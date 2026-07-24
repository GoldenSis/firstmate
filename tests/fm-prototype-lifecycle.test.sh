#!/usr/bin/env bash
# Behavior tests for the question-first prototype lifecycle.
#
# The suite covers positive registration/evidence, invalid and incomplete
# inputs, idempotent retries, immutable sensitive-system defaults, central
# tool-neutral spawn binding, promotion residue hygiene, and the logic-state
# regression-test obligation carried into ship instructions.
# shellcheck disable=SC2016  # Fixed-string source assertions intentionally contain shell syntax.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROTOTYPE="$ROOT/bin/fm-prototype.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-prototype)

setup_case() {
  local id=$1 class=$2 question=$3 injected_hook=${4:-}
  CASE_HOME="$TMP_ROOT/$id-home"
  CASE_REPO="$TMP_ROOT/$id-repo"
  CASE_WT="$TMP_ROOT/$id-wt"
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/state"
  fm_git_worktree "$CASE_REPO" "$CASE_WT" "fixture-$id"
  git -C "$CASE_WT" checkout --detach -q
  if [ "$injected_hook" = with-hook ]; then
    mkdir -p "$CASE_WT/.claude"
    printf '{}\n' > "$CASE_WT/.claude/settings.local.json"
    printf '.claude/settings.local.json\n' >> "$(git -C "$CASE_WT" rev-parse --git-path info/exclude)"
  fi
  FM_HOME="$CASE_HOME" "$PROTOTYPE" register "$id" "$class" "$question" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" bind "$id" "$CASE_WT" >/dev/null
}

write_report() {
  local id=$1 question=$2 class=$3 obligation=$4
  cat > "$CASE_HOME/data/$id/report.md" <<EOF
# Prototype report

## Prototype evidence

### Question

$question

### Classification

$class

### Assumptions

- The fixture represents the relevant boundary.

### Alternatives

- Alternative A.
- Alternative B.

### Observed evidence

- The state driver preserved the invariant.

### Chosen decision

Choose alternative A because the observed transition remained deterministic.

### Rejected options

- Reject alternative B because retry behavior was ambiguous.

### Unresolved risks

- Production scale remains unmeasured.

### Expiry or disposal

Discard all experiment state at promotion or scout teardown.

### Regression-test obligation

$obligation
EOF
}

test_positive_evidence_and_decision() {
  local id=positive question='Does retry preserve the queued transition?' decision
  setup_case "$id" logic-state "$question"
  write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" verify "$id" >/dev/null
  decision=$(FM_HOME="$CASE_HOME" "$PROTOTYPE" decision "$id")
  assert_contains "$decision" "Choose alternative A" \
    "validated prototype decision was not recoverable from durable evidence"
  jq -e '
    .schema == "fm-prototype.v1"
    and .class == "logic-state"
    and .binding.baseline_head != null
    and (.binding.ignored_snapshot | type == "array")
    and .evidence.report_sha256 != null
  ' "$CASE_HOME/data/$id/prototype.json" >/dev/null \
    || fail "positive prototype manifest did not carry registration, binding, and evidence"
  pass "fm-prototype.sh: positive question-first evidence is durable and verifiable"
}

test_brief_requires_question_and_exact_class() {
  local home="$TMP_ROOT/brief-home" rc brief
  mkdir -p "$home/data"
  FM_HOME="$home" "$BRIEF" brief-proto alpha --scout --prototype ui \
    --question 'Which layout exposes retry state?' >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "registered prototype brief should scaffold"
  brief="$home/data/brief-proto/brief.md"
  assert_grep "# Question-first prototype" "$brief" \
    "prototype brief did not declare its distinct lifecycle"
  assert_grep "prototype-lifecycle/SKILL.md" "$brief" \
    "prototype brief did not load its precise policy owner"
  assert_present "$home/data/brief-proto/prototype.json" \
    "prototype brief did not register its durable manifest"

  FM_HOME="$home" "$BRIEF" no-question alpha --scout --prototype ui >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "prototype brief without a question must fail"
  assert_absent "$home/data/no-question/brief.md" \
    "failed questionless prototype still wrote a brief"

  FM_HOME="$home" "$BRIEF" wrong-kind alpha --prototype ui --question 'Question?' >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "prototype variant without --scout must fail"

  FM_HOME="$home" "$BRIEF" bad-class alpha --scout --prototype backend \
    --question 'Question?' >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "prototype class outside ui|logic-state must fail"

  FM_HOME="$home" "$BRIEF" mixed alpha --scout --prototype ui \
    --question 'Question?' --fusion-synthesis >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "prototype and fusion-synthesis variants must not combine"
  pass "fm-brief.sh: prototype intake requires one question and exactly one supported class"
}

test_incomplete_or_changed_evidence_fails() {
  local id=negative question='Which UI makes the state visible?' rc path_home
  setup_case "$id" ui "$question"
  write_report "$id" "$question" ui 'not-required: this UI experiment reproduced no logic failure'
  awk '
    $0 == "### Rejected options" { skip = 1; next }
    $0 == "### Unresolved risks" { skip = 0 }
    !skip { print }
  ' "$CASE_HOME/data/$id/report.md" > "$CASE_HOME/data/$id/report.md.tmp"
  mv "$CASE_HOME/data/$id/report.md.tmp" "$CASE_HOME/data/$id/report.md"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "prototype completion must reject a missing evidence section"

  write_report "$id" 'A different unregistered question' ui \
    'not-required: this UI experiment reproduced no logic failure'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "prototype completion must reject question drift"

  path_home="$TMP_ROOT/path-integrity-home"
  mkdir -p "$path_home/data/symlinked"
  FM_HOME="$path_home" "$PROTOTYPE" register .. ui 'Question?' >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "prototype registration accepted a parent-directory task id"
  assert_absent "$path_home/prototype.json" \
    "parent-directory task id escaped the prototype data directory"
  ln -s missing-target "$path_home/data/symlinked/prototype.json"
  FM_HOME="$path_home" "$PROTOTYPE" register symlinked ui 'Question?' >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "prototype registration replaced a broken manifest symlink"
  [ -L "$path_home/data/symlinked/prototype.json" ] \
    || fail "failed prototype registration did not preserve the broken manifest symlink"
  pass "fm-prototype.sh: missing fields and question drift fail closed"
}

test_registration_completion_and_preparation_are_idempotent() {
  local id=idempotent question='Does the reducer converge after duplicate input?' before after
  setup_case "$id" logic-state "$question"
  before=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" register "$id" logic-state "$question" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" bind "$id" "$CASE_WT" >/dev/null
  after=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  [ "$before" = "$after" ] || fail "identical registration and binding retries changed manifest bytes"

  write_report "$id" "$question" logic-state 'not-required: duplicate input did not reproduce a failure'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null
  before=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null
  after=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  [ "$before" = "$after" ] || fail "identical completion retry changed manifest bytes"

  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  before=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  after=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  [ "$before" = "$after" ] || fail "identical promotion preparation retry changed manifest bytes"
  pass "fm-prototype.sh: registration, completion, and preparation retries are idempotent"
}

test_sensitive_defaults_have_no_worker_bypass() {
  local id=sensitive question='Can a local fixture model NAS recovery policy?' manifest rc
  setup_case "$id" logic-state "$question"
  manifest="$CASE_HOME/data/$id/prototype.json"
  jq -e '
    .safety == {
      fixtures: "synthetic-or-minimized",
      persistence: "none",
      external_side_effects: "none",
      sensitive_live_access: "forbidden"
    }
  ' "$manifest" >/dev/null || fail "prototype registration did not apply the immutable safe envelope"

  FM_HOME="$CASE_HOME" "$PROTOTYPE" register "$id" logic-state "$question" \
    --allow-sensitive >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "ordinary worker convenience flag unexpectedly authorized sensitive access"

  jq '.safety.sensitive_live_access = "worker-asserted"' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" check "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "free-form sensitive assertion unexpectedly passed manifest validation"
  pass "fm-prototype.sh: sensitive boundaries are immutable and expose no worker bypass"
}

test_promotion_rejects_scratch_and_ignored_residue() {
  local id=hygiene question='Which state representation survives retries?' rc baseline exclude
  setup_case "$id" logic-state "$question" with-hook
  write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null

  printf 'debug\n' > "$CASE_WT/debug.log"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "promotion preparation accepted an untracked debug artifact"
  rm -f "$CASE_WT/debug.log"

  exclude=$(git -C "$CASE_WT" rev-parse --git-path info/exclude)
  printf '.env\n' >> "$exclude"
  printf 'credential-like residue\n' > "$CASE_WT/.env"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "promotion preparation accepted ignored credential residue"
  rm -f "$CASE_WT/.env"

  printf '{"changed":true}\n' > "$CASE_WT/.claude/settings.local.json"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "promotion preparation accepted a modified pre-launch ignored file"
  printf '{}\n' > "$CASE_WT/.claude/settings.local.json"

  baseline=$(git -C "$CASE_WT" rev-parse HEAD)
  printf '# scratch\n' >> "$CASE_WT/README.md"
  git -C "$CASE_WT" add README.md
  git -C "$CASE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm scratch
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "promotion preparation accepted a scratch commit"
  git -C "$CASE_WT" checkout --detach -q "$baseline"

  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" promotion-verify "$id" "$CASE_WT" >/dev/null
  pass "fm-prototype.sh: promotion rejects scratch state while allowing only the known injected hook"
}

test_logic_failure_carries_regression_test_obligation() {
  local id=regression question='Does replay duplicate a completed transition?' obligation out
  setup_case "$id" logic-state "$question"
  write_report "$id" "$question" logic-state \
    'required: replay duplicated the completed transition'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null
  obligation=$(FM_HOME="$CASE_HOME" "$PROTOTYPE" regression-obligation "$id")
  assert_contains "$obligation" "required: replay duplicated" \
    "logic-state failure did not persist its regression-test obligation"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=w:$id" "worktree=$CASE_WT" "project=$CASE_REPO" \
    "harness=echo" "kind=scout" "mode=no-mistakes" "yolo=off"
  out=$(FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" "$id")
  assert_contains "$out" "add the required regression test when it says required" \
    "prototype promotion did not carry the regression-test obligation into ship instructions"
  assert_contains "$out" "$ROOT/bin/fm-prototype.sh decision $id" \
    "prototype promotion did not use the absolute lifecycle helper outside the project worktree"
  assert_grep "kind=ship" "$CASE_HOME/state/$id.meta" \
    "validated prototype promotion did not enter the existing ship path"

  setup_case ui-regression ui 'Which layout exposes completion?'
  write_report ui-regression 'Which layout exposes completion?' ui \
    'required: a click failed'
  if FM_HOME="$CASE_HOME" "$PROTOTYPE" complete ui-regression >/dev/null 2>&1; then
    fail "UI prototype incorrectly created a logic-state regression-test obligation"
  fi
  pass "fm-prototype.sh: reproduced logic failures become explicit ship-time regression obligations"
}

test_tool_neutral_lifecycle_boundaries_are_central() {
  local check_line backend_line last_hook_line bind_line launch_line
  check_line=$(grep -n '"$FM_ROOT/bin/fm-prototype.sh" check' "$SPAWN" | head -n 1 | cut -d: -f1)
  backend_line=$(grep -n '^case "$BACKEND" in' "$SPAWN" | head -n 1 | cut -d: -f1)
  last_hook_line=$(grep -n "exclude_path '.fm-grok-turnend'" "$SPAWN" | head -n 1 | cut -d: -f1)
  bind_line=$(grep -n '"$FM_ROOT/bin/fm-prototype.sh" bind' "$SPAWN" | head -n 1 | cut -d: -f1)
  launch_line=$(grep -n 'spawn_send_literal "$T" "$LAUNCH"' "$SPAWN" | head -n 1 | cut -d: -f1)
  [ "$check_line" -lt "$backend_line" ] \
    || fail "prototype registration validation must precede runtime-backend creation"
  [ "$bind_line" -gt "$backend_line" ] && [ "$bind_line" -gt "$last_hook_line" ] \
    && [ "$bind_line" -lt "$launch_line" ] \
    || fail "prototype binding must occur after backend and tool-hook convergence but before harness launch"
  assert_grep '"$SCRIPT_DIR/fm-prototype.sh" verify "$ID"' "$TEARDOWN" \
    "prototype evidence verification is not wired into scout teardown"
  if grep -E '\.(claude|opencode|grok)|(^|[^A-Za-z0-9_-])(claude|codex|opencode|grok|pi)([^A-Za-z0-9_-]|$)' "$PROTOTYPE" >/dev/null; then
    fail "prototype lifecycle helper contains a worker-tool-specific assumption"
  fi
  assert_no_grep "Wayfinder" "$PROTOTYPE" \
    "prototype lifecycle introduced a second orchestration vocabulary"
  pass "prototype lifecycle: shared spawn and teardown seams stay tool-neutral"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

test_positive_evidence_and_decision
test_brief_requires_question_and_exact_class
test_incomplete_or_changed_evidence_fails
test_registration_completion_and_preparation_are_idempotent
test_sensitive_defaults_have_no_worker_bypass
test_promotion_rejects_scratch_and_ignored_residue
test_logic_failure_carries_regression_test_obligation
test_tool_neutral_lifecycle_boundaries_are_central
