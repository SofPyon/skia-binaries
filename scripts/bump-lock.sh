#!/usr/bin/env bash
# Advances skia.lock's pin to a new upstream branch or commit. Run scripts/fetch.sh
# afterwards to clone the new pin and resolve HARFBUZZ_COMMIT (see below).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${ROOT_DIR}/skia.lock"
# shellcheck disable=SC1090
source "${LOCK_FILE}"

usage() {
  cat <<'USAGE' >&2
usage: bump-lock.sh <branch|commit> [--milestone N] [--tag TAG]

  <branch|commit>  A branch on MONO_SKIA_REPO (typically release/X.Y.Z), or a
                    full 40-character commit SHA.
  --milestone N    Skia milestone number. Required for a raw commit, or for a
                    branch name that doesn't parse as release/X.Y.Z (its
                    milestone can't be derived from the name alone).
  --branch NAME    The branch the commit belongs to. Required for a raw commit:
                    MONO_SKIA_BRANCH is what scripts/check-upstream.sh measures
                    drift against, so leaving the previous branch in place would
                    make every later check report drift that cannot be resolved.
  --tag TAG        Override the derived RELEASE_TAG instead of computing one.

Rewrites MONO_SKIA_COMMIT, MONO_SKIA_BRANCH, SKIA_MILESTONE and RELEASE_TAG in
skia.lock in place, and blanks HARFBUZZ_COMMIT: the new pin's HarfBuzz commit
is unresolved until scripts/fetch.sh runs git-sync-deps against it.
USAGE
}

REF=""
MILESTONE_OVERRIDE=""
BRANCH_OVERRIDE=""
TAG_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --milestone)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --milestone requires a value" >&2
        exit 1
      }
      MILESTONE_OVERRIDE="$2"
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --branch requires a value" >&2
        exit 1
      }
      BRANCH_OVERRIDE="$2"
      shift 2
      ;;
    --tag)
      [ "$#" -ge 2 ] || {
        echo "ERROR: --tag requires a value" >&2
        exit 1
      }
      TAG_OVERRIDE="$2"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [ -n "${REF}" ]; then
        echo "ERROR: unexpected extra argument '$1'" >&2
        usage
        exit 1
      fi
      REF="$1"
      shift
      ;;
  esac
done

if [ -z "${REF}" ]; then
  usage
  exit 1
fi

OLD_MILESTONE="${SKIA_MILESTONE}"
OLD_RELEASE_TAG="${RELEASE_TAG}"

NEW_BRANCH=""
NEW_COMMIT=""
NEW_MILESTONE=""
BRANCH_NOTE=""

if [[ "${REF}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  NEW_COMMIT="$(printf '%s' "${REF}" | tr '[:upper:]' '[:lower:]')"
  if [ -z "${MILESTONE_OVERRIDE}" ]; then
    echo "ERROR: --milestone is required when passing a raw commit" >&2
    exit 1
  fi
  NEW_MILESTONE="${MILESTONE_OVERRIDE}"
  if [ -z "${BRANCH_OVERRIDE}" ]; then
    echo "ERROR: --branch is required when passing a raw commit" >&2
    echo "       MONO_SKIA_BRANCH is the ref scripts/check-upstream.sh measures drift against;" >&2
    echo "       keeping the previous branch alongside an unrelated commit makes every later" >&2
    echo "       check report drift that no bump can clear." >&2
    exit 1
  fi
  NEW_BRANCH="${BRANCH_OVERRIDE}"
  BRANCH_NOTE="a raw commit was given; MONO_SKIA_BRANCH was set from --branch - confirm the commit is on it"
else
  echo "== Resolving ${REF} on ${MONO_SKIA_REPO} ==" >&2
  RESOLVED_LINE="$(git ls-remote --heads "${MONO_SKIA_REPO}" "${REF}")"
  if [ -z "${RESOLVED_LINE}" ]; then
    echo "ERROR: branch '${REF}' not found on ${MONO_SKIA_REPO}" >&2
    exit 1
  fi
  NEW_COMMIT="$(printf '%s\n' "${RESOLVED_LINE}" | head -1 | awk '{print $1}')"
  NEW_BRANCH="${BRANCH_OVERRIDE:-${REF}}"
  if [ -n "${MILESTONE_OVERRIDE}" ]; then
    NEW_MILESTONE="${MILESTONE_OVERRIDE}"
  elif [[ "${REF}" =~ ^release/[0-9]+\.([0-9]+)\.(x|[0-9]+)(-preview\.[0-9]+|-rc\.[0-9]+)?$ ]]; then
    NEW_MILESTONE="${BASH_REMATCH[1]}"
  else
    echo "ERROR: cannot derive a milestone from branch name '${REF}' - pass --milestone" >&2
    exit 1
  fi
fi

if [ -n "${TAG_OVERRIDE}" ]; then
  NEW_RELEASE_TAG="${TAG_OVERRIDE}"
elif [ "${NEW_MILESTONE}" != "${OLD_MILESTONE}" ]; then
  NEW_RELEASE_TAG="skia-m${NEW_MILESTONE}-1"
elif [[ "${OLD_RELEASE_TAG}" =~ ^skia-m${OLD_MILESTONE}-([0-9]+)$ ]]; then
  NEW_RELEASE_TAG="skia-m${NEW_MILESTONE}-$((BASH_REMATCH[1] + 1))"
else
  echo "WARNING: existing RELEASE_TAG '${OLD_RELEASE_TAG}' doesn't match 'skia-m${OLD_MILESTONE}-N' - starting a new sequence" >&2
  NEW_RELEASE_TAG="skia-m${NEW_MILESTONE}-1"
fi

# MONO_SKIA_COMMIT's comment states the exact version pinned, so it goes stale on every bump
# and is regenerated below. Every other comment in the file describes something that stays
# true regardless of which commit is pinned, so line order and wording elsewhere are kept as-is.
if [ -n "${NEW_BRANCH}" ] && [[ "${NEW_BRANCH}" =~ ^release/([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  COMMIT_COMMENT="SkiaSharp v${BASH_REMATCH[1]} pin, Skia milestone ${NEW_MILESTONE}"
else
  COMMIT_COMMENT="pinned to ${REF}, Skia milestone ${NEW_MILESTONE}"
fi

TMP_LOCK="$(mktemp)"
trap 'rm -f "${TMP_LOCK}"' EXIT

awk -v new_commit="${NEW_COMMIT}" \
  -v commit_comment="${COMMIT_COMMENT}" \
  -v new_branch="${NEW_BRANCH}" \
  -v have_branch="$([ -n "${NEW_BRANCH}" ] && echo 1 || echo 0)" \
  -v new_milestone="${NEW_MILESTONE}" \
  -v new_tag="${NEW_RELEASE_TAG}" \
  '
  /^MONO_SKIA_COMMIT=/ { print "MONO_SKIA_COMMIT=" new_commit "   # " commit_comment; next }
  /^MONO_SKIA_BRANCH=/ {
    if (have_branch == "1") {
      sub(/^MONO_SKIA_BRANCH=[^ \t#]*/, "MONO_SKIA_BRANCH=" new_branch)
    }
    print
    next
  }
  /^SKIA_MILESTONE=/ { print "SKIA_MILESTONE=" new_milestone; next }
  /^RELEASE_TAG=/ { print "RELEASE_TAG=" new_tag; next }
  /^HARFBUZZ_COMMIT=/ {
    sub(/^HARFBUZZ_COMMIT=[^ \t#]*/, "HARFBUZZ_COMMIT=")
    print
    next
  }
  { print }
  ' "${LOCK_FILE}" >"${TMP_LOCK}"

mv "${TMP_LOCK}" "${LOCK_FILE}"
trap - EXIT

echo "== skia.lock updated =="
echo "MONO_SKIA_COMMIT=${NEW_COMMIT}"
if [ -n "${NEW_BRANCH}" ]; then
  echo "MONO_SKIA_BRANCH=${NEW_BRANCH}"
fi
if [ -n "${BRANCH_NOTE}" ]; then
  echo "NOTE: ${BRANCH_NOTE}"
fi
echo "SKIA_MILESTONE=${NEW_MILESTONE}"
echo "RELEASE_TAG=${NEW_RELEASE_TAG}"
echo "HARFBUZZ_COMMIT= (cleared - unresolved until scripts/fetch.sh runs)"
echo
echo "Next: run scripts/fetch.sh to clone the new pin and resolve HARFBUZZ_COMMIT."
