#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"
DIST_DIR="${ROOT_DIR}/dist"
LICENSES_DIR="${DIST_DIR}/LICENSES"
EXTERNALS_DIR="${SKIA_DIR}/third_party/externals"

rm -rf "${LICENSES_DIR}"
mkdir -p "${LICENSES_DIR}"

copy_license() {
  local name="$1"
  local dir="$2"
  local found=0
  if [ -d "${dir}" ]; then
    for candidate in LICENSE LICENSE.txt LICENSE.md COPYING COPYING.txt NOTICE; do
      if [ -f "${dir}/${candidate}" ]; then
        cp "${dir}/${candidate}" "${LICENSES_DIR}/${name}-${candidate}"
        found=1
      fi
    done
  fi
  if [ "${found}" -eq 0 ]; then
    echo "WARNING: no license file found for ${name} under ${dir}" >&2
  fi
}

echo "== Skia =="
copy_license "skia" "${SKIA_DIR}"

echo "== SkiaSharp (C API sources, from mono/SkiaSharp) =="
SKIASHARP_LICENSE="${LICENSES_DIR}/SkiaSharp-LICENSE.md"
if command -v gh >/dev/null 2>&1; then
  gh api repos/mono/SkiaSharp/contents/LICENSE.md --jq '.content' | base64 --decode > "${SKIASHARP_LICENSE}"
else
  echo "WARNING: gh not available, skipping SkiaSharp LICENSE.md fetch" >&2
fi

echo "== HarfBuzz =="
copy_license "harfbuzz" "${EXTERNALS_DIR}/harfbuzz"

echo "== libpng =="
copy_license "libpng" "${EXTERNALS_DIR}/libpng"

echo "== libjpeg-turbo =="
copy_license "libjpeg-turbo" "${EXTERNALS_DIR}/libjpeg-turbo"

echo "== libwebp =="
copy_license "libwebp" "${EXTERNALS_DIR}/libwebp"

echo "== zlib =="
copy_license "zlib" "${EXTERNALS_DIR}/zlib"

echo "== expat =="
copy_license "expat" "${EXTERNALS_DIR}/expat"

echo "== wuffs =="
copy_license "wuffs" "${EXTERNALS_DIR}/wuffs"

echo "== piex =="
copy_license "piex" "${EXTERNALS_DIR}/piex"

echo "== Concatenating THIRD_PARTY_NOTICES.txt =="
NOTICES_FILE="${DIST_DIR}/THIRD_PARTY_NOTICES.txt"
: > "${NOTICES_FILE}"
for f in "${LICENSES_DIR}"/*; do
  [ -f "${f}" ] || continue
  {
    echo "================================================================================"
    echo "$(basename "${f}")"
    echo "================================================================================"
    cat "${f}"
    echo
  } >> "${NOTICES_FILE}"
done

echo "== Zipping LICENSES =="
(
  cd "${DIST_DIR}"
  rm -f LICENSES.zip
  ditto -c -k --keepParent LICENSES LICENSES.zip
)

echo "== Done =="
echo "Wrote ${NOTICES_FILE}"
echo "Wrote ${DIST_DIR}/LICENSES.zip"
