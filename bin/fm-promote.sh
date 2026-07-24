#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the project's delivery mode).
# A scout carrying data/<task-id>/fusion-synthesis is refused until
# fm-fusion-gate.sh verify confirms its validator-authored baseline-red seal.
# The emitted fusion instructions run that same sealed gate red before production
# edits and green before the selected delivery path begins.
# A scout carrying data/<task-id>/prototype.json is refused until
# fm-prototype.sh promotion-verify confirms completed evidence, the validated
# decision, its regression-test obligation, and a residue-free detached worktree
# at the exact pre-experiment baseline. The emitted ship instructions implement
# that decision afresh and continue through the existing delivery path.
# --expect red is the required pre-edit observation.
# --expect green is the required pre-delivery observation.
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
WT=$(sed -n 's/^worktree=//p' "$META" | tail -n 1)

FUSION_SYNTHESIS=0
if [ -f "$DATA/$ID/fusion-synthesis" ]; then
  FUSION_SYNTHESIS=1
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-fusion-gate.sh" verify "$ID" >/dev/null; then
    echo "error: fusion synthesis $ID has no valid sealed baseline-red gate; promotion refused" >&2
    exit 1
  fi
fi

PROTOTYPE=0
if [ -e "$DATA/$ID/prototype.json" ] || [ -L "$DATA/$ID/prototype.json" ]; then
  PROTOTYPE=1
  if [ "$FUSION_SYNTHESIS" -eq 1 ]; then
    echo "error: task $ID cannot be both a fusion synthesis and a question-first prototype" >&2
    exit 1
  fi
  if ! FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-prototype.sh" promotion-verify "$ID" "$WT" >/dev/null; then
    echo "error: prototype $ID has no valid clean promotion preparation; promotion refused" >&2
    exit 1
  fi
fi

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
PROTOTYPE_Q=$(printf '%q' "$FM_ROOT/bin/fm-prototype.sh")
echo "promoted $ID to ship (teardown protection restored)"
if [ "$FUSION_SYNTHESIS" -eq 1 ]; then
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state; reset to the sealed base; create branch fm/$ID; run FM_HOME=$HOME_Q bin/fm-fusion-gate.sh run $ID \"\$PWD\" --expect red before production edits; implement without editing gate-managed tests; run FM_HOME=$HOME_Q bin/fm-fusion-gate.sh run $ID \"\$PWD\" --expect green; commit; follow the selected delivery path>'"
elif [ "$PROTOTYPE" -eq 1 ]; then
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: the prototype worktree is clean at its registered baseline; create branch fm/$ID; read the validated decision with FM_HOME=$HOME_Q $PROTOTYPE_Q decision $ID and implement it afresh; read FM_HOME=$HOME_Q $PROTOTYPE_Q regression-obligation $ID and add the required regression test when it says required; do not restore scratch code, fixtures, credentials, debug artifacts, or ignored experiment state; commit; follow the selected delivery path with its normal tests and review>'"
else
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
fi
