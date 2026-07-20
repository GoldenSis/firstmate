#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh, covering the ordinary scout->ship flip
# and the model-fusion promotion guard from data/fusion-synthesis-v6/report.md
# ("Extend bin/fm-promote.sh narrowly").
#
# Ordinary promotion must stay exactly as it is. When a synthesis task carries
# the private data/<id>/fusion-synthesis marker, promotion must refuse unless
# `fm-fusion-gate.sh verify <id>` succeeds, and the emitted ship instructions
# must order the sealed gate red before production edits and green before the
# delivery path. All fixtures are hermetic: a meta file and marker under a temp
# FM_HOME, no live runtime.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-promote.sh"

# mk_home <id> <kind>: temp FM_HOME with a scout/ship meta for <id>. A fresh
# watcher beacon keeps the liveness guard silent so output assertions are clean.
mk_home() {
  local id=$1 kind=$2 home
  home=$(fm_test_tmproot fm-promote)
  mkdir -p "$home/data/$id" "$home/state"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/$id.meta" \
    "window=w:$id" "worktree=$home/wt-$id" "project=proj" \
    "harness=echo" "kind=$kind" "mode=$kind" "yolo=off"
  printf '%s\n' "$home"
}

meta_kind() { grep -E '^kind=' "$1" | tail -n1; }

# --- ordinary behavior (must stay green before and after fusion lands) -------
test_ordinary_scout_promotes_to_ship() {
  local home rc
  home=$(mk_home ord1 scout)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" ord1 >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "ordinary scout promotion must succeed"
  assert_grep "kind=ship" "$home/state/ord1.meta" "ordinary promotion did not flip kind to ship"
  assert_no_grep "kind=scout" "$home/state/ord1.meta" "ordinary promotion left a stale kind=scout line"
  pass "fm-promote.sh: ordinary scout promotion flips kind to ship"
}

test_non_scout_refused() {
  local home rc
  home=$(mk_home ord2 ship)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" ord2 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "promoting a task that is not kind=scout must be refused"
  pass "fm-promote.sh: a non-scout task is refused"
}

test_missing_meta_refused() {
  local home rc
  home=$(fm_test_tmproot fm-promote)
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" ghost >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "promoting a task with no meta must be refused"
  pass "fm-promote.sh: a task with no meta is refused"
}

# --- fusion guard: marker without a valid sealed red gate refuses ------------
test_marked_synthesis_refused_without_valid_seal() {
  local home rc
  home=$(mk_home synth1 scout)
  # The private fusion-synthesis marker with no sealed gate package present.
  : > "$home/data/synth1/fusion-synthesis"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" synth1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "a fusion-synthesis-marked task must not promote before a valid sealed red gate exists"
  # Refusal must not have flipped the kind: the task stays a scout.
  assert_grep "kind=scout" "$home/state/synth1.meta" \
    "refused fusion promotion still mutated the meta away from kind=scout"
  assert_no_grep "kind=ship" "$home/state/synth1.meta" \
    "refused fusion promotion still flipped kind to ship"
  pass "fm-promote.sh: a marked synthesis without a valid seal is refused and left a scout"
}

# --- fusion guard wiring and gate-first ship ordering (static) ---------------
test_promote_consults_fusion_gate_verify() {
  assert_grep "fusion-synthesis" "$PROMOTE" \
    "fm-promote.sh does not read the data/<id>/fusion-synthesis marker"
  assert_grep "fm-fusion-gate.sh verify" "$PROMOTE" \
    "fm-promote.sh does not gate a marked synthesis on fm-fusion-gate.sh verify"
  pass "fm-promote.sh: marked promotion is gated on fm-fusion-gate.sh verify"
}

test_promote_emits_gate_first_red_before_green_ordering() {
  local red_line green_line
  assert_grep "--expect red" "$PROMOTE" \
    "fm-promote.sh does not instruct the builder to run the sealed gate red before production edits"
  assert_grep "--expect green" "$PROMOTE" \
    "fm-promote.sh does not instruct the builder to run the sealed gate green before delivery"
  red_line=$(grep -n -- "--expect red" "$PROMOTE" | head -n1 | cut -d: -f1)
  green_line=$(grep -n -- "--expect green" "$PROMOTE" | head -n1 | cut -d: -f1)
  [ -n "$red_line" ] && [ -n "$green_line" ] && [ "$red_line" -lt "$green_line" ] \
    || fail "fm-promote.sh must order the sealed gate red (before edits) ahead of green (before delivery)"
  pass "fm-promote.sh: emitted ship instructions order red before green"
}

test_ordinary_scout_promotes_to_ship
test_non_scout_refused
test_missing_meta_refused
test_marked_synthesis_refused_without_valid_seal
test_promote_consults_fusion_gate_verify
test_promote_emits_gate_first_red_before_green_ordering
