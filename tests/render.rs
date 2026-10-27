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
