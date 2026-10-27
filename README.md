# granite

A minimal terminal multiplexer with one window and one pane, written in Zig
on Ghostty's `ghostty-vt` module. It runs a program (`claude` by default) in
a pty, feeds the program's output into a Ghostty terminal, and redraws the
host terminal from the render state, drawing only the rows that changed.

```sh
./zig-out/bin/granite            # runs claude
./zig-out/bin/granite htop       # runs any other program
```

- Keyboard and mouse input is forwarded to the program unchanged. The input
  modes the program enables (application cursor keys and keypad, mouse
  tracking and formats, focus events, bracketed paste, Alt and backspace
  handling, Kitty keyboard flags) are mirrored onto the host terminal, so
  the host encodes input the way the program expects. Reverse video and
  grapheme clustering are mirrored too, so the host draws the screen the
  way the program sees it.
- Device attribute and size queries are answered through terminal effects,
  and the terminal writes its replies back to the pty.
- At startup granite asks the host for its default foreground and background
  colors and its 16 ANSI colors, so the program's color queries (OSC 10, 11,
  and 4) get the host's answers. It also asks whether the host clusters
  graphemes (mode 2027) and starts the terminal in the same mode, so both
  agree on character widths.
- Frames are wrapped in synchronized output and limited to about 60 per
  second. While the program holds rendering (mode 2026), drawing waits for
  up to one second.
- Window title changes and the bell are passed through to the host.
- Resizing the host window resizes the pty and the terminal.
- When the program exits, granite exits with the same status.

## Layout

- `src/main.zig`: granite's pty and host terminal handling and event loop
- `src/mux.zig`: the Ghostty terminal and the renderer that redraws the host
- `src/record.zig`: `granite-record`, which records a program's output
- `test/`: the round-trip and live tests
- `vendor/ghostty`: Ghostty source, used as a path dependency
- `.toolchain/zig-aarch64-macos-0.17.0`: Zig 0.17, which Ghostty requires

## Build

```sh
make
```

`make` runs `zig build` with the bundled toolchain and installs the binary
at `zig-out/bin/granite`.

## Testing

```sh
make test
```

`make test` runs `zig build test`, which runs two test binaries.

The round-trip test (`test/roundtrip.zig`) feeds program output to granite's
terminal and renderer without a pty. After each chunk of output, granite
renders a frame, the frame is fed to a second Ghostty terminal standing in
for the host, and the host's screen is compared with the program's: text
including grapheme clusters, wide characters, colors resolved to RGB,
attributes, the cursor, and the mirrored modes. A difference fails the test
with a cell-by-cell report. Each input runs with its original chunk
boundaries and with seeded random splits. The inputs are:

- the fixtures in `test/fixtures.zig`
- streams from the fuzzer in `test/fuzz.zig`; `-Dfuzz-iterations=N` and
  `-Dfuzz-seed=N` set how many and where the seeds start (300 from seed 1 by
  default)
- every `.rec` file in `test/recordings`

Fixtures marked `known` cover differences granite doesn't resolve, and
pass while the difference remains.

The live test (`test/live.zig`) runs granite in a pty with a scripted
program (`test/child.zig`) inside it, and acts as the host terminal. It
covers mode 2026 holds and their timeout, frame coalescing, resizing,
mirroring and restoring input modes, query replies, input forwarding, and
exit status.

### Recording

`granite-record` runs a program, passes its input and output through, and
writes the output to a file with each read as its own record, along with
the terminal size and every size change:

```sh
./zig-out/bin/granite-record test/recordings/claude.rec claude
```

Recordings in `test/recordings` are replayed by the round-trip test.
