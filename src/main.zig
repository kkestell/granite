//! A minimal terminal multiplexer: one window, one pane, no detach.
//!
//! Runs a program (default: claude) in a pty, feeds its output into a
//! Ghostty terminal, and redraws the host terminal from the render state.
//! Keyboard and mouse input from the host is forwarded to the pty as-is;
//! the input modes the program enables (cursor keys, mouse, focus,
//! bracketed paste, Kitty keyboard) are mirrored onto the host terminal so
//! the host encodes input the way the program expects.
//!
//!   ./zig-out/bin/granite            # runs claude
//!   ./zig-out/bin/granite htop       # runs any other program

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
    _ = c.ioctl(m.pty.?, TIOCSWINSZ, &ws);
    try m.resize(ws);
}

//------------------------------------------------------------------------

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const args = init.minimal.args.vector;
    const default_cmd = [_:null]?[*:0]const u8{"claude"};
    const cmd: [*:null]const ?[*:0]const u8 = if (args.len > 1)
        @ptrCast(args.ptr + 1)
    else
        &default_cmd;

    if (c.isatty(posix.STDIN_FILENO) == 0 or c.isatty(posix.STDOUT_FILENO) == 0) {
        std.debug.print("granite: stdin and stdout must be a terminal\n", .{});
        return 1;
    }

    const ws = hostSize();

    var pty: posix.fd_t = undefined;
    const pid = forkpty(&pty, null, null, &ws);
    if (pid < 0) {
        perror("forkpty");
        return 1;
    }
    if (pid == 0) {
        _ = setenv("TERM", "xterm-256color", 1);
        _ = execvp(cmd[0].?, cmd);
        perror(cmd[0].?);
        c._exit(127);
    }
    errdefer posix.kill(pid, .TERM) catch {};

    var m: Mux = undefined;
    try m.init(init.io, gpa, ws, pty);
    defer m.deinit();
    try resize(&m);

    const orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    setupHost(orig_termios);
    errdefer restoreHost(&m, orig_termios);
    try queryHost(&m);

    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = onSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    var dirty = true;
    var last_render: i64 = 0;
    var buf: [65536]u8 = undefined;

    while (true) {
        if (winch_pending.swap(false, .monotonic)) {
            try resize(&m);
            dirty = true;
        }

        const now = nowMs();
        if (m.held and now - m.held_since > hold_timeout_ms) m.held = false;

        if (dirty and !m.held and now - last_render >= frame_ms) {
            try mux.render(&m);
            last_render = now;
            dirty = false;
        }
        if (m.out.written().len > 0) flush(&m);

        var timeout: i64 = -1;
        if (m.held) {
            timeout = hold_timeout_ms - (now - m.held_since);
        } else if (dirty) {
            timeout = frame_ms - (now - last_render);
        }
        if (dirty and timeout < 0) timeout = 0;

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pty, .events = posix.POLL.IN, .revents = 0 },
        };
        // A raw poll, so that SIGWINCH interrupts the wait.
        if (c.poll(&fds, fds.len, @intCast(timeout)) < 0) {
            if (posix.errno(-1) == .INTR) continue;
            break;
        }

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buf) catch break;
            if (n == 0) break;
            writeAll(pty, buf[0..n]);
        }

        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            // The program exited.
            const n = posix.read(pty, &buf) catch break;
            if (n == 0) break;
            m.feed(buf[0..n]);
            dirty = true;
        }
    }

    if (dirty) {
        try mux.render(&m);
        flush(&m);
    }
    restoreHost(&m, orig_termios);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    const s: u32 = @bitCast(status);
    if (posix.W.IFSIGNALED(s)) return 128 + @as(u8, @intCast(@backingInt(posix.W.TERMSIG(s))));
    return posix.W.EXITSTATUS(s);
}
