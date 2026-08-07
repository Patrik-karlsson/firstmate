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
  assert_contains "$(fr "$home" list)" "surfaced patterns: none" "text rendering must say nothing surfaced"
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

test_dot_leading_signature_is_unclassified_not_a_hidden_record() {
  local home json before after
  home=$(make_home dot-signature)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=.hidden-sig] a signature may not start with a dot"
  status_append "$home" task-b "friction: [sig=.hidden-sig] and here it is again"

  json=$(fr "$home" list --json)
  printf '%s' "$json" | jq -e '
    ([.records[].sig] | index(".hidden-sig")) == null and .counts.unclassified == 2
  ' >/dev/null || fail "a dot-leading signature must degrade to unclassified: $json"

  # The real failure this pins is durability, not naming: a record written to a
  # dotfile is rewritten from live data on every ingest and then disappears the
  # moment the status log is torn down. Read once with the logs present, then
  # once after teardown removes them.
  fr "$home" ingest || fail "ingest must succeed with a dot-leading signature present"
  before=$(fr "$home" list --json | jq -c '[.records[] | {sig, count}]')
  rm -f "$home"/state/task-a.status "$home"/state/task-b.status
  after=$(fr "$home" list --json | jq -c '[.records[] | {sig, count}]')
  [ "$before" = "$after" ] \
    || fail "a dot-leading signature's events must survive teardown: $before vs $after"
  pass "a dot-leading signature is preserved as unclassified, never as an unreadable record"
}

test_corrupt_record_file_costs_only_its_own_row() {
  local home json
  home=$(make_home corrupt-record)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=agents-md-conflict] advice contradicts a hook"
  status_append "$home" task-b "friction: [sig=agents-md-conflict] and again here"
  fr "$home" ingest || fail "ingest must succeed before corrupting a record"
  printf 'not json at all {' > "$home/data/friction/corrupted.json"

  # One unparseable record must not take the whole store down with it: the read
  # is batched for speed, and a batched read that aborts on the first bad file
  # is worse than the fork it saved.
  json=$(fr "$home" list --json) || fail "list must survive a corrupt record file"
  printf '%s' "$json" | jq -e '
    .counts.surfaced == 1
    and ([.records[].sig] | index("agents-md-conflict")) != null
  ' >/dev/null || fail "a corrupt record must not hide the good ones: $json"
  pass "a corrupt record file costs its own row and nothing else"
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

  # Its own record and its own SECTION, never ranked in the pattern list beside
  # the ordinary signature: batching is what turns a friction ranker into a
  # prioritised list of security controls to remove.
  printf '%s' "$json" | jq -e '
    ([.records[] | select(.surfaced)] | length) == 2
    and ([.records[] | select(.security == true) | .sig] == ["secret-blocker-false-positive"])
  ' >/dev/null || fail "the guard signature must surface as its own security-marked record: $json"
  local text; text=$(fr "$home" list)
  assert_contains "$text" "security guards - never batched" \
    "the rendering must give guard signatures their own section"
  assert_contains "$text" "frequency is not evidence a guard is wrong" \
    "the guard section must carry the frequency caveat"
  # The ordinary signature stays in the batched pattern list; the guard does not.
  printf '%s' "$text" | awk '/^surfaced patterns:/{s=1;next} /^$/{s=0} s' | grep -qF "issue-scope-understated" \
    || fail "the ordinary signature must appear in the batched surfaced list"
  printf '%s' "$text" | awk '/^surfaced patterns:/{s=1;next} /^$/{s=0} s' | grep -qF "secret-blocker-false-positive" \
    && fail "the guard signature must not be batched into the surfaced pattern list"

  draft=$(fr "$home" draft secret-blocker-false-positive --outcome keep)
  printf '%s' "$draft" | jq -e '.labels == ["known-friction"] and .close_on_file == true' >/dev/null \
    || fail "a keep draft must carry known-friction and close on filing: $draft"
  printf '%s' "$draft" | jq -re '.body' | grep -qF "Frequency is not evidence a guard is wrong" \
    || fail "a guard draft must carry the frequency caveat"
  printf '%s' "$draft" | jq -re '.body' | grep -qF "Observed false positives: 2" \
    || fail "a guard draft must carry its observed false-positive count"
  pass "a security-guard signature surfaces individually and carries its caveat"
}

test_guard_classification_survives_the_slugs_spelling() {
  local home out rc
  home=$(make_home guard-spelling)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  # The slug grammar admits capitals, `_` and `.`, so a guard can be named in a
  # spelling a plain hyphen-run match would miss. Under-classifying is the
  # expensive direction: it is what makes the mechanism recommend removing a
  # security control.
  status_append "$home" task-a "friction: [sig=Secret_Blocker.FP] blocker denied an edit to a docs path class"
  status_append "$home" task-b "friction: [sig=Secret_Blocker.FP] blocker denied an edit to a fixtures path class"

  out=$(fr "$home" outcomes Secret_Blocker.FP)
  [ "$out" = "keep
narrow" ] || fail "a guard signature must classify whatever its spelling, got: $out"

  set +e
  fr "$home" draft Secret_Blocker.FP --outcome clear >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "drafting a clear for a differently-spelled guard signature must be refused"

  # The stored signature is untouched: only the comparison is folded.
  fr "$home" show Secret_Blocker.FP | jq -e '.sig == "Secret_Blocker.FP" and .security == true' \
    >/dev/null || fail "the record must keep the signature the worker wrote"

  # An extension token is folded the same way, so a home cannot write one in a
  # form that can never match.
  home=$(make_home guard-spelling-token)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=vault-guard-denied] the vault guard refused a read"
  status_append "$home" task-b "friction: [sig=vault-guard-denied] and refused another"
  out=$(FM_FRICTION_GUARD_TOKENS='Vault_Guard' fr "$home" outcomes vault-guard-denied)
  [ "$out" = "keep
narrow" ] || fail "a configured guard token must match whatever its spelling, got: $out"
  pass "guard classification is not evaded by a signature's spelling"
}

test_bearings_never_batches_a_guard_into_the_ranked_list() {
  local home toon json
  home=$(seed_guard_home guard-bearings)
  toon=$(FM_HOME="$home" "$BEARINGS" 2>/dev/null) || fail "bearings failed on a seeded home"
  json=$(FM_HOME="$home" "$BEARINGS" --json 2>/dev/null) || fail "bearings --json failed"

  # bin/fm-friction.sh gives a guard its own section; the captain-facing
  # projection must not put it back into one ranked, bounded list where ordinary
  # friction can outrank and evict it.
  printf '%s' "$json" | jq -e '
    ([.friction[].sig] == ["issue-scope-understated"])
    and ([.friction_guards[].sig] == ["secret-blocker-false-positive"])
    and (.friction_guards[0].security == true)
  ' >/dev/null || fail "a guard row must live in friction_guards, never in friction: $json"

  # And the empty case renders rather than vanishing, for the same reason the
  # counts do: absent is indistinguishable from not-computed.
  home=$(make_home guard-bearings-empty)
  toon=$(FM_HOME="$home" "$BEARINGS" 2>/dev/null) || fail "bearings failed on an empty home"
  assert_contains "$toon" "friction_guards: []" \
    "an empty guard list must still render as the empty-array form"
  pass "bearings keeps guard signatures out of the ranked friction list"
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

test_cancel_without_a_pending_draft_is_refused() {
  local home rc
  home=$(make_home cancel-no-draft)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=agents-md-conflict] advice contradicts a hook"
  status_append "$home" task-b "friction: [sig=agents-md-conflict] and again here"
  fr "$home" draft agents-md-conflict --outcome keep >/dev/null
  fr "$home" approve agents-md-conflict --issue https://example.invalid/issues/1 >/dev/null
  [ "$(counts "$home")" = "0 0 0 1" ] \
    || fail "the approved signature must be settled before the cancel, got: $(counts "$home")"

  # Cancel rejects a draft's wording. A settled signature has no draft to
  # reject, and reviving it would contradict "a kept signature keeps counting
  # and never re-surfaces" while it still carries its outcome and filed issue.
  set +e
  fr "$home" cancel agents-md-conflict >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cancelling a signature with no pending draft must be refused"
  [ "$(counts "$home")" = "0 0 0 1" ] \
    || fail "a refused cancel must leave the signature settled, got: $(counts "$home")"
  fr "$home" show agents-md-conflict | jq -e '
    .state == "kept" and .surfaced == false and .outcome == "keep"
    and .issue_url == "https://example.invalid/issues/1"
  ' >/dev/null || fail "a refused cancel must leave the settled record intact"
  pass "cancel requires a pending draft and never revives a settled signature"
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

# The predicate that lets a supervisor absorb a friction append. Every
# uncertain case must fail CLOSED (report "not friction-only", so the wake
# surfaces), because absorbing a real status is far worse than one extra wake.
# tests/fm-watch-triage.test.sh covers the watcher end to end; these pin the
# safety cases that are hard to reach from there.
test_friction_only_delta_fails_closed() {
  local dir log size
  dir=$(mktemp -d "$TMP_ROOT/delta.XXXXXX")
  log="$dir/task.status"

  printf 'working: setup\n' > "$log"
  size=$(LC_ALL=C wc -c < "$log" | tr -d ' ')
  printf 'friction: [sig=x] something got in the way\n' >> "$log"
  status_delta_is_friction_only "$log" "$size" \
    || fail "a delta of only friction lines must be recognised"

  # A real status in the same delta: never absorbed.
  printf 'working: setup\n' > "$log"
  size=$(LC_ALL=C wc -c < "$log" | tr -d ' ')
  printf 'friction: [sig=x] got in the way\nneeds-decision: pick A or B\n' >> "$log"
  ! status_delta_is_friction_only "$log" "$size" \
    || fail "a delta containing a real status must never be treated as friction-only"

  # A malformed friction line still counts as friction: it becomes an
  # unclassified RECORD, and it is still not a state change worth waking for.
  printf 'working: setup\n' > "$log"
  size=$(LC_ALL=C wc -c < "$log" | tr -d ' ')
  printf 'friction: no signature at all\n' >> "$log"
  status_delta_is_friction_only "$log" "$size" \
    || fail "a malformed friction line is still a friction-only delta"

  # No recorded previous size (a first sighting), no growth, a shrunk file, and
  # a missing file each fail closed.
  ! status_delta_is_friction_only "$log" "" \
    || fail "a first sighting with no recorded size must fail closed"
  ! status_delta_is_friction_only "$log" "$(LC_ALL=C wc -c < "$log" | tr -d ' ')" \
    || fail "a file that did not grow must fail closed"
  ! status_delta_is_friction_only "$log" 999999 \
    || fail "a shrunk file must fail closed"
  ! status_delta_is_friction_only "$dir/absent.status" 0 \
    || fail "a missing file must fail closed"
  pass "the friction-only delta test fails closed on every uncertain case"
}

test_last_status_line_is_exact_past_the_bounded_scan() {
  local dir log i
  dir=$(mktemp -d "$TMP_ROOT/bounded-scan.XXXXXX")
  log="$dir/task.status"
  # The only state-bearing line is the FIRST, buried under a friction tail far
  # longer than the bounded scan. Both phases must miss it and the full-file
  # fallback must still return it, or a long-running task reads as stateless.
  printf 'working: the only real state\n' > "$log"
  for i in $(seq 1 400); do
    printf 'friction: [sig=chatty] observation %d\n' "$i" >> "$log"
  done
  [ "$(FM_CLASSIFY_STATUS_TAIL=50 last_status_line "$log")" = "working: the only real state" ] \
    || fail "a state line before a long friction tail must survive the bounded scan"

  # And the ordinary case: a state line inside the tail wins over an earlier one.
  printf 'done: shipped\n' >> "$log"
  [ "$(FM_CLASSIFY_STATUS_TAIL=50 last_status_line "$log")" = "done: shipped" ] \
    || fail "the last state-bearing line must win"

  # A log SHORTER than the bound with no state-bearing line at all was fully
  # read by the bounded scan, so the empty answer is already exact and must not
  # be second-guessed into another pass.
  local short="$dir/short.status"
  printf 'friction: [sig=only] just friction\nfriction: [sig=only] and more\n' > "$short"
  [ -z "$(FM_CLASSIFY_STATUS_TAIL=50 last_status_line "$short")" ] \
    || fail "a friction-only log must report no state-bearing line"

  # Exactly the bound, with the state line outside it, still falls back.
  local exact="$dir/exact.status"
  printf 'working: buried at the front\n' > "$exact"
  for i in $(seq 1 50); do printf 'friction: [sig=chatty] observation %d\n' "$i" >> "$exact"; done
  [ "$(FM_CLASSIFY_STATUS_TAIL=50 last_status_line "$exact")" = "working: buried at the front" ] \
    || fail "a full-length friction tail must fall back to the whole file"
  pass "last_status_line stays exact when the bounded scan cannot answer"
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

# --- 6b. an accumulating store stays readable -------------------------------

test_large_store_stays_readable_and_never_renders_blind() {
  local home json text pad i
  home=$(make_home large-store)
  mkdir -p "$home/data/friction"
  # Seeded as record FILES rather than through ingest: data/friction/<sig>.json
  # is this script's own persisted-state contract (the same one the corrupt-record
  # case writes), and reaching the transport limit through status logs alone would
  # take minutes. 300 records x ~450 bytes puts the durable read well past the
  # ~128 KB a single argv string can carry.
  pad=$(printf 'x%.0s' $(seq 1 200))
  for i in $(seq 1 300); do
    jq -n --arg s "bulk-sig-$i" --arg p "$pad" '{
      sig: $s, first_seen: "2026-01-01T00:00:00Z", last_seen: "2026-01-02T00:00:00Z",
      count: 4, tasks: ["task-a", "task-b"], dropped_counts: {"task-a": 2, "task-b": 1},
      projects: ["lobbyn"],
      observations: [ { task: "task-a", ordinal: 1, sig: $s, text: $p,
                        project: "lobbyn", at: "2026-01-01T00:00:00Z" } ],
      state: "surfaced", security: false, outcome: null, issue_url: null, draft: null
    }' > "$home/data/friction/bulk-sig-$i.json"
  done
  [ "$(cat "$home/data/friction"/*.json | wc -c)" -gt 131072 ] \
    || fail "the seeded store must exceed a single argv string to be a real test"

  json=$(fr "$home" list --json) || fail "list --json must survive a large durable store"
  printf '%s' "$json" | jq -e 'has("counts") and .records_total == 300' >/dev/null \
    || fail "a large store must still produce a complete model: $(printf '%s' "$json" | head -c 200)"

  # Exit status alone does not catch this: the failure mode was a successful
  # exit with an empty rendering, which is the blind section the counts exist
  # to prevent.
  text=$(fr "$home" list) || fail "text rendering must survive a large durable store"
  [ -n "$text" ] || fail "a large store must never render an empty friction section"
  assert_contains "$text" "surfaced=300" "the counts must be stated over the whole store"
  fr "$home" ingest || fail "ingest must survive a large durable store"
  pass "an accumulated store stays readable and never renders a blind section"
}

test_observation_window_bounds_the_record_without_losing_counts() {
  local home json total
  home=$(make_home obs-window)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  local i
  for i in $(seq 1 40); do
    status_append "$home" task-a "friction: [sig=loud-sig] task-a occurrence $i"
    status_append "$home" task-b "friction: [sig=loud-sig] task-b occurrence $i"
  done

  # While the logs exist every observation is re-derivable, so none is evicted:
  # teardown folds one last time with the log still present, and evicting there
  # would discard exactly what that fold exists to preserve.
  FM_FRICTION_OBSERVATIONS=5 fr "$home" ingest || fail "ingest must succeed with a window"
  json=$(FM_FRICTION_OBSERVATIONS=5 fr "$home" show loud-sig)
  printf '%s' "$json" | jq -e '
    .count == 80 and (.observations | length) == 80 and .observations_dropped == 0
  ' >/dev/null || fail "a live task must keep its observations: $json"

  # Once the logs are gone the record is the only source, so the window applies
  # and the dropped occurrences must still be counted.
  rm -f "$home"/state/task-a.status "$home"/state/task-b.status
  FM_FRICTION_OBSERVATIONS=5 fr "$home" ingest || fail "ingest after teardown must succeed"
  json=$(FM_FRICTION_OBSERVATIONS=5 fr "$home" show loud-sig)
  printf '%s' "$json" | jq -e '
    .count == 80 and (.tasks | sort) == ["task-a", "task-b"]
    and .first_seen != null and (.observations | length) == 5
    and .observations_dropped == 75
  ' >/dev/null || fail "count and tasks must survive teardown of every reporting task: $json"

  # Re-folding must not inflate: the same events seen again are the same events.
  total=$(FM_FRICTION_OBSERVATIONS=5 fr "$home" show loud-sig | jq -r '.count')
  FM_FRICTION_OBSERVATIONS=5 fr "$home" ingest
  [ "$(FM_FRICTION_OBSERVATIONS=5 fr "$home" show loud-sig | jq -r '.count')" = "$total" ] \
    || fail "re-ingesting must not inflate a windowed count"

  # And a log recreated for the same task after its observations were evicted
  # must ADD its new events rather than be absorbed. This is the case a tally
  # that took a maximum silently swallowed.
  for i in $(seq 1 10); do
    status_append "$home" task-a "friction: [sig=loud-sig] a later run occurrence $i"
  done
  FM_FRICTION_OBSERVATIONS=5 fr "$home" ingest || fail "ingest of a recreated log must succeed"
  FM_FRICTION_OBSERVATIONS=5 fr "$home" show loud-sig | jq -e '.count == 90' >/dev/null \
    || fail "a recreated log must add its events on top of the tally: $(FM_FRICTION_OBSERVATIONS=5 fr "$home" show loud-sig | jq -c '{count,dropped_counts}')"
  pass "the observation window bounds the record while count and tasks stay exact"
}

test_triage_preserves_the_exact_count() {
  local home
  home=$(make_home triage-count)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  local i
  for i in $(seq 1 15); do
    status_append "$home" task-a "friction: [sig=agents-md-conflict] task-a occurrence $i"
    status_append "$home" task-b "friction: [sig=agents-md-conflict] task-b occurrence $i"
  done
  FM_FRICTION_OBSERVATIONS=3 fr "$home" ingest

  # Every triage command rewrites the record through the durable field list, so
  # a per-task tally missing from that list is silently dropped the first time
  # the captain touches a signature.
  FM_FRICTION_OBSERVATIONS=3 fr "$home" draft agents-md-conflict --outcome keep >/dev/null \
    || fail "drafting must succeed"
  FM_FRICTION_OBSERVATIONS=3 fr "$home" approve agents-md-conflict --issue https://example.invalid/1 >/dev/null \
    || fail "approving must succeed"

  # Asserted only after teardown. While the status logs are present the live
  # fold still supplies every event, so a tally lost in a triage rewrite stays
  # invisible; the record is the sole source exactly once the logs are gone.
  rm -f "$home"/state/task-a.status "$home"/state/task-b.status
  FM_FRICTION_OBSERVATIONS=3 fr "$home" ingest || fail "ingest after teardown must succeed"
  FM_FRICTION_OBSERVATIONS=3 fr "$home" show agents-md-conflict | jq -e '
    .count == 30 and (.tasks | sort) == ["task-a", "task-b"] and .state == "kept"
  ' >/dev/null || fail "triage must not collapse the exact count: $(FM_FRICTION_OBSERVATIONS=3 fr "$home" show agents-md-conflict)"
  pass "triage rewrites preserve the exact occurrence count"
}

test_settled_signature_cannot_be_redrafted() {
  local home rc
  home=$(make_home settled-redraft)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=agents-md-conflict] advice contradicts a hook"
  status_append "$home" task-b "friction: [sig=agents-md-conflict] and again here"
  fr "$home" draft agents-md-conflict --outcome keep >/dev/null
  fr "$home" approve agents-md-conflict --issue https://example.invalid/1 >/dev/null

  # draft creates exactly the pending draft cancel accepts, so an ungated draft
  # walks a settled signature back to surfaced one step further out.
  set +e
  fr "$home" draft agents-md-conflict --outcome clear >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "drafting a settled signature must be refused"
  [ "$(counts "$home")" = "0 0 0 1" ] \
    || fail "a settled signature must stay settled, got: $(counts "$home")"
  fr "$home" show agents-md-conflict | jq -e '
    .state == "kept" and .surfaced == false and .draft == null
    and .outcome == "keep" and .issue_url == "https://example.invalid/1"
  ' >/dev/null || fail "the settled record must be untouched by a refused draft"
  pass "a settled signature cannot be revived by drafting and then cancelling"
}

test_shape_invalid_record_costs_only_its_own_row() {
  local home json
  home=$(make_home shape-invalid)
  mkdir -p "$home/data/friction"
  jq -n '{sig:"good-sig",first_seen:"2026-01-01T00:00:00Z",last_seen:"2026-01-01T00:00:00Z",
          count:2,tasks:["task-a","task-b"],dropped_counts:{"task-a":1,"task-b":1},
          projects:["lobbyn"],observations:[],state:"surfaced",security:false,
          outcome:null,issue_url:null,draft:null}' > "$home/data/friction/good-sig.json"
  # Valid JSON, wrong shape: an observation with no task. friction-triage tells
  # an agent to hand-correct a record that captured a payload, which is exactly
  # how one gets written - and every task-keyed group in the fold errors on a
  # null key, so this must cost its own row like an unparseable file does.
  # dropped_counts is the wrong type too, so the per-task tally coerces away and
  # the record's own count is the ONLY surviving source of the dropped base.
  jq -n '{sig:"weird-sig",first_seen:"2026-01-01T00:00:00Z",last_seen:"2026-01-01T00:00:00Z",
          count:7,tasks:["task-a"],dropped_counts:"corrupt",projects:[],
          observations:[{text:"redacted",ordinal:1,at:"2026-01-01T00:00:00Z"}],
          state:"new",security:false,outcome:null,issue_url:null,draft:null}' \
    > "$home/data/friction/weird-sig.json"

  json=$(fr "$home" list --json) || fail "a shape-invalid record must not break the read"
  printf '%s' "$json" | jq -e '
    ([.records[].sig] | index("good-sig")) != null
    and ([.records[] | select(.sig == "good-sig") | .count] == [2])
  ' >/dev/null || fail "the neighbouring record must stay readable: $json"

  # The bad record must degrade, not evaporate: with its tally unusable the
  # count and task list are read back from the record rather than collapsing to
  # what the surviving observations can prove.
  printf '%s' "$json" | jq -e '
    [.records[] | select(.sig == "weird-sig")] as $w
    | ($w | length) == 1 and $w[0].count == 7 and $w[0].tasks == ["task-a"]
  ' >/dev/null || fail "a shape-invalid record must keep its count and tasks: $json"

  fr "$home" ingest || fail "ingest, the only writer, must survive a shape-invalid record"
  # Re-read after the rewrite: the record now holds no observations at all, so a
  # second fold has nothing but the read-back to work from.
  fr "$home" show weird-sig | jq -e '.count == 7 and .tasks == ["task-a"]' >/dev/null \
    || fail "the count must survive a rewrite that leaves no observations: $(fr "$home" show weird-sig)"
  pass "a shape-invalid record costs its own row and never bricks the store"
}

test_outcomes_propagates_a_read_failure() {
  local home rc out
  home=$(make_home outcomes-rc)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=agents-md-conflict] advice contradicts a hook"
  status_append "$home" task-b "friction: [sig=agents-md-conflict] and again here"

  # outcomes is the interlock triage checks before drafting, so an empty answer
  # must never be indistinguishable from a real one.
  out=$(fr "$home" outcomes agents-md-conflict) || fail "outcomes must succeed for a real signature"
  assert_contains "$out" "clear" "a real signature must report its outcomes"
  set +e
  fr "$home" outcomes no-such-sig >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "outcomes must propagate a read failure the way show does"
  pass "outcomes reports a read failure instead of succeeding with empty output"
}

test_eviction_keeps_evidence_from_every_task() {
  local home json text draft
  home=$(make_home eviction-spread)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  local i
  for i in $(seq 1 12); do
    status_append "$home" task-a "friction: [sig=loud] task-a occurrence $i"
    status_append "$home" task-b "friction: [sig=loud] task-b occurrence $i"
  done
  FM_FRICTION_OBSERVATIONS=4 fr "$home" ingest
  rm -f "$home"/state/task-a.status "$home"/state/task-b.status
  FM_FRICTION_OBSERVATIONS=4 fr "$home" ingest

  # A signature surfaces because INDEPENDENT tasks hit it. A window that evicts
  # whole tasks leaves the record unable to support the claim its draft makes.
  json=$(FM_FRICTION_OBSERVATIONS=4 fr "$home" show loud)
  printf '%s' "$json" | jq -e '
    .count == 24 and (.tasks | sort) == ["task-a", "task-b"]
    and ([.observations[].task] | unique | sort) == ["task-a", "task-b"]
  ' >/dev/null || fail "the window must keep evidence from every task: $json"

  # And both human-facing surfaces must say the list is short.
  draft=$(FM_FRICTION_OBSERVATIONS=4 fr "$home" draft loud --outcome clear | jq -r '.body')
  assert_contains "$draft" "of 24 observation(s)" "a draft must disclose elided observations"
  text=$(FM_FRICTION_OBSERVATIONS=4 fr "$home" list)
  assert_contains "$text" "observations elided by the retained window" \
    "the text rendering must disclose elided observations"
  pass "eviction spreads across tasks and both surfaces disclose the elision"
}

test_unclassified_section_discloses_its_window() {
  local home text
  home=$(make_home unclassified-window)
  task_project "$home" task-a lobbyn
  local i
  for i in $(seq 1 12); do
    status_append "$home" task-a "friction: no signature token $i"
  done
  FM_FRICTION_OBSERVATIONS=3 fr "$home" ingest
  rm -f "$home"/state/task-a.status
  FM_FRICTION_OBSERVATIONS=3 fr "$home" ingest

  text=$(FM_FRICTION_OBSERVATIONS=3 fr "$home" list)
  assert_contains "$text" "unclassified: 12 event(s)" "the unclassified count must stay exact"
  assert_contains "$text" "showing 3 of 12" "the unclassified section must disclose its window"
  pass "the unclassified section discloses how much of its history it shows"
}

test_draft_survives_a_very_chatty_signature() {
  local home pad i json body
  home=$(make_home chatty-draft)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  # Observations for a task whose log is still LIVE are never evicted - that is
  # the authorized carve-out that keeps teardown's last fold honest - so a
  # heavily reported signature carries an unbounded draft body. The status logs
  # stay in place here for exactly that reason.
  pad=$(printf 'y%.0s' $(seq 1 180))
  for i in $(seq 1 350); do
    status_append "$home" task-a "friction: [sig=chatty-helper] occurrence $i $pad"
    status_append "$home" task-b "friction: [sig=chatty-helper] occurrence $i $pad"
  done
  fr "$home" ingest || fail "ingest must succeed for a chatty signature"
  json=$(fr "$home" show chatty-helper)
  printf '%s' "$json" | jq -e '.count == 700 and .observations_dropped == 0' >/dev/null \
    || fail "the fixture must retain every observation to exercise the draft transport: $(printf '%s' "$json" | jq -c '{count,observations_dropped}')"

  # The most-reported signature is the one the ranking exists to surface, so it
  # must not be the one signature that cannot be triaged.
  fr "$home" draft chatty-helper --outcome clear >/dev/null \
    || fail "drafting the most-reported signature must not fail on transport"
  # Round-trip, not just the exit code: a draft that silently stored null would
  # look like success.
  fr "$home" show chatty-helper | jq -e '
    .draft != null and .draft.outcome == "clear" and (.draft.body | length) > 100000
  ' >/dev/null || fail "the drafted issue must be stored intact: $(fr "$home" show chatty-helper | jq -c '.draft | {outcome, body_len:(.body|length)}')"
  # And the body the captain reads must agree with the record it hangs off.
  body=$(fr "$home" show chatty-helper | jq -r '.draft.body')
  assert_contains "$body" "observed 700 time(s) across 2 task(s)" \
    "the drafted body must agree with the record it is attached to"
  pass "a very chatty signature can still be drafted and the draft round-trips"
}

test_a_guard_signature_survives_the_record_cap() {
  local home text json i t
  home=$(make_home guard-vs-cap)
  for t in task-a task-b task-c; do task_project "$home" "$t" lobbyn; done
  # Ordinary signatures outrank the guard on task count, so under one flat
  # ranked cap the guard is the row that falls off. A cap is not allowed to be
  # a way to hide a containment guard.
  for i in $(seq 1 8); do
    for t in task-a task-b task-c; do
      status_append "$home" "$t" "friction: [sig=ordinary-$i] noise"
    done
  done
  status_append "$home" task-a "friction: [sig=secret-blocker-fp] guard denied a docs path class"
  status_append "$home" task-b "friction: [sig=secret-blocker-fp] guard denied a fixtures path class"

  text=$(FM_FRICTION_RECORDS=4 fr "$home" list)
  assert_contains "$text" "security guards - never batched" \
    "a guard must keep its own section however tight the record cap is"
  assert_contains "$text" "secret-blocker-fp" "the guard signature must be named under the cap"
  json=$(FM_FRICTION_RECORDS=4 fr "$home" list --json)
  printf '%s' "$json" | jq -e '
    ([.records[] | select(.security) | .sig] == ["secret-blocker-fp"])
    and .records_truncated > 0
  ' >/dev/null || fail "the guard must survive a cap that truncates ordinary records: $(printf '%s' "$json" | jq -c '{records_truncated, guards:[.records[]|select(.security)|.sig]}')"

  # And the same through the captain-facing projection, including its own bound.
  json=$(FM_HOME="$home" FM_FRICTION_RECORDS=4 FM_BEARINGS_FRICTION=2 "$BEARINGS" --json 2>/dev/null) \
    || fail "bearings must render with a tight cap"
  printf '%s' "$json" | jq -e '
    ([.friction_guards[].sig] == ["secret-blocker-fp"])
  ' >/dev/null || fail "bearings must still show the guard under both bounds: $(printf '%s' "$json" | jq -c '{friction_guards, friction:(.friction|length)}')"
  pass "a guard signature survives every record bound on both surfaces"
}

test_illegal_stored_signature_costs_only_its_own_row() {
  local home
  home=$(make_home illegal-sig)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=good-sig] one"
  status_append "$home" task-b "friction: [sig=good-sig] two"
  fr "$home" ingest || fail "ingest must succeed before seeding an illegal record"
  # write_record refuses an illegal slug and ingest propagates that refusal, so
  # an unscreened record here would stop the ONLY writer for every signature.
  jq -n '{sig:"../../escaped",first_seen:"2026-01-01T00:00:00Z",last_seen:"2026-01-01T00:00:00Z",
          count:1,tasks:["task-a"],dropped_counts:{},projects:[],observations:[],
          state:"new",security:false,outcome:null,issue_url:null,draft:null}' \
    > "$home/data/friction/escaped.json"

  fr "$home" ingest || fail "an illegal stored signature must not stop the only writer"
  fr "$home" draft good-sig --outcome clear >/dev/null \
    || fail "a neighbouring signature must stay triageable"
  fr "$home" list --json | jq -e '
    ([.records[].sig] | index("../../escaped")) == null
    and ([.records[].sig] | index("good-sig")) != null
  ' >/dev/null || fail "the illegal record must degrade to its own row"
  assert_present "$home/data/friction/escaped.json" \
    "the offending file must be left in place for inspection rather than deleted"
  pass "an illegal stored signature costs its own row and never stops the writer"
}

test_unclassified_aggregate_survives_the_signature_screen() {
  local home
  home=$(make_home unclassified-screen)
  task_project "$home" task-a lobbyn
  status_append "$home" task-a "friction: no signature token at all"
  fr "$home" ingest || fail "ingest must record the unattributable line"
  # The aggregate is stored under a sentinel that is deliberately NOT a legal
  # slug, so a signature screen must special-case it or the unclassified count
  # silently drops to zero once the reporting log is gone.
  rm -f "$home"/state/task-a.status
  fr "$home" list --json | jq -e '.counts.unclassified == 1' >/dev/null \
    || fail "the unclassified aggregate must survive teardown: $(fr "$home" list --json | jq -c .counts)"
  pass "the unclassified aggregate survives the stored-signature screen"
}

test_an_unusual_but_legal_signature_survives_teardown() {
  local home json
  home=$(make_home unusual-slug)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  # `_` and `-` lead a legal slug: the parser accepts it and record_path writes
  # it, so a reader that accepts less turns the record into a write-only file
  # that disappears exactly when teardown makes the store the only source.
  status_append "$home" task-a "friction: [sig=_internal-helper-refuses] helper refused"
  status_append "$home" task-b "friction: [sig=_internal-helper-refuses] refused again"
  status_append "$home" task-a "friction: [sig=-dash-lead-sig] another one"
  status_append "$home" task-b "friction: [sig=-dash-lead-sig] and again"
  fr "$home" ingest || fail "ingest must accept a legal leading-underscore signature"

  rm -f "$home"/state/task-a.status "$home"/state/task-b.status
  json=$(fr "$home" list --json)
  printf '%s' "$json" | jq -e '
    .counts.surfaced == 2
    and ([.records[].sig] | index("_internal-helper-refuses")) != null
    and ([.records[].sig] | index("-dash-lead-sig")) != null
  ' >/dev/null || fail "a legal signature must survive teardown: $(printf '%s' "$json" | jq -c '{counts, sigs:[.records[].sig]}')"
  fr "$home" show _internal-helper-refuses | jq -e '.count == 2 and (.tasks | length) == 2' \
    >/dev/null || fail "the surviving record must still be readable by signature"
  pass "a legal but unusual signature survives teardown on every surface"
}

test_signature_grammar_agrees_across_its_consumers() {
  local sig home accepted stored
  # The grammar is applied by the parser, by the writer that turns a signature
  # into a filename, and by the reader that screens stored records. They are
  # three consumers of ONE rule, so drift between them is the defect class this
  # pins: anything the parser accepts must round-trip through write and read.
  for sig in _leading -leading a.b_c ok-sig UPPER.Case_9 x; do
    home=$(make_home "grammar-$(printf '%s' "$sig" | tr -c 'A-Za-z0-9' '-')")
    task_project "$home" task-a lobbyn
    task_project "$home" task-b lobbyn
    status_append "$home" task-a "friction: [sig=$sig] first"
    status_append "$home" task-b "friction: [sig=$sig] second"
    accepted=$(fr "$home" list --json | jq -r --arg s "$sig" '[.records[].sig] | index($s) | tostring')
    [ "$accepted" != "null" ] || fail "the parser must accept the legal signature $sig"
    fr "$home" ingest || fail "the writer must accept the legal signature $sig"
    rm -f "$home"/state/task-a.status "$home"/state/task-b.status
    stored=$(fr "$home" list --json | jq -r --arg s "$sig" '[.records[].sig] | index($s) | tostring')
    [ "$stored" != "null" ] \
      || fail "the stored-record screen rejected $sig, which the parser and writer both accept"
  done
  # And the direction that must stay rejected everywhere: a leading dot would
  # write a dotfile the reading glob never matches again.
  home=$(make_home grammar-rejected)
  task_project "$home" task-a lobbyn
  status_append "$home" task-a "friction: [sig=.hidden-sig] should not classify"
  fr "$home" list --json | jq -e '
    ([.records[].sig] | index(".hidden-sig")) == null and .counts.unclassified == 1
  ' >/dev/null || fail ".hidden-sig must degrade to unclassified, not become a signature"
  pass "the signature grammar agrees across parser, writer and stored-record screen"
}

test_dismiss_refuses_a_settled_signature() {
  local home rc
  home=$(make_home dismiss-settled)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=slow-helper] took 40s"
  status_append "$home" task-b "friction: [sig=slow-helper] took 41s"
  fr "$home" draft slow-helper --outcome keep >/dev/null
  fr "$home" approve slow-helper --issue https://example.invalid/1 >/dev/null

  # dismiss means "not a real pattern". Applying it to a kept signature would
  # leave the record asserting that AND carrying the filed issue that says the
  # friction is intentional and stays.
  set +e
  fr "$home" dismiss slow-helper >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dismissing an already-settled signature must be refused"
  fr "$home" show slow-helper | jq -e '
    .state == "kept" and .outcome == "keep" and .issue_url == "https://example.invalid/1"
  ' >/dev/null || fail "a refused dismiss must leave the settled record intact"

  # The guard refusal must still hold independently.
  home=$(make_home dismiss-guard)
  task_project "$home" task-a lobbyn
  task_project "$home" task-b lobbyn
  status_append "$home" task-a "friction: [sig=secret-blocker-fp] denied a docs path"
  status_append "$home" task-b "friction: [sig=secret-blocker-fp] denied a fixtures path"
  set +e
  fr "$home" dismiss secret-blocker-fp >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dismissing a guard signature must still be refused"
  pass "dismiss refuses a settled signature and still refuses a guard"
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
test_dot_leading_signature_is_unclassified_not_a_hidden_record
test_corrupt_record_file_costs_only_its_own_row
test_guard_signature_offers_no_removal_option
test_guard_signature_surfaces_individually_with_its_caveat
test_guard_classification_survives_the_slugs_spelling
test_bearings_never_batches_a_guard_into_the_ranked_list
test_cancelled_draft_returns_to_surfaced
test_cancel_without_a_pending_draft_is_refused
test_settled_signature_cannot_be_redrafted
test_settled_signature_keeps_counting_and_never_resurfaces
test_large_store_stays_readable_and_never_renders_blind
test_observation_window_bounds_the_record_without_losing_counts
test_triage_preserves_the_exact_count
test_ingest_is_idempotent
test_friction_is_transparent_to_state_readers
test_friction_only_delta_fails_closed
test_last_status_line_is_exact_past_the_bounded_scan
test_malformed_friction_line_is_still_inert
test_shape_invalid_record_costs_only_its_own_row
test_outcomes_propagates_a_read_failure
test_eviction_keeps_evidence_from_every_task
test_unclassified_section_discloses_its_window
test_draft_survives_a_very_chatty_signature
test_a_guard_signature_survives_the_record_cap
test_illegal_stored_signature_costs_only_its_own_row
test_unclassified_aggregate_survives_the_signature_screen
test_an_unusual_but_legal_signature_survives_teardown
test_signature_grammar_agrees_across_its_consumers
test_dismiss_refuses_a_settled_signature
test_friction_survives_teardown
test_ingest_leaves_a_frictionless_home_untouched

echo "all fm-friction tests passed"
