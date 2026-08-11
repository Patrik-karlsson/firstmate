---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions or leaving a project's committed material contradicted by the findings.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for the completion gate an investigation or visual review must pass: its unresolved captain decisions, and the project material its findings contradict.
The name says decision-hold because holds came first; the gate is the shared thing, and a second gate would be a second thing to remember at exactly the moment things get forgotten.

## Policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a structured captain-held work item in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
The agent performs the semantic inventory because scripts must not infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key, register it through `bin/fm-decision-hold.sh hold`, and use the same key on retry so registration is idempotent while different decisions retain different durable identities.
After inventorying the whole report and review surface, run `bin/fm-decision-hold.sh complete` with every unresolved key, or with `--none` only when the reviewed surface contains no unresolved captain decision.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; main-home work creates main-home holds, and secondmate-owned work creates holds in that secondmate home's backlog rather than copying them into the main backlog.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and `bin/fm-decision-hold.sh resolve` routes the answer by clearing those dependency edges before closing the hold.
Whenever a captain-facing decision surface records an answer, the same edit that records it must remove or collapse that decision's option presentation, meaning its options table, choice list, or input control.
A live option presentation left beside a recorded answer reads as a fresh question and invites a contradictory second answer, so the surface that recorded the answer must never keep presenting that decision as an unanswered choice.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.

A second inventory class shares this completion gate: the findings that contradict a project's committed material, or answer an open question it poses.
A private report is unreachable from any clone, so an uncorrected contradiction leaves the project asserting the opposite of what the investigation established, and every later repo-only check re-derives the wrong answer.
This class never creates a hold, because it is engineering follow-up rather than a captain's choice; a plain `tasks-axi add` ship task blocked by the originating work is the whole mechanism.
No script attests this inventory, unlike the hold inventory that `bin/fm-decision-hold.sh complete` enforces, so the agent's own pass over the report is the only thing standing between a contradiction and a repo that stays wrong.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and use the script's `hold` command with a concise title, reason, and repository.
4. Run the script's `complete` command with the full unresolved-key inventory for that review pass.
5. Read the report's `Repo contradictions` section, verify it against the findings rather than trusting it, and treat an absent section as an unperformed inventory that blocks completion.
6. Settle every entry in that section before the investigation may be treated as complete: either it is corrected in a change delivered through that project's selected delivery path, or it is filed as a follow-up ship task with `tasks-axi add` and a `blocked-by` edge to the originating work.
7. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
8. After the captain decides, record dependent work with normal tasks-axi commands and block it by the hold identity.
9. Put the captain's exact durable decision in a file and use the script's `resolve` command with every routed task.
10. Confirm Bearings no longer shows the closed hold and that routed work remains in structured backlog state.

`bin/fm-decision-hold.sh --help` owns command syntax, identity construction, completion attestation, retry behavior, and close ordering.
`docs/decision-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
