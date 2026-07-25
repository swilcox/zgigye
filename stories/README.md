# Story files

Two version-3 story files ship with this repository. Neither is part of
zgigye — they are separate works with their own terms, recorded here so the
distinction is explicit.

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

## zork1.z3

**ZORK I: The Great Underground Empire**, release 119 / serial 880429.
ZORK is a registered trademark; the Infocom catalogue passed to Activision
and, with it, to Microsoft.

**MIT-licensed.** The rightsholder published Zork I's original ZIL source
*and its compiled story file* in the
[`historicalsource/zork1`](https://github.com/historicalsource/zork1)
repository, under an MIT `LICENSE` at the repository root. This is that
file — `COMPILED/zork1.z3`, byte-identical, git blob
`e447402828441d44375b2b067befcd0ef02b37b7`:

```sh
git hash-object stories/zork1.z3
curl -s https://api.github.com/repos/historicalsource/zork1/contents/COMPILED/zork1.z3 \
  | grep '"sha"'
```

Zork II and Zork III are published the same way, and the interpreter runs
any v3 story file, so either can be dropped in beside this one.

This replaced `minizork.z3`, which had shipped here previously. Mini-Zork
was a 1988 promotional cut-down of Zork I that circulated widely but was
never released under any license — "widely distributed" rather than
"permitted". Everything a repository ships should have terms someone can
point at, and now it does.

The demo at [swilcox.github.io/zgigye](https://swilcox.github.io/zgigye/)
serves this file, and `src/integration_test.zig` plays a scripted session
of it against a golden transcript.
