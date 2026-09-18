#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"
DIST_DIR="${ROOT_DIR}/dist"
HEADERS_DIR="${DIST_DIR}/headers"

SLICES=(iphoneos-arm64 iphonesimulator-arm64 xros-arm64 xrsimulator-arm64 macosx-arm64)

rm -rf "${DIST_DIR}/libSkiaSharp.xcframework" "${DIST_DIR}/libHarfBuzzSharp.xcframework" "${HEADERS_DIR}"
mkdir -p "${DIST_DIR}" "${HEADERS_DIR}/CSkia" "${HEADERS_DIR}/CHarfBuzz"

echo "== Assembling headers =="
cp "${SKIA_DIR}"/include/c/*.h "${HEADERS_DIR}/CSkia/"
cp "${ROOT_DIR}/modulemap/CSkia/module.modulemap" "${HEADERS_DIR}/CSkia/"
cp "${ROOT_DIR}/modulemap/CSkia/CSkia.h" "${HEADERS_DIR}/CSkia/"

HARFBUZZ_SRC_DIR="${SKIA_DIR}/third_party/externals/harfbuzz/src"
find "${HARFBUZZ_SRC_DIR}" -maxdepth 1 -name 'hb*.h' -exec cp {} "${HEADERS_DIR}/CHarfBuzz/" \;
cp "${ROOT_DIR}/modulemap/CHarfBuzz/module.modulemap" "${HEADERS_DIR}/CHarfBuzz/"
cp "${ROOT_DIR}/modulemap/CHarfBuzz/CHarfBuzz.h" "${HEADERS_DIR}/CHarfBuzz/"

for NAME in SkiaSharp HarfBuzzSharp; do
  if [ "${NAME}" = "SkiaSharp" ]; then
    HEADERS_PATH="${HEADERS_DIR}/CSkia"
  else
    HEADERS_PATH="${HEADERS_DIR}/CHarfBuzz"
  fi

  XCFRAMEWORK_OUT="${DIST_DIR}/lib${NAME}.xcframework"
  echo "== Creating lib${NAME}.xcframework =="

  CREATE_ARGS=()
  for SLICE in "${SLICES[@]}"; do
    LIB_PATH="${SKIA_DIR}/out/${SLICE}/lib${NAME}.a"
    if [ ! -f "${LIB_PATH}" ]; then
      echo "ERROR: ${LIB_PATH} not found - run scripts/build-slice.sh ${SLICE} first" >&2
      exit 1
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
