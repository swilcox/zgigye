# Story files

Two version-3 story files ship with this repository. They are *not* covered
by zgigye's MIT license — they are games, with their own terms, recorded
here so the distinction is explicit.

Byte-identical copies live in `src/testdata/`, where the integration tests
pull them in via `@embedFile`; the copies here are the ones you play with
`zig build run`.

## czech.z3

The **C**omprehensive **Z**-machine **E**mulation **CH**ecker, by Amir
Karger and Evin Robertson. A conformance suite rather than a game: it runs
with no input and prints a pass/fail count for each part of the z-machine
specification it exercises. Freely distributable, and distributed for
exactly this purpose — it is the project's oracle, and
`src/integration_test.zig` asserts it reports `Passed: 349, Failed: 0`.

Upstream: <https://www.ifarchive.org/indexes/if-archive/infocom/interpreters/tools/>

## minizork.z3

**MINI-ZORK I: The Great Underground Empire**, release 34 / serial 871124.
Copyright © 1988 Infocom, Inc.; the Infocom catalogue is now held by
Activision. ZORK is a registered trademark.

This is a commercial game, not free software. It was given away with
*Computer & Video Games* magazine in 1988 as a cut-down promotional version
of Zork I, and has circulated freely since, but no rightsholder has ever
released it under a license — its status here is "widely distributed", not
"permitted". It is included because it is the standard v3 story for
exercising a parser, and the demo at
[swilcox.github.io/zgigye](https://swilcox.github.io/zgigye/) serves it.

If Activision would rather it were not distributed here, open an issue and
it will be removed; the interpreter runs any v3 story file, and the test
suite's real oracle is czech.z3.
