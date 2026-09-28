# Elun

Package installer guided by the Linux From Scratch books (LFS, BLFS, MLFS,
GLFS, SLFS). A mini Portage: ask for a package and Elun follows the books.

## Commands

- `elun update-books` — downloads and updates the books into `~/LFS-BOOKS-DEV`.
- `elun install <package>` — downloads, verifies, builds and installs.
- `elun update <package>` — rebuilds over the existing install.
- `elun remove <package>` — uninstalls (make/ninja rule, cmake manifest or chapter install paths).
- `elun orphans` — installed packages nothing else needs.
- `elun list` — installed packages with version, book and build time.
- `elun search <package>` — read-only lookup.

## Status

- Phase 1: books download and stay up to date. Done.
- Phase 2: branch-aware search (developer first, stable after) with
  dependency report. Done.
- Phase 3: build and install, with sudo for root steps. Done.
- Phase 4: failure logs and orphans done; dependency resolution still open.

## Requirements

- Nim >= 2.2.0 (`nimble install` pulls `libsha`).
- `git`, `make`, `xsltproc`, `tidy`, `docbook-xsl`, `docbook-xml`
  (only needed to render MLFS, GLFS and SLFS).

## Build

```sh
nimble build
./elun update-books
./elun install curl
```

## Status

- Phase 1: books download and stay up to date. Done.
- Phase 2: branch-aware search (developer first, stable after) with
  dependency report. Done.
- Phase 3: build and install, with sudo for root steps. Done.
- Phase 4: failure logs and orphans done; dependency resolution still open.

Spec (Spanish): `Elun.md`.
License: BSD Zero Clause.
