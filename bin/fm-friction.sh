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
# sig, first_seen, last_seen, count, tasks[], projects[], observations[], state,
# plus security, outcome, issue_url, and draft. The unattributable aggregate
# lives at data/friction/@unclassified.json; `@` is not a legal signature
# character, so it can never collide with a real signature.
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
# hyphen-delimited segment run in its slug:
#   secret credential security merge-into-main branch-protection push-protection
# FM_FRICTION_GUARD_TOKENS EXTENDS that list (space-separated); it deliberately
# cannot shrink it, so a home cannot switch the carve-out off. Over-classifying
# costs one triage option; under-classifying makes the mechanism recommend
# removing a security control.
#
# Triage never files anything. `draft` composes an issue and stores it for the
# captain; `approve` records the URL of an issue that was filed separately
# through gh-axi; `cancel` returns the signature to `surfaced` - rejecting a
# draft rejects the wording, not the finding. `dismiss` is the separate,
# explicit act for a signature that is not a real pattern. A kept or dismissed
# signature keeps counting and never re-surfaces, so friction that was accepted
# once and later became severe is still visible on inspection.
#
# Environment:
#   FM_FRICTION_THRESHOLD      distinct tasks required to surface (default 2)
#   FM_FRICTION_RECORDS        max records in the rendered model (default 50);
#                              the COUNTS are always computed over every record
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

command -v jq >/dev/null 2>&1 || die "jq not found"

FM_FRICTION_THRESHOLD=${FM_FRICTION_THRESHOLD:-2}
case "$FM_FRICTION_THRESHOLD" in ''|*[!0-9]*|0) die "FM_FRICTION_THRESHOLD must be a positive integer" ;; esac
FM_FRICTION_RECORDS=${FM_FRICTION_RECORDS:-50}
case "$FM_FRICTION_RECORDS" in ''|*[!0-9]*|0) die "FM_FRICTION_RECORDS must be a positive integer" ;; esac

# The tracked containment-guard identities. Extended, never replaced, by
# FM_FRICTION_GUARD_TOKENS - see the carve-out note in the header.
FM_FRICTION_GUARDS_BUILTIN='secret credential security merge-into-main branch-protection push-protection'
GUARD_TOKENS="$FM_FRICTION_GUARDS_BUILTIN ${FM_FRICTION_GUARD_TOKENS:-}"

UNCLASSIFIED="$FM_CLASSIFY_FRICTION_UNCLASSIFIED"

now_ts() { printf '%s' "${FM_FRICTION_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

# Durable path for a signature. Rejects anything that is not a legal slug, so a
# signature can never escape data/friction/ - `.` and `..` pass the character
# class but are refused explicitly.
record_path() {  # <sig>
  local sig=$1
  if [ "$sig" = "$UNCLASSIFIED" ]; then
    printf '%s/@unclassified.json' "$FRICTION_DIR"
    return 0
  fi
  case "$sig" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/%s.json' "$FRICTION_DIR" "$sig"
}

# task -> project NAME, from the task metadata this home already records.
# Task metadata stores `project=` as the clone's absolute path; a friction
# record keeps only the final component. That is the noun the captain uses, and
# a record that outlives every task in it has no business carrying a local
# filesystem path around.
project_map_json() {
  local m task p
  {
    for m in "$STATE"/*.meta; do
      [ -e "$m" ] || continue
      task=$(basename "$m"); task=${task%.meta}
      p=$(grep '^project=' "$m" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      p=${p%/}
      p=${p##*/}
      jq -n --arg t "$task" --arg p "$p" '{key:$t,value:$p}'
    done
  } | jq -s 'from_entries'
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

stored_json() {
  local f
  {
    for f in "$FRICTION_DIR"/*.json; do
      [ -e "$f" ] || continue
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
merged_model() {  # <now>
  local now=$1
  jq -n \
    --arg now "$now" \
    --arg unclassified "$UNCLASSIFIED" \
    --arg guards "$GUARD_TOKENS" \
    --argjson threshold "$FM_FRICTION_THRESHOLD" \
    --argjson live "$(live_json "$now")" \
    --argjson stored "$(stored_json)" '
    def obskey: [.task, (.ordinal | tostring), .text] | join(" ");
    def guardmatch($sig; $tokens):
      ("-" + $sig + "-") as $h
      | any($tokens[]; ("-" + . + "-") as $t | ($h | contains($t)));

    ($guards | split(" ") | map(select(length > 0)) | unique) as $gt
    | ([$stored[].sig] + [$live[].sig] | unique) as $sigs
    | [ $sigs[] as $s
        | ([$stored[] | select(.sig == $s)] | first) as $rec
        | ((($rec.observations // []) + [$live[] | select(.sig == $s)])
           | group_by(obskey) | map(sort_by(.at) | .[0])
           | sort_by([.at, .task, .ordinal])) as $obs
        | ($obs | map(.task) | unique) as $tasks
        | ($obs | map(.project) | map(select(. != null and . != "")) | unique) as $projects
        | ($obs | map(.at) | sort) as $ats
        | (if $s == $unclassified then "unclassified" else ($rec.state // "new") end) as $state
        | guardmatch($s; $gt) as $security
        | {
            sig: $s,
            first_seen: ($ats | first),
            last_seen: ($ats | last),
            count: ($obs | length),
            tasks: $tasks,
            projects: $projects,
            observations: $obs,
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
cap_model() {  # <model-json>
  printf '%s' "$1" | jq --argjson cap "$FM_FRICTION_RECORDS" '
    .records_truncated = ([(.records | length) - $cap, 0] | max)
    | .records |= .[:$cap]'
}

# Strip the derived view fields before persisting: threshold-dependent verdicts
# must be recomputed on read, never frozen into the record.
DURABLE_FIELDS='{sig,first_seen,last_seen,count,tasks,projects,observations,state,security,outcome,issue_url,draft}'

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
  model=$(merged_model "$now")
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
  local sig=$1
  merged_model "$(now_ts)" | jq -e --arg s "$sig" '.records[] | select(.sig == $s)' \
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
  printf '%s' "$1" | jq -r --arg u "$UNCLASSIFIED" '
    "FRICTION (threshold: \(.threshold) distinct tasks)",
    "counts: surfaced=\(.counts.surfaced) suppressed=\(.counts.suppressed) unclassified=\(.counts.unclassified) settled=\(.counts.settled)",
    "",
    (([.records[] | select(.surfaced)]) as $s
     | if ($s | length) == 0 then "surfaced: none"
       else ("surfaced:",
             ($s[] | "  \(.sig)\(if .security then "  [security]" else "" end)  tasks=\(.tasks | length) count=\(.count)  outcomes: \(.outcomes | join(", "))",
                     "    last: \(.observations | last | .text)"))
       end),
    (([.records[] | select(.sig == $u)]) as $u2
     | if ($u2 | length) == 0 then empty
       else ("", "unclassified: \($u2[0].count) event(s) the fold could not attribute to a signature",
             ($u2[0].observations[] | "  \(.task): \(.text)"))
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
    MODEL=$(cap_model "$(merged_model "$(now_ts)")")
    if [ "$FORMAT" = json ]; then printf '%s\n' "$MODEL"; else render_text "$MODEL"; fi
    ;;

  show)
    require_sig "${1:-}"
    read_record "$1"
    ;;

  outcomes)
    require_sig "${1:-}"
    read_record "$1" | jq -r '.outcomes[]'
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
    ingest
    REC=$(read_record "$SIG")
    printf '%s' "$REC" | jq -e '.above_threshold' >/dev/null \
      || die "$SIG is below the recurrence threshold ($FM_FRICTION_THRESHOLD distinct tasks); it is recorded, not surfaced"
    printf '%s' "$REC" | jq -e --arg o "$OUTCOME" '.outcomes | index($o)' >/dev/null \
      || die "$OUTCOME is not an available outcome for $SIG (available: $(printf '%s' "$REC" | jq -r '.outcomes | join(", ")'))"
    DRAFT=$(compose_draft "$REC" "$OUTCOME" "$(now_ts)")
    # shellcheck disable=SC2016 # $d is a jq variable bound by --argjson, not a shell one.
    update_record "$SIG" '.draft = $d' --argjson d "$DRAFT"
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
    ingest
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
    # Rejecting a draft rejects the wording, not the finding: the signature goes
    # back to `surfaced` and stays eligible. `dismiss` is the separate act.
    update_record "$SIG" '.draft = null | .state = "surfaced"'
    printf '%s: draft cancelled, back to surfaced\n' "$SIG"
    ;;

  dismiss)
    SIG=${1:-}; require_sig "$SIG"
    ingest
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
