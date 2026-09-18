#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${ROOT_DIR}/skia.lock"

WORK_DIR="${ROOT_DIR}/work"
SKIA_DIR="${WORK_DIR}/skia"

mkdir -p "${WORK_DIR}"

if [ -d "${SKIA_DIR}/.git" ]; then
  echo "== work/skia already exists, skipping clone =="
else
  echo "== Cloning ${MONO_SKIA_REPO} =="
  git clone "${MONO_SKIA_REPO}" "${SKIA_DIR}"
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
  HARFBUZZ_COMMIT="$(git -C "${HARFBUZZ_DIR}" rev-parse HEAD)"
else
  echo "ERROR: ${HARFBUZZ_DIR} not found after git-sync-deps" >&2
  exit 1
fi

BUILD_INFO="${WORK_DIR}/BUILD-INFO.txt"
{
  echo "MONO_SKIA_COMMIT=${MONO_SKIA_COMMIT}"
  echo "SKIA_MILESTONE=${SKIA_MILESTONE}"
  echo "HARFBUZZ_COMMIT=${HARFBUZZ_COMMIT}"
  echo "FETCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${BUILD_INFO}"

echo "== Done =="
echo "Resolved HarfBuzz commit: ${HARFBUZZ_COMMIT}"
echo "Recorded in ${BUILD_INFO}"
