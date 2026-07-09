#!/usr/bin/env bash
# fm-autonudge.sh — deterministic, bounded auto-steer for a wedged crewmate.
#
# The cheap first rung BELOW the LLM `stuck-crewmate-recovery` ladder. When
# fm-watch.sh reports `stale: <window>` (a pane that stopped changing and shows
# no busy signature), most wedges are just a harness that needs one poke — the
# same "send a steering prompt, then keep sleeping" move a human supervisor
# makes. Doing that in the firstmate LLM costs a full turn per stale wake. This
# helper does it deterministically for a bounded number of pokes per wedge, and
# only escalates to the LLM ladder once the cheap pokes are spent.
#
# Safety contract (why this is safe to run without LLM judgment):
#   1. It NEVER nudges a busy or pending-input pane. It reuses the same busy /
#      composer detectors as fm-send.sh and the away-mode daemon
#      (bin/fm-tmux-lib.sh), so a working crewmate is left alone. It ALSO never
#      types into a harness confirm/permission/trust dialog: such a pane awaits a
#      human choice with no busy footer and no composer text, so the busy/pending
#      checks miss it. The pane tail is matched against FM_AUTONUDGE_DIALOG_RE (a
#      broad, configurable regex) and any match defers to the LLM ladder instead
#      of nudging. Over-suppressing is acceptable; answering a dialog is not.
#   2. The nudge is a single generic, goal-anchored line — it never invents task
#      detail, never restates a plan, and asks for a one-line blocker if stuck.
#   3. Pokes are budgeted per window (FM_AUTONUDGE_MAX, default 2) with a
#      cooldown (FM_AUTONUDGE_COOLDOWN, default 120s). Once the budget is spent
#      it stops and tells the caller to escalate — it can never machine-gun a
#      pane or loop forever.
#   4. The ledger resets on real progress two ways: the caller runs
#      `--reset <window>` when the crewmate's stale marker clears (it advanced),
#      AND the ledger self-expires after FM_AUTONUDGE_TTL (default 900s) so a
#      much-later, unrelated quiet spell always starts from a fresh budget even
#      if no explicit reset reached it. The explicit reset is the precise path;
#      the TTL is the backstop that guarantees the budget can never wedge shut.
#
# Usage:
#   fm-autonudge.sh <window>            try one bounded auto-nudge
#   fm-autonudge.sh --reset <window>    clear the poke ledger (call on progress)
#   <window> may be a bare firstmate window name (fm-xyz), resolved through this
#   home's state/<id>.meta, or an explicit session:window.
#
# Exit codes (so a caller — daemon or firstmate — can branch deterministically):
#   0   nudged: a steering line was submitted; keep supervising, do not escalate
#   3   not idle: pane is busy or holds pending input; nothing to do
#   10  exhausted: poke budget spent for this wedge; ESCALATE to
#       stuck-crewmate-recovery (interrupt / relaunch)
#   1   error (bad usage, unresolved window, failed submit)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"

MAX=${FM_AUTONUDGE_MAX:-2}
COOLDOWN=${FM_AUTONUDGE_COOLDOWN:-120}
TTL=${FM_AUTONUDGE_TTL:-900}
# One generic, goal-anchored line. Deliberately task-agnostic: it must be safe
# to send to any wedged crewmate without knowing its brief.
NUDGE_TEXT=${FM_AUTONUDGE_TEXT:-"Supervisor status check: if your last step finished, continue toward the goal in your brief. If you are blocked or waiting on input, reply with the single blocker on one line. Do not restate the plan."}
# Broad, over-inclusive regex for a pane awaiting a human choice (harness
# confirm / permission / trust dialog). A match defers to the LLM recovery
# ladder rather than typing the steer line into the dialog.
DIALOG_RE=${FM_AUTONUDGE_DIALOG_RE:-'Do you want to (proceed|trust|allow|continue)|Yes, (and|proceed)|❯ *[0-9]+\.|\[y/n\]|\(y/n\)|Allow this|permission to (run|use|edit)|trust the (files|authors|folder|workspace)|awaiting (your )?(approval|confirmation)'}

usage() { echo "usage: fm-autonudge.sh <window> | --reset <window>" >&2; exit 1; }

# Same window resolver used by fm-peek.sh / fm-send.sh.
resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    fm-*)
      meta="$STATE/${1#fm-}.meta"
      [ -f "$meta" ] || { echo "error: no metadata for $1 in $STATE" >&2; exit 1; }
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; exit 1; }
      echo "$window" ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

# Per-window ledger path — slug the window arg into a safe filename.
ledger_path() {
  slug=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  echo "$STATE/.autonudge-$slug"
}

case "${1:-}" in
  ""|-h|--help) usage ;;
  --reset)
    [ $# -ge 2 ] || usage
    rm -f "$(ledger_path "$2")" 2>/dev/null || true
    exit 0 ;;
esac

WINDOW="$1"
LEDGER="$(ledger_path "$WINDOW")"
TARGET="$(resolve "$WINDOW")"

"$SCRIPT_DIR/fm-guard.sh" || true

# Never touch a pane that is working or already holds typed-but-unsent input.
if fm_pane_is_busy "$TARGET"; then
  echo "not-idle: $WINDOW is busy" >&2
  exit 3
fi
if fm_pane_input_pending "$TARGET"; then
  echo "not-idle: $WINDOW has pending composer input" >&2
  exit 3
fi
# A pane waiting on a human confirm/permission/trust dialog shows no busy footer
# and no composer text, so the checks above miss it. Match the tail against the
# broad dialog regex and defer to the LLM ladder rather than answering it.
if [ -n "$DIALOG_RE" ]; then
  pane_tail=$(tmux capture-pane -p -t "$TARGET" -S -20 2>/dev/null || true)
  if [ -n "$pane_tail" ] && printf '%s\n' "$pane_tail" | grep -qiE "$DIALOG_RE"; then
    echo "not-idle: $WINDOW shows a confirm/permission dialog" >&2
    exit 3
  fi
fi

# Read ledger: "<count> <last_epoch>".
count=0; last=0
if [ -f "$LEDGER" ]; then
  read -r count last _ < "$LEDGER" 2>/dev/null || true
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last"  in ''|*[!0-9]*) last=0  ;; esac
fi

now=$(date +%s)
# TTL backstop: a ledger older than TTL is a stale wedge that already resolved
# (an explicit --reset never reached it), so start its budget fresh.
if [ "$last" -gt 0 ] && [ "$TTL" -gt 0 ] && [ $((now - last)) -ge "$TTL" ]; then
  count=0; last=0
fi
if [ "$count" -ge "$MAX" ]; then
  echo "exhausted: $WINDOW nudged $count/$MAX times; escalate to stuck-crewmate-recovery" >&2
  exit 10
fi
if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$COOLDOWN" ]; then
  echo "cooldown: $WINDOW last nudged $((now - last))s ago (<${COOLDOWN}s); waiting" >&2
  exit 3
fi

# Send the steer through the verified primitive (retries + submit confirmation).
if "$SCRIPT_DIR/fm-send.sh" "$WINDOW" "$NUDGE_TEXT"; then
  printf '%s %s\n' "$((count + 1))" "$now" > "$LEDGER"
  echo "nudged: $WINDOW ($((count + 1))/$MAX)"
  exit 0
else
  echo "error: steer did not land on $WINDOW" >&2
  exit 1
fi
