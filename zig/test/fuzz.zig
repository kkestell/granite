//! Random program output: text in several scripts and widths, control
//! characters, and the escape sequences a full-screen program uses, with
//! valid-looking parameters.

const std = @import("std");
const Record = @import("recording").Record;

const Random = std.Random;

/// Generate a stream of output chunks with an occasional size change.
/// Grapheme clustering is set once at the start, as programs do: the
/// host can't lay out a row printed partly in each mode.
pub fn generate(gpa: std.mem.Allocator, rand: Random) ![]Record {
    var records: std.ArrayList(Record) = .empty;
    errdefer {
        for (records.items) |r| if (r == .output) gpa.free(r.output);
        records.deinit(gpa);
    }

    const clustering = if (rand.boolean()) "\x1b[?2027h" else "\x1b[?2027l";
    try records.append(gpa, .{ .output = try gpa.dupe(u8, clustering) });

    const chunks = rand.intRangeAtMost(usize, 1, 40);
    for (0..chunks) |_| {
        if (rand.uintLessThan(u8, 30) == 0) {
            try records.append(gpa, .{ .size = .{
                .cols = rand.intRangeAtMost(u16, 4, 60),
                .rows = rand.intRangeAtMost(u16, 2, 20),
            } });
            continue;
        }
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const tokens = rand.intRangeAtMost(usize, 1, 24);
        for (0..tokens) |_| try token(&out.writer, rand);
        try records.append(gpa, .{ .output = try out.toOwnedSlice() });
    }
    return records.toOwnedSlice(gpa);
}

pub fn free(gpa: std.mem.Allocator, records: []Record) void {
    for (records) |r| if (r == .output) gpa.free(r.output);
    gpa.free(records);
}

const texts = [_][]const u8{
    "a",                                    "hello",             "The quick brown fox",
    " ",                                    "    ",              "\xe4\xb8\xad",
    "\xe6\x96\x87\xe5\xad\x97",             "\xf0\x9f\x98\x80",  "\xe2\x9d\xa4\xef\xb8\x8f",
    "e\xcc\x81",                            "a\xcc\x88\xcc\xa3", "\xcc\x81",
    "\xe2\x94\x80\xe2\x94\x82\xe2\x94\x8c", "\xef\xbd\x81",      "\xd7\xa9\xd7\x9c\xd7\x95\xd7\x9d",
};

const modes = [_]u16{
    1,    4,    6,    7,    9,    12,   25,   47,   66,   67,   1000, 1002, 1003,
    1004, 1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1047, 1048, 1049, 2004,
    2026,
};

fn token(w: *std.Io.Writer, rand: Random) !void {
    switch (rand.uintLessThan(u8, 24)) {
        0...5 => try w.writeAll(texts[rand.uintLessThan(usize, texts.len)]),
        6 => {
            // A run of printable ASCII.
            const n = rand.intRangeAtMost(usize, 1, 80);
            for (0..n) |_| try w.writeByte(rand.intRangeAtMost(u8, 0x20, 0x7e));
        },
        7 => try w.writeAll(switch (rand.uintLessThan(u8, 6)) {
            0 => "\r\n",
            1 => "\n",
            2 => "\r",
            3 => "\x08",
            4 => "\t",
            else => "\x07",
        }),
        8 => try w.print("\x1b[{d};{d}H", .{ rand.intRangeAtMost(u8, 0, 30), rand.intRangeAtMost(u8, 0, 70) }),
        9 => try w.print("\x1b[{d}{c}", .{
            rand.intRangeAtMost(u8, 0, 12),
            "ABCDEFGd`"[rand.uintLessThan(usize, 9)],
        }),
        10 => try w.print("\x1b[{d}{c}", .{ rand.intRangeAtMost(u8, 0, 3), "JK"[rand.uintLessThan(usize, 2)] }),
        11 => try w.print("\x1b[{d}{c}", .{
            rand.intRangeAtMost(u8, 0, 8),
            "@PXLMSTb"[rand.uintLessThan(usize, 8)],
        }),
        12 => if (rand.boolean())
            try w.writeAll("\x1b[r")
        else
            try w.print("\x1b[{d};{d}r", .{ rand.intRangeAtMost(u8, 1, 10), rand.intRangeAtMost(u8, 2, 24) }),
        13...15 => try sgr(w, rand),
        16, 17 => {
            const mode = modes[rand.uintLessThan(usize, modes.len)];
            try w.print("\x1b[?{d}{c}", .{ mode, "hl"[rand.uintLessThan(usize, 2)] });
        },
        18 => try w.print("\x1b[{d} q", .{rand.intRangeAtMost(u8, 0, 6)}),
        19 => try w.writeAll(switch (rand.uintLessThan(u8, 8)) {
            0 => "\x1b7",
            1 => "\x1b8",
            2 => "\x1bM",
            3 => "\x1bD",
            4 => "\x1bE",
            5 => "\x1bH",
            6 => "\x1b=",
            else => "\x1b>",
        }),
        20 => switch (rand.uintLessThan(u8, 4)) {
            0 => try w.print("\x1b[>{d}u", .{rand.intRangeAtMost(u8, 0, 31)}),
            1 => try w.print("\x1b[<{d}u", .{rand.intRangeAtMost(u8, 0, 3)}),
            2 => try w.print("\x1b[={d};{d}u", .{ rand.intRangeAtMost(u8, 0, 31), rand.intRangeAtMost(u8, 1, 3) }),
            else => try w.print("\x1b[{d}g", .{@as(u8, if (rand.boolean()) 0 else 3)}),
        },
        21 => try w.print("\x1b]{d};title {d}\x07", .{ @as(u8, if (rand.boolean()) 0 else 2), rand.int(u8) }),
        22 => try w.writeAll(if (rand.uintLessThan(u8, 8) == 0) "\x1bc" else "\x1b[4h\x1b[4l"),
        else => try w.writeAll(if (rand.boolean()) "\x1b#8" else "\x1b[!p"),
    }
}

fn sgr(w: *std.Io.Writer, rand: Random) !void {
    try w.writeAll("\x1b[");
    const n = rand.intRangeAtMost(usize, 1, 4);
    for (0..n) |i| {
        if (i > 0) try w.writeByte(';');
        switch (rand.uintLessThan(u8, 12)) {
            0 => try w.writeAll("0"),
            1 => try w.print("{d}", .{rand.intRangeAtMost(u8, 1, 9)}),
            2 => try w.print("{d}", .{rand.intRangeAtMost(u8, 21, 29)}),
            3 => try w.print("{d}", .{rand.intRangeAtMost(u8, 30, 49)}),
            4 => try w.print("{d}", .{rand.intRangeAtMost(u8, 90, 107)}),
            5 => try w.print("{d}8:5:{d}", .{ "345"[rand.uintLessThan(usize, 3)] - '0', rand.int(u8) }),
            6 => try w.print("{d}8;5;{d}", .{ "345"[rand.uintLessThan(usize, 3)] - '0', rand.int(u8) }),
            7 => try w.print("{d}8;2;{d};{d};{d}", .{ "345"[rand.uintLessThan(usize, 3)] - '0', rand.int(u8), rand.int(u8), rand.int(u8) }),
            8 => try w.print("4:{d}", .{rand.intRangeAtMost(u8, 0, 5)}),
            9 => try w.print("{d}", .{@as(u8, if (rand.boolean()) 53 else 55)}),
            10 => try w.writeAll(if (rand.boolean()) "39;49" else "59"),
            else => try w.print("58:2::{d}:{d}:{d}", .{ rand.int(u8), rand.int(u8), rand.int(u8) }),
        }
    }
    try w.writeByte('m');
}
