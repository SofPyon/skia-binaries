#!/usr/bin/env bash
# Reports how far skia.lock's pin is behind mono/skia, using only
# `git ls-remote --heads` (no clone, no gh, no network access beyond that one call).
#
# Exit codes (also documented in usage()): 0 = pin is current, 10 = an update is
# available (drift, a newer patch, or a newer milestone), 1 = the check itself failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090,SC1091  # skia.lock's path is resolved at runtime; shellcheck can't follow it statically
source "${ROOT_DIR}/skia.lock"

usage() {
  cat <<'USAGE' >&2
usage: check-upstream.sh [--format=text|json|markdown]

Compares skia.lock's MONO_SKIA_BRANCH/MONO_SKIA_COMMIT against the current
state of MONO_SKIA_REPO (via `git ls-remote --heads`, no clone) and reports:
  - ref drift: MONO_SKIA_BRANCH has moved past MONO_SKIA_COMMIT
  - same-milestone patches newer than the pinned one
  - newer milestones, stable and provisional (-preview.N/-rc.N/.x) separately
  - skia-sync/m<N> branches ahead of the pinned milestone, for reference

Exit codes:
  0   pin is up to date
  10  an update is available (drift, newer patch, and/or newer milestone)
  1   the check failed (bad skia.lock, network error, ...)
USAGE
}

FORMAT="text"
for arg in "$@"; do
  case "${arg}" in
    --format=text | --format=json | --format=markdown)
      FORMAT="${arg#--format=}"
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

if [[ ! "${MONO_SKIA_BRANCH:-}" =~ ^release/([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "ERROR: MONO_SKIA_BRANCH ('${MONO_SKIA_BRANCH:-}') is not set or not of the form release/X.Y.Z" >&2
  exit 1
fi
CUR_MAJOR="${BASH_REMATCH[1]}"
CUR_MILESTONE="${BASH_REMATCH[2]}"
CUR_PATCH="${BASH_REMATCH[3]}"

echo "== Fetching refs from ${MONO_SKIA_REPO} ==" >&2
REMOTE_HEADS="$(git ls-remote --heads "${MONO_SKIA_REPO}")" || {
  echo "ERROR: git ls-remote --heads ${MONO_SKIA_REPO} failed" >&2
  exit 1
}
if [ -z "${REMOTE_HEADS}" ]; then
  echo "ERROR: git ls-remote returned no refs for ${MONO_SKIA_REPO}" >&2
  exit 1
fi

# --- ref drift -------------------------------------------------------------
CURRENT_TIP="$(printf '%s\n' "${REMOTE_HEADS}" | awk -v b="refs/heads/${MONO_SKIA_BRANCH}" '$2 == b { print $1; exit }')"
DRIFTED=0
BRANCH_MISSING=0
if [ -z "${CURRENT_TIP}" ]; then
  BRANCH_MISSING=1
elif [ "${CURRENT_TIP}" != "${MONO_SKIA_COMMIT}" ]; then
  DRIFTED=1
fi

# --- same-milestone patches newer than the pinned one -----------------------
# Numeric-only comparison (no sort -V) to avoid BSD/GNU sort differences.
SAME_MILESTONE_PATCHES=()
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  SHA="$(awk '{print $1}' <<<"${line}")"
  BRANCH="$(awk '{print $2}' <<<"${line}" | sed 's#^refs/heads/##')"
  PATCH="${BRANCH##*.}"
  if [ "${PATCH}" -gt "${CUR_PATCH}" ] 2>/dev/null; then
    SAME_MILESTONE_PATCHES+=("${BRANCH}|${SHA}|${PATCH}")
  fi
done < <(printf '%s\n' "${REMOTE_HEADS}" | grep -E "	refs/heads/release/${CUR_MAJOR}\.${CUR_MILESTONE}\.[0-9]+\$" || true)

# --- newer milestones: stable vs. provisional -------------------------------
NEW_MILESTONE_STABLE=()
NEW_MILESTONE_PROVISIONAL=()
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  SHA="$(awk '{print $1}' <<<"${line}")"
  BRANCH="$(awk '{print $2}' <<<"${line}" | sed 's#^refs/heads/##')"
  if [[ "${BRANCH}" =~ ^release/${CUR_MAJOR}\.([0-9]+)\.(x|[0-9]+)(-preview\.[0-9]+|-rc\.[0-9]+)?$ ]]; then
    MILESTONE="${BASH_REMATCH[1]}"
    PATCH="${BASH_REMATCH[2]}"
    SUFFIX="${BASH_REMATCH[3]}"
    if [ "${MILESTONE}" -gt "${CUR_MILESTONE}" ] 2>/dev/null; then
      if [ -z "${SUFFIX}" ] && [ "${PATCH}" != "x" ]; then
        NEW_MILESTONE_STABLE+=("${BRANCH}|${SHA}|${MILESTONE}|${PATCH}")
      else
        KIND="floating"
        case "${SUFFIX}" in
          -preview.*) KIND="preview" ;;
          -rc.*) KIND="rc" ;;
        esac
        NEW_MILESTONE_PROVISIONAL+=("${BRANCH}|${SHA}|${MILESTONE}|${KIND}")
      fi
    fi
  fi
done < <(printf '%s\n' "${REMOTE_HEADS}" | grep -E "	refs/heads/release/${CUR_MAJOR}\." || true)

# --- skia-sync/m<N> branches ahead of the pinned milestone, for reference ---
SYNC_NEWER=()
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  SHA="$(awk '{print $1}' <<<"${line}")"
  BRANCH="$(awk '{print $2}' <<<"${line}" | sed 's#^refs/heads/##')"
  if [[ "${BRANCH}" =~ ^skia-sync/m([0-9]+)$ ]]; then
    MILESTONE="${BASH_REMATCH[1]}"
    if [ "${MILESTONE}" -gt "${CUR_MILESTONE}" ] 2>/dev/null; then
      SYNC_NEWER+=("${BRANCH}|${SHA}|${MILESTONE}")
    fi
  fi
done < <(printf '%s\n' "${REMOTE_HEADS}" | grep -E "	refs/heads/skia-sync/" || true)

# --- recommendation: the highest stable branch among the newer ones --------
REC_BRANCH=""
REC_SHA=""
REC_MILESTONE=0
REC_PATCH=0
consider_stable() {
  local branch="$1" sha="$2" milestone="$3" patch="$4"
  if [ "${milestone}" -gt "${REC_MILESTONE}" ] || { [ "${milestone}" -eq "${REC_MILESTONE}" ] && [ "${patch}" -gt "${REC_PATCH}" ]; }; then
    REC_BRANCH="${branch}"
    REC_SHA="${sha}"
    REC_MILESTONE="${milestone}"
    REC_PATCH="${patch}"
  fi
}
for entry in "${SAME_MILESTONE_PATCHES[@]:-}"; do
  [ -n "${entry}" ] || continue
  IFS='|' read -r branch sha patch <<<"${entry}"
  consider_stable "${branch}" "${sha}" "${CUR_MILESTONE}" "${patch}"
done
for entry in "${NEW_MILESTONE_STABLE[@]:-}"; do
  [ -n "${entry}" ] || continue
  IFS='|' read -r branch sha milestone patch <<<"${entry}"
  consider_stable "${branch}" "${sha}" "${milestone}" "${patch}"
done

UPDATE_AVAILABLE=0
if [ "${DRIFTED}" -eq 1 ] || [ "${BRANCH_MISSING}" -eq 1 ] || [ "${#SAME_MILESTONE_PATCHES[@]}" -gt 0 ] \
  || [ "${#NEW_MILESTONE_STABLE[@]}" -gt 0 ] || [ "${#NEW_MILESTONE_PROVISIONAL[@]}" -gt 0 ]; then
  UPDATE_AVAILABLE=1
fi

# --- rendering ---------------------------------------------------------------

join_list() {
  # Prints "(none)" for an empty array, else its elements' first field, comma-separated.
  # Callers pass "${ARR[@]:-}" so an empty ARR still arrives as one empty-string argument
  # under `set -u` (bash 3.2 treats a truly empty "${ARR[@]}" as unbound); skip it here.
  local out="" first=1 entry branch
  for entry in "$@"; do
    [ -n "${entry}" ] || continue
    branch="${entry%%|*}"
    if [ "${first}" -eq 0 ]; then
      out+=", "
    fi
    out+="${branch}"
    first=0
  done
  if [ "${first}" -eq 1 ]; then
    printf '(none)'
  else
    printf '%s' "${out}"
  fi
}

render_text() {
  echo "Current pin:   ${MONO_SKIA_BRANCH} @ ${MONO_SKIA_COMMIT} (milestone ${CUR_MILESTONE})"
  if [ "${BRANCH_MISSING}" -eq 1 ]; then
    echo "Ref drift:     UNKNOWN - ${MONO_SKIA_BRANCH} no longer exists upstream"
  elif [ "${DRIFTED}" -eq 1 ]; then
    echo "Ref drift:     yes - ${MONO_SKIA_BRANCH} now points at ${CURRENT_TIP}"
  else
    echo "Ref drift:     none"
  fi
  echo "Same-milestone patches newer than ${MONO_SKIA_BRANCH}: $(join_list "${SAME_MILESTONE_PATCHES[@]:-}")"
  echo "Newer milestones, stable:        $(join_list "${NEW_MILESTONE_STABLE[@]:-}")"
  echo "Newer milestones, provisional:   $(join_list "${NEW_MILESTONE_PROVISIONAL[@]:-}")"
  echo "skia-sync branches ahead (ref only): $(join_list "${SYNC_NEWER[@]:-}")"
  if [ -n "${REC_BRANCH}" ]; then
    echo "Recommendation: bump to ${REC_BRANCH} (${REC_SHA})"
  elif [ "${#NEW_MILESTONE_PROVISIONAL[@]}" -gt 0 ] || [ "${#SYNC_NEWER[@]}" -gt 0 ]; then
    echo "Recommendation: none - only provisional/sync branches are ahead, no stable release yet"
  else
    echo "Recommendation: none - already on the newest stable branch"
  fi
}

json_array() {
  # Renders SAME_MILESTONE_PATCHES/NEW_MILESTONE_STABLE-shaped entries ("branch|sha|...")
  # as a JSON array of {"branch":...,"commit":...}. Extra fields are ignored here; callers
  # that need them (milestone, kind) build their own array below instead.
  local first=1 entry branch sha
  printf '['
  for entry in "$@"; do
    [ -n "${entry}" ] || continue
    IFS='|' read -r branch sha _ <<<"${entry}"
    [ "${first}" -eq 1 ] || printf ','
    printf '{"branch":"%s","commit":"%s"}' "${branch}" "${sha}"
    first=0
  done
  printf ']'
}

render_json() {
  printf '{'
  printf '"current":{"branch":"%s","commit":"%s","milestone":%s},' "${MONO_SKIA_BRANCH}" "${MONO_SKIA_COMMIT}" "${CUR_MILESTONE}"
  if [ "${BRANCH_MISSING}" -eq 1 ]; then
    printf '"ref_drift":{"status":"unknown","remote_tip":null},'
  elif [ "${DRIFTED}" -eq 1 ]; then
    printf '"ref_drift":{"status":"drifted","remote_tip":"%s"},' "${CURRENT_TIP}"
  else
    printf '"ref_drift":{"status":"none","remote_tip":"%s"},' "${CURRENT_TIP}"
  fi
  printf '"same_milestone_newer_patches":%s,' "$(json_array "${SAME_MILESTONE_PATCHES[@]:-}")"
  printf '"new_milestones":{"stable":%s,"provisional":%s},' \
    "$(json_array "${NEW_MILESTONE_STABLE[@]:-}")" "$(json_array "${NEW_MILESTONE_PROVISIONAL[@]:-}")"
  printf '"skia_sync_ahead":%s,' "$(json_array "${SYNC_NEWER[@]:-}")"
  if [ -n "${REC_BRANCH}" ]; then
    printf '"recommendation":{"branch":"%s","commit":"%s"},' "${REC_BRANCH}" "${REC_SHA}"
  else
    printf '"recommendation":null,'
  fi
  printf '"update_available":%s' "$([ "${UPDATE_AVAILABLE}" -eq 1 ] && echo true || echo false)"
  printf '}\n'
}

render_markdown() {
  echo "## Skia upstream check"
  echo
  echo "- **Current pin:** \`${MONO_SKIA_BRANCH}\` @ \`${MONO_SKIA_COMMIT}\` (milestone ${CUR_MILESTONE})"
  if [ "${BRANCH_MISSING}" -eq 1 ]; then
    echo "- **Ref drift:** unknown - \`${MONO_SKIA_BRANCH}\` no longer exists upstream"
  elif [ "${DRIFTED}" -eq 1 ]; then
    echo "- **Ref drift:** \`${MONO_SKIA_BRANCH}\` now points at \`${CURRENT_TIP}\`"
  else
    echo "- **Ref drift:** none"
  fi
  echo "- **Same-milestone patches newer than ${MONO_SKIA_BRANCH}:** $(join_list "${SAME_MILESTONE_PATCHES[@]:-}")"
  echo "- **New milestones, stable:** $(join_list "${NEW_MILESTONE_STABLE[@]:-}")"
  echo "- **New milestones, provisional:** $(join_list "${NEW_MILESTONE_PROVISIONAL[@]:-}")"
  echo "- **skia-sync branches ahead (reference only):** $(join_list "${SYNC_NEWER[@]:-}")"
  if [ -n "${REC_BRANCH}" ]; then
    echo "- **Recommendation:** bump to \`${REC_BRANCH}\` (\`${REC_SHA}\`)"
  elif [ "${#NEW_MILESTONE_PROVISIONAL[@]}" -gt 0 ] || [ "${#SYNC_NEWER[@]}" -gt 0 ]; then
    echo "- **Recommendation:** none yet - only provisional/sync branches are ahead"
  else
    echo "- **Recommendation:** none - already on the newest stable branch"
  fi
}

case "${FORMAT}" in
  text) render_text ;;
  json) render_json ;;
  markdown) render_markdown ;;
esac

if [ "${UPDATE_AVAILABLE}" -eq 1 ]; then
  exit 10
fi
exit 0
