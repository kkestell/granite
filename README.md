# granite

A minimal terminal multiplexer written in Rust on Ghostty's libghostty-vt,
through [libghostty-rs](https://github.com/Uzaaft/libghostty-rs). With no
arguments it runs `claude` on the left, `codex` on the top right, and
`opencode` on the bottom right. Each program runs in its own pty and terminal; granite redraws only
the rows that changed.

```sh
./target/debug/granite                         # claude | codex over opencode
./target/debug/granite htop                    # one pane, no header or divider
./target/debug/granite claude :: codex         # two side-by-side commands
./target/debug/granite claude :: codex :: htop # left | top right over bottom right
./target/debug/granite sh -l :: htop           # arguments belong to each command
```

- In split mode, **Ctrl-]** moves focus to the next live pane: left, then
  top right, then bottom right. Each pane has a header row with its program
  and exit status, black on white for the focused pane and black on gray for
  the others. The left pane gets half the
  width, with a divider between it and the right side. With three commands,
  the right side is split into a top and a bottom pane, each with its own
  header row.
- Keyboard input goes to the focused pane. SGR cell-coordinate mouse reports are translated
  into its coordinates; reports outside that pane and other mouse formats
  are dropped in split mode. A single command receives all input unchanged.
- The focused program's input modes (application cursor keys and keypad,
  mouse tracking and formats, focus events, bracketed paste, Alt and
  backspace handling, Kitty keyboard flags) are mirrored onto the host
  terminal. Reverse video and grapheme clustering are mirrored too. Programs
  requesting focus events receive notifications when pane focus changes.
- Device attribute and size queries are answered through terminal effects,
  and the terminal writes its replies back to the pty.
- At startup granite asks the host for its default foreground and background
  colors and its 16 ANSI colors, so the program's color queries (OSC 10, 11,
  and 4) get the host's answers. It also asks whether the host clusters
  graphemes (mode 2027) and starts the terminal in the same mode, so both
  agree on character widths.
- Frames are wrapped in synchronized output and limited to about 60 per
  second. While a program holds rendering (mode 2026), its pane shows the
  last frame the program completed before the hold began; the other panes
  continue drawing. After a second without a completed frame, the pane
  draws what it has and the hold ends as if the program had ended it.
- The focused pane controls the host title. Bells from any pane pass through.
- Resizing the host window resizes every pty and terminal.
- An exited pane keeps its last screen, and focus moves to the surviving
  program. Granite exits when all programs have exited, returning the first
  nonzero status in pane order, or zero. A single command keeps its exit status.
- Ghostty's log messages would land on the screen through stderr, so granite
  drops them, or appends them to the file named by `GRANITE_LOG`.

## Layout

- `src/main.rs`: granite's pty and host terminal handling and event loop
- `src/mux.rs`: the Ghostty terminals and the renderer that redraws the host
- `src/recording.rs`: the recording format
- `src/bin/granite-record.rs`: `granite-record`, which records a program's
  output
- `src/bin/granite-test-child.rs`: the scripted program the live tests run
- `tests/`: the round-trip, hold, and live tests, and the recordings
- `vendor/ghostty`: Ghostty source at the commit libghostty-rs pins, which
  `.cargo/config.toml` points the libghostty-vt build at
- `.toolchain/zig-aarch64-macos-0.17.0`: Zig 0.17, which builds
  libghostty-vt

## Build

```sh
make
```

`make` runs `cargo build`, which builds libghostty-vt from `vendor/ghostty`
with the bundled Zig and puts the binaries in `target/debug`. If the
toolchain isn't in `.toolchain` yet, `make` downloads it from ziglang.org
and checks its SHA-256 first; `make toolchain` does only that step. If the
Ghostty checkout isn't there, `make` runs `git submodule update --init` for
it. Once both are in place, `cargo build` works directly, and
`cargo build --release` puts optimized binaries in `target/release`.

## Testing

```sh
make test
```

`make test` runs `cargo test`.

The round-trip test (`tests/roundtrip.rs`) feeds program output to granite's
terminal and renderer without a pty. After each chunk of output, granite
renders a frame, the frame is fed to a second Ghostty terminal standing in
for the host, and the host's screen is compared with the program's: text
including grapheme clusters, wide characters, colors resolved to RGB,
attributes, the cursor, and the mirrored modes. A difference fails the test
with a cell-by-cell report. Each input runs with its original chunk
boundaries and with seeded random splits. The inputs are:

- the fixtures in `tests/support/fixtures.rs`
- streams from the fuzzer in `tests/support/fuzz.rs`;
  `GRANITE_FUZZ_ITERATIONS` and `GRANITE_FUZZ_SEED` set how many and where
  the seeds start (300 from seed 1 by default)
- every `.rec` file in `tests/recordings`

Fixtures marked `known` cover differences granite doesn't resolve, and
pass while the difference remains.

The hold test (`tests/holds.rs`) checks what a pane draws while its program
holds rendering, and that a timed-out hold ends.

The live test (`tests/live.rs`) runs granite in a pty with a scripted
program (`src/bin/granite-test-child.rs`) inside it, and acts as the host
terminal. It covers mode 2026 holds and their timeout, frame coalescing,
resizing, mirroring and restoring input modes, query replies, input
forwarding, and exit status. Split-mode tests cover legacy and Kitty Ctrl-]
focus switching, focused modes, cursor and title, focus events, independent
holds, per-pane resizing, mouse coordinates, and programs exiting at
different times. Three-pane tests cover the stacked layout, focus order, and
skipping exited panes.

### Recording

`granite-record` runs a program, passes its input and output through, and
writes the output to a file with each read as its own record, along with
the terminal size and every size change:

```sh
./target/debug/granite-record tests/recordings/claude.rec claude
```

Recordings in `tests/recordings` are replayed by the round-trip test.
