#!/usr/bin/env bash
# fm-prototype.sh - deterministic lifecycle boundaries for question-first prototypes.
#
# A prototype is an ordinary scout subtype, identified by data/<task-id>/prototype.json.
# `register` must run before spawn with one non-empty, one-line question and exactly
# one class: ui or logic-state. Repeating the identical registration is idempotent;
# a conflicting registration fails without rewriting the original.
#
# Every manifest uses schema fm-prototype.v1:
#   schema: "fm-prototype.v1"
#   class: "ui" | "logic-state"
#   question: the explicit uncertainty
#   safety.fixtures: "synthetic-or-minimized"
#   safety.persistence: "none"
#   safety.external_side_effects: "none"
#   safety.sensitive_live_access: "forbidden"
#   binding: null, or {worktree, baseline_head, ignored_snapshot[]}
#     ignored_snapshot[]: {path, sha256} for ignored regular files present
#       immediately before launch
#   evidence: null, or {report_sha256, chosen_decision,
#              regression_test_required, regression_test_reason}
#   promotion: null, or {prepared_head, report_sha256, decision_sha256,
#               regression_test_required}
# The safe values are immutable. There is deliberately no allow-sensitive,
# force, assertion, or environment-variable bypass. Live NAS data, production
# accounts/routes, tailnet or remote-access policy, DNS/MX/email control planes,
# subscriptions/billing, credentials, and recovery material stay outside this
# lifecycle and require an existing higher-authority decision route plus a safe
# rescope before any prototype can continue.
#
# `bind` is called by fm-spawn.sh after every backend converges on an isolated
# worktree and after Firstmate writes any tool hook, but before harness launch.
# It records the clean starting HEAD and a content-addressed snapshot of every
# already-ignored file. This is tool-neutral: promotion requires that exact
# snapshot unchanged and rejects every new or modified ignored path.
# `complete` validates data/<task-id>/report.md. Under an exact
# "## Prototype evidence" heading, the report must contain non-empty sections:
#   ### Question
#   ### Classification
#   ### Assumptions
#   ### Alternatives
#   ### Observed evidence
#   ### Chosen decision
#   ### Rejected options
#   ### Unresolved risks
#   ### Expiry or disposal
#   ### Regression-test obligation
# Question and Classification must exactly match registration. The final section
# must be `required: <reason>` or `not-required: <reason>`; `required` is valid
# only for logic-state. Repeating completion over identical report bytes is
# idempotent. Changed evidence replaces the evidence digest and invalidates any
# prior promotion preparation.
#
# `verify` revalidates the evidence and its digest. Scout teardown calls it for
# every marked prototype. `prepare-promotion` additionally requires the original
# bound worktree, detached at its exact baseline HEAD, with no tracked or
# untracked residue and the exact unchanged pre-launch ignored-file snapshot.
# Repeating preparation in the same clean state is idempotent. `promotion-verify`
# repeats every check without mutation and is called by fm-promote.sh.
#
# Usage:
#   fm-prototype.sh register <task-id> <ui|logic-state> <question>
#   fm-prototype.sh check <task-id>
#   fm-prototype.sh bind <task-id> <worktree>
#   fm-prototype.sh complete <task-id>
#   fm-prototype.sh verify <task-id>
#   fm-prototype.sh prepare-promotion <task-id> <worktree>
#   fm-prototype.sh promotion-verify <task-id> <worktree>
#   fm-prototype.sh decision <task-id>
#   fm-prototype.sh regression-obligation <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'fm-prototype: %s\n' "$*" >&2
  exit 1
}

valid_id() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

json_replace() {
  local filter=$1 tmp
  shift
  tmp=$(mktemp "$TASK_DIR/.prototype.XXXXXX")
  if ! jq "$@" "$filter" "$MANIFEST" > "$tmp"; then
    rm -f "$tmp"
    die "could not update prototype manifest"
  fi
  if cmp -s "$tmp" "$MANIFEST"; then
    rm -f "$tmp"
  else
    chmod 600 "$tmp"
    mv "$tmp" "$MANIFEST"
  fi
}

load_task() {
  [ "$#" -eq 1 ] || die "exactly one task id is required"
  ID=$1
  valid_id "$ID" || die "task id must be a non-empty privacy-safe slug: $ID"
  TASK_DIR="$DATA/$ID"
  MANIFEST="$TASK_DIR/prototype.json"
  REPORT="$TASK_DIR/report.md"
  [ ! -L "$TASK_DIR" ] || die "prototype task directory must not be a symlink: $TASK_DIR"
}

validate_manifest() {
  require_jq
  [ ! -L "$MANIFEST" ] || die "prototype manifest must not be a symlink: $MANIFEST"
  [ -f "$MANIFEST" ] || die "no registered prototype for task $ID at $MANIFEST"
  jq -e '
    type == "object"
    and (keys | sort) == [
      "binding",
      "class",
      "evidence",
      "promotion",
      "question",
      "safety",
      "schema"
    ]
    and .schema == "fm-prototype.v1"
    and (.class == "ui" or .class == "logic-state")
    and (.question
      | type == "string"
      and length > 0
      and (contains("\n") | not)
      and (contains("\r") | not)
    )
    and .safety == {
      fixtures: "synthetic-or-minimized",
      persistence: "none",
      external_side_effects: "none",
      sensitive_live_access: "forbidden"
    }
    and (.binding == null or (
      (.binding | keys | sort) == ["baseline_head", "ignored_snapshot", "worktree"]
      and (.binding.worktree | type == "string" and length > 0)
      and (.binding.baseline_head | test("^[0-9a-f]{40,64}$"))
      and (.binding.ignored_snapshot | type == "array")
      and all(.binding.ignored_snapshot[];
        (keys | sort) == ["path", "sha256"]
        and (.path | type == "string" and length > 0)
        and (.sha256 | test("^[0-9a-f]{64}$"))
      )
    ))
    and (.evidence == null or (
      (.evidence | keys | sort) == [
        "chosen_decision",
        "regression_test_reason",
        "regression_test_required",
        "report_sha256"
      ]
      and (.evidence.report_sha256 | test("^[0-9a-f]{64}$"))
      and (.evidence.chosen_decision | type == "string" and length > 0)
      and (.evidence.regression_test_required | type == "boolean")
      and (.evidence.regression_test_reason | type == "string" and length > 0)
    ))
    and (.promotion == null or (
      (.promotion | keys | sort) == [
        "decision_sha256",
        "prepared_head",
        "regression_test_required",
        "report_sha256"
      ]
      and (.promotion.prepared_head | test("^[0-9a-f]{40,64}$"))
      and (.promotion.report_sha256 | test("^[0-9a-f]{64}$"))
      and (.promotion.decision_sha256 | test("^[0-9a-f]{64}$"))
      and (.promotion.regression_test_required | type == "boolean")
    ))
  ' "$MANIFEST" >/dev/null || die "invalid or unsafe prototype manifest: $MANIFEST"
}

trim_blank_lines() {
  awk '
    { rows[NR] = $0 }
    NF { if (!first) first = NR; last = NR }
    END {
      if (!first) exit
      for (i = first; i <= last; i++) print rows[i]
    }
  '
}

evidence_section() {
  local heading=$1
  awk -v wanted="### $heading" '
    $0 == wanted { found = 1; next }
    found && /^### / { exit }
    found { print }
  ' "$REPORT" | trim_blank_lines
}

require_section() {
  local heading=$1 value count
  count=$(grep -Fxc -- "### $heading" "$REPORT" || true)
  [ "$count" -eq 1 ] || die "report must contain exactly one '$heading' prototype evidence section"
  value=$(evidence_section "$heading")
  [ -n "$value" ] || die "report has no non-empty '$heading' prototype evidence section"
  printf '%s\n' "$value"
}

validate_evidence() {
  local registered_question registered_class question classification obligation prefix evidence_heading_count
  [ ! -L "$REPORT" ] || die "prototype report must not be a symlink: $REPORT"
  [ -f "$REPORT" ] || die "prototype report is missing: $REPORT"
  evidence_heading_count=$(grep -Fxc '## Prototype evidence' "$REPORT" || true)
  [ "$evidence_heading_count" -eq 1 ] \
    || die "report must contain exactly one '## Prototype evidence' heading"

  registered_question=$(jq -r '.question' "$MANIFEST")
  registered_class=$(jq -r '.class' "$MANIFEST")
  question=$(require_section "Question")
  classification=$(require_section "Classification")
  [ "$question" = "$registered_question" ] \
    || die "report Question does not exactly match the registered uncertainty"
  [ "$classification" = "$registered_class" ] \
    || die "report Classification does not exactly match the registered class"

  require_section "Assumptions" >/dev/null
  require_section "Alternatives" >/dev/null
  require_section "Observed evidence" >/dev/null
  CHOSEN_DECISION=$(require_section "Chosen decision")
  require_section "Rejected options" >/dev/null
  require_section "Unresolved risks" >/dev/null
  require_section "Expiry or disposal" >/dev/null
  obligation=$(require_section "Regression-test obligation")

  prefix=${obligation%%:*}
  REGRESSION_REASON=${obligation#*:}
  [ "$REGRESSION_REASON" != "$obligation" ] \
    || die "Regression-test obligation must be 'required: <reason>' or 'not-required: <reason>'"
  REGRESSION_REASON=$(printf '%s\n' "$REGRESSION_REASON" | sed 's/^[[:space:]]*//')
  [ -n "$REGRESSION_REASON" ] || die "Regression-test obligation requires a reason"
  case "$prefix" in
    required)
      [ "$registered_class" = logic-state ] \
        || die "only a logic-state prototype may record a required regression test"
      REGRESSION_REQUIRED=true
      ;;
    not-required)
      REGRESSION_REQUIRED=false
      ;;
    *)
      die "Regression-test obligation must be 'required: <reason>' or 'not-required: <reason>'"
      ;;
  esac
}

worktree_residue() {
  local worktree=$1 tracked
  tracked=$(git -C "$worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null) \
    || die "cannot inspect prototype worktree status: $worktree"
  [ -z "$tracked" ] || printf '%s\n' "$tracked"
}

ignored_snapshot() {
  local worktree=$1 ignored path digest rows=
  ignored=$(git -C "$worktree" ls-files --others --ignored --exclude-standard 2>/dev/null) \
    || die "cannot inspect ignored prototype worktree residue: $worktree"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      *$'\t'*) die "ignored prototype path contains a tab and cannot be attested safely: $path" ;;
    esac
    [ ! -L "$worktree/$path" ] && [ -f "$worktree/$path" ] \
      || die "ignored prototype path must be a regular non-symlink file: $path"
    digest=$(sha256_file "$worktree/$path")
    rows="${rows}${rows:+$'\n'}${digest}"$'\t'"${path}"
  done <<EOF
$ignored
EOF
  printf '%s\n' "$rows" | jq -cRn '
    [
      inputs
      | select(length > 0)
      | capture("^(?<sha256>[0-9a-f]{64})\\t(?<path>.*)$")
      | {path, sha256}
    ]
  '
}

assert_clean_baseline() {
  local supplied=$1 bound baseline current branch residue expected_ignored actual_ignored
  supplied=$(canonical_dir "$supplied") || die "worktree does not exist: $1"
  bound=$(jq -r '.binding.worktree // empty' "$MANIFEST")
  baseline=$(jq -r '.binding.baseline_head // empty' "$MANIFEST")
  [ -n "$bound" ] && [ -n "$baseline" ] || die "prototype has not been bound before worker launch"
  [ "$supplied" = "$bound" ] || die "promotion worktree differs from the registered worktree"
  current=$(git -C "$supplied" rev-parse HEAD 2>/dev/null) \
    || die "cannot resolve prototype worktree HEAD"
  [ "$current" = "$baseline" ] \
    || die "prototype worktree is not at its registered baseline HEAD"
  branch=$(git -C "$supplied" symbolic-ref -q --short HEAD 2>/dev/null || true)
  [ -z "$branch" ] || die "prototype worktree must be detached at baseline before promotion"
  residue=$(worktree_residue "$supplied")
  [ -z "$residue" ] || die "prototype worktree still contains experiment residue: $residue"
  expected_ignored=$(jq -c '.binding.ignored_snapshot' "$MANIFEST")
  actual_ignored=$(ignored_snapshot "$supplied")
  [ "$actual_ignored" = "$expected_ignored" ] \
    || die "prototype worktree ignored files differ from the pre-launch snapshot"
}

register_command() {
  local class=$1 question=$2 existing_class existing_question tmp
  case "$class" in
    ui|logic-state) ;;
    *) die "prototype class must be exactly ui or logic-state" ;;
  esac
  [ -n "$question" ] || die "prototype question must not be empty"
  case "$question" in
    *$'\n'*|*$'\r'*) die "prototype question must be one line" ;;
  esac
  require_jq
  [ ! -L "$TASK_DIR" ] || die "prototype task directory must not be a symlink: $TASK_DIR"
  mkdir -p "$TASK_DIR"
  if [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
    validate_manifest
    existing_class=$(jq -r '.class' "$MANIFEST")
    existing_question=$(jq -r '.question' "$MANIFEST")
    [ "$existing_class" = "$class" ] && [ "$existing_question" = "$question" ] \
      || die "prototype is already registered with a different class or question"
    printf 'already registered %s\n' "$ID"
    return 0
  fi
  tmp=$(mktemp "$TASK_DIR/.prototype.XXXXXX")
  jq -n --arg class "$class" --arg question "$question" '{
    schema: "fm-prototype.v1",
    class: $class,
    question: $question,
    safety: {
      fixtures: "synthetic-or-minimized",
      persistence: "none",
      external_side_effects: "none",
      sensitive_live_access: "forbidden"
    },
    binding: null,
    evidence: null,
    promotion: null
  }' > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$MANIFEST"
  printf 'registered %s\n' "$ID"
}

bind_command() {
  local worktree=$1 top baseline existing_worktree existing_baseline residue ignored
  validate_manifest
  worktree=$(canonical_dir "$worktree") || die "worktree does not exist: $1"
  top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) \
    || die "prototype worktree is not a git worktree: $worktree"
  top=$(canonical_dir "$top") || die "cannot resolve prototype worktree root"
  [ "$top" = "$worktree" ] || die "prototype path is not the git worktree root: $worktree"
  baseline=$(git -C "$worktree" rev-parse HEAD 2>/dev/null) \
    || die "cannot resolve prototype baseline HEAD"
  existing_worktree=$(jq -r '.binding.worktree // empty' "$MANIFEST")
  existing_baseline=$(jq -r '.binding.baseline_head // empty' "$MANIFEST")
  if [ -n "$existing_worktree" ] || [ -n "$existing_baseline" ]; then
    [ "$existing_worktree" = "$worktree" ] && [ "$existing_baseline" = "$baseline" ] \
      || die "prototype is already bound to a different worktree or baseline"
    printf 'already bound %s\n' "$ID"
    return 0
  fi
  residue=$(worktree_residue "$worktree")
  [ -z "$residue" ] || die "prototype must start from a clean isolated copy: $residue"
  ignored=$(ignored_snapshot "$worktree")
  # shellcheck disable=SC2016  # jq variables are expanded by jq, not the shell.
  json_replace '.binding = {
    worktree: $worktree,
    baseline_head: $baseline,
    ignored_snapshot: $ignored
  }' \
    --arg worktree "$worktree" --arg baseline "$baseline" --argjson ignored "$ignored"
  printf 'bound %s\n' "$ID"
}

complete_command() {
  local report_digest
  validate_manifest
  [ "$(jq -r '.binding != null' "$MANIFEST")" = true ] \
    || die "prototype must be bound before evidence completion"
  validate_evidence
  report_digest=$(sha256_file "$REPORT")
  # shellcheck disable=SC2016  # jq variables are expanded by jq, not the shell.
  json_replace '
    .evidence = {
      report_sha256: $report_digest,
      chosen_decision: $chosen_decision,
      regression_test_required: $regression_required,
      regression_test_reason: $regression_reason
    }
    | .promotion = null
  ' \
    --arg report_digest "$report_digest" \
    --arg chosen_decision "$CHOSEN_DECISION" \
    --argjson regression_required "$REGRESSION_REQUIRED" \
    --arg regression_reason "$REGRESSION_REASON"
  printf 'completed %s\n' "$ID"
}

verify_command() {
  local expected actual recorded_decision
  validate_manifest
  [ "$(jq -r '.binding != null' "$MANIFEST")" = true ] \
    || die "prototype has not been bound"
  [ "$(jq -r '.evidence != null' "$MANIFEST")" = true ] \
    || die "prototype evidence has not been completed"
  validate_evidence
  expected=$(jq -r '.evidence.report_sha256' "$MANIFEST")
  actual=$(sha256_file "$REPORT")
  [ "$actual" = "$expected" ] || die "prototype report changed after evidence completion"
  recorded_decision=$(jq -r '.evidence.chosen_decision' "$MANIFEST")
  [ "$CHOSEN_DECISION" = "$recorded_decision" ] \
    || die "validated prototype decision no longer matches the manifest"
  [ "$REGRESSION_REQUIRED" = "$(jq -r '.evidence.regression_test_required' "$MANIFEST")" ] \
    || die "regression-test obligation no longer matches the manifest"
}

prepare_promotion_command() {
  local worktree=$1 report_digest decision_digest baseline
  verify_command
  assert_clean_baseline "$worktree"
  report_digest=$(jq -r '.evidence.report_sha256' "$MANIFEST")
  decision_digest=$(sha256_text "$(jq -r '.evidence.chosen_decision' "$MANIFEST")")
  baseline=$(jq -r '.binding.baseline_head' "$MANIFEST")
  # shellcheck disable=SC2016  # jq variables are expanded by jq, not the shell.
  json_replace '
    .promotion = {
      prepared_head: $baseline,
      report_sha256: $report_digest,
      decision_sha256: $decision_digest,
      regression_test_required: .evidence.regression_test_required
    }
  ' \
    --arg baseline "$baseline" \
    --arg report_digest "$report_digest" \
    --arg decision_digest "$decision_digest"
  printf 'promotion prepared %s\n' "$ID"
}

promotion_verify_command() {
  local worktree=$1 expected_report expected_decision actual_decision
  verify_command
  [ "$(jq -r '.promotion != null' "$MANIFEST")" = true ] \
    || die "prototype promotion has not been prepared"
  assert_clean_baseline "$worktree"
  expected_report=$(jq -r '.evidence.report_sha256' "$MANIFEST")
  [ "$expected_report" = "$(jq -r '.promotion.report_sha256' "$MANIFEST")" ] \
    || die "promotion preparation carries stale report evidence"
  actual_decision=$(sha256_text "$(jq -r '.evidence.chosen_decision' "$MANIFEST")")
  expected_decision=$(jq -r '.promotion.decision_sha256' "$MANIFEST")
  [ "$actual_decision" = "$expected_decision" ] \
    || die "promotion preparation carries a stale validated decision"
  [ "$(jq -r '.binding.baseline_head' "$MANIFEST")" = "$(jq -r '.promotion.prepared_head' "$MANIFEST")" ] \
    || die "promotion preparation carries a stale baseline"
  [ "$(jq -r '.evidence.regression_test_required' "$MANIFEST")" = "$(jq -r '.promotion.regression_test_required' "$MANIFEST")" ] \
    || die "promotion preparation carries a stale regression-test obligation"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  register)
    [ "$#" -eq 4 ] || die "usage: fm-prototype.sh register <task-id> <ui|logic-state> <question>"
    load_task "$2"
    register_command "$3" "$4"
    ;;
  check)
    [ "$#" -eq 2 ] || die "usage: fm-prototype.sh check <task-id>"
    load_task "$2"
    validate_manifest
    printf 'registered %s\n' "$ID"
    ;;
  bind)
    [ "$#" -eq 3 ] || die "usage: fm-prototype.sh bind <task-id> <worktree>"
    load_task "$2"
    bind_command "$3"
    ;;
  complete)
    [ "$#" -eq 2 ] || die "usage: fm-prototype.sh complete <task-id>"
    load_task "$2"
    complete_command
    ;;
  verify)
    [ "$#" -eq 2 ] || die "usage: fm-prototype.sh verify <task-id>"
    load_task "$2"
    verify_command
    printf 'verified %s\n' "$ID"
    ;;
  prepare-promotion)
    [ "$#" -eq 3 ] || die "usage: fm-prototype.sh prepare-promotion <task-id> <worktree>"
    load_task "$2"
    prepare_promotion_command "$3"
    ;;
  promotion-verify)
    [ "$#" -eq 3 ] || die "usage: fm-prototype.sh promotion-verify <task-id> <worktree>"
    load_task "$2"
    promotion_verify_command "$3"
    printf 'promotion verified %s\n' "$ID"
    ;;
  decision)
    [ "$#" -eq 2 ] || die "usage: fm-prototype.sh decision <task-id>"
    load_task "$2"
    verify_command
    jq -r '.evidence.chosen_decision' "$MANIFEST"
    ;;
  regression-obligation)
    [ "$#" -eq 2 ] || die "usage: fm-prototype.sh regression-obligation <task-id>"
    load_task "$2"
    verify_command
    if [ "$(jq -r '.evidence.regression_test_required' "$MANIFEST")" = true ]; then
      printf 'required: %s\n' "$(jq -r '.evidence.regression_test_reason' "$MANIFEST")"
    else
      printf 'not-required: %s\n' "$(jq -r '.evidence.regression_test_reason' "$MANIFEST")"
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
