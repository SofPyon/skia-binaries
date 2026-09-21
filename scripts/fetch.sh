#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${ROOT_DIR}/skia.lock"
# shellcheck disable=SC1090
source "${LOCK_FILE}"
# Captured before anything below reuses the HARFBUZZ_COMMIT name for the commit this run
# actually resolves, so the two can be compared.
LOCK_HARFBUZZ_COMMIT="${HARFBUZZ_COMMIT}"

usage() {
  cat <<'USAGE' >&2
usage: fetch.sh [--update-lock]

Clones (or reuses) MONO_SKIA_COMMIT into work/skia and syncs its dependencies.

  --update-lock  If the HarfBuzz commit resolved via git-sync-deps differs from
                 skia.lock's HARFBUZZ_COMMIT, overwrite skia.lock with the
                 resolved value instead of failing. Use this after moving
                 MONO_SKIA_COMMIT by hand; scripts/bump-lock.sh already blanks
                 HARFBUZZ_COMMIT so the normal run just fills it in.

Env:
  SKIA_FETCH_DEPTH=0  Force a full clone instead of the default depth-1 fetch
                       of the pinned commit.
USAGE
}

UPDATE_LOCK=0
for arg in "$@"; do
  case "${arg}" in
    --update-lock)
      UPDATE_LOCK=1
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

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"

mkdir -p "${WORK_DIR}"

update_lock_value() {
  # Rewrites one KEY=value line in skia.lock, keeping its trailing comment and every other
  # line untouched (same approach as bump-lock.sh).
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    index($0, key "=") == 1 { sub(/=[^ \t#]*/, "=" value); print; next }
    { print }
  ' "${LOCK_FILE}" >"${tmp}"
  mv "${tmp}" "${LOCK_FILE}"
}

if [ -d "${SKIA_DIR}/.git" ]; then
  echo "== work/skia already exists, skipping clone =="
else
  SKIA_FETCH_DEPTH="${SKIA_FETCH_DEPTH:-1}"
  if [ "${SKIA_FETCH_DEPTH}" = "0" ]; then
    echo "== Cloning ${MONO_SKIA_REPO} (SKIA_FETCH_DEPTH=0: full history) =="
    git clone "${MONO_SKIA_REPO}" "${SKIA_DIR}"
  else
    echo "== Shallow-fetching ${MONO_SKIA_COMMIT} from ${MONO_SKIA_REPO} =="
    # GitHub serves an arbitrary commit SHA directly (not just branch tips), so a depth-1
    # fetch of the pinned commit avoids downloading Skia's full history, which is large.
    mkdir -p "${SKIA_DIR}"
    if (
      cd "${SKIA_DIR}" &&
        git init -q &&
        git remote add origin "${MONO_SKIA_REPO}" &&
        git fetch --depth 1 origin "${MONO_SKIA_COMMIT}" &&
        git checkout --detach FETCH_HEAD
    ); then
      echo "Shallow fetch succeeded"
    else
      echo "== Shallow fetch failed - falling back to a full clone ==" >&2
      rm -rf "${SKIA_DIR}"
      git clone "${MONO_SKIA_REPO}" "${SKIA_DIR}"
    fi
  fi
fi

echo "== Checking out ${MONO_SKIA_COMMIT} =="
git -C "${SKIA_DIR}" fetch origin "${MONO_SKIA_COMMIT}" || true
git -C "${SKIA_DIR}" checkout --detach "${MONO_SKIA_COMMIT}"

echo "== Syncing dependencies (git-sync-deps) =="
(
  cd "${SKIA_DIR}"
  GIT_SYNC_DEPS_QUIET=1 python3 tools/git-sync-deps
)

echo "== Fetching gn and ninja =="
(
  cd "${SKIA_DIR}"
  bin/fetch-gn
  bin/fetch-ninja
)

echo "== Verifying milestone =="
MILESTONE_HEADER="${SKIA_DIR}/include/core/SkMilestone.h"
if [ ! -f "${MILESTONE_HEADER}" ]; then
  echo "ERROR: ${MILESTONE_HEADER} not found" >&2
  exit 1
fi
if ! grep -q "SK_MILESTONE ${SKIA_MILESTONE}" "${MILESTONE_HEADER}"; then
  echo "ERROR: SkMilestone.h does not report milestone ${SKIA_MILESTONE}:" >&2
  cat "${MILESTONE_HEADER}" >&2
  exit 1
fi
echo "SkMilestone.h confirms milestone ${SKIA_MILESTONE}"

HARFBUZZ_DIR="${SKIA_DIR}/third_party/externals/harfbuzz"
if [ -d "${HARFBUZZ_DIR}/.git" ]; then
  RESOLVED_HARFBUZZ_COMMIT="$(git -C "${HARFBUZZ_DIR}" rev-parse HEAD)"
else
  echo "ERROR: ${HARFBUZZ_DIR} not found after git-sync-deps" >&2
  exit 1
fi

# skia.lock's HARFBUZZ_COMMIT is a contract, not a cache: DEPS pins HarfBuzz indirectly
# through MONO_SKIA_COMMIT, and a silent mismatch here would mean two builds of the same
# lock file could pull different HarfBuzz sources without anyone noticing.
echo "== Verifying HARFBUZZ_COMMIT against skia.lock =="
if [ -z "${LOCK_HARFBUZZ_COMMIT}" ]; then
  echo "skia.lock has no HARFBUZZ_COMMIT yet - recording ${RESOLVED_HARFBUZZ_COMMIT}"
  update_lock_value "HARFBUZZ_COMMIT" "${RESOLVED_HARFBUZZ_COMMIT}"
elif [ "${LOCK_HARFBUZZ_COMMIT}" = "${RESOLVED_HARFBUZZ_COMMIT}" ]; then
  echo "HARFBUZZ_COMMIT matches skia.lock (${RESOLVED_HARFBUZZ_COMMIT})"
elif [ "${UPDATE_LOCK}" -eq 1 ]; then
  echo "HARFBUZZ_COMMIT mismatch - updating skia.lock (--update-lock): ${LOCK_HARFBUZZ_COMMIT} -> ${RESOLVED_HARFBUZZ_COMMIT}"
  update_lock_value "HARFBUZZ_COMMIT" "${RESOLVED_HARFBUZZ_COMMIT}"
else
  echo "ERROR: HARFBUZZ_COMMIT mismatch: skia.lock has ${LOCK_HARFBUZZ_COMMIT}, but MONO_SKIA_COMMIT now resolves to ${RESOLVED_HARFBUZZ_COMMIT}." >&2
  echo "Re-run with --update-lock to accept the new value, or investigate why DEPS moved." >&2
  exit 1
fi
HARFBUZZ_COMMIT="${RESOLVED_HARFBUZZ_COMMIT}"

BUILD_INFO="${WORK_DIR}/BUILD-INFO.txt"
{
  echo "MONO_SKIA_COMMIT=${MONO_SKIA_COMMIT}"
  echo "MONO_SKIA_BRANCH=${MONO_SKIA_BRANCH}"
  echo "SKIA_MILESTONE=${SKIA_MILESTONE}"
  echo "HARFBUZZ_COMMIT=${HARFBUZZ_COMMIT}"
  echo "FETCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"${BUILD_INFO}"

echo "== Done =="
echo "Resolved HarfBuzz commit: ${HARFBUZZ_COMMIT}"
echo "Recorded in ${BUILD_INFO}"
