# skia-binaries

Prebuilt Skia (SkiaSharp C API) static libraries: xcframeworks for Apple
platforms (iOS, iOS Simulator, visionOS, visionOS Simulator, macOS, Mac Catalyst)
and, for Linux (arm64, x86_64), both SwiftPM artifact bundles and pkg-config
tarballs.

Binaries are published on the [Releases](../../releases) page, built from the
[mono/skia](https://github.com/mono/skia) SkiaSharp fork pinned in
`skia.lock`.

## Contents

- `libSkiaSharp.xcframework` — Skia + the SkiaSharp C API (`sk_*` symbols)
- `libHarfBuzzSharp.xcframework` — HarfBuzz + the HarfBuzzSharp C API (`hb_*` symbols)
- `libSkiaSharp-linux.artifactbundle.zip` / `libHarfBuzzSharp-linux.artifactbundle.zip` — the
  same two libraries for Linux as SwiftPM artifact bundles ([SE-0482][se0482] `staticLibrary`
  artifacts, Swift 6.2 and later), one variant per architecture
- `skiasharp-linux-arm64.tar.gz` / `skiasharp-linux-x64.tar.gz` — the same static archives and
  headers again, with `lib/pkgconfig/{SkiaSharp,HarfBuzzSharp}.pc`, for build systems other
  than SwiftPM
- `CHECKSUMS.txt` — `swift package compute-checksum` output for each zip, for use in a Swift Package `binaryTarget`, and the SHA-256 of each tarball

[se0482]: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0482-swiftpm-static-library-binary-target-non-apple-platforms.md
- `THIRD_PARTY_NOTICES.txt` / `LICENSES.zip` — license texts for Skia and its bundled third-party dependencies

## Build scripts

All scripts live in `scripts/` and read configuration from `skia.lock`. Run
them from a clean checkout of this repository; they resolve paths relative
to their own location.

| Script | Purpose |
| --- | --- |
| `scripts/fetch.sh` | Clone the pinned Skia commit into `work/skia` and sync its dependencies (gn, ninja, third_party). |
| `scripts/build-slice.sh <slice>` | Build `libSkiaSharp.a` and `libHarfBuzzSharp.a` for one slice with `gn`/`ninja`. A Linux slice run on macOS goes through `scripts/docker-build-linux.sh`. |
| `scripts/docker-build-linux.sh <slice>` | Run `build-slice.sh` for a Linux slice inside the container from `docker/Dockerfile` (based on `swift:6.4-noble`, so the archives match the toolchain consumers build with). |
| `scripts/make-xcframework.sh` | Assemble the Apple slices (lipo'd into one fat library per platform) and headers into xcframeworks, then zip them. Rewrites `CHECKSUMS.txt`. |
| `scripts/make-linux-bundle.sh` | Package the Linux slices as pkg-config tarballs. Appends to `CHECKSUMS.txt`, so run it after `make-xcframework.sh`. |
| `scripts/make-linux-artifactbundle.sh` | Repackage those tarballs as SwiftPM artifact bundles (one per library, both architectures as variants). Reads `dist/skiasharp-linux-*.tar.gz`, so run it after `make-linux-bundle.sh`; `--dist <dir>` works on a published release's downloaded tarballs too. |
| `scripts/collect-licenses.sh` | Gather license texts of Skia and its third-party dependencies. |
| `scripts/release.sh` | Publish the built zips and checksums as a GitHub release. Accepts `--draft`; refuses to run if `RELEASE_TAG` already has a release, or if `scripts/verify-release.sh` finds a problem with `dist/`. |
| `scripts/check-lock.sh` | Validate `skia.lock`'s shape (sourceable, every variable but `HARFBUZZ_COMMIT` non-empty). Run standalone or from CI. |
| `scripts/check-upstream.sh` | Report how far `skia.lock`'s pin is behind `mono/skia`. See [Maintenance](#maintenance). |
| `scripts/bump-lock.sh <branch\|commit>` | Advance `skia.lock`'s pin to a new branch or commit, blanking `HARFBUZZ_COMMIT` for `scripts/fetch.sh` to re-resolve. |
| `scripts/verify-release.sh` | Verify a built `dist/` (`--dist <dir>`) or a published release (`--tag <tag>`) matches this repo's asset/checksum/layout contract. |

Supported slices: `iphoneos-arm64`, `iphonesimulator-arm64`, `iphonesimulator-x86_64`,
`xros-arm64`, `xrsimulator-arm64`, `macosx-arm64`, `macosx-x86_64`, `maccatalyst-arm64`,
`maccatalyst-x86_64`, `linux-arm64`, `linux-x64`.

The Linux slices build in Docker (`docker/Dockerfile`). `linux-x64` on an Apple Silicon host
runs under Docker Desktop's x86_64 emulation and takes several times longer than the
native slice.

### Typical flow

```sh
scripts/fetch.sh
for slice in iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64 \
    xros-arm64 xrsimulator-arm64 macosx-arm64 macosx-x86_64 \
    maccatalyst-arm64 maccatalyst-x86_64 linux-arm64 linux-x64; do
  scripts/build-slice.sh "$slice"
done
scripts/make-xcframework.sh
scripts/make-linux-bundle.sh
scripts/make-linux-artifactbundle.sh
scripts/collect-licenses.sh
scripts/release.sh --draft   # or scripts/release.sh to publish directly
```

The `build-release` GitHub Actions workflow (`.github/workflows/build-release.yml`) runs the
same flow on hosted runners: `workflow_dispatch` with a `slices` input (a space-separated list,
or `all`), a `publish` choice (`none`/`draft`/`publish`), and an optional `xcode` version. It
only assembles and releases when every slice was requested; a partial run uploads the built
`.a` files as artifacts without going further.

## Maintenance

mono/skia's release branches follow `release/<major>.<milestone>.<patch>`, where `<milestone>`
is the same Skia milestone number as `SKIA_MILESTONE`/`SkMilestone.h`. A `-preview.N` or `-rc.N`
suffix, or a `.x` patch component, marks a provisional branch that hasn't cut a stable patch
yet. Tags on that repository stopped being maintained after 4.148, so `scripts/check-upstream.sh`
tracks branches instead, using only `git ls-remote --heads` (no clone): it compares
`MONO_SKIA_BRANCH`/`MONO_SKIA_COMMIT` against the current state of `MONO_SKIA_REPO` and reports
ref drift, newer same-milestone patches, and newer milestones (stable and provisional
separately).

`scripts/check-upstream.sh` exits `0` when there is nothing to take, `10` when a stable update
is available — ref drift, a newer patch on this milestone, or a newer stable milestone — and `1`
if the check itself failed (bad `skia.lock`, network error, ...). Provisional branches are listed
in the report but never raise the flag on their own: they sit upstream continuously between
stable cuts, so counting them would hold the issue open forever. The `upstream-check` workflow
runs it weekly and files (or updates) a `upstream-update`-labelled issue with the result when
exit code `10` is reported, closing that issue once a later run reports `0`.

The `lint` workflow runs shellcheck, actionlint and `scripts/check-lock.sh` on every push and
pull request. It pins both linters so a local run and a CI run agree, running the same two
commands:

```sh
docker run --rm -v "${PWD}:/mnt" koalaman/shellcheck:v0.11.0 scripts/*.sh
docker run --rm -v "${PWD}:/repo" -w /repo rhysd/actionlint:1.7.12 -color
```

The loop from an upstream update to a new release:

1. The scheduled `upstream-check` workflow opens or refreshes the `upstream-update` issue.
2. `scripts/bump-lock.sh <branch>` pins `skia.lock` to the new branch (or a raw commit with
   `--milestone`), blanking `HARFBUZZ_COMMIT`.
3. `scripts/fetch.sh` clones the new pin, confirms `SkMilestone.h` agrees with
   `SKIA_MILESTONE`, and resolves `HARFBUZZ_COMMIT` back into `skia.lock`.
4. Build the slices, either locally (`scripts/build-slice.sh`) or via the `build-release`
   workflow.
5. `scripts/verify-release.sh` checks the assembled `dist/` before anything is published.
6. `scripts/release.sh` (`--draft` first, if you want to inspect the release before publishing).

## Using the binaries

The xcframeworks carry static libraries and headers only. Header layout:

- `libSkiaSharp.xcframework`: `Headers/include/c/*.h` and `Headers/include/skb/*.h`
  (the headers include each other as `"include/c/sk_types.h"`, so the prefix is part of the API)
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
MobileCoreServices on iOS/visionOS, AppKit and ApplicationServices on macOS, or UIKit on
Mac Catalyst.

`include/skb/*.h` holds this repository's own C wrappers with the `skb_` prefix.
mono/skia owns `include/c/` and the `sk_` prefix; separate names prevent collisions
if mono/skia later adds the same API.

Adding a wrapper: put its header in `capi/include/skb/` and source in `capi/src/`.
The build compiles it with the flags ninja used for mono/skia's C API and folds it
into `libSkiaSharp.a`. Add the header to `modulemap/CSkia/CSkia.h` and extend the
symbol check and smoke test in `scripts/build-slice.sh`.

### Linux

The same two static archives are published twice: as SwiftPM artifact bundles, and as
pkg-config tarballs for everything else.

#### SwiftPM (Swift 6.2 and later)

[SE-0482][se0482] added `staticLibrary` artifacts to artifact bundles, which makes
`.binaryTarget` work on Linux. Nothing has to be unpacked and `PKG_CONFIG_PATH` is not
involved; the declaration looks like the Apple one:

```swift
.binaryTarget(name: "libSkiaSharp", url: "…/libSkiaSharp-linux.artifactbundle.zip", checksum: "…"),
.binaryTarget(name: "libHarfBuzzSharp", url: "…/libHarfBuzzSharp-linux.artifactbundle.zip", checksum: "…"),
.target(name: "CSkia", dependencies: ["libSkiaSharp"]),          // Sources/CSkia/include/{module.modulemap,CSkia.h} + an empty .c file
.target(name: "CHarfBuzz", dependencies: ["libHarfBuzzSharp"]),  // Sources/CHarfBuzz/include/{module.modulemap,CHarfBuzz.h} + an empty .c file
```

Each bundle holds one `staticLibrary` artifact with two variants, `linux-arm64/lib*.a` for
`aarch64-unknown-linux-gnu` and `linux-x64/lib*.a` for `x86_64-unknown-linux-gnu`, and one
`Headers/` directory shared by both, which SwiftPM puts on the include path (the same layout as
the xcframeworks: `Headers/include/c/*.h` and `Headers/include/skb/*.h` for Skia,
`Headers/harfbuzz/hb*.h` for HarfBuzz).

The bundles name no `moduleMapPath`, so the consuming package declares the module, as it does
for the xcframeworks. A bundle could carry one — SwiftPM passes each bundle's `headerPaths` as
`-I` into that bundle's own directory, so two bundles cannot collide the way two xcframeworks
with a root module map would — but leaving it out is what lets a consumer choose how much of the
API its umbrella header exposes. HarfBuzz's subsetting API (`harfbuzz/hb-subset.h`) is in the
archive, and `modulemap/CHarfBuzz/CHarfBuzz.h` here does not include it.

SE-0482 covers artifacts that need nothing beyond the C standard library, and these need more
than that, so the dependencies are not declared by the bundle: each target that uses them links
them itself, as the proposal allows.

```swift
linkerSettings: [
  .linkedLibrary(":libfontconfig.so.1", .when(platforms: [.linux])),
  .linkedLibrary("stdc++", .when(platforms: [.linux])),
  .linkedLibrary("m", .when(platforms: [.linux])),
  .linkedLibrary("pthread", .when(platforms: [.linux])),
  .linkedLibrary("dl", .when(platforms: [.linux])),
]
```

These are the flags the `.pc` files below carry and the link smoke test in `build-slice.sh`
uses. The fontconfig soname is named directly (`-l:libfontconfig.so.1`) because images such as
`swift:*-noble` ship `libfontconfig1` but not the `-dev` package that provides the plain
`libfontconfig.so` link.

#### Other build systems

Unpack `skiasharp-linux-<arch>.tar.gz` anywhere, add its `lib/pkgconfig` to `PKG_CONFIG_PATH`,
and declare the two modules as system libraries, reusing the same module map files:

```swift
.systemLibrary(name: "CSkia", path: "Sources/CSkia/include", pkgConfig: "SkiaSharp"),
.systemLibrary(name: "CHarfBuzz", path: "Sources/CHarfBuzz/include", pkgConfig: "HarfBuzzSharp"),
```

The `.pc` files carry the include path and the link line.

#### Either way

The archives are raster-only (no GL, Vulkan, Metal or Graphite) and use fontconfig as the
default font manager, so the consuming image needs `libfontconfig1` and some fonts
installed; the `swift:*-noble` images ship both. FreeType is compiled in.

## License

The build scripts in this repository are MIT licensed; see `LICENSE`.
The prebuilt binaries bundle Skia and its third-party dependencies under
their own licenses — see `THIRD_PARTY_NOTICES.txt` in each release.
