# skia-binaries

Prebuilt Skia (SkiaSharp C API) static xcframeworks for Apple platforms
(iOS, iOS Simulator, visionOS, visionOS Simulator, macOS — arm64 only).

Binaries are published as zipped `.xcframework` assets on the
[Releases](../../releases) page, built from the
[mono/skia](https://github.com/mono/skia) SkiaSharp fork pinned in
`skia.lock`.

## Contents

- `libSkiaSharp.xcframework` — Skia + the SkiaSharp C API (`sk_*` symbols)
- `libHarfBuzzSharp.xcframework` — HarfBuzz + the HarfBuzzSharp C API (`hb_*` symbols)
- `CHECKSUMS.txt` — `swift package compute-checksum` output for each zip, for use in a Swift Package `binaryTarget`
- `THIRD_PARTY_NOTICES.txt` / `LICENSES.zip` — license texts for Skia and its bundled third-party dependencies

## Build scripts

All scripts live in `scripts/` and read configuration from `skia.lock`. Run
them from a clean checkout of this repository; they resolve paths relative
to their own location.

| Script | Purpose |
| --- | --- |
| `scripts/fetch.sh` | Clone the pinned Skia commit into `work/skia` and sync its dependencies (gn, ninja, third_party). |
| `scripts/build-slice.sh <slice>` | Build `libSkiaSharp.a` and `libHarfBuzzSharp.a` for one slice with `gn`/`ninja`. |
| `scripts/make-xcframework.sh` | Assemble per-slice static libraries and headers into xcframeworks, then zip them. |
| `scripts/collect-licenses.sh` | Gather license texts of Skia and its third-party dependencies. |
| `scripts/release.sh` | Publish the built zips and checksums as a GitHub release. |

Supported slices: `iphoneos-arm64`, `iphonesimulator-arm64`, `xros-arm64`,
`xrsimulator-arm64`, `macosx-arm64`.

### Typical flow

```sh
scripts/fetch.sh
scripts/build-slice.sh iphoneos-arm64
scripts/build-slice.sh iphonesimulator-arm64
scripts/build-slice.sh xros-arm64
scripts/build-slice.sh xrsimulator-arm64
scripts/build-slice.sh macosx-arm64
scripts/make-xcframework.sh
scripts/collect-licenses.sh
scripts/release.sh
```

## Using the binaries

The xcframeworks carry static libraries and headers only. Header layout:

- `libSkiaSharp.xcframework`: `Headers/include/c/*.h` (the headers include each other as
  `"include/c/sk_types.h"`, so the prefix is part of the API)
- `libHarfBuzzSharp.xcframework`: `Headers/harfbuzz/hb*.h`

They deliberately ship no `module.modulemap`: SwiftPM copies every binary target's
headers into one shared include directory, and two xcframeworks with a root module
map collide there. Declare the modules in the consuming package instead, with a
small C target per library whose `include/` holds the files from `modulemap/`:

```swift
.binaryTarget(name: "libSkiaSharp", url: "…/libSkiaSharp.xcframework.zip", checksum: "…"),
.binaryTarget(name: "libHarfBuzzSharp", url: "…/libHarfBuzzSharp.xcframework.zip", checksum: "…"),
.target(name: "CSkia", dependencies: ["libSkiaSharp"]),          // Sources/CSkia/include/{module.modulemap,CSkia.h} + an empty .c file
.target(name: "CHarfBuzz", dependencies: ["libHarfBuzzSharp"]),  // Sources/CHarfBuzz/include/{module.modulemap,CHarfBuzz.h} + an empty .c file
```

Targets that use them link `c++` and the frameworks Skia's Apple ports need:
Foundation, CoreFoundation, CoreGraphics, CoreText, ImageIO, Metal, plus UIKit and
MobileCoreServices on iOS/visionOS or AppKit and ApplicationServices on macOS.

## License

The build scripts in this repository are MIT licensed; see `LICENSE`.
The prebuilt binaries bundle Skia and its third-party dependencies under
their own licenses — see `THIRD_PARTY_NOTICES.txt` in each release.
