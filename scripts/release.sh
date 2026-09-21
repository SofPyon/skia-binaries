#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # skia.lock's path is resolved at runtime; shellcheck can't follow it statically
source "${ROOT_DIR}/skia.lock"

usage() {
  cat <<'USAGE' >&2
usage: release.sh [--draft]

Publishes dist/'s built assets as a GitHub release tagged RELEASE_TAG (from
skia.lock). Refuses to run if that tag already has a release, and if
scripts/verify-release.sh finds anything wrong with dist/ first.

  --draft         Create the release as a draft (same as RELEASE_DRAFT=1).
USAGE
}

DRAFT="${RELEASE_DRAFT:-0}"
for arg in "$@"; do
  case "${arg}" in
    --draft)
      DRAFT=1
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '${arg}'" >&2
      usage
      exit 1
      ;;
  esac
done

DIST_DIR="${ROOT_DIR}/dist"
REPO="SofPyon/skia-binaries"

if gh release view "${RELEASE_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  echo "ERROR: a release already exists for tag ${RELEASE_TAG} - bump RELEASE_TAG in skia.lock (scripts/bump-lock.sh does this) before releasing again" >&2
  exit 1
fi

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

echo "== Verifying dist/ before releasing =="
"${SCRIPT_DIR}/verify-release.sh" --dist "${DIST_DIR}"

GH_RELEASE_ARGS=(
  "${RELEASE_TAG}"
  --repo "${REPO}"
  --title "${RELEASE_TAG}"
  --notes-file "${RELEASE_NOTES}"
)
if [ "${DRAFT}" = "1" ]; then
  GH_RELEASE_ARGS+=(--draft)
fi

echo "== Creating GitHub release ${RELEASE_TAG}$([ "${DRAFT}" = "1" ] && echo ' (draft)') =="
gh release create "${GH_RELEASE_ARGS[@]}" \
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
