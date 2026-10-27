//! A minimal terminal multiplexer with one to three panes, no detach.
//!
//! With no arguments, runs claude on the left, codex on the top right, and
//! opencode on the bottom right. Ctrl-] moves focus to the next pane. A
//! command runs alone with unchanged input and no chrome; separate two or
//! three commands with a lone :: to split them.
//! Each program has its own pty and Ghostty terminal. The focused pane's
//! input modes are mirrored onto the host, and only dirty rows redraw.
//!
//!   ./zig-out/bin/granite
//!   ./zig-out/bin/granite htop
//!   ./zig-out/bin/granite claude :: codex
//!   ./zig-out/bin/granite claude :: codex :: opencode

const std = @import("std");
const mux = @import("mux.zig");

const c = std.c;
const posix = std.posix;
const Mux = mux.Mux;
const nowMs = mux.nowMs;
const writeAll = mux.writeAll;

const frame_ms = 16;
const hold_timeout_ms = 1000;
const host_reply_timeout_ms = 1000;

/// _IOW('t', 103, struct winsize), which std.c doesn't define for macOS.
const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));

extern "c" fn forkpty(
    master: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn cfmakeraw(termios: *posix.termios) void;
extern "c" fn perror(s: [*:0]const u8) void;

var winch_pending: std.atomic.Value(bool) = .init(false);

fn onSigwinch(_: posix.SIG) callconv(.c) void {
    winch_pending.store(true, .monotonic);
}

fn flush(m: *Mux) void {
    writeAll(posix.STDOUT_FILENO, m.out.written());
    m.out.clearRetainingCapacity();
}

//------------------------------------------------------------------------
// Logging

pub const std_options: std.Options = .{ .logFn = writeLog };

var log_fd: ?posix.fd_t = null;
var log_opened = false;

/// Ghostty logs through std.log, and stderr is the host terminal, so logs
/// would land on the screen. They go to the file named by GRANITE_LOG, or
/// nowhere.
fn writeLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!log_opened) {
        log_opened = true;
        if (c.getenv("GRANITE_LOG")) |path| {
            const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o644));
            if (fd >= 0) log_fd = fd;
        }
    }
    const fd = log_fd orelse return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{s}({t}): ", .{ level.asText(), scope }) catch {};
    w.print(format ++ "\n", args) catch {};
    writeAll(fd, w.buffered());
}

//------------------------------------------------------------------------
// Host terminal setup

fn restoreHost(m: *Mux, orig: posix.termios) void {
    mux.writeRestore(m);
    flush(m);
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig) catch {};
}

fn setupHost(orig: posix.termios) void {
    var raw = orig;
    cfmakeraw(&raw);
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {};
    writeAll(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[2J");
}

/// Ask the host for its colors and grapheme clustering mode; see
/// `mux.useHostRepliesFor`.
fn queryHost(m: *Mux) !void {
    writeAll(posix.STDOUT_FILENO, mux.host_queries);

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    const deadline = nowMs() + host_reply_timeout_ms;
    while (len < buf.len and !mux.hostRepliesDone(buf[0..len])) {
        const left = deadline - nowMs();
        if (left <= 0) break;
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(left)) == 0) break;
        const n = posix.read(posix.STDIN_FILENO, buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    try m.useHostReplies(buf[0..len]);
}

fn hostSize() posix.winsize {
    var ws: posix.winsize = undefined;
    _ = c.ioctl(posix.STDOUT_FILENO, c.T.IOCGWINSZ, &ws);
    return ws;
}

fn resize(m: *Mux) !void {
    const ws = hostSize();
    try m.resize(ws);
    for (m.panes[0..m.count]) |*p| if (p.pty) |pty| {
        _ = c.ioctl(pty, TIOCSWINSZ, &p.ws);
    };
}

//------------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = init.minimal.args.vector;
    const claude = [_:null]?[*:0]const u8{"claude"};
    const codex = [_:null]?[*:0]const u8{"codex"};
    const opencode = [_:null]?[*:0]const u8{"opencode"};
    var commands = [_][*:null]const ?[*:0]const u8{ &claude, &codex, &opencode };
    var count: usize = 3;
    // Every command but the last needs its own null-terminated copy.
    var copies: [2]?[:null]?[*:0]const u8 = @splat(null);
    defer for (copies) |copy| if (copy) |a| gpa.free(a);
    if (args.len > 1) {
        var separators: [2]usize = undefined;
        var found: usize = 0;
        var start: usize = 1;
        for (args[1..], 1..) |arg, i| {
            if (!std.mem.eql(u8, std.mem.span(arg), "::")) continue;
            if (found == separators.len or i == start or i + 1 == args.len) {
                std.debug.print("granite: expected cmd args... [:: cmd args... [:: cmd args...]]\n", .{});
                return 2;
            }
            separators[found] = i;
            found += 1;
            start = i + 1;
        }
        start = 1;
        for (separators[0..found], copies[0..found], commands[0..found]) |at, *copy, *cmd| {
            const head = try gpa.allocSentinel(?[*:0]const u8, at - start, null);
            copy.* = head;
            for (args[start..at], head) |arg, *dest| dest.* = arg;
            cmd.* = head.ptr;
            start = at + 1;
        }
        commands[found] = @ptrCast(args.ptr + start);
        count = found + 1;
    }

    if (c.isatty(posix.STDIN_FILENO) == 0 or c.isatty(posix.STDOUT_FILENO) == 0) {
        std.debug.print("granite: stdin and stdout must be a terminal\n", .{});
        return 1;
    }

    var labels: [3][]const u8 = undefined;
    for (commands[0..count], labels[0..count]) |cmd, *label| label.* = std.fs.path.basename(std.mem.span(cmd[0].?));
    var m: Mux = undefined;
    try m.init(init.io, gpa, hostSize(), labels[0..count]);
    defer m.deinit();
    defer for (m.panes[0..count]) |*p| {
        if (p.pty) |pty| _ = c.close(pty);
    };
    errdefer for (m.panes[0..count]) |*p| {
        if (p.pid) |pid| if (p.status == null) {
            posix.kill(pid, .TERM) catch {};
            _ = c.waitpid(pid, null, 0);
        };
    };

    for (m.panes[0..count], commands[0..count]) |*p, cmd| {
        var pty: posix.fd_t = undefined;
        const pid = forkpty(&pty, null, null, &p.ws);
        if (pid < 0) return error.ForkptyFailed;
        if (pid == 0) {
            // Later children must not retain earlier children's masters.
            for (m.panes[0..count]) |*other| if (other.pty) |fd| {
                _ = c.close(fd);
            };
            _ = setenv("TERM", "xterm-256color", 1);
            _ = execvp(cmd[0].?, cmd);
            perror(cmd[0].?);
            c._exit(127);
        }
        p.pty = pty;
        p.pid = pid;
    }
    try resize(&m);

    const orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    setupHost(orig_termios);
    defer restoreHost(&m, orig_termios);
    try queryHost(&m);

    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = onSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    var last_render: i64 = 0;
    var buf: [65536]u8 = undefined;
    var live = count;
    while (live > 0) {
        if (winch_pending.swap(false, .monotonic)) try resize(&m);
        const now = nowMs();
        for (m.panes[0..count]) |*p| {
            if (p.held and now - p.held_since >= hold_timeout_ms) p.held = false;
        }
        if (m.needsRender() and now - last_render >= frame_ms) {
            try mux.render(&m);
            last_render = now;
        }
        if (m.out.written().len > 0) flush(&m);

        var timeout: i64 = -1;
        if (m.needsRender()) timeout = @max(0, frame_ms - (now - last_render));
        for (m.panes[0..count]) |*p| {
            if (p.held) {
                const left = @max(0, hold_timeout_ms - (now - p.held_since));
                timeout = if (timeout < 0) left else @min(timeout, left);
            }
        }
        var fds: [4]posix.pollfd = undefined;
        fds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };
        for (m.panes[0..count], fds[1 .. count + 1]) |*p, *fd| {
            fd.* = .{ .fd = p.pty orelse -1, .events = posix.POLL.IN, .revents = 0 };
        }
        // Raw poll lets SIGWINCH interrupt the wait.
        if (c.poll(&fds, @intCast(count + 1), @intCast(timeout)) < 0) {
            if (posix.errno(-1) == .INTR) continue;
            break;
        }
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buf) catch break;
            if (n == 0) break;
            m.input(buf[0..n]);
        }
        for (m.panes[0..count], fds[1 .. count + 1], 0..) |*p, fd, i| {
            if (fd.revents & (posix.POLL.IN | posix.POLL.HUP) == 0) continue;
            const n = posix.read(fd.fd, &buf) catch 0;
            if (n > 0) {
                p.feed(buf[0..n]);
                continue;
            }
            var status: c_int = 0;
            _ = c.waitpid(p.pid.?, &status, 0);
            p.status = exitStatus(@bitCast(status));
            _ = c.close(p.pty.?);
            p.pty = null;
            p.held = false;
            live -= 1;
            if (count > 1) m.chrome_dirty = true;
            if (count > 1 and m.focus == i) m.focusNext();
        }
    }
    // Preserve a short-lived child's final output, including held output.
    for (m.panes[0..count]) |*p| p.held = false;
    if (m.needsRender()) try mux.render(&m);
    flush(&m);
    for (m.panes[0..count]) |*p| {
        if (p.status == null) {
            var status: c_int = 0;
            _ = c.waitpid(p.pid.?, &status, 0);
            p.status = exitStatus(@bitCast(status));
        }
    }
    for (m.panes[0..count]) |*p| if (p.status.? != 0) return p.status.?;
    return 0;
}

fn exitStatus(status: u32) u8 {
    if (posix.W.IFSIGNALED(status)) return 128 + @as(u8, @intCast(@backingInt(posix.W.TERMSIG(status))));
    return posix.W.EXITSTATUS(status);
}
