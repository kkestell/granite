//! granite: a terminal multiplexer on Ghostty's libghostty-vt. The `mux`
//! module holds the terminals and the renderer, and runs without ptys for
//! the round-trip tests; `recording` is the format `granite-record` writes.

pub mod mux;
pub mod recording;
pub mod winch;
