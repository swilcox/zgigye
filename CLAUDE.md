# zgigye — z-machine v3 interpreter in Zig

## Commands

- `zig build test` — full suite (silent on success; cached, so unchanged reruns print nothing)
- `zig test src/root.zig` — same library tests with per-test output (run from repo root; doesn't cover tui_ui/main, which need the build graph for the vaxis import)
- `zig build coverage` — kcov line coverage; report at `zig-out/coverage/index.html`
- `zig build run -- stories/minizork.z3` — play (TUI on a terminal; `--plain` or piped = plain text)

## Architecture rules

- The core library (everything except `tui_ui.zig`/`main.zig`) must stay free of file/terminal access and of the vaxis dependency. All I/O goes through the `Ui` vtable in `src/ui.zig`; status-line data is passed structured, never preformatted.
- One module per spec concern; see the table in README.md. Opcode handlers live in one switch in `opcodes.zig`; `Machine.step` pre-advances the PC, so handlers only touch it for control flow.
- Version 3 only, on purpose. Don't add v4+ branches speculatively.

## Testing

- Oracle: `czech.z3` must report `Passed: 349, Failed: 0` (integration test asserts this). The reference implementation is `../yazm-py` (Python); compare against it when behavior is in question.
- Integration tests embed stories from `src/testdata/` via `@embedFile` and use `TextUi` over fixed/allocating streams. `Machine.steps_remaining` is set in tests so loops fail instead of hanging.
- Driving the TUI headlessly (expect/script): ptys default to 0×0 — set `stty rows 24 columns 80 < $spawn_out(slave,name)` — and reply `\x1b[0n` to vaxis's `\x1b[5n` query or shutdown blocks. Match single words; rendering interleaves escapes between words.

## Environment

- Zig 0.16: new `std.Io` API (`main(init: std.process.Init)`, explicit `io`). `Reader.takeDelimiter` consumes the newline; `takeDelimiterExclusive` does not. `std.BoundedArray` and `std.time.microTimestamp` are gone.
- Known gaps: Quetzal save/restore (opcodes branch false), sound, screen split, output streams.
