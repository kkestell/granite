//! Live tests: granite runs the scripted child (child.zig) in a real pty,
//! and the test is granite's host terminal. It owns the pty granite runs
//! in, feeds granite's output into a Ghostty terminal that answers
//! granite's startup queries, and checks what that terminal shows, its
//! modes, timing, and granite's exit status.

const std = @import("std");
const vt = @import("ghostty-vt");
const mux = @import("mux");
const options = @import("live_options");

const c = std.c;
const posix = std.posix;
const Handler = vt.TerminalStream.Handler;
const gpa = std.testing.allocator;
const io = std.testing.io;

/// _IOW('t', 103, struct winsize), which std.c doesn't define for macOS.
const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));

extern "c" fn forkpty(
    master: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c.pid_t;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// The host's colors, as the replies to granite's color queries carry them.
const host_colors = blk: {
    var r: []const u8 = "\x1b]10;rgb:d0d0/d1d1/d2d2\x1b\\\x1b]11;rgb:1010/1111/1212\x1b\\";
    for (0..16) |i| {
        r = r ++ std.fmt.comptimePrint("\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ i, i * 16 + 1, 255 - i * 15, i * 7 + 3 });
    }
    break :blk r;
};

const Host = struct {
    pid: c.pid_t,
    pty: posix.fd_t,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    /// Everything granite wrote.
    output: std.ArrayList(u8) = .empty,
    /// When each read from granite ended, by offset into `output`.
    reads: std.ArrayList(struct { end: usize, ms: i64 }) = .empty,
    eof: bool = false,
    status: ?u32 = null,
    screen_text: ?[]const u8 = null,

    /// Start granite running the child with `args`.
    fn start(args: []const []const u8, cols: u16, rows: u16) !*Host {
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        defer {
            for (argv.items) |a| if (a) |p| gpa.free(std.mem.span(p));
            argv.deinit(gpa);
        }
        try argv.append(gpa, try gpa.dupeSentinel(u8, options.granite, 0));
        try argv.append(gpa, try gpa.dupeSentinel(u8, options.child, 0));
        for (args) |a| try argv.append(gpa, try gpa.dupeSentinel(u8, a, 0));
        try argv.append(gpa, null);

        const h = try gpa.create(Host);
        errdefer gpa.destroy(h);
        h.* = .{
            .pid = undefined,
            .pty = undefined,
            .terminal = try .init(io, gpa, .{ .cols = cols, .rows = rows }),
            .stream = undefined,
        };
        try mux.useHostRepliesFor(&h.terminal, gpa, host_colors);
        h.terminal.modes.setDefault(.grapheme_cluster, true);
        var handler = h.terminal.vtHandler();
        handler.effects.write_pty = &writePty;
        handler.effects.device_attributes = &deviceAttributes;
        h.stream = .init(.{ .allocator = gpa, .handler = handler });

        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = cols * 8, .ypixel = rows * 16 };
        const pid = forkpty(&h.pty, null, null, &ws);
        if (pid < 0) return error.ForkptyFailed;
        if (pid == 0) {
            _ = execv(argv.items[0].?, @ptrCast(argv.items.ptr));
            c._exit(127);
        }
        h.pid = pid;
        return h;
    }

    fn deinit(h: *Host) void {
        if (h.status == null) {
            posix.kill(h.pid, .KILL) catch {};
            var status: c_int = 0;
            _ = c.waitpid(h.pid, &status, 0);
        }
        _ = c.close(h.pty);
        h.stream.deinit();
        h.terminal.deinit(gpa);
        h.output.deinit(gpa);
        h.reads.deinit(gpa);
        if (h.screen_text) |t| gpa.free(t);
        gpa.destroy(h);
    }

    fn fromHandler(handler: *Handler) *Host {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn writePty(handler: *Handler, data: []const u8) void {
        mux.writeAll(fromHandler(handler).pty, data);
    }

    fn deviceAttributes(_: *Handler) vt.device_attributes.Attributes {
        return .{};
    }

    /// Read and show what granite writes, for up to `timeout_ms`.
    fn pump(h: *Host, timeout_ms: i64) !void {
        if (h.eof) return;
        var fds = [_]posix.pollfd{.{ .fd = h.pty, .events = posix.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, @intCast(@max(timeout_ms, 0))) <= 0) return;
        var buf: [65536]u8 = undefined;
        const n = posix.read(h.pty, &buf) catch 0;
        if (n == 0) {
            h.eof = true;
            return;
        }
        try h.output.appendSlice(gpa, buf[0..n]);
        try h.reads.append(gpa, .{ .end = h.output.items.len, .ms = mux.nowMs() });
        h.stream.nextSlice(buf[0..n]);
    }

    /// Pump until `done` returns true. Fails after `timeout_ms`.
    fn waitUntil(h: *Host, timeout_ms: i64, ctx: anytype, comptime done: fn (*Host, @TypeOf(ctx)) bool) !void {
        const deadline = mux.nowMs() + timeout_ms;
        while (!done(h, ctx)) {
            const left = deadline - mux.nowMs();
            if (left <= 0 or h.eof) {
                std.debug.print("timed out; screen:\n{s}\n", .{try h.screen()});
                return error.Timeout;
            }
            try h.pump(@min(left, 50));
        }
    }

    fn waitForOutput(h: *Host, text: []const u8) !void {
        try h.waitUntil(5000, text, struct {
            fn f(host: *Host, t: []const u8) bool {
                return std.mem.indexOf(u8, host.output.items, t) != null;
            }
        }.f);
    }

    fn waitForScreen(h: *Host, text: []const u8) !void {
        try h.waitUntil(5000, text, struct {
            fn f(host: *Host, t: []const u8) bool {
                const s = host.screen() catch return false;
                return std.mem.indexOf(u8, s, t) != null;
            }
        }.f);
    }

    /// The text of the active screen without trailing blanks. Valid
    /// until the next call.
    fn screen(h: *Host) ![]const u8 {
        if (h.screen_text) |t| gpa.free(t);
        h.screen_text = null;
        const plain = try h.terminal.plainString(gpa);
        defer gpa.free(plain);

        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        var lines = std.mem.splitScalar(u8, plain, '\n');
        while (lines.next()) |line| {
            try text.appendSlice(gpa, std.mem.trimEnd(u8, line, " "));
            try text.append(gpa, '\n');
        }
        const trimmed = std.mem.trimEnd(u8, text.items, "\n");
        text.shrinkRetainingCapacity(trimmed.len);
        h.screen_text = try text.toOwnedSlice(gpa);
        return h.screen_text.?;
    }

    /// When `text` first appeared in granite's output.
    fn firstSeen(h: *Host, text: []const u8) ?i64 {
        const i = std.mem.indexOf(u8, h.output.items, text) orelse return null;
        for (h.reads.items) |r| if (r.end >= i + text.len) return r.ms;
        return null;
    }

    fn send(h: *Host, data: []const u8) void {
        mux.writeAll(h.pty, data);
    }

    fn resize(h: *Host, cols: u16, rows: u16) !void {
        try h.stream.handler.resize(.{ .cols = cols, .rows = rows });
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = cols * 8, .ypixel = rows * 16 };
        _ = c.ioctl(h.pty, TIOCSWINSZ, &ws);
    }

    /// Read until granite closes the pty, then return its exit status.
    fn wait(h: *Host) !u32 {
        const deadline = mux.nowMs() + 5000;
        while (!h.eof) {
            if (mux.nowMs() > deadline) return error.Timeout;
            try h.pump(50);
        }
        var status: c_int = 0;
        if (c.waitpid(h.pid, &status, 0) < 0) return error.WaitFailed;
        const s: u32 = @bitCast(status);
        h.status = s;
        if (posix.W.IFSIGNALED(s)) return 128 + @as(u32, @backingInt(posix.W.TERMSIG(s)));
        return posix.W.EXITSTATUS(s);
    }

    fn mode(h: *Host, comptime value: u16) bool {
        return h.terminal.modes.get(comptime vt.modes.modeFromInt(value, false).?);
    }
};

test "exit status" {
    const h = try Host.start(&.{ "exit", "7", "" }, 40, 10);
    defer h.deinit();
    try std.testing.expectEqual(7, try h.wait());
}

test "killed child" {
    const h = try Host.start(&.{"kill"}, 40, 10);
    defer h.deinit();
    try std.testing.expectEqual(128 + 15, try h.wait());
}

test "missing command" {
    const granite = try gpa.dupeSentinel(u8, options.granite, 0);
    defer gpa.free(granite);
    var argv = [_:null]?[*:0]const u8{ granite, "/nonexistent/granite-test-command" };
    var pty: posix.fd_t = undefined;
    const pid = forkpty(&pty, null, null, &.{ .row = 10, .col = 40, .xpixel = 0, .ypixel = 0 });
    if (pid == 0) {
        _ = execv(argv[0].?, &argv);
        c._exit(127);
    }
    defer _ = c.close(pty);
    // Answer nothing: granite gives up on the host's replies after a second.
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(pty, &buf) catch break;
        if (n == 0) break;
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(127, posix.W.EXITSTATUS(@bitCast(status)));
}

test "short-lived child's output is drawn before granite exits" {
    // Granite reads the output and sees the pty close in the same frame
    // interval, so its last frame comes after the program exits.
    for (0..10) |_| {
        const h = try Host.start(&.{ "exit", "0", "goodbye from the child" }, 40, 10);
        defer h.deinit();
        try std.testing.expectEqual(0, try h.wait());
        try std.testing.expect(std.mem.indexOf(u8, h.output.items, "goodbye from the child") != null);
    }
}

test "mode 2026 holds drawing until it ends" {
    const h = try Host.start(&.{"hold"}, 40, 10);
    defer h.deinit();
    try h.waitForScreen("held-1 held-2");

    // Both halves reach the host in the same frame.
    const out = h.output.items;
    const first = std.mem.indexOf(u8, out, "held-1").?;
    const second = std.mem.indexOf(u8, out, "held-2").?;
    try std.testing.expect(std.mem.indexOf(u8, out[first..second], "\x1b[?2026l") == null);

    // The hold kept "held-1" off the host for the 300ms it lasted.
    const before = h.firstSeen("before").?;
    try std.testing.expect(h.firstSeen("held-1").? - before >= 450);
    h.send("q");
    try std.testing.expectEqual(0, try h.wait());
}

test "mode 2026 hold times out after a second" {
    const h = try Host.start(&.{"hold-forever"}, 40, 10);
    defer h.deinit();
    try h.waitForScreen("start");
    try h.waitForScreen("stuck");
    const held_for = h.firstSeen("stuck").? - h.firstSeen("start").?;
    try std.testing.expect(held_for >= 1000);
    try std.testing.expect(held_for < 2500);
    h.send("q");
    try std.testing.expectEqual(0, try h.wait());
}

test "frames are coalesced" {
    const h = try Host.start(&.{ "burst", "3000" }, 40, 10);
    defer h.deinit();
    try h.waitForScreen("done");

    const start = h.firstSeen("line ").?;
    const elapsed = h.firstSeen("done").? - start;
    const begin = std.mem.indexOf(u8, h.output.items, "line ").?;
    const frames = std.mem.count(u8, h.output.items[begin..], "\x1b[?2026h");
    // At most one frame per 16ms, plus the first and the last.
    try std.testing.expect(frames <= @divTrunc(elapsed, 16) + 2);
    try std.testing.expectEqualStrings("line 2991\nline 2992\nline 2993\nline 2994\nline 2995\nline 2996\nline 2997\nline 2998\nline 2999\ndone", try h.screen());
    h.send("q");
    try std.testing.expectEqual(0, try h.wait());
}

test "resize reaches the child and redraws the host" {
    const h = try Host.start(&.{"size"}, 40, 10);
    defer h.deinit();
    try h.waitForScreen("size 40x10");

    try h.resize(60, 15);
    try h.waitForScreen("size 60x15");
    try std.testing.expectEqualStrings("size 60x15", try h.screen());

    try h.resize(30, 5);
    try h.waitForScreen("size 30x5");
    try std.testing.expectEqualStrings("size 30x5", try h.screen());

    // A SIGWINCH without a size change still leaves the screen drawn.
    const before = h.output.items.len;
    try posix.kill(h.pid, .WINCH);
    try h.waitUntil(5000, before, struct {
        fn f(host: *Host, n: usize) bool {
            return std.mem.indexOf(u8, host.output.items[n..], "size 30x5") != null;
        }
    }.f);
    try h.pump(100);
    try std.testing.expectEqualStrings("size 30x5", try h.screen());

    h.send("q");
    try std.testing.expectEqual(0, try h.wait());
}

test "input modes are mirrored and restored" {
    const h = try Host.start(&.{"modes"}, 40, 10);
    defer h.deinit();
    try h.waitForScreen("ready");
    for ([_]bool{ h.mode(1), h.mode(66), h.mode(1000), h.mode(1004), h.mode(1006), h.mode(2004) }) |on| {
        try std.testing.expect(on);
    }
    try std.testing.expectEqual(1, h.terminal.screens.active.kitty_keyboard.current().int());
    try std.testing.expectEqual(.bar, h.terminal.screens.active.cursor.cursor_style);

    // Input reaches the program unchanged.
    h.send("a");
    try h.waitForScreen("got 97");

    h.send("q");
    try std.testing.expectEqual(0, try h.wait());
    for ([_]bool{ h.mode(1), h.mode(66), h.mode(1000), h.mode(1004), h.mode(1006), h.mode(2004), h.mode(1049) }) |on| {
        try std.testing.expect(!on);
    }
    try std.testing.expect(h.mode(25));
    try std.testing.expectEqual(0, h.terminal.screens.active.kitty_keyboard.current().int());
    try std.testing.expectEqual(.block, h.terminal.screens.active.cursor.cursor_style);
}

test "queries are answered" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/granite-live-{d}.replies", .{c.getpid()});
    const h = try Host.start(&.{ "query", path }, 40, 10);
    defer h.deinit();
    try std.testing.expectEqual(0, try h.wait());

    const replies = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(replies);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const expected = [_][]const u8{
        "\x1b]10;rgb:d0d0/d1d1/d2d2",
        "\x1b]11;rgb:1010/1111/1212",
        "\x1b]4;1;rgb:1111/f0f0/0a0a",
        "\x1b[3;5R",
        "\x1b[?2027;1$y",
        "\x1b[?62;22c",
    };
    var at: usize = 0;
    for (expected) |e| {
        const i = std.mem.indexOfPos(u8, replies, at, e) orelse {
            std.debug.print("missing reply {any} in {any}\n", .{ e, replies });
            return error.MissingReply;
        };
        at = i + e.len;
    }
}
