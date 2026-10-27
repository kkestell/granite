//! Rendering tests that drive the mux without a pty.

use granite::mux::{Mux, Winsize};

fn winsize(cols: u16, rows: u16, cell_px: u16) -> Winsize {
    Winsize { ws_col: cols, ws_row: rows, ws_xpixel: cols * cell_px, ws_ypixel: rows * cell_px * 2 }
}

fn frame(m: &mut Mux) -> String {
    m.render().unwrap();
    String::from_utf8(m.take_output()).unwrap()
}

#[test]
fn full_repaint_keeps_a_mark_that_arrived_in_its_own_read() {
    // Without grapheme clustering, a combining mark at the start of a read
    // attaches to the previous cell without dirtying its row.
    let mut m = Mux::new(winsize(10, 4, 8), &["test"]).unwrap();
    m.panes[0].feed(b"e");
    frame(&mut m);
    m.panes[0].feed("\u{301}".as_bytes());
    assert!(frame(&mut m).contains("e\u{301}"));

    // A pixel-only resize keeps the grid and repaints every row.
    m.resize(winsize(10, 4, 9)).unwrap();
    assert!(frame(&mut m).contains("e\u{301}"));
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
