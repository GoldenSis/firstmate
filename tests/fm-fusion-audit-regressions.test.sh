#!/usr/bin/env bash
# Regressions from the bounded Claude audit of the model-fusion gate.
# These remain separate from the sealed validator-owned test patch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-fusion-gate.sh"
BRIEF="$ROOT/bin/fm-brief.sh"

fm_git_identity

test_ordinary_scout_spacing_is_byte_compatible() {
  local home brief prefix expected
  home=$(fm_test_tmproot fm-fusion-ordinary-brief)
  mkdir -p "$home/data"
  FM_HOME="$home" "$BRIEF" ordinary alpha --scout >/dev/null
  brief="$home/data/ordinary/brief.md"
  prefix=$(sed -n '1,/^# Setup$/p' "$brief")
  expected=$(cat <<'EOF'
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.

# Setup
EOF
)
  [ "$prefix" = "$expected" ] || fail "ordinary scout spacing differs from the pre-fusion scaffold"
  pass "ordinary scout spacing remains byte-compatible through Setup"
}

make_sha256sum_only_path() {
  local target=$1 tool resolved real_shasum
  mkdir -p "$target"
  for tool in bash cat chmod cp dirname git mkdir mktemp mv rm sed tail; do
    resolved=$(type -P "$tool") || fail "required test tool is unavailable: $tool"
    ln -s "$resolved" "$target/$tool"
  done
  if resolved=$(type -P sha256sum); then
    ln -s "$resolved" "$target/sha256sum"
  else
    real_shasum=$(type -P shasum) || fail "neither sha256sum nor shasum is available for the fallback fixture"
    cat > "$target/sha256sum" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -c ]; then
  shift
  exec "$real_shasum" -a 256 -c "\$@"
fi
exec "$real_shasum" -a 256 "\$@"
EOF
    chmod +x "$target/sha256sum"
  fi
}

test_sha256sum_fallback_seals_and_verifies() {
  local root home repo val_wt synth_wt patch fallback base out rc
  root=$(fm_test_tmproot fm-fusion-sha-fallback)
  home="$root/home"
  repo="$root/project"
  val_wt="$root/validator"
  synth_wt="$root/synthesis"
  patch="$root/gate.patch"
  fallback="$root/sha256sum-only"
  mkdir -p "$home/data" "$home/state" "$repo/bin" "$repo/tests"
  printf '#!/usr/bin/env bash\necho old\n' > "$repo/bin/feature.sh"
  chmod +x "$repo/bin/feature.sh"
  : > "$repo/tests/.keep"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" worktree add -q --detach "$val_wt" "$base"
  git -C "$repo" worktree add -q --detach "$synth_wt" "$base"
  fm_write_meta "$home/state/synth.meta" \
    "worktree=$synth_wt" "project=$repo" "harness=codex" "model=explicit-synth" \
    "kind=scout" "mode=scout" "base=$base"
  fm_write_meta "$home/state/validator.meta" \
    "worktree=$val_wt" "project=$repo" "harness=claude" "model=explicit-validator" \
    "kind=scout" "mode=scout" "base=$base"
  cat > "$val_wt/tests/feature.test.sh" <<'EOF'
#!/usr/bin/env bash
[ "$(./bin/feature.sh)" = new ]
EOF
  git -C "$val_wt" add tests/feature.test.sh
  git -C "$val_wt" diff --cached > "$patch"
  git -C "$val_wt" reset -q --hard "$base"
  make_sha256sum_only_path "$fallback"

  out=$(PATH="$fallback" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth validator --patch "$patch" -- bash tests/feature.test.sh 2>&1); rc=$?
  expect_code 0 "$rc" "seal must use sha256sum when shasum is unavailable (out: $out)"
  out=$(PATH="$fallback" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" verify synth 2>&1); rc=$?
  expect_code 0 "$rc" "verify must use sha256sum when shasum is unavailable (out: $out)"
  pass "fusion gate seals and verifies through the sha256sum fallback"
}

test_rename_into_tests_is_rejected() {
  local root home repo val_wt synth_wt patch base out rc
  root=$(fm_test_tmproot fm-fusion-rename)
  home="$root/home"
  repo="$root/project"
  val_wt="$root/validator"
  synth_wt="$root/synthesis"
  patch="$root/gate.patch"
  mkdir -p "$home/data" "$home/state" "$repo/bin" "$repo/tests"
  printf '#!/usr/bin/env bash\necho production\n' > "$repo/bin/feature.sh"
  chmod +x "$repo/bin/feature.sh"
  : > "$repo/tests/.keep"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" worktree add -q --detach "$val_wt" "$base"
  git -C "$repo" worktree add -q --detach "$synth_wt" "$base"
  fm_write_meta "$home/state/synth.meta" \
    "worktree=$synth_wt" "project=$repo" "harness=codex" "model=explicit-synth" \
    "kind=scout" "mode=scout" "base=$base"
  fm_write_meta "$home/state/validator.meta" \
    "worktree=$val_wt" "project=$repo" "harness=claude" "model=explicit-validator" \
    "kind=scout" "mode=scout" "base=$base"
  # A rename of a production file into tests/ shows numstat only for the
  # destination path, so the tests-only check must reject the rename metadata.
  git -C "$val_wt" mv bin/feature.sh tests/moved.sh
  git -C "$val_wt" commit -qm move
  git -C "$val_wt" format-patch -1 --stdout > "$patch"
  git -C "$val_wt" reset -q --hard "$base"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$GATE" seal synth validator --patch "$patch" -- bash tests/moved.sh 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "seal must reject a rename of a production file into tests/ (out: $out)"
  assert_contains "$out" "rename or copy" "seal must name the rename/copy restriction (out: $out)"
  assert_absent "$home/data/synth/fusion-gate/v1" "no package may be sealed from a rename patch"
  pass "fusion gate refuses a rename of a production file into tests/"
}

test_sha256sum_fallback_seals_and_verifies
test_rename_into_tests_is_rejected
test_ordinary_scout_spacing_is_byte_compatible
