//! The program the live tests run inside granite. Each scenario writes a
//! known sequence of output, sometimes with pauses, and reports what it
//! sees on its tty.
//!
//!   child exit <status> <text>   print text and exit with status
//!   child kill                   kill itself with SIGTERM
//!   child hold                   draw inside a mode 2026 hold, then release it
//!   child hold-forever           start a mode 2026 hold and never release it
//!   child burst <lines>          print many lines as fast as possible
//!   child size                   print the tty size at start and on SIGWINCH
//!   child modes                  enable input modes, echo input until 'q'
//!   child input <label> <plain|modes> <exit-status> [file]   echo and record input
//!   child query <file>           send queries and write the replies to file

const std = @import("std");

const c = std.c;
const posix = std.posix;

extern "c" fn cfmakeraw(termios: *posix.termios) void;

fn write(data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const n = c.write(posix.STDOUT_FILENO, rest.ptr, rest.len);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    write(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn sleepMs(ms: i32) void {
    _ = c.poll(&[_]posix.pollfd{}, 0, ms);
}

fn rawMode() void {
    var t = posix.tcgetattr(posix.STDIN_FILENO) catch return;
    cfmakeraw(&t);
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, t) catch {};
}

/// Read one byte, or null after `timeout_ms` or at end of input.
fn readByte(timeout_ms: i32) ?u8 {
    var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    if (c.poll(&fds, 1, timeout_ms) <= 0) return null;
    var b: [1]u8 = undefined;
    const n = posix.read(posix.STDIN_FILENO, &b) catch return null;
    return if (n == 1) b[0] else null;
}

var winch: std.atomic.Value(bool) = .init(false);

fn onSigwinch(_: posix.SIG) callconv(.c) void {
    winch.store(true, .monotonic);
}

fn printSize() void {
    var ws: posix.winsize = undefined;
    _ = c.ioctl(posix.STDOUT_FILENO, c.T.IOCGWINSZ, &ws);
    print("\x1b[H\x1b[2Ksize {d}x{d}", .{ ws.col, ws.row });
}

pub fn main(init: std.process.Init) !u8 {
    const args = init.minimal.args.vector;
    if (args.len < 2) return 2;
    const scenario = std.mem.span(args[1]);

    if (std.mem.eql(u8, scenario, "exit")) {
        write(std.mem.span(args[3]));
        return std.fmt.parseInt(u8, std.mem.span(args[2]), 10);
    }

    if (std.mem.eql(u8, scenario, "kill")) {
        write("killed");
        posix.kill(c.getpid(), .TERM) catch {};
        sleepMs(1000);
        return 1;
    }

    if (std.mem.eql(u8, scenario, "hold")) {
        rawMode();
        write("before");
        sleepMs(200);
        write("\x1b[?2026h\x1b[2;1Hheld-1");
        sleepMs(300);
        write(" held-2\x1b[?2026l");
        _ = readByte(10_000);
        return 0;
    }

    if (std.mem.eql(u8, scenario, "hold-forever")) {
        rawMode();
        write("start");
        sleepMs(100);
        write("\x1b[?2026h\x1b[2;1Hstuck");
        _ = readByte(10_000);
        return 0;
    }

    if (std.mem.eql(u8, scenario, "burst")) {
        rawMode();
        const lines = try std.fmt.parseInt(u32, std.mem.span(args[2]), 10);
        for (0..lines) |i| print("line {d}\r\n", .{i});
        write("done");
        _ = readByte(10_000);
        return 0;
    }

    if (std.mem.eql(u8, scenario, "size")) {
        rawMode();
        posix.sigaction(.WINCH, &.{
            .handler = .{ .handler = onSigwinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        printSize();
        while (true) {
            if (winch.swap(false, .monotonic)) printSize();
            if (readByte(50)) |b| if (b == 'q') return 0;
        }
    }

    if (std.mem.eql(u8, scenario, "modes")) {
        rawMode();
        write("\x1b[?1h\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b=\x1b[>1u\x1b[5 qready");
        while (readByte(10_000)) |b| {
            if (b == 'q') return 0;
            print("\r\ngot {d}", .{b});
        }
        return 1;
    }

    if (std.mem.eql(u8, scenario, "input")) {
        rawMode();
        const label = std.mem.span(args[2]);
        const status = try std.fmt.parseInt(u8, std.mem.span(args[4]), 10);
        const file = if (args.len > 5)
            c.open(args[5], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644))
        else
            -1;
        defer if (file >= 0) {
            _ = c.close(file);
        };
        if (std.mem.eql(u8, std.mem.span(args[3]), "modes")) {
            write("\x1b[?1h\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?1004h\x1b=\x1b[>1u\x1b[5 q");
        }
        print("\x1b]0;{s}\x07{s} ready", .{ label, label });
        while (readByte(10_000)) |b| {
            if (file >= 0) _ = c.write(file, @ptrCast(&b), 1);
            if (b == 'q') return status;
            print("\r\n{s} got {d}", .{ label, b });
        }
        return 1;
    }

    if (std.mem.eql(u8, scenario, "query")) {
        rawMode();
        // DA1 goes last: its reply marks the end of the replies.
        write("\x1b[3;5H\x1b]10;?\x1b\\\x1b]11;?\x07\x1b]4;1;?\x1b\\\x1b[6n\x1b[?2027$p\x1b[c");
        var replies: [1024]u8 = undefined;
        var len: usize = 0;
        while (len < replies.len) {
            const b = readByte(2000) orelse break;
            replies[len] = b;
            len += 1;
            if (b == 'c' and std.mem.lastIndexOf(u8, replies[0..len], "\x1b[?") != null) break;
        }
        const file = c.open(args[2], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
        if (file < 0) return 1;
        _ = c.write(file, &replies, len);
        _ = c.close(file);
        write("queried");
        return 0;
    }

    return 2;
}
