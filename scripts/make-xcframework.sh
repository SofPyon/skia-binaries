#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # skia.lock's path is resolved at runtime; shellcheck can't follow it statically
source "${ROOT_DIR}/skia.lock"

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"
DIST_DIR="${ROOT_DIR}/dist"
HEADERS_DIR="${DIST_DIR}/headers"

# One xcframework library per platform. Where a platform has two architectures the archives
# are lipo'd into a fat library first, because an xcframework holds one library per platform.
LIBRARIES=(
  "iphoneos:iphoneos-arm64"
  "iphonesimulator:iphonesimulator-arm64 iphonesimulator-x86_64"
  "xros:xros-arm64"
  "xrsimulator:xrsimulator-arm64"
  "macosx:macosx-arm64 macosx-x86_64"
  "maccatalyst:maccatalyst-arm64 maccatalyst-x86_64"
)
FAT_DIR="${SKIA_DIR}/out/fat"

rm -rf "${DIST_DIR}/libSkiaSharp.xcframework" "${DIST_DIR}/libHarfBuzzSharp.xcframework" "${HEADERS_DIR}" "${FAT_DIR}"
mkdir -p "${DIST_DIR}" "${HEADERS_DIR}/CSkia/include/c" "${HEADERS_DIR}/CHarfBuzz"

echo "== Assembling headers =="
# The xcframeworks carry headers only, each under its own subdirectory, and no module map.
# SwiftPM copies every slice's Headers into one shared include directory, so two xcframeworks
# that both ship a root module.modulemap collide there ("Multiple commands produce
# module.modulemap"). Consumers declare the modules themselves; see modulemap/ and README.md.
# The Skia C API headers include each other as "include/c/sk_types.h", so that layout is kept.
cp "${SKIA_DIR}"/include/c/*.h "${HEADERS_DIR}/CSkia/include/c/"

HARFBUZZ_SRC_DIR="${SKIA_DIR}/third_party/externals/harfbuzz/src"
mkdir -p "${HEADERS_DIR}/CHarfBuzz/harfbuzz"
find "${HARFBUZZ_SRC_DIR}" -maxdepth 1 -name 'hb*.h' -exec cp {} "${HEADERS_DIR}/CHarfBuzz/harfbuzz/" \;

for NAME in SkiaSharp HarfBuzzSharp; do
  if [ "${NAME}" = "SkiaSharp" ]; then
    HEADERS_PATH="${HEADERS_DIR}/CSkia"
  else
    HEADERS_PATH="${HEADERS_DIR}/CHarfBuzz"
  fi

  XCFRAMEWORK_OUT="${DIST_DIR}/lib${NAME}.xcframework"
  echo "== Creating lib${NAME}.xcframework =="

  CREATE_ARGS=()
  for ENTRY in "${LIBRARIES[@]}"; do
    LIBRARY="${ENTRY%%:*}"
    read -r -a SLICES <<<"${ENTRY#*:}"
    INPUTS=()
    for SLICE in "${SLICES[@]}"; do
      LIB_PATH="${SKIA_DIR}/out/${SLICE}/merged/lib${NAME}.a"
      if [ ! -f "${LIB_PATH}" ]; then
        echo "ERROR: ${LIB_PATH} not found - run scripts/build-slice.sh ${SLICE} first" >&2
        exit 1
      fi
      INPUTS+=("${LIB_PATH}")
    done
    if [ "${#INPUTS[@]}" -eq 1 ]; then
      LIB_PATH="${INPUTS[0]}"
    else
      LIB_PATH="${FAT_DIR}/${LIBRARY}/lib${NAME}.a"
      mkdir -p "$(dirname "${LIB_PATH}")"
      echo "== lipo ${LIBRARY}/lib${NAME}.a <- ${SLICES[*]} =="
      lipo -create "${INPUTS[@]}" -output "${LIB_PATH}"
    fi
    CREATE_ARGS+=("-library" "${LIB_PATH}" "-headers" "${HEADERS_PATH}")
  done

  rm -rf "${XCFRAMEWORK_OUT}"
  xcodebuild -create-xcframework "${CREATE_ARGS[@]}" -output "${XCFRAMEWORK_OUT}"

  echo "== Zipping lib${NAME}.xcframework =="
  (
    cd "${DIST_DIR}"
    rm -f "lib${NAME}.xcframework.zip"
    ditto -c -k --keepParent "lib${NAME}.xcframework" "lib${NAME}.xcframework.zip"
  )
done

echo "== Computing checksums =="
CHECKSUMS_FILE="${DIST_DIR}/CHECKSUMS.txt"
: > "${CHECKSUMS_FILE}"

TMP_PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_PKG_DIR}"' EXIT
cat > "${TMP_PKG_DIR}/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "checksum-helper", targets: [])
EOF

for NAME in SkiaSharp HarfBuzzSharp; do
  ZIP_PATH="${DIST_DIR}/lib${NAME}.xcframework.zip"
  SWIFTPM_CHECKSUM="$(cd "${TMP_PKG_DIR}" && swift package compute-checksum "${ZIP_PATH}")"
  SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
  {
    echo "lib${NAME}.xcframework.zip"
    echo "  swift-package-checksum: ${SWIFTPM_CHECKSUM}"
    echo "  sha256:                 ${SHA256}"
  } >> "${CHECKSUMS_FILE}"
done

echo "== Done =="
cat "${CHECKSUMS_FILE}"
