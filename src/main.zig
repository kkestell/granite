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
const vt = @import("ghostty-vt");

const c = std.c;
const posix = std.posix;
const Handler = vt.TerminalStream.Handler;

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

/// Modes the program can enable that change how the host terminal must
/// encode input.
const mirrored_modes = [_]u16{
    1, // DECCKM: application cursor keys
    1000, // normal mouse tracking
    1002, // button-event mouse tracking
    1003, // any-event mouse tracking
    1004, // focus in/out events
    1006, // SGR mouse format
    2004, // bracketed paste
};

const Mux = struct {
    gpa: std.mem.Allocator,
    pty: posix.fd_t,
    ws: posix.winsize,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render_state: vt.RenderState = .empty,
    out: std.Io.Writer.Allocating,
    held: bool = false,
    held_since: i64 = 0,
    host_modes: [mirrored_modes.len]bool = @splat(false),
    host_kitty_flags: u8 = 0,

    fn fromHandler(handler: *Handler) *Mux {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream);
    }
};

var winch_pending: std.atomic.Value(bool) = .init(false);

fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

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

//------------------------------------------------------------------------
// Terminal effects

fn writePty(handler: *Handler, data: []const u8) void {
    writeAll(Mux.fromHandler(handler).pty, data);
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
fn cellStyle(raw: vt.Cell, style: vt.Style) vt.Style {
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
        else => |u| try w.print(";4:{d}", .{@intFromEnum(u)}),
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

fn syncInputModes(m: *Mux) !void {
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

fn render(m: *Mux) !void {
    const state = &m.render_state;
    try state.update(m.gpa, &m.terminal);
    const w = &m.out.writer;

    // Synchronized output keeps the host from showing a half-drawn frame.
    try w.writeAll("\x1b[?2026h\x1b[?25l");

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

    try syncInputModes(m);
    try w.writeAll("\x1b[?2026l");

    state.clean();
}

fn flush(m: *Mux) void {
    writeAll(posix.STDOUT_FILENO, m.out.written());
    m.out.clearRetainingCapacity();
}

//------------------------------------------------------------------------
// Host terminal setup

fn restoreHost(m: *Mux, orig: posix.termios) void {
    const w = &m.out.writer;
    for (mirrored_modes, m.host_modes) |value, set| {
        if (set) w.print("\x1b[?{d}l", .{value}) catch {};
    }
    if (m.host_kitty_flags != 0) w.writeAll("\x1b[=0;1u") catch {};
    w.writeAll("\x1b[0 q\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
    flush(m);
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, orig) catch {};
}

fn setupHost(orig: posix.termios) void {
    var raw = orig;
    cfmakeraw(&raw);
    posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch {};
    writeAll(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[2J");
}

/// Queries for the host's default colors and its 16 ANSI palette colors,
/// followed by DA1. Every terminal answers DA1, so its reply marks the end
/// of the host's replies. The replies stay small enough to fit in the tty
/// input buffer while the queries are still being written.
const color_queries = blk: {
    var q: []const u8 = "\x1b]10;?\x1b\\\x1b]11;?\x1b\\";
    for (0..16) |i| q = q ++ std.fmt.comptimePrint("\x1b]4;{d};?\x1b\\", .{i});
    break :blk q ++ "\x1b[c";
};

/// Ask the host for its colors, so the terminal answers the program's
/// OSC 10, 11, and 4 queries the way the host would.
fn queryHostColors(m: *Mux) !void {
    writeAll(posix.STDOUT_FILENO, color_queries);

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    const deadline = nowMs() + host_reply_timeout_ms;
    while (len < buf.len) {
        const replies = buf[0..len];
        if (std.mem.indexOf(u8, replies, "\x1b[?")) |da1| {
            if (std.mem.indexOfScalarPos(u8, replies, da1, 'c') != null) break;
        }
        const left = deadline - nowMs();
        if (left <= 0) break;
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(left)) == 0) break;
        const n = posix.read(posix.STDIN_FILENO, buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }

    var palette = vt.color.default;
    var have_palette = false;
    var it = std.mem.splitSequence(u8, buf[0..len], "\x1b]");
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
                const colors = &m.terminal.colors;
                if (code == 10) colors.foreground = .init(rgb) else colors.background = .init(rgb);
            },
            else => {},
        }
    }
    if (have_palette) try m.terminal.colors.palette.changeDefault(m.gpa, palette);
}

fn resize(m: *Mux) !void {
    _ = c.ioctl(posix.STDOUT_FILENO, c.T.IOCGWINSZ, &m.ws);
    _ = c.ioctl(m.pty, TIOCSWINSZ, &m.ws);
    try m.stream.handler.resize(.{
        .cols = m.ws.col,
        .rows = m.ws.row,
        .cell_size_px = .{
            .width = if (m.ws.col > 0) m.ws.xpixel / m.ws.col else 0,
            .height = if (m.ws.row > 0) m.ws.ypixel / m.ws.row else 0,
        },
    });
    try m.out.writer.writeAll("\x1b[2J");
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

    var ws: posix.winsize = undefined;
    _ = c.ioctl(posix.STDOUT_FILENO, c.T.IOCGWINSZ, &ws);

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

    var m: Mux = .{
        .gpa = gpa,
        .pty = pty,
        .ws = ws,
        .terminal = try .init(init.io, gpa, .{ .cols = ws.col, .rows = ws.row }),
        .stream = undefined,
        .out = .init(gpa),
    };
    defer m.terminal.deinit(gpa);
    defer m.render_state.deinit(gpa);
    defer m.out.deinit();

    // Prompts can't be assumed to redraw on resize without Ghostty's shell
    // integration. Shells can still opt in with OSC 133;A;redraw=1.
    m.terminal.flags.shell_redraws_prompt = .false;

    var handler = m.terminal.vtHandler();
    handler.effects.write_pty = &writePty;
    handler.effects.bell = &bell;
    handler.effects.title_changed = &titleChanged;
    handler.effects.device_attributes = &deviceAttributes;
    handler.effects.size = &size;
    handler.effects.render_hold = &renderHold;
    m.stream = .init(.{ .allocator = gpa, .handler = handler });
    defer m.stream.deinit();
    try resize(&m);

    const orig_termios = try posix.tcgetattr(posix.STDIN_FILENO);
    setupHost(orig_termios);
    errdefer restoreHost(&m, orig_termios);
    try queryHostColors(&m);

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
            try render(&m);
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
            .{ .fd = m.pty, .events = posix.POLL.IN, .revents = 0 },
        };
        // A raw poll, so that SIGWINCH interrupts the wait.
        if (c.poll(&fds, fds.len, @intCast(timeout)) < 0) {
            if (posix.errno(-1) == .INTR) continue;
            break;
        }

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buf) catch break;
            if (n == 0) break;
            writeAll(m.pty, buf[0..n]);
        }

        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            // The program exited.
            const n = posix.read(m.pty, &buf) catch break;
            if (n == 0) break;
            m.stream.nextSlice(buf[0..n]);
            dirty = true;
        }
    }

    restoreHost(&m, orig_termios);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    const s: u32 = @bitCast(status);
    if (posix.W.IFSIGNALED(s)) return 128 + @as(u8, @intCast(@intFromEnum(posix.W.TERMSIG(s))));
    return posix.W.EXITSTATUS(s);
}
