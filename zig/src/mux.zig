//! Per-pane Ghostty terminals, host input routing, and rendering for one
//! program, two side-by-side programs, or a left program beside two
//! stacked programs. Terminals can run without ptys
//! for round-trip tests.

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

/// Per-program state. Initialize in place: effects recover this Pane from
/// the stream handler's address, and the pane must not move afterwards.
pub const Pane = struct {
    host: *Mux,
    pty: ?posix.fd_t = null,
    pid: ?c.pid_t = null,
    status: ?u8 = null,
    label: []const u8,
    ws: posix.winsize,
    row: u16,
    col: u16,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render_state: vt.RenderState = .empty,
    held: bool = false,
    held_since: i64 = 0,
    redraw: bool = true,
    dirty: bool = true,

    fn init(p: *Pane, m: *Mux, io: std.Io, label: []const u8, index: usize) !void {
        const layout = m.layout(index);
        p.* = .{
            .host = m,
            .label = label,
            .ws = layout.ws,
            .row = layout.row,
            .col = layout.col,
            .terminal = try .init(io, m.gpa, .{ .cols = layout.ws.col, .rows = layout.ws.row }),
            .stream = undefined,
        };
        // Prompts can't be assumed to redraw without shell integration.
        p.terminal.flags.shell_redraws_prompt = .false;
        var handler = p.terminal.vtHandler();
        handler.effects.write_pty = &writePty;
        handler.effects.bell = &bell;
        handler.effects.title_changed = &titleChanged;
        handler.effects.device_attributes = &deviceAttributes;
        handler.effects.size = &size;
        handler.effects.render_hold = &renderHold;
        p.stream = .init(.{ .allocator = m.gpa, .handler = handler });
    }

    fn deinit(p: *Pane) void {
        p.stream.deinit();
        p.render_state.deinit(p.host.gpa);
        p.terminal.deinit(p.host.gpa);
    }

    pub fn feed(p: *Pane, data: []const u8) void {
        // A leading zero-width character can attach without dirtying a row.
        p.terminal.screens.active.cursorMarkDirty();
        p.stream.nextSlice(data);
        p.dirty = true;
    }

    fn fromHandler(handler: *Handler) *Pane {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }

    fn send(p: *Pane, data: []const u8) void {
        if (p.pty) |pty| writeAll(pty, data);
    }
};

pub const Mux = struct {
    gpa: std.mem.Allocator,
    ws: posix.winsize,
    panes: [3]Pane = undefined,
    count: usize,
    focus: usize = 0,
    out: std.Io.Writer.Allocating,
    chrome_dirty: bool = true,
    host_modes: [mirrored_modes.len]bool = @splat(false),
    host_kitty_flags: u8 = 0,

    pub fn init(m: *Mux, io: std.Io, gpa: std.mem.Allocator, ws: posix.winsize, labels: []const []const u8) !void {
        std.debug.assert(labels.len >= 1 and labels.len <= 3);
        m.* = .{ .gpa = gpa, .ws = ws, .count = labels.len, .out = .init(gpa), .chrome_dirty = labels.len > 1 };
        errdefer m.out.deinit();
        var initialized: usize = 0;
        errdefer for (m.panes[0..initialized]) |*p| p.deinit();
        for (labels, 0..) |label, i| {
            try m.panes[i].init(m, io, label, i);
            initialized += 1;
        }
        m.resetHostModes();
    }

    fn layout(m: *Mux, index: usize) struct { ws: posix.winsize, row: u16, col: u16 } {
        if (m.count == 1) return .{ .ws = m.ws, .row = 0, .col = 0 };
        // Ghostty and the pty require at least one cell in each dimension.
        // Each pane has a header row above it.
        const width = @max(m.ws.col, 3);
        const left = (width - 1) / 2;
        const cols = if (index == 0) left else width - left - 1;
        var row: u16 = 1;
        var rows = @max(m.ws.row, 2) - 1;
        if (m.count == 3 and index > 0) {
            const height = @max(m.ws.row, 4);
            const top = (height - 1) / 2;
            rows = if (index == 1) top else height - top - 2;
            if (index == 2) row = top + 2;
        }
        return .{
            .ws = .{
                .col = cols,
                .row = rows,
                .xpixel = @intCast(@as(u32, m.ws.xpixel) * cols / @max(m.ws.col, 1)),
                .ypixel = @intCast(@as(u32, m.ws.ypixel) * rows / @max(m.ws.row, 1)),
            },
            .row = row,
            .col = if (index == 0) 0 else left + 1,
        };
    }

    pub fn useHostReplies(m: *Mux, replies: []const u8) !void {
        for (m.panes[0..m.count]) |*p| try useHostRepliesFor(&p.terminal, m.gpa, replies);
        m.resetHostModes();
    }

    fn resetHostModes(m: *Mux) void {
        inline for (mirrored_modes, &m.host_modes) |value, *host| {
            host.* = m.panes[0].terminal.modes.getDefault(comptime vt.modes.modeFromInt(value, false).?);
        }
    }

    pub fn deinit(m: *Mux) void {
        for (m.panes[0..m.count]) |*p| p.deinit();
        m.out.deinit();
    }

    pub fn resize(m: *Mux, ws: posix.winsize) !void {
        m.ws = ws;
        for (m.panes[0..m.count], 0..) |*p, i| {
            const l = m.layout(i);
            p.ws = l.ws;
            p.row = l.row;
            p.col = l.col;
            try p.stream.handler.resize(.{
                .cols = p.ws.col,
                .rows = p.ws.row,
                .cell_size_px = .{
                    .width = if (p.ws.col > 0) p.ws.xpixel / p.ws.col else 0,
                    .height = if (p.ws.row > 0) p.ws.ypixel / p.ws.row else 0,
                },
            });
            p.redraw = true;
            p.dirty = true;
        }
        try m.out.writer.writeAll("\x1b[2J");
        m.chrome_dirty = m.count > 1;
    }

    pub fn needsRender(m: *Mux) bool {
        if (m.chrome_dirty) return true;
        for (m.panes[0..m.count]) |*p| if (p.dirty and !p.held) return true;
        return false;
    }

    pub fn setFocus(m: *Mux, index: usize) void {
        if (index == m.focus or m.panes[index].status != null) return;
        const old = &m.panes[m.focus];
        const next = &m.panes[index];
        const focus_mode = comptime vt.modes.modeFromInt(1004, false).?;
        if (old.terminal.modes.get(focus_mode)) old.send("\x1b[O");
        m.focus = index;
        if (next.terminal.modes.get(focus_mode)) next.send("\x1b[I");
        m.chrome_dirty = true;
        m.writeTitle();
    }

    /// Focus the next live pane after the focused one, in pane order.
    pub fn focusNext(m: *Mux) void {
        for (1..m.count) |step| {
            const index = (m.focus + step) % m.count;
            if (m.panes[index].status == null) return m.setFocus(index);
        }
    }

    fn writeTitle(m: *Mux) void {
        const title = m.panes[m.focus].terminal.getTitle() orelse "";
        m.out.writer.print("\x1b]0;{s}\x07", .{title}) catch {};
    }

    /// Input is parsed only within this read; partial escape sequences are
    /// forwarded without waiting for another read.
    pub fn input(m: *Mux, data: []const u8) void {
        if (m.count == 1) return m.panes[0].send(data);
        var i: usize = 0;
        var start: usize = 0;
        while (i < data.len) {
            var end = i + 1;
            var swallow = false;
            var toggle = false;
            if (data[i] == 0x1d) {
                swallow = true;
                toggle = true;
            } else if (std.mem.startsWith(u8, data[i..], "\x1b[")) {
                var final = i + 2;
                while (final < data.len and !(data[final] >= 0x40 and data[final] <= 0x7e)) : (final += 1) {}
                if (final < data.len) {
                    end = final + 1;
                    const params = data[i + 2 .. final];
                    if (data[final] == 'u') {
                        if (focusKey(params)) |press| {
                            swallow = true;
                            toggle = press;
                        }
                    } else if ((std.mem.startsWith(u8, params, "<") and (data[final] == 'M' or data[final] == 'm')) or
                        (data[final] == 'M' and (params.len == 0 or std.mem.count(u8, params, ";") == 2)))
                    {
                        // All mouse protocols end in M/m. Only SGR cell
                        // coordinates can be translated into a pane.
                        m.panes[m.focus].send(data[start..i]);
                        start = end;
                        if (std.mem.startsWith(u8, params, "<")) m.mouse(params[1..], data[final]);
                        if (params.len == 0 and data[final] == 'M') {
                            // X10/1005 encodes three characters after CSI M.
                            for (0..3) |_| {
                                if (end == data.len) break;
                                const len = if (m.panes[m.focus].terminal.modes.get(.mouse_format_utf8))
                                    std.unicode.utf8ByteSequenceLength(data[end]) catch 1
                                else
                                    1;
                                end = @min(data.len, end + len);
                            }
                            start = end;
                        }
                        i = end;
                        continue;
                    }
                }
            }
            if (swallow) {
                m.panes[m.focus].send(data[start..i]);
                if (toggle) m.focusNext();
                start = end;
            }
            i = end;
        }
        m.panes[m.focus].send(data[start..]);
    }

    fn mouse(m: *Mux, params: []const u8, final: u8) void {
        var fields = std.mem.splitScalar(u8, params, ';');
        const button = std.fmt.parseInt(u16, fields.next() orelse return, 10) catch return;
        const x = std.fmt.parseInt(u16, fields.next() orelse return, 10) catch return;
        const y = std.fmt.parseInt(u16, fields.next() orelse return, 10) catch return;
        if (fields.next() != null) return;
        const p = &m.panes[m.focus];
        if (p.terminal.modes.get(.mouse_format_sgr_pixels)) return;
        if (x <= p.col or x > p.col + p.ws.col or y <= p.row or y > p.row + p.ws.row) return;
        var buf: [64]u8 = undefined;
        p.send(std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ button, x - p.col, y - p.row, final }) catch return);
    }
};

/// Kitty's key;modifiers:event;... form, including alternate key fields.
fn focusKey(params: []const u8) ?bool {
    var fields = std.mem.splitScalar(u8, params, ';');
    var keys = std.mem.splitScalar(u8, fields.next() orelse return null, ':');
    if ((std.fmt.parseInt(u32, keys.first(), 10) catch return null) != 93) return null;
    var modifiers = std.mem.splitScalar(u8, fields.next() orelse return null, ':');
    if ((std.fmt.parseInt(u16, modifiers.first(), 10) catch return null) != 5) return null;
    const event = if (modifiers.next()) |e| std.fmt.parseInt(u8, e, 10) catch return null else 1;
    return switch (event) {
        1 => true,
        2, 3 => false,
        else => null,
    };
}

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
    Pane.fromHandler(handler).send(data);
}

fn bell(handler: *Handler) void {
    Pane.fromHandler(handler).host.out.writer.writeByte(0x07) catch {};
}

fn titleChanged(handler: *Handler) void {
    const p = Pane.fromHandler(handler);
    if (p == &p.host.panes[p.host.focus]) p.host.writeTitle();
}

/// Reports a VT220 with ANSI color.
fn deviceAttributes(_: *Handler) vt.device_attributes.Attributes {
    return .{};
}

fn size(handler: *Handler) ?vt.size_report.Size {
    const ws = Pane.fromHandler(handler).ws;
    return .{
        .rows = ws.row,
        .columns = ws.col,
        .cell_width = if (ws.col > 0) ws.xpixel / ws.col else 0,
        .cell_height = if (ws.row > 0) ws.ypixel / ws.row else 0,
    };
}

fn renderHold(handler: *Handler, held: bool) void {
    const p = Pane.fromHandler(handler);
    p.held = held;
    if (held) p.held_since = nowMs();
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

fn renderRow(w: *std.Io.Writer, cells: std.MultiArrayList(vt.RenderState.Cell).Slice, y: usize, row: u16, col: u16) !void {
    try w.print("\x1b[{d};{d}H", .{ y + row + 1, col + 1 });

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
        if (raw.wide == .wide) try w.print("\x1b[{d}G", .{x + col + 3});
    }
    try w.writeAll("\x1b[0m");
}

fn syncModes(m: *Mux) !void {
    const w = &m.out.writer;
    inline for (mirrored_modes, &m.host_modes) |value, *host| {
        const mode = comptime vt.modes.modeFromInt(value, false).?;
        const set = m.panes[m.focus].terminal.modes.get(mode);
        if (set != host.*) {
            try w.print("\x1b[?{d}{c}", .{ value, @as(u8, if (set) 'h' else 'l') });
            host.* = set;
        }
    }

    const flags: u8 = m.panes[m.focus].terminal.screens.active.kitty_keyboard.current().int();
    if (flags != m.host_kitty_flags) {
        try w.print("\x1b[={d};1u", .{flags});
        m.host_kitty_flags = flags;
    }
}

/// Draw the rows that changed since the last frame, the cursor, and the
/// input modes into `m.out`.
pub fn render(m: *Mux) !void {
    const w = &m.out.writer;
    try w.writeAll("\x1b[?2026h\x1b[?25l");
    // Grapheme clustering must be synchronized before drawing rows.
    try syncModes(m);

    if (m.count > 1 and m.chrome_dirty) try renderChrome(m);
    m.chrome_dirty = false;
    for (m.panes[0..m.count]) |*p| {
        if (p.held) continue;
        const state = &p.render_state;
        try state.update(m.gpa, &p.terminal);
        if (p.redraw) state.dirty = .full;
        p.redraw = false;
        p.dirty = false;
        if (state.dirty != .false) {
            const rows = state.row_data.slice();
            for (rows.items(.cells), rows.items(.dirty), 0..) |cells, dirty, y| {
                if (state.dirty == .full or dirty) try renderRow(w, cells.slice(), y, p.row, p.col);
            }
        }
        state.clean();
    }

    const p = &m.panes[m.focus];
    const cursor = p.render_state.cursor;
    if (cursor.viewport) |pos| try w.print("\x1b[{d};{d}H", .{ pos.y + p.row + 1, pos.x + p.col + 1 });
    var shape: u8 = switch (cursor.visual_style) {
        .bar => 6,
        .underline => 4,
        else => 2,
    };
    if (cursor.blinking) shape -= 1;
    try w.print("\x1b[{d} q", .{shape});
    if (cursor.visible and cursor.viewport != null) try w.writeAll("\x1b[?25h");
    try w.writeAll("\x1b[?2026l");
}

fn renderChrome(m: *Mux) !void {
    const w = &m.out.writer;
    for (m.panes[0..m.count], 0..) |*p, index| {
        // Black on white for the focused pane, black on gray for the others.
        const colors = if (index == m.focus) "38;2;0;0;0;48;2;255;255;255" else "38;2;0;0;0;48;2;128;128;128";
        try w.print("\x1b[{d};{d}H\x1b[0;{s}m", .{ p.row, p.col + 1, colors });
        var label: std.Io.Writer.Allocating = .init(m.gpa);
        defer label.deinit();
        try label.writer.writeAll(p.label);
        if (p.status) |status| try label.writer.print(" (exited {d})", .{status});
        // Keep labels within their pane and prevent command-name controls
        // from being interpreted by the host.
        const text = label.written();
        for (0..p.ws.col) |x| try w.writeByte(if (x < text.len and text[x] >= 0x20 and text[x] <= 0x7e) text[x] else ' ');
    }
    try w.writeAll("\x1b[0;2m");
    for (0..m.ws.row) |y| try w.print("\x1b[{d};{d}H│", .{ y + 1, m.panes[0].ws.col + 1 });
    try w.writeAll("\x1b[0m");
}

/// Write what turns the host terminal back to how granite found it.
pub fn writeRestore(m: *Mux) void {
    const w = &m.out.writer;
    inline for (mirrored_modes, m.host_modes) |value, set| {
        const default = m.panes[0].terminal.modes.getDefault(comptime vt.modes.modeFromInt(value, false).?);
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
