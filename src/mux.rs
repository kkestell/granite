//! Per-pane Ghostty terminals, host input routing, and rendering for one
//! program, two side-by-side programs, or a left program beside two
//! stacked programs. Terminals can run without ptys for round-trip tests.

use std::cell::{Cell, Ref, RefCell};
use std::io::Write as _;
use std::os::fd::RawFd;
use std::rc::Rc;

use libghostty_vt::error::{Error, Result};
use libghostty_vt::render::{CellIterator, Cursor, CursorVisualStyle, Dirty, RowIterator};
use libghostty_vt::screen::{Cell as RawCell, CellContentTag, CellWide};
use libghostty_vt::style::{Palette, RgbColor, Style, StyleColor, Underline};
use libghostty_vt::terminal::{
    ConformanceLevel, DeviceAttributeFeature, DeviceAttributes, DeviceType, Mode, ModeKind, Point,
    PointCoordinate, PrimaryDeviceAttributes, SecondaryDeviceAttributes, SizeReportSize,
    TertiaryDeviceAttributes,
};
use libghostty_vt::{RenderState, Terminal};

pub use libc::winsize as Winsize;

/// Modes mirrored onto the host terminal: the ones that change how the
/// host must encode input, and the ones that change how it draws what
/// granite sends. Each comes with Ghostty's default, which the host is
/// assumed to share; grapheme clustering's default comes from the host.
pub const MIRRORED_MODES: [(u16, bool); 19] = [
    (1, false),    // DECCKM: application cursor keys
    (5, false),    // DECSCNM: reverse video
    (9, false),    // X10 mouse reporting
    (66, false),   // DECNKM: application keypad
    (67, false),   // DECBKM: backspace sends BS
    (1000, false), // normal mouse tracking
    (1002, false), // button-event mouse tracking
    (1003, false), // any-event mouse tracking
    (1004, false), // focus in/out events
    (1005, false), // UTF-8 mouse format
    (1006, false), // SGR mouse format
    (1007, true),  // alternate scroll
    (1015, false), // urxvt mouse format
    (1016, false), // SGR pixel mouse format
    (1035, true),  // ignore keypad with Num Lock
    (1036, true),  // Alt sends ESC
    (1039, false), // Alt sends ESC (alternate)
    (2004, false), // bracketed paste
    (2027, false), // grapheme clustering
];

/// How long a pane may hold drawing (mode 2026) without completing a frame.
pub const HOLD_TIMEOUT_MS: i64 = 1000;

/// Reports a VT220 with ANSI color.
const DEVICE_ATTRIBUTES: DeviceAttributes = DeviceAttributes {
    primary: PrimaryDeviceAttributes::new(
        ConformanceLevel::VT220,
        &[DeviceAttributeFeature::ANSI_COLOR],
    ),
    secondary: SecondaryDeviceAttributes {
        device_type: DeviceType::VT220,
        firmware_version: 0,
        rom_cartridge: 0,
    },
    tertiary: TertiaryDeviceAttributes { unit_id: 0 },
};

fn dec(value: u16) -> Mode {
    Mode::new(value, ModeKind::Dec)
}

/// State shared with the terminals' effect callbacks.
struct Shared {
    out: RefCell<Vec<u8>>,
    focus: Cell<usize>,
}

/// Per-pane state shared with its terminal's effect callbacks.
struct PaneState {
    pty: Cell<Option<RawFd>>,
    ws: Cell<Winsize>,
    held: Cell<bool>,
    held_since: Cell<i64>,
}

impl PaneState {
    fn send(&self, data: &[u8]) {
        if let Some(pty) = self.pty.get() {
            write_all(pty, data);
        }
    }
}

/// What a pane last captured from its terminal and hasn't drawn yet. A
/// capture happens before each frame, and when the program starts a hold
/// (mode 2026), so that a held pane draws the last frame the program
/// completed rather than nothing or a half-drawn one.
struct Frame {
    render_state: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
    /// The rows that changed since the last draw, by viewport row.
    pending: Vec<Option<RowBuf>>,
    /// Whether `pending` holds a capture that hasn't been drawn.
    captured: bool,
    /// The cursor as of the last capture.
    cursor: Cursor,
    /// Rows to capture from the terminal itself; see `Pane::feed`.
    stale_rows: Vec<u16>,
}

impl Frame {
    fn new() -> Result<Frame> {
        Ok(Frame {
            render_state: RenderState::new()?,
            rows: RowIterator::new()?,
            cells: CellIterator::new()?,
            pending: Vec::new(),
            captured: false,
            cursor: Cursor {
                viewport: None,
                visible: true,
                blinking: false,
                password_input: false,
                visual_style: CursorVisualStyle::Block,
            },
            stale_rows: Vec::new(),
        })
    }

    /// Take the rows that changed since the last capture.
    fn capture(&mut self, terminal: &Terminal<'static, '_>) -> Result<()> {
        let snapshot = self.render_state.update(terminal)?;
        self.cursor = snapshot.cursor()?;
        let dirty = snapshot.dirty()?;
        let height = usize::from(snapshot.rows()?);
        if self.pending.len() != height {
            self.pending = (0..height).map(|_| None).collect();
        }
        let stale = std::mem::take(&mut self.stale_rows);
        if dirty != Dirty::Clean || !stale.is_empty() {
            let mut rows = self.rows.update(&snapshot)?;
            let mut y: u16 = 0;
            while let Some(r) = rows.next() {
                let Some(slot) = self.pending.get_mut(usize::from(y)) else { break };
                if stale.contains(&y) {
                    let mut row = RowBuf::default();
                    for x in 0..snapshot.cols()? {
                        let grid = terminal.grid_ref(Point::Active(PointCoordinate {
                            x,
                            y: u32::from(y),
                        }))?;
                        let raw = grid.cell()?;
                        let style = grid.style()?;
                        row.push(raw, style, |buf| grid.graphemes(buf))?;
                    }
                    *slot = Some(row);
                } else if dirty == Dirty::Full || r.dirty()? {
                    let mut row = RowBuf::default();
                    let mut cells = self.cells.update(r)?;
                    while let Some(c) = cells.next() {
                        let raw = c.raw_cell()?;
                        let style = c.style()?;
                        row.push(raw, style, |buf| {
                            let len = c.graphemes_len()? as usize;
                            if buf.len() < len {
                                return Err(Error::OutOfSpace { required: len });
                            }
                            c.graphemes_buf(&mut buf[..len])?;
                            Ok(len)
                        })?;
                    }
                    *slot = Some(row);
                }
                y += 1;
            }
        }
        snapshot.clean()?;
        self.captured = true;
        Ok(())
    }

    /// Draw the captured rows into `out`.
    fn draw(&mut self, out: &mut Vec<u8>, row: u16, col: u16) {
        for (y, slot) in self.pending.iter_mut().enumerate() {
            if let Some(r) = slot.take() {
                r.write(out, y as u16, row, col);
            }
        }
        self.captured = false;
    }
}

/// Per-program state.
pub struct Pane {
    state: Rc<PaneState>,
    pub pid: Option<libc::pid_t>,
    pub status: Option<u8>,
    pub label: String,
    pub row: u16,
    pub col: u16,
    pub terminal: Terminal<'static, 'static>,
    frame: Rc<RefCell<Frame>>,
    dirty: bool,
}

impl Pane {
    fn new(shared: &Rc<Shared>, label: &str, index: usize, layout: Layout) -> Result<Pane> {
        let state = Rc::new(PaneState {
            pty: Cell::new(None),
            ws: Cell::new(layout.ws),
            held: Cell::new(false),
            held_since: Cell::new(0),
        });
        let frame = Rc::new(RefCell::new(Frame::new()?));
        let mut terminal = Terminal::new(layout.ws.ws_col, layout.ws.ws_row)?;

        let s = state.clone();
        terminal.on_pty_write(move |_, data| s.send(data))?;
        let sh = shared.clone();
        terminal.on_bell(move |_| sh.out.borrow_mut().push(0x07))?;
        let sh = shared.clone();
        terminal.on_title_changed(move |t| {
            if sh.focus.get() == index {
                write_title(&mut sh.out.borrow_mut(), t);
            }
        })?;
        terminal.on_device_attributes(|_| Some(DEVICE_ATTRIBUTES))?;
        let s = state.clone();
        terminal.on_size(move |_| {
            let ws = s.ws.get();
            Some(SizeReportSize {
                rows: ws.ws_row,
                columns: ws.ws_col,
                cell_width: u32::from(ws.ws_xpixel.checked_div(ws.ws_col).unwrap_or(0)),
                cell_height: u32::from(ws.ws_ypixel.checked_div(ws.ws_row).unwrap_or(0)),
            })
        })?;
        let s = state.clone();
        let f = frame.clone();
        terminal.on_render_hold(move |t, held| {
            s.held.set(held);
            if held {
                // Nothing after the hold's start has been processed, so the
                // terminal holds the frame the program completed.
                if let Ok(mut frame) = f.try_borrow_mut() {
                    let _ = frame.capture(t);
                }
                s.held_since.set(now_ms());
            }
        })?;

        Ok(Pane {
            state,
            pid: None,
            status: None,
            label: label.to_owned(),
            row: layout.row,
            col: layout.col,
            terminal,
            frame,
            dirty: true,
        })
    }

    pub fn feed(&mut self, data: &[u8]) {
        // A leading zero-width character can attach to the previous cell
        // without dirtying its row, so the render state wouldn't see it.
        // Capture the cursor's row from the terminal.
        if let Ok(y) = self.terminal.cursor_y() {
            let mut frame = self.frame.borrow_mut();
            if !frame.stale_rows.contains(&y) {
                frame.stale_rows.push(y);
            }
        }
        self.terminal.vt_write(data);
        self.dirty = true;
    }

    pub fn pty(&self) -> Option<RawFd> {
        self.state.pty.get()
    }

    pub fn set_pty(&self, pty: Option<RawFd>) {
        self.state.pty.set(pty);
    }

    pub fn ws(&self) -> Winsize {
        self.state.ws.get()
    }

    /// Whether the program holds drawing (mode 2026). A held pane draws
    /// only what was captured when the hold began.
    pub fn held(&self) -> bool {
        self.state.held.get()
    }

    pub fn set_held(&self, held: bool) {
        self.state.held.set(held);
    }

    /// When the program last completed a frame by starting a hold.
    pub fn held_since(&self) -> i64 {
        self.state.held_since.get()
    }

    /// Stop honoring a hold that has gone on too long.
    pub fn end_hold(&mut self) -> Result<()> {
        self.set_held(false);
        Ok(())
    }

    pub fn send(&self, data: &[u8]) {
        self.state.send(data);
    }

    fn mode(&self, mode: Mode) -> bool {
        self.terminal.mode(mode).unwrap_or(false)
    }

    fn needs_render(&self) -> bool {
        if self.held() { self.frame.borrow().captured } else { self.dirty }
    }

    /// Draw the rows that changed since the last frame into `out`: from
    /// the terminal, or while held, from the capture at the hold's start.
    fn render(&mut self, out: &mut Vec<u8>) -> Result<()> {
        let mut frame = self.frame.borrow_mut();
        if !self.held() {
            frame.capture(&self.terminal)?;
            self.dirty = false;
        }
        frame.draw(out, self.row, self.col);
        Ok(())
    }

    fn cursor(&self) -> Cursor {
        self.frame.borrow().cursor
    }
}

#[derive(Clone, Copy)]
struct Layout {
    ws: Winsize,
    row: u16,
    col: u16,
}

pub struct Mux {
    pub ws: Winsize,
    pub panes: Vec<Pane>,
    shared: Rc<Shared>,
    pub chrome_dirty: bool,
    host_modes: [bool; MIRRORED_MODES.len()],
    host_kitty_flags: u8,
    /// Whether terminals cluster graphemes by default, from the host.
    grapheme_default: bool,
}

impl Mux {
    pub fn new(ws: Winsize, labels: &[&str]) -> Result<Mux> {
        assert!((1..=3).contains(&labels.len()));
        let shared = Rc::new(Shared { out: RefCell::new(Vec::new()), focus: Cell::new(0) });
        let mut panes = Vec::with_capacity(labels.len());
        for (i, label) in labels.iter().enumerate() {
            panes.push(Pane::new(&shared, label, i, layout(ws, labels.len(), i))?);
        }
        let mut m = Mux {
            ws,
            panes,
            shared,
            chrome_dirty: labels.len() > 1,
            host_modes: [false; MIRRORED_MODES.len()],
            host_kitty_flags: 0,
            grapheme_default: false,
        };
        m.reset_host_modes();
        Ok(m)
    }

    pub fn focus(&self) -> usize {
        self.shared.focus.get()
    }

    /// What granite has drawn since the output was last taken.
    pub fn output(&self) -> Ref<'_, Vec<u8>> {
        self.shared.out.borrow()
    }

    pub fn take_output(&mut self) -> Vec<u8> {
        std::mem::take(&mut *self.shared.out.borrow_mut())
    }

    pub fn use_host_replies(&mut self, replies: &[u8]) -> Result<()> {
        for p in &mut self.panes {
            use_host_replies_for(&mut p.terminal, replies)?;
        }
        self.grapheme_default = host_clusters(replies);
        self.reset_host_modes();
        Ok(())
    }

    fn mode_default(&self, value: u16, default: bool) -> bool {
        if value == 2027 { self.grapheme_default } else { default }
    }

    fn reset_host_modes(&mut self) {
        for (i, &(value, default)) in MIRRORED_MODES.iter().enumerate() {
            self.host_modes[i] = self.mode_default(value, default);
        }
    }

    pub fn resize(&mut self, ws: Winsize) -> Result<()> {
        self.ws = ws;
        let count = self.panes.len();
        for (i, p) in self.panes.iter_mut().enumerate() {
            let l = layout(ws, count, i);
            p.state.ws.set(l.ws);
            p.row = l.row;
            p.col = l.col;
            let ws = l.ws;
            p.terminal.resize(
                ws.ws_col,
                ws.ws_row,
                u32::from(ws.ws_xpixel.checked_div(ws.ws_col).unwrap_or(0)),
                u32::from(ws.ws_ypixel.checked_div(ws.ws_row).unwrap_or(0)),
            )?;
            // Marking the render state dirty would repaint its cached rows,
            // which can miss what `feed` captured from the terminal. Setting
            // a color default marks the terminal's palette dirty instead,
            // which makes the next capture rebuild every row.
            let cursor = p.terminal.default_cursor_color()?;
            p.terminal.set_default_cursor_color(cursor)?;
            p.dirty = true;
        }
        self.shared.out.borrow_mut().extend_from_slice(b"\x1b[2J");
        self.chrome_dirty = count > 1;
        Ok(())
    }

    /// End holds that have gone `HOLD_TIMEOUT_MS` without a completed frame.
    pub fn expire_holds(&mut self, now: i64) -> Result<()> {
        for p in &mut self.panes {
            if p.held() && now - p.held_since() >= HOLD_TIMEOUT_MS {
                p.end_hold()?;
            }
        }
        Ok(())
    }

    pub fn needs_render(&self) -> bool {
        self.chrome_dirty || self.panes.iter().any(Pane::needs_render)
    }

    pub fn set_focus(&mut self, index: usize) {
        let focus = self.focus();
        if index == focus || self.panes[index].status.is_some() {
            return;
        }
        let old = &self.panes[focus];
        if old.mode(Mode::FOCUS_EVENT) {
            old.send(b"\x1b[O");
        }
        self.shared.focus.set(index);
        let next = &self.panes[index];
        if next.mode(Mode::FOCUS_EVENT) {
            next.send(b"\x1b[I");
        }
        self.chrome_dirty = true;
        write_title(&mut self.shared.out.borrow_mut(), &next.terminal);
    }

    /// Focus the next live pane after the focused one, in pane order.
    pub fn focus_next(&mut self) {
        let count = self.panes.len();
        for step in 1..count {
            let index = (self.focus() + step) % count;
            if self.panes[index].status.is_none() {
                return self.set_focus(index);
            }
        }
    }

    fn send(&self, data: &[u8]) {
        self.panes[self.focus()].send(data);
    }

    /// Input is parsed only within this read; partial escape sequences are
    /// forwarded without waiting for another read.
    pub fn input(&mut self, data: &[u8]) {
        if self.panes.len() == 1 {
            return self.panes[0].send(data);
        }
        let mut i = 0;
        let mut start = 0;
        while i < data.len() {
            let mut end = i + 1;
            let mut swallow = false;
            let mut toggle = false;
            if data[i] == 0x1d {
                swallow = true;
                toggle = true;
            } else if data[i..].starts_with(b"\x1b[") {
                let mut fin = i + 2;
                while fin < data.len() && !(0x40..=0x7e).contains(&data[fin]) {
                    fin += 1;
                }
                if fin < data.len() {
                    end = fin + 1;
                    let params = &data[i + 2..fin];
                    let last = data[fin];
                    if last == b'u' {
                        if let Some(press) = focus_key(params) {
                            swallow = true;
                            toggle = press;
                        }
                    } else if (params.starts_with(b"<") && (last == b'M' || last == b'm'))
                        || (last == b'M'
                            && (params.is_empty()
                                || params.iter().filter(|&&b| b == b';').count() == 2))
                    {
                        // All mouse protocols end in M/m. Only SGR cell
                        // coordinates can be translated into a pane.
                        self.send(&data[start..i]);
                        start = end;
                        if let Some(sgr) = params.strip_prefix(b"<") {
                            self.mouse(sgr, last);
                        }
                        if params.is_empty() && last == b'M' {
                            // X10/1005 encodes three characters after CSI M.
                            let utf8 = self.panes[self.focus()].mode(Mode::UTF8_MOUSE);
                            for _ in 0..3 {
                                if end == data.len() {
                                    break;
                                }
                                let len = if utf8 { utf8_sequence_length(data[end]) } else { 1 };
                                end = data.len().min(end + len);
                            }
                            start = end;
                        }
                        i = end;
                        continue;
                    }
                }
            }
            if swallow {
                self.send(&data[start..i]);
                if toggle {
                    self.focus_next();
                }
                start = end;
            }
            i = end;
        }
        self.send(&data[start..]);
    }

    fn mouse(&self, params: &[u8], last: u8) {
        let mut fields = params.split(|&b| b == b';');
        let mut field = || fields.next().and_then(parse_int::<u16>);
        let (Some(button), Some(x), Some(y)) = (field(), field(), field()) else { return };
        if fields.next().is_some() {
            return;
        }
        let p = &self.panes[self.focus()];
        if p.mode(Mode::SGR_PIXELS_MOUSE) {
            return;
        }
        let ws = p.ws();
        if x <= p.col || x > p.col + ws.ws_col || y <= p.row || y > p.row + ws.ws_row {
            return;
        }
        let report = format!("\x1b[<{};{};{}{}", button, x - p.col, y - p.row, last as char);
        p.send(report.as_bytes());
    }

    fn sync_modes(&mut self, out: &mut Vec<u8>) {
        let p = &self.panes[self.focus()];
        for (i, &(value, _)) in MIRRORED_MODES.iter().enumerate() {
            let set = p.mode(dec(value));
            if set != self.host_modes[i] {
                let _ = write!(out, "\x1b[?{}{}", value, if set { 'h' } else { 'l' });
                self.host_modes[i] = set;
            }
        }

        let flags = p.terminal.kitty_keyboard_flags().map_or(0, |f| f.bits());
        if flags != self.host_kitty_flags {
            let _ = write!(out, "\x1b[={flags};1u");
            self.host_kitty_flags = flags;
        }
    }

    /// Draw the rows that changed since the last frame, the cursor, and the
    /// input modes into the output.
    pub fn render(&mut self) -> Result<()> {
        let shared = self.shared.clone();
        let mut out = shared.out.borrow_mut();
        out.extend_from_slice(b"\x1b[?2026h\x1b[?25l");
        // Grapheme clustering must be synchronized before drawing rows.
        self.sync_modes(&mut out);

        if self.panes.len() > 1 && self.chrome_dirty {
            self.render_chrome(&mut out);
        }
        self.chrome_dirty = false;
        for p in &mut self.panes {
            p.render(&mut out)?;
        }

        let p = &self.panes[self.focus()];
        let cursor = p.cursor();
        if let Some(pos) = cursor.viewport {
            let _ = write!(out, "\x1b[{};{}H", pos.y + p.row + 1, pos.x + p.col + 1);
        }
        let mut shape: u8 = match cursor.visual_style {
            CursorVisualStyle::Bar => 6,
            CursorVisualStyle::Underline => 4,
            _ => 2,
        };
        if cursor.blinking {
            shape -= 1;
        }
        let _ = write!(out, "\x1b[{shape} q");
        if cursor.visible && cursor.viewport.is_some() {
            out.extend_from_slice(b"\x1b[?25h");
        }
        out.extend_from_slice(b"\x1b[?2026l");
        Ok(())
    }

    fn render_chrome(&self, out: &mut Vec<u8>) {
        for (index, p) in self.panes.iter().enumerate() {
            // Black on white for the focused pane, black on gray for the others.
            let colors = if index == self.focus() {
                "38;2;0;0;0;48;2;255;255;255"
            } else {
                "38;2;0;0;0;48;2;128;128;128"
            };
            let _ = write!(out, "\x1b[{};{}H\x1b[0;{}m", p.row, p.col + 1, colors);
            let mut label = p.label.clone();
            if let Some(status) = p.status {
                label.push_str(&format!(" (exited {status})"));
            }
            // Keep labels within their pane and prevent command-name controls
            // from being interpreted by the host.
            let text = label.as_bytes();
            for x in 0..usize::from(p.ws().ws_col) {
                let b = text.get(x).copied().unwrap_or(b' ');
                out.push(if (0x20..=0x7e).contains(&b) { b } else { b' ' });
            }
        }
        out.extend_from_slice(b"\x1b[0;2m");
        let divider = self.panes[0].ws().ws_col + 1;
        for y in 0..self.ws.ws_row {
            let _ = write!(out, "\x1b[{};{}H│", y + 1, divider);
        }
        out.extend_from_slice(b"\x1b[0m");
    }

    /// Write what turns the host terminal back to how granite found it.
    pub fn write_restore(&mut self) {
        let mut out = self.shared.out.borrow_mut();
        for (i, &(value, default)) in MIRRORED_MODES.iter().enumerate() {
            let default = self.mode_default(value, default);
            if self.host_modes[i] != default {
                let _ = write!(out, "\x1b[?{}{}", value, if default { 'h' } else { 'l' });
            }
        }
        if self.host_kitty_flags != 0 {
            out.extend_from_slice(b"\x1b[=0;1u");
        }
        out.extend_from_slice(b"\x1b[0 q\x1b[0m\x1b[?25h\x1b[?1049l");
    }
}

fn layout(ws: Winsize, count: usize, index: usize) -> Layout {
    if count == 1 {
        return Layout { ws, row: 0, col: 0 };
    }
    // Ghostty and the pty require at least one cell in each dimension.
    // Each pane has a header row above it.
    let width = ws.ws_col.max(3);
    let left = (width - 1) / 2;
    let cols = if index == 0 { left } else { width - left - 1 };
    let mut row = 1;
    let mut rows = ws.ws_row.max(2) - 1;
    if count == 3 && index > 0 {
        let height = ws.ws_row.max(4);
        let top = (height - 1) / 2;
        rows = if index == 1 { top } else { height - top - 2 };
        if index == 2 {
            row = top + 2;
        }
    }
    Layout {
        ws: Winsize {
            ws_col: cols,
            ws_row: rows,
            ws_xpixel: (u32::from(ws.ws_xpixel) * u32::from(cols) / u32::from(ws.ws_col.max(1)))
                as u16,
            ws_ypixel: (u32::from(ws.ws_ypixel) * u32::from(rows) / u32::from(ws.ws_row.max(1)))
                as u16,
        },
        row,
        col: if index == 0 { 0 } else { left + 1 },
    }
}

fn write_title(out: &mut Vec<u8>, terminal: &Terminal) {
    out.extend_from_slice(b"\x1b]0;");
    out.extend_from_slice(terminal.title().unwrap_or(b""));
    out.push(0x07);
}

/// Kitty's key;modifiers:event;... form, including alternate key fields.
fn focus_key(params: &[u8]) -> Option<bool> {
    let mut fields = params.split(|&b| b == b';');
    let key = fields.next()?.split(|&b| b == b':').next()?;
    if parse_int::<u32>(key)? != 93 {
        return None;
    }
    let mut modifiers = fields.next()?.split(|&b| b == b':');
    if parse_int::<u16>(modifiers.next()?)? != 5 {
        return None;
    }
    let event = match modifiers.next() {
        Some(e) => parse_int::<u8>(e)?,
        None => 1,
    };
    match event {
        1 => Some(true),
        2 | 3 => Some(false),
        _ => None,
    }
}

fn parse_int<T: std::str::FromStr>(s: &[u8]) -> Option<T> {
    std::str::from_utf8(s).ok()?.parse().ok()
}

fn utf8_sequence_length(first: u8) -> usize {
    match first {
        0x00..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => 1,
    }
}

pub fn now_ms() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec * 1000 + ts.tv_nsec / 1_000_000
}

/// Read into `buf`, retrying when a signal interrupts the read. Returns
/// the byte count, 0 at end of input, or -1 on any other error.
pub fn read(fd: RawFd, buf: &mut [u8]) -> isize {
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if n >= 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return n;
        }
    }
}

pub fn write_all(fd: RawFd, data: &[u8]) {
    let mut rest = data;
    while !rest.is_empty() {
        let n = unsafe { libc::write(fd, rest.as_ptr().cast(), rest.len()) };
        if n < 0 {
            match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::EINTR | libc::EAGAIN) => continue,
                _ => return,
            }
        }
        rest = &rest[n as usize..];
    }
}

//------------------------------------------------------------------------
// Rendering

/// One row's cells, gathered from the render state or the terminal.
#[derive(Default)]
struct RowBuf {
    cells: Vec<(RawCell, Style, usize, usize)>,
    text: Vec<char>,
}

impl RowBuf {
    /// Add a cell whose text `graphemes` writes into a buffer, returning
    /// its length.
    fn push(
        &mut self,
        raw: RawCell,
        style: Style,
        graphemes: impl Fn(&mut [char]) -> Result<usize>,
    ) -> Result<()> {
        let start = self.text.len();
        let mut room = 8;
        let len = loop {
            self.text.resize(start + room, '\0');
            match graphemes(&mut self.text[start..]) {
                Ok(len) => break len,
                Err(Error::OutOfSpace { required }) if required > room => room = required,
                Err(e) => return Err(e),
            }
        };
        self.text.truncate(start + len);
        self.cells.push((raw, style, start, len));
        Ok(())
    }

    fn write(&self, out: &mut Vec<u8>, y: u16, row: u16, col: u16) {
        let _ = write!(out, "\x1b[{};{}H", y + row + 1, col + 1);

        let mut prev: Option<Style> = None;
        for (x, &(raw, style, start, len)) in self.cells.iter().enumerate() {
            let wide = raw.wide().unwrap_or(CellWide::Narrow);
            if wide == CellWide::SpacerTail {
                continue;
            }

            let s = cell_style(raw, style);
            if prev != Some(s) {
                write_sgr(out, s);
                prev = Some(s);
            }

            if raw.has_text().unwrap_or(false) && len > 0 {
                let mut buf = [0; 4];
                for &c in &self.text[start..start + len] {
                    out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
                }
            } else {
                out.push(b' ');
            }

            // Re-sync the column after a wide character in case the host
            // terminal disagrees about its width.
            if wide == CellWide::Wide {
                let _ = write!(out, "\x1b[{}G", x + usize::from(col) + 3);
            }
        }
        out.extend_from_slice(b"\x1b[0m");
    }
}

/// The style a cell is drawn with. Cells cleared with a background color
/// carry it in the cell content rather than the style.
pub fn cell_style(raw: RawCell, style: Style) -> Style {
    let mut s = if raw.has_styling().unwrap_or(false) { style } else { Style::default() };
    match raw.content_tag() {
        Ok(CellContentTag::BgColorPalette) => {
            if let Ok(i) = raw.bg_color_palette() {
                s.bg_color = StyleColor::Palette(i);
            }
        }
        Ok(CellContentTag::BgColorRgb) => {
            if let Ok(rgb) = raw.bg_color_rgb() {
                s.bg_color = StyleColor::Rgb(rgb);
            }
        }
        _ => {}
    }
    s
}

fn write_color(out: &mut Vec<u8>, base: u8, color: StyleColor) {
    match color {
        StyleColor::None => {}
        StyleColor::Palette(i) => {
            let _ = write!(out, ";{base};5;{}", i.0);
        }
        StyleColor::Rgb(c) => {
            let _ = write!(out, ";{base};2;{};{};{}", c.r, c.g, c.b);
        }
    }
}

/// Write the SGR sequence that fully describes a style.
fn write_sgr(out: &mut Vec<u8>, s: Style) {
    out.extend_from_slice(b"\x1b[0");
    if s.bold {
        out.extend_from_slice(b";1");
    }
    if s.faint {
        out.extend_from_slice(b";2");
    }
    if s.italic {
        out.extend_from_slice(b";3");
    }
    match s.underline {
        Underline::None => {}
        Underline::Single => out.extend_from_slice(b";4"),
        u => {
            let _ = write!(out, ";4:{}", u as i32);
        }
    }
    if s.blink {
        out.extend_from_slice(b";5");
    }
    if s.inverse {
        out.extend_from_slice(b";7");
    }
    if s.invisible {
        out.extend_from_slice(b";8");
    }
    if s.strikethrough {
        out.extend_from_slice(b";9");
    }
    if s.overline {
        out.extend_from_slice(b";53");
    }
    write_color(out, 38, s.fg_color);
    write_color(out, 48, s.bg_color);
    write_color(out, 58, s.underline_color);
    out.push(b'm');
}

//------------------------------------------------------------------------
// Host state

/// Queries for the host's default colors, its 16 ANSI palette colors, and
/// whether it clusters graphemes (mode 2027), followed by DA1. Every
/// terminal answers DA1, so its reply marks the end of the host's replies.
/// The replies stay small enough to fit in the tty input buffer while the
/// queries are still being written.
pub fn host_queries() -> Vec<u8> {
    let mut q = b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\".to_vec();
    for i in 0..16 {
        let _ = write!(q, "\x1b]4;{i};?\x1b\\");
    }
    q.extend_from_slice(b"\x1b[?2027$p\x1b[c");
    q
}

/// The pieces of `data` after each occurrence of `sep`.
fn after_each<'a>(data: &'a [u8], sep: &'a [u8]) -> impl Iterator<Item = &'a [u8]> {
    let mut rest = find(data, sep).map(|i| &data[i + sep.len()..]);
    std::iter::from_fn(move || {
        let r = rest?;
        match find(r, sep) {
            Some(i) => {
                rest = Some(&r[i + sep.len()..]);
                Some(&r[..i])
            }
            None => {
                rest = None;
                Some(r)
            }
        }
    })
}

fn find(data: &[u8], needle: &[u8]) -> Option<usize> {
    data.windows(needle.len()).position(|w| w == needle)
}

/// True once `replies` holds the host's DA1 reply.
pub fn host_replies_done(replies: &[u8]) -> bool {
    after_each(replies, b"\x1b[?").any(|reply| {
        reply.iter().find(|b| !b.is_ascii_digit() && **b != b';').is_some_and(|&b| b == b'c')
    })
}

/// Whether the host's replies say it clusters graphemes.
fn host_clusters(replies: &[u8]) -> bool {
    const REPLY: &[u8] = b"\x1b[?2027;";
    find(replies, REPLY)
        .and_then(|i| replies.get(i + REPLY.len()))
        .is_some_and(|&b| b == b'1' || b == b'3')
}

/// Take the host's replies to `host_queries` as the terminal's colors, so
/// it answers the program's OSC 10, 11, and 4 queries the way the host
/// would, and as its default for grapheme clustering, so the host lays out
/// rows the way the terminal does.
pub fn use_host_replies_for(t: &mut Terminal, replies: &[u8]) -> Result<()> {
    if host_clusters(replies) {
        t.set_default_mode(Mode::GRAPHEME_CLUSTER, true)?;
    }

    let mut palette = Palette::default();
    let mut have_palette = false;
    for reply in after_each(replies, b"\x1b]") {
        let Some(end) = reply.iter().position(|&b| b == 0x1b || b == 0x07) else { continue };
        let mut fields = reply[..end].splitn(2, |&b| b == b';');
        let Some(code) = fields.next().and_then(parse_int::<u8>) else { continue };
        let rest = fields.next().unwrap_or(b"");
        match code {
            4 => {
                let mut fields = rest.splitn(2, |&b| b == b';');
                let Some(i) = fields.next().and_then(parse_int::<u8>) else { continue };
                let Some(rgb) = parse_rgb(fields.next().unwrap_or(b"")) else { continue };
                palette.0[usize::from(i)] = rgb;
                have_palette = true;
            }
            10 | 11 => {
                let Some(rgb) = parse_rgb(rest) else { continue };
                if code == 10 {
                    t.set_default_fg_color(Some(rgb))?;
                } else {
                    t.set_default_bg_color(Some(rgb))?;
                }
            }
            _ => {}
        }
    }
    if have_palette {
        t.set_default_color_palette(Some(palette))?;
    }
    Ok(())
}

fn parse_rgb(s: &[u8]) -> Option<RgbColor> {
    RgbColor::parse(std::str::from_utf8(s).ok()?).ok()
}
