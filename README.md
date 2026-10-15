<p align="center"><img src="docs/logo.png" alt="MacParity logo" width="360"></p>

# MacParity

A modern macOS rebuild of MacPAR deLuxe: verify, repair and create PAR2 (and PAR1) sets,
extract RAR archives, and run post-processing rules. See [SPEC.md](SPEC.md) for the feature spec.

## Layout

| Path | What |
|---|---|
| `App/Sources` | AppKit + SwiftUI app (NSDocument per par set, menus in code) |
| `App/CUnrar` | Clang module exposing RARLAB's UnRAR `dll.hpp` to Swift |
| `Packages/ParityKit` | Pure Swift core: par2 output parser, PAR2 file reader, rules, RAR volume naming |
| `Scripts/bootstrap-vendor.sh` | Downloads (SHA-256 pinned) and builds par2cmdline-turbo and libunrar, universal |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated |

## Build

```bash
brew install xcodegen
Scripts/bootstrap-vendor.sh
xcodegen generate
open MacParity.xcodeproj
```

## Licenses of bundled engines

- par2cmdline-turbo: GPL-2.0, shipped as a separate executable in `Contents/Helpers`.
- UnRAR: RARLAB UnRAR license (extraction only; may not be used to re-create the RAR compression
  algorithm). Linked statically. Its license text is copied to the app's resources.
