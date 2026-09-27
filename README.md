# Elun

Package installer guided by the Linux From Scratch books (LFS, BLFS, MLFS,
GLFS, SLFS). A mini Portage: ask for a package and Elun follows the books.

## Commands

- `elun update-books` — downloads and updates the books into `~/LFS-BOOKS-DEV`.
- `elun install <package>` — reports the book, version and dependencies.
  Building comes in phase 3.
- `elun update <package>` — same lookup, for an already installed package.
- `elun remove <package>` — planned for phase 3.
- `elun orphans` — planned, blocked on phase 4 dependency resolution.

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
- Phase 3: build and install. Next.

Spec (Spanish): `Elun.md`.
License: BSD Zero Clause.
