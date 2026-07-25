# Third-party material

zgigye itself is MIT-licensed (see `LICENSE`). It also builds against, and
in two cases ships copies of, work by other people. Everything below is
MIT-licensed too, except the story files, which are covered separately in
`stories/README.md`.

## Build dependencies

Fetched by the Zig package manager (`build.zig.zon`); no copies live in this
repository. Only the command-line executable links against them — the core
library has no dependencies at all.

| Package | Used for | License |
|---------|----------|---------|
| [libvaxis](https://github.com/rockorager/libvaxis) | the full-screen TUI frontend | MIT, © 2023 Tim Culverhouse |
| [zigimg](https://github.com/zigimg/zigimg) | transitive dependency of libvaxis | MIT, © 2019-2021 zigimg developers |
| [uucode](https://github.com/jacobsandlund/uucode) | transitive dependency of libvaxis | MIT, © 2026 Jacob Sandlund |

## Embedded in this repository

### ET Book

The `tufte` theme in the web frontends uses the ET Book family, from
[github.com/edwardtufte/et-book](https://github.com/edwardtufte/et-book) —
MIT License, © 2015 Dmitry Krasny, Bonnie Scranton, Edward Tufte.

Three weights are embedded as `data:` URIs in `src/web/index.html` and
`src/web/wasm.html`, so each page stays a single self-contained file. Those
files are therefore partly third-party content, and the MIT notice above
travels with them.

### Story files

`stories/` and `src/testdata/` hold two `.z3` games with different terms
from everything above. See `stories/README.md`.
