//! The terminal side of granite: a Ghostty terminal fed with the program's
//! output, and the renderer that redraws the host terminal from it. The
//! pty and the host terminal stay in main.zig, so this can run without
//! either.

const std = @import("std");
const vt = @import("ghostty-vt");

const c = std.c;
const posix = std.posix;
const Handler = vt.TerminalStream.Handler;

/// Modes mirrored onto the host terminal: the ones that change how the
/// host must encode input, and the ones that change how it draws what
/// granite sends.
pub const mirrored_modes = [_]u16{
    1, // DECCKM: application cursor keys
    5, // DECSCNM: reverse video
    9, // X10 mouse reporting
    66, // DECNKM: application keypad
    67, // DECBKM: backspace sends BS
    1000, // normal mouse tracking
    1002, // button-event mouse tracking
    1003, // any-event mouse tracking
    1004, // focus in/out events
    1005, // UTF-8 mouse format
    1006, // SGR mouse format
    1007, // alternate scroll
    1015, // urxvt mouse format
    1016, // SGR pixel mouse format
    1035, // ignore keypad with Num Lock
    1036, // Alt sends ESC
    1039, // Alt sends ESC (alternate)
    2004, // bracketed paste
    2027, // grapheme clustering
};

pub const Mux = struct {
    gpa: std.mem.Allocator,
    /// Where the terminal writes its replies. Replies are dropped when null.
    pty: ?posix.fd_t,
    ws: posix.winsize,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render_state: vt.RenderState = .empty,
    /// Output for the host terminal, written by `render` and the effects.
    out: std.Io.Writer.Allocating,
    held: bool = false,
    held_since: i64 = 0,
    /// The host screen was cleared, so the next frame redraws every row.
    redraw: bool = true,
    /// The mirrored modes as last sent to the host, which starts out with
    /// the defaults.
    host_modes: [mirrored_modes.len]bool = @splat(false),
    host_kitty_flags: u8 = 0,

    /// Initialize in place: the terminal effects find the Mux from the
    /// handler's address, so it must not move afterwards.
    pub fn init(m: *Mux, io: std.Io, gpa: std.mem.Allocator, ws: posix.winsize, pty: ?posix.fd_t) !void {
        m.* = .{
            .gpa = gpa,
            .pty = pty,
            .ws = ws,
            .terminal = try .init(io, gpa, .{ .cols = ws.col, .rows = ws.row }),
            .stream = undefined,
            .out = .init(gpa),
        };

        // Prompts can't be assumed to redraw on resize without Ghostty's
        // shell integration. Shells can still opt in with OSC 133;A;redraw=1.
        m.terminal.flags.shell_redraws_prompt = .false;

        var handler = m.terminal.vtHandler();
        handler.effects.write_pty = &writePty;
        handler.effects.bell = &bell;
        handler.effects.title_changed = &titleChanged;
        handler.effects.device_attributes = &deviceAttributes;
        handler.effects.size = &size;
        handler.effects.render_hold = &renderHold;
        m.stream = .init(.{ .allocator = gpa, .handler = handler });
        m.resetHostModes();
    }

    /// Take the host's replies to `host_queries`; see `useHostRepliesFor`.
    pub fn useHostReplies(m: *Mux, replies: []const u8) !void {
        try useHostRepliesFor(&m.terminal, m.gpa, replies);
        m.resetHostModes();
    }

    fn resetHostModes(m: *Mux) void {
        inline for (mirrored_modes, &m.host_modes) |value, *host| {
            host.* = m.terminal.modes.getDefault(comptime vt.modes.modeFromInt(value, false).?);
        }
    }

    pub fn deinit(m: *Mux) void {
        m.stream.deinit();
        m.render_state.deinit(m.gpa);
        m.terminal.deinit(m.gpa);
        m.out.deinit();
    }

    /// Feed output from the program.
    pub fn feed(m: *Mux, data: []const u8) void {
        // A zero-width character that starts this output attaches to a
        // cell on the cursor row without marking the row dirty.
        m.terminal.screens.active.cursorMarkDirty();
        m.stream.nextSlice(data);
    }

    pub fn resize(m: *Mux, ws: posix.winsize) !void {
        m.ws = ws;
        try m.stream.handler.resize(.{
            .cols = ws.col,
            .rows = ws.row,
            .cell_size_px = .{
                .width = if (ws.col > 0) ws.xpixel / ws.col else 0,
                .height = if (ws.row > 0) ws.ypixel / ws.row else 0,
            },
        });
        try m.out.writer.writeAll("\x1b[2J");
        m.redraw = true;
    }

    fn fromHandler(handler: *Handler) *Mux {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }
};

pub fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn writeAll(fd: posix.fd_t, data: []const u8) void {
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

//------------------------------------------------------------------------
// Terminal effects

fn writePty(handler: *Handler, data: []const u8) void {
    if (Mux.fromHandler(handler).pty) |pty| writeAll(pty, data);
}

fn bell(handler: *Handler) void {
    Mux.fromHandler(handler).out.writer.writeByte(0x07) catch {};
}

fn titleChanged(handler: *Handler) void {
    const title = handler.terminal.getTitle() orelse "";
    Mux.fromHandler(handler).out.writer.print("\x1b]0;{s}\x07", .{title}) catch {};
}

/// Reports a VT220 with ANSI color.
fn deviceAttributes(_: *Handler) vt.device_attributes.Attributes {
    return .{};
}

fn size(handler: *Handler) ?vt.size_report.Size {
    const ws = Mux.fromHandler(handler).ws;
    return .{
        .rows = ws.row,
        .columns = ws.col,
        .cell_width = if (ws.col > 0) ws.xpixel / ws.col else 0,
        .cell_height = if (ws.row > 0) ws.ypixel / ws.row else 0,
    };
}

fn renderHold(handler: *Handler, held: bool) void {
    const m = Mux.fromHandler(handler);
    m.held = held;
    if (held) m.held_since = nowMs();
}

//------------------------------------------------------------------------
// Rendering

/// The style a cell is drawn with. Cells cleared with a background color
/// carry it in the cell content rather than the style.
pub fn cellStyle(raw: vt.Cell, style: vt.Style) vt.Style {
    var s: vt.Style = if (raw.hasStyling()) style else .{};
    switch (raw.content_tag) {
        .bg_color_palette => s.bg_color = .{ .palette = raw.content.color_palette.data },
        .bg_color_rgb => {
            const rgb = raw.content.color_rgb;
            s.bg_color = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } };
        },
        .codepoint, .codepoint_grapheme => {},
    }
    return s;
}

fn writeColor(w: *std.Io.Writer, base: u8, color: vt.Style.Color) !void {
    switch (color) {
        .none => {},
        .palette => |i| try w.print(";{d};5;{d}", .{ base, i }),
        .rgb => |rgb| try w.print(";{d};2;{d};{d};{d}", .{ base, rgb.r, rgb.g, rgb.b }),
    }
}

/// Write the SGR sequence that fully describes a style.
fn writeSgr(w: *std.Io.Writer, s: vt.Style) !void {
    try w.writeAll("\x1b[0");
    if (s.flags.bold) try w.writeAll(";1");
    if (s.flags.faint) try w.writeAll(";2");
    if (s.flags.italic) try w.writeAll(";3");
    switch (s.flags.underline) {
        .none => {},
        .single => try w.writeAll(";4"),
        else => |u| try w.print(";4:{d}", .{@backingInt(u)}),
    }
    if (s.flags.blink) try w.writeAll(";5");
    if (s.flags.inverse) try w.writeAll(";7");
    if (s.flags.invisible) try w.writeAll(";8");
    if (s.flags.strikethrough) try w.writeAll(";9");
    if (s.flags.overline) try w.writeAll(";53");
    try writeColor(w, 38, s.fg_color);
    try writeColor(w, 48, s.bg_color);
    try writeColor(w, 58, s.underline_color);
    try w.writeByte('m');
}

fn writeCodepoint(w: *std.Io.Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return w.writeAll("\u{FFFD}");
    try w.writeAll(buf[0..len]);
}

fn renderRow(w: *std.Io.Writer, cells: std.MultiArrayList(vt.RenderState.Cell).Slice, y: usize) !void {
    try w.print("\x1b[{d};1H", .{y + 1});

    var prev: ?vt.Style = null;
    for (cells.items(.raw), cells.items(.grapheme), cells.items(.style), 0..) |raw, grapheme, style, x| {
        if (raw.wide == .spacer_tail) continue;

        const s = cellStyle(raw, style);
        if (prev == null or !prev.?.eql(s)) {
            try writeSgr(w, s);
            prev = s;
        }

        if (raw.hasText()) {
            try writeCodepoint(w, raw.codepoint());
            if (raw.hasGrapheme()) for (grapheme) |cp| try writeCodepoint(w, cp);
        } else {
            try w.writeByte(' ');
        }

        // Re-sync the column after a wide character in case the host
        // terminal disagrees about its width.
        if (raw.wide == .wide) try w.print("\x1b[{d}G", .{x + 3});
    }
    try w.writeAll("\x1b[0m");
}

fn syncModes(m: *Mux) !void {
    const w = &m.out.writer;
    inline for (mirrored_modes, &m.host_modes) |value, *host| {
        const mode = comptime vt.modes.modeFromInt(value, false).?;
        const set = m.terminal.modes.get(mode);
        if (set != host.*) {
            try w.print("\x1b[?{d}{c}", .{ value, @as(u8, if (set) 'h' else 'l') });
            host.* = set;
        }
    }

    const flags: u8 = m.terminal.screens.active.kitty_keyboard.current().int();
    if (flags != m.host_kitty_flags) {
        try w.print("\x1b[={d};1u", .{flags});
        m.host_kitty_flags = flags;
    }
}

/// Draw the rows that changed since the last frame, the cursor, and the
/// input modes into `m.out`.
pub fn render(m: *Mux) !void {
    const state = &m.render_state;
    try state.update(m.gpa, &m.terminal);
    if (m.redraw) state.dirty = .full;
    m.redraw = false;
    const w = &m.out.writer;

    // Synchronized output keeps the host from showing a half-drawn frame.
    try w.writeAll("\x1b[?2026h\x1b[?25l");

    // Modes first, since grapheme clustering changes how the host lays
    // out the rows.
    try syncModes(m);

    if (state.dirty != .false) {
        const rows = state.row_data.slice();
        for (rows.items(.cells), rows.items(.dirty), 0..) |cells, dirty, y| {
            if (state.dirty == .full or dirty) try renderRow(w, cells.slice(), y);
        }
    }

    const cursor = state.cursor;
    if (cursor.viewport) |pos| try w.print("\x1b[{d};{d}H", .{ pos.y + 1, pos.x + 1 });
    var shape: u8 = switch (cursor.visual_style) {
        .bar => 6,
        .underline => 4,
        else => 2, // steady block
    };
    if (cursor.blinking) shape -= 1;
    try w.print("\x1b[{d} q", .{shape});
    if (cursor.visible and cursor.viewport != null) try w.writeAll("\x1b[?25h");

    try w.writeAll("\x1b[?2026l");

    state.clean();
}

/// Write what turns the host terminal back to how granite found it.
pub fn writeRestore(m: *Mux) void {
    const w = &m.out.writer;
    inline for (mirrored_modes, m.host_modes) |value, set| {
        const default = m.terminal.modes.getDefault(comptime vt.modes.modeFromInt(value, false).?);
        if (set != default) w.print("\x1b[?{d}{c}", .{ value, @as(u8, if (default) 'h' else 'l') }) catch {};
    }
    if (m.host_kitty_flags != 0) w.writeAll("\x1b[=0;1u") catch {};
    w.writeAll("\x1b[0 q\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
}

//------------------------------------------------------------------------
// Host state

/// Queries for the host's default colors, its 16 ANSI palette colors, and
/// whether it clusters graphemes (mode 2027), followed by DA1. Every
/// terminal answers DA1, so its reply marks the end of the host's replies.
/// The replies stay small enough to fit in the tty input buffer while the
/// queries are still being written.
pub const host_queries = blk: {
    var q: []const u8 = "\x1b]10;?\x1b\\\x1b]11;?\x1b\\";
    for (0..16) |i| q = q ++ std.fmt.comptimePrint("\x1b]4;{d};?\x1b\\", .{i});
    break :blk q ++ "\x1b[?2027$p\x1b[c";
};

/// True once `replies` holds the host's DA1 reply.
pub fn hostRepliesDone(replies: []const u8) bool {
    var it = std.mem.splitSequence(u8, replies, "\x1b[?");
    _ = it.next();
    while (it.next()) |reply| {
        const end = std.mem.indexOfNone(u8, reply, "0123456789;") orelse continue;
        if (reply[end] == 'c') return true;
    }
    return false;
}

/// Take the host's replies to `host_queries` as the terminal's colors, so
/// it answers the program's OSC 10, 11, and 4 queries the way the host
/// would, and as its default for grapheme clustering, so the host lays out
/// rows the way the terminal does.
pub fn useHostRepliesFor(t: *vt.Terminal, gpa: std.mem.Allocator, replies: []const u8) !void {
    if (std.mem.indexOf(u8, replies, "\x1b[?2027;")) |i| {
        const rest = replies[i + "\x1b[?2027;".len ..];
        if (rest.len > 0 and (rest[0] == '1' or rest[0] == '3')) t.modes.setDefault(.grapheme_cluster, true);
    }

    var palette = vt.color.default;
    var have_palette = false;
    var it = std.mem.splitSequence(u8, replies, "\x1b]");
    _ = it.next();
    while (it.next()) |reply| {
        const end = std.mem.indexOfAny(u8, reply, "\x1b\x07") orelse continue;
        var fields = std.mem.splitScalar(u8, reply[0..end], ';');
        const code = std.fmt.parseInt(u8, fields.first(), 10) catch continue;
        switch (code) {
            4 => {
                const i = std.fmt.parseInt(u8, fields.next() orelse continue, 10) catch continue;
                palette[i] = vt.color.RGB.parse(fields.rest()) catch continue;
                have_palette = true;
            },
            10, 11 => {
                const rgb = vt.color.RGB.parse(fields.rest()) catch continue;
                const colors = &t.colors;
                if (code == 10) colors.foreground = .init(rgb) else colors.background = .init(rgb);
            },
            else => {},
        }
    }
    if (have_palette) try t.colors.palette.changeDefault(gpa, palette);
}
