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

FUSION_SYNTHESIS=0
if [ -f "$DATA/$ID/fusion-synthesis" ]; then
  FUSION_SYNTHESIS=1
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$FM_ROOT/bin/fm-fusion-gate.sh" verify "$ID" >/dev/null; then
    echo "error: fusion synthesis $ID has no valid sealed baseline-red gate; promotion refused" >&2
    exit 1
  fi
fi

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship (teardown protection restored)"
if [ "$FUSION_SYNTHESIS" -eq 1 ]; then
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state; reset to the sealed base; create branch fm/$ID; run FM_HOME=$HOME_Q bin/fm-fusion-gate.sh run $ID \"\$PWD\" --expect red before production edits; implement without editing gate-managed tests; run FM_HOME=$HOME_Q bin/fm-fusion-gate.sh run $ID \"\$PWD\" --expect green; commit; follow the selected delivery path>'"
else
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
fi
