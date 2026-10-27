# granite

A minimal terminal multiplexer written in Zig on Ghostty's `ghostty-vt`
module. The Zig version lives in `zig/`; a Rust port on
[libghostty-rs](https://github.com/Uzaaft/libghostty-rs) is in progress at
the top level. With no arguments it runs `claude` on the left, `codex` on the top
right, and `opencode` on the bottom right. Each program runs in its own pty and terminal; granite redraws only
the rows that changed.

```sh
./zig/zig-out/bin/granite                         # claude | codex over opencode
./zig/zig-out/bin/granite htop                    # one pane, no header or divider
./zig/zig-out/bin/granite claude :: codex         # two side-by-side commands
./zig/zig-out/bin/granite claude :: codex :: htop # left | top right over bottom right
./zig/zig-out/bin/granite sh -l :: htop           # arguments belong to each command
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
  draws what it has and the hold ends as if the program had ended it. (The
  Zig version waits up to a second from the latest hold, and draws nothing
  while it waits.)
- The focused pane controls the host title. Bells from any pane pass through.
- Resizing the host window resizes every pty and terminal.
- An exited pane keeps its last screen, and focus moves to the surviving
  program. Granite exits when all programs have exited, returning the first
  nonzero status in pane order, or zero. A single command keeps its exit status.
- Ghostty's log messages would land on the screen through stderr, so granite
  drops them, or appends them to the file named by `GRANITE_LOG`.

## Layout

- `zig/src/main.zig`: granite's pty and host terminal handling and event loop
- `zig/src/mux.zig`: the Ghostty terminal and the renderer that redraws the host
- `zig/src/record.zig`: `granite-record`, which records a program's output
- `zig/test/`: the round-trip and live tests
- `zig/vendor/ghostty`: Ghostty source, used as a path dependency
- `src/`: the Rust port
- `vendor/ghostty`: Ghostty source at the commit libghostty-rs pins, which
  `.cargo/config.toml` points the libghostty-vt build at
- `.toolchain/zig-aarch64-macos-0.17.0`: Zig 0.17, which Ghostty requires

## Build

```sh
make zig
```

`make zig` runs `zig build` in `zig/` with the bundled toolchain and
installs the binary at `zig/zig-out/bin/granite`. `make` runs `cargo build`
for the Rust port, which builds libghostty-vt with the same toolchain. If
the toolchain isn't in `.toolchain` yet, `make` downloads it from
ziglang.org and checks its SHA-256 first; `make toolchain` does only that
step. If a Ghostty checkout isn't there, `make` runs
`git submodule update --init` for it.

## Testing

```sh
make zig-test
```

`make zig-test` runs `zig build test` in `zig/`, which runs two test binaries.

The round-trip test (`zig/test/roundtrip.zig`) feeds program output to granite's
terminal and renderer without a pty. After each chunk of output, granite
renders a frame, the frame is fed to a second Ghostty terminal standing in
for the host, and the host's screen is compared with the program's: text
including grapheme clusters, wide characters, colors resolved to RGB,
attributes, the cursor, and the mirrored modes. A difference fails the test
with a cell-by-cell report. Each input runs with its original chunk
boundaries and with seeded random splits. The inputs are:

- the fixtures in `zig/test/fixtures.zig`
- streams from the fuzzer in `zig/test/fuzz.zig`; `-Dfuzz-iterations=N` and
  `-Dfuzz-seed=N` set how many and where the seeds start (300 from seed 1 by
  default)
- every `.rec` file in `zig/test/recordings`

Fixtures marked `known` cover differences granite doesn't resolve, and
pass while the difference remains.

The live test (`zig/test/live.zig`) runs granite in a pty with a scripted
program (`zig/test/child.zig`) inside it, and acts as the host terminal. It
covers mode 2026 holds and their timeout, frame coalescing, resizing,
mirroring and restoring input modes, query replies, input forwarding, and
exit status. Split-mode tests cover legacy and Kitty Ctrl-] focus switching,
focused modes, cursor and title, focus events, independent holds, per-pane
resizing, mouse coordinates, and programs exiting at different times. Three-pane
tests cover the stacked layout, focus order, and skipping exited panes.

### Recording

`granite-record` runs a program, passes its input and output through, and
writes the output to a file with each read as its own record, along with
the terminal size and every size change:

```sh
./zig/zig-out/bin/granite-record zig/test/recordings/claude.rec claude
```

Recordings in `zig/test/recordings` are replayed by the round-trip test.
