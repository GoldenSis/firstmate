#!/usr/bin/env bash
# fm-herdr-lib.sh — herdr-backed reimplementation of firstmate's supervision
# primitives, drawing agent state from herdr's socket API (native, push-based)
# instead of scraping tmux panes. Drop-in analogue of the three responsibilities
# in bin/fm-tmux-lib.sh:
#
#   fm-tmux-lib.sh (scrape)                 fm-herdr-lib.sh (native)
#   ------------------------------------    ----------------------------------
#   fm_pane_is_busy  (grep busy footer)  -> agent_status == working
#   fm_tmux_composer_state (ANSI/border   -> agent_status: idle|blocked = ready,
#     strip heuristic; pending vs empty)      working = mid-turn; no scraping
#   fm_tmux_submit_core (send-keys -l +   -> agent send + Enter, CONFIRMED by the
#     verify composer cleared + retry)        native idle->working transition
#
# The key shift: firstmate scrapes because tmux gives it no ground truth (an Enter
# can be silently swallowed; ghost/placeholder text looks like real input; a
# bordered-empty composer looks pending). Herdr's claude integration watches the
# session transcript and PUSHES state (idle|working|blocked) over the socket, so
# state detection stops being a heuristic entirely. Submit is still a keystroke op
# (see the big caveat below), but it is now CONFIRMED by a real state transition
# rather than by re-scraping the composer.
#
# ---------------------------------------------------------------------------
# VALIDATED AGAINST A REAL claude (herdr 0.7.3, claude-code 2.1.206), task
# herdr-state-h7. Findings that shaped this file:
#
#   * State truth is solid. idle -> working -> blocked -> working -> idle all
#     fired natively from the transcript, sub-second to ~1.4s latency, and NO
#     spurious `unknown` was ever observed mid-turn. `blocked` fires on an
#     in-turn tool-approval prompt — this is firstmate's needs-decision signal.
#
#   * SUBMIT IS THE SHARP EDGE. `herdr pane run` claims to send "text + Enter"
#     atomically, but against claude's TUI the bundled Enter is SWALLOWED: the
#     prompt lands in the composer unsent. This is the exact swallowed-Enter
#     class the prototype claimed herdr eliminated — it does NOT. The reliable
#     path is: `herdr agent send` (literal text, no Enter) THEN a separate
#     `herdr pane send-keys <pane> Enter`, and — crucially — CONFIRM the submit
#     by waiting for idle->working, retrying the Enter if no transition appears.
#     Herdr's win is not a magic submit; it is that the *confirmation* is now
#     native ground truth instead of a composer re-scrape.
#
#   * `unknown` is a startup/attach window only. A freshly `agent start`ed pane
#     reads `unknown` for a few seconds until the SessionStart hook registers
#     the transcript, and a pane herdr has never tracked reads `unknown`
#     forever. Treat `unknown` as not-ready (fail-safe) and optionally fall back
#     to tmux via FM_HERDR_UNKNOWN_FALLBACK (see fm_herdr_agent_status).
#
#   * claude reports turn-end as `idle`, never `done`. `done` exists in the API
#     (other integrations may use it) so we accept it everywhere as a synonym
#     for idle, but never WAIT on `done` alone for a claude pane — it would
#     hang. fm_herdr_wait_done waits on `idle`.
#
#   * The initial trust dialog ("Is this a project you trust?") reads as `idle`,
#     NOT `blocked` — it is pre-session, before any transcript exists. Spawn-time
#     trust handling still belongs to the harness adapter / a pane read; herdr's
#     `blocked` covers in-turn approvals only.
# ---------------------------------------------------------------------------
#
# A "target" is any herdr target: pane id (w1:p1), terminal id, unique agent
# name, or reported agent label. JSON is flat/single-line, so grep-extract keeps
# this bash-3.2 clean with no python/jq dependency (mirrors fm-tmux-lib.sh).

HERDR="${HERDR_BIN:-herdr}"

# fm_herdr_agent_status: print herdr's native status for <target>:
#   idle | working | blocked | done | unknown   (unknown if unreadable/untracked).
# If the read yields `unknown` and FM_HERDR_UNKNOWN_FALLBACK is set to a command,
# that command is run as `<cmd> <target>` and its stdout used instead — the seam
# where a caller can degrade to a tmux busy-scrape during the startup/attach
# window rather than mis-treating a live-but-not-yet-attached pane as not-ready.
fm_herdr_agent_status() {  # <target>
  local json status=
  json=$("$HERDR" agent get "$1" 2>/dev/null) || status=unknown
  if [ -z "$status" ]; then
    status=$(printf '%s' "$json" | grep -oE '"agent_status":"[a-z]+"' | head -1 | cut -d'"' -f4)
    [ -n "$status" ] || status=unknown
  fi
  if [ "$status" = unknown ] && [ -n "${FM_HERDR_UNKNOWN_FALLBACK:-}" ]; then
    local fb
    fb=$($FM_HERDR_UNKNOWN_FALLBACK "$1" 2>/dev/null) && [ -n "$fb" ] && status=$fb
  fi
  printf '%s' "$status"
}

# fm_herdr_pane_is_busy: 0 (busy) iff the agent is mid-turn. Direct read of native
# state — no 40-line tail scan, no per-harness busy-footer regex.
fm_herdr_pane_is_busy() {  # <target>
  [ "$(fm_herdr_agent_status "$1")" = working ]
}

# fm_herdr_needs_human: 0 iff the agent is parked on an in-turn approval prompt
# (herdr `blocked`). This is the native needs-decision signal — the thing firstmate
# currently has to infer from a pane read. Distinct from idle: an idle agent
# finished its turn; a blocked agent is actively waiting on a human answer.
fm_herdr_needs_human() {  # <target>
  [ "$(fm_herdr_agent_status "$1")" = blocked ]
}

# fm_herdr_ready_for_input: 0 iff it is safe to inject — the agent is idle, done,
# or actively blocked waiting on the human. `working` is the only not-ready state;
# `unknown` is treated not-ready (fail-safe: never inject into a pane we cannot
# read — unless FM_HERDR_UNKNOWN_FALLBACK resolved it to a real state above).
fm_herdr_ready_for_input() {  # <target>
  case "$(fm_herdr_agent_status "$1")" in
    idle|done|blocked) return 0 ;;
    *)                 return 1 ;;
  esac
}

# fm_herdr_submit: deliver <text> to <target> and submit it, then CONFIRM the
# agent actually picked it up via the native idle->working transition.
#
# WHY THIS IS NOT JUST `pane run`: against claude's TUI the Enter bundled into
# `pane run` is swallowed (validated — the text lands unsent). So we type the
# literal text with `agent send`, press Enter separately with `pane send-keys`,
# and if no working transition appears within the window we RE-PRESS Enter up to
# FM_HERDR_SUBMIT_RETRIES times. The confirmation is native truth, which is
# exactly what the tmux lib had to fake by re-reading the composer.
#
# Echoes the verdict:
#   submitted     : agent transitioned to working within the window (landed).
#   no-transition : text was sent and Enter pressed the allotted times but no
#                   working transition was seen (caller decides; analogue of the
#                   tmux lib's ambiguous "pending" outcome).
#   send-failed   : the `agent send` call itself failed (pane gone / server down).
#
# Callers should ensure the target is ready first (fm_herdr_ready_for_input) so
# the working-transition confirm is meaningful.
fm_herdr_submit() {  # <target> <text> [confirm-timeout-ms]
  local target=$1 text=$2 timeout=${3:-6000}
  local retries=${FM_HERDR_SUBMIT_RETRIES:-2} i
  "$HERDR" agent send "$target" "$text" >/dev/null 2>&1 || { printf 'send-failed'; return 0; }
  i=0
  while :; do
    "$HERDR" pane send-keys "$target" Enter >/dev/null 2>&1
    if "$HERDR" wait agent-status "$target" --status working --timeout "$timeout" >/dev/null 2>&1; then
      printf 'submitted'; return 0
    fi
    i=$((i + 1))
    [ "$i" -le "$retries" ] || break
  done
  printf 'no-transition'
}

# fm_herdr_wait_done: BLOCK until <target> goes idle (or timeout). This single call
# is the event-driven replacement for fm-watch.sh's whole poll loop plus its
# .seen-*/.stale-* suppression markers — herdr wakes us on the transition instead
# of us scraping the pane on a timer. We wait on `idle` (claude's turn-end state);
# do NOT wait on `done` for claude, it never emits it. Prints: done | timeout.
fm_herdr_wait_done() {  # <target> [timeout-ms]
  local target=$1 timeout=${2:-600000}
  if "$HERDR" wait agent-status "$target" --status idle --timeout "$timeout" >/dev/null 2>&1; then
    printf 'done'
  else
    printf 'timeout'
  fi
}
