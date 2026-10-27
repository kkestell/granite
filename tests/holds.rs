//! Mode 2026 hold tests that drive the mux without a pty. The round-trip
//! suite skips frames while a pane is held, so it can't check what a held
//! pane draws.

use granite::mux::{HOLD_TIMEOUT_MS, Mux, Winsize, now_ms};

fn winsize(cols: u16, rows: u16, cell_px: u16) -> Winsize {
    Winsize { ws_col: cols, ws_row: rows, ws_xpixel: cols * cell_px, ws_ypixel: rows * cell_px * 2 }
}

fn frame(m: &mut Mux) -> String {
    m.render().unwrap();
    String::from_utf8(m.take_output()).unwrap()
}

#[test]
fn held_pane_draws_each_frame_completed_before_a_new_hold() {
    // Every read ends one hold and starts the next, so the pane is held
    // whenever granite draws, and the hold never lasts long enough to time out.
    let mut m = Mux::new(winsize(20, 4, 8), &["test"]).unwrap();
    m.panes[0].feed(b"\x1b[?2026h");
    frame(&mut m);
    for text in ["frame-1", "frame-2"] {
        m.panes[0].feed(format!("\x1b[H\x1b[2K{text}\x1b[?2026l\x1b[?2026hpartial").as_bytes());
        assert!(m.panes[0].held());
        assert!(m.needs_render());
        let out = frame(&mut m);
        assert!(out.contains(text), "{out:?}");
        assert!(!out.contains("partial"), "{out:?}");
    }
}

#[test]
fn timed_out_hold_ends_so_the_next_one_holds() {
    let mut m = Mux::new(winsize(20, 4, 8), &["test"]).unwrap();
    m.panes[0].feed(b"\x1b[?2026h");
    assert!(m.panes[0].held());
    m.expire_holds(now_ms() + HOLD_TIMEOUT_MS).unwrap();
    assert!(!m.panes[0].held());
    frame(&mut m);

    m.panes[0].feed(b"\x1b[?2026hpartial");
    assert!(m.panes[0].held());
    assert!(!frame(&mut m).contains("partial"));
}
