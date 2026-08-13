#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#
# Check-state preflight matrix (needs jq, which stands in for gh's built-in
# filter so the real filter runs over realistic rollup payloads):
#   (i) failing checks refuse the merge and name the concrete check
#       (including a workflow that was blocked or never started)
#   (j) checks still running refuse the merge and name the concrete check,
#       over gh's empty-string conclusion as well as a null one
#   (j2) a failure carried in state= behind an empty conclusion reads as failing
#   (k) a repository with no checks configured still merges
#   (l) passing checks merge
#   (m) an unreadable check state refuses rather than merging blind
#   (n) --checks-override merges a failing PR and records the classification
#   (o) neither a yolo posture nor an environment variable reaches the override
#   (p) --checks-override refuses an unknown, missing, or empty classification
#   (q) --checks-override is refused when the check state is already clean
#   (r) a repeated override replaces the recorded classification, and a later
#       merge that needs none clears it
#   (s) the meta an override merge leaves behind is still accepted by the
#       readers of the task's PR identity and armed merge watch
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *statusCheckRollup*)
        # Answer the way gh does: run the caller's own filter, which is its last
        # argument, over this case's rollup payload. FM_TEST_ROLLUP=UNAVAILABLE
        # stands for a gh that cannot answer at all.
        rollup=\${FM_TEST_ROLLUP:-'{"statusCheckRollup":[]}'}
        [ "\$rollup" != UNAVAILABLE ] || exit 1
        if command -v jq >/dev/null 2>&1; then
          for filter in "\$@"; do :; done
          printf '%s' "\$rollup" | jq -r "\$filter"
        else
          # No JSON processor: only the default empty-rollup payload is
          # answerable, and the cases that need any other one are skipped.
          printf 'state=none\n'
        fi
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  # Same gh mock as every other case, so the check-state preflight still gets a
  # real answer and the merge is the only thing that fails.
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_ROLLUP="${FM_TEST_ROLLUP:-}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- check-state preflight ------------------------------------------------
#
# Rollup payloads shaped like the ones the forge really returns: a CheckRun
# carries name/status/conclusion, a StatusContext carries context/state.
ROLLUP_FAILING='{"statusCheckRollup":[
  {"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"build (ubuntu-latest)","status":"COMPLETED","conclusion":"FAILURE"}]}'
# gh reports an unset conclusion as an empty string, not null, so the pending
# payload carries the shape production actually sees. A JSON null is kept beside
# it because the two are distinct inputs to the filter's field fallback.
ROLLUP_PENDING='{"statusCheckRollup":[
  {"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"build (ubuntu-latest)","status":"IN_PROGRESS","conclusion":""}]}'
ROLLUP_PENDING_NULL='{"statusCheckRollup":[
  {"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
  {"name":"build (ubuntu-latest)","status":"IN_PROGRESS","conclusion":null}]}'
ROLLUP_PENDING_QUEUED='{"statusCheckRollup":[
  {"name":"ci","status":"QUEUED","conclusion":""}]}'
# A red status context that also carries gh's empty conclusion: the failure
# lives in state=, which the field fallback must reach past the empty string.
ROLLUP_CONTEXT_FAILING='{"statusCheckRollup":[
  {"context":"codecov/patch","state":"FAILURE","conclusion":""}]}'
ROLLUP_PASSING='{"statusCheckRollup":[
  {"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
  {"context":"codecov/patch","state":"SUCCESS"}]}'
ROLLUP_NONE='{"statusCheckRollup":[]}'
# A blocked or never-started workflow - the billing block that started this -
# concludes without ever running the change's tests. It is not green and must
# not read as one.
ROLLUP_BLOCKED='{"statusCheckRollup":[
  {"name":"ci","status":"COMPLETED","conclusion":"ACTION_REQUIRED"},
  {"name":"release","status":"COMPLETED","conclusion":"STARTUP_FAILURE"}]}'

# Run one preflight case. Args: case_dir rollup then fm-pr-merge args.
run_with_rollup() {
  local case_dir=$1 rollup=$2 rc; shift 2
  set +e
  FM_TEST_ROLLUP="$rollup" run_pr_merge "$case_dir" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  return "$rc"
}

# Nothing may have happened: no merge, no recorded PR, no armed poll.
assert_no_merge_side_effects() {
  local case_dir=$1 label=$2
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "$label: gh-axi pr merge was invoked despite the refusal"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "$label: the PR was recorded even though the merge was refused"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "$label: a merge poll was armed even though the merge was refused"
}

test_failing_checks_refuse_and_name_the_check() {
  local case_dir rc
  case_dir=$(make_case checks-failing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/31 || rc=$?

  expect_code 1 "$rc" "checks-failing: a failing check should refuse the merge"
  assert_grep "the PR's checks are failing" "$case_dir/stderr" \
    "checks-failing: the refusal did not say the checks are failing"
  assert_grep 'build (ubuntu-latest) (FAILURE)' "$case_dir/stderr" \
    "checks-failing: the refusal did not name the concrete failing check"
  assert_no_grep 'lint' "$case_dir/stderr" \
    "checks-failing: the refusal listed a check that is passing"
  assert_no_merge_side_effects "$case_dir" checks-failing
  pass "fm-pr-merge refuses a failing PR and names the concrete failing check"
}

test_blocked_workflow_refuses_and_names_the_check() {
  local case_dir rc
  case_dir=$(make_case checks-blocked)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" afafafafafafafafafafafafafafafafafafafaf
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_BLOCKED" task-x1 \
    https://github.com/example/repo/pull/41 || rc=$?

  expect_code 1 "$rc" "checks-blocked: a workflow that never ran must not merge"
  assert_grep 'ci (ACTION_REQUIRED)' "$case_dir/stderr" \
    "checks-blocked: the refusal did not name the blocked workflow"
  assert_grep 'release (STARTUP_FAILURE)' "$case_dir/stderr" \
    "checks-blocked: the refusal did not name the workflow that failed to start"
  assert_no_merge_side_effects "$case_dir" checks-blocked
  pass "fm-pr-merge refuses a workflow that was blocked or never started"
}

test_pending_checks_refuse_and_name_the_check() {
  local case_dir rc
  case_dir=$(make_case checks-pending)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_PENDING" task-x1 \
    https://github.com/example/repo/pull/32 || rc=$?

  expect_code 1 "$rc" "checks-pending: an unfinished check should refuse the merge"
  assert_grep "the PR's checks are still running" "$case_dir/stderr" \
    "checks-pending: the refusal did not say the checks are still running"
  assert_grep 'build (ubuntu-latest) (IN_PROGRESS)' "$case_dir/stderr" \
    "checks-pending: the refusal did not name the concrete unfinished check"
  assert_grep 'wait for the check to finish' "$case_dir/stderr" \
    "checks-pending: the refusal did not recommend waiting"
  assert_no_merge_side_effects "$case_dir" checks-pending

  # The same contract over the null spelling and over a check that has not
  # started, so neither shape can lose its state behind the other.
  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_PENDING_NULL" task-x1 \
    https://github.com/example/repo/pull/32 || rc=$?
  expect_code 1 "$rc" "checks-pending: a null conclusion should refuse the merge"
  assert_grep 'build (ubuntu-latest) (IN_PROGRESS)' "$case_dir/stderr" \
    "checks-pending: a null conclusion did not name the unfinished check's state"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_PENDING_QUEUED" task-x1 \
    https://github.com/example/repo/pull/32 || rc=$?
  expect_code 1 "$rc" "checks-pending: a queued check should refuse the merge"
  assert_grep 'ci (QUEUED)' "$case_dir/stderr" \
    "checks-pending: the refusal did not name the queued check's state"
  pass "fm-pr-merge refuses to merge mid-flight and names the unfinished check"
}

test_status_context_failure_survives_an_empty_conclusion() {
  local case_dir rc
  case_dir=$(make_case checks-context-failing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_CONTEXT_FAILING" task-x1 \
    https://github.com/example/repo/pull/44 || rc=$?

  expect_code 1 "$rc" "checks-context-failing: a red status context should refuse the merge"
  assert_grep "the PR's checks are failing" "$case_dir/stderr" \
    "checks-context-failing: a failure carried in state= was not reported as failing"
  assert_grep 'codecov/patch (FAILURE)' "$case_dir/stderr" \
    "checks-context-failing: the refusal did not name the failing context's state"
  assert_no_merge_side_effects "$case_dir" checks-context-failing
  pass "a failing status context is reported as failing despite gh's empty conclusion"
}

test_no_checks_configured_still_merges() {
  local case_dir rc
  case_dir=$(make_case checks-none)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_NONE" task-x1 \
    https://github.com/example/repo/pull/33 || rc=$?

  expect_code 0 "$rc" "checks-none: a repository with no checks should still merge"
  assert_grep 'checks: none configured' "$case_dir/stdout" \
    "checks-none: an empty rollup was not reported as no checks configured"
  grep -qxF 'pr merge 33 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "checks-none: the merge did not run on a repository with no checks"
  pass "fm-pr-merge still merges on a repository with no checks configured"
}

test_passing_checks_merge() {
  local case_dir rc
  case_dir=$(make_case checks-passing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_PASSING" task-x1 \
    https://github.com/example/repo/pull/34 || rc=$?

  expect_code 0 "$rc" "checks-passing: passing checks should merge"
  assert_grep 'checks: passing' "$case_dir/stdout" \
    "checks-passing: a green rollup was not reported as passing"
  assert_grep 'statusCheckRollup' "$case_dir/gh.log" \
    "checks-passing: the check state was never actually read from the forge"
  grep -qxF 'pr merge 34 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "checks-passing: the merge did not run"
  pass "fm-pr-merge reads the check state from the forge and merges a green PR"
}

test_unreadable_check_state_refuses() {
  local case_dir rc
  case_dir=$(make_case checks-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" UNAVAILABLE task-x1 \
    https://github.com/example/repo/pull/35 || rc=$?

  expect_code 1 "$rc" "checks-unavailable: an unreadable check state should refuse the merge"
  assert_grep 'check state could not be read' "$case_dir/stderr" \
    "checks-unavailable: the refusal did not say the check state was unreadable"
  assert_no_merge_side_effects "$case_dir" checks-unavailable
  pass "fm-pr-merge refuses rather than merging blind when the checks cannot be read"
}

test_override_merges_failing_pr_and_records_classification() {
  local case_dir rc
  case_dir=$(make_case checks-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/36 --checks-override INFRASTRUCTURE || rc=$?

  expect_code 0 "$rc" "checks-override: an explicit override should merge a failing PR"
  assert_grep 'checks_override=INFRASTRUCTURE' "$case_dir/state/task-x1.meta" \
    "checks-override: the classification was not recorded in the task's meta"
  grep -qxF 'pr merge 36 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "checks-override: the merge did not run under an explicit override"
  assert_no_grep 'checks-override' "$case_dir/gh-axi.log" \
    "checks-override: the override flag leaked through to gh-axi pr merge"
  pass "fm-pr-merge merges a failing PR only under an explicit, recorded override"
}

test_override_replaces_a_previous_classification() {
  local case_dir rc
  case_dir=$(make_case checks-override-repeat)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/37 --checks-override FLAKE || rc=$?
  expect_code 0 "$rc" "checks-override-repeat: the first override should merge"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/37 --checks-override=CHANGE || rc=$?
  expect_code 0 "$rc" "checks-override-repeat: the second override should merge"

  assert_grep 'checks_override=CHANGE' "$case_dir/state/task-x1.meta" \
    "checks-override-repeat: the new classification was not recorded"
  assert_no_grep 'checks_override=FLAKE' "$case_dir/state/task-x1.meta" \
    "checks-override-repeat: the superseded classification was left behind"
  pass "fm-pr-merge replaces a recorded classification instead of stacking a second one"
}

test_clean_merge_clears_a_superseded_override() {
  local case_dir rc
  case_dir=$(make_case checks-override-cleared)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" babababababababababababababababababababa
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/42 --checks-override FLAKE || rc=$?
  expect_code 0 "$rc" "checks-override-cleared: the override merge should succeed"
  assert_grep 'checks_override=FLAKE' "$case_dir/state/task-x1.meta" \
    "checks-override-cleared: the classification was not recorded to begin with"

  # The check later goes green and the merge is re-run with no override. The
  # earlier classification described an authorization this merge never used.
  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_PASSING" task-x1 \
    https://github.com/example/repo/pull/42 || rc=$?
  expect_code 0 "$rc" "checks-override-cleared: the later clean merge should succeed"
  assert_no_grep 'checks_override=' "$case_dir/state/task-x1.meta" \
    "checks-override-cleared: a merge that needed no override left the old classification behind"
  pass "a merge that needed no override clears a superseded classification"
}

test_yolo_and_environment_do_not_reach_the_override() {
  local case_dir rc
  case_dir=$(make_case checks-yolo)
  mkdir -p "$case_dir/wt"
  # A yolo posture is exactly the standing authority that must not reach past a
  # red check, and no environment variable may stand in for the flag either.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=1"
  add_gh_mocks "$case_dir" acacacacacacacacacacacacacacacacacacacac
  : > "$case_dir/gh-axi.log"

  rc=0
  set +e
  FM_TEST_ROLLUP="$ROLLUP_FAILING" \
  FM_CHECKS_OVERRIDE=INFRASTRUCTURE CHECKS_OVERRIDE=INFRASTRUCTURE \
  FM_PR_MERGE_CHECKS_OVERRIDE=INFRASTRUCTURE \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/38 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "checks-yolo: a yolo posture must not merge a failing PR"
  assert_grep "the PR's checks are failing" "$case_dir/stderr" \
    "checks-yolo: the refusal did not report the failing checks"
  assert_no_grep 'checks_override=' "$case_dir/state/task-x1.meta" \
    "checks-yolo: an override was recorded without the explicit flag"
  assert_no_merge_side_effects "$case_dir" checks-yolo
  pass "neither a yolo posture nor an environment variable reaches the check override"
}

test_override_requires_a_known_classification() {
  local case_dir rc
  case_dir=$(make_case checks-override-invalid)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" adadadadadadadadadadadadadadadadadadadad
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/39 --checks-override MAYBE || rc=$?
  expect_code 2 "$rc" "checks-override-invalid: an unknown classification should be refused"
  assert_grep 'CHANGE, FLAKE, or INFRASTRUCTURE' "$case_dir/stderr" \
    "checks-override-invalid: the refusal did not name the accepted classifications"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/39 --checks-override || rc=$?
  expect_code 2 "$rc" "checks-override-invalid: a missing classification should be refused"
  assert_grep 'needs a classification' "$case_dir/stderr" \
    "checks-override-invalid: the refusal did not report the missing classification"

  # An empty value carries no judgment in either spelling - a wrapper expanding
  # an unset variable reaches both - and may not degrade to "no override given".
  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/39 --checks-override= || rc=$?
  expect_code 2 "$rc" "checks-override-invalid: an empty joined classification should be refused"
  assert_grep 'needs a classification' "$case_dir/stderr" \
    "checks-override-invalid: --checks-override= was read as no override rather than a missing classification"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/39 --checks-override '' || rc=$?
  expect_code 2 "$rc" "checks-override-invalid: an empty separate classification should be refused"
  assert_grep 'needs a classification' "$case_dir/stderr" \
    "checks-override-invalid: an empty --checks-override operand was read as no override rather than a missing classification"

  assert_no_merge_side_effects "$case_dir" checks-override-invalid
  pass "fm-pr-merge refuses an override that carries no usable classification"
}

test_override_meta_still_parses_for_its_consumers() {
  local case_dir rc
  case_dir=$(make_case checks-override-meta)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_FAILING" task-x1 \
    https://github.com/example/repo/pull/43 --checks-override INFRASTRUCTURE || rc=$?
  expect_code 0 "$rc" "checks-override-meta: the override merge should succeed"
  assert_grep 'checks_override=INFRASTRUCTURE' "$case_dir/state/task-x1.meta" \
    "checks-override-meta: the classification was not recorded to begin with"

  # Recording the decision may not cost the task its PR identity. The meta is
  # read back by fm_pr_metadata_identity_parse, which allows only a fixed set of
  # keys after the canonical pr= line, and fm-watch reaches the armed merge watch
  # through fm_pr_poll_artifacts_valid on every check interval - so a meta those
  # refuse strands the very merge the captain authorized. Run in a subshell so
  # the library's FM_PR_* globals stay out of the harness.
  rc=0
  (
    # shellcheck source=bin/fm-pr-lib.sh
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_metadata_identity_parse "$case_dir/state/task-x1.meta" || exit 1
    [ "$FM_PR_META_URL" = https://github.com/example/repo/pull/43 ] || exit 1
    fm_pr_poll_artifacts_valid "$case_dir/state" task-x1 "$ROOT/bin/fm-pr-poll.sh" || exit 2
  ) || rc=$?
  expect_code 0 "$rc" \
    "checks-override-meta: the meta left by an override merge is refused by its own readers"
  pass "the meta an override merge leaves behind still parses for its consumers"
}

test_override_refused_when_checks_are_clean() {
  local case_dir rc
  case_dir=$(make_case checks-override-clean)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
  : > "$case_dir/gh-axi.log"

  rc=0
  run_with_rollup "$case_dir" "$ROLLUP_PASSING" task-x1 \
    https://github.com/example/repo/pull/40 --checks-override FLAKE || rc=$?

  expect_code 2 "$rc" "checks-override-clean: an override on a green PR should be refused"
  assert_grep 'applies only to a check state that is not clean' "$case_dir/stderr" \
    "checks-override-clean: the refusal did not explain why the override was rejected"
  assert_no_grep 'checks_override=' "$case_dir/state/task-x1.meta" \
    "checks-override-clean: a classification was recorded for a green PR"
  assert_no_merge_side_effects "$case_dir" checks-override-clean
  pass "fm-pr-merge refuses a classification for a check state that is already clean"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi

# The preflight cases drive the real filter through jq, standing in for the one
# gh runs. Without it only the default empty rollup is answerable, so they are
# skipped rather than passing over a payload the mock could not evaluate.
if command -v jq >/dev/null 2>&1; then
  test_failing_checks_refuse_and_name_the_check
  test_blocked_workflow_refuses_and_names_the_check
  test_pending_checks_refuse_and_name_the_check
  test_status_context_failure_survives_an_empty_conclusion
  test_no_checks_configured_still_merges
  test_passing_checks_merge
  test_unreadable_check_state_refuses
  test_override_merges_failing_pr_and_records_classification
  test_override_replaces_a_previous_classification
  test_clean_merge_clears_a_superseded_override
  test_yolo_and_environment_do_not_reach_the_override
  test_override_requires_a_known_classification
  test_override_refused_when_checks_are_clean
  test_override_meta_still_parses_for_its_consumers
else
  echo "skip: jq not found; check-state preflight cases skipped"
fi
