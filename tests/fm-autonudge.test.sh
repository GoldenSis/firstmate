#!/usr/bin/env bash
# tests/fm-autonudge.test.sh - the deterministic bounded auto-nudge helper.
#
# fm-autonudge.sh is the cheap first rung below stuck-crewmate-recovery: on a
# stale wake the daemon pokes a quiet crewmate once or twice with a canned
# steering line, deterministically, before any firstmate turn is spent. These
# tests pin that contract hermetically - the real script is exercised against
# stubbed busy/pending detectors (fm-tmux-lib.sh), a stubbed fm-send.sh that
# logs every steer, and a stub fm-guard.sh, so no tmux and no live pane are
# needed:
#   1. An idle pane is nudged (exit 0) and exactly one steering line is sent.
#   2. The poke budget is bounded: after FM_AUTONUDGE_MAX pokes the next call
#      exits 10 (escalate) and sends nothing more.
#   3. --reset clears the ledger so the budget starts fresh.
#   4. A busy or pending-input pane is never nudged (exit 3, no send).
#   5. A failed steer surfaces as exit 1.
#   6. The cooldown blocks a too-soon second poke (exit 3).
#   7. The TTL backstop forgives an old ledger even without an explicit reset.
#   8. A pane showing a confirm/permission dialog is never nudged (exit 3).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUDGE_SRC="$ROOT/bin/fm-autonudge.sh"
TMP_ROOT=$(fm_test_tmproot fm-autonudge-tests)

# Build a hermetic sandbox: a bin dir holding a copy of the real script next to
# stubbed fm-tmux-lib.sh / fm-send.sh / fm-guard.sh, plus an isolated state dir.
# Echoes the sandbox bin dir; the state dir is "<sandbox>/../state".
make_sandbox() {
  local dir=$1 bin
  bin="$dir/bin"
  mkdir -p "$bin" "$dir/state"
  # Busy/pending controlled by STUB_BUSY / STUB_PENDING at call time.
  cat > "$bin/fm-tmux-lib.sh" <<'LIB'
fm_pane_is_busy()       { [ "${STUB_BUSY:-0}" = 1 ]; }
fm_pane_input_pending() { [ "${STUB_PENDING:-0}" = 1 ]; }
LIB
  # fm-send stub: log the steer, fail iff STUB_SEND_FAIL=1.
  cat > "$bin/fm-send.sh" <<SEND
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$dir/sent.log"
[ "\${STUB_SEND_FAIL:-0}" = 1 ] && exit 1 || exit 0
SEND
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/fm-guard.sh"
  # tmux stub: only 'capture-pane' matters here (resolve() takes the sess:win
  # branch and never calls tmux). It echoes the controllable STUB_PANE var so a
  # test can drive the dialog guard; empty (the default) means no dialog.
  cat > "$bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  capture-pane) printf '%s\n' "${STUB_PANE:-}" ;;
  *) exit 0 ;;
esac
TMUX
  cp "$NUDGE_SRC" "$bin/fm-autonudge.sh"
  chmod +x "$bin"/*.sh "$bin/tmux"
  printf '%s\n' "$bin"
}

# run_nudge <sandbox-dir> <extra-env...> -- <args...>: invoke the copied script
# with the sandbox state dir, capturing nothing (caller reads $? and files).
run_nudge() {
  local dir=$1; shift
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  env PATH="$dir/bin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_AUTONUDGE_COOLDOWN=0 \
    "${env[@]+"${env[@]}"}" "$dir/bin/fm-autonudge.sh" "$@"
}

sent_count() { [ -f "$1/sent.log" ] && wc -l < "$1/sent.log" | tr -d ' ' || echo 0; }


test_idle_pane_is_nudged_once() {
  local dir; dir="$TMP_ROOT/idle"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" -- "sess:win"; expect_code 0 $? "idle pane should be nudged"
  [ "$(sent_count "$dir")" = 1 ] || fail "expected exactly one steer sent, got $(sent_count "$dir")"
  assert_grep "sess:win" "$dir/sent.log" "steer should target the window"
  pass "fm-autonudge: an idle pane is nudged once (exit 0, one steer)"
}

test_budget_is_bounded() {
  local dir; dir="$TMP_ROOT/budget"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" FM_AUTONUDGE_MAX=2 -- "sess:win"; expect_code 0 $? "poke 1/2"
  run_nudge "$dir" FM_AUTONUDGE_MAX=2 -- "sess:win"; expect_code 0 $? "poke 2/2"
  run_nudge "$dir" FM_AUTONUDGE_MAX=2 -- "sess:win"; expect_code 10 $? "budget spent must exit 10"
  [ "$(sent_count "$dir")" = 2 ] || fail "budget spent must send nothing extra, got $(sent_count "$dir") steers"
  pass "fm-autonudge: the poke budget is bounded, then it escalates (exit 10)"
}

test_reset_clears_budget() {
  local dir; dir="$TMP_ROOT/reset"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" FM_AUTONUDGE_MAX=1 -- "sess:win"; expect_code 0 $? "poke 1/1"
  run_nudge "$dir" FM_AUTONUDGE_MAX=1 -- "sess:win"; expect_code 10 $? "budget spent"
  run_nudge "$dir" -- --reset "sess:win"; expect_code 0 $? "--reset should succeed"
  run_nudge "$dir" FM_AUTONUDGE_MAX=1 -- "sess:win"; expect_code 0 $? "after reset, poke again"
  pass "fm-autonudge: --reset clears the ledger so the budget starts fresh"
}

test_busy_and_pending_are_never_nudged() {
  local dir; dir="$TMP_ROOT/busy"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" STUB_BUSY=1 -- "sess:win"; expect_code 3 $? "busy pane must not be nudged"
  run_nudge "$dir" STUB_PENDING=1 -- "sess:win"; expect_code 3 $? "pending pane must not be nudged"
  [ "$(sent_count "$dir")" = 0 ] || fail "a busy/pending pane must receive no steer, got $(sent_count "$dir")"
  pass "fm-autonudge: a busy or pending-input pane is never nudged (exit 3)"
}

test_failed_steer_is_reported() {
  local dir; dir="$TMP_ROOT/fail"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" STUB_SEND_FAIL=1 -- "sess:win"; expect_code 1 $? "a failed steer must exit 1"
  pass "fm-autonudge: a steer that does not land surfaces as exit 1"
}

test_cooldown_blocks_second_poke() {
  local dir; dir="$TMP_ROOT/cooldown"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" FM_AUTONUDGE_COOLDOWN=999 -- "sess:win"; expect_code 0 $? "first poke"
  run_nudge "$dir" FM_AUTONUDGE_COOLDOWN=999 -- "sess:win"; expect_code 3 $? "cooldown must block the second"
  [ "$(sent_count "$dir")" = 1 ] || fail "cooldown must suppress the second steer, got $(sent_count "$dir")"
  pass "fm-autonudge: the cooldown blocks a too-soon second poke (exit 3)"
}

test_ttl_backstop_forgives_old_ledger() {
  local dir ledger; dir="$TMP_ROOT/ttl"; make_sandbox "$dir" >/dev/null
  ledger="$dir/state/.autonudge-sess_win"
  # Simulate a spent budget last touched long ago (older than a 10s TTL).
  printf '9 100\n' > "$ledger"
  run_nudge "$dir" FM_AUTONUDGE_MAX=2 FM_AUTONUDGE_TTL=10 -- "sess:win"
  expect_code 0 $? "an expired ledger must be forgiven and nudged"
  pass "fm-autonudge: the TTL backstop forgives an old ledger without an explicit reset"
}

test_confirm_dialog_is_never_nudged() {
  local dir; dir="$TMP_ROOT/dialog"; make_sandbox "$dir" >/dev/null
  run_nudge "$dir" STUB_PANE="Do you want to proceed?
❯ 1. Yes
  2. No" -- "sess:win"
  expect_code 3 $? "a confirm dialog must not be nudged"
  [ "$(sent_count "$dir")" = 0 ] || fail "a confirm dialog must receive no steer, got $(sent_count "$dir")"
  pass "fm-autonudge: a confirm/permission dialog is never nudged (exit 3)"
}

test_idle_pane_is_nudged_once
test_confirm_dialog_is_never_nudged
test_budget_is_bounded
test_reset_clears_budget
test_busy_and_pending_are_never_nudged
test_failed_steer_is_reported
test_cooldown_blocks_second_poke
test_ttl_backstop_forgives_old_ledger
