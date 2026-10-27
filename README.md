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
  modes the program enables (application cursor keys, mouse tracking, focus
  events, bracketed paste, Kitty keyboard flags) are mirrored onto the host
  terminal, so the host encodes input the way the program expects.
- Device attribute and size queries are answered through terminal effects,
  and the terminal writes its replies back to the pty.
- At startup granite asks the host for its default foreground and background
  colors and its 16 ANSI colors, so the program's color queries (OSC 10, 11,
  and 4) get the host's answers.
- Frames are wrapped in synchronized output and limited to about 60 per
  second. While the program holds rendering (mode 2026), drawing waits for
  up to one second.
- Window title changes and the bell are passed through to the host.
- Resizing the host window resizes the pty and the terminal.
- When the program exits, granite exits with the same status.

## Layout

- `src/main.zig`: granite
- `vendor/ghostty`: Ghostty source, used as a path dependency
- `.toolchain/zig-aarch64-macos-0.17.0`: Zig 0.17, which Ghostty requires

## Build

```sh
make
```

`make` runs `zig build` with the bundled toolchain and installs the binary
at `zig-out/bin/granite`.
