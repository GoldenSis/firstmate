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
trap 'rm -rf "$TMP_ROOT"' EXIT

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

Dispose of UI scratch at promotion; retain decision-bearing logic-state evidence until the decision expires.

### Regression-test obligation

$obligation
EOF
}

commit_logic_artifact() {
  local id=$1
  git -C "$CASE_WT" checkout -qb "proto/$id"
  printf 'queued -> retry -> completed\n' > "$CASE_WT/reducer.txt"
  git -C "$CASE_WT" add reducer.txt
  git -C "$CASE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'Prototype reducer'
}

setup_teardown() {
  local id=$1 backend=$2 kind=${3:-scout}
  CASE_FAKEBIN=$(fm_fakebin "$CASE_HOME")
  fm_fake_exit0 "$CASE_FAKEBIN" tmux
  mkdir -p "$CASE_HOME/config"
  printf 'manual\n' > "$CASE_HOME/config/backlog-backend"
  cat > "$CASE_FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
touch "$PROTOTYPE_TEST_CLEANUP"
git -C "$PROTOTYPE_TEST_REPO" worktree remove --force "$PROTOTYPE_TEST_WT"
SH
  cat > "$CASE_FAKEBIN/orca" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'worktree show') jq -n --arg path "$PROTOTYPE_TEST_WT" '{result: {path: $path}}' ;;
  'worktree rm')
    touch "$PROTOTYPE_TEST_CLEANUP"
    git -C "$PROTOTYPE_TEST_REPO" worktree remove --force "$PROTOTYPE_TEST_WT" || exit 1
    printf '{"ok":true}\n'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$CASE_FAKEBIN/treehouse" "$CASE_FAKEBIN/orca"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=w:$id" "worktree=$CASE_WT" "project=$CASE_REPO" \
    "kind=$kind" "backend=$backend" "orca_worktree_id=fixture" \
    'mode=local-only' 'decisions_reviewed=1' 'decision_keys='
}

run_teardown() {
  PATH="$CASE_FAKEBIN:$PATH" PROTOTYPE_TEST_WT="$CASE_WT" \
    PROTOTYPE_TEST_REPO="$CASE_REPO" PROTOTYPE_TEST_CLEANUP="$CASE_HOME/cleanup-called" \
    FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$TEARDOWN" "$@"
}

test_logic_completion_retains_artifact_without_promotion() {
  local backend id question='Does the reducer preserve retry order?' artifact
  for backend in tmux orca; do
    id="completion-$backend"
    setup_case "$id" logic-state "$question"
    commit_logic_artifact "$id"
    artifact=$(git -C "$CASE_WT" rev-parse HEAD)
    write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
    FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null \
      || fail "logic-state completion failed"
    jq -e '.promotion == null' "$CASE_HOME/data/$id/prototype.json" >/dev/null \
      || fail "report-only completion prepared implementation"
    setup_teardown "$id" "$backend"
    run_teardown "$id" >/dev/null || fail "$backend report-only teardown failed"
    [ "$(git -C "$CASE_REPO" rev-parse --verify "refs/heads/proto/$id" 2>/dev/null)" = "$artifact" ] \
      || fail "$backend report-only teardown lost the artifact branch"
    assert_absent "$CASE_WT" "$backend teardown did not remove the fixture worktree"
    assert_present "$CASE_HOME/data/$id/report.md" "$backend teardown removed the report"
    jq -e --arg branch "proto/$id" --arg commit "$artifact" \
      '.retained_artifact == {branch: $branch, commit: $commit}' \
      "$CASE_HOME/data/$id/prototype.json" >/dev/null \
      || fail "$backend completion did not preserve artifact identity"
  done
  pass "fm-prototype.sh: report-only completion retains artifact evidence across both cleanup paths"
}

test_teardown_refuses_changed_retained_refs() {
  local backend stage damage id question='Does retry converge?' baseline artifact before rc out
  for backend in tmux orca; do
    for stage in completed prepared promoted; do
      for damage in missing renamed moved; do
        id="ref-$backend-$stage-$damage"
        setup_case "$id" logic-state "$question" with-hook
        baseline=$(git -C "$CASE_WT" rev-parse HEAD)
        commit_logic_artifact "$id"
        artifact=$(git -C "$CASE_WT" rev-parse HEAD)
        write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
        FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "completion failed"
        setup_teardown "$id" "$backend"
        if [ "$stage" != completed ]; then
          FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null \
            || fail "preparation failed"
        fi
        if [ "$stage" = promoted ]; then
          FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" "$id" >/dev/null \
            || fail "promotion failed"
          git -C "$CASE_WT" checkout -qb "fm/$id"
        fi
        case "$damage" in
          missing)
            git -C "$CASE_WT" checkout --detach -q "$baseline"
            git -C "$CASE_REPO" branch -D "proto/$id" >/dev/null
            ;;
          renamed) git -C "$CASE_REPO" branch -m "proto/$id" "renamed/$id" ;;
          moved)
            git -C "$CASE_WT" checkout --detach -q "$baseline"
            git -C "$CASE_REPO" branch -f "proto/$id" "$baseline" >/dev/null
            ;;
        esac
        before=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
        out=$(run_teardown "$id" 2>&1); rc=$?
        [ "$rc" -ne 0 ] || fail "$backend $stage teardown accepted a $damage artifact ref"
        assert_contains "$out" 'retained artifact' "teardown failed for a reason unrelated to retention"
        assert_absent "$CASE_HOME/cleanup-called" "refused teardown invoked backend cleanup"
        assert_present "$CASE_WT/.claude/settings.local.json" "refused teardown removed the injected hook"
        assert_present "$CASE_HOME/state/$id.meta" "refused teardown removed task metadata"
        [ "$before" = "$(sha256_file "$CASE_HOME/data/$id/prototype.json")" ] \
          || fail "refused teardown changed artifact identity"
        if [ "$damage" = renamed ]; then
          [ "$(git -C "$CASE_REPO" rev-parse "renamed/$id")" = "$artifact" ] \
            || fail "refused teardown deleted the renamed artifact"
          git -C "$CASE_REPO" branch -m "renamed/$id" "proto/$id"
        else
          git -C "$CASE_REPO" branch -f "proto/$id" "$artifact" >/dev/null
        fi
        run_teardown "$id" >/dev/null || fail "restoring the artifact ref did not unblock cleanup"
        assert_absent "$CASE_WT" "successful teardown did not remove the fixture worktree"
        [ "$(git -C "$CASE_REPO" rev-parse "proto/$id")" = "$artifact" ] \
          || fail "successful teardown lost restored artifact evidence"
      done
    done
  done
  pass "fm-teardown.sh: both cleanup paths refuse missing, renamed, or moved artifacts before and after promotion"
}

test_logic_completion_requires_clean_artifact() {
  local id=completion-hygiene question='Does replay preserve order?' manifest before rc residue
  setup_case "$id" logic-state "$question" with-hook
  write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
  manifest="$CASE_HOME/data/$id/prototype.json"
  before=$(sha256_file "$manifest")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "logic-state completion accepted an absent artifact branch"
  commit_logic_artifact "$id"
  printf '.env\n' >> "$(git -C "$CASE_WT" rev-parse --git-path info/exclude)"
  for residue in tracked untracked ignored hook; do
    case "$residue" in
      tracked) printf 'changed\n' >> "$CASE_WT/reducer.txt" ;;
      untracked) printf 'debug\n' > "$CASE_WT/debug.log" ;;
      ignored) printf 'synthetic secret\n' > "$CASE_WT/.env" ;;
      hook) printf '{"changed":true}\n' > "$CASE_WT/.claude/settings.local.json" ;;
    esac
    FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] || fail "logic-state completion accepted $residue residue"
    [ "$before" = "$(sha256_file "$manifest")" ] || fail "refused completion changed the manifest"
    git -C "$CASE_WT" restore reducer.txt
    rm -f "$CASE_WT/debug.log" "$CASE_WT/.env"
    printf '{}\n' > "$CASE_WT/.claude/settings.local.json"
  done
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "preparation accepted an artifact before completion"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "clean artifact completion failed"
  jq 'del(.retained_artifact)' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "preparation recorded an artifact missing from completed evidence"
  pass "fm-prototype.sh: completion requires a clean retained artifact and preparation requires its recorded identity"
}

test_legacy_retention_survives_evidence_updates() {
  local id=legacy question='Does retry preserve order?' manifest artifact before rc
  setup_case "$id" logic-state "$question"
  commit_logic_artifact "$id"
  artifact=$(git -C "$CASE_WT" rev-parse HEAD)
  write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "completion failed"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null || fail "preparation failed"
  manifest="$CASE_HOME/data/$id/prototype.json"
  jq '.promotion.retained_artifact = .retained_artifact | del(.retained_artifact)' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" promotion-verify "$id" "$CASE_WT" >/dev/null \
    || fail "legacy artifact preparation was not verifiable"
  printf '\nAdditional observation: repeated input converges.\n' >> "$CASE_HOME/data/$id/report.md"
  git -C "$CASE_WT" branch -m "proto/$id" "renamed/$id"
  before=$(sha256_file "$manifest")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "evidence update accepted a renamed legacy artifact"
  [ "$before" = "$(sha256_file "$manifest")" ] || fail "refused update lost legacy retention"
  git -C "$CASE_WT" branch -m "renamed/$id" "proto/$id"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "legacy evidence update failed"
  jq -e --arg branch "proto/$id" --arg commit "$artifact" \
    '.promotion == null and .retained_artifact == {branch: $branch, commit: $commit}' "$manifest" >/dev/null \
    || fail "legacy evidence update lost retained artifact identity"
  setup_teardown "$id" tmux
  run_teardown "$id" >/dev/null || fail "updated legacy artifact cleanup failed"
  [ "$(git -C "$CASE_REPO" rev-parse "proto/$id")" = "$artifact" ] \
    || fail "legacy artifact was lost during cleanup"
  pass "fm-prototype.sh: legacy retention remains verified and survives evidence updates"
}

test_ui_completion_keeps_report_only() {
  local id=ui-report question='Which layout exposes retries?'
  setup_case "$id" ui "$question"
  git -C "$CASE_WT" checkout -qb "proto/$id"
  printf 'UI scratch\n' > "$CASE_WT/layout.txt"
  write_report "$id" "$question" ui 'not-required: no failure was reproduced'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "UI completion refused scratch"
  setup_teardown "$id" tmux
  run_teardown "$id" >/dev/null || fail "UI report-only cleanup failed"
  if git -C "$CASE_REPO" show-ref --verify --quiet "refs/heads/proto/$id"; then
    fail "UI cleanup retained an artifact branch"
  fi
  assert_absent "$CASE_WT" "UI cleanup retained scratch"
  assert_present "$CASE_HOME/data/$id/report.md" "UI cleanup removed the report"
  jq -e '.retained_artifact == null and .promotion == null' "$CASE_HOME/data/$id/prototype.json" >/dev/null \
    || fail "UI completion recorded artifact retention"
  pass "fm-prototype.sh: UI report-only completion still discards scratch"
}

test_positive_evidence_and_decision() {
  local id=positive question='Does retry preserve the queued transition?' decision
  setup_case "$id" logic-state "$question"
  commit_logic_artifact "$id"
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
  local id=idempotent question='Does the reducer converge after duplicate input?' before after artifact refs rc
  setup_case "$id" logic-state "$question"
  before=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" register "$id" logic-state "$question" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" bind "$id" "$CASE_WT" >/dev/null
  after=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  [ "$before" = "$after" ] || fail "identical registration and binding retries changed manifest bytes"

  commit_logic_artifact "$id"
  artifact=$(git -C "$CASE_WT" rev-parse HEAD)
  refs=$(git -C "$CASE_REPO" for-each-ref --format='%(refname) %(objectname)' refs/heads)
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
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "completion retry failed after preparation"
  [ "$before" = "$(sha256_file "$CASE_HOME/data/$id/prototype.json")" ] \
    || fail "identical completion retry invalidated preparation or retention"

  printf '\nAdditional observation: retries remain deterministic.\n' >> "$CASE_HOME/data/$id/report.md"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null || fail "evidence update failed"
  jq -e --arg branch "proto/$id" --arg commit "$artifact" \
    '.promotion == null and .retained_artifact == {branch: $branch, commit: $commit}' \
    "$CASE_HOME/data/$id/prototype.json" >/dev/null \
    || fail "evidence update did not preserve retention independently of preparation"
  [ "$refs" = "$(git -C "$CASE_REPO" for-each-ref --format='%(refname) %(objectname)' refs/heads)" ] \
    || fail "completion or preparation created or changed an artifact branch"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  before=$(sha256_file "$CASE_HOME/data/$id/prototype.json")
  git -C "$CASE_WT" checkout --detach -q "$(jq -r '.binding.baseline_head' "$CASE_HOME/data/$id/prototype.json")"
  git -C "$CASE_REPO" branch -f "proto/$id" HEAD >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "completion retry accepted a moved artifact"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "preparation retry accepted a moved artifact"
  [ "$before" = "$(sha256_file "$CASE_HOME/data/$id/prototype.json")" ] \
    || fail "refused retry rewrote the retained identity"
  git -C "$CASE_REPO" branch -f "proto/$id" "$artifact" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null \
    || fail "completion retry refused detached baseline with the retained branch"
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

test_ui_promotion_rejects_scratch_and_ignored_residue() {
  local id=hygiene question='Which layout exposes retries?' rc baseline exclude
  setup_case "$id" ui "$question" with-hook
  write_report "$id" "$question" ui 'not-required: no failure was reproduced'
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
  git -C "$CASE_WT" checkout -qb "proto/$id"
  printf '# scratch\n' >> "$CASE_WT/README.md"
  git -C "$CASE_WT" add README.md
  git -C "$CASE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm scratch
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "UI preparation accepted a scratch commit on a prototype branch"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=w:$id" "worktree=$CASE_WT" "project=$CASE_REPO" "kind=scout"
  FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" "$id" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "UI promotion accepted retained scratch"
  assert_grep 'kind=scout' "$CASE_HOME/state/$id.meta" "refused UI promotion changed task kind"
  git -C "$CASE_WT" checkout --detach -q "$baseline"

  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" promotion-verify "$id" "$CASE_WT" >/dev/null
  pass "fm-prototype.sh: UI promotion rejects scratch state while allowing only the known injected hook"
}

test_logic_promotion_retains_artifact_off_ship_branch() {
  local id=retained question='Does the reducer preserve retry order?' baseline artifact manifest before rc
  setup_case "$id" logic-state "$question" with-hook
  baseline=$(git -C "$CASE_WT" rev-parse HEAD)
  commit_logic_artifact "$id"
  artifact=$(git -C "$CASE_WT" rev-parse HEAD)
  write_report "$id" "$question" logic-state 'not-required: no failure was reproduced'
  FM_HOME="$CASE_HOME" "$PROTOTYPE" complete "$id" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null \
    || fail "logic-state preparation refused the clean retained artifact"
  manifest="$CASE_HOME/data/$id/prototype.json"
  jq -e --arg branch "proto/$id" --arg commit "$artifact" \
    '.retained_artifact == {branch: $branch, commit: $commit}' "$manifest" >/dev/null \
    || fail "promotion did not preserve the completed artifact branch and commit"
  before=$(sha256_file "$manifest")
  FM_HOME="$CASE_HOME" "$PROTOTYPE" prepare-promotion "$id" "$CASE_WT" >/dev/null
  [ "$before" = "$(sha256_file "$manifest")" ] || fail "retention preparation was not idempotent"

  printf 'debug\n' > "$CASE_WT/debug.log"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" promotion-verify "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "retention accepted untracked scratch"
  rm "$CASE_WT/debug.log"
  printf '{"changed":true}\n' > "$CASE_WT/.claude/settings.local.json"
  FM_HOME="$CASE_HOME" "$PROTOTYPE" promotion-verify "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "retention accepted modified ignored residue"
  printf '{}\n' > "$CASE_WT/.claude/settings.local.json"

  git -C "$CASE_WT" checkout --detach -q "$baseline"
  git -C "$CASE_WT" branch -f "proto/$id" "$baseline" >/dev/null
  FM_HOME="$CASE_HOME" "$PROTOTYPE" promotion-verify "$id" "$CASE_WT" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "retention accepted a moved artifact branch"
  git -C "$CASE_WT" branch -f "proto/$id" "$artifact" >/dev/null
  git -C "$CASE_WT" checkout -q "proto/$id"

  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=w:$id" "worktree=$CASE_WT" "project=$CASE_REPO" \
    "harness=echo" "kind=scout" "mode=no-mistakes" "yolo=off"
  FM_HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PROMOTE" "$id" >/dev/null \
    || fail "logic-state promotion failed"
  [ "$(git -C "$CASE_WT" rev-parse HEAD)" = "$baseline" ] \
    || fail "ship task did not start at the clean baseline"
  assert_absent "$CASE_WT/reducer.txt" "retained scratch reached the promoted worktree"
  git -C "$CASE_WT" checkout -qb "fm/$id"
  if git -C "$CASE_WT" merge-base --is-ancestor "$artifact" HEAD; then
    fail "retained prototype commit reached the ship branch"
  fi
  [ "$(git -C "$CASE_REPO" rev-parse "proto/$id")" = "$artifact" ] \
    || fail "promotion lost the retained prototype branch"
  pass "fm-prototype.sh: logic-state artifact survives promotion outside the ship branch"
}

test_logic_failure_carries_regression_test_obligation() {
  local id=regression question='Does replay duplicate a completed transition?' obligation out
  setup_case "$id" logic-state "$question"
  commit_logic_artifact "$id"
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

test_logic_completion_retains_artifact_without_promotion
test_teardown_refuses_changed_retained_refs
test_logic_completion_requires_clean_artifact
test_legacy_retention_survives_evidence_updates
test_ui_completion_keeps_report_only
test_positive_evidence_and_decision
test_brief_requires_question_and_exact_class
test_incomplete_or_changed_evidence_fails
test_logic_promotion_retains_artifact_off_ship_branch
test_registration_completion_and_preparation_are_idempotent
test_sensitive_defaults_have_no_worker_bypass
test_ui_promotion_rejects_scratch_and_ignored_residue
test_logic_failure_carries_regression_test_obligation
test_tool_neutral_lifecycle_boundaries_are_central
