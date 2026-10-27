//! Real-pty tests of granite, with a Ghostty terminal acting as its host.
//! Ported from zig/test/live.zig; the child is src/bin/granite-test-child.rs.
use std::cell::Cell;
use std::ffi::CString;
use std::rc::Rc;
use std::sync::Mutex;

use granite::mux::{self, now_ms, write_all};
use libghostty_vt::render::{CellIterator, CursorVisualStyle, RowIterator};
use libghostty_vt::screen::CellWide;
use libghostty_vt::terminal::{
    ConformanceLevel, DeviceAttributeFeature, DeviceAttributes, DeviceType, Mode, ModeKind,
    PrimaryDeviceAttributes, SecondaryDeviceAttributes, TertiaryDeviceAttributes,
};
use libghostty_vt::{RenderState, Terminal};

const GRANITE: &str = env!("CARGO_BIN_EXE_granite");
const CHILD: &str = env!("CARGO_BIN_EXE_granite-test-child");

/// Tests run on parallel threads, and forkpty isn't thread-safe on macOS:
/// it names the pty with ptsname, which returns a shared static buffer.
static FORKPTY: Mutex<()> = Mutex::new(());
fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}
fn position(haystack: &[u8], needle: &[u8]) -> usize {
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
        .unwrap()
}
fn host_colors() -> Vec<u8> {
    let mut s = "\x1b]10;rgb:d0d0/d1d1/d2d2\x1b\\\x1b]11;rgb:1010/1111/1212\x1b\\".to_owned();
    for i in 0..16 {
        s.push_str(&format!(
            "\x1b]4;{i};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
            i * 16 + 1,
            255 - i * 15,
            i * 7 + 3
        ));
    }
    s.into_bytes()
}
fn winsize(cols: u16, rows: u16) -> libc::winsize {
    libc::winsize {
        ws_col: cols,
        ws_row: rows,
        ws_xpixel: cols * 8,
        ws_ypixel: rows * 16,
    }
}
struct Host {
    pid: libc::pid_t,
    pty: libc::c_int,
    terminal: Terminal<'static, 'static>,
    output: Vec<u8>,
    reads: Vec<(usize, i64)>,
    eof: bool,
    status: Option<i32>,
}
impl Host {
    fn start(args: &[&str], cols: u16, rows: u16) -> Self {
        let mut command = vec![CHILD];
        command.extend_from_slice(args);
        Self::spawn(&command, cols, rows, true)
    }
    fn split(left: &[&str], right: &[&str], cols: u16, rows: u16) -> Self {
        Self::panes(&[left, right], cols, rows)
    }
    fn panes(panes: &[&[&str]], cols: u16, rows: u16) -> Self {
        let mut args = Vec::new();
        for (i, pane) in panes.iter().enumerate() {
            if i > 0 {
                args.push("::");
            }
            args.push(CHILD);
            args.extend_from_slice(pane);
        }
        Self::spawn(&args, cols, rows, true)
    }
    fn spawn(args: &[&str], cols: u16, rows: u16, answer: bool) -> Self {
        // Prepare everything before fork: the child may only call async-signal-safe
        // functions, since the Rust test harness can have other running threads.
        let argv: Vec<_> = std::iter::once(GRANITE)
            .chain(args.iter().copied())
            .map(|a| CString::new(a).unwrap())
            .collect();
        let mut pointers: Vec<_> = argv.iter().map(|a| a.as_ptr()).collect();
        pointers.push(std::ptr::null());
        let mut terminal = Terminal::new(cols, rows).unwrap();
        mux::use_host_replies_for(&mut terminal, &host_colors()).unwrap();
        terminal
            .set_default_mode(Mode::new(2027, ModeKind::Dec), true)
            .unwrap();
        let fd = Rc::new(Cell::new(-1));
        if answer {
            let fd = fd.clone();
            terminal
                .on_pty_write(move |_, data| write_all(fd.get(), data))
                .unwrap();
            terminal
                .on_device_attributes(|_| {
                    Some(DeviceAttributes {
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
                    })
                })
                .unwrap();
        }
        let mut pty = -1;
        let mut ws = winsize(cols, rows);
        let guard = FORKPTY.lock().unwrap_or_else(|e| e.into_inner());
        let pid = unsafe {
            libc::forkpty(
                &mut pty,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut ws,
            )
        };
        let err = std::io::Error::last_os_error();
        drop(guard);
        assert!(pid >= 0, "forkpty: {err}");
        if pid == 0 {
            unsafe {
                libc::execv(pointers[0], pointers.as_ptr());
                libc::_exit(127);
            }
        }
        fd.set(pty);
        Self {
            pid,
            pty,
            terminal,
            output: Vec::new(),
            reads: Vec::new(),
            eof: false,
            status: None,
        }
    }
    fn pump(&mut self, timeout: i64) {
        if self.eof {
            return;
        }
        let mut fd = libc::pollfd {
            fd: self.pty,
            events: libc::POLLIN,
            revents: 0,
        };
        if unsafe { libc::poll(&mut fd, 1, timeout.max(0) as i32) } <= 0 {
            return;
        }
        let mut buf = [0u8; 65536];
        let n = unsafe { libc::read(self.pty, buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 {
            self.eof = true;
            return;
        }
        let data = &buf[..n as usize];
        self.output.extend_from_slice(data);
        self.reads.push((self.output.len(), now_ms()));
        self.terminal.vt_write(data);
    }
    fn until(&mut self, mut done: impl FnMut(&mut Self) -> bool) {
        let deadline = now_ms() + 5000;
        while !done(self) {
            assert!(
                now_ms() < deadline && !self.eof,
                "timed out; screen:\n{}\noutput: {:?}",
                self.screen(),
                String::from_utf8_lossy(&self.output)
            );
            self.pump((deadline - now_ms()).min(50));
        }
    }
    fn screen(&self) -> String {
        let mut state = RenderState::new().unwrap();
        let snapshot = state.update(&self.terminal).unwrap();
        let mut rows = RowIterator::new().unwrap();
        let mut rows = rows.update(&snapshot).unwrap();
        let mut cells = CellIterator::new().unwrap();
        let mut text = String::new();
        while let Some(row) = rows.next() {
            let mut line = String::new();
            let mut iter = cells.update(row).unwrap();
            while let Some(cell) = iter.next() {
                let raw = cell.raw_cell().unwrap();
                if raw.wide().unwrap() == CellWide::SpacerTail {
                    continue;
                }
                if raw.has_text().unwrap() {
                    let mut grapheme = String::new();
                    cell.graphemes_utf8(&mut grapheme).unwrap();
                    line.push_str(&grapheme);
                } else {
                    line.push(' ');
                }
            }
            text.push_str(line.trim_end_matches(' '));
            text.push('\n');
        }
        text.trim_end_matches('\n').to_owned()
    }
    fn wait_screen(&mut self, text: &str) {
        self.until(|h| h.screen().contains(text));
    }
    fn first_seen(&self, text: &str) -> i64 {
        let end = position(&self.output, text.as_bytes()) + text.len();
        self.reads.iter().find(|(n, _)| *n >= end).unwrap().1
    }
    fn send(&self, data: impl AsRef<[u8]>) {
        write_all(self.pty, data.as_ref());
    }
    fn resize(&mut self, cols: u16, rows: u16) {
        self.terminal.resize(cols, rows, 8, 16).unwrap();
        assert_eq!(
            unsafe { libc::ioctl(self.pty, libc::TIOCSWINSZ, &winsize(cols, rows)) },
            0
        );
    }
    fn wait(&mut self) -> i32 {
        let deadline = now_ms() + 5000;
        while !self.eof {
            assert!(now_ms() < deadline, "waiting for exit");
            self.pump(50);
        }
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(self.pid, &mut status, 0) }, self.pid);
        self.status = Some(status);
        if libc::WIFSIGNALED(status) {
            128 + libc::WTERMSIG(status)
        } else {
            libc::WEXITSTATUS(status)
        }
    }
    fn mode(&self, n: u16) -> bool {
        self.terminal.mode(Mode::new(n, ModeKind::Dec)).unwrap()
    }
    fn kitty(&self) -> u8 {
        self.terminal.kitty_keyboard_flags().unwrap().bits()
    }
    fn cursor_style(&self) -> CursorVisualStyle {
        let mut state = RenderState::new().unwrap();
        state
            .update(&self.terminal)
            .unwrap()
            .cursor_visual_style()
            .unwrap()
    }
    fn finish_split(&mut self) {
        self.send("q");
        self.wait_screen("(exited 0)");
        self.send("q");
        assert_eq!(self.wait(), 0);
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            if self.status.is_none() {
                libc::kill(self.pid, libc::SIGKILL);
                libc::waitpid(self.pid, std::ptr::null_mut(), 0);
            }
            libc::close(self.pty);
        }
    }
}

#[test]
fn exit_status() {
    assert_eq!(Host::start(&["exit", "7", ""], 40, 10).wait(), 7);
}
#[test]
fn killed_child() {
    assert_eq!(Host::start(&["kill"], 40, 10).wait(), 143);
}
#[test]
fn missing_command() {
    // Answer nothing: granite times out on the host's replies after a second.
    assert_eq!(
        Host::spawn(&["/nonexistent/granite-test-command"], 40, 10, false).wait(),
        127
    );
}
#[test]
fn short_lived_output_is_drawn_before_exit() {
    for _ in 0..10 {
        let mut h = Host::start(&["exit", "0", "goodbye from the child"], 40, 10);
        assert_eq!(h.wait(), 0);
        assert!(contains(&h.output, b"goodbye from the child"));
    }
}
#[test]
fn ghostty_logs_stay_off_host_screen() {
    let mut h = Host::start(
        &[
            "exit",
            "0",
            "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\done",
        ],
        40,
        10,
    );
    assert_eq!(h.wait(), 0);
    assert!(contains(&h.output, b"done"));
    assert!(!contains(&h.output, b"kitty graphics"));
}
#[test]
fn synchronized_output_holds_drawing_until_it_ends() {
    let mut h = Host::start(&["hold"], 40, 10);
    h.wait_screen("held-1 held-2");
    let first = position(&h.output, b"held-1");
    let second = position(&h.output, b"held-2");
    assert!(!contains(&h.output[first..second], b"\x1b[?2026l"));
    assert!(h.first_seen("held-1") - h.first_seen("before") >= 450);
    h.send("q");
    assert_eq!(h.wait(), 0);
}
#[test]
fn synchronized_output_hold_times_out_after_a_second() {
    let mut h = Host::start(&["hold-forever"], 40, 10);
    h.wait_screen("start");
    h.wait_screen("stuck");
    let elapsed = h.first_seen("stuck") - h.first_seen("start");
    assert!((1000..2500).contains(&elapsed), "held for {elapsed}ms");
    h.send("q");
    assert_eq!(h.wait(), 0);
}
#[test]
fn frames_are_coalesced() {
    let mut h = Host::start(&["burst", "3000"], 40, 10);
    h.wait_screen("done");
    let elapsed = h.first_seen("done") - h.first_seen("line ");
    let begin = position(&h.output, b"line ");
    let frames = h.output[begin..]
        .windows(8)
        .filter(|s| *s == b"\x1b[?2026h")
        .count();
    assert!(frames as i64 <= elapsed / 16 + 2);
    assert_eq!(
        h.screen(),
        "line 2991\nline 2992\nline 2993\nline 2994\nline 2995\nline 2996\nline 2997\nline 2998\nline 2999\ndone"
    );
    h.send("q");
    assert_eq!(h.wait(), 0);
}
#[test]
fn resize_reaches_child_and_redraws_host() {
    let mut h = Host::start(&["size"], 40, 10);
    h.wait_screen("size 40x10");
    for (cols, rows) in [(60, 15), (30, 5)] {
        h.resize(cols, rows);
        let expected = format!("size {cols}x{rows}");
        h.wait_screen(&expected);
        assert_eq!(h.screen(), expected);
    }
    let before = h.output.len();
    assert_eq!(unsafe { libc::kill(h.pid, libc::SIGWINCH) }, 0);
    h.until(|h| contains(&h.output[before..], b"size 30x5"));
    h.pump(100);
    assert_eq!(h.screen(), "size 30x5");
    h.send("q");
    assert_eq!(h.wait(), 0);
}
#[test]
fn input_modes_are_mirrored_and_restored() {
    let mut h = Host::start(&["modes"], 40, 10);
    h.wait_screen("ready");
    for n in [1, 66, 1000, 1004, 1006, 2004] {
        assert!(h.mode(n), "mode {n}");
    }
    assert_eq!(h.kitty(), 1);
    assert_eq!(h.cursor_style(), CursorVisualStyle::Bar);
    h.send("a");
    h.wait_screen("got 97");
    h.send("q");
    assert_eq!(h.wait(), 0);
    for n in [1, 66, 1000, 1004, 1006, 2004, 1049] {
        assert!(!h.mode(n), "mode {n}");
    }
    assert!(h.mode(25));
    assert_eq!(h.kitty(), 0);
    assert_eq!(h.cursor_style(), CursorVisualStyle::Block);
}
// Unique per test, even with the test harness running tests in parallel.
struct TempPath(std::path::PathBuf);
impl TempPath {
    fn new(suffix: &str) -> Self {
        Self(std::env::temp_dir().join(format!("granite-live-{}.{suffix}", std::process::id())))
    }
    fn path(&self) -> &str {
        self.0.to_str().unwrap()
    }
    fn read(&self) -> Vec<u8> {
        std::fs::read(&self.0).unwrap()
    }
}
impl Drop for TempPath {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
#[test]
fn queries_are_answered() {
    let path = TempPath::new("replies");
    let mut h = Host::start(&["query", path.path()], 40, 10);
    assert_eq!(h.wait(), 0);
    let replies = path.read();
    let mut at = 0;
    for expected in [
        "\x1b]10;rgb:d0d0/d1d1/d2d2",
        "\x1b]11;rgb:1010/1111/1212",
        "\x1b]4;1;rgb:1111/f0f0/0a0a",
        "\x1b[3;5R",
        "\x1b[?2027;1$y",
        "\x1b[?62;22c",
    ] {
        assert!(
            contains(&replies[at..], expected.as_bytes()),
            "missing {expected:?} in {:?}",
            String::from_utf8_lossy(&replies)
        );
        at += position(&replies[at..], expected.as_bytes()) + expected.len();
    }
}
#[test]
fn split_routes_input_and_switches_focus_with_legacy_ctrl_bracket() {
    let mut h = Host::split(
        &["input", "left", "plain", "0"],
        &["input", "right", "plain", "0"],
        81,
        12,
    );
    h.wait_screen("left ready");
    h.wait_screen("right ready");
    h.send("a");
    h.wait_screen("left got 97");
    h.send("\x1db");
    h.wait_screen("right got 98");
    h.send("\x1dc");
    h.wait_screen("left got 99");
    for text in ["right got 97", "left got 98", "right got 99", "got 29"] {
        assert!(!contains(&h.output, text.as_bytes()));
    }
    h.finish_split();
}
#[test]
fn split_consumes_kitty_ctrl_bracket_press_repeat_and_release() {
    let mut h = Host::split(
        &["input", "left", "plain", "0"],
        &["input", "right", "plain", "0"],
        81,
        12,
    );
    h.wait_screen("left ready");
    h.wait_screen("right ready");
    h.send("\x1b[93;5u\x1b[93;5:2;93u\x1b[93;5:3u\x1b[97;1ua");
    h.wait_screen("right got 97");
    // Repeats and releases did not switch. The next press switches back.
    h.send("\x1b[93:93;5:1;93ub");
    h.wait_screen("left got 98");
    assert!(!contains(&h.output, b"left got 27"));
    assert!(contains(&h.output, b"right got 27")); // unrelated CSI-u forwarded unchanged
    h.finish_split();
}
#[test]
fn split_modes_cursor_title_and_focus_reports_follow_focus() {
    let mut h = Host::split(
        &["input", "left", "modes", "0"],
        &["input", "right", "plain", "0"],
        81,
        16,
    );
    h.wait_screen("left ready");
    h.wait_screen("right ready");
    h.until(|h| h.mode(2004) && h.kitty() == 1);
    assert_eq!(h.terminal.title().unwrap(), b"left");
    h.send("\x1d");
    h.wait_screen("left got 79"); // ESC [ O: focus out
    h.until(|h| !h.mode(2004) && h.kitty() == 0);
    for n in [1, 66, 1000, 1004, 1006, 2004] {
        assert!(!h.mode(n));
    }
    assert_eq!(h.cursor_style(), CursorVisualStyle::Block);
    assert_eq!(h.terminal.title().unwrap(), b"right");
    h.send("\x1d");
    h.wait_screen("left got 73"); // ESC [ I: focus in
    h.until(|h| h.mode(2004) && h.kitty() == 1);
    for n in [1, 66, 1000, 1004, 1006, 2004] {
        assert!(h.mode(n));
    }
    assert_eq!(h.cursor_style(), CursorVisualStyle::Bar);
    assert_eq!(h.terminal.title().unwrap(), b"left");
    h.finish_split();
}
#[test]
fn split_stays_alive_after_exit_and_returns_first_nonzero_status_in_pane_order() {
    let mut h = Host::split(
        &["exit", "7", "left final"],
        &["input", "right", "plain", "9"],
        81,
        12,
    );
    h.wait_screen("(exited 7)");
    h.wait_screen("left final");
    h.wait_screen("right ready");
    assert!(!h.eof);
    h.send("a");
    h.wait_screen("right got 97"); // automatic focus change
    h.send("q");
    assert_eq!(h.wait(), 7);
    let mut h = Host::split(
        &["input", "left", "plain", "0"],
        &["exit", "9", "right final"],
        81,
        12,
    );
    h.wait_screen("(exited 9)");
    h.wait_screen("right final");
    h.wait_screen("left ready");
    h.send("\x1da");
    h.wait_screen("left got 97"); // cannot focus exited pane
    h.send("q");
    assert_eq!(h.wait(), 9);
}
#[test]
fn split_resizes_each_child_and_preserves_divider() {
    let mut h = Host::split(&["size"], &["size"], 81, 12);
    h.until(|h| h.screen().matches("size 40x11").count() == 2);
    h.resize(100, 9);
    h.wait_screen("size 49x8");
    h.wait_screen("size 50x8");
    assert_eq!(h.screen().matches('│').count(), 9);
    h.finish_split();
}
#[test]
fn split_translates_sgr_mouse_and_drops_outside_focus_and_other_formats() {
    let path = TempPath::new("mouse");
    let mut h = Host::split(
        &["input", "left", "plain", "0"],
        &["input", "right", "plain", "0", path.path()],
        81,
        20,
    );
    h.wait_screen("left ready");
    h.wait_screen("right ready");
    h.send(b"\x1d\x1b[<0;43;4M\x1b[<0;43;4m\x1b[<0;1;4M\x1b[<0;43;1M\x1b[<0;41;4M\x1b[M !!\x1b[M \xc2!\x1b[32;43;4M!");
    h.wait_screen("right got 33");
    assert_eq!(path.read(), b"\x1b[<0;2;3M\x1b[<0;2;3m!");
    h.finish_split();
}
#[test]
fn split_renders_other_pane_during_synchronized_output_hold() {
    let mut h = Host::split(&["hold-forever"], &["input", "right", "plain", "0"], 81, 12);
    h.wait_screen("start");
    h.wait_screen("right ready");
    let deadline = now_ms() + 250;
    while now_ms() < deadline {
        h.pump(20);
    }
    h.send("\x1da");
    h.wait_screen("right got 97");
    assert!(!h.screen().contains("stuck"));
    h.wait_screen("stuck");
    h.finish_split();
}
#[test]
fn split_renders_wide_characters_at_each_panes_offset() {
    let mut h = Host::split(
        &["input", "界L", "plain", "0"],
        &["input", "界R", "plain", "0"],
        81,
        12,
    );
    h.wait_screen("界L ready");
    h.wait_screen("界R ready");
    assert_eq!(
        h.screen().lines().nth(1).unwrap(),
        "界L ready                               │界R ready"
    );
    assert_eq!(h.terminal.cursor_y().unwrap(), 1);
    assert_eq!(h.terminal.cursor_x().unwrap(), 9);
    h.send("\x1d");
    h.until(|h| h.terminal.cursor_x().unwrap() == 50);
    h.finish_split();
}
#[test]
fn three_panes_stack_right_side_and_cycle_focus() {
    let mut h = Host::panes(&[&["size"], &["size"], &["size"]], 81, 12);
    h.until(|h| {
        let text = h.screen();
        text.matches("size 40x11").count() == 1 && text.matches("size 40x5").count() == 2
    });
    let text = h.screen();
    let lines: Vec<_> = text.lines().collect();
    assert_eq!(
        lines[1],
        "size 40x11                              │size 40x5"
    );
    assert!(lines[6].starts_with("                                        │granite-test-child"));
    assert_eq!(
        lines[7],
        "                                        │size 40x5"
    );
    assert_eq!(text.matches('│').count(), 12);
    h.resize(100, 9);
    h.wait_screen("size 49x8");
    h.wait_screen("size 50x4");
    h.wait_screen("size 50x3");
    assert_eq!(h.screen().matches('│').count(), 9);
    h.send("q");
    h.wait_screen("(exited 0)");
    h.send("q");
    h.until(|h| h.screen().matches("(exited 0)").count() == 2);
    h.send("q");
    assert_eq!(h.wait(), 0);
}
#[test]
fn three_panes_route_input_in_focus_order_and_skip_exited_panes() {
    let path = TempPath::new("mouse3");
    let mut h = Host::panes(
        &[
            &["input", "left", "plain", "0"],
            &["input", "top", "plain", "5"],
            &["input", "bottom", "plain", "0", path.path()],
        ],
        81,
        12,
    );
    h.wait_screen("left ready");
    h.wait_screen("top ready");
    h.wait_screen("bottom ready");
    h.send("a\x1db\x1dc");
    h.wait_screen("left got 97");
    h.wait_screen("top got 98");
    h.wait_screen("bottom got 99");
    // Bottom starts on row 8, column 42. Reports in the top pane are dropped.
    h.send("\x1b[<0;43;10M\x1b[<0;43;4M");
    h.wait_screen("bottom got 77");
    h.send("\x1dd\x1dq");
    h.wait_screen("left got 100");
    h.wait_screen("(exited 5)");
    h.send("e");
    h.wait_screen("bottom got 101");
    for text in ["left got 98", "top got 97", "bottom got 98", "left got 101"] {
        assert!(!contains(&h.output, text.as_bytes()));
    }
    h.send("q");
    h.until(|h| h.screen().matches("(exited").count() == 2);
    h.send("q");
    assert_eq!(h.wait(), 5);
    assert_eq!(path.read(), b"c\x1b[<0;2;3Meq");
}
