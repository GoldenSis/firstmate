#!/usr/bin/env bash
# Static contract tests for crew-owned no-mistakes validation runs.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

delivery_contract() {
  awk '
    /^## 7\. Task lifecycle$/ { found = 1; next }
    found && /^## 8\. / { exit }
    found { print }
  ' "$ROOT/AGENTS.md"
}

test_worker_owns_synchronous_driver() {
  local contract
  contract=$(delivery_contract)

  assert_contains "$contract" 'The task worker owns every `no-mistakes axi run`/`respond` call' \
    "delivery contract does not assign the run to its task worker"
  assert_contains "$contract" 'a worker hand-editing, committing, aborting, or restarting during an active run duplicates pipeline ownership' \
    "Validate contract does not assign every synchronous driver call to the task worker"
  pass "delivery contract assigns the synchronous driver loop to the task worker"
}

test_firstmate_never_responds_for_crew_run() {
  local contract
  contract=$(delivery_contract)

  assert_contains "$contract" "firstmate never invokes \`no-mistakes axi respond\` for a crew-owned run." \
    "Validate contract permits Firstmate to respond directly for a crew-owned run"
  pass "Validate contract forbids Firstmate from responding directly for a crew-owned run"
}

# The model-fusion overlay (data/fusion-synthesis-v6/report.md) must not disturb
# no-mistakes ownership: the pre-builder fusion gate is a test replayer, the same
# ship worker still exclusively drives the post-commit pipeline, and no fusion
# role returns after the build to drive or answer no-mistakes. This guard is green
# on the untouched baseline (no fusion surface yet) and stays green after a correct
# implementation; it turns red only if fusion is wired into no-mistakes.
FUSION_GATE="$ROOT/bin/fm-fusion-gate.sh"

test_fusion_never_owns_or_drives_no_mistakes() {
  local contract
  contract=$(delivery_contract)
  assert_contains "$contract" 'The task worker owns every `no-mistakes axi run`/`respond` call' \
    "Validate contract no longer makes the initiating ship worker the sole pipeline driver"
  assert_grep 'worker runs the full pipeline (review, fixes, tests, docs, push, PR, CI)' \
    "$ROOT/AGENTS.md" \
    "delivery contract lost no-mistakes sole post-implementation ownership"
  if [ -f "$FUSION_GATE" ]; then
    assert_no_grep 'no-mistakes axi run' "$FUSION_GATE" \
      "fusion gate helper must never invoke no-mistakes axi run"
    assert_no_grep 'no-mistakes axi respond' "$FUSION_GATE" \
      "fusion gate helper must never invoke no-mistakes axi respond"
  fi
  pass "fusion never owns, drives, or responds to no-mistakes"
}

test_worker_owns_synchronous_driver
test_firstmate_never_responds_for_crew_run
test_fusion_never_owns_or_drives_no_mistakes
