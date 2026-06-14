# zgigye — z-machine v3 interpreter in Zig

## Commands

- `zig build test` — full suite (silent on success; cached, so unchanged reruns print nothing)
- `zig test src/root.zig` — same library tests with per-test output (run from repo root; doesn't cover tui_ui/main, which need the build graph for the vaxis import)
- `zig build coverage` — kcov line coverage; report at `zig-out/coverage/index.html`
- `zig build run -- stories/minizork.z3` — play (TUI on a terminal; `--plain` or piped = plain text; `--no-highlight-location`/`--no-highlight-keywords` disable transcript styling; `--theme name` picks a colour theme, `default`, `mono`, or `c64`)
- `zig build serve -- stories/minizork.z3` — demo web frontend on http://127.0.0.1:8080 (`--port N` to change); stateless, the state blob round-trips through the client
- `zig build wasm` — builds the WebAssembly module at `zig-out/bin/zgigye.wasm`; `zig build web` stages it with `src/web/wasm.html` (as `index.html`) and a story under `zig-out/web/`, ready for any static file server (`cd zig-out/web && python3 -m http.server`)

## Architecture rules

- The core library (everything except `tui_ui.zig`/`main.zig`/`serve.zig`/`wasm.zig`) must stay free of file/terminal/network access and of the vaxis dependency. All I/O goes through the `Ui` vtable in `src/ui.zig`; status-line data is passed structured, never preformatted. `wasm.zig` is the browser frontend: a `wasm32-freestanding` reactor (no `main`; `build.zig` sets `entry=.disabled`, `rdynamic=true`) that drives `session.zig` and exports one call per turn (`alloc`/`dealloc`/`setStory`/`start`/`advance`/`resultLen`), returning the same JSON as `serve.zig`. Strings cross the JS boundary as (ptr, len) into linear memory. Because a module is tied to one target, `build.zig` compiles a separate wasm-targeted copy of the core for it rather than reusing the host module.
- Suspend/resume: a non-blocking `Ui.readLine` returns `error.InputPending`; the sread handler rewinds the PC so the read re-executes on resume. `Machine.saveState`/`loadState` (format in `state.zig`) snapshot all mutable state; `loadState` treats blobs as untrusted and validates everything. `session.zig` is the pure turn-at-a-time wrapper.
- Highlighting: decided at print time, matching the yazm-py reference. The `print_obj` opcode routes through `Machine.printObjectName` → `Ui.printObject(text, is_location)` (`is_location` = obj == global 0), so only names the game prints *as objects* are marked — never words that merely appear in prose. Frontends collect the marks over a turn: the TUI records bold/italic marks in transcript offsets as `printObject` fires; the web/session path records `highlight.Mark`s and builds plain/location/keyword spans via `highlight.spansFromMarks`, rendered with CSS classes. `highlight.zig` is just the span model (no story scanning). TUI colours/attributes live in `theme.zig` (exe-only, a `vaxis.Style` per element: body/title/footer/prompt/location/keyword, where `body` fills the screen background and colours plain text); `Options.theme` selects it, `--theme name` on the CLI. The web pages (`src/web/index.html` for `serve`, `src/web/wasm.html` for the wasm build) mirror the same three themes as CSS variables and tuck the highlight checkboxes and theme picker behind a gear icon, persisted in localStorage.
- One module per spec concern; see the table in README.md. Opcode handlers live in one switch in `opcodes.zig`; `Machine.step` pre-advances the PC, so handlers only touch it for control flow.
- Debug commands: input lines starting with `$` are intercepted in `Machine.readInput` (before tokenising) and dispatched to `debug.zig`, which inspects state read-only and writes a report through the `Ui`. They never mutate the machine or advance the turn, so every frontend (TUI, plain text, HTTP, wasm) gets them for free. `$you` finds the player by short-name heuristic (`you`/`cretin`/…).
- Version 3 only, on purpose. Don't add v4+ branches speculatively.

## Testing

- Oracle: `czech.z3` must report `Passed: 349, Failed: 0` (integration test asserts this). The reference implementation is `../yazm-py` (Python); compare against it when behavior is in question.
- Integration tests embed stories from `src/testdata/` via `@embedFile` and use `TextUi` over fixed/allocating streams. `Machine.steps_remaining` is set in tests so loops fail instead of hanging.
- Driving the TUI headlessly (expect/script): ptys default to 0×0 — set `stty rows 24 columns 80 < $spawn_out(slave,name)` — and reply `\x1b[0n` to vaxis's `\x1b[5n` query or shutdown blocks. Match single words; rendering interleaves escapes between words.

## Environment

- Zig 0.16: new `std.Io` API (`main(init: std.process.Init)`, explicit `io`). `Reader.takeDelimiter` consumes the newline; `takeDelimiterExclusive` does not. `std.BoundedArray` and `std.time.microTimestamp` are gone.
- Known gaps: in-band Quetzal save/restore (the opcodes branch false; out-of-band snapshots in `state.zig` cover the web case), sound, screen split, output streams.
