#!/usr/bin/env bash
# tests/fm-state-source.test.sh - the FM_STATE_SOURCE=herdr detection seam in
# bin/fm-tmux-lib.sh.
#
# The seam lets the detection predicates draw native agent state from herdr
# (bin/fm-herdr-lib.sh) instead of scraping tmux, WITHOUT changing default
# behavior. These tests pin that contract hermetically, against a fake `herdr`
# (answers `agent get` with a controllable agent_status) and a fake `tmux`
# (controllable busy tail + composer line), so no live server or pane is needed:
#   1. Flag UNSET is byte-identical tmux behavior: herdr is never even invoked.
#   2. Flag=herdr: `working` -> busy; `idle`/`done` -> not busy; state drives it.
#   3. Flag=herdr: `blocked` is the native needs-decision signal (fm_pane_needs_human),
#      and needs_human is false whenever the source is off.
#   4. Flag=herdr readiness: `working`/`blocked` defer directly; `idle` defers to
#      the tmux composer check (herdr cannot see human-typed text).
#   5. Flag=herdr but herdr says `unknown` -> FM_HERDR_UNKNOWN_FALLBACK degrades
#      to the tmux busy-scrape.
#   6. Flag=herdr but the herdr binary is missing -> tmux path, unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-state-source-tests)

# Fake herdr: implements only `agent get <target>`, echoing agent_status from
# STUB_HERDR_STATE. Every invocation is logged to HERDR_CALL_LOG so a test can
# assert herdr was NOT consulted on the default path.
FB="$TMP_ROOT/fakebin"
mkdir -p "$FB"
cat > "$FB/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${HERDR_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
if [ "${1:-}" = agent ] && [ "${2:-}" = get ]; then
  printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${STUB_HERDR_STATE:-idle}"
  exit 0
fi
exit 1
SH
chmod +x "$FB/herdr"

# Fake tmux: `-40` in the args means the busy-tail scrape (controlled by
# STUB_TMUX_BUSY); otherwise it is the composer cursor line (STUB_COMPOSER).
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    is_tail=0
    for a in "$@"; do [ "$a" = "-40" ] && is_tail=1; done
    if [ "$is_tail" = 1 ]; then
      if [ "${STUB_TMUX_BUSY:-0}" = 1 ]; then printf 'work\nesc to interrupt\n'; else printf 'work\n> \n'; fi
    else
      printf '%s\n' "${STUB_COMPOSER:-> }"
    fi
    exit 0 ;;
esac
exit 1
SH
chmod +x "$FB/tmux"

HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
export HERDR_CALL_LOG

# run <predicate> : evaluate an fm-tmux-lib predicate against the fakebin and echo
# its exit code. PATH is shimmed so the real herdr/tmux never run.
run() {  # <fn> [args...]
  ( PATH="$FB:$PATH"; "$@" >/dev/null 2>&1; echo $? )
}

# --- 1. default OFF: byte-identical tmux, herdr never invoked ----------------
test_default_off_is_tmux_and_never_calls_herdr() {
  : > "$HERDR_CALL_LOG"
  unset FM_STATE_SOURCE
  # tmux says busy -> busy; not busy -> not busy. herdr must not be touched.
  local rc
  rc=$(STUB_TMUX_BUSY=1 run fm_pane_is_busy w1:p1); [ "$rc" = 0 ] || fail "default: busy tail should read busy (got $rc)"
  rc=$(STUB_TMUX_BUSY=0 run fm_pane_is_busy w1:p1); [ "$rc" = 1 ] || fail "default: idle tail should read not-busy (got $rc)"
  # composer drives readiness on the default path.
  rc=$(STUB_COMPOSER="> hello" run fm_pane_input_pending w1:p1); [ "$rc" = 0 ] || fail "default: typed composer should be pending (got $rc)"
  rc=$(STUB_COMPOSER="> "      run fm_pane_input_pending w1:p1); [ "$rc" = 1 ] || fail "default: empty composer should not be pending (got $rc)"
  # needs_human has no tmux equivalent: always false when the source is off.
  rc=$(run fm_pane_needs_human w1:p1); [ "$rc" = 1 ] || fail "default: needs_human must be false (got $rc)"
  [ ! -s "$HERDR_CALL_LOG" ] || fail "default path invoked herdr: $(cat "$HERDR_CALL_LOG")"
  pass "FM_STATE_SOURCE unset: tmux path unchanged and herdr never invoked"
}

# --- 2. flag ON: native busy from herdr state --------------------------------
test_flag_on_busy_follows_herdr() {
  export FM_STATE_SOURCE=herdr
  local rc
  rc=$(STUB_HERDR_STATE=working run fm_pane_is_busy w1:p1); [ "$rc" = 0 ] || fail "herdr working should be busy (got $rc)"
  rc=$(STUB_HERDR_STATE=idle    run fm_pane_is_busy w1:p1); [ "$rc" = 1 ] || fail "herdr idle should not be busy (got $rc)"
  rc=$(STUB_HERDR_STATE="done"  run fm_pane_is_busy w1:p1); [ "$rc" = 1 ] || fail "herdr done should not be busy (got $rc)"
  rc=$(STUB_HERDR_STATE=blocked run fm_pane_is_busy w1:p1); [ "$rc" = 1 ] || fail "herdr blocked should not be busy (got $rc)"
  unset FM_STATE_SOURCE
  pass "FM_STATE_SOURCE=herdr: fm_pane_is_busy tracks herdr's working state"
}

# --- 3. flag ON: blocked is the native needs-decision signal -----------------
test_flag_on_needs_human_is_blocked() {
  export FM_STATE_SOURCE=herdr
  local rc
  rc=$(STUB_HERDR_STATE=blocked run fm_pane_needs_human w1:p1); [ "$rc" = 0 ] || fail "herdr blocked should be needs_human (got $rc)"
  rc=$(STUB_HERDR_STATE=working run fm_pane_needs_human w1:p1); [ "$rc" = 1 ] || fail "herdr working is not needs_human (got $rc)"
  rc=$(STUB_HERDR_STATE=idle    run fm_pane_needs_human w1:p1); [ "$rc" = 1 ] || fail "herdr idle is not needs_human (got $rc)"
  unset FM_STATE_SOURCE
  pass "FM_STATE_SOURCE=herdr: fm_pane_needs_human fires only on blocked"
}

# --- 4. flag ON: readiness (working/blocked defer; idle -> tmux composer) -----
test_flag_on_readiness() {
  export FM_STATE_SOURCE=herdr
  local rc
  rc=$(STUB_HERDR_STATE=working run fm_pane_input_pending w1:p1); [ "$rc" = 0 ] || fail "herdr working should defer (pending) (got $rc)"
  rc=$(STUB_HERDR_STATE=blocked run fm_pane_input_pending w1:p1); [ "$rc" = 0 ] || fail "herdr blocked should defer (pending) (got $rc)"
  # idle: herdr can't see typed text, so the tmux composer decides.
  rc=$(STUB_HERDR_STATE=idle STUB_COMPOSER="> hello" run fm_pane_input_pending w1:p1); [ "$rc" = 0 ] || fail "herdr idle + typed composer should be pending (got $rc)"
  rc=$(STUB_HERDR_STATE=idle STUB_COMPOSER="> "      run fm_pane_input_pending w1:p1); [ "$rc" = 1 ] || fail "herdr idle + empty composer should not be pending (got $rc)"
  unset FM_STATE_SOURCE
  pass "FM_STATE_SOURCE=herdr: working/blocked defer, idle falls to tmux composer"
}

# --- 5. flag ON: unknown degrades to the tmux busy-scrape --------------------
test_flag_on_unknown_falls_back_to_tmux() {
  export FM_STATE_SOURCE=herdr
  local rc
  rc=$(STUB_HERDR_STATE=unknown STUB_TMUX_BUSY=1 run fm_pane_is_busy w1:p1); [ "$rc" = 0 ] || fail "unknown+busy tail should read busy (got $rc)"
  rc=$(STUB_HERDR_STATE=unknown STUB_TMUX_BUSY=0 run fm_pane_is_busy w1:p1); [ "$rc" = 1 ] || fail "unknown+idle tail should read not-busy (got $rc)"
  # unknown is not blocked, so needs_human stays false.
  rc=$(STUB_HERDR_STATE=unknown run fm_pane_needs_human w1:p1); [ "$rc" = 1 ] || fail "unknown should not be needs_human (got $rc)"
  unset FM_STATE_SOURCE
  pass "FM_STATE_SOURCE=herdr: unknown falls back to the tmux busy-scrape"
}

# --- 6. flag ON but no herdr binary: tmux path, unchanged --------------------
test_flag_on_missing_binary_uses_tmux() {
  export FM_STATE_SOURCE=herdr
  # PATH WITHOUT the fakebin's herdr: shim only tmux so `herdr` is absent.
  local shim="$TMP_ROOT/tmux-only" rc
  mkdir -p "$shim"; cp "$FB/tmux" "$shim/tmux"
  rc=$( PATH="$shim:/usr/bin:/bin"; STUB_TMUX_BUSY=1 fm_pane_is_busy w1:p1 >/dev/null 2>&1; echo $? )
  [ "$rc" = 0 ] || fail "missing herdr + busy tail should read busy via tmux (got $rc)"
  rc=$( PATH="$shim:/usr/bin:/bin"; STUB_TMUX_BUSY=0 fm_pane_is_busy w1:p1 >/dev/null 2>&1; echo $? )
  [ "$rc" = 1 ] || fail "missing herdr + idle tail should read not-busy via tmux (got $rc)"
  unset FM_STATE_SOURCE
  pass "FM_STATE_SOURCE=herdr with no herdr binary: tmux path, unchanged"
}

test_default_off_is_tmux_and_never_calls_herdr
test_flag_on_busy_follows_herdr
test_flag_on_needs_human_is_blocked
test_flag_on_readiness
test_flag_on_unknown_falls_back_to_tmux
test_flag_on_missing_binary_uses_tmux

echo "# fm-state-source: all assertions passed"
