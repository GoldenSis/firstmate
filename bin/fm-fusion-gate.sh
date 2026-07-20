#!/usr/bin/env bash
# Seal and replay a model-fusion validator's pre-builder acceptance gate.
# Usage:
#   fm-fusion-gate.sh seal <synthesis-id> <validator-id> --patch <file> -- <test-argv...>
#   fm-fusion-gate.sh verify <synthesis-id>
#   fm-fusion-gate.sh run <synthesis-id> <worktree> --expect red|green
#
# `seal` requires two scout tasks for the same project and untouched base, accepts
# a regular test-only patch plus an argv-safe test command, proves that gate red in
# the validator worktree, and publishes a non-writable content-addressed package at
# data/<synthesis-id>/fusion-gate/v1/. Existing identical seals are idempotent;
# conflicting reseals fail closed instead of rewriting v1.
#
# `verify` checks the package bytes, recorded synthesis/project/base identity, test
# path restriction, and seal metadata. `run` verifies the package, refuses the
# primary checkout or a different base, applies the test patch temporarily, runs
# the exact argv without eval, checks the requested red/green result, and removes
# the patch. The helper never edits production files and grants no delivery,
# review, push, merge, or no-mistakes authority.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

meta_value() {
  local file=$1 key=$2
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

sha256_tool() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\n' shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' sha256sum
  else
    die "shasum or sha256sum is required for fusion gate digests"
  fi
}

sha256_files() {
  local tool=$1
  shift
  case "$tool" in
    shasum) shasum -a 256 "$@" ;;
    sha256sum) sha256sum "$@" ;;
    *) die "unsupported SHA-256 tool: $tool" ;;
  esac
}

sha256_check() {
  local tool=$1 manifest=$2
  case "$tool" in
    shasum) shasum -a 256 -c "$manifest" ;;
    sha256sum) sha256sum -c "$manifest" ;;
    *) die "unsupported SHA-256 tool: $tool" ;;
  esac
}

task_meta() {
  local id=$1 file="$STATE/$1.meta"
  [ -f "$file" ] || die "no meta for task $id at $file"
  printf '%s\n' "$file"
}

task_base() {
  local meta=$1 worktree=$2 base
  base=$(meta_value "$meta" base)
  if [ -z "$base" ]; then
    base=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) || return 1
  fi
  printf '%s\n' "$base"
}

reject_unsafe_patch_argument() {
  local patch=$1
  case "$patch" in
    *$'\n'*|../*|*/../*|*/..) die "patch path is unsafe or contains traversal: $patch" ;;
  esac
  [ ! -L "$patch" ] || die "patch must not be a symlink: $patch"
  [ -f "$patch" ] || die "patch must be a regular file: $patch"
}

validate_test_patch() {
  local project=$1 patch=$2 rows path count=0 error=
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-fusion-paths.XXXXXX")
  if ! git -C "$project" apply --numstat "$patch" > "$rows" 2>/dev/null; then
    rm -f "$rows"
    die "patch is not a valid git patch"
  fi
  while IFS=$'\t' read -r _ _ path; do
    [ -n "$path" ] || continue
    count=$((count + 1))
    case "$path" in
      tests/*) ;;
      *) error="gate patch may change only tests/: $path"; break ;;
    esac
    case "$path" in
      /*|*'..'*|*$'\n'*) error="unsafe gate path: $path"; break ;;
    esac
  done < "$rows"
  rm -f "$rows"
  [ -z "$error" ] || die "$error"
  [ "$count" -gt 0 ] || die "gate patch contains no test changes"
}

write_argv() {
  local target=$1 arg
  shift
  : > "$target"
  [ "$#" -gt 0 ] || die "test argv must not be empty"
  for arg in "$@"; do
    [ -n "$arg" ] || die "test argv contains an empty argument"
    case "$arg" in *$'\n'*) die "test argv must not contain newlines" ;; esac
    printf '%s\n' "$arg" >> "$target"
  done
}

read_argv_and_run() {
  local argv_file=$1 worktree=$2 arg
  local args=()
  while IFS= read -r arg || [ -n "$arg" ]; do
    args+=("$arg")
  done < "$argv_file"
  [ "${#args[@]}" -gt 0 ] || die "sealed test argv is empty"
  (cd "$worktree" && "${args[@]}")
}

manifest_value() {
  meta_value "$1" "$2"
}

verify_package() {
  local id=$1 pkg="$DATA/$1/fusion-gate/v1" manifest synth_meta
  local recorded_project current_project synth_worktree recorded_base current_base file digest_tool
  [ -d "$pkg" ] || die "no sealed fusion gate for $id"
  for file in gate.patch argv manifest red-output.log seal.sha256; do
    [ -f "$pkg/$file" ] && [ ! -L "$pkg/$file" ] || die "sealed package has a missing or unsafe $file"
    [ ! -w "$pkg/$file" ] || die "sealed package file is writable: $file"
  done
  digest_tool=$(sha256_tool)
  (cd "$pkg" && sha256_check "$digest_tool" seal.sha256 >/dev/null 2>&1) \
    || die "sealed fusion gate digest verification failed"
  manifest="$pkg/manifest"
  [ "$(manifest_value "$manifest" synthesis)" = "$id" ] || die "sealed synthesis identity mismatch"
  synth_meta=$(task_meta "$id")
  synth_worktree=$(meta_value "$synth_meta" worktree)
  recorded_project=$(manifest_value "$manifest" project)
  current_project=$(canonical_dir "$(meta_value "$synth_meta" project)") || die "invalid synthesis project"
  [ "$current_project" = "$recorded_project" ] || die "sealed project identity mismatch"
  recorded_base=$(manifest_value "$manifest" base)
  current_base=$(task_base "$synth_meta" "$synth_worktree") || die "cannot resolve synthesis base"
  [ "$current_base" = "$recorded_base" ] || die "sealed base identity mismatch"
  validate_test_patch "$recorded_project" "$pkg/gate.patch"
  printf '%s\n' "$pkg"
}

seal_gate() {
  local synthesis=${1:-} validator=${2:-}
  shift 2 || true
  valid_id "$synthesis" || die "invalid synthesis task id"
  valid_id "$validator" || die "invalid validator task id"
  [ "$synthesis" != "$validator" ] || die "validator task must be separate from the synthesis task"
  [ "${1:-}" = --patch ] || die "seal requires --patch <file>"
  local patch=${2:-}
  shift 2 || true
  [ "${1:-}" = -- ] || die "seal requires -- before the test argv"
  shift
  [ "$#" -gt 0 ] || die "seal requires a test argv"
  reject_unsafe_patch_argument "$patch"

  local synth_meta val_meta synth_wt val_wt synth_project val_project synth_base val_base
  synth_meta=$(task_meta "$synthesis")
  val_meta=$(task_meta "$validator")
  [ "$(meta_value "$synth_meta" kind)" = scout ] || die "synthesis task must be kind=scout while sealing"
  [ "$(meta_value "$val_meta" kind)" = scout ] || die "validator task must be kind=scout while sealing"
  synth_wt=$(canonical_dir "$(meta_value "$synth_meta" worktree)") || die "invalid synthesis worktree"
  val_wt=$(canonical_dir "$(meta_value "$val_meta" worktree)") || die "invalid validator worktree"
  synth_project=$(canonical_dir "$(meta_value "$synth_meta" project)") || die "invalid synthesis project"
  val_project=$(canonical_dir "$(meta_value "$val_meta" project)") || die "invalid validator project"
  [ "$synth_project" = "$val_project" ] || die "synthesis and validator projects differ"
  [ "$synth_wt" != "$synth_project" ] || die "synthesis worktree is the primary checkout"
  [ "$val_wt" != "$val_project" ] || die "validator worktree is the primary checkout"
  synth_base=$(task_base "$synth_meta" "$synth_wt") || die "cannot resolve synthesis base"
  val_base=$(task_base "$val_meta" "$val_wt") || die "cannot resolve validator base"
  [ "$synth_base" = "$val_base" ] || die "synthesis and validator bases differ"
  [ "$(git -C "$synth_wt" rev-parse HEAD)" = "$synth_base" ] || die "synthesis worktree is not at its recorded base"
  [ "$(git -C "$val_wt" rev-parse HEAD)" = "$val_base" ] || die "validator worktree is not at its recorded base"
  [ -z "$(git -C "$val_wt" status --porcelain)" ] || die "validator worktree must be clean before sealing"
  validate_test_patch "$val_project" "$patch"
  git -C "$val_wt" apply --check "$patch" >/dev/null 2>&1 || die "gate patch does not apply to the validator base"

  local parent="$DATA/$synthesis/fusion-gate" pkg output argv_tmp rc stage digest_tool
  pkg="$parent/v1"
  mkdir -p "$parent"
  output=$(mktemp "${TMPDIR:-/tmp}/fm-fusion-red.XXXXXX")
  argv_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fusion-argv.XXXXXX")
  write_argv "$argv_tmp" "$@"

  if [ -d "$parent/v1" ]; then
    verify_package "$synthesis" >/dev/null
    if cmp -s "$patch" "$parent/v1/gate.patch" && cmp -s "$argv_tmp" "$parent/v1/argv"; then
      rm -f "$output" "$argv_tmp"
      echo "sealed: $synthesis fusion gate already matches v1"
      return 0
    fi
    rm -f "$output" "$argv_tmp"
    die "fusion gate v1 already exists with different bytes"
  fi

  git -C "$val_wt" apply "$patch"
  if read_argv_and_run "$argv_tmp" "$val_wt" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if ! git -C "$val_wt" apply -R "$patch"; then
    rm -f "$output" "$argv_tmp"
    die "could not remove the temporary gate patch from the validator worktree"
  fi
  cat "$output"
  if [ "$rc" -eq 0 ]; then
    rm -f "$output" "$argv_tmp"
    die "validator gate passed on the untouched base; expected an observable red result"
  fi

  stage=$(mktemp -d "$parent/.v1.tmp.XXXXXX")
  cp "$patch" "$stage/gate.patch"
  cp "$argv_tmp" "$stage/argv"
  cp "$output" "$stage/red-output.log"
  {
    echo "version=1"
    echo "synthesis=$synthesis"
    echo "validator=$validator"
    echo "project=$synth_project"
    echo "base=$synth_base"
    echo "validator_harness=$(meta_value "$val_meta" harness)"
    echo "validator_model=$(meta_value "$val_meta" model)"
    echo "red_exit=$rc"
  } > "$stage/manifest"
  digest_tool=$(sha256_tool)
  (
    cd "$stage"
    sha256_files "$digest_tool" gate.patch argv manifest red-output.log > seal.sha256
  )
  chmod 0444 "$stage"/*
  mv "$stage" "$pkg"
  rm -f "$output" "$argv_tmp"
  echo "sealed: $synthesis fusion gate v1 (baseline red exit=$rc)"
}

verify_gate() {
  local synthesis=${1:-}
  [ "$#" -eq 1 ] || die "verify requires exactly one synthesis task id"
  valid_id "$synthesis" || die "invalid synthesis task id"
  verify_package "$synthesis" >/dev/null
  echo "verified: $synthesis fusion gate v1"
}

run_gate() {
  local synthesis=${1:-} requested_wt=${2:-}
  shift 2 || true
  [ "${1:-}" = --expect ] || die "run requires --expect red|green"
  local expected=${2:-}
  [ "$#" -eq 2 ] || die "run accepts only --expect red|green after the worktree"
  case "$expected" in red|green) ;; *) die "--expect must be red or green" ;; esac
  valid_id "$synthesis" || die "invalid synthesis task id"

  local pkg manifest project base worktree top output rc reverse_ok=1
  pkg=$(verify_package "$synthesis")
  manifest="$pkg/manifest"
  project=$(canonical_dir "$(manifest_value "$manifest" project)") || die "invalid sealed project"
  base=$(manifest_value "$manifest" base)
  worktree=$(canonical_dir "$requested_wt") || die "invalid builder worktree"
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || die "builder target is not a git worktree"
  top=$(canonical_dir "$top") || die "cannot resolve builder worktree root"
  [ "$top" = "$worktree" ] || die "builder target must be the worktree root"
  [ "$worktree" != "$project" ] || die "fusion gate refuses the primary checkout"
  [ "$(git -C "$worktree" rev-parse HEAD 2>/dev/null)" = "$base" ] || die "builder worktree is not at the sealed base"
  git -C "$worktree" apply --check "$pkg/gate.patch" >/dev/null 2>&1 \
    || die "sealed gate patch does not apply cleanly to the builder worktree"
  git -C "$worktree" apply "$pkg/gate.patch"
  git -C "$worktree" apply -R --check "$pkg/gate.patch" >/dev/null 2>&1 \
    || die "applied gate bytes do not match the seal"

  output=$(mktemp "${TMPDIR:-/tmp}/fm-fusion-run.XXXXXX")
  if read_argv_and_run "$pkg/argv" "$worktree" > "$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  git -C "$worktree" apply -R --check "$pkg/gate.patch" >/dev/null 2>&1 || reverse_ok=0
  if [ "$reverse_ok" -eq 1 ]; then
    git -C "$worktree" apply -R "$pkg/gate.patch"
  fi
  cat "$output"
  rm -f "$output"
  [ "$reverse_ok" -eq 1 ] || die "gate-managed test bytes changed during execution"

  if [ "$expected" = red ]; then
    [ "$rc" -ne 0 ] || die "fusion gate unexpectedly passed; expected red"
  else
    [ "$rc" -eq 0 ] || die "fusion gate failed; expected green"
  fi
  echo "gate: $synthesis expected=$expected observed_exit=$rc"
}

case "${1:-}" in
  -h|--help) usage ;;
  seal) shift; seal_gate "$@" ;;
  verify) shift; verify_gate "$@" ;;
  run) shift; run_gate "$@" ;;
  *) usage >&2; exit 1 ;;
esac
