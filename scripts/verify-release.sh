#!/usr/bin/env bash
# Verifies that a built dist/ directory, or a published GitHub release, matches this repo's
# contract: all assets present, checksums correct, xcframework layout and Linux tarball
# contents as documented in README.md. Every check runs even after one fails, so a single
# run reports everything wrong instead of stopping at the first problem.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # skia.lock's path is resolved at runtime; shellcheck can't follow it statically
source "${ROOT_DIR}/skia.lock"

REPO="SofPyon/skia-binaries"

usage() {
  cat <<'USAGE' >&2
usage: verify-release.sh [--dist <dir>] [--tag <tag>]

  --dist <dir>  Directory of built release assets to verify (default: dist).
  --tag <tag>   Download a published release's assets (~155MB) into a
                temporary directory, verify them, then delete the download.
                Mutually exclusive with --dist.

Exits non-zero if any check fails; all checks run regardless of earlier
failures, and every failure is listed at the end.
USAGE
}

DIST_DIR="${ROOT_DIR}/dist"
TAG=""
DIST_DIR_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dist)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --dist requires a value" >&2
        exit 1
      }
      DIST_DIR="$2"
      DIST_DIR_SET=1
      shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --tag requires a value" >&2
        exit 1
      }
      TAG="$2"
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

if [ -n "${TAG}" ] && [ "${DIST_DIR_SET}" -eq 1 ]; then
  echo "ERROR: --dist and --tag are mutually exclusive" >&2
  exit 1
fi

FAILURES=()
fail() {
  FAILURES+=("$1")
  echo "FAIL: $1" >&2
}
pass() {
  echo "PASS: $1"
}
skip() {
  echo "SKIP: $1"
}

CLEANUP_DIR=""
PLIST_LOOKUP_PY=""
# SC2317/SC2329 are the same finding under different shellcheck versions: this is only ever
# called indirectly, via the `trap ... EXIT` below.
# shellcheck disable=SC2317,SC2329
cleanup() {
  # Separate `if`s rather than `[ ... ] && ...`: under `set -e` a false test in the first line
  # would return from the function and leak the second temporary.
  if [ -n "${CLEANUP_DIR}" ]; then
    rm -rf "${CLEANUP_DIR}"
  fi
  if [ -n "${PLIST_LOOKUP_PY}" ]; then
    rm -f "${PLIST_LOOKUP_PY}"
  fi
}
trap cleanup EXIT

# A real script file, not a heredoc on the same command: `python3 - <<PY` would make the
# heredoc *be* the script's stdin, leaving nothing for json.load(sys.stdin) to read from the
# piped Info.plist JSON.
PLIST_LOOKUP_PY="$(mktemp)"
cat >"${PLIST_LOOKUP_PY}" <<'PY'
import json, sys
platform, variant = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
for lib in data["AvailableLibraries"]:
    lib_variant = lib.get("SupportedPlatformVariant")
    want_variant = None if variant == "null" else variant
    if lib.get("SupportedPlatform") == platform and lib_variant == want_variant:
        print(lib["LibraryIdentifier"] + "|" + ",".join(sorted(lib["SupportedArchitectures"])))
        break
PY

IS_TAG_MODE=0
if [ -n "${TAG}" ]; then
  IS_TAG_MODE=1
  CLEANUP_DIR="$(mktemp -d)"
  DIST_DIR="${CLEANUP_DIR}/assets"
  mkdir -p "${DIST_DIR}"
  echo "== Downloading release assets for ${TAG} (~155MB) =="
  gh release download "${TAG}" --repo "${REPO}" --dir "${DIST_DIR}" --clobber
fi

if [ ! -d "${DIST_DIR}" ]; then
  echo "ERROR: dist directory '${DIST_DIR}' does not exist" >&2
  exit 1
fi

HAVE_PLUTIL=0
command -v plutil >/dev/null 2>&1 && HAVE_PLUTIL=1
HAVE_LIPO=0
command -v lipo >/dev/null 2>&1 && HAVE_LIPO=1
if [ "${HAVE_PLUTIL}" -eq 0 ]; then
  skip "xcframework Info.plist / architecture checks (plutil not available on this host)"
fi
if [ "${HAVE_LIPO}" -eq 0 ]; then
  skip "xcframework binary architecture checks (lipo not available on this host)"
fi

# --- 1. required assets -----------------------------------------------------
echo "== Checking required assets =="
REQUIRED_ASSETS=(
  libSkiaSharp.xcframework.zip
  libHarfBuzzSharp.xcframework.zip
  skiasharp-linux-arm64.tar.gz
  skiasharp-linux-x64.tar.gz
  CHECKSUMS.txt
  THIRD_PARTY_NOTICES.txt
)
for asset in "${REQUIRED_ASSETS[@]}"; do
  if [ -f "${DIST_DIR}/${asset}" ]; then
    pass "asset present: ${asset}"
  else
    fail "asset missing: ${asset}"
  fi
done

# LICENSES.zip ships in every published release but is only produced locally once
# scripts/collect-licenses.sh has run, so --dist requires it and --tag merely notes it.
if [ -f "${DIST_DIR}/LICENSES.zip" ]; then
  pass "asset present: LICENSES.zip"
elif [ "${IS_TAG_MODE}" -eq 1 ]; then
  skip "LICENSES.zip not present in this release"
else
  fail "asset missing: LICENSES.zip"
fi

# --- 2. CHECKSUMS.txt matches the actual files ------------------------------
echo "== Verifying CHECKSUMS.txt =="
if [ -f "${DIST_DIR}/CHECKSUMS.txt" ]; then
  CURRENT_FILE=""
  while IFS= read -r line; do
    case "${line}" in
      "")
        ;;
      " "* | $'\t'*)
        case "${line}" in
          *sha256:*)
            EXPECTED="${line##* }"
            TARGET="${DIST_DIR}/${CURRENT_FILE}"
            if [ ! -f "${TARGET}" ]; then
              fail "CHECKSUMS.txt references ${CURRENT_FILE}, which is missing"
            else
              ACTUAL="$(shasum -a 256 "${TARGET}" | awk '{print $1}')"
              if [ "${ACTUAL}" = "${EXPECTED}" ]; then
                pass "sha256 matches: ${CURRENT_FILE}"
              else
                fail "sha256 mismatch for ${CURRENT_FILE}: expected ${EXPECTED}, got ${ACTUAL}"
              fi
            fi
            ;;
        esac
        ;;
      *)
        CURRENT_FILE="${line}"
        ;;
    esac
  done <"${DIST_DIR}/CHECKSUMS.txt"
else
  fail "cannot verify checksums: CHECKSUMS.txt is missing"
fi

# --- 3-5. xcframework layout -------------------------------------------------
# Platform key -> "SupportedPlatform SupportedPlatformVariant expected,architectures".
# SupportedPlatformVariant is "-" when the plist entry has none (plain ios/macos/xros).
XCFRAMEWORK_PLATFORMS="
iphoneos ios - arm64
iphonesimulator ios simulator arm64,x86_64
xros xros - arm64
xrsimulator xros simulator arm64
macosx macos - arm64,x86_64
maccatalyst ios maccatalyst arm64,x86_64
"

verify_xcframework() {
  local zip_name="$1" fw_name="$2" header_check="$3"
  local zip_path="${DIST_DIR}/${zip_name}"
  if [ ! -f "${zip_path}" ]; then
    fail "cannot verify ${zip_name}: file missing"
    return
  fi

  local extract_dir
  extract_dir="$(mktemp -d)"
  if ! unzip -q "${zip_path}" -d "${extract_dir}"; then
    fail "${zip_name}: failed to unzip"
    rm -rf "${extract_dir}"
    return
  fi
  local fw_dir="${extract_dir}/${fw_name}"
  if [ ! -d "${fw_dir}" ]; then
    fail "${zip_name}: ${fw_name} not found after unzip"
    rm -rf "${extract_dir}"
    return
  fi

  # This layout is intentional (see README.md): SwiftPM merges every binary target's headers
  # into one shared include directory, so a root module.modulemap here would collide with the
  # other xcframework's. Regressing this silently breaks consumers, hence the explicit check.
  if find "${fw_dir}" -maxdepth 2 -name 'module.modulemap' | grep -q .; then
    fail "${zip_name}: found a module.modulemap under a Headers root (must not ship one)"
  else
    pass "${zip_name}: no module.modulemap under any Headers root"
  fi

  if [ "${HAVE_PLUTIL}" -eq 1 ]; then
    local plist_json
    plist_json="$(plutil -convert json -o - "${fw_dir}/Info.plist" 2>/dev/null)" || {
      fail "${zip_name}: failed to parse Info.plist"
      rm -rf "${extract_dir}"
      return
    }
    local lib_count
    lib_count="$(printf '%s' "${plist_json}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["AvailableLibraries"]))')"
    if [ "${lib_count}" != "6" ]; then
      fail "${zip_name}: expected 6 AvailableLibraries, found ${lib_count}"
    fi

    while IFS=' ' read -r key platform variant expected_archs; do
      [ -n "${key}" ] || continue
      local match_variant="${variant}"
      [ "${match_variant}" = "-" ] && match_variant="null"
      local entry
      entry="$(printf '%s' "${plist_json}" | python3 "${PLIST_LOOKUP_PY}" "${platform}" "${match_variant}")"
      if [ -z "${entry}" ]; then
        fail "${zip_name}: no AvailableLibraries entry for platform=${platform} variant=${variant} (${key})"
        continue
      fi
      local lib_id actual_archs
      lib_id="${entry%%|*}"
      actual_archs="${entry#*|}"
      local expected_sorted
      expected_sorted="$(printf '%s\n' "${expected_archs}" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')"
      if [ "${actual_archs}" = "${expected_sorted}" ]; then
        pass "${zip_name} [${key}]: declared architectures ${actual_archs}"
      else
        fail "${zip_name} [${key}]: declared architectures '${actual_archs}', expected '${expected_sorted}'"
      fi

      local lib_path="${fw_dir}/${lib_id}/${fw_name%.xcframework}.a"
      if [ "${HAVE_LIPO}" -eq 1 ] && [ -f "${lib_path}" ]; then
        local lipo_archs
        lipo_archs="$(lipo -archs "${lib_path}" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//')"
        if [ "${lipo_archs}" = "${expected_sorted}" ]; then
          pass "${zip_name} [${key}]: lipo confirms architectures ${lipo_archs}"
        else
          fail "${zip_name} [${key}]: lipo reports '${lipo_archs}', expected '${expected_sorted}'"
        fi
      fi

      if [ -n "${header_check}" ]; then
        if [ -f "${fw_dir}/${lib_id}/Headers/${header_check}" ]; then
          pass "${zip_name} [${key}]: header at Headers/${header_check}"
        else
          fail "${zip_name} [${key}]: missing Headers/${header_check}"
        fi
      fi
    done <<<"${XCFRAMEWORK_PLATFORMS}"
  fi

  rm -rf "${extract_dir}"
}

echo "== Verifying libSkiaSharp.xcframework.zip =="
verify_xcframework "libSkiaSharp.xcframework.zip" "libSkiaSharp.xcframework" "include/c/sk_types.h"

echo "== Verifying libHarfBuzzSharp.xcframework.zip =="
verify_xcframework "libHarfBuzzSharp.xcframework.zip" "libHarfBuzzSharp.xcframework" "harfbuzz/hb.h"

# --- 6-7. Linux tarballs -----------------------------------------------------
verify_linux_tarball() {
  local tarball_name="$1"
  local tarball_path="${DIST_DIR}/${tarball_name}"
  if [ ! -f "${tarball_path}" ]; then
    fail "cannot verify ${tarball_name}: file missing"
    return
  fi
  local bundle_name="${tarball_name%.tar.gz}"
  local extract_dir
  extract_dir="$(mktemp -d)"
  if ! tar xzf "${tarball_path}" -C "${extract_dir}"; then
    fail "${tarball_name}: failed to extract"
    rm -rf "${extract_dir}"
    return
  fi
  local bundle_dir="${extract_dir}/${bundle_name}"

  local expected_files=(
    "lib/libSkiaSharp.a"
    "lib/libHarfBuzzSharp.a"
    "lib/pkgconfig/SkiaSharp.pc"
    "lib/pkgconfig/HarfBuzzSharp.pc"
    "include/SkiaSharp/include/c/sk_types.h"
    "include/HarfBuzzSharp/harfbuzz/hb.h"
    "BUILD-INFO.txt"
  )
  for rel in "${expected_files[@]}"; do
    if [ -f "${bundle_dir}/${rel}" ]; then
      pass "${tarball_name}: ${rel} present"
    else
      fail "${tarball_name}: ${rel} missing"
    fi
  done

  if [ -f "${bundle_dir}/BUILD-INFO.txt" ]; then
    local recorded_commit
    recorded_commit="$(awk -F= '/^MONO_SKIA_COMMIT=/ { print $2 }' "${bundle_dir}/BUILD-INFO.txt")"
    if [ "${recorded_commit}" = "${MONO_SKIA_COMMIT}" ]; then
      pass "${tarball_name}: BUILD-INFO.txt MONO_SKIA_COMMIT matches skia.lock"
    else
      fail "${tarball_name}: BUILD-INFO.txt MONO_SKIA_COMMIT is '${recorded_commit}', skia.lock has '${MONO_SKIA_COMMIT}'"
    fi
  fi

  rm -rf "${extract_dir}"
}

echo "== Verifying skiasharp-linux-arm64.tar.gz =="
verify_linux_tarball "skiasharp-linux-arm64.tar.gz"
echo "== Verifying skiasharp-linux-x64.tar.gz =="
verify_linux_tarball "skiasharp-linux-x64.tar.gz"

# --- summary -----------------------------------------------------------------
echo
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "== All checks passed =="
  exit 0
fi

echo "== ${#FAILURES[@]} check(s) failed ==" >&2
for f in "${FAILURES[@]}"; do
  echo "  - ${f}" >&2
done
exit 1
