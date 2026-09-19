#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

DIST_DIR="${ROOT_DIR}/dist"
REPO="SofPyon/skia-binaries"

REQUIRED_FILES=(
  "${DIST_DIR}/libSkiaSharp.xcframework.zip"
  "${DIST_DIR}/libHarfBuzzSharp.xcframework.zip"
  "${DIST_DIR}/skiasharp-linux-arm64.tar.gz"
  "${DIST_DIR}/skiasharp-linux-x64.tar.gz"
  "${DIST_DIR}/CHECKSUMS.txt"
  "${DIST_DIR}/THIRD_PARTY_NOTICES.txt"
  "${DIST_DIR}/LICENSES.zip"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "${f}" ]; then
    echo "ERROR: missing ${f} - run scripts/make-xcframework.sh, scripts/make-linux-bundle.sh and scripts/collect-licenses.sh first" >&2
    exit 1
  fi
done

RELEASE_NOTES="${DIST_DIR}/RELEASE-NOTES.md"
cat > "${RELEASE_NOTES}" <<EOF
Prebuilt Skia (SkiaSharp C API) static libraries: xcframeworks for Apple platforms and
pkg-config tarballs for Linux.

- Skia commit: ${MONO_SKIA_COMMIT} (mono/skia, milestone ${SKIA_MILESTONE})
- xcframework libraries: iphoneos (arm64), iphonesimulator (arm64, x86_64), xros (arm64),
  xrsimulator (arm64), macosx (arm64, x86_64), maccatalyst (arm64, x86_64)
- Linux tarballs: skiasharp-linux-arm64.tar.gz, skiasharp-linux-x64.tar.gz (static archives
  built on swift:6.2-noble, see docker/Dockerfile; fontconfig is linked from the system)
- Minimum OS versions: iOS ${MIN_IOS}, macOS ${MIN_MACOS}, visionOS ${MIN_VISIONOS},
  Mac Catalyst ${MIN_MACCATALYST}

See CHECKSUMS.txt for Swift Package \`binaryTarget\` checksums and the tarballs' SHA-256,
and THIRD_PARTY_NOTICES.txt for bundled third-party licenses.
EOF

echo "== Creating GitHub release ${RELEASE_TAG} =="
gh release create "${RELEASE_TAG}" \
  --repo "${REPO}" \
  --title "${RELEASE_TAG}" \
  --notes-file "${RELEASE_NOTES}" \
  "${DIST_DIR}"/*.zip \
  "${DIST_DIR}"/*.tar.gz \
  "${DIST_DIR}/CHECKSUMS.txt" \
  "${DIST_DIR}/THIRD_PARTY_NOTICES.txt"

echo "== Package.swift binaryTarget snippet =="
while IFS= read -r line; do
  case "${line}" in
    lib*.xcframework.zip)
      NAME="${line%.xcframework.zip}"
      ;;
    "  swift-package-checksum:"*)
      CHECKSUM="$(echo "${line}" | awk '{print $2}')"
      cat <<SNIPPET

.binaryTarget(
    name: "${NAME}",
    url: "https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${NAME}.xcframework.zip",
    checksum: "${CHECKSUM}"
)
SNIPPET
      ;;
  esac
done < "${DIST_DIR}/CHECKSUMS.txt"
