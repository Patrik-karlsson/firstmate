#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# The PR's check state is read from the forge before merging, so "never merge a
# red PR" rests on the forge's own answer rather than on having looked at the
# PR by eye. Four states are distinguished because collapsing them breaks real
# repositories: failing and pending both refuse, an unreadable answer refuses,
# and a PR with no checks configured at all merges normally. That last case is
# not red - a repository with CI disabled has an empty rollup, and a preflight
# that refused it would block every merge there.
#
# --checks-override is the one way past a non-clean state and exists for the
# case AGENTS.md section 7 contemplates: a current captain instruction naming
# this concrete merge. It is a flag with no environment or configuration
# equivalent, so no standing posture such as yolo can reach it, and it is never
# the default. Its argument is the classification of why the check is not
# passing, which is what a non-passing check may never be reported without:
#
#   CHANGE          this change caused the failure
#   FLAKE           a known-unstable check that passes on re-run
#   INFRASTRUCTURE  billing, runner availability, token permission, or network
#
# The chosen classification is recorded as checks_override= in the task's meta,
# so the decision stays inspectable after the merge. A rollup cannot tell a real
# failure from a flake, so this judgment is supplied by the caller rather than
# guessed here.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url>
#          [--checks-override <CHANGE|FLAKE|INFRASTRUCTURE>]
#          [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

CHECKS_OVERRIDE=
CHECKS_OVERRIDE_GIVEN=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --checks-override)
      if [ "$#" -lt 2 ]; then
        echo "error: --checks-override needs a classification" >&2
        exit 2
      fi
      CHECKS_OVERRIDE=$2
      CHECKS_OVERRIDE_GIVEN=1
      shift 2
      ;;
    --checks-override=*)
      CHECKS_OVERRIDE=${1#--checks-override=}
      CHECKS_OVERRIDE_GIVEN=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

# An empty value carries no judgment whichever spelling supplied it, so the
# emptiness check has one owner here rather than one guard per spelling.
if [ -n "$CHECKS_OVERRIDE_GIVEN" ] && [ -z "$CHECKS_OVERRIDE" ]; then
  echo "error: --checks-override needs a classification" >&2
  exit 2
fi

case "$CHECKS_OVERRIDE" in
  ''|CHANGE|FLAKE|INFRASTRUCTURE) ;;
  *)
    echo "error: --checks-override must classify the failure as CHANGE, FLAKE, or INFRASTRUCTURE" >&2
    exit 2
    ;;
esac

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# The check state comes from gh rather than gh-axi for the same reason
# bin/fm-pr-check.sh reads headRefOid that way: gh exposes statusCheckRollup as
# a selectable field with a built-in filter, so the answer arrives as fixed
# tokens instead of prose a release could reword. The filter always emits a
# state= line, which is what keeps an unreadable answer from being mistaken for
# a repository that simply has no checks - empty output can only mean failure.
# shellcheck disable=SC2016 # $s/$checks/$state are jq variables, not shell ones.
CHECKS_FILTER='
def verdict: (.conclusion // .state // "") as $s
  | if ($s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT" or $s == "CANCELLED"
        or $s == "ACTION_REQUIRED" or $s == "STARTUP_FAILURE") then "failing"
    elif ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS") then "pending"
    else "passing" end;
if (.statusCheckRollup | type) != "array" then "state=unreadable" else
[ .statusCheckRollup[]
  | { name: (.name // .context // "unnamed"),
      detail: (.conclusion // .state // .status // "unknown"),
      verdict: verdict } ] as $checks
| (if ($checks | length) == 0 then "none"
   elif any($checks[]; .verdict == "failing") then "failing"
   elif any($checks[]; .verdict == "pending") then "pending"
   else "passing" end) as $state
| ( [ "state=" + $state ]
    + [ $checks[] | select(.verdict != "passing")
        | "check=" + .verdict + " " + .name + " (" + .detail + ")" ] )[]
end
'

# Sets CHECKS_STATE to failing, pending, passing, none, or unavailable, and
# CHECKS_DETAIL to the concrete non-passing checks. Every path that cannot
# produce a trustworthy answer leaves the state unavailable.
read_checks_state() {
  local out first
  CHECKS_STATE=unavailable
  CHECKS_DETAIL=
  command -v gh >/dev/null 2>&1 || return 0
  if ! out=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
    --json statusCheckRollup -q "$CHECKS_FILTER" 2>/dev/null); then
    return 0
  fi
  first=${out%%$'\n'*}
  case "$first" in
    state=failing|state=pending|state=passing|state=none) ;;
    *) return 0 ;;
  esac
  CHECKS_STATE=${first#state=}
  CHECKS_DETAIL=$(printf '%s\n' "$out" | sed -n 's/^check=/  /p')
  return 0
}

read_checks_state
case "$CHECKS_STATE" in
  passing|none)
    if [ -n "$CHECKS_OVERRIDE" ]; then
      echo "error: --checks-override applies only to a check state that is not clean" >&2
      exit 2
    fi
    if [ "$CHECKS_STATE" = none ]; then
      echo "checks: none configured for this repository"
    else
      echo "checks: passing"
    fi
    ;;
  *)
    if [ -z "$CHECKS_OVERRIDE" ]; then
      case "$CHECKS_STATE" in
        failing)
          echo "error: the PR's checks are failing; refusing to merge" >&2
          [ -z "$CHECKS_DETAIL" ] || printf '%s\n' "$CHECKS_DETAIL" >&2
          echo "hint: fix the failing check, or if a current captain instruction names this merge, re-run with --checks-override <CHANGE|FLAKE|INFRASTRUCTURE>" >&2
          ;;
        pending)
          echo "error: the PR's checks are still running; refusing to merge" >&2
          [ -z "$CHECKS_DETAIL" ] || printf '%s\n' "$CHECKS_DETAIL" >&2
          echo "hint: wait for the check to finish and merge again; merging before it finishes needs a current captain instruction naming this merge, via --checks-override <CHANGE|FLAKE|INFRASTRUCTURE>" >&2
          ;;
        *)
          echo "error: the PR's check state could not be read; refusing to merge" >&2
          echo "hint: confirm gh is installed and authenticated for $PR_OWNER/$PR_REPO, then merge again" >&2
          ;;
      esac
      exit 1
    fi
    echo "checks: $CHECKS_STATE, overridden as $CHECKS_OVERRIDE"
    ;;
esac

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Recorded after fm-pr-check.sh, which rewrites the meta wholesale. Any earlier
# line is dropped so a re-run replaces the classification rather than stacking a
# second one behind it, and a later merge that needed no override clears it
# rather than leaving a stale record claiming an authorization this merge never
# used. The common clean merge touches nothing.
if [ -n "$CHECKS_OVERRIDE" ] || grep -q '^checks_override=' "$META"; then
  META_TMP=
  # shellcheck disable=SC2329 # Registered by the traps below.
  merge_meta_cleanup() { [ -z "$META_TMP" ] || rm -f -- "$META_TMP"; }
  trap merge_meta_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  META_TMP=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || exit 1
  chmod 0600 "$META_TMP" || exit 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      checks_override=*) ;;
      pr=*)
        if [ -n "$CHECKS_OVERRIDE" ]; then
          printf 'checks_override=%s\n' "$CHECKS_OVERRIDE" >> "$META_TMP" || exit 1
        fi
        printf '%s\n' "$line" >> "$META_TMP" || exit 1
        ;;
      *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
    esac
  done < "$META"
  fm_pr_metadata_identity_parse "$META_TMP" || {
    echo "error: task metadata is unavailable" >&2
    exit 1
  }
  fm_pr_regular_destination_or_absent "$META" || exit 1
  mv -f -- "$META_TMP" "$META" || exit 1
  META_TMP=
  fm_pr_metadata_identity_parse "$META" || {
    echo "error: task metadata is unavailable" >&2
    exit 1
  }
  if [ -n "$CHECKS_OVERRIDE" ]; then
    grep -qxF "checks_override=$CHECKS_OVERRIDE" "$META" || {
      echo "error: check override recording failed" >&2
      exit 1
    }
  elif grep -q '^checks_override=' "$META"; then
    echo "error: superseded check override could not be cleared" >&2
    exit 1
  fi
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
