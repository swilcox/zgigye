# Brand assets

The marks for zgigye, plus the README screenshots. Part of the repository,
so MIT like the rest of it.

<img src="brandmark.svg" alt="" width="88" height="88">
<img src="brandmark-mono.svg" alt="" width="88" height="88">

| File | Size | Use it for |
| ---- | ---- | ---------- |
| `brandmark.svg` | 1024×1024 | The default. A self-contained tile — it carries its own dark ground, so it reads on any page in either colour scheme. README header, favicon, avatars, social preview. |
| `brandmark-mono.svg` | 1024×1024 | Single-colour contexts and anything below about 32px: black tile, white Z, no steps to muddy at 16px. |
| `wordmark.svg` | 973×480 | The horizontal lockup — the mark, 기계, and ZGIGYE under a red rule. For a banner or a slide where the full name has to be legible at a glance. Carries its own ground too, so it goes anywhere the brandmark goes. |

The mark is a **Z built out of the transcript it is reading**: two full lines
of prose in cream, top and bottom, with a red stair of six steps descending
between them. Read it at a glance and it is the letter Z; read it slowly and
it is an interpreter walking a story file one line at a time. The steps
overlap by two thirds of their width, which is what welds the staircase into
a single diagonal instead of leaving it a column of dashes.

The name's other half is not in the brandmark on purpose. Carrying **Z** and
기계 and a memory rail at once left nothing legible below 32px, so the icon
keeps the Z and the wordmark carries 기계.

## Palette

| Swatch | Hex | Role |
| ------ | --- | ---- |
| Ink | `#111820` | Tile and panel ground |
| Red | `#C95248` | The descending stair, the wordmark's rule |
| Cream | `#F2E9D8` | The two transcript lines, 기계, ZGIGYE |
| Slate | `#33424D` | The silhouette ring |

The red and cream are the same pair the web frontend's `tufte` theme uses
for object names and page, which is why the mark and the demo look related.

## The ring is load-bearing

Both the brandmark and the wordmark draw a slate ring just inside their
edge. It is not a border for its own sake: the ground is `#111820` and
GitHub's dark mode is `#0d1117`, close enough that without the ring the
silhouette dissolves into the page. On light grounds it is nearly invisible,
which is the point — it only shows up where it is needed.

This is also what retired the old caveat that the wordmark could not be used
on a dark page. It now carries an opaque ground of its own, so no
light-on-dark variant or `<picture>` pairing is required.

## Why the mono variant is a different Z

`brandmark-mono.svg` is not the brandmark recoloured — it closes the stair
up into one solid stroke. Rendered side by side at 16px the stepped Z is
legible but soft while the solid one stays crisp, and that difference is the
whole reason the file exists. It occupies the identical bounding box,
`(130,128)`–`(382,384)` in the 512 viewBox, so the two sit at matching
optical size when they appear near each other.

## Regenerating the wordmark

The wordmark's 기계 and ZGIGYE are font outlines, too long to edit by hand.
`docs/assets/build_wordmark.py` composes the file from those outlines plus
the mark, placing every element from its measured bounding box — change the
sizes and margins at the top of the script and re-run it rather than editing
the SVG.

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
