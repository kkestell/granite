//! Snapshots of what a terminal shows, and a cell-level comparison of two
//! snapshots. Colors are resolved to RGB against each terminal's own
//! palette and default colors, so a palette index and the RGB value it
//! stands for compare equal.

const std = @import("std");
const vt = @import("ghostty-vt");

const RGB = vt.color.RGB;

/// Modes compared between the two terminals: everything that changes how
/// the host encodes input, plus the modes that change what it shows.
pub const compared_modes = [_]u16{
    1,    5,    9,    66,   67,   1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016,
    1035, 1036, 1039, 2004, 2027,
};

pub const Wide = enum { narrow, wide, tail };

pub const Cell = struct {
    /// The base codepoint and any grapheme extenders. Empty for a blank
    /// cell; a lone space counts as blank.
    text: []const u21,
    wide: Wide,
    fg: RGB,
    bg: RGB,
    underline_color: ?RGB,
    flags: Flags,

    pub const Flags = struct {
        bold: bool,
        italic: bool,
        faint: bool,
        blink: bool,
        inverse: bool,
        invisible: bool,
        strikethrough: bool,
        overline: bool,
        underline: vt.sgr.Attribute.Underline,
    };

    pub fn eql(a: Cell, b: Cell) bool {
        return std.mem.eql(u21, a.text, b.text) and a.wide == b.wide and
            a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            optEql(a.underline_color, b.underline_color) and
            std.meta.eql(a.flags, b.flags);
    }

    fn optEql(a: ?RGB, b: ?RGB) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.eql(b.?);
    }

    pub fn format(cell: Cell, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (cell.text) |cp| {
            if (cp >= 0x20 and cp < 0x7f) try w.writeByte(@intCast(cp)) else try w.print("\\u{{{x}}}", .{cp});
        }
        try w.print("\" {t} fg #{x:0>2}{x:0>2}{x:0>2} bg #{x:0>2}{x:0>2}{x:0>2}", .{
            cell.wide, cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b,
        });
        if (cell.underline_color) |u| try w.print(" ul #{x:0>2}{x:0>2}{x:0>2}", .{ u.r, u.g, u.b });
        const f = cell.flags;
        const names = [_][]const u8{ "bold", "italic", "faint", "blink", "inverse", "invisible", "strikethrough", "overline" };
        const set = [_]bool{ f.bold, f.italic, f.faint, f.blink, f.inverse, f.invisible, f.strikethrough, f.overline };
        for (names, set) |name, on| if (on) try w.print(" {s}", .{name});
        if (f.underline != .none) try w.print(" underline={t}", .{f.underline});
    }
};

pub const Cursor = struct {
    /// Null when the cursor is outside the viewport.
    pos: ?struct { x: u16, y: u16 },
    visible: bool,
    style: vt.CursorStyle,
    blinking: bool,
};

pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cells: []Cell,
    cursor: Cursor,
    modes: [compared_modes.len]bool,
    kitty_flags: u8,

    pub fn at(s: Snapshot, x: usize, y: usize) Cell {
        return s.cells[y * s.cols + x];
    }

    /// Write the screen text, one line per row between bars.
    pub fn dump(s: Snapshot, w: *std.Io.Writer) !void {
        for (0..s.rows) |y| {
            try w.writeAll("    |");
            for (0..s.cols) |x| {
                const cell = s.at(x, y);
                if (cell.wide == .tail) continue;
                if (cell.text.len == 0) try w.writeByte(' ');
                for (cell.text) |cp| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                    try w.writeAll(buf[0..n]);
                }
            }
            try w.writeAll("|\n");
        }
    }
};

/// Take a snapshot of what `t` shows. Reading it through a fresh render
/// state consumes the terminal's dirty flags, so this must not be used on a
/// terminal that something else renders incrementally.
pub fn take(arena: std.mem.Allocator, t: *vt.Terminal) !Snapshot {
    var state: vt.RenderState = .empty;
    try state.update(arena, t);
    const colors = state.colors;

    const cells = try arena.alloc(Cell, @as(usize, state.rows) * state.cols);
    const rows = state.row_data.slice();
    for (rows.items(.cells), 0..) |row_cells, y| {
        const row = row_cells.slice();
        for (row.items(.raw), row.items(.grapheme), row.items(.style), 0..) |raw, grapheme, style, x| {
            var s: vt.Style = if (raw.hasStyling()) style else .{};
            switch (raw.content_tag) {
                .bg_color_palette => s.bg_color = .{ .palette = raw.content.color_palette.data },
                .bg_color_rgb => {
                    const c = raw.content.color_rgb;
                    s.bg_color = .{ .rgb = .{ .r = c.r, .g = c.g, .b = c.b } };
                },
                .codepoint, .codepoint_grapheme => {},
            }

            var text: []const u21 = &.{};
            if (raw.hasText() and !(raw.codepoint() == ' ' and !raw.hasGrapheme())) {
                const extra = if (raw.hasGrapheme()) grapheme else &.{};
                const t_buf = try arena.alloc(u21, 1 + extra.len);
                t_buf[0] = raw.codepoint();
                @memcpy(t_buf[1..], extra);
                text = t_buf;
            }

            cells[y * state.cols + x] = .{
                .text = text,
                .wide = switch (raw.wide) {
                    .wide => .wide,
                    .spacer_tail => .tail,
                    .narrow, .spacer_head => .narrow,
                },
                .fg = resolve(s.fg_color, colors) orelse colors.foreground,
                .bg = resolve(s.bg_color, colors) orelse colors.background,
                .underline_color = resolve(s.underline_color, colors),
                .flags = .{
                    .bold = s.flags.bold,
                    .italic = s.flags.italic,
                    .faint = s.flags.faint,
                    .blink = s.flags.blink,
                    .inverse = s.flags.inverse,
                    .invisible = s.flags.invisible,
                    .strikethrough = s.flags.strikethrough,
                    .overline = s.flags.overline,
                    .underline = s.flags.underline,
                },
            };
        }
    }

    var modes: [compared_modes.len]bool = undefined;
    inline for (compared_modes, &modes) |value, *v| {
        v.* = t.modes.get(comptime vt.modes.modeFromInt(value, false).?);
    }

    const cursor = state.cursor;
    return .{
        .cols = state.cols,
        .rows = state.rows,
        .cells = cells,
        .cursor = .{
            .pos = if (cursor.viewport) |p| .{ .x = p.x, .y = p.y } else null,
            .visible = cursor.visible,
            .style = cursor.visual_style,
            .blinking = cursor.blinking,
        },
        .modes = modes,
        .kitty_flags = t.screens.active.kitty_keyboard.current().int(),
    };
}

fn resolve(color: vt.Style.Color, colors: vt.RenderState.Colors) ?RGB {
    return switch (color) {
        .none => null,
        .palette => |i| colors.palette[i],
        .rgb => |rgb| rgb,
    };
}

/// Write every difference between `a` and `b`, up to `max_cells` cells.
/// Returns the number of differences found.
pub fn diff(w: *std.Io.Writer, a: Snapshot, b: Snapshot, max_cells: usize) !usize {
    var count: usize = 0;
    if (a.cols != b.cols or a.rows != b.rows) {
        try w.print("  size: granite {d}x{d}, host {d}x{d}\n", .{ a.cols, a.rows, b.cols, b.rows });
        return 1;
    }

    if (!std.meta.eql(a.cursor, b.cursor)) {
        count += 1;
        try w.writeAll("  cursor: granite ");
        try writeCursor(w, a.cursor);
        try w.writeAll(", host ");
        try writeCursor(w, b.cursor);
        try w.writeByte('\n');
    }

    for (compared_modes, a.modes, b.modes) |value, am, bm| {
        if (am == bm) continue;
        count += 1;
        try w.print("  mode {d}: granite {s}, host {s}\n", .{ value, onOff(am), onOff(bm) });
    }
    if (a.kitty_flags != b.kitty_flags) {
        count += 1;
        try w.print("  kitty keyboard flags: granite {d}, host {d}\n", .{ a.kitty_flags, b.kitty_flags });
    }

    var shown: usize = 0;
    for (0..a.rows) |y| for (0..a.cols) |x| {
        const ac = a.at(x, y);
        const bc = b.at(x, y);
        if (ac.eql(bc)) continue;
        count += 1;
        shown += 1;
        if (shown <= max_cells) {
            try w.print("  row {d} col {d}:\n    granite {f}\n    host    {f}\n", .{ y, x, ac, bc });
        }
    };
    if (shown > max_cells) try w.print("  ... and {d} more cells\n", .{shown - max_cells});
    return count;
}

fn writeCursor(w: *std.Io.Writer, c: Cursor) !void {
    if (c.pos) |p| try w.print("row {d} col {d}", .{ p.y, p.x }) else try w.writeAll("offscreen");
    try w.print(" {s} {t}{s}", .{
        if (c.visible) "visible" else "hidden",
        c.style,
        if (c.blinking) " blinking" else "",
    });
}

fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}
