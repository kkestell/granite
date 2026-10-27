//! granite: a terminal multiplexer on Ghostty's libghostty-vt. The Rust port
//! of the Zig version in `zig/` is in progress.

use libghostty_vt::Terminal;

fn main() -> Result<(), libghostty_vt::Error> {
    let mut terminal = Terminal::new(80, 24)?;
    terminal.vt_write(b"granite\r\n");
    Ok(())
}
