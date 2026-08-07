#!/usr/bin/env bash
# fm-friction.sh - durable friction records and the captain's triage surface.
#
# Workers append `friction: [sig=<slug>] <one-line observation>` when something
# impeded the work without blocking it. bin/fm-classify-lib.sh owns the verb and
# the per-line fold; this script owns the durable record, the recurrence
# threshold, the three mandatory counts, and the triage lifecycle.
#
# Usage:
#   fm-friction.sh list [--json] [--limit <n>]
#   fm-friction.sh show <sig>
#   fm-friction.sh outcomes <sig>
#   fm-friction.sh ingest
#   fm-friction.sh draft <sig> --outcome <clear|keep|narrow>
#   fm-friction.sh approve <sig> --issue <url>
#   fm-friction.sh cancel <sig>
#   fm-friction.sh dismiss <sig>
#
# `list`, `show`, and `outcomes` are PURE READS: they merge the durable records
# under data/friction/ with a live fold of state/*.status and write nothing, so
# a read-only surface such as /bearings can call them without mutating state.
# `ingest` is the write path; every triage command ingests first.
#
# Records. One durable record per signature at data/friction/<sig>.json, holding
# sig, first_seen, last_seen, count, tasks[], dropped_counts{}, projects[],
# observations[], state, plus security, outcome, issue_url, and draft. The
# unattributable aggregate lives at data/friction/@unclassified.json; `@` is not
# a legal signature character, so it can never collide with a real signature.
#
# A record is BOUNDED; the history it summarises is not. Nothing prunes a
# signature - a settled one keeps counting, and teardown folds a task's events
# in so they outlive the task - so retaining every observation would grow one
# file without limit until it could no longer be read at all. Only the
# observation TEXTS are windowed, and only for tasks that are already gone:
#   An observation whose task still has a status log is RE-DERIVABLE, so it is
#   never evicted. That is not an optimisation: teardown folds one last time
#   while the log still exists, and evicting there would discard the events that
#   fold exists to preserve. Once the log is gone the record is the only source,
#   and the FM_FRICTION_OBSERVATIONS most recent of those are kept.
#   count, tasks[] and first_seen/last_seen stay EXACT and never shrink, because
#   they are what the threshold, the counts and the ranking read. count and
#   tasks are READ BACK from the record rather than rederived from the surviving
#   window, so neither can fall below what the record already established as
#   observations are evicted - in particular the distinct-task count the
#   threshold reads cannot drop back under the surfacing bar. dropped_counts
#   carries the per-task eviction tally and supplies the same base; the larger of
#   the two wins, which restores the base if the tally is ever lost. It is a
#   BASE and never a ceiling: what the current fold can see is added on top, so a
#   log recreated after its observations were evicted still counts its new
#   events, and re-folding an unchanged log adds nothing.
#   observations_dropped states how many occurrences the window does not show,
#   and both human-facing surfaces repeat it - `list` and every composed draft
#   say "showing N of M" - so a shortened list is never mistaken for the whole
#   history.
# Retention inside the window is ROUND-ROBIN across tasks, newest first within
# each task. A flat most-recent-N would concentrate the loss: every live event
# folded in one pass carries that pass's single timestamp, so the sort ties and
# the tie-break degrades to alphabetical-by-task, evicting whole tasks. A
# signature surfaces because independent tasks hit it, so the record has to keep
# evidence from each task it is claimed to span.
# security is recomputed on every read and never taken from the record, so a
# stored classification can never outlive a change to the guard token list.
# The unclassified aggregate is windowed too. Its texts are the only value it
# carries, but exempting it would restore unbounded growth for exactly the
# repeated-typo case; counts.unclassified stays exact and the drop is disclosed.
#
# States are new, surfaced, cleared, kept, and dismissed. The aggregate record
# carries the non-signature state `unclassified` and never enters triage.
#
# Recurrence threshold: a signature surfaces at FM_FRICTION_THRESHOLD (default 2)
# or more DISTINCT TASKS. One task hitting the same thing repeatedly is usually
# one worker looping; two tasks independently hitting it is a system problem.
#
# The three mandatory counts, stated in every rendering including when all are
# zero. Their definitions matter, because a reader who assumes a settled
# signature is hiding inside `suppressed` will misread a quiet section:
#   surfaced     - signatures at or above threshold and still eligible
#                  (state new or surfaced).
#   suppressed   - signatures below threshold and still eligible. NOT a
#                  synonym for "hidden": a settled signature is not here.
#   unclassified - friction EVENTS the fold could not attribute to a signature,
#                  counted per event rather than per record.
# `settled` is reported alongside them as inventory disclosure, not as a fourth
# mandatory count: it holds every cleared, kept, and dismissed signature, so
# surfaced + suppressed + settled accounts for every signature record and a
# quiet section can be told apart from a blind one.
#
# Security carve-out. A signature naming a guard whose purpose is containment is
# never batched into a pattern list, and `clear` and `dismiss` are unavailable
# for it: its only outcomes are `keep` (an issue recording the cost and why the
# guard stays) or `narrow` (an issue proposing to tighten a false positive,
# never to remove or disable the guard). This mechanism ranks by how often
# something impedes work, which is the right signal for a broken helper and the
# WRONG signal for a guard - a guard that never fires falsely is a guard
# catching very little. Without the carve-out its natural output is a
# prioritised list of security controls to remove.
#
# A signature is security-classified when any of these tokens appears as a whole
# segment run in its slug:
#   secret credential security merge-into-main branch-protection push-protection
# The comparison folds case and reads `_` and `.` as segment separators, so
# `Secret_Blocker_FP` classifies exactly like `secret-blocker-fp`. Only the
# comparison is folded; the stored signature is never rewritten. A slug the
# grammar accepts must not be able to slip a guard past the carve-out by its
# spelling, and the same fold is applied to the configured tokens so an extension
# cannot be written in a form that can never match.
# FM_FRICTION_GUARD_TOKENS EXTENDS that list (space-separated); it deliberately
# cannot shrink it, so a home cannot switch the carve-out off. Over-classifying
# costs one triage option; under-classifying makes the mechanism recommend
# removing a security control.
#
# Triage never files anything. `draft` composes an issue and stores it for the
# captain; `approve` records the URL of an issue that was filed separately
# through gh-axi; `cancel` returns the signature to `surfaced` - rejecting a
# draft rejects the wording, not the finding, so it requires a draft to reject
# and refuses a signature that has none. `dismiss` is the separate,
# explicit act for a signature that is not a real pattern. A kept or dismissed
# signature keeps counting and never re-surfaces, so friction that was accepted
# once and later became severe is still visible on inspection - visible, not
# re-triageable: `draft` refuses a settled signature, because drafting one and
# then cancelling the draft would otherwise walk it back to `surfaced` still
# carrying the outcome and issue it was settled with.
#
# Scope: this home only. Records are keyed to the home's own data/ and state/,
# so a signature hit once in the main home and once in a secondmate home does
# NOT reach the threshold - each home counts its own. Cross-home aggregation is
# deliberately not built here.
#
# Environment:
#   FM_FRICTION_THRESHOLD      distinct tasks required to surface (default 2)
#   FM_FRICTION_RECORDS        max records in the rendered model (default 50);
#                              the COUNTS are always computed over every record
#   FM_FRICTION_OBSERVATIONS   observation texts retained per record (default
#                              20); count, tasks and first/last_seen stay exact
#   FM_FRICTION_GUARD_TOKENS   extra security-guard tokens, space-separated
#   FM_FRICTION_NOW            fixed timestamp, for deterministic tests
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FRICTION_DIR="$DATA/friction"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { printf 'fm-friction: %s\n' "$1" >&2; exit 1; }

# --help renders this script's header, which needs no jq: a box without jq must
# still be able to read what this does and what the guard list contains.
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || die "jq not found"

FM_FRICTION_THRESHOLD=${FM_FRICTION_THRESHOLD:-2}
case "$FM_FRICTION_THRESHOLD" in ''|*[!0-9]*|0) die "FM_FRICTION_THRESHOLD must be a positive integer" ;; esac
FM_FRICTION_RECORDS=${FM_FRICTION_RECORDS:-50}
case "$FM_FRICTION_RECORDS" in ''|*[!0-9]*|0) die "FM_FRICTION_RECORDS must be a positive integer" ;; esac
FM_FRICTION_OBSERVATIONS=${FM_FRICTION_OBSERVATIONS:-20}
case "$FM_FRICTION_OBSERVATIONS" in ''|*[!0-9]*|0) die "FM_FRICTION_OBSERVATIONS must be a positive integer" ;; esac

# The tracked containment-guard identities. Extended, never replaced, by
# FM_FRICTION_GUARD_TOKENS - see the carve-out note in the header.
FM_FRICTION_GUARDS_BUILTIN='secret credential security merge-into-main branch-protection push-protection'
GUARD_TOKENS="$FM_FRICTION_GUARDS_BUILTIN ${FM_FRICTION_GUARD_TOKENS:-}"

UNCLASSIFIED="$FM_CLASSIFY_FRICTION_UNCLASSIFIED"

now_ts() { printf '%s' "${FM_FRICTION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# Durable path for a signature. Rejects anything that is not a legal slug, so a
# signature can never escape data/friction/ nor land somewhere the read below
# cannot see it - a leading `.` passes the character class and is refused here,
# which covers `.` and `..` and also keeps a record out of a dotfile that
# stored_json's glob would never match again. fm-classify-lib.sh applies the
# same rule when it parses a signature off a status line, so a worker's typo
# degrades into an unclassified record rather than reaching this refusal.
record_path() {  # <sig>
  local sig=$1
  if [ "$sig" = "$UNCLASSIFIED" ]; then
    printf '%s/@unclassified.json' "$FRICTION_DIR"
    return 0
  fi
  case "$sig" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/%s.json' "$FRICTION_DIR" "$sig"
}

# task -> project NAME, from the task metadata this home already records.
# Task metadata stores `project=` as the clone's absolute path; a friction
# record keeps only the final component. That is the noun the captain uses, and
# a record that outlives every task in it has no business carrying a local
# filesystem path around.
#
# One jq for the whole map rather than one per task: every read path builds this,
# and a home accumulates task metadata for as long as it runs. The per-file read
# is plain parameter expansion, so a fleet with many tasks costs one process, not
# three per task. TAB separates the two fields; a project name is the final path
# component of a clone directory, so it cannot contain one.
project_map_json() {
  local m task line p
  {
    for m in "$STATE"/*.meta; do
      [ -e "$m" ] || continue
      task=${m##*/}; task=${task%.meta}
      p=""
      if [ -f "$m" ] && [ -r "$m" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            project=*) p=${line#project=} ;;
          esac
        done < "$m"
      fi
      p=${p%/}
      p=${p##*/}
      printf '%s\t%s\n' "$task" "$p"
    done
  } | jq -R -s '
    [ split("\n")[]
      | select(length > 0)
      | (. / "\t") as $f
      | {key: $f[0], value: ($f[1:] | join("\t"))} ]
    | from_entries'
}

# Live friction events across every status log in this home, as JSON. The parse
# is fm-classify-lib.sh's scan_friction; nothing here re-implements it.
live_json() {  # <now>
  scan_friction "$STATE" | jq -R -s \
    --arg at "$1" --argjson pm "$(project_map_json)" '
    [ split("\n")[]
      | select(length > 0)
      | (. / "\t") as $f
      | select(($f | length) >= 3)
      | { task: $f[0],
          ordinal: (try ($f[1] | tonumber) catch 0),
          sig: $f[2],
          text: ($f[3:] | join("\t")),
          project: ($pm[$f[0]] // ""),
          at: $at } ]'
}

# Task ids that still have a status log in this home. Bounded by the live fleet
# rather than by history, so it travels on argv like every other fleet-bounded
# input. merged_model needs it to tell a re-derivable observation from one that
# only the record still holds.
live_tasks_json() {
  local f task
  {
    for f in "$STATE"/*.status; do
      [ -e "$f" ] || continue
      task=${f##*/}; task=${task%.status}
      printf '%s\n' "$task"
    done
  } | jq -R -s 'split("\n") | map(select(length > 0))'
}

# Every durable record, as one JSON array in glob order.
#
# Read in ONE jq pass. A settled signature is never pruned by design, so a home's
# record count only grows, and bin/fm-fleet-snapshot.sh reads this on every
# snapshot - a jq per record would put that growth on the /bearings path. The
# single pass aborts on the first unparseable record, which would lose every
# good record with it, so the per-file loop stays as the fallback: one corrupt
# record must cost its own row and nothing else.
stored_json() {
  local f out
  set --
  for f in "$FRICTION_DIR"/*.json; do
    [ -e "$f" ] || continue
    set -- "$@" "$f"
  done
  [ "$#" -gt 0 ] || { printf '[]'; return 0; }
  if out=$(jq -s -c '[ .[] | select(type == "object" and (.sig | type) == "string") ]' "$@" 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  {
    for f in "$@"; do
      jq -c 'select(type == "object" and (.sig | type) == "string")' "$f" 2>/dev/null || true
    done
  } | jq -s '.'
}

# The ONE merge. Both the durable ingest and every pure read build their view
# here, so the two paths cannot drift into disagreeing about identity or counts.
#
# Observation identity is (task, ordinal, text). Ordinal alone would be enough
# for a strictly append-only log, but fm-classify-lib.sh's cursor code already
# defends against a status file being recreated, and with a bare ordinal a
# recreated log whose ordinal 3 holds different text would silently overwrite
# the stored one. Including the text turns that silent loss into two honest
# records, and re-ingesting an unchanged log stays exactly idempotent.
#
# Both inputs arrive on STDIN rather than through --argjson. They are the one
# pair of inputs in this repo with unbounded monotonic growth by design, and a
# single argv string is capped far below ARG_MAX (32 pages on Linux), so an
# --argjson transport turns an accumulating store into an unreadable one that
# ingest can no longer shrink. Capturing each into a shell variable first is
# also what makes a read failure propagate: a command substitution nested in an
# argument list discards its exit status.
merged_model() {  # <now>
  local now=$1 live stored
  live=$(live_json "$now") || return 1
  stored=$(stored_json) || return 1
  printf '%s\n%s\n' "$live" "$stored" | jq -n \
    --arg now "$now" \
    --arg unclassified "$UNCLASSIFIED" \
    --arg guards "$GUARD_TOKENS" \
    --argjson threshold "$FM_FRICTION_THRESHOLD" \
    --argjson window "$FM_FRICTION_OBSERVATIONS" \
    --argjson live_tasks "$(live_tasks_json)" '
    def obskey: [.task, (.ordinal | tostring), .text] | join(" ");
    # Fold a slug to its comparison form: one case, one segment separator. The
    # slug grammar admits `_`, `.` and capitals, so a raw hyphen-run match would
    # let `Secret_Blocker_FP` past the carve-out. Applied to both sides, so a
    # configured token cannot be spelled into a form that never matches.
    def slugfold: ascii_downcase | gsub("[._]"; "-");
    def guardmatch($sig; $tokens):
      ("-" + ($sig | slugfold) + "-") as $h
      | any($tokens[]; ("-" + slugfold + "-") as $t | ($h | contains($t)));
    # A stored record can be valid JSON and still be the wrong SHAPE - an agent
    # redacting a payload out of an observation writes exactly that. Every
    # task-keyed group_by and index below hard-errors on a null key, which would
    # take the whole store down rather than the one bad row, and ingest is the
    # only writer so there would be no way back. Coerce each field once, here,
    # instead of guarding each use.
    def normobs: if type == "array"
                 then map(select(type == "object" and (.task | type) == "string"))
                 else [] end;
    def normstrings: if type == "array" then map(select(type == "string")) else [] end;
    def normcounts: if type == "object"
                    then with_entries(select(.value | type == "number")) else {} end;
    def normnum: if type == "number" and . >= 0 then . else 0 end;

    (input) as $live
    | (input) as $stored
    | ($guards | split(" ") | map(select(length > 0)) | unique) as $gt
    | ($live | group_by(.sig) | map({key: .[0].sig, value: .}) | from_entries) as $live_by_sig
    | ($stored | map({key: .sig, value: .}) | from_entries) as $stored_by_sig
    | (($stored | map(.sig)) + ($live | map(.sig)) | unique) as $sigs
    | [ $sigs[] as $s
        | ($stored_by_sig[$s] // {}) as $raw
        | { observations: ($raw.observations | normobs),
            dropped_counts: ($raw.dropped_counts | normcounts),
            tasks: ($raw.tasks | normstrings),
            projects: ($raw.projects | normstrings),
            count: ($raw.count | normnum),
            first_seen: $raw.first_seen, last_seen: $raw.last_seen,
            state: $raw.state, outcome: $raw.outcome,
            issue_url: $raw.issue_url, draft: $raw.draft } as $rec
        | (($rec.observations + ($live_by_sig[$s] // []))
           | group_by(obskey) | map(sort_by(.at) | .[0])
           | sort_by([.at, .task, .ordinal])) as $obs
        # An observation belonging to a task whose status log still exists is
        # RE-DERIVABLE - the next fold reads it again - so evicting it would
        # lose nothing now and everything at teardown, which folds one last time
        # while the log is still there. Only observations whose task no longer
        # has a log are evictable, and each eviction is added to the permanent
        # dropped tally for the task it belonged to.
        #
        # count is then dropped + what this fold can see, per task. That is
        # exact in both directions a plain tally is not: re-folding an unchanged
        # log sees the same events and adds nothing, while a log recreated for a
        # task whose earlier observations were already evicted still adds its new
        # events on top of the tally. Taking a maximum instead would silently
        # swallow that second case, and counting the retained window alone would
        # shrink `count` to the window.
        | ($live_tasks | map({key: ., value: true}) | from_entries) as $is_live
        | ($obs | map(select($is_live[.task] // false))) as $live_obs
        | ($obs | map(select(($is_live[.task] // false) | not))) as $dead_obs
        # Retain ROUND-ROBIN across tasks, newest first within each task. Taking
        # the window off the tail of one flat sort concentrates the loss: every
        # live event folded in one pass carries that pass single timestamp, so
        # `.at` ties and the tie-break degrades to alphabetical-by-task, evicting
        # whole tasks. A signature surfaces because INDEPENDENT tasks hit it, so
        # a record that keeps no evidence from one of them cannot support the
        # claim its own draft makes.
        | ($dead_obs | group_by(.task) | map(sort_by([.at, .ordinal]) | reverse)) as $dead_by_task
        | ([ range(0; ($dead_by_task | map(length) | max // 0)) as $i
             | $dead_by_task[] | .[$i] // empty ] | .[:$window]) as $dead_kept
        | ($dead_kept | map({key: obskey, value: true}) | from_entries) as $keep_set
        | ($dead_obs | map(select(($keep_set[obskey] // false) | not))) as $evicted
        | $rec.dropped_counts as $prev_dropped
        | ($evicted | group_by(.task) | map({key: .[0].task, value: length}) | from_entries) as $evicted_tc
        | ((($prev_dropped | keys) + ($evicted_tc | keys) | unique) as $ks
           | [ $ks[] | {key: ., value: (($prev_dropped[.] // 0) + ($evicted_tc[.] // 0))} ]
           | from_entries) as $dropped_counts
        | ($obs | group_by(.task) | map({key: .[0].task, value: length}) | from_entries) as $obs_tc
        # The dropped base is read back from the record as well as summed from
        # the per-task tally, and the LARGER wins. In a healthy record the two
        # are equal by construction - the stored count is the tally plus the
        # stored window - so the max only bites when the tally was lost, where it
        # restores the base instead of letting the total collapse to the window.
        # It is a base, never a ceiling: the events this fold can see are added
        # ON TOP, so a log recreated after its observations were evicted still
        # counts its new events.
        | ([ ([$prev_dropped[]] | add // 0),
             (($rec.count - ($rec.observations | length))) ] | max | normnum) as $dropped_base
        | ($dropped_base + ($obs | length)) as $count
        # tasks is read back from the record too, so the distinct-task count the
        # threshold reads can never fall below what the record already claimed
        # as observations are evicted.
        | ((($prev_dropped | keys) + ($obs_tc | keys) + $rec.tasks) | unique) as $tasks
        | (($rec.projects + ($obs | map(.project)))
           | map(select(. != null and . != "")) | unique) as $projects
        | ([$rec.first_seen // empty] + ($obs | map(.at)) | min) as $first_seen
        | ([$rec.last_seen // empty] + ($obs | map(.at)) | max) as $last_seen
        | (($live_obs + $dead_kept) | sort_by([.at, .task, .ordinal])) as $kept
        | (if $s == $unclassified then "unclassified" else ($rec.state // "new") end) as $state
        | guardmatch($s; $gt) as $security
        | {
            sig: $s,
            first_seen: $first_seen,
            last_seen: $last_seen,
            count: $count,
            tasks: $tasks,
            dropped_counts: $dropped_counts,
            projects: $projects,
            observations: $kept,
            observations_dropped: ([$count - ($kept | length), 0] | max),
            state: $state,
            security: $security,
            outcome: ($rec.outcome // null),
            issue_url: ($rec.issue_url // null),
            draft: ($rec.draft // null)
          }
        | . + {
            above_threshold: (($tasks | length) >= $threshold),
            eligible: (.state == "new" or .state == "surfaced"),
            outcomes: (if $s == $unclassified then []
                       elif $security then ["keep", "narrow"]
                       else ["clear", "keep", "dismiss"] end)
          }
        | . + { surfaced: (.sig != $unclassified and .above_threshold and .eligible) } ]
    | . as $records
    | ($records | sort_by([(if .surfaced then 0 else 1 end), -(.tasks | length), .sig])) as $ordered
    | {
        schema: "fm-friction.v1",
        generated: $now,
        threshold: $threshold,
        counts: {
          surfaced:     ([$records[] | select(.surfaced)] | length),
          suppressed:   ([$records[] | select(.sig != $unclassified and .eligible and (.above_threshold | not))] | length),
          unclassified: ([$records[] | select(.sig == $unclassified) | .count] | add // 0),
          settled:      ([$records[] | select(.sig != $unclassified and (.eligible | not))] | length)
        },
        records: $ordered,
        records_total: ($ordered | length)
      }'
}

# Apply the rendering cap. Deliberately separate from merged_model: the ingest
# and every per-signature lookup work over the COMPLETE record set, and the
# three counts above are always computed over every record. Only the rendered
# list is bounded, and it discloses what it dropped.
#
# Refuses a blank or shapeless model rather than rendering it. An empty home is
# a VALID model with zeroed counts and an empty record list; an empty STRING is
# a failed read upstream, and letting that through would print a section with no
# counts at all - the blind section the counts exist to prevent.
cap_model() {  # <model-json>
  [ -n "${1//[[:space:]]/}" ] || return 1
  printf '%s' "$1" | jq --argjson cap "$FM_FRICTION_RECORDS" '
    if (type == "object" and has("counts")) then
      .records_truncated = ([(.records | length) - $cap, 0] | max)
      | .records |= .[:$cap]
    else error("friction model is not a readable record set") end'
}

# Strip the derived view fields before persisting: threshold-dependent verdicts
# must be recomputed on read, never frozen into the record.
DURABLE_FIELDS='{sig,first_seen,last_seen,count,tasks,dropped_counts,projects,observations,state,security,outcome,issue_url,draft}'

write_record() {  # <record-json>
  local rec=$1 sig path tmp
  sig=$(printf '%s' "$rec" | jq -r '.sig')
  path=$(record_path "$sig") || { printf 'fm-friction: refusing illegal signature: %s\n' "$sig" >&2; return 1; }
  mkdir -p "$FRICTION_DIR"
  tmp="$path.tmp.$$"
  if printf '%s' "$rec" | jq "$DURABLE_FIELDS" > "$tmp"; then
    mv -f "$tmp" "$path"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Fold every live status log into the durable store. Idempotent by construction
# (see merged_model). Promotes an untouched `new` signature to `surfaced` once
# it reaches the threshold; a settled signature is never revived.
ingest() {
  local now model promoted rec
  now=$(now_ts)
  model=$(merged_model "$now") || die "could not read friction records"
  # Every record, never the capped rendering set: a rendering bound must never
  # decide what gets persisted.
  promoted=$(printf '%s' "$model" | jq -c --arg u "$UNCLASSIFIED" '
    .records[]
    | if (.sig != $u) and .state == "new" and .above_threshold
      then .state = "surfaced" else . end') \
    || die "friction ingest could not project records"
  # No unconditional mkdir: a home that has never recorded friction must stay
  # untouched by an ingest, so calling this from teardown is free of side
  # effects when there is nothing to preserve. write_record creates the
  # directory when there is actually something to write.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    write_record "$rec" || return 1
  done <<EOF
$promoted
EOF
}

# Read one signature's current record, ingest-free.
read_record() {  # <sig>
  local sig=$1 model
  model=$(merged_model "$(now_ts)") || die "could not read friction records"
  printf '%s' "$model" | jq -e --arg s "$sig" '.records[] | select(.sig == $s)' \
    || die "no friction record for signature: $sig"
}

require_sig() {  # <sig>
  [ -n "${1:-}" ] || die "a signature is required"
  [ "$1" != "$UNCLASSIFIED" ] || die "the unclassified aggregate is not a signature and cannot be triaged"
  record_path "$1" >/dev/null || die "illegal signature: $1"
}

# Mutate one stored record through a jq expression, after an ingest so a
# signature seen only in a live log is triageable.
update_record() {  # <sig> <jq-expr> [--arg name value]...
  local sig=$1 expr=$2; shift 2
  ingest
  local path rec tmp
  path=$(record_path "$sig")
  [ -f "$path" ] || die "no friction record for signature: $sig"
  rec=$(jq -e "$@" "$expr" "$path") || die "could not update record for $sig"
  tmp="$path.tmp.$$"
  if printf '%s\n' "$rec" | jq "$DURABLE_FIELDS" > "$tmp"; then
    mv -f "$tmp" "$path"
  else
    rm -f "$tmp"
    die "could not persist record for $sig"
  fi
}

# --- rendering --------------------------------------------------------------

render_text() {  # <model-json>
  [ -n "${1//[[:space:]]/}" ] || die "could not read friction records"
  printf '%s' "$1" | jq -r --arg u "$UNCLASSIFIED" '
    "FRICTION (threshold: \(.threshold) distinct tasks)",
    "counts: surfaced=\(.counts.surfaced) suppressed=\(.counts.suppressed) unclassified=\(.counts.unclassified) settled=\(.counts.settled)",
    "",
    (([.records[] | select(.surfaced and (.security | not))]) as $s
     | if ($s | length) == 0 then "surfaced patterns: none"
       else ("surfaced patterns:",
             ($s[] | "  \(.sig)  tasks=\(.tasks | length) count=\(.count)  outcomes: \(.outcomes | join(", "))",
                     "    last: \(.observations | last | .text)"))
       end),
    # A guard signature is rendered in its OWN section rather than beside the
    # ordinary patterns. Batching it into a ranked list is what turns this
    # mechanism into a prioritised list of security controls to remove, so the
    # separation is enforced here rather than left to whoever reads the output.
    (([.records[] | select(.surfaced and .security)]) as $g
     | if ($g | length) == 0 then empty
       else ("", "security guards - never batched, each is its own decision:",
             ($g[] | "  \(.sig)  tasks=\(.tasks | length) observed-false-positives=\(.count)  outcomes: \(.outcomes | join(", "))",
                     "    last: \(.observations | last | .text)"),
             "  frequency is not evidence a guard is wrong")
       end),
    (([.records[] | select(.sig == $u)]) as $u2
     | if ($u2 | length) == 0 then empty
       else ("", "unclassified: \($u2[0].count) event(s) the fold could not attribute to a signature",
             ($u2[0].observations[] | "  \(.task): \(.text)"),
             (if ($u2[0].observations_dropped // 0) > 0
              then "  showing \($u2[0].observations | length) of \($u2[0].count) (raise FM_FRICTION_OBSERVATIONS)"
              else empty end))
       end),
    # The window elides observations, never counts. Saying so here keeps the
    # text surface as honest as the record: a reader must not take a shortened
    # list for the whole history.
    (([.records[] | select(.surfaced and (.observations_dropped // 0) > 0)]) as $t
     | if ($t | length) == 0 then empty
       else ("", "observations elided by the retained window (counts and task lists stay exact):",
             ($t[] | "  \(.sig): showing \(.observations | length) of \(.count)"))
       end),
    (if .records_truncated > 0 then "", "records: showing \(.records | length) of \(.records_total) (raise FM_FRICTION_RECORDS)" else empty end)'
}

# --- issue drafting ---------------------------------------------------------
#
# Both `clear` and `keep` produce a drafted issue: a keep with no artifact is a
# decision that gets re-litigated the next time a worker trips over it. The
# draft is composed here and filed by the captain through gh-axi; nothing in
# this script talks to a forge.
compose_draft() {  # <record-json> <outcome> <now>
  local rec=$1 outcome=$2 now=$3
  printf '%s' "$rec" | jq \
    --arg outcome "$outcome" \
    --arg now "$now" '
    . as $r
    | (if $outcome == "clear" then
         "friction: \($r.sig) impedes work across \($r.tasks | length) tasks"
       elif $outcome == "keep" then
         "known friction: \($r.sig) stays, and what it costs"
       else
         "narrow \($r.sig) to cut false positives"
       end) as $title
    | (if $outcome == "keep" then ["known-friction"] else ["friction"] end) as $labels
    | (if $outcome == "clear" then
         "This friction should go. Firstmate proposes removing or fixing the cause."
       elif $outcome == "keep" then
         "This friction is intentional. This issue records why it stays and what it costs, so the decision is not re-litigated the next time a worker trips over it."
       else
         "This guard stays. This issue proposes tightening it to cut a false positive, and must never remove or disable it."
       end) as $intent
    | ([ "## What repeats",
         "",
         "`\($r.sig)` - observed \($r.count) time(s) across \($r.tasks | length) task(s)"
         + (if ($r.projects | length) > 0 then " in \($r.projects | join(", "))" else "" end)
         + ".",
         "",
         "First seen \($r.first_seen // "-"), last seen \($r.last_seen // "-").",
         "",
         "## Proposed outcome: \($outcome)",
         "",
         $intent,
         "",
         "## What each worker observed",
         "" ]
       + [ $r.observations[] | "- `\(.task)`\(if .project != "" then " (\(.project))" else "" end): \(.text)" ]
       + (if ($r.observations_dropped // 0) > 0 then
            [ "",
              "Showing \($r.observations | length) of \($r.count) observation(s); the rest were elided by the retained window. The occurrence count and the task list above are exact." ]
          else [] end)
       + (if $r.security then
            [ "",
              "## Security guard",
              "",
              "This signature names a containment guard, so it surfaces on its own rather than in a pattern list, and removing or disabling it is not an available outcome.",
              "",
              "Observed false positives: \($r.count) across \($r.tasks | length) task(s). The denominator - how often the guard fired in total - is NOT measured by this mechanism; it comes from the deferred project-side denial logging. Frequency is not evidence a guard is wrong: a guard that never fires falsely is a guard catching very little." ]
          else [] end)
       + (if $outcome == "keep" then
            [ "", "File with the `known-friction` label and close on filing, so it stays searchable without adding to the open backlog." ]
          else [] end)
       | join("\n")) as $body
    | { outcome: $outcome, title: $title, labels: $labels, body: $body,
        close_on_file: ($outcome == "keep"), drafted_at: $now }'
}

# --- commands ---------------------------------------------------------------

cmd=${1:-list}
if [ $# -gt 0 ]; then shift; fi

case "$cmd" in
  -h|--help|help)
    usage
    ;;

  ingest)
    ingest
    ;;

  list)
    FORMAT=text
    LIMIT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) FORMAT=json ;;
        --limit) shift; LIMIT=${1:-} ;;
        --limit=*) LIMIT=${1#--limit=} ;;
        *) usage >&2; exit 2 ;;
      esac
      shift
    done
    if [ -n "$LIMIT" ]; then
      case "$LIMIT" in ''|*[!0-9]*|0) die "--limit must be a positive integer" ;; esac
      FM_FRICTION_RECORDS=$LIMIT
    fi
    RAW=$(merged_model "$(now_ts)") || die "could not read friction records"
    MODEL=$(cap_model "$RAW") || die "could not read friction records"
    if [ "$FORMAT" = json ]; then printf '%s\n' "$MODEL"; else render_text "$MODEL"; fi
    ;;

  show)
    require_sig "${1:-}"
    read_record "$1"
    ;;

  outcomes)
    require_sig "${1:-}"
    # Captured, not piped: read_record dies on a failed read, and on the left of
    # a pipeline that die exits only the subshell, leaving the command reporting
    # success with empty output. This is the interlock triage checks before
    # drafting, so an empty answer must never be mistaken for a real one.
    REC=$(read_record "$1") || die "could not read friction records"
    printf '%s' "$REC" | jq -r '.outcomes[]'
    ;;

  draft)
    SIG=${1:-}; require_sig "$SIG"; shift
    OUTCOME=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --outcome) shift; OUTCOME=${1:-} ;;
        --outcome=*) OUTCOME=${1#--outcome=} ;;
        *) usage >&2; exit 2 ;;
      esac
      shift
    done
    [ -n "$OUTCOME" ] || die "draft requires --outcome"
    REC=$(read_record "$SIG")
    # A settled signature is not re-drafted. Without this gate `draft` creates
    # the pending draft that `cancel` accepts, and the pair walks a cleared,
    # kept or dismissed record back to `surfaced` while it still carries its
    # outcome and filed issue. It keeps counting and stays visible to `show`
    # and `list`; what it does not do is re-enter triage.
    printf '%s' "$REC" | jq -e '.eligible' >/dev/null \
      || die "$SIG is already settled ($(printf '%s' "$REC" | jq -r '.state')); a settled signature keeps counting and never re-enters triage"
    printf '%s' "$REC" | jq -e '.above_threshold' >/dev/null \
      || die "$SIG is below the recurrence threshold ($FM_FRICTION_THRESHOLD distinct tasks); it is recorded, not surfaced"
    printf '%s' "$REC" | jq -e --arg o "$OUTCOME" '.outcomes | index($o)' >/dev/null \
      || die "$OUTCOME is not an available outcome for $SIG (available: $(printf '%s' "$REC" | jq -r '.outcomes | join(", ")'))"
    DRAFT=$(compose_draft "$REC" "$OUTCOME" "$(now_ts)")
    # The draft embeds one bullet per retained observation, and observations for
    # a task whose log is still live are deliberately never evicted, so this blob
    # is unbounded while the reporting tasks run. --slurpfile past a process
    # substitution keeps it off argv - only the /dev/fd path travels there - so
    # the most-reported signature, the one the ranking exists to surface, cannot
    # become the one signature that is impossible to triage.
    # shellcheck disable=SC2016 # $d is a jq variable bound by --slurpfile, not a shell one.
    update_record "$SIG" '.draft = $d[0]' --slurpfile d <(printf '%s' "$DRAFT")
    printf '%s\n' "$DRAFT"
    ;;

  approve)
    SIG=${1:-}; require_sig "$SIG"; shift
    ISSUE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --issue) shift; ISSUE=${1:-} ;;
        --issue=*) ISSUE=${1#--issue=} ;;
        *) usage >&2; exit 2 ;;
      esac
      shift
    done
    [ -n "$ISSUE" ] || die "approve requires --issue <url> of the filed issue"
    REC=$(read_record "$SIG")
    OUTCOME=$(printf '%s' "$REC" | jq -r '.draft.outcome // ""')
    [ -n "$OUTCOME" ] || die "$SIG has no drafted issue to approve; run draft first"
    # narrow is the clear-family outcome for a guard: the friction is reduced,
    # the guard stays. The exact outcome is retained on the record.
    case "$OUTCOME" in
      keep) NEWSTATE=kept ;;
      *)    NEWSTATE=cleared ;;
    esac
    # shellcheck disable=SC2016 # $s/$o/$u are jq variables bound by --arg, not shell ones.
    update_record "$SIG" '.state = $s | .outcome = $o | .issue_url = $u | .draft = null' \
      --arg s "$NEWSTATE" --arg o "$OUTCOME" --arg u "$ISSUE"
    printf '%s: %s (%s) -> %s\n' "$SIG" "$NEWSTATE" "$OUTCOME" "$ISSUE"
    ;;

  cancel)
    SIG=${1:-}; require_sig "$SIG"
    REC=$(read_record "$SIG")
    # Cancel rejects the wording of a PENDING draft, so a pending draft is a
    # precondition rather than an assumption. Without it, cancelling a signature
    # that has none would return a cleared, kept or dismissed record to
    # `surfaced` while it still carried its outcome and filed issue - and a
    # settled signature keeps counting but never re-surfaces.
    printf '%s' "$REC" | jq -e '.draft != null' >/dev/null \
      || die "$SIG has no pending draft to cancel; dismiss is the separate act for a signature that is not a real pattern"
    # Rejecting a draft rejects the wording, not the finding: dropping the draft
    # leaves the signature exactly where drafting found it, which for a drafted
    # signature is `surfaced`. Assigning the state here instead would be a way
    # to promote a record that was never eligible to hold a draft at all.
    update_record "$SIG" '.draft = null'
    printf '%s: draft cancelled, back to surfaced\n' "$SIG"
    ;;

  dismiss)
    SIG=${1:-}; require_sig "$SIG"
    REC=$(read_record "$SIG")
    printf '%s' "$REC" | jq -e '.security | not' >/dev/null \
      || die "$SIG names a containment guard; silent dismissal is not an outcome (available: $(printf '%s' "$REC" | jq -r '.outcomes | join(", ")'))"
    update_record "$SIG" '.draft = null | .state = "dismissed"'
    printf '%s: dismissed (not a real pattern); it keeps counting and never re-surfaces\n' "$SIG"
    ;;

  *)
    usage >&2
    exit 2
    ;;
esac
