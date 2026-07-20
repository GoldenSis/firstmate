#!/usr/bin/env bash
# Acceptance tests for bin/fm-fusion-gate.sh - the narrow, deterministic
# pre-builder gate helper from the model-fusion overlay
# (data/fusion-synthesis-v6/report.md, "Deterministic mechanics owner").
#
# The helper seals a validator-authored, test-only patch as a tamper-evident
# package, proves it observably RED on the untouched recorded base, and later
# replays it in the builder worktree enforcing red-before-edit / green-after.
# It must never edit production files, review a diff, push, merge, or invoke
# no-mistakes.
#
# These are the executable specification for that helper. On the untouched
# production baseline the helper does not exist, so test_helper_present is the
# first check and turns the whole file RED for exactly that missing capability;
# the behavioral fixtures below become live once the helper is implemented. All
# fixtures are hermetic: only git and bash, no live runtime and no no-mistakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-fusion-gate.sh"

fm_git_identity

# --- baseline RED anchor ----------------------------------------------------
# The single check that fires on the untouched baseline. Every behavioral test
# below needs the helper, so this ordering makes the file's red state
# unambiguously the missing helper, never a fixture accident.
test_helper_present() {
  assert_present "$GATE" \
    "bin/fm-fusion-gate.sh is missing (fusion pre-builder gate helper not implemented)"
  [ -x "$GATE" ] || fail "bin/fm-fusion-gate.sh must be an executable helper"
  pass "fm-fusion-gate.sh: helper present and executable"
}

test_usage_declares_three_subcommands() {
  local help
  help=$("$GATE" --help 2>&1 || true)
  assert_contains "$help" "seal" "fm-fusion-gate.sh --help omits the seal subcommand"
  assert_contains "$help" "verify" "fm-fusion-gate.sh --help omits the verify subcommand"
  assert_contains "$help" "run" "fm-fusion-gate.sh --help omits the run subcommand"
  pass "fm-fusion-gate.sh: usage declares seal, verify, and run"
}

# --- hermetic fixture -------------------------------------------------------
# Builds an FM_HOME with a synthesis scout and a validator scout, both on
# isolated worktrees of one project at a common base commit, plus a test-only
# patch that fails on the base (RED) and passes only after a production fixture
# edit (GREEN). Sets: HOME_DIR REPO BASE VAL_WT BUILD_WT PATCH PROD_PATCH.
mk_fusion_fixture() {
  local root
  root=$(fm_test_tmproot fm-fusion-gate)
  HOME_DIR="$root/home"
  REPO="$root/proj"
  VAL_WT="$root/val-wt"
  BUILD_WT="$root/build-wt"
  PATCH="$root/tests.patch"
  PROD_PATCH="$root/prod.patch"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

  # Project at a known base commit: a production script that prints "old" and a
  # tests/ dir the sealed patch is allowed to touch.
  mkdir -p "$REPO/bin" "$REPO/tests"
  cat > "$REPO/bin/feature.sh" <<'SH'
#!/usr/bin/env bash
echo old
SH
  chmod +x "$REPO/bin/feature.sh"
  : > "$REPO/tests/.keep"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm base
  BASE=$(git -C "$REPO" rev-parse HEAD)

  # Two isolated worktrees pinned to the same base commit.
  git -C "$REPO" worktree add -q --detach "$VAL_WT" "$BASE"
  git -C "$REPO" worktree add -q --detach "$BUILD_WT" "$BASE"

  # Scout metas for both tasks, recording project, base, and worktree.
  fm_write_meta "$HOME_DIR/state/synth1.meta" \
    "window=w:synth" "worktree=$BUILD_WT" "project=$REPO" \
    "harness=echo" "kind=scout" "mode=scout" "yolo=off" "base=$BASE"
  fm_write_meta "$HOME_DIR/state/val1.meta" \
    "window=w:val" "worktree=$VAL_WT" "project=$REPO" \
    "harness=echo" "kind=scout" "mode=scout" "yolo=off" "base=$BASE"

  # Test-only patch: adds a focused test that asserts feature.sh prints "new".
  # RED on base ("old"); GREEN only after the production fixture below.
  cat > "$VAL_WT/tests/feature-fusion.test.sh" <<'SH'
#!/usr/bin/env bash
set -u
out=$(./bin/feature.sh)
[ "$out" = new ] || { echo "not ok - feature.sh must print new (got: $out)"; exit 1; }
echo "ok - feature.sh prints new"
SH
  git -C "$VAL_WT" add tests/feature-fusion.test.sh
  git -C "$VAL_WT" diff --cached > "$PATCH"
  git -C "$VAL_WT" reset -q --hard "$BASE"
  git -C "$VAL_WT" clean -fdq

  # Production fixture the builder would author to turn the sealed gate green.
  cat > "$BUILD_WT/bin/feature.sh" <<'SH'
#!/usr/bin/env bash
echo new
SH
  git -C "$BUILD_WT" add bin/feature.sh
  git -C "$BUILD_WT" diff --cached > "$PROD_PATCH"
  git -C "$BUILD_WT" reset -q --hard "$BASE"
}

# --- seal: red proof, package, tamper-evidence ------------------------------
test_seal_requires_red_proof_and_writes_sealed_package() {
  local out rc pkg
  mk_fusion_fixture
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$PATCH" -- bash tests/feature-fusion.test.sh 2>&1); rc=$?
  expect_code 0 "$rc" "seal must succeed once the test patch is proven red on the base (out: $out)"
  pkg="$HOME_DIR/data/synth1/fusion-gate/v1"
  assert_present "$pkg" "seal did not create the sealed package under data/<synthesis-id>/fusion-gate/v1"
  # Sealed bytes must be recorded non-writable (tamper-evident storage).
  if find "$pkg" -type f -perm -u+w 2>/dev/null | grep -q .; then
    fail "seal left a user-writable file inside the sealed package"
  fi
  pass "fm-fusion-gate.sh: seal proves red on the base and writes a non-writable package"
}

test_seal_rejects_production_file_patch() {
  local rc
  mk_fusion_fixture
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$PROD_PATCH" -- bash tests/feature-fusion.test.sh >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "seal must refuse a patch that changes a production (non-test) file"
  assert_absent "$HOME_DIR/data/synth1/fusion-gate/v1" \
    "refused production-file patch still created a sealed package"
  pass "fm-fusion-gate.sh: seal refuses a production-file patch"
}

test_seal_rejects_symlink_patch() {
  local rc link
  mk_fusion_fixture
  link="$VAL_WT/link.patch"
  ln -s "$PATCH" "$link"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$link" -- bash tests/feature-fusion.test.sh >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "seal must refuse a symlinked patch file"
  pass "fm-fusion-gate.sh: seal refuses a symlink patch"
}

test_seal_rejects_traversal_patch_path() {
  local rc
  mk_fusion_fixture
  # A patch path that escapes the validator worktree via traversal.
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$VAL_WT/../tests.patch" -- bash tests/feature-fusion.test.sh >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "seal must refuse a patch path that traverses outside the validator worktree"
  pass "fm-fusion-gate.sh: seal refuses a traversal patch path"
}

# --- verify: fail closed, tamper detection ----------------------------------
test_verify_fails_closed_without_seal() {
  local rc
  mk_fusion_fixture
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$GATE" verify synth1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail closed when no seal exists"
  pass "fm-fusion-gate.sh: verify fails closed on a missing seal"
}

test_verify_detects_tampered_package() {
  local rc pkg victim
  mk_fusion_fixture
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$PATCH" -- bash tests/feature-fusion.test.sh >/dev/null 2>&1 \
    || fail "seal fixture failed before the tamper check"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$GATE" verify synth1 >/dev/null 2>&1 \
    || fail "verify must succeed on an untampered seal"
  pkg="$HOME_DIR/data/synth1/fusion-gate/v1"
  victim=$(find "$pkg" -type f | head -n1)
  chmod u+w "$victim"
  printf '\ntampered\n' >> "$victim"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$GATE" verify synth1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "verify must fail closed once a sealed package byte changes"
  pass "fm-fusion-gate.sh: verify detects a tampered sealed package"
}

# --- run: red-before-edit, green-after, isolation ---------------------------
test_run_enforces_red_on_base_then_green_after_fix() {
  local rc
  mk_fusion_fixture
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$PATCH" -- bash tests/feature-fusion.test.sh >/dev/null 2>&1 \
    || fail "seal fixture failed before the run check"
  # On the untouched builder worktree the sealed gate is red.
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" run synth1 "$BUILD_WT" --expect red >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "run --expect red must pass on the unmodified builder base"
  # A --expect green demand must fail while production is still unchanged.
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" run synth1 "$BUILD_WT" --expect green >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "run --expect green must fail before the production fix lands"
  # Apply the production fixture; the same sealed gate is now green.
  git -C "$BUILD_WT" apply "$PROD_PATCH"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" run synth1 "$BUILD_WT" --expect green >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "run --expect green must pass once the production fix makes the sealed test pass"
  # The gate must not have edited production itself: the only tracked change is
  # the builder's own production fix, never a committed test artifact.
  git -C "$BUILD_WT" reset -q --hard "$BASE"
  assert_absent "$BUILD_WT/tests/feature-fusion.test.sh" \
    "run left the sealed test committed/applied in the worktree after reset - it must apply idempotently, not persist"
  pass "fm-fusion-gate.sh: run enforces red-before-edit and green-after-fix"
}

test_run_refuses_primary_checkout() {
  local rc
  mk_fusion_fixture
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth1 val1 --patch "$PATCH" -- bash tests/feature-fusion.test.sh >/dev/null 2>&1 \
    || fail "seal fixture failed before the primary-checkout check"
  # The project's primary checkout (REPO itself) is never a valid run target.
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" run synth1 "$REPO" --expect red >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "run must refuse to operate on the project's primary checkout"
  pass "fm-fusion-gate.sh: run refuses the primary checkout"
}

# --- no delivery authority: the gate never touches no-mistakes ---------------
test_gate_helper_never_invokes_no_mistakes() {
  # Source-level guard: the pre-builder gate is a test replayer, never a ship
  # pipeline. It must not shell out to no-mistakes in any subcommand.
  assert_no_grep "no-mistakes axi" "$GATE" \
    "fm-fusion-gate.sh must never invoke a no-mistakes axi command"
  pass "fm-fusion-gate.sh: helper never invokes no-mistakes"
}

test_helper_present
test_usage_declares_three_subcommands
test_seal_requires_red_proof_and_writes_sealed_package
test_seal_rejects_production_file_patch
test_seal_rejects_symlink_patch
test_seal_rejects_traversal_patch_path
test_verify_fails_closed_without_seal
test_verify_detects_tampered_package
test_run_enforces_red_on_base_then_green_after_fix
test_run_refuses_primary_checkout
test_gate_helper_never_invokes_no_mistakes
