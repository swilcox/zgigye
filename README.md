# zgigye

A z-machine interpreter in Zig, targeting version 3 (`.z3`) story files.

## Build and run

Requires Zig 0.16.

```sh
zig build                              # builds zig-out/bin/zgigye
zig build run -- stories/minizork.z3   # play a story (full-screen TUI)
zig build test                         # unit + integration tests
```

When attached to a terminal the interpreter runs a full-screen TUI (built
on [libvaxis](https://github.com/rockorager/libvaxis)): a title bar with
the story name and live status (location, score/moves or time), a
word-wrapped scrolling transcript (PgUp/PgDn), an input line, and a footer
with key hints. With `--plain`, or whenever stdin/stdout is not a
terminal, it falls back to plain text — so piping commands in keeps
working.

## Architecture

The core never touches files or terminals; everything flows through small,
testable layers:

| File | Responsibility |
|------|----------------|
| `src/memory.zig` | Byte-addressed memory, big-endian words, dynamic/static write guard |
| `src/header.zig` | Story file header parsing |
| `src/zscii.zig` | Z-string decoding and dictionary-word encoding (spec ch. 3) |
| `src/instruction.zig` | Side-effect-free instruction decoder (spec ch. 4) |
| `src/objects.zig` | Object tree, attributes, properties (spec ch. 12) |
| `src/dictionary.zig` | Dictionary lookup and input tokenisation (spec ch. 13) |
| `src/machine.zig` | Call frames, evaluation stack, variables, the run loop |
| `src/opcodes.zig` | The v3 instruction set, one switch (spec ch. 14-15) |
| `src/ui.zig` | The frontend interface (`Ui` vtable) |
| `src/text_ui.zig` | Plain-text frontend over any `std.Io` reader/writer pair |
| `src/tui_ui.zig` | Full-screen libvaxis frontend (exe only, not in the library) |
| `src/main.zig` | CLI entry point; picks the frontend and wires it up |

### Pluggable frontends

`Ui` is a vtable interface with three operations: `print`, `readLine`, and
`showStatus`. Status-line data is passed structured (location object name
plus score/turns or time), so each frontend renders it natively. Two
implementations exist: `TextUi` (plain text over generic `std.Io` streams,
used for piped play and all tests) and `TuiUi` (full-screen libvaxis).
The core library has no dependency on libvaxis; only the executable does.

### Testing

Every module carries unit tests. Integration tests in
`src/integration_test.zig` run real stories embedded from `src/testdata/`:

- `czech.z3` — the Comprehensive Z-machine Emulation CHecker; runs with no
  input and must report `Passed: 349, Failed: 0`.
- `minizork.z3` — a scripted play session exercising `sread`,
  tokenisation, and the parser.

Line coverage (requires `brew install kcov`):

```sh
zig build coverage
open zig-out/coverage/index.html   # per-file, per-line HTML report
```

The totals are also machine-readable in
`zig-out/coverage/*/coverage.json`. Coverage measures the core library's
test run; the libvaxis frontend is excluded.

## Not yet implemented

- Save/restore (Quetzal) — the save/restore opcodes currently branch as
  failed.
- Versions other than 3.
- Sound, screen splitting, and output streams beyond the main window.
