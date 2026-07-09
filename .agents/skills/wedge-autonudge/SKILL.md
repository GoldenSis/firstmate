---
name: wedge-autonudge
description: Cheap first rung below stuck-crewmate-recovery. On a stale wake, try a bounded deterministic auto-nudge (bin/fm-autonudge.sh) BEFORE spending a firstmate turn on the LLM recovery ladder. Use when a crewmate pane went stale and you want to poke it without burning a turn.
user-invocable: false
---

# wedge-autonudge

Most `stale: <window>` wakes are not real wedges — the harness just needs one
poke. Running the full LLM `stuck-crewmate-recovery` playbook on every stale
wake spends a firstmate turn to send one line. This skill front-loads that poke
deterministically and only escalates to judgment when the cheap poke is spent.

This is the firstmate-native form of the classic supervisor loop: watch the
worker, and when it goes quiet, send a short steering line and keep waiting —
without waking the manager's brain for it.

## When

On a `stale: <window>` wake, before invoking `stuck-crewmate-recovery`.
Skip it and go straight to the ladder when the pane is not merely quiet but
visibly confused, looping, or asking a question (peek shows it) — auto-nudge is
for silence, not for wrong-direction.

## How

Run the helper on the stale window:

```
bin/fm-autonudge.sh <window>
```

Branch on the exit code — it is designed so a caller (you, or the away-mode
daemon) never needs to parse output:

- **0 — nudged.** A steering line was submitted. Keep supervising; do **not**
  escalate. Re-arm the watcher and let the crewmate act.
- **3 — not idle.** The pane is busy, holds pending input, or is inside the
  cooldown window. Nothing to do; keep supervising.
- **10 — exhausted.** The poke budget for this wedge is spent. Now escalate to
  `stuck-crewmate-recovery` (interrupt → relaunch → failed status). The cheap
  path is done; this is a real wedge.
- **1 — error.** Bad window or the steer would not land; fall back to the
  recovery ladder and peek the pane yourself.

## Reset on progress

The poke budget is per-wedge, not per-lifetime. Whenever the crewmate produces a
**signal** wake (it advanced — wrote a status line or ended a turn), clear its
ledger so a later, unrelated quiet spell starts fresh:

```
bin/fm-autonudge.sh --reset <window>
```

## Knobs

- `FM_AUTONUDGE_MAX` — pokes per wedge before escalating (default 2).
- `FM_AUTONUDGE_COOLDOWN` — seconds between pokes (default 120).
- `FM_AUTONUDGE_TEXT` — override the generic steering line. Keep it
  task-agnostic and one line: it is sent to any wedged crewmate without knowing
  its brief.
- `FM_AUTONUDGE_DIALOG_RE` — regex (matched case-insensitively against the pane
  tail) for a pane awaiting a human choice. A match suppresses the nudge and
  defers to the ladder. The default is deliberately broad; widen it if a harness
  shows a confirm prompt it does not yet catch.

## Safety

The helper never nudges a busy or pending-input pane (it reuses the same
detectors as `fm-send.sh` and the away-mode daemon), and it never types into a
harness confirm/permission/trust dialog: a pane awaiting a human choice usually
shows no busy footer and no composer text, so the busy/pending checks miss it,
but its tail is matched against a broad, configurable regex
(`FM_AUTONUDGE_DIALOG_RE`) and any match defers to the ladder instead of
answering the dialog. Over-suppressing is acceptable — it just falls back to the
existing stale-persistence escalation — while a false negative that answers a
dialog is not. The nudge is a single generic goal-anchored line that invents no
task detail, and pokes are strictly budgeted — it cannot machine-gun a pane or
loop. See the header of `bin/fm-autonudge.sh` for the full contract.
