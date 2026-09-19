#!/usr/bin/env bash
# Packages the Linux slices as relocatable tarballs. SwiftPM has no binary targets on Linux,
# so consumers unpack one of these and point PKG_CONFIG_PATH at its lib/pkgconfig; a
# `.systemLibrary(name: "CSkia", pkgConfig: "SkiaSharp")` then picks up the include path and
# the static archives. The header layout is the same as in the xcframeworks
# (include/c/*.h for Skia, harfbuzz/hb*.h for HarfBuzz), one directory per module.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"
DIST_DIR="${ROOT_DIR}/dist"
CHECKSUMS_FILE="${DIST_DIR}/CHECKSUMS.txt"

# Both slices by default; a subset can be named on the command line while the other is still
# building (`scripts/make-linux-bundle.sh linux-arm64`).
if [ "$#" -gt 0 ]; then
  SLICES=("$@")
else
  SLICES=(linux-arm64 linux-x64)
fi
mkdir -p "${DIST_DIR}"

for SLICE in "${SLICES[@]}"; do
  MERGED_DIR="${SKIA_DIR}/out/${SLICE}/merged"
  for NAME in SkiaSharp HarfBuzzSharp; do
    if [ ! -f "${MERGED_DIR}/lib${NAME}.a" ]; then
      echo "ERROR: ${MERGED_DIR}/lib${NAME}.a not found - run scripts/build-slice.sh ${SLICE} first" >&2
      exit 1
    fi
  done

  BUNDLE_NAME="skiasharp-${SLICE}"
  STAGE_DIR="${DIST_DIR}/${BUNDLE_NAME}"
  rm -rf "${STAGE_DIR}"
  mkdir -p "${STAGE_DIR}/include/SkiaSharp/include/c" "${STAGE_DIR}/include/HarfBuzzSharp/harfbuzz" \
    "${STAGE_DIR}/lib/pkgconfig"

  echo "== Assembling ${BUNDLE_NAME} =="
  cp "${SKIA_DIR}"/include/c/*.h "${STAGE_DIR}/include/SkiaSharp/include/c/"
  find "${SKIA_DIR}/third_party/externals/harfbuzz/src" -maxdepth 1 -name 'hb*.h' \
    -exec cp {} "${STAGE_DIR}/include/HarfBuzzSharp/harfbuzz/" \;
  cp "${MERGED_DIR}/libSkiaSharp.a" "${MERGED_DIR}/libHarfBuzzSharp.a" "${STAGE_DIR}/lib/"

  # `${pcfiledir}` makes the files valid wherever the tarball is unpacked. The link flags are
  # the ones the link smoke test in build-slice.sh uses: Skia is C++ (libstdc++ on this
  # toolchain) and its default font manager on Linux is fontconfig, which stays a system
  # library so the archive carries no copy of it. The runtime soname is named directly
  # (`-l:libfontconfig.so.1`) because images such as swift:*-noble ship libfontconfig1 but not
  # the -dev package that provides the plain libfontconfig.so link.
  cat > "${STAGE_DIR}/lib/pkgconfig/SkiaSharp.pc" <<PC
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: SkiaSharp
Description: Skia with the SkiaSharp C API, static archive (mono/skia milestone ${SKIA_MILESTONE})
Version: ${SKIA_MILESTONE}
Cflags: -I\${includedir}/SkiaSharp
Libs: -L\${libdir} -lSkiaSharp -l:libfontconfig.so.1 -lstdc++ -lm -lpthread -ldl
PC
  cat > "${STAGE_DIR}/lib/pkgconfig/HarfBuzzSharp.pc" <<PC
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: HarfBuzzSharp
Description: HarfBuzz with the HarfBuzzSharp C API, static archive (built with mono/skia milestone ${SKIA_MILESTONE})
Version: ${SKIA_MILESTONE}
Cflags: -I\${includedir}/HarfBuzzSharp
Libs: -L\${libdir} -lHarfBuzzSharp -lstdc++ -lm -lpthread
PC
  cp "${WORK_DIR}/BUILD-INFO.txt" "${STAGE_DIR}/BUILD-INFO.txt"

  TARBALL="${DIST_DIR}/${BUNDLE_NAME}.tar.gz"
  rm -f "${TARBALL}"
  # tar's GNU/BSD differences in ownership metadata would change the checksum between hosts,
  # so the archive carries no user or group names.
  (
    cd "${DIST_DIR}"
    COPYFILE_DISABLE=1 tar --numeric-owner --uid 0 --gid 0 -czf "${TARBALL}" "${BUNDLE_NAME}"
  )
  rm -rf "${STAGE_DIR}"

  SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
  {
    echo "${BUNDLE_NAME}.tar.gz"
    echo "  sha256:                 ${SHA256}"
  } >> "${CHECKSUMS_FILE}"
  echo "Wrote ${TARBALL} (sha256 ${SHA256})"
done

echo "== Done =="
cat "${CHECKSUMS_FILE}"
