//! granite-record: runs a program in a pty and passes its input and output
//! through unchanged, while logging the output to a file with each read()
//! as its own record (see recording.zig). Recordings in test/recordings
//! are replayed by the round-trip test.
//!
//!   ./zig-out/bin/granite-record test/recordings/claude.rec claude

const std = @import("std");
const recording = @import("recording");

const c = std.c;
const posix = std.posix;

/// _IOW('t', 103, struct winsize), which std.c doesn't define for macOS.
const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));

extern "c" fn forkpty(
    master: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn cfmakeraw(termios: *posix.termios) void;
extern "c" fn perror(s: [*:0]const u8) void;

var winch_pending: std.atomic.Value(bool) = .init(false);

fn onSigwinch(_: posix.SIG) callconv(.c) void {
    winch_pending.store(true, .monotonic);
}

fn writeAll(fd: posix.fd_t, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) switch (posix.errno(n)) {
            .INTR, .AGAIN => continue,
            else => return,
        };
        rest = rest[@intCast(n)..];
    }
}

fn hostSize() posix.winsize {
    var ws: posix.winsize = undefined;
    _ = c.ioctl(posix.STDOUT_FILENO, c.T.IOCGWINSZ, &ws);
    return ws;
}

fn log(fd: posix.fd_t, record: recording.Record) void {
    var buf: [65536 + 8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    recording.write(&w, record) catch unreachable;
    writeAll(fd, w.buffered());
}

pub fn main(init: std.process.Init) !u8 {
    const args = init.minimal.args.vector;
    if (args.len < 3) {
        std.debug.print("usage: granite-record <file> <command> [args...]\n", .{});
        return 2;
    }
    if (c.isatty(posix.STDIN_FILENO) == 0 or c.isatty(posix.STDOUT_FILENO) == 0) {
        std.debug.print("granite-record: stdin and stdout must be a terminal\n", .{});
        return 1;
    }
    const cmd: [*:null]const ?[*:0]const u8 = @ptrCast(args.ptr + 2);

    const file = c.open(args[1], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (file < 0) {
        perror(args[1]);
        return 1;
    }
    defer _ = c.close(file);

    const ws = hostSize();
    writeAll(file, recording.magic);
    log(file, .{ .size = .{ .cols = ws.col, .rows = ws.row } });

    var pty: posix.fd_t = undefined;
    const pid = forkpty(&pty, null, null, &ws);
    if (pid < 0) {
        perror("forkpty");
        return 1;
    }
    if (pid == 0) {
        _ = execvp(cmd[0].?, cmd);
        perror(cmd[0].?);
        c._exit(127);
    }

    const orig = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = orig;
    cfmakeraw(&raw);
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {};
    defer posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig) catch {};

    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = onSigwinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    var buf: [65536]u8 = undefined;
    while (true) {
        if (winch_pending.swap(false, .monotonic)) {
            const new = hostSize();
            _ = c.ioctl(pty, TIOCSWINSZ, &new);
            log(file, .{ .size = .{ .cols = new.col, .rows = new.row } });
        }

        var fds = [_]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pty, .events = posix.POLL.IN, .revents = 0 },
        };
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (posix.errno(-1) == .INTR) continue;
            break;
        }

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buf) catch break;
            if (n == 0) break;
            writeAll(pty, buf[0..n]);
        }

        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(pty, &buf) catch break;
            if (n == 0) break;
            writeAll(posix.STDOUT_FILENO, buf[0..n]);
            log(file, .{ .output = buf[0..n] });
        }
    }

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    const s: u32 = @bitCast(status);
    if (posix.W.IFSIGNALED(s)) return 128 + @as(u8, @intCast(@backingInt(posix.W.TERMSIG(s))));
    return posix.W.EXITSTATUS(s);
}
