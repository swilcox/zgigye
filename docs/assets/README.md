# Brand assets

The marks for zgigye, plus the README screenshots. Part of the repository,
so MIT like the rest of it.

<img src="brandmark.svg" alt="" width="88" height="88">
<img src="brandmark-mono.svg" alt="" width="88" height="88">

| File | Size | Use it for |
| ---- | ---- | ---------- |
| `brandmark.svg` | 1024×1024 | The default. A self-contained tile — it carries its own dark background, so it reads on any page in either colour scheme. README header, favicon, avatars, social preview. |
| `brandmark-mono.svg` | 1024×1024 | Single-colour contexts and small sizes: black tile, white glyphs, no corner brackets or memory cells to muddy at 16px. |
| `wordmark.svg` | 1500×500 | The horizontal lockup — icon tile, 기계, and ZGIGYE under a red rule. For a banner or a slide where the full name has to be legible at a glance. **Assumes a light background** (see below). |

The marks say the same thing the name does: a geometric **Z** beside 기계,
over a rail of memory cells with a read head at each end — an interpreter
walking a story file.

## Palette

| Swatch | Hex | Role |
| ------ | --- | ---- |
| Ink | `#111820` | Tile background, wordmark glyphs |
| Red | `#C95248` | The Z, the read heads, the wordmark's rule |
| Cream | `#F2E9D8` | 기계, the memory cells |
| Slate | `#33424D` | Corner brackets, the rail, ZGIGYE |

The red and cream are the same pair the web frontend's `tufte` theme uses
for object names and page, which is why the mark and the demo look related.

## The wordmark needs a light background

`wordmark.svg` draws 기계 in ink (`#111820`) on transparency, so it
disappears against a dark page — including GitHub in dark mode, which is why
the README header uses the brandmark instead. Two ways out if the wordmark
is wanted there: add a light-on-dark variant and pair them with
`<picture media="(prefers-color-scheme: dark)">`, or give the file an opaque
cream background of its own. Neither exists yet.

## Where they are used

- `README.md` — the brandmark at the top.
- The web frontends' favicon. `src/web/page.html` links `brandmark.svg`;
  `serve.zig` embeds it through a named import (it lives outside the module,
  so a relative `@embedFile` path cannot reach it) and serves it at
  `/brandmark.svg`, and `zig build web` stages the same file next to the
  page. Changing the file changes both frontends.

Not set from here: the repository's social preview image, which is a GitHub
setting rather than a file in the tree — upload a PNG export of the
brandmark under Settings → General → Social preview.

## Screenshots

`screenshot.png` is the TUI under the default theme, `screenshot_web.png`
the browser frontend under `tufte`, both playing Zork I. They are hand-taken
terminal and browser captures; after a change that alters what they show,
retake them rather than editing them.
