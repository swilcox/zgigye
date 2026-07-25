# zgigye — z-machine v3 interpreter in Zig

Instructions for coding agents — the layout, the invariants, and what the
code cannot tell you. Meant to be enough on its own; the README is for
people evaluating the project, not working on it.

Requires Zig 0.16.

## Commands

- `zig build test` — full suite. Silent on success, and cached, so an
  unchanged rerun prints nothing.
- `zig test src/root.zig` — same library tests with per-test output. Run
  from the repo root; skips `tui_ui.zig`/`main.zig`, which need the build
  graph for vaxis.
- `zig fmt --check build.zig src/*.zig` — CI runs this; keep it clean.
- `zig build run -- stories/zork1.z3` — play. TUI on a terminal, plain
  text when piped or given `--plain`. Also `--theme <default|mono|c64>`,
  `--no-highlight-location`, `--no-highlight-keywords`.
- `zig build serve -- stories/zork1.z3` — HTTP demo on port 8080
  (`--port N`).
- `zig build wasm` / `zig build web` — the module, and the browser demo
  staged under `zig-out/web/` for any static file server.
- `zig build coverage` — kcov report at `zig-out/coverage/index.html`.

## Layout

One module per spec concern, all under `src/`. The core library is
everything except `tui_ui.zig`, `theme.zig`, `main.zig`, `serve.zig` and
`wasm.zig`.

| File | Responsibility |
|------|----------------|
| `memory.zig` | Byte-addressed memory, big-endian words, dynamic/static write guard |
| `header.zig` | Story header parsing and validation |
| `zscii.zig` | Z-string decoding, dictionary-word encoding (spec ch. 3) |
| `instruction.zig` | Side-effect-free instruction decoder (spec ch. 4) |
| `objects.zig` | Object tree, attributes, properties (spec ch. 12) |
| `dictionary.zig` | Dictionary lookup and input tokenisation (spec ch. 13) |
| `machine.zig` | Call frames, evaluation stack, variables, the run loop |
| `opcodes.zig` | The v3 instruction set, one switch (spec ch. 14-15) |
| `ui.zig` | The frontend interface: `Ui` vtable and `Ui.Error` |
| `highlight.zig` | Span model for object-name highlighting |
| `debug.zig` | `$`-prefixed commands that inspect machine state |
| `state.zig` | Out-of-band machine-state snapshots (byte blobs) |
| `session.zig` | Suspend-at-input/resume driver for non-blocking frontends |
| `turn_json.zig` | The JSON wire format for a turn, shared by both web frontends |
| `text_ui.zig` | Plain-text frontend over any `std.Io` reader/writer pair |
| `tui_ui.zig` | Full-screen libvaxis frontend (exe only) |
| `theme.zig` | TUI colour themes, a `vaxis.Style` per element (exe only) |
| `main.zig` | CLI entry point; picks the frontend |
| `serve.zig` | HTTP frontend, one request per turn (exe only) |
| `wasm.zig` | WebAssembly frontend, one exported call per turn (exe only) |
| `root.zig` | Library entry point: the public API, and the test aggregator |
| `integration_test.zig` | Whole-machine tests against real story files |
| `fuzz_test.zig` | Malformed-input fuzz targets and their seeded driver |
| `test_machine.zig` | Test fixture: a machine over a synthetic story, plus an assembler |
| `web/page.html` | The play page, shared by both web frontends |

## Architecture rules

- **The core library touches no files, terminals or sockets**, and does not
  depend on vaxis. All I/O goes through the `Ui` vtable in `ui.zig`;
  status-line data is passed structured, never preformatted.
- **Story files and state blobs are untrusted input**: a malformed one must
  come back as an error, never a panic. `Header.parse` checks every address
  against the file length (so `static_memory` can bound writes safely);
  `Instruction.decode` rejects unknown opcodes, short operand lists
  (`minOperands`) and out-of-range branch targets; the object table rejects
  numbers above 255 and bounds its sibling walks. Handlers index operands
  positionally, so anything that would make that unsound belongs in the
  decoder, next to the store/branch checks — not in `opcodes.zig`.
- **Suspend/resume**: a non-blocking `Ui.readLine` returns
  `error.InputPending` and the sread handler rewinds the PC, so the read
  re-executes on resume. `Machine.saveState`/`loadState` (format in
  `state.zig`) snapshot all mutable state; `loadState` validates
  everything; `session.zig` is the turn-at-a-time wrapper. `Ui.Error` is an
  explicit set rather than `anyerror` so that contract is compiler-checked;
  frontends map their library's errors onto it (see `TuiUi.uiError`).
- **Highlighting is decided at print time.** `print_obj` routes through
  `Machine.printObjectName` → `Ui.printObject(text, is_location)`, so only
  names the game prints *as objects* are marked, never a word that merely
  appears in prose. `highlight.zig` is only the span model; it never scans
  the story.
- **The two web frontends differ only in transport.** `turn_json.zig` owns
  the JSON, so both emit identical bytes. `web/page.html` is the one page;
  the only file that differs is the one served as `transport.js`. Anything
  that would otherwise need changing in both belongs in the shared file.
- `Machine.step` pre-advances the PC, so opcode handlers only touch it for
  control flow.
- Debug commands: lines starting with `$` are intercepted in
  `Machine.readInput` before tokenising and dispatched to `debug.zig`,
  which is read-only and never advances the turn, so every frontend gets
  them for free.
- **Version 3 only, on purpose.** Do not add v4+ branches speculatively.

## Testing

- **Oracle**: `czech.z3` must report `Passed: 349, Failed: 0`; an
  integration test asserts it. The reference implementation is `../yazm-py`
  (Python); compare against it when behaviour is in question.
- Integration tests embed stories from `src/testdata/` via `@embedFile` and
  drive `TextUi` over fixed/allocating streams. Set
  `Machine.steps_remaining` so a runaway loop fails instead of hanging.
- `test_machine.zig` is the fixture for per-opcode tests: a machine over a
  *synthetic* story, so tests own every byte they touch — patching code
  into a real story lands in whatever table is there (czech's abbreviations
  start at 0x46). Use its `Asm` builder; hand-written bytes belong in
  `instruction.zig`, where the encoding is the subject.
- The Zork I golden transcript (`testdata/zork1_transcript.txt`, from
  `zork1_script.txt`) is compared byte-for-byte and the run is
  deterministic. After an intentional change, check the diff, then
  regenerate:
  `zig build && ./zig-out/bin/zgigye --plain stories/zork1.z3 < src/testdata/zork1_script.txt > src/testdata/zork1_transcript.txt`
- `fuzz_test.zig` holds the malformed-input targets. `zig build test
  --fuzz` is coverage-guided but does not compile on Zig 0.16.0 — the
  compiler's own `test_runner.zig:566` has a `StackTrace` type error in its
  fuzz-only branch — so a seeded driver runs the same targets over 2,000
  pseudo-random inputs each on every `zig build test`. To search harder,
  raise `seeded_iterations` and change the two PRNG seeds.
- Driving the TUI headlessly (expect/script): ptys default to 0×0, so set
  `stty rows 24 columns 80 < $spawn_out(slave,name)`, and reply `\x1b[0n`
  to vaxis's `\x1b[5n` query or shutdown blocks. Match single words;
  rendering interleaves escapes between them.

## CI

`.github/workflows/ci.yml` runs the format check, the suite, and a build of
every frontend on Linux and macOS. `pages.yml` calls it and depends on it,
so pushes to main are tested through the deploy gate rather than by a
second direct run — which is why ci.yml does not trigger on push to main
itself. Adding a build target means adding it there too.

## Environment

- Zig 0.16: the new `std.Io` API (`main(init: std.process.Init)`, explicit
  `io`). `Reader.takeDelimiter` consumes the newline;
  `takeDelimiterExclusive` does not. `std.BoundedArray` and
  `std.time.microTimestamp` are gone.
- Known gaps, all deliberate: in-band Quetzal save/restore (the opcodes
  branch false; `state.zig`'s out-of-band snapshots cover the web case),
  sound, screen splitting, and output streams beyond the main window.
