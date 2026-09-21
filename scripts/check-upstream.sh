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

if [ -z "${MONO_SKIA_BRANCH:-}" ]; then
  echo "ERROR: MONO_SKIA_BRANCH is not set in skia.lock" >&2
  exit 1
fi
# SKIA_MILESTONE, not the branch name, is the milestone of record: scripts/bump-lock.sh also
# accepts maintenance (release/X.Y.x) and skia-sync branches, and deriving the milestone from
# the name would make this check fail outright on a pin those produce.
if [[ ! "${SKIA_MILESTONE:-}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SKIA_MILESTONE ('${SKIA_MILESTONE:-}') is not a number" >&2
  exit 1
fi
CUR_MILESTONE="${SKIA_MILESTONE}"

# The major and patch come from the branch name when it has them, and are only used to decide
# which patch releases on this milestone count as newer. A branch that carries neither (a
# floating .x line, a skia-sync ref) leaves the baseline unknown, which the report says outright
# rather than guessing at.
CUR_MAJOR=""
CUR_PATCH=""
if [[ "${MONO_SKIA_BRANCH}" =~ ^release/([0-9]+)\.[0-9]+\.([0-9]+)$ ]]; then
  CUR_MAJOR="${BASH_REMATCH[1]}"
  CUR_PATCH="${BASH_REMATCH[2]}"
elif [[ "${MONO_SKIA_BRANCH}" =~ ^release/([0-9]+)\.[0-9]+\.x$ ]]; then
  # A .x branch floats at the head of its line, so every numbered patch on it is fair game.
  CUR_MAJOR="${BASH_REMATCH[1]}"
  CUR_PATCH="-1"
fi

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
if [ -n "${CUR_MAJOR}" ]; then
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    SHA="$(awk '{print $1}' <<<"${line}")"
    BRANCH="$(awk '{print $2}' <<<"${line}" | sed 's#^refs/heads/##')"
    PATCH="${BRANCH##*.}"
    if [ "${PATCH}" -gt "${CUR_PATCH}" ] 2>/dev/null; then
      SAME_MILESTONE_PATCHES+=("${BRANCH}|${SHA}|${PATCH}")
    fi
  done < <(printf '%s\n' "${REMOTE_HEADS}" | grep -E "	refs/heads/release/${CUR_MAJOR}\.${CUR_MILESTONE}\.[0-9]+\$" || true)
fi

# --- newer milestones: stable vs. provisional -------------------------------
NEW_MILESTONE_STABLE=()
NEW_MILESTONE_PROVISIONAL=()
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  SHA="$(awk '{print $1}' <<<"${line}")"
  BRANCH="$(awk '{print $2}' <<<"${line}" | sed 's#^refs/heads/##')"
  # Every major line is scanned, not just the pinned one: mono/skia has moved 1.x -> 2.x ->
  # 3.x -> 4.x, and filtering on the current major would make the next such jump invisible and
  # report "up to date" forever.
  if [[ "${BRANCH}" =~ ^release/([0-9]+)\.([0-9]+)\.(x|[0-9]+)(-preview\.[0-9]+|-rc\.[0-9]+)?$ ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MILESTONE="${BASH_REMATCH[2]}"
    PATCH="${BASH_REMATCH[3]}"
    SUFFIX="${BASH_REMATCH[4]}"
    if [ "${MILESTONE}" -gt "${CUR_MILESTONE}" ] 2>/dev/null; then
      if [ -z "${SUFFIX}" ] && [ "${PATCH}" != "x" ]; then
        NEW_MILESTONE_STABLE+=("${BRANCH}|${SHA}|${MILESTONE}|${MAJOR}|${PATCH}")
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
done < <(printf '%s\n' "${REMOTE_HEADS}" | grep -E "	refs/heads/release/" || true)

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
REC_MILESTONE=-1
REC_MAJOR=-1
REC_PATCH=-1
# Ranked on milestone first, then major, then patch: the milestone is the Skia version these
# binaries actually track, and a higher major of the same milestone is the same Skia with a
# newer SkiaSharp wrapper.
consider_stable() {
  local branch="$1" sha="$2" milestone="$3" major="$4" patch="$5"
  local better=0
  if [ "${milestone}" -gt "${REC_MILESTONE}" ]; then
    better=1
  elif [ "${milestone}" -eq "${REC_MILESTONE}" ]; then
    if [ "${major}" -gt "${REC_MAJOR}" ]; then
      better=1
    elif [ "${major}" -eq "${REC_MAJOR}" ] && [ "${patch}" -gt "${REC_PATCH}" ]; then
      better=1
    fi
  fi
  if [ "${better}" -eq 1 ]; then
    REC_BRANCH="${branch}"
    REC_SHA="${sha}"
    REC_MILESTONE="${milestone}"
    REC_MAJOR="${major}"
    REC_PATCH="${patch}"
  fi
}
for entry in "${SAME_MILESTONE_PATCHES[@]:-}"; do
  [ -n "${entry}" ] || continue
  IFS='|' read -r branch sha patch <<<"${entry}"
  consider_stable "${branch}" "${sha}" "${CUR_MILESTONE}" "${CUR_MAJOR}" "${patch}"
done
for entry in "${NEW_MILESTONE_STABLE[@]:-}"; do
  [ -n "${entry}" ] || continue
  IFS='|' read -r branch sha milestone major patch <<<"${entry}"
  consider_stable "${branch}" "${sha}" "${milestone}" "${major}" "${patch}"
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

# Drift is an update in its own right, so it becomes the recommendation when no newer branch
# outranks it; otherwise the report would tell the reader to do nothing right after telling them
# the pinned ref has moved.
recommendation_line() {
  if [ -n "${REC_BRANCH}" ]; then
    printf 'bump to %s (%s)' "${REC_BRANCH}" "${REC_SHA}"
  elif [ "${BRANCH_MISSING}" -eq 1 ]; then
    printf 'none - %s no longer exists upstream; pick a new branch by hand' "${MONO_SKIA_BRANCH}"
  elif [ "${DRIFTED}" -eq 1 ]; then
    printf 're-pin %s to its current tip (%s)' "${MONO_SKIA_BRANCH}" "${CURRENT_TIP}"
  elif [ "${#NEW_MILESTONE_PROVISIONAL[@]}" -gt 0 ] || [ "${#SYNC_NEWER[@]}" -gt 0 ]; then
    printf 'none - only provisional/sync branches are ahead, no stable release yet'
  else
    printf 'none - already on the newest stable branch'
  fi
}

# The baseline for "newer patch on this milestone" only exists when the pinned branch names one.
same_milestone_label() {
  if [ -n "${CUR_MAJOR}" ]; then
    printf 'Same-milestone patches newer than %s' "${MONO_SKIA_BRANCH}"
  else
    printf 'Same-milestone patches (baseline unknown: %s names no patch)' "${MONO_SKIA_BRANCH}"
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
  echo "$(same_milestone_label): $(join_list "${SAME_MILESTONE_PATCHES[@]:-}")"
  echo "Newer milestones, stable:        $(join_list "${NEW_MILESTONE_STABLE[@]:-}")"
  echo "Newer milestones, provisional:   $(join_list "${NEW_MILESTONE_PROVISIONAL[@]:-}")"
  echo "skia-sync branches ahead (ref only): $(join_list "${SYNC_NEWER[@]:-}")"
  echo "Recommendation: $(recommendation_line)"
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
  echo "- **$(same_milestone_label):** $(join_list "${SAME_MILESTONE_PATCHES[@]:-}")"
  echo "- **New milestones, stable:** $(join_list "${NEW_MILESTONE_STABLE[@]:-}")"
  echo "- **New milestones, provisional:** $(join_list "${NEW_MILESTONE_PROVISIONAL[@]:-}")"
  echo "- **skia-sync branches ahead (reference only):** $(join_list "${SYNC_NEWER[@]:-}")"
  echo "- **Recommendation:** $(recommendation_line)"
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
