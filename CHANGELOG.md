# Changelog

Notable changes to zgigye. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is 0, the library API may change in any minor
release.

## [Unreleased]

### Changed

- The bundled play/demo story is now **Zork I** (release 119 / serial
  880429) instead of Mini-Zork, so every file in the repository is
  redistributable under a license someone can point at. The Zork I story
  file is published by the rightsholder under MIT in
  `historicalsource/zork1`; Mini-Zork was never licensed at all. See
  [stories/README.md](stories/README.md). `minizork.z3` is gone from
  `stories/` and `src/testdata/`, the golden transcript is regenerated
  from a Zork I playthrough (`src/testdata/zork1_script.txt`,
  `zork1_transcript.txt`), and the wasm demo now fetches `zork1.z3`.

### Fixed

- `zig build serve`: a POST to an unrouted path with no body headers (a
  bare `curl -X POST`) crashed the server on an assert inside std.http's
  `discardBody`. The 404 path now settles the request body first, as the
  routed handlers already did.

## [0.1.0] — 2026-07-25

First tagged release. Everything before this point was untagged
development; there is no earlier version to compare against, so this entry
describes what the release contains rather than what changed.

### The interpreter

- A complete z-machine version 3 interpreter: memory, the object table,
  the dictionary and tokeniser, ZSCII text, the instruction decoder, and
  the v3 instruction set.
- Passes the czech conformance suite (`Passed: 349, Failed: 0`), asserted
  by the test suite on every run.
- Version 3 only, by design.

### Frontends

All I/O goes through the `Ui` vtable; the core library touches no files,
terminals or sockets, and has no third-party dependencies.

- **TUI** (`zig build run`) — full-screen, built on libvaxis: title bar
  with live status, word-wrapped scrolling transcript, key hints. Colour
  themes via `--theme` (`default`, `mono`, `c64`).
- **Plain text** — automatic when stdin/stdout is not a terminal, or with
  `--plain`, so piping commands in works.
- **HTTP demo** (`zig build serve`) — stateless; the machine-state blob
  round-trips through the client.
- **WebAssembly** (`zig build web`) — the whole interpreter in the
  browser, no server. Deployed at
  [swilcox.github.io/zgigye](https://swilcox.github.io/zgigye/).

The web frontends share one page and one JSON format; only the transport
differs. The page adds a web-only `tufte` theme.

### Features

- Object-name highlighting decided at print time, so only names the game
  prints *as objects* are marked — never a word that merely appears in
  prose.
- Out-of-band state snapshots (`state.zig`) and a turn-at-a-time session
  API, which is what lets a frontend suspend at an input prompt and resume
  in a different process.
- `$`-prefixed debug commands (`$tree`, `$room`, `$dump`, `$header`, …)
  available in every frontend.

### Robustness

Story files and state blobs are treated as untrusted: a malformed one
returns an error rather than crashing the interpreter. Header addresses,
instruction encodings, object numbers and state blobs are all validated,
and `src/fuzz_test.zig` carries fuzz targets for both inputs plus a seeded
driver that runs on every test.

### Not implemented

- In-band save/restore (Quetzal) — the `save`/`restore` opcodes branch as
  failed. Out-of-band snapshots cover the web case.
- Versions other than 3.
- Sound, screen splitting, and output streams beyond the main window.

[0.1.0]: https://github.com/swilcox/zgigye/releases/tag/v0.1.0
