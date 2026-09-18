#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

APPLE_SLICES=(iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64 xros-arm64 xrsimulator-arm64
  macosx-arm64 macosx-x86_64 maccatalyst-arm64 maccatalyst-x86_64)
LINUX_SLICES=(linux-arm64 linux-x64)

SLICE="${1:-}"
if [ -z "${SLICE}" ]; then
  echo "usage: $0 <slice>" >&2
  echo "  Apple slices: ${APPLE_SLICES[*]}" >&2
  echo "  Linux slices: ${LINUX_SLICES[*]} (built inside Docker when run on macOS)" >&2
  exit 1
fi

HOST_OS="$(uname -s)"

# Linux slices are built inside a container so the archives match the glibc / libstdc++ of the
# Swift Docker image consumers build against (see docker/Dockerfile). On a Linux host the
# script runs directly.
if [[ "${SLICE}" == linux-* ]] && [ "${HOST_OS}" != "Linux" ]; then
  exec "${SCRIPT_DIR}/docker-build-linux.sh" "${SLICE}"
fi

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"

PLATFORM="${SLICE%-*}"
ARCH="${SLICE##*-}"
case "${ARCH}" in
  arm64) GN_CPU="arm64" ;;
  x86_64 | x64) GN_CPU="x64" ;;
  *)
    echo "ERROR: unknown architecture '${ARCH}' in slice '${SLICE}'" >&2
    exit 1
    ;;
esac

# gn: Apple hosts use the binary bin/fetch-gn vendored into work/skia/bin; a Linux container
# needs its own build of the same gn revision, kept outside the Skia tree so the two never
# overwrite each other.
if [ "${HOST_OS}" = "Linux" ]; then
  GN="${WORK_DIR}/gn/linux-$(uname -m)/gn"
  if [ ! -x "${GN}" ]; then
    echo "== Fetching gn for linux-$(uname -m) =="
    GN_REV="$(grep -o "rev = '[0-9a-f]*'" "${SKIA_DIR}/bin/fetch-gn" | grep -o '[0-9a-f]\{40\}')"
    mkdir -p "$(dirname "${GN}")"
    python3 - "${GN_REV}" "$(dirname "${GN}")" <<'PY'
import platform, sys, tempfile, zipfile, os, stat
from urllib.request import urlopen
rev, out_dir = sys.argv[1], sys.argv[2]
cpu = {'aarch64': 'arm64', 'x86_64': 'amd64'}[platform.machine()]
url = f'https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-{cpu}/+/git_revision:{rev}'
zip_path = os.path.join(tempfile.mkdtemp(), 'gn.zip')
with open(zip_path, 'wb') as f:
    f.write(urlopen(url).read())
with zipfile.ZipFile(zip_path) as z:
    z.extract('gn', out_dir)
os.chmod(os.path.join(out_dir, 'gn'), stat.S_IRWXU | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)
PY
  fi
else
  GN="${SKIA_DIR}/bin/gn"
fi
if [ ! -x "${GN}" ]; then
  echo "ERROR: gn not found at ${GN} - run scripts/fetch.sh first" >&2
  exit 1
fi

# bin/fetch-ninja does not always vendor a `bin/ninja` binary (it may only
# write ninja.version for the DEPS-pinned release). Fall back to depot_tools'
# ninja, then a PATH ninja (Homebrew, or apt's ninja-build in the container).
NINJA="${SKIA_DIR}/bin/ninja"
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

# Common args, mirroring SkiaSharp's native/*/build.cake +
# scripts/infra/native/shared/native-shared.cake, plus static-lib mode.
COMMON_ARGS=(
  "is_official_build=true"
  "is_static_skiasharp=true"
  "skia_enable_tools=false"
  "skia_use_harfbuzz=false"
  "skia_use_icu=false"
  "skia_use_partition_alloc=false"
  "skia_use_piex=true"
  "skia_use_system_expat=false"
  "skia_use_system_libjpeg_turbo=false"
  "skia_use_system_libpng=false"
  "skia_use_system_libwebp=false"
  "skia_use_system_zlib=false"
  "skia_enable_skottie=true"
  "target_cpu=\"${GN_CPU}\""
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
)
EXTRA_ASMFLAGS=()

# Apple slices render through Metal (Ganesh and Graphite); Linux is raster-only. GL and Vulkan
# stay off on Linux so the static archive pulls in no windowing-system libraries: consumers
# only need fontconfig, which the SkiaSharp default font manager uses to find system fonts.
APPLE_ARGS=(
  "skia_use_metal=true"
  "skia_enable_graphite=true"
)
LINUX_ARGS=(
  "target_os=\"linux\""
  "cc=\"clang\""
  "cxx=\"clang++\""
  "skia_use_metal=false"
  "skia_enable_graphite=false"
  "skia_use_gl=false"
  "skia_use_egl=false"
  "skia_use_x11=false"
  "skia_use_vulkan=false"
  "skia_use_dawn=false"
  "skia_use_fontconfig=true"
  "skia_use_freetype=true"
  "skia_use_system_freetype2=false"
)

case "${SLICE}" in
  iphoneos-arm64)
    SLICE_ARGS=(
      "${APPLE_ARGS[@]}"
      "target_os=\"ios\""
      "ios_use_simulator=false"
      "min_ios_version=\"${MIN_IOS}\""
    )
    EXTRA_CFLAGS+=("-DHAVE_ARC4RANDOM_BUF")
    ;;
  iphonesimulator-arm64 | iphonesimulator-x86_64)
    SLICE_ARGS=(
      "${APPLE_ARGS[@]}"
      "target_os=\"ios\""
      "ios_use_simulator=true"
      "min_ios_version=\"${MIN_IOS}\""
    )
    EXTRA_CFLAGS+=("-DHAVE_ARC4RANDOM_BUF")
    ;;
  xros-arm64)
    XROS_SDK="$(xcrun --sdk xros --show-sdk-path)"
    SLICE_ARGS=(
      "${APPLE_ARGS[@]}"
      "target_os=\"ios\""
      "ios_use_simulator=false"
      "min_ios_version=\"${MIN_IOS}\""
      "xcode_sysroot=\"${XROS_SDK}\""
    )
    EXTRA_CFLAGS+=("-DHAVE_ARC4RANDOM_BUF" "-target" "arm64-apple-xros1.0")
    EXTRA_ASMFLAGS+=("-target" "arm64-apple-xros1.0")
    ;;
  xrsimulator-arm64)
    XRSIM_SDK="$(xcrun --sdk xrsimulator --show-sdk-path)"
    SLICE_ARGS=(
      "${APPLE_ARGS[@]}"
      "target_os=\"ios\""
      "ios_use_simulator=true"
      "min_ios_version=\"${MIN_IOS}\""
      "xcode_sysroot=\"${XRSIM_SDK}\""
    )
    EXTRA_CFLAGS+=("-DHAVE_ARC4RANDOM_BUF" "-target" "arm64-apple-xros1.0-simulator")
    EXTRA_ASMFLAGS+=("-target" "arm64-apple-xros1.0-simulator")
    ;;
  macosx-arm64 | macosx-x86_64)
    SLICE_ARGS=(
      "${APPLE_ARGS[@]}"
      "target_os=\"mac\""
      "min_macos_version=\"${MIN_MACOS}\""
    )
    EXTRA_CFLAGS+=("-DHAVE_ARC4RANDOM_BUF" "-stdlib=libc++")
    ;;
  maccatalyst-arm64 | maccatalyst-x86_64)
    # gn's "maccatalyst" target_os sets `-target <arch>-apple-ios<ver>-macabi` and the
    # iOSSupport framework search path itself; the macOS SDK is the sysroot.
    SLICE_ARGS=(
      "${APPLE_ARGS[@]}"
      "target_os=\"maccatalyst\""
      "min_maccatalyst_version=\"${MIN_MACCATALYST}\""
    )
    EXTRA_CFLAGS+=("-DHAVE_ARC4RANDOM_BUF" "-stdlib=libc++")
    ;;
  linux-arm64 | linux-x64)
    if [ "${HOST_OS}" != "Linux" ]; then
      echo "ERROR: ${SLICE} must be built on Linux (see docker/Dockerfile)" >&2
      exit 1
    fi
    SLICE_ARGS=("${LINUX_ARGS[@]}")
    # Skia's expat build compiles random_getrandom.c on Linux but generates no expat_config.h
    # that says how to reach getrandom(); glibc 2.25+ has it in <sys/random.h>.
    EXTRA_CFLAGS+=("-DHAVE_GETRANDOM")
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
# either toolchain (the archive only carries the C API shims and a few objects), so every
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
if [ "${HOST_OS}" = "Linux" ]; then
  # binutils ar has no `libtool -static`; an MRI script adds whole archives member by member.
  {
    echo "create ${MERGED_DIR}/libSkiaSharp.a"
    for archive in "${SKIA_INPUTS[@]}"; do
      echo "addlib ${archive}"
    done
    echo "save"
    echo "end"
  } | ar -M
else
  libtool -static -no_warning_for_no_symbols -o "${MERGED_DIR}/libSkiaSharp.a" "${SKIA_INPUTS[@]}"
fi
cp "${OUT_DIR}/libHarfBuzzSharp.a" "${MERGED_DIR}/libHarfBuzzSharp.a"

if [ "${HOST_OS}" != "Linux" ]; then
  for LIB in libSkiaSharp.a libHarfBuzzSharp.a; do
    LIB_PATH="${MERGED_DIR}/${LIB}"
    ARCHS="$(lipo -info "${LIB_PATH}" | sed -E 's/.*: //')"
    if [[ "${ARCHS}" == *"arm64e"* ]]; then
      echo "== Thinning ${LIB} (${ARCHS}) to arm64 =="
      lipo "${LIB_PATH}" -thin arm64 -output "${LIB_PATH}.thin"
      mv "${LIB_PATH}.thin" "${LIB_PATH}"
    fi
  done
fi

echo "== Verifying symbols =="
SKIA_LIB="${MERGED_DIR}/libSkiaSharp.a"
HB_LIB="${MERGED_DIR}/libHarfBuzzSharp.a"

# Mach-O prefixes C symbols with an underscore; ELF does not.
if [ "${HOST_OS}" = "Linux" ]; then
  SYM=""
  EXPECTED_SKIA_SYMBOLS=(sk_canvas_draw_path sk_pathop_op sk_surface_new_raster)
else
  SYM="_"
  EXPECTED_SKIA_SYMBOLS=(sk_canvas_draw_path sk_pathop_op sk_surface_new_metal_layer)
fi
SKIA_SYMBOL_COUNT=0
NM_OUTPUT="$(nm -g "${SKIA_LIB}" 2>/dev/null || true)"
for symbol in "${EXPECTED_SKIA_SYMBOLS[@]}"; do
  if grep -q " T ${SYM}${symbol}$" <<<"${NM_OUTPUT}"; then
    SKIA_SYMBOL_COUNT=$((SKIA_SYMBOL_COUNT + 1))
  fi
done
if [ "${SKIA_SYMBOL_COUNT}" -lt "${#EXPECTED_SKIA_SYMBOLS[@]}" ]; then
  echo "ERROR: expected ${#EXPECTED_SKIA_SYMBOLS[@]} SkiaSharp C API symbols, found ${SKIA_SYMBOL_COUNT}" >&2
  exit 1
fi

# `grep -q` closes the pipe as soon as it matches; with `pipefail` that turns nm's SIGPIPE into
# a failure of the whole pipeline, so nm's output is captured first.
HB_NM_OUTPUT="$(nm -g "${HB_LIB}" 2>/dev/null || true)"
if ! grep -q " T ${SYM}hb_shape$" <<<"${HB_NM_OUTPUT}"; then
  echo "ERROR: ${SYM}hb_shape not found in ${HB_LIB}" >&2
  exit 1
fi

TMP_EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_EXTRACT_DIR}"' EXIT

if [ "${HOST_OS}" = "Linux" ]; then
  echo "== Verifying ELF machine =="
  ARCHIVE_MEMBERS="$(ar -t "${SKIA_LIB}")"
  FIRST_OBJECT="$(awk '/\.o$/ { print; exit }' <<<"${ARCHIVE_MEMBERS}")"
  (
    cd "${TMP_EXTRACT_DIR}"
    ar -x "${SKIA_LIB}" "${FIRST_OBJECT}"
  )
  case "${SLICE}" in
    linux-arm64) EXPECTED_MACHINE="AArch64" ;;
    linux-x64) EXPECTED_MACHINE="X86-64" ;;
  esac
  ACTUAL_MACHINE="$(readelf -h "${TMP_EXTRACT_DIR}/${FIRST_OBJECT}" | awk -F: '/Machine/ { gsub(/^[ \t]+/, "", $2); print $2 }')"
  if [[ "${ACTUAL_MACHINE}" != *"${EXPECTED_MACHINE}"* ]]; then
    echo "ERROR: expected ELF machine ${EXPECTED_MACHINE}, got '${ACTUAL_MACHINE}' in ${FIRST_OBJECT}" >&2
    exit 1
  fi
  echo "ELF machine confirmed: ${ACTUAL_MACHINE}"
else
  echo "== Verifying LC_BUILD_VERSION platform =="
  # otool -l prints the LC_BUILD_VERSION platform as a numeric code, not text:
  # PLATFORM_MACOS=1, PLATFORM_IOS=2, PLATFORM_MACCATALYST=6, PLATFORM_IOSSIMULATOR=7,
  # PLATFORM_XROS=11, PLATFORM_XROS_SIMULATOR=12.
  case "${PLATFORM}" in
    iphoneos) EXPECTED_PLATFORM_NAME="IOS"; EXPECTED_PLATFORM_CODE=2 ;;
    iphonesimulator) EXPECTED_PLATFORM_NAME="IOSSIMULATOR"; EXPECTED_PLATFORM_CODE=7 ;;
    xros) EXPECTED_PLATFORM_NAME="XROS"; EXPECTED_PLATFORM_CODE=11 ;;
    xrsimulator) EXPECTED_PLATFORM_NAME="XROS_SIMULATOR"; EXPECTED_PLATFORM_CODE=12 ;;
    macosx) EXPECTED_PLATFORM_NAME="MACOS"; EXPECTED_PLATFORM_CODE=1 ;;
    maccatalyst) EXPECTED_PLATFORM_NAME="MACCATALYST"; EXPECTED_PLATFORM_CODE=6 ;;
  esac

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
fi

echo "== Link smoke test =="
# Linking a program that calls into both libraries proves the merged archive is complete:
# any Skia object left out shows up here as an undefined symbol, which nm alone cannot tell.
cat >"${TMP_EXTRACT_DIR}/smoke.c" <<'SMOKE'
#include "include/c/sk_canvas.h"
#include "include/c/sk_paint.h"
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
if [ "${HOST_OS}" = "Linux" ]; then
  # The same flags consumers get from the bundled pkg-config files (see make-linux-bundle.sh).
  clang -I "${SKIA_DIR}" -I "${SKIA_DIR}/third_party/externals/harfbuzz/src" \
    "${TMP_EXTRACT_DIR}/smoke.c" "${SKIA_LIB}" "${HB_LIB}" \
    -lfontconfig -lstdc++ -lm -lpthread -ldl \
    -o "${TMP_EXTRACT_DIR}/smoke"
  # The container's CPU matches the slice, so the program can also run: it exercises the
  # raster surface and the fontconfig font manager at startup.
  "${TMP_EXTRACT_DIR}/smoke"
  echo "link and run smoke test passed"
else
  case "${SLICE}" in
    iphoneos-arm64) LINK_TARGET="arm64-apple-ios${MIN_IOS}"; LINK_SDK=iphoneos; LINK_UI=1 ;;
    iphonesimulator-arm64) LINK_TARGET="arm64-apple-ios${MIN_IOS}-simulator"; LINK_SDK=iphonesimulator; LINK_UI=1 ;;
    iphonesimulator-x86_64) LINK_TARGET="x86_64-apple-ios${MIN_IOS}-simulator"; LINK_SDK=iphonesimulator; LINK_UI=1 ;;
    xros-arm64) LINK_TARGET="arm64-apple-xros${MIN_VISIONOS}"; LINK_SDK=xros; LINK_UI=1 ;;
    xrsimulator-arm64) LINK_TARGET="arm64-apple-xros${MIN_VISIONOS}-simulator"; LINK_SDK=xrsimulator; LINK_UI=1 ;;
    macosx-arm64) LINK_TARGET="arm64-apple-macos${MIN_MACOS}"; LINK_SDK=macosx; LINK_UI=0 ;;
    macosx-x86_64) LINK_TARGET="x86_64-apple-macos${MIN_MACOS}"; LINK_SDK=macosx; LINK_UI=0 ;;
    maccatalyst-arm64) LINK_TARGET="arm64-apple-ios${MIN_MACCATALYST}-macabi"; LINK_SDK=macosx; LINK_UI=2 ;;
    maccatalyst-x86_64) LINK_TARGET="x86_64-apple-ios${MIN_MACCATALYST}-macabi"; LINK_SDK=macosx; LINK_UI=2 ;;
  esac
  LINK_FRAMEWORKS=(-framework Foundation -framework CoreFoundation -framework CoreGraphics
    -framework CoreText -framework ImageIO -framework Metal)
  LINK_EXTRA=()
  case "${LINK_UI}" in
    1) LINK_FRAMEWORKS+=(-framework UIKit -framework MobileCoreServices) ;;
    0) LINK_FRAMEWORKS+=(-framework AppKit -framework ApplicationServices) ;;
    2)
      # Mac Catalyst: UIKit lives under the macOS SDK's iOSSupport tree.
      LINK_EXTRA+=(-iframework "$(xcrun --sdk macosx --show-sdk-path)/System/iOSSupport/System/Library/Frameworks")
      LINK_FRAMEWORKS+=(-framework UIKit)
      ;;
  esac
  xcrun --sdk "${LINK_SDK}" clang -target "${LINK_TARGET}" ${LINK_EXTRA[@]+"${LINK_EXTRA[@]}"} \
    -I "${SKIA_DIR}" -I "${SKIA_DIR}/third_party/externals/harfbuzz/src" \
    "${TMP_EXTRACT_DIR}/smoke.c" "${SKIA_LIB}" "${HB_LIB}" -lc++ "${LINK_FRAMEWORKS[@]}" \
    -o "${TMP_EXTRACT_DIR}/smoke"
  echo "link smoke test passed"
fi

echo "== Summary =="
echo "Slice:        ${SLICE}"
if [ "${HOST_OS}" = "Linux" ]; then
  echo "libSkiaSharp:    $(du -h "${SKIA_LIB}" | cut -f1)  (ELF ${ACTUAL_MACHINE})"
  echo "libHarfBuzzSharp: $(du -h "${HB_LIB}" | cut -f1)"
else
  echo "libSkiaSharp:    $(du -h "${SKIA_LIB}" | cut -f1)  ($(lipo -info "${SKIA_LIB}"))"
  echo "libHarfBuzzSharp: $(du -h "${HB_LIB}" | cut -f1)  ($(lipo -info "${HB_LIB}"))"
fi
echo "SkiaSharp C API symbol matches: ${SKIA_SYMBOL_COUNT}"
echo "Output dir: ${OUT_DIR}"
