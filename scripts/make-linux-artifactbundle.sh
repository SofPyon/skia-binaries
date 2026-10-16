#!/usr/bin/env bash
# Packages the Linux slices as SwiftPM artifact bundles (SE-0482's `staticLibrary` artifact
# type, implemented in Swift 6.2), one bundle per library, each carrying both architectures as
# variants. A consumer declares a `.binaryTarget(url:checksum:)` for the bundle and SwiftPM puts
# the static archive on the link line and the bundle's `Headers/` on the include path - no
# unpacking step and no PKG_CONFIG_PATH, unlike the pkg-config tarballs from
# make-linux-bundle.sh, which stay in the release for everything that isn't SwiftPM.
#
# Like the xcframeworks, the bundles carry no module map (`staticLibraryMetadata` has no
# `moduleMapPath`), so the consuming package declares the module itself; see modulemap/ and
# README.md for why.
#
# The input is dist/skiasharp-linux-{arm64,x64}.tar.gz, which already hold both the merged
# archives and the headers: in the release flow this runs after make-linux-bundle.sh, and the
# bundles for an already published release can be built by downloading that release's tarballs
# and CHECKSUMS.txt into a directory and passing --dist <dir>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # skia.lock's path is resolved at runtime; shellcheck can't follow it statically
source "${ROOT_DIR}/skia.lock"

usage() {
  cat <<'USAGE' >&2
usage: make-linux-artifactbundle.sh [--dist <dir>]

Builds lib{SkiaSharp,HarfBuzzSharp}-linux.artifactbundle.zip from the Linux
tarballs in <dir> (default: dist) and writes their checksums into that
directory's CHECKSUMS.txt, replacing earlier entries for the same assets.
USAGE
}

DIST_DIR="${ROOT_DIR}/dist"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dist)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --dist requires a value" >&2
        exit 1
      }
      DIST_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

CHECKSUMS_FILE="${DIST_DIR}/CHECKSUMS.txt"
# `152.0.3` for skia-m152-3: the milestone, then the release sequence number. The field is a
# free-form string to SwiftPM, so this only has to be stable and readable.
BUNDLE_VERSION="${SKIA_MILESTONE}.0.${RELEASE_TAG##*-}"

for ARCH in arm64 x64; do
  if [ ! -f "${DIST_DIR}/skiasharp-linux-${ARCH}.tar.gz" ]; then
    echo "ERROR: ${DIST_DIR}/skiasharp-linux-${ARCH}.tar.gz not found - run scripts/make-linux-bundle.sh first, or download a release's tarballs into this directory" >&2
    exit 1
  fi
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

for ARCH in arm64 x64; do
  mkdir -p "${WORK_DIR}/${ARCH}"
  tar xzf "${DIST_DIR}/skiasharp-linux-${ARCH}.tar.gz" -C "${WORK_DIR}/${ARCH}" --strip-components 1
done

# `swift package compute-checksum` is what a consumer's `.binaryTarget(checksum:)` must match.
# It insists on running inside a package, so a throwaway one stands in.
PKG_DIR="${WORK_DIR}/checksum-helper"
mkdir -p "${PKG_DIR}"
cat > "${PKG_DIR}/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "checksum-helper", targets: [])
EOF

# Replaces the three-line block for one asset in CHECKSUMS.txt, or appends it if absent, so that
# a re-run (or a run against a downloaded CHECKSUMS.txt) leaves one entry per asset.
write_checksum_entry() {
  local asset="$1" swiftpm_checksum="$2" sha256="$3"
  local tmp_file="${WORK_DIR}/CHECKSUMS.new"
  : > "${tmp_file}"
  if [ -f "${CHECKSUMS_FILE}" ]; then
    awk -v asset="${asset}" '
      $0 == asset { skipping = 1; next }
      skipping && /^[[:space:]]/ { next }
      { skipping = 0; print }
    ' "${CHECKSUMS_FILE}" > "${tmp_file}"
  fi
  {
    echo "${asset}"
    echo "  swift-package-checksum: ${swiftpm_checksum}"
    echo "  sha256:                 ${sha256}"
  } >> "${tmp_file}"
  mv "${tmp_file}" "${CHECKSUMS_FILE}"
}

for NAME in SkiaSharp HarfBuzzSharp; do
  BUNDLE_NAME="lib${NAME}-linux.artifactbundle"
  BUNDLE_DIR="${DIST_DIR}/${BUNDLE_NAME}"
  echo "== Assembling ${BUNDLE_NAME} =="
  rm -rf "${BUNDLE_DIR}"
  mkdir -p "${BUNDLE_DIR}/Headers" "${BUNDLE_DIR}/linux-arm64" "${BUNDLE_DIR}/linux-x64"

  # The headers are the same for both architectures; the tarballs keep them one directory per
  # module (include/SkiaSharp/include/c, include/HarfBuzzSharp/harfbuzz), and that layout is
  # part of the API, since the Skia C headers include each other as "include/c/sk_types.h".
  cp -R "${WORK_DIR}/arm64/include/${NAME}/." "${BUNDLE_DIR}/Headers/"
  cp "${WORK_DIR}/arm64/lib/lib${NAME}.a" "${BUNDLE_DIR}/linux-arm64/"
  cp "${WORK_DIR}/x64/lib/lib${NAME}.a" "${BUNDLE_DIR}/linux-x64/"
  cp "${WORK_DIR}/arm64/BUILD-INFO.txt" "${BUNDLE_DIR}/BUILD-INFO.txt"

  cat > "${BUNDLE_DIR}/info.json" <<JSON
{
  "schemaVersion": "1.0",
  "artifacts": {
    "lib${NAME}": {
      "type": "staticLibrary",
      "version": "${BUNDLE_VERSION}",
      "variants": [
        {
          "path": "linux-arm64/lib${NAME}.a",
          "supportedTriples": ["aarch64-unknown-linux-gnu"],
          "staticLibraryMetadata": {
            "headerPaths": ["Headers"]
          }
        },
        {
          "path": "linux-x64/lib${NAME}.a",
          "supportedTriples": ["x86_64-unknown-linux-gnu"],
          "staticLibraryMetadata": {
            "headerPaths": ["Headers"]
          }
        }
      ]
    }
  }
}
JSON

  ZIP_PATH="${DIST_DIR}/${BUNDLE_NAME}.zip"
  rm -f "${ZIP_PATH}"
  (
    cd "${DIST_DIR}"
    # ditto on macOS, where the rest of the release is assembled, and zip elsewhere. Either
    # archive extracts the same; only the checksum differs between the two, and the checksum
    # this script records is the one from the file it just wrote.
    if command -v ditto >/dev/null 2>&1; then
      ditto -c -k --keepParent "${BUNDLE_NAME}" "${BUNDLE_NAME}.zip"
    else
      zip -r -q -X "${BUNDLE_NAME}.zip" "${BUNDLE_NAME}"
    fi
  )
  rm -rf "${BUNDLE_DIR}"

  SWIFTPM_CHECKSUM="$(cd "${PKG_DIR}" && swift package compute-checksum "${ZIP_PATH}")"
  SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
  write_checksum_entry "${BUNDLE_NAME}.zip" "${SWIFTPM_CHECKSUM}" "${SHA256}"
  echo "Wrote ${ZIP_PATH} (swift-package-checksum ${SWIFTPM_CHECKSUM})"
done

echo "== Done =="
cat "${CHECKSUMS_FILE}"
