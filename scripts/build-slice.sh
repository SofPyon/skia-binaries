#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

SLICE="${1:-}"
if [ -z "${SLICE}" ]; then
  echo "usage: $0 <slice>" >&2
  echo "  slices: iphoneos-arm64 iphonesimulator-arm64 xros-arm64 xrsimulator-arm64 macosx-arm64" >&2
  exit 1
fi

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"
GN="${SKIA_DIR}/bin/gn"
NINJA="${SKIA_DIR}/bin/ninja"

if [ ! -x "${GN}" ]; then
  echo "ERROR: gn not found at ${GN} - run scripts/fetch.sh first" >&2
  exit 1
fi

# bin/fetch-ninja does not always vendor a `bin/ninja` binary (it may only
# write ninja.version for the DEPS-pinned release). Fall back to depot_tools'
# ninja, then a Homebrew-installed ninja, since both can resolve to the same
# ninja release pinned by DEPS at MONO_SKIA_COMMIT.
if [ ! -x "${NINJA}" ]; then
  if [ -x "${HOME}/depot_tools/ninja" ]; then
    NINJA="${HOME}/depot_tools/ninja"
  elif command -v ninja >/dev/null 2>&1; then
    NINJA="$(command -v ninja)"
  else
    echo "ERROR: ninja not found (checked ${SKIA_DIR}/bin/ninja, ${HOME}/depot_tools/ninja, PATH)" >&2
    exit 1
  fi
  echo "== bin/ninja missing, falling back to ${NINJA} =="
fi

LEAN="${LEAN:-0}"

# Common args, mirroring SkiaSharp's native/ios/build.cake +
# scripts/infra/native/shared/native-shared.cake, plus static-lib mode.
COMMON_ARGS=(
  "is_official_build=true"
  "is_static_skiasharp=true"
  "skia_enable_tools=false"
  "skia_use_harfbuzz=false"
  "skia_use_icu=false"
  "skia_use_metal=true"
  "skia_enable_graphite=true"
  "skia_use_partition_alloc=false"
  "skia_use_piex=true"
  "skia_use_system_expat=false"
  "skia_use_system_libjpeg_turbo=false"
  "skia_use_system_libpng=false"
  "skia_use_system_libwebp=false"
  "skia_use_system_zlib=false"
  "skia_enable_skottie=true"
)

if [ "${LEAN}" = "1" ]; then
  COMMON_ARGS+=(
    "skia_use_gl=false"
    "skia_use_piex=false"
    "skia_use_dng_sdk=false"
  )
fi

EXTRA_CFLAGS=(
  "-DSKIA_C_DLL"
  "-DSK_AVOID_SLOW_RASTER_PIPELINE_BLURS"
  "-DSK_ENABLE_LEGACY_SHADERCONTEXT"
  "-DHAVE_ARC4RANDOM_BUF"
)
EXTRA_ASMFLAGS=()

case "${SLICE}" in
  iphoneos-arm64)
    SLICE_ARGS=(
      "target_os=\"ios\""
      "target_cpu=\"arm64\""
      "ios_use_simulator=false"
      "min_ios_version=\"${MIN_IOS}\""
    )
    ;;
  iphonesimulator-arm64)
    SLICE_ARGS=(
      "target_os=\"ios\""
      "target_cpu=\"arm64\""
      "ios_use_simulator=true"
      "min_ios_version=\"${MIN_IOS}\""
    )
    ;;
  xros-arm64)
    XROS_SDK="$(xcrun --sdk xros --show-sdk-path)"
    SLICE_ARGS=(
      "target_os=\"ios\""
      "target_cpu=\"arm64\""
      "ios_use_simulator=false"
      "min_ios_version=\"${MIN_IOS}\""
      "xcode_sysroot=\"${XROS_SDK}\""
    )
    EXTRA_CFLAGS+=("-target" "arm64-apple-xros1.0")
    EXTRA_ASMFLAGS+=("-target" "arm64-apple-xros1.0")
    ;;
  xrsimulator-arm64)
    XRSIM_SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
    SLICE_ARGS=(
      "target_os=\"ios\""
      "target_cpu=\"arm64\""
      "ios_use_simulator=true"
      "min_ios_version=\"${MIN_IOS}\""
      "xcode_sysroot=\"${XRSIM_SDK}\""
    )
    EXTRA_CFLAGS+=("-target" "arm64-apple-xros1.0-simulator")
    EXTRA_ASMFLAGS+=("-target" "arm64-apple-xros1.0-simulator")
    ;;
  macosx-arm64)
    SLICE_ARGS=(
      "target_os=\"mac\""
      "target_cpu=\"arm64\""
      "min_macos_version=\"${MIN_MACOS}\""
    )
    EXTRA_CFLAGS+=("-stdlib=libc++")
    ;;
  *)
    echo "ERROR: unknown slice '${SLICE}'" >&2
    exit 1
    ;;
esac

# Build the extra_cflags=[...] / extra_asmflags=[...] gn list literals.
join_gn_list() {
  local out="["
  local first=1
  for item in "$@"; do
    if [ "${first}" -eq 0 ]; then
      out+=","
    fi
    out+="\"${item}\""
    first=0
  done
  out+="]"
  printf '%s' "${out}"
}

CFLAGS_LITERAL="extra_cflags=$(join_gn_list "${EXTRA_CFLAGS[@]}")"
GN_ARGS=("${COMMON_ARGS[@]}" "${SLICE_ARGS[@]}" "${CFLAGS_LITERAL}")
if [ "${#EXTRA_ASMFLAGS[@]}" -gt 0 ]; then
  ASMFLAGS_LITERAL="extra_asmflags=$(join_gn_list "${EXTRA_ASMFLAGS[@]}")"
  GN_ARGS+=("${ASMFLAGS_LITERAL}")
fi

OUT_SUBDIR="out/${SLICE}"
OUT_DIR="${SKIA_DIR}/${OUT_SUBDIR}"

GN_ARGS_STRING="$(printf '%s ' "${GN_ARGS[@]}")"
echo "== gn gen ${OUT_SUBDIR} =="
echo "${GN_ARGS_STRING}"
(
  cd "${SKIA_DIR}"
  "${GN}" gen "${OUT_SUBDIR}" --args="${GN_ARGS_STRING}"
)

# Target names come from the skiasharp_build(...) gn templates; if the pinned
# commit renames them, adjust here (check BUILD.gn / gn/BUILDCONFIG.gn).
NINJA_TARGETS=("SkiaSharp" "HarfBuzzSharp")

echo "== ninja ${NINJA_TARGETS[*]} =="
(
  cd "${SKIA_DIR}"
  "${NINJA}" -C "${OUT_SUBDIR}" "${NINJA_TARGETS[@]}"
)

# gn's `complete_static_lib` does not fold the dependency archives into libSkiaSharp.a on
# Apple toolchains (the archive only carries the C API shims and a few objects), so every
# archive ninja produced except HarfBuzz is merged into one libSkiaSharp.a under merged/.
# HarfBuzz stays separate; it is its own module.
MERGED_DIR="${OUT_DIR}/merged"
rm -rf "${MERGED_DIR}"
mkdir -p "${MERGED_DIR}"
SKIA_INPUTS=()
for archive in "${OUT_DIR}"/*.a; do
  case "$(basename "${archive}")" in
    libHarfBuzzSharp.a) ;;
    *) SKIA_INPUTS+=("${archive}") ;;
  esac
done
echo "== Merging ${#SKIA_INPUTS[@]} archives into merged/libSkiaSharp.a =="
libtool -static -no_warning_for_no_symbols -o "${MERGED_DIR}/libSkiaSharp.a" "${SKIA_INPUTS[@]}"
cp "${OUT_DIR}/libHarfBuzzSharp.a" "${MERGED_DIR}/libHarfBuzzSharp.a"

for LIB in libSkiaSharp.a libHarfBuzzSharp.a; do
  LIB_PATH="${MERGED_DIR}/${LIB}"
  ARCHS="$(lipo -info "${LIB_PATH}" | sed -E 's/.*: //')"
  if [[ "${ARCHS}" == *"arm64e"* ]]; then
    echo "== Thinning ${LIB} (${ARCHS}) to arm64 =="
    lipo "${LIB_PATH}" -thin arm64 -output "${LIB_PATH}.thin"
    mv "${LIB_PATH}.thin" "${LIB_PATH}"
  fi
done

echo "== Verifying symbols =="
SKIA_LIB="${MERGED_DIR}/libSkiaSharp.a"
HB_LIB="${MERGED_DIR}/libHarfBuzzSharp.a"

SKIA_SYMBOL_COUNT="$(nm -g "${SKIA_LIB}" | grep -c ' T _sk_canvas_draw_path\| T _sk_pathop_op\| T _sk_surface_new_metal_layer' || true)"
if [ "${SKIA_SYMBOL_COUNT}" -lt 3 ]; then
  echo "ERROR: expected >= 3 SkiaSharp C API symbols, found ${SKIA_SYMBOL_COUNT}" >&2
  exit 1
fi

if ! nm -g "${HB_LIB}" | grep -q ' T _hb_shape$'; then
  echo "ERROR: _hb_shape not found in ${HB_LIB}" >&2
  exit 1
fi

echo "== Verifying LC_BUILD_VERSION platform =="
# otool -l prints the LC_BUILD_VERSION platform as a numeric code, not text:
# PLATFORM_MACOS=1, PLATFORM_IOS=2, PLATFORM_IOSSIMULATOR=7,
# PLATFORM_XROS=11, PLATFORM_XROS_SIMULATOR=12.
case "${SLICE}" in
  iphoneos-arm64) EXPECTED_PLATFORM_NAME="IOS"; EXPECTED_PLATFORM_CODE=2 ;;
  iphonesimulator-arm64) EXPECTED_PLATFORM_NAME="IOSSIMULATOR"; EXPECTED_PLATFORM_CODE=7 ;;
  xros-arm64) EXPECTED_PLATFORM_NAME="XROS"; EXPECTED_PLATFORM_CODE=11 ;;
  xrsimulator-arm64) EXPECTED_PLATFORM_NAME="XROS_SIMULATOR"; EXPECTED_PLATFORM_CODE=12 ;;
  macosx-arm64) EXPECTED_PLATFORM_NAME="MACOS"; EXPECTED_PLATFORM_CODE=1 ;;
esac

TMP_EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_EXTRACT_DIR}"' EXIT
# The member list is captured whole first: piping `ar -t` into `head -1` makes `ar` die of
# SIGPIPE on a large archive, and with `pipefail` that silently aborts the script.
ARCHIVE_MEMBERS="$(ar -t "${SKIA_LIB}")"
FIRST_OBJECT="$(awk '!/^__\.SYMDEF/ { print; exit }' <<<"${ARCHIVE_MEMBERS}")"
(
  cd "${TMP_EXTRACT_DIR}"
  ar -x "${SKIA_LIB}" "${FIRST_OBJECT}"
)
OTOOL_OUTPUT="$(otool -l "${TMP_EXTRACT_DIR}/${FIRST_OBJECT}")"
echo "${OTOOL_OUTPUT}" | grep -A4 LC_BUILD_VERSION || true
ACTUAL_PLATFORM_CODE="$(echo "${OTOOL_OUTPUT}" | grep -A3 LC_BUILD_VERSION | awk '/platform/ {print $2; exit}')"
if [ "${ACTUAL_PLATFORM_CODE}" != "${EXPECTED_PLATFORM_CODE}" ]; then
  echo "WARNING: expected LC_BUILD_VERSION platform ${EXPECTED_PLATFORM_NAME} (${EXPECTED_PLATFORM_CODE}), got '${ACTUAL_PLATFORM_CODE}' in ${FIRST_OBJECT}" >&2
else
  echo "LC_BUILD_VERSION platform confirmed: ${EXPECTED_PLATFORM_NAME} (${EXPECTED_PLATFORM_CODE})"
fi

echo "== Link smoke test =="
# Linking a program that calls into both libraries proves the merged archive is complete:
# any Skia object left out shows up here as an undefined symbol, which nm alone cannot tell.
case "${SLICE}" in
  iphoneos-arm64) LINK_TARGET="arm64-apple-ios${MIN_IOS}"; LINK_SDK=iphoneos; LINK_UI=1 ;;
  iphonesimulator-arm64) LINK_TARGET="arm64-apple-ios${MIN_IOS}-simulator"; LINK_SDK=iphonesimulator; LINK_UI=1 ;;
  xros-arm64) LINK_TARGET="arm64-apple-xros${MIN_VISIONOS}"; LINK_SDK=xros; LINK_UI=1 ;;
  xrsimulator-arm64) LINK_TARGET="arm64-apple-xros${MIN_VISIONOS}-simulator"; LINK_SDK=xrsimulator; LINK_UI=1 ;;
  macosx-arm64) LINK_TARGET="arm64-apple-macos${MIN_MACOS}"; LINK_SDK=macosx; LINK_UI=0 ;;
esac
LINK_FRAMEWORKS=(-framework Foundation -framework CoreFoundation -framework CoreGraphics
  -framework CoreText -framework ImageIO -framework Metal)
if [ "${LINK_UI}" = "1" ]; then
  LINK_FRAMEWORKS+=(-framework UIKit -framework MobileCoreServices)
else
  LINK_FRAMEWORKS+=(-framework AppKit -framework ApplicationServices)
fi
cat >"${TMP_EXTRACT_DIR}/smoke.c" <<'SMOKE'
#include "include/c/sk_canvas.h"
#include "include/c/sk_path.h"
#include "include/c/sk_surface.h"
#include "include/c/sk_document.h"
#include "include/c/sk_typeface.h"
#include "hb.h"
int main(void) {
  sk_imageinfo_t info = {0, 4, 4, RGBA_8888_SK_COLORTYPE, PREMUL_SK_ALPHATYPE};
  sk_surface_t* surface = sk_surface_new_raster(&info, 0, 0);
  sk_canvas_t* canvas = sk_surface_get_canvas(surface);
  sk_path_t* path = sk_path_new();
  sk_paint_t* paint = sk_paint_new();
  sk_canvas_draw_path(canvas, path, paint);
  sk_pathop_op(path, path, UNION_SK_PATHOP, path);
  sk_fontmgr_t* fontmgr = sk_fontmgr_create_default();
  hb_buffer_t* buffer = hb_buffer_create();
  hb_buffer_destroy(buffer);
  (void)fontmgr;
  sk_paint_delete(paint);
  sk_path_delete(path);
  sk_surface_unref(surface);
  return 0;
}
SMOKE
xcrun --sdk "${LINK_SDK}" clang -target "${LINK_TARGET}" \
  -I "${SKIA_DIR}" -I "${SKIA_DIR}/third_party/externals/harfbuzz/src" \
  "${TMP_EXTRACT_DIR}/smoke.c" "${SKIA_LIB}" "${HB_LIB}" -lc++ "${LINK_FRAMEWORKS[@]}" \
  -o "${TMP_EXTRACT_DIR}/smoke"
echo "link smoke test passed"

echo "== Summary =="
echo "Slice:        ${SLICE}"
echo "libSkiaSharp:    $(du -h "${SKIA_LIB}" | cut -f1)  ($(lipo -info "${SKIA_LIB}"))"
echo "libHarfBuzzSharp: $(du -h "${HB_LIB}" | cut -f1)  ($(lipo -info "${HB_LIB}"))"
echo "SkiaSharp C API symbol matches: ${SKIA_SYMBOL_COUNT}"
echo "Output dir: ${OUT_DIR}"
