#!/usr/bin/env bash
# Validates skia.lock's shape: every other script `source`s it, so a missing or empty
# variable there fails deep inside a build instead of up front. Kept as its own script
# (rather than inlined in a workflow) so it can be run the same way locally and in CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${1:-${ROOT_DIR}/skia.lock}"

if [ ! -f "${LOCK_FILE}" ]; then
  echo "ERROR: lock file '${LOCK_FILE}' does not exist" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${LOCK_FILE}"

# HARFBUZZ_COMMIT is intentionally excluded: scripts/bump-lock.sh blanks it, and
# scripts/fetch.sh is what fills it back in, so an empty value here is a valid mid-bump state.
REQUIRED_VARS=(
  MONO_SKIA_REPO
  MONO_SKIA_COMMIT
  MONO_SKIA_BRANCH
  SKIA_MILESTONE
  RELEASE_TAG
  MIN_IOS
  MIN_MACOS
  MIN_VISIONOS
  MIN_MACCATALYST
)

MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    MISSING+=("${var}")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: ${LOCK_FILE} is missing a value for: ${MISSING[*]}" >&2
  exit 1
fi

echo "OK: ${LOCK_FILE} is well-formed"
