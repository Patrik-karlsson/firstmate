#!/usr/bin/env bash
# Behavior tests for the friction capture mechanism.
#
# Friction is the one status verb that declares no state: a worker hit
# resistance and kept going. Two properties carry the whole design, and both are
# easy to break silently, so both are pinned here:
#
#   1. TRANSPARENCY - a friction append must not change what any state reader
#      thinks the task is doing, must not mask a captain-relevant event beneath
#      it, and must not open or close a decision or a work phase.
#   2. HONEST COUNTS - every rendering states surfaced, suppressed, and
#      unclassified, including when all three are zero. A quiet friction section
#      that cannot be told apart from a blind one is the exact failure the
#      counts exist to prevent, so the zero case is tested as hard as the
#      populated one.
#
# Everything is driven through the public interfaces: bin/fm-friction.sh,
# bin/fm-classify-lib.sh's exported functions, bin/fm-bearings-snapshot.sh, and
# a real bin/fm-teardown.sh run. Nothing asserts implementation source text.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

FRICTION="$ROOT/bin/fm-friction.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-friction)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

# A bare firstmate home. Echoes its path.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

# Record a task's project so friction records can carry project attribution.
task_project() {  # <home> <task> <project>
  printf 'project=%s\n' "$3" > "$1/state/$2.meta"
}

# Append status lines to a task's log, exactly as a worker would.
status_append() {  # <home> <task> <line>...
  local home=$1 task=$2; shift 2
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/state/$task.status"
  done
}

fr() {  # <home> <args>...
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_FRICTION_NOW="${FM_TEST_NOW:-2026-08-06T10:00:00Z}" \
    "$FRICTION" "$@"
}

counts() {  # <home> -> "surfaced suppressed unclassified settled"
  fr "$1" list --json | jq -r '.counts | "\(.surfaced) \(.suppressed) \(.unclassified) \(.settled)"'
}

# --- 1. recurrence threshold ------------------------------------------------

test_signature_across_two_tasks_surfaces() {
  local home
  home=$(make_home threshold-two)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a \
    "working: started" \
    "friction: [sig=issue-scope-understated] issue said 4 bad frontmatter blocks, found 21"
  status_append "$home" task-b \
    "friction: [sig=issue-scope-understated] completeness gate rejected 16 of 16 docs"

  fr "$home" list --json | jq -e '
    .records[] | select(.sig == "issue-scope-understated")
    | .surfaced == true and (.tasks | length) == 2 and .count == 2
  ' >/dev/null || fail "a signature in two distinct tasks must surface: $(fr "$home" list --json)"
  [ "$(counts "$home")" = "1 0 0 0" ] \
    || fail "expected exactly one surfaced signature, got: $(counts "$home")"
  pass "a signature hit by two distinct tasks is folded and surfaces"
}

test_single_task_signature_is_recorded_not_surfaced() {
  local home
  home=$(make_home threshold-one)
  task_project "$home" task-a lobbyn
  # The SAME signature three times inside ONE task: one worker looping is not a
  # system problem, so the threshold is on distinct tasks, never on occurrences.
  status_append "$home" task-a \
    "friction: [sig=slow-helper] helper took 40s" \
    "friction: [sig=slow-helper] helper took 41s" \
    "friction: [sig=slow-helper] helper took 39s"

  fr "$home" list --json | jq -e '
    .records[] | select(.sig == "slow-helper")
    | .surfaced == false and .count == 3 and (.tasks | length) == 1
  ' >/dev/null || fail "a single-task signature must be recorded but not surfaced"
  [ "$(counts "$home")" = "0 1 0 0" ] \
    || fail "a single-task signature belongs in suppressed, got: $(counts "$home")"
  assert_contains "$(fr "$home" list)" "surfaced: none" "text rendering must say nothing surfaced"
  pass "a signature seen in one task is recorded and never surfaced"
}

# --- 2. the three mandatory counts ------------------------------------------

test_counts_render_when_everything_is_zero() {
  local home text json
  home=$(make_home counts-zero)
  text=$(fr "$home" list)
  json=$(fr "$home" list --json)

  # An empty home is the case most likely to render a blank section.
  assert_contains "$text" "surfaced=0" "the zero rendering must still state surfaced"
  assert_contains "$text" "suppressed=0" "the zero rendering must still state suppressed"
  assert_contains "$text" "unclassified=0" "the zero rendering must still state unclassified"
  printf '%s' "$json" | jq -e '
    (.counts | has("surfaced") and has("suppressed") and has("unclassified"))
    and .counts.surfaced == 0 and .counts.suppressed == 0 and .counts.unclassified == 0
  ' >/dev/null || fail "all three counts must be present and zero: $json"
  pass "surfaced, suppressed and unclassified render even when all three are zero"
}

test_bearings_always_carries_the_three_counts() {
  local home toon json
  home=$(make_home counts-bearings)
  toon=$(FM_HOME="$home" "$BEARINGS" 2>/dev/null) || fail "bearings failed on an empty home"
  json=$(FM_HOME="$home" "$BEARINGS" --json 2>/dev/null) || fail "bearings --json failed"

  # Flat scalar fields, not a nested object: the TOON encoder renders only
  # scalars and arrays of uniform scalar objects, so a nested counts object
  # would leave the captain reading a quoted JSON blob.
  assert_contains "$toon" "friction_surfaced: 0" "bearings must carry the surfaced count at zero"
  assert_contains "$toon" "friction_suppressed: 0" "bearings must carry the suppressed count at zero"
  assert_contains "$toon" "friction_unclassified: 0" "bearings must carry the unclassified count at zero"
  assert_contains "$toon" "friction: []" "an empty friction list must render as the empty-array form"
  printf '%s' "$json" | jq -e '
    (.friction_surfaced | type) == "number"
    and (.friction_suppressed | type) == "number"
    and (.friction_unclassified | type) == "number"
  ' >/dev/null || fail "bearings friction counts must be scalars: $json"

  # And once populated, the same fields carry real numbers.
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=agents-md-conflict] documented advice contradicts a hook"
  status_append "$home" task-b "friction: [sig=agents-md-conflict] same contradiction in another repo"
  toon=$(FM_HOME="$home" "$BEARINGS" 2>/dev/null)
  assert_contains "$toon" "friction_surfaced: 1" "bearings must report a surfaced signature"
  assert_contains "$toon" "agents-md-conflict" "bearings must name the surfaced signature"
  pass "bearings states all three friction counts in every rendering"
}

# --- 3. unattributable records ----------------------------------------------

test_unattributable_record_surfaces_as_unclassified() {
  local home json
  home=$(make_home unclassified)
  task_project "$home" task-a lobbyn
  status_append "$home" task-a \
    "friction: no signature token at all" \
    "friction: [sig=not a legal slug] spaces are illegal in a signature"

  json=$(fr "$home" list --json)
  printf '%s' "$json" | jq -e '.counts.unclassified == 2' >/dev/null \
    || fail "both unattributable lines must be counted, not dropped: $json"
  # Preserved, not summarised away: the raw line survives so a worker's typo is
  # still readable and fixable.
  printf '%s' "$json" | jq -e '
    .records[] | select(.state == "unclassified")
    | (.observations | map(.text) | join(" ")) | contains("no signature token at all")
  ' >/dev/null || fail "an unattributable line must keep its own text: $json"
  assert_contains "$(fr "$home" list)" "unclassified: 2 event(s)" "text rendering must report unclassified events"
  pass "an unattributable record surfaces as unclassified rather than vanishing"
}

# --- 4. the security carve-out ----------------------------------------------

# Cross the threshold for a guard signature and an ordinary one side by side.
seed_guard_home() {  # <name>
  local home
  home=$(make_home "$1")
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a \
    "friction: [sig=secret-blocker-false-positive] blocker denied an edit to a docs path class" \
    "friction: [sig=issue-scope-understated] issue scope badly understated"
  status_append "$home" task-b \
    "friction: [sig=secret-blocker-false-positive] blocker denied an edit to a fixtures path class" \
    "friction: [sig=issue-scope-understated] scope understated again"
  printf '%s\n' "$home"
}

test_guard_signature_offers_no_removal_option() {
  local home out rc
  home=$(seed_guard_home guard-outcomes)

  out=$(fr "$home" outcomes secret-blocker-false-positive)
  [ "$out" = "keep
narrow" ] || fail "a guard signature must offer exactly keep and narrow, got: $out"
  assert_not_contains "$out" "clear" "a guard signature must not offer clear"
  assert_not_contains "$out" "dismiss" "a guard signature must not offer dismiss"

  # The ordinary signature in the same home keeps its full outcome set, so this
  # is the carve-out rather than a blanket restriction.
  out=$(fr "$home" outcomes issue-scope-understated)
  assert_contains "$out" "clear" "an ordinary signature must still offer clear"

  set +e
  fr "$home" draft secret-blocker-false-positive --outcome clear >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "drafting a clear for a guard signature must be refused"

  set +e
  fr "$home" dismiss secret-blocker-false-positive >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dismissing a guard signature must be refused; silent dismissal is not an outcome"
  pass "a security-guard signature offers only keep or narrow, never removal"
}

test_guard_signature_surfaces_individually_with_its_caveat() {
  local home json draft
  home=$(seed_guard_home guard-individual)
  json=$(fr "$home" list --json)

  # Its own record and its own row, never folded into a pattern list with the
  # ordinary signature beside it.
  printf '%s' "$json" | jq -e '
    ([.records[] | select(.surfaced)] | length) == 2
    and ([.records[] | select(.security == true) | .sig] == ["secret-blocker-false-positive"])
  ' >/dev/null || fail "the guard signature must surface as its own security-marked record: $json"
  assert_contains "$(fr "$home" list)" "[security]" "the rendering must mark the guard signature"

  draft=$(fr "$home" draft secret-blocker-false-positive --outcome keep)
  printf '%s' "$draft" | jq -e '.labels == ["known-friction"] and .close_on_file == true' >/dev/null \
    || fail "a keep draft must carry known-friction and close on filing: $draft"
  printf '%s' "$draft" | jq -re '.body' | grep -qF "Frequency is not evidence a guard is wrong" \
    || fail "a guard draft must carry the frequency caveat"
  printf '%s' "$draft" | jq -re '.body' | grep -qF "Observed false positives: 2" \
    || fail "a guard draft must carry its observed false-positive count"
  pass "a security-guard signature surfaces individually and carries its caveat"
}

# --- 5. triage lifecycle ----------------------------------------------------

test_cancelled_draft_returns_to_surfaced() {
  local home
  home=$(make_home cancel-draft)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=issue-scope-understated] scope understated"
  status_append "$home" task-b "friction: [sig=issue-scope-understated] scope understated again"

  fr "$home" draft issue-scope-understated --outcome clear >/dev/null \
    || fail "drafting a surfaced signature must succeed"
  fr "$home" cancel issue-scope-understated >/dev/null || fail "cancelling a draft must succeed"

  # Rejecting a draft rejects the wording, not the finding. Asserted through a
  # fresh render rather than the stored field alone, because staying in the
  # surfaced COUNT is what actually keeps the finding alive.
  fr "$home" show issue-scope-understated | jq -e '
    .state == "surfaced" and .draft == null and .surfaced == true
  ' >/dev/null || fail "a cancelled draft must return the signature to surfaced"
  [ "$(counts "$home")" = "1 0 0 0" ] \
    || fail "a cancelled signature must re-render as surfaced, got: $(counts "$home")"
  pass "a cancelled draft returns the signature to surfaced, not to dismissed"
}

test_settled_signature_keeps_counting_and_never_resurfaces() {
  local home
  home=$(make_home settled)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=agents-md-conflict] advice contradicts a hook"
  status_append "$home" task-b "friction: [sig=agents-md-conflict] and again here"
  status_append "$home" task-a "friction: [sig=noise-sig] not a real pattern"
  status_append "$home" task-b "friction: [sig=noise-sig] still not a real pattern"

  fr "$home" draft agents-md-conflict --outcome keep >/dev/null
  fr "$home" approve agents-md-conflict --issue https://example.invalid/issues/1 >/dev/null
  fr "$home" dismiss noise-sig >/dev/null

  [ "$(counts "$home")" = "0 0 0 2" ] \
    || fail "both settled signatures must leave the surfaced set, got: $(counts "$home")"

  # A settled signature is not deleted and not frozen: a third task hitting it
  # still raises the count, so friction accepted once and later severe is
  # visible on inspection.
  task_project "$home" task-c firstmate
  status_append "$home" task-c "friction: [sig=agents-md-conflict] a third task hit it"
  fr "$home" show agents-md-conflict | jq -e '
    .state == "kept" and .count == 3 and (.tasks | length) == 3 and .surfaced == false
    and .issue_url == "https://example.invalid/issues/1"
  ' >/dev/null || fail "a kept signature must keep counting without re-surfacing"
  [ "$(counts "$home")" = "0 0 0 2" ] \
    || fail "a kept signature must not re-enter surfaced, got: $(counts "$home")"
  pass "a kept or dismissed signature keeps counting and never re-surfaces"
}

test_ingest_is_idempotent() {
  local home before after
  home=$(make_home idempotent)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=repeat-sig] once" "friction: [sig=repeat-sig] twice"
  status_append "$home" task-b "friction: [sig=repeat-sig] elsewhere"

  before=$(fr "$home" list --json | jq -c '[.records[] | {sig, count, tasks}]')
  fr "$home" ingest; fr "$home" ingest; fr "$home" ingest
  after=$(fr "$home" list --json | jq -c '[.records[] | {sig, count, tasks}]')
  [ "$before" = "$after" ] || fail "repeated ingest must not inflate counts: $before vs $after"
  pass "re-ingesting an unchanged status log leaves every count untouched"
}

# --- 6. friction never changes a task's state -------------------------------

test_friction_is_transparent_to_state_readers() {
  local dir log
  dir=$(mktemp -d "$TMP_ROOT/transparency.XXXXXX")
  log="$dir/task.status"

  # A friction append must not mask the event that says what the task is doing.
  printf 'working: implementing the fold\nfriction: [sig=x] something got in the way\n' > "$log"
  [ "$(last_status_line "$log")" = "working: implementing the fold" ] \
    || fail "friction must not become a task's last state-bearing line"

  # Nor may it hide a finished task from the fleet scan.
  printf 'done: shipped\nfriction: [sig=x] something got in the way\n' > "$log"
  status_is_captain_relevant "$(last_status_line "$log")" \
    || fail "a friction append must not hide a captain-relevant done beneath it"

  # A friction observation is free text and may legitimately mention words the
  # legacy free-text matcher looks for. It must still never be captain-relevant.
  ! status_is_captain_relevant "friction: [sig=x] rebased onto merged #76, checks green" \
    || fail "a friction line must never match the legacy free-text captain tokens"

  # It opens and closes nothing.
  printf 'needs-decision [key=api-shape]: which shape\nfriction: [sig=x] slow helper\n' > "$log"
  assert_contains "$(status_open_decisions "$log")" "api-shape" \
    "a friction append must leave an open decision open"
  printf 'working [key=phase1]: doing the thing\nfriction: [sig=x] slow helper\n' > "$log"
  assert_contains "$(status_open_activities "$log")" "phase1" \
    "a friction append must leave an open work phase open"
  pass "a friction line changes no task state and masks no other event"
}

test_malformed_friction_line_is_still_inert() {
  local dir log
  dir=$(mktemp -d "$TMP_ROOT/malformed.XXXXXX")
  log="$dir/task.status"
  # A worker typo must degrade to an unclassified record, never to a state change.
  printf 'working: still going\nfriction: [sig=BAD SLUG] whatever\n' > "$log"
  [ "$(last_status_line "$log")" = "working: still going" ] \
    || fail "a malformed friction line must still be transparent to state readers"
  assert_contains "$(status_friction_events "$log")" "(unclassified)" \
    "a malformed friction line must be reported as unclassified"
  pass "a malformed friction line is unclassified, never a state change"
}

# --- 7. durability across teardown ------------------------------------------

test_friction_survives_teardown() {
  local case_dir home before after
  case_dir="$TMP_ROOT/teardown-case"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$case_dir/fakebin"
  touch "$home/state/.last-watcher-beat"

  local fb="$case_dir/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cp "$fb/gh-axi" "$fb/gh"
  chmod +x "$fb"/*

  # A landed local-only task: work committed on the branch and merged into the
  # project's own main, which teardown accepts without any remote.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "task work"
  git -C "$case_dir/wt" push -q origin fm/task-x1

  fm_write_meta "$home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  status_append "$home" task-x1 \
    "friction: [sig=issue-scope-understated] issue said 4 bad blocks, found 21" \
    "done: ready in branch"

  before=$(fr "$home" list --json | jq -c '[.records[] | {sig, count}]')
  assert_contains "$before" "issue-scope-understated" "the live log must fold before teardown"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$fb:$PATH" \
    "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "teardown of landed work failed: $(cat "$case_dir/stderr")"

  assert_absent "$home/state/task-x1.status" "teardown must have removed the status log"
  # The signature outlives the task that reported it - which is the whole point,
  # since it only becomes actionable once a SECOND task hits it.
  after=$(fr "$home" list --json | jq -c '[.records[] | {sig, count}]')
  [ "$before" = "$after" ] \
    || fail "friction must survive teardown unchanged: $before vs $after"
  fr "$home" show issue-scope-understated | jq -e '
    .count == 1 and .tasks == ["task-x1"] and .projects == ["project"]
  ' >/dev/null || fail "the surviving record must still name the task and project that reported it"
  pass "friction records survive teardown of the task that reported them"
}

test_ingest_leaves_a_frictionless_home_untouched() {
  local home
  home=$(make_home no-friction)
  task_project "$home" task-a lobbyn
  status_append "$home" task-a "working: nothing to report" "done: shipped"
  fr "$home" ingest || fail "ingest must succeed on a home with no friction"
  assert_absent "$home/data/friction" \
    "ingest must not create a friction store for a home that never recorded any"
  pass "ingesting a home with no friction has no side effects"
}

test_signature_across_two_tasks_surfaces
test_single_task_signature_is_recorded_not_surfaced
test_counts_render_when_everything_is_zero
test_bearings_always_carries_the_three_counts
test_unattributable_record_surfaces_as_unclassified
test_guard_signature_offers_no_removal_option
test_guard_signature_surfaces_individually_with_its_caveat
test_cancelled_draft_returns_to_surfaced
test_settled_signature_keeps_counting_and_never_resurfaces
test_ingest_is_idempotent
test_friction_is_transparent_to_state_readers
test_malformed_friction_line_is_still_inert
test_friction_survives_teardown
test_ingest_leaves_a_frictionless_home_untouched

echo "all fm-friction tests passed"
