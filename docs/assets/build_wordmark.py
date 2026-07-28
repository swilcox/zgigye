#!/usr/bin/env python3
"""Compose docs/assets/wordmark.svg.

The lockup's 기계 and ZGIGYE are font outlines — thousands of coordinates,
not editable by hand. This script keeps them and lays everything else out
from measured bounding boxes, so the composition is stated once, here, as
sizes and margins rather than as baked-in path data.

The outlines are read back out of the wordmark itself (the two paths carry
`id` attributes), which makes the script idempotent: run it, edit the
constants below, run it again.

    python3 docs/assets/build_wordmark.py
"""

import pathlib
import re

HERE = pathlib.Path(__file__).parent
OUT = HERE / "wordmark.svg"

# --- composition -----------------------------------------------------------
# Heights are in final canvas units; the source outlines are scaled to hit them.
MARK_H, HANGUL_H, ZGIGYE_H = 280, 230, 60
PAD, GAP = 96, 88                       # panel margin, mark-to-lettering gap
RULE_ABOVE, RULE_BELOW, RULE_H = 26, 22, 8
CANVAS_H = 480
CORNER, RING = 88, 8

INK, RED, CREAM, SLATE = "#111820", "#C95248", "#F2E9D8", "#33424D"

# Measured bounding boxes, each in its own source coordinate space.
HANGUL_BOX = (455.00, 126.00, 926.49, 386.00)
ZGIGYE_BOX = (460.00, 425.00, 704.44, 481.00)
MARK_BOX = (130.0, 128.0, 382.0, 384.0)  # the brandmark's artwork, untiled


def read_outlines():
    """Pull the two lettering paths out of the existing wordmark."""
    svg = OUT.read_text()
    by_id = dict(re.findall(r'<path id="(hangul|zgigye)" d="([^"]+)"', svg))
    if len(by_id) == 2:
        return by_id["hangul"], by_id["zgigye"]
    # Pre-id wordmark: the only two evenodd paths, in document order.
    loose = re.findall(r'<path d="([^"]+)" fill="#[0-9A-Fa-f]{6}" fill-rule="evenodd"/>', svg)
    if len(loose) == 2:
        return loose[0], loose[1]
    raise SystemExit(f"could not find the two lettering outlines in {OUT}")


def place(box, x, y, height):
    """Transform mapping box's top-left corner to (x, y) at the given height."""
    x0, y0, _, y1 = box
    return f"translate({x:g},{y:g}) scale({height / (y1 - y0):.6f}) translate({-x0:g},{-y0:g})"


def width_at(box, height):
    x0, y0, x1, y1 = box
    return (x1 - x0) * height / (y1 - y0)


hangul_d, zgigye_d = read_outlines()

mark_w = width_at(MARK_BOX, MARK_H)
hangul_w = width_at(HANGUL_BOX, HANGUL_H)
text_x = PAD + mark_w + GAP
text_h = HANGUL_H + RULE_ABOVE + RULE_H + RULE_BELOW + ZGIGYE_H
text_y = (CANVAS_H - text_h) / 2
rule_y = text_y + HANGUL_H + RULE_ABOVE

W, H = round(text_x + hangul_w + PAD), CANVAS_H

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">

  <!-- Ground. The lockup carries its own, like the brandmark, so it reads on a
       page of any colour; the slate ring holds the edge where the page is as
       dark as the panel (GitHub dark is #0d1117 against this #111820). -->
  <rect width="{W}" height="{H}" rx="{CORNER}" fill="{INK}"/>
  <rect x="{RING / 2}" y="{RING / 2}" width="{W - RING}" height="{H - RING}"
        rx="{CORNER - RING / 2}" fill="none" stroke="{SLATE}" stroke-width="{RING}"/>

  <!-- The brandmark's stepped Z, untiled: the panel is its container here. -->
  <g transform="{place(MARK_BOX, PAD, (H - MARK_H) / 2, MARK_H)}">
    <g fill="{CREAM}">
      <rect x="130" y="128" width="252" height="28" rx="14"/>
      <rect x="130" y="356" width="252" height="28" rx="14"/>
    </g>
    <g fill="{RED}">
      <rect x="286" y="162" width="96" height="28" rx="14"/>
      <rect x="255" y="194" width="96" height="28" rx="14"/>
      <rect x="224" y="226" width="96" height="28" rx="14"/>
      <rect x="192" y="258" width="96" height="28" rx="14"/>
      <rect x="161" y="290" width="96" height="28" rx="14"/>
      <rect x="130" y="322" width="96" height="28" rx="14"/>
    </g>
  </g>

  <g transform="{place(HANGUL_BOX, text_x, text_y, HANGUL_H)}">
    <path id="hangul" d="{hangul_d}" fill="{CREAM}" fill-rule="evenodd"/>
  </g>

  <rect x="{text_x:.1f}" y="{rule_y:.1f}" width="{hangul_w:.1f}" height="{RULE_H}"
        rx="{RULE_H / 2}" fill="{RED}"/>

  <g transform="{place(ZGIGYE_BOX, text_x, rule_y + RULE_H + RULE_BELOW, ZGIGYE_H)}">
    <path id="zgigye" d="{zgigye_d}" fill="{CREAM}" fill-rule="evenodd"/>
  </g>

</svg>
'''

OUT.write_text(svg)
print(f"wrote {OUT.relative_to(HERE.parent.parent)}: {W}x{H}, {len(svg)} bytes")
