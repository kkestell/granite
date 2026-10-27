//! Round-trip tests for granite's renderer.
//!
//! Program output is fed to granite's Mux and to a twin terminal that sees
//! the same bytes. After every chunk granite renders a frame, the frame is
//! fed to a host terminal, and the twin's screen is compared with the
//! host's. The twin stands in for granite's terminal because reading a
//! terminal consumes its dirty flags, which granite's incremental
//! rendering depends on. Each input runs with its original chunk
//! boundaries and with seeded random splits.

const std = @import("std");
const vt = @import("ghostty-vt");
const mux = @import("mux");
const recording = @import("recording");
const options = @import("test_options");
const screen = @import("screen.zig");
const fixtures = @import("fixtures.zig");
const fuzz = @import("fuzz.zig");

const Record = recording.Record;
const gpa = std.testing.allocator;
const io = std.testing.io;

const splits_per_fixture = 8;
const splits_per_fuzz_case = 2;
const splits_per_recording = 2;

// Every test sets the log level to errors: Ghostty warns about the
// malformed sequences the fuzzer writes.

/// The host's replies to granite's queries. The palette differs from
/// Ghostty's built-in one, so a palette index only matches when both
/// terminals resolve it against the host's palette. Grapheme clustering is
/// on, as in Ghostty.
const host_replies = blk: {
    var r: []const u8 = "\x1b]10;rgb:d0d0/d1d1/d2d2\x1b\\\x1b]11;rgb:1010/1111/1212\x1b\\";
    for (0..16) |i| {
        r = r ++ std.fmt.comptimePrint("\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ i, i * 16 + 1, 255 - i * 15, i * 7 + 3 });
    }
    break :blk r ++ "\x1b[?2027;1$y\x1b[?62;22c";
};

/// A terminal with no effects.
const Term = struct {
    terminal: vt.Terminal,
    stream: vt.TerminalStream,

    fn init(t: *Term, s: recording.Size) !void {
        t.terminal = try .init(io, gpa, .{ .cols = s.cols, .rows = s.rows });
        t.stream = .init(.{ .allocator = gpa, .handler = t.terminal.vtHandler() });
        try mux.useHostRepliesFor(&t.terminal, gpa, host_replies);
    }

    fn deinit(t: *Term) void {
        t.stream.deinit();
        t.terminal.deinit(gpa);
    }

    fn resize(t: *Term, s: recording.Size) !void {
        try t.stream.handler.resize(.{ .cols = s.cols, .rows = s.rows });
    }
};

fn winsize(s: recording.Size) std.posix.winsize {
    return .{ .row = s.rows, .col = s.cols, .xpixel = s.cols * 8, .ypixel = s.rows * 16 };
}

/// Run `records` through granite and return a report of the first frame
/// whose host screen differs from the program's, or null if none do.
fn roundTrip(label: []const u8, initial: recording.Size, records: []const Record) !?[]u8 {
    var m: mux.Mux = undefined;
    try m.init(io, gpa, winsize(initial), null);
    defer m.deinit();
    try m.useHostReplies(host_replies);

    var twin: Term = undefined;
    try twin.init(initial);
    defer twin.deinit();
    twin.terminal.flags.shell_redraws_prompt = m.terminal.flags.shell_redraws_prompt;

    var host: Term = undefined;
    try host.init(initial);
    defer host.deinit();
    host.stream.nextSlice("\x1b[?1049h\x1b[2J");

    for (records, 0..) |record, i| {
        switch (record) {
            .output => |data| {
                m.feed(data);
                twin.stream.nextSlice(data);
            },
            .size => |s| {
                try host.resize(s);
                try twin.resize(s);
                try m.resize(winsize(s));
            },
        }
        // Granite doesn't draw while the program holds rendering.
        if (m.held) continue;
        if (try frame(&m, &twin, &host)) |diff| return try report(label, records, i, diff);
    }

    // The hold times out eventually, and granite draws what it has.
    if (try frame(&m, &twin, &host)) |diff| return try report(label, records, records.len, diff);
    return null;
}

/// Render a frame, show it on the host, and compare. Returns the
/// differences, if any.
fn frame(m: *mux.Mux, twin: *Term, host: *Term) !?[]u8 {
    try mux.render(m);
    host.stream.nextSlice(m.out.written());
    m.out.clearRetainingCapacity();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const want = try screen.take(arena.allocator(), &twin.terminal);
    const got = try screen.take(arena.allocator(), &host.terminal);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    if (try screen.diff(&out.writer, want, got, 12) == 0) {
        out.deinit();
        return null;
    }
    try out.writer.writeAll("  program screen:\n");
    try want.dump(&out.writer);
    try out.writer.writeAll("  host screen:\n");
    try got.dump(&out.writer);
    return try out.toOwnedSlice();
}

fn report(label: []const u8, records: []const Record, index: usize, diff: []u8) ![]u8 {
    defer gpa.free(diff);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    if (index < records.len) {
        try w.print("{s}: after record {d} of {d}: ", .{ label, index + 1, records.len });
        switch (records[index]) {
            .output => |data| try writeEscaped(w, data[0..@min(data.len, 160)]),
            .size => |s| try w.print("size {d}x{d}", .{ s.cols, s.rows }),
        }
    } else {
        try w.print("{s}: after the final frame", .{label});
    }
    try w.print("\n{s}", .{diff});
    return try out.toOwnedSlice();
}

fn writeEscaped(w: *std.Io.Writer, data: []const u8) !void {
    try w.writeByte('"');
    for (data) |b| switch (b) {
        0x1b => try w.writeAll("\\e"),
        '\r' => try w.writeAll("\\r"),
        '\n' => try w.writeAll("\\n"),
        '"', '\\' => try w.print("\\{c}", .{b}),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(b),
        else => try w.print("\\x{x:0>2}", .{b}),
    };
    try w.writeByte('"');
}

/// Cut the output between size changes into pieces of random length,
/// ignoring the original boundaries.
fn split(arena: std.mem.Allocator, records: []const Record, seed: u64) ![]Record {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();
    var result: std.ArrayList(Record) = .empty;
    var pending: std.ArrayList(u8) = .empty;
    for (records, 0..) |record, i| {
        switch (record) {
            .output => |data| try pending.appendSlice(arena, data),
            .size => try result.append(arena, record),
        }
        const last = i + 1 == records.len or records[i + 1] == .size;
        if (record == .output and last) {
            const maxes = [_]usize{ 1, 2, 7, 32, 256 };
            const max = maxes[rand.uintLessThan(usize, maxes.len)];
            var rest = try pending.toOwnedSlice(arena);
            while (rest.len > 0) {
                const n = @min(rest.len, rand.intRangeAtMost(usize, 1, max));
                try result.append(arena, .{ .output = rest[0..n] });
                rest = rest[n..];
            }
        }
    }
    return result.toOwnedSlice(arena);
}

/// Run an input with its own boundaries and with `splits` random splits.
/// Returns the first report.
fn roundTripSplits(name: []const u8, initial: recording.Size, records: []const Record, splits: u64) !?[]u8 {
    if (try roundTrip(name, initial, records)) |r| return r;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (1..splits + 1) |seed| {
        const label = try std.fmt.allocPrint(arena.allocator(), "{s} (split seed {d})", .{ name, seed });
        const pieces = try split(arena.allocator(), records, seed);
        if (try roundTrip(label, initial, pieces)) |r| return r;
    }
    return null;
}

test "fixtures" {
    std.testing.log_level = .err;
    var failures: usize = 0;
    for (fixtures.all) |f| {
        const initial: recording.Size = .{ .cols = f.cols, .rows = f.rows };
        const result = try roundTripSplits(f.name, initial, f.records, splits_per_fixture);
        defer if (result) |r| gpa.free(r);
        if (f.known) |why| {
            if (result == null) {
                std.debug.print("{s}: matches, but is marked as a known gap ({s})\n", .{ f.name, why });
                failures += 1;
            }
        } else if (result) |r| {
            std.debug.print("{s}\n", .{r});
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}

test "fuzz" {
    std.testing.log_level = .err;
    for (0..options.fuzz_iterations) |i| {
        const seed = options.fuzz_seed +% i;
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();
        const initial: recording.Size = .{
            .cols = rand.intRangeAtMost(u16, 4, 60),
            .rows = rand.intRangeAtMost(u16, 2, 20),
        };
        const records = try fuzz.generate(gpa, rand);
        defer fuzz.free(gpa, records);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fuzz seed {d}", .{seed});
        if (try roundTripSplits(name, initial, records, splits_per_fuzz_case)) |r| {
            defer gpa.free(r);
            std.debug.print("{s}\n", .{r});
            return error.TestUnexpectedResult;
        }
    }
}

test "recordings" {
    std.testing.log_level = .err;
    var dir = std.Io.Dir.cwd().openDir(io, options.recordings_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rec")) continue;
        const data = try dir.readFileAlloc(io, entry.name, gpa, .unlimited);
        defer gpa.free(data);

        var records: std.ArrayList(Record) = .empty;
        defer records.deinit(gpa);
        var reader = try recording.Reader.init(data);
        while (try reader.next()) |r| try records.append(gpa, r);
        if (records.items.len == 0 or records.items[0] != .size or
            records.items[0].size.cols == 0 or records.items[0].size.rows == 0)
        {
            std.debug.print("{s}: doesn't start with a usable size\n", .{entry.name});
            failures += 1;
            continue;
        }

        const initial = records.items[0].size;
        if (try roundTripSplits(entry.name, initial, records.items[1..], splits_per_recording)) |r| {
            defer gpa.free(r);
            std.debug.print("{s}\n", .{r});
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}
