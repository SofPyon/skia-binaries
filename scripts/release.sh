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
  "${DIST_DIR}/CHECKSUMS.txt"
  "${DIST_DIR}/THIRD_PARTY_NOTICES.txt"
  "${DIST_DIR}/LICENSES.zip"
)
for f in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "${f}" ]; then
    echo "ERROR: missing ${f} - run scripts/make-xcframework.sh and scripts/collect-licenses.sh first" >&2
    exit 1
  fi
done

RELEASE_NOTES="${DIST_DIR}/RELEASE-NOTES.md"
cat > "${RELEASE_NOTES}" <<EOF
Prebuilt Skia (SkiaSharp C API) static xcframeworks for Apple platforms.

- Skia commit: ${MONO_SKIA_COMMIT} (mono/skia, milestone ${SKIA_MILESTONE})
- Slices: iphoneos-arm64, iphonesimulator-arm64, xros-arm64, xrsimulator-arm64, macosx-arm64
- Minimum OS versions: iOS ${MIN_IOS}, macOS ${MIN_MACOS}, visionOS ${MIN_VISIONOS}

See CHECKSUMS.txt for Swift Package \`binaryTarget\` checksums and
THIRD_PARTY_NOTICES.txt for bundled third-party licenses.
EOF

echo "== Creating GitHub release ${RELEASE_TAG} =="
gh release create "${RELEASE_TAG}" \
  --repo "${REPO}" \
  --title "${RELEASE_TAG}" \
  --notes-file "${RELEASE_NOTES}" \
  "${DIST_DIR}"/*.zip \
  "${DIST_DIR}/CHECKSUMS.txt"

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
