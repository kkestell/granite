//! The recording format written by granite-record and replayed by the
//! round-trip tests: a magic line, then records. An output record holds
//! one read() of the program's output. A size record holds the terminal
//! size from that point on; the first record is always a size record.
//!
//!   output: 'o', length (u32 little-endian), bytes
//!   size:   's', cols (u16 little-endian), rows (u16 little-endian)

const std = @import("std");

pub const magic = "granite-recording 1\n";

pub const Size = struct { cols: u16, rows: u16 };

pub const Record = union(enum) {
    output: []const u8,
    size: Size,
};

pub fn write(w: *std.Io.Writer, record: Record) !void {
    switch (record) {
        .output => |data| {
            try w.writeByte('o');
            try w.writeInt(u32, @intCast(data.len), .little);
            try w.writeAll(data);
        },
        .size => |s| {
            try w.writeByte('s');
            try w.writeInt(u16, s.cols, .little);
            try w.writeInt(u16, s.rows, .little);
        },
    }
}

pub const Reader = struct {
    rest: []const u8,

    pub fn init(data: []const u8) !Reader {
        if (!std.mem.startsWith(u8, data, magic)) return error.NotARecording;
        return .{ .rest = data[magic.len..] };
    }

    pub fn next(r: *Reader) !?Record {
        if (r.rest.len == 0) return null;
        switch (r.rest[0]) {
            'o' => {
                if (r.rest.len < 5) return error.Truncated;
                const len = std.mem.readInt(u32, r.rest[1..5], .little);
                if (r.rest.len - 5 < len) return error.Truncated;
                const data = r.rest[5..][0..len];
                r.rest = r.rest[5 + len ..];
                return .{ .output = data };
            },
            's' => {
                if (r.rest.len < 5) return error.Truncated;
                const s: Size = .{
                    .cols = std.mem.readInt(u16, r.rest[1..3], .little),
                    .rows = std.mem.readInt(u16, r.rest[3..5], .little),
                };
                r.rest = r.rest[5..];
                return .{ .size = s };
            },
            else => return error.BadRecord,
        }
    }
};
