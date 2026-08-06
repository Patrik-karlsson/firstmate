---
name: friction-triage
description: >-
  Agent-only procedure for triaging recurring friction signatures.
  Load before drafting, approving, cancelling, or dismissing a friction signature, and before relaying a friction section to the captain.
  Owns the drafted-issue contract, the security-guard carve-out, and the three mandatory counts.
user-invocable: false
metadata:
  internal: true
---

# friction-triage

Workers append `friction: [sig=<slug>] <observation>` when something impeded the work without blocking them.
`bin/fm-classify-lib.sh` owns the verb, `bin/fm-friction.sh` owns the durable record and every command below, and this skill owns what firstmate does with the result.

Read `bin/fm-friction.sh --help` for the record shape, states, count definitions, and guard list; this skill does not restate them.

## What this mechanism is for, and what it is not

It answers one question: which impediment recurred across independent work.
A signature seen in one task is usually one worker looping, so it is recorded and never surfaced.
A signature seen in two tasks is a system problem, so it surfaces for the captain's decision.

It is not a bug tracker, not a progress report, and not an escalation channel.
A friction line never parks a worker, never gates cleanup, and never needs an answer from anyone.
Nothing here files an issue: triage is the captain's, and both `clear` and `keep` produce a **drafted** issue presented for approval.

## Surfacing

Every rendering states all three counts, including when all three are zero: **surfaced**, **suppressed**, **unclassified**.
Never drop them because the section is quiet.
Without them a quiet section is indistinguishable from a blind one, which is the exact failure this mechanism exists to catch.

Under the `/bearings` four-section contract, friction reports patterns rather than actions, so it belongs in **Charted Next**.
It moves to **Captain's Call** only for a signature actually waiting on the captain's triage decision.
An `unclassified` record is a real finding, not noise: it means the fold could not attribute a worker's observation, so relay it rather than rounding it to zero.

Translate for the captain per `AGENTS.md` section 9.
Say what keeps getting in the way and how many separate pieces of work hit it, not signatures, folds, records, or counts as internal nouns.

## Deciding an outcome

Per surfaced signature the captain decides what happens to the **bottleneck**.

- **clear** - the friction should go. Draft an issue proposing the fix.
- **keep** - the friction is intentional. Draft an issue recording *why* it stays and what it costs.
  This is the important half: a `keep` with no artifact is a decision that gets re-litigated the next time a worker trips over it.
- **dismiss** - not a real pattern. No issue, no draft.

`keep` drafts carry the `known-friction` label and are closed on filing, so they stay searchable without adding to the open backlog.
That matters concretely on a repository already carrying a large open-issue count: permanent "this is intentional" entries in the open pile make a tracker less usable, not more.

## The security carve-out

A signature naming a containment guard is handled differently, and this is not optional.
`bin/fm-friction.sh` enforces it, so the commands will refuse rather than let a mistake through - do not work around a refusal.

- It surfaces **on its own**, never batched into a pattern list.
- Its only outcomes are **keep** or **narrow**. `clear` and `dismiss` are unavailable.
  A `narrow` draft may propose tightening a false positive and must never propose removing or disabling the guard.
- Its draft carries the observed false-positive count and an explicit note that frequency is not evidence a guard is wrong.

The reason is structural. This mechanism ranks by how often something impedes work.
That is the correct signal for a broken helper and the *wrong* signal for a guard: a guard that never fires falsely is a guard catching very little.
Without the carve-out, the mechanism's natural output is a prioritised list of security controls to remove.

If a guard signature is not classified as security and should be, extend the guard token list rather than triaging it as ordinary friction.
Over-classifying costs one triage option; under-classifying recommends deleting a security control.

## Running a triage

1. Read the current surface, then relay it to the captain in outcome language with the three counts.
2. For each signature the captain rules on, check the available outcomes first - a guard offers only two.
3. Draft the issue and show the captain the title, labels, and body.
4. On approval, file it with `gh-axi`, then record the returned URL against the signature.
   The record moves to `cleared` or `kept`.
   Where the entry belongs in a project's own memory, it goes through that project's normal delivery path; firstmate never writes to a project.
5. On cancellation, return the signature to `surfaced`.
   Rejecting a draft rejects the wording, not the finding, so the signature stays eligible to surface again.
   `dismiss` is the separate, explicit act and is never the fallback for a rejected draft.

A `kept` or `dismissed` signature keeps counting and never re-surfaces.
The count stays honest, so friction that was accepted once and later became severe is still visible on inspection.

## Payload safety

A record carries the rule or helper name and a path class, never the command line, the matched string, or file contents.
A secret-blocker denial is by definition about text that looked like a credential, so logging it would move the secret into a durable record.
The collector cannot leak one on its own - its only input is a worker's one-line status append - so the boundary is what workers are taught to write, and `bin/fm-brief.sh` teaches it.
If an observation nonetheless contains a payload, treat it as an incident: correct the record before drafting anything from it.
