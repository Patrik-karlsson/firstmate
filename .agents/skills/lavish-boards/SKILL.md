---
name: lavish-boards
description: >-
  Agent-only procedure for building, publishing, and maintaining the captain's Lavish review boards.
  Load before building or editing a Lavish board file, and before publishing one.
  Owns the batch-then-publish order, the two publish forms, feedback arming, the read-window rule, and the session, artifact, and tab distinctions that board failures come from.
user-invocable: false
metadata:
  internal: true
---

# lavish-boards

Load this before building or editing a Lavish board, and before publishing one.

A board is how the captain sees a whole piece of orchestration at once, so a board that silently regresses costs more than it was worth.
Everything below is proven behavior rather than taste.

How a card should READ is captain preference and lives in `data/captain.md`, which is local to each home and private.
That file owns card format; this skill restates none of it.

## The procedure

Work through these in order.

1. **Build or edit the board file completely first.**
   Batch every change into one round of edits.
   Publish once per round, never once per card.
2. **Publish once, choosing the form deliberately.**
   A board the captain has no tab for takes bare `lavish-axi <file>`, which is the only correct use of the bare form, and it opens their one tab.
   A board they already have open takes `lavish-axi <file> --no-open`, and then they must be told to reload.
3. **Arm feedback once per board.**

   ```sh
   bin/fm-procevent-lavish.sh arm <file>
   ```

   `arm` registers the source and starts the poll, and the runner owns capture and re-arming from there.
   Never run `lavish-axi poll` yourself in a conversational turn, because it blocks and it destructively clears the captain's feedback.
   [`process-event-sources`](../process-event-sources/SKILL.md) owns the wake handling, the handled acknowledgement, and the loss limitation.
4. **While the captain may be reading, do not publish.**
   If a card must change, say so in chat first and let them send or copy out.
5. **When the captain answers, record the answer and remove its control in the same edit.**
   [`decision-hold-lifecycle`](../decision-hold-lifecycle/SKILL.md) owns that rule.
6. **After the captain closes a board, a bare call deliberately refuses to reopen it.**
   `lavish-axi <file> --reopen` restores a fresh responsive tab, and it is for when the captain asks for further review or something important needs their visual attention, never for reopening uninvited.

## Why each step holds

**A session, an artifact, and a tab are three different things, and every board failure confuses them.**
A session is a record.
An artifact is published bytes.
A tab holds a revision token.
A session serves published bytes, so editing the file alone changes nothing for the captain, and a session can read `open` with nothing served.
Diagnose with bare `lavish-axi` first: `pending_prompts: 0` means the feedback never left their browser.

**Bare `lavish-axi <file>` opens a new tab every time.**
Three bare calls in one session left the captain with three stale tabs, and they reported the board as broken.

**Publishing while the captain reads invalidates their page token**, so the tab accepts annotations it cannot send, **and the reload that fixes that destroys whatever they already typed**.
Annotations live only in the page until Send succeeds, and nothing on this side can recover them.
The cost of a careless republish is the captain's written work, not a refresh.
When it has already happened, tell them to copy their text out before reloading, and never lead with "reload".

**A card counts as open only if it carries an `.ask` block.**
The board's own load-time script counts `.ask` and rewrites the heading number, so a decision card without one reads as zero waiting while a real decision sits there.
That happened, and the captain caught it first.

**Never name a web font the machine does not have.**
Lavish blocks the whole artifact behind "Checking layout, waiting for fonts and final geometry" with a Show anyway button, and the captain reports that as not rendering.
Check `fc-list | grep -ci <font>` before naming one.
Dead names ride along when a house `<style>` block is copied into a new board.

**An artifact must be a complete document** with exactly one `<body>` and a declared favicon.
It renders inside a frame, so open the file directly when inspecting your own diagram.
