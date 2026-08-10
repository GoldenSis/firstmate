#!/usr/bin/env bash
# Deterministic structural audit for every tracked Firstmate skill plus the
# seeded skill-admission and contract-failure fixtures.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMISSION_FIXTURES="$ROOT/tests/fixtures/skill-admission"
CONTRACT_FIXTURES="$ROOT/tests/fixtures/skill-contract"
CODING_GUIDELINES="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
REFERENCE_CHECKER="$ROOT/tests/fm-instruction-reference-integrity.test.sh"
# Single owner of the evidence label both reporters emit and SC008 validates.
RECEIPT_LABEL='structural presence'
CONTRACT_CHECKS='SC001 SC002 SC003 SC004 SC005 SC006 SC007 SC008'
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-skill-contract.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fixture_value() {
  local file=$1 key=$2
  awk -v key="$key" 'index($0, key ":") == 1 {
    value = substr($0, length(key) + 2)
    sub(/^[[:space:]]+/, "", value)
    print value
    exit
  }' "$file"
}

frontmatter_scalar() {
  local file=$1 key=$2
  awk -v key="$key" '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$file"
}

frontmatter_metadata_scalar() {
  local file=$1 key=$2
  awk -v key="$key" '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && /^metadata:[[:space:]]*$/ { metadata = 1; next }
    frontmatter && metadata && /^[^[:space:]]/ { metadata = 0 }
    frontmatter && metadata {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, key ":") == 1) {
        value = substr(line, length(key) + 2)
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$file"
}

frontmatter_description() {
  local file=$1
  awk '
    NR == 1 && $0 == "---" { frontmatter = 1; next }
    frontmatter && $0 == "---" { exit }
    frontmatter && /^description:/ {
      description = 1
      line = $0
      sub(/^description:[[:space:]]*/, "", line)
      if (line != ">-" && line != "|") text = line
      next
    }
    frontmatter && description && /^[[:alnum:]_-]+:/ { description = 0 }
    frontmatter && description {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      text = text " " line
    }
    END {
      gsub(/[[:space:]]+/, " ", text)
      sub(/^ /, "", text)
      sub(/ $/, "", text)
      print text
    }
  ' "$file"
}

tracked_skill_files() {
  local root=$1
  git -C "$root" ls-files |
    grep -E '^(\.agents/skills|skills)/[^/]+/SKILL\.md$' |
    LC_ALL=C sort
}

structural_ok() {
  printf 'ok - [%s] %s\n' "$RECEIPT_LABEL" "$1"
}

structural_error() {
  printf 'not ok - [%s] %s\n' "$RECEIPT_LABEL" "$1"
}

emitted_receipt_labels() {
  printf '%s\n' "$1" | awk -F '[][]' '/^(not )?ok - \[/ { print $2 }' | LC_ALL=C sort -u
}

precise_trigger_count() {
  local agents=$1 name=$2
  awk -v needle="- \`$name\` -" '
    /^## 13\. Agent-only reference skills$/ { section = 1; next }
    section && /^## / { exit }
    section && index($0, needle) == 1 &&
      $0 ~ / - (load|use) (before|when|whenever|on|after) / { count++ }
    END { print count + 0 }
  ' "$agents"
}

skill_has_inbound_reference() {
  local root=$1 name=$2 current=$3 other
  shift 3
  for other in "$@"; do
    [ "$other" = "$current" ] && continue
    if grep -F -- "\`$name\`" "$root/$other" >/dev/null; then
      return 0
    fi
  done
  return 1
}

normalize_trigger() {
  printf '%s\n' "$1" | awk '{
    line = tolower($0)
    gsub(/[[:space:]]+/, " ", line)
    sub(/^[[:space:]]+/, "", line)
    sub(/[[:space:].;:]+$/, "", line)
    print line
  }'
}

frontmatter_triggers() {
  local file=$1 explicit description
  explicit=$(frontmatter_scalar "$file" trigger)
  [ -n "$explicit" ] || explicit=$(frontmatter_metadata_scalar "$file" trigger)
  if [ -n "$explicit" ]; then
    normalize_trigger "$explicit"
    return
  fi
  description=$(frontmatter_description "$file")
  printf '%s\n' "$description" | awk '
    # A trigger clause runs to the end of its sentence. Only a period that
    # actually ends a sentence may cut it: periods inside an abbreviation
    # ("e.g."), a filename ("bin/fm-autonudge.sh"), or an ellipsis ("...") are
    # shielded first, so a clause is never truncated mid-word into a prefix that
    # can collide with an unrelated skill.
    function shield(text,   i, size, char, following, out) {
      size = length(text)
      out = ""
      for (i = 1; i <= size; i++) {
        char = substr(text, i, 1)
        if (char == ".") {
          following = (i < size) ? substr(text, i + 1, 1) : ""
          if (following ~ /[[:alnum:]]/ || following == ".") {
            out = out MARK
            continue
          }
          # A period closing a run already shielded as an abbreviation
          # ("e.g.") or as an ellipsis ("...") belongs to that run too.
          if (length(out) >= 1 && substr(out, length(out), 1) == MARK) {
            out = out MARK
            continue
          }
          if (length(out) >= 2 &&
              substr(out, length(out) - 1, 1) == MARK &&
              substr(out, length(out), 1) ~ /[[:alpha:]]/) {
            out = out MARK
            continue
          }
        }
        out = out char
      }
      return out
    }
    BEGIN { MARK = "\001" }
    {
      text = shield(tolower($0))
      gsub(/[[:space:]]+/, " ", text)
      while (match(text, /(use|load) (before|whenever|when|on|after) [^.]+/)) {
        phrase = substr(text, RSTART, RLENGTH)
        sub(/[[:space:].;:]+$/, "", phrase)
        gsub(MARK, ".", phrase)
        print phrase
        text = substr(text, RSTART + RLENGTH)
      }
    }'
}

# Literal-reference resolution is owned by tests/fm-instruction-reference-integrity.test.sh
# (fenced-code, example-line, placeholder, glob, and case handling included).
# SC006 delegates to it and only translates its diagnostics into audit receipts.
# The delegate exits 0 when clean and 1 when it reported diagnostics; any other
# status means the delegation itself is broken and must not be read as findings.
skill_reference_diagnostics() {
  local root=$1 destination=$2
  shift 2
  /bin/bash "$REFERENCE_CHECKER" --check-files "$root" "$@" > "$destination" 2>&1
}

validate_receipt_label() {
  local label=$1
  if [ "$label" = "$RECEIPT_LABEL" ]; then
    structural_ok "SC008 evidence-label: audit receipts identify $RECEIPT_LABEL and do not claim executed behavior"
    return 0
  fi
  structural_error "SC008 evidence-label: contract audit receipts must say '$RECEIPT_LABEL', not '$label'"
  return 1
}

audit_skill_tree() {
  local root=$1 agents="$1/AGENTS.md" failed=0 check_failed=0
  local relative file directory_name declared_name user_invocable internal name
  local count referenced standalone trigger owner marker
  local trigger_rows trigger_groups phrase names
  local diagnostic_line reference_file reference_literal reference_message
  local reference_output reference_status
  local -a skill_files=()
  local skill_count=0 internal_count=0 public_count=0

  # The tracked skill list cannot change mid-audit, so resolve it once and let
  # every check iterate the same materialized set.
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    skill_files+=("$relative")
  done < <(tracked_skill_files "$root")
  skill_count=${#skill_files[@]}

  for relative in "${skill_files[@]+"${skill_files[@]}"}"; do
    file="$root/$relative"
    directory_name=$(basename "$(dirname "$relative")")
    declared_name=$(frontmatter_scalar "$file" name)
    if [ "$directory_name" != "$declared_name" ]; then
      structural_error "SC001 name-parity: $relative directory name '$directory_name' does not match frontmatter name '$declared_name'"
      check_failed=1
      failed=1
    fi
    case "$relative" in
      .agents/skills/*) internal_count=$((internal_count + 1)) ;;
      skills/*) public_count=$((public_count + 1)) ;;
    esac
  done
  [ "$skill_count" -gt 0 ] || {
    structural_error "SC001 name-parity: no tracked skill files were found"
    check_failed=1
    failed=1
  }
  [ "$check_failed" -ne 0 ] || structural_ok "SC001 name-parity: $skill_count tracked skill directory names match frontmatter"

  check_failed=0
  for relative in "${skill_files[@]+"${skill_files[@]}"}"; do
    case "$relative" in .agents/skills/*) ;; *) continue ;; esac
    file="$root/$relative"
    user_invocable=$(frontmatter_scalar "$file" user-invocable)
    internal=$(frontmatter_metadata_scalar "$file" internal)
    case "$user_invocable" in
      true|false) ;;
      *)
        structural_error "SC002 frontmatter-posture: $relative must declare user-invocable: true or false"
        check_failed=1
        failed=1
        ;;
    esac
    if [ "$internal" != "true" ]; then
      structural_error "SC002 frontmatter-posture: $relative must declare metadata.internal: true"
      check_failed=1
      failed=1
    fi
  done
  [ "$check_failed" -ne 0 ] || structural_ok "SC002 frontmatter-posture: $internal_count internal skills declare invocability and metadata.internal"

  check_failed=0
  if [ ! -f "$agents" ]; then
    structural_error "SC003 trigger-pointer: AGENTS.md is missing"
    check_failed=1
    failed=1
  else
    for relative in "${skill_files[@]+"${skill_files[@]}"}"; do
      case "$relative" in .agents/skills/*) ;; *) continue ;; esac
      file="$root/$relative"
      user_invocable=$(frontmatter_scalar "$file" user-invocable)
      [ "$user_invocable" = "false" ] || continue
      name=$(basename "$(dirname "$relative")")
      referenced=0
      grep -F -- "\`$name\`" "$agents" >/dev/null && referenced=1
      [ "$referenced" -eq 1 ] || continue
      count=$(precise_trigger_count "$agents" "$name")
      if [ "$count" -ne 1 ]; then
        structural_error "SC003 trigger-pointer: agent-only skill '$name' is referenced from AGENTS.md but has $count precise trigger pointers"
        check_failed=1
        failed=1
      fi
    done
  fi
  [ "$check_failed" -ne 0 ] || structural_ok "SC003 trigger-pointer: every referenced agent-only skill has one precise AGENTS.md pointer"

  check_failed=0
  for relative in "${skill_files[@]+"${skill_files[@]}"}"; do
    case "$relative" in .agents/skills/*) ;; *) continue ;; esac
    file="$root/$relative"
    name=$(basename "$(dirname "$relative")")
    user_invocable=$(frontmatter_scalar "$file" user-invocable)
    standalone=$(frontmatter_scalar "$file" standalone)
    [ -n "$standalone" ] || standalone=$(frontmatter_metadata_scalar "$file" standalone)
    referenced=0
    [ -f "$agents" ] && grep -F -- "\`$name\`" "$agents" >/dev/null && referenced=1
    if [ "$referenced" -eq 0 ] &&
      ! skill_has_inbound_reference "$root" "$name" "$relative" "${skill_files[@]}" &&
      [ "$user_invocable" != "true" ] && [ "$standalone" != "true" ]; then
      structural_error "SC004 orphan: agent-only skill '$name' has no AGENTS.md reference, inbound skill reference, or standalone posture"
      check_failed=1
      failed=1
    fi
  done
  [ "$check_failed" -ne 0 ] || structural_ok "SC004 orphan: internal skills are reachable or explicitly standalone"

  check_failed=0
  trigger_rows=$(mktemp "$TMP_ROOT/triggers.XXXXXX")
  trigger_groups=$(mktemp "$TMP_ROOT/trigger-groups.XXXXXX")
  for relative in "${skill_files[@]+"${skill_files[@]}"}"; do
    file="$root/$relative"
    name=$(basename "$(dirname "$relative")")
    owner=$(frontmatter_scalar "$file" trigger-owner)
    [ -n "$owner" ] || owner=$(frontmatter_metadata_scalar "$file" trigger-owner)
    while IFS= read -r trigger; do
      [ -n "$trigger" ] || continue
      printf '%s|%s|%s\n' "$trigger" "$name" "$owner" >> "$trigger_rows"
    done < <(frontmatter_triggers "$file")
  done
  LC_ALL=C sort -u "$trigger_rows" | awk -F '|' '
    function flush() {
      if (count > 1 && !resolved) print phrase "|" names
    }
    {
      if (NR > 1 && $1 != phrase) flush()
      if ($1 != phrase) {
        phrase = $1
        names = $2
        count = 1
        shared_owner = $3
        resolved = ($3 != "")
      } else {
        names = names "," $2
        count++
        if ($3 == "" || $3 != shared_owner) resolved = 0
      }
    }
    END { if (NR > 0) flush() }
  ' > "$trigger_groups"
  while IFS='|' read -r phrase names; do
    [ -n "$phrase" ] || continue
    structural_error "SC005 trigger-overlap: trigger '$phrase' is claimed by $names without one shared trigger-owner"
    check_failed=1
    failed=1
  done < "$trigger_groups"
  [ "$check_failed" -ne 0 ] || structural_ok "SC005 trigger-overlap: declared and description-derived triggers have no unresolved collisions"

  check_failed=0
  if [ "$skill_count" -gt 0 ]; then
    reference_output=$(mktemp "$TMP_ROOT/references.XXXXXX")
    reference_status=0
    skill_reference_diagnostics "$root" "$reference_output" "${skill_files[@]}" ||
      reference_status=$?
    if [ "$reference_status" -gt 1 ]; then
      structural_error "SC006 artifact-reachability: the reference resolver could not run (exit $reference_status): $(tr '\n' ' ' < "$reference_output")"
      check_failed=1
      failed=1
    else
      while IFS= read -r diagnostic_line; do
        [ -n "$diagnostic_line" ] || continue
        IFS=: read -r reference_file _ reference_literal reference_message <<< "$diagnostic_line"
        reference_literal=${reference_literal# }
        reference_message=${reference_message# }
        case "$reference_message" in
          'case does not match'*)
            structural_error "SC006 artifact-reachability: $reference_file references local target '$reference_literal' with a different tracked case"
            ;;
          'no exact tracked target')
            structural_error "SC006 artifact-reachability: $reference_file references missing local target '$reference_literal'"
            ;;
          'missing file')
            structural_error "SC006 artifact-reachability: tracked skill file $reference_file is absent from the working tree"
            ;;
          'cannot read the tracked-file index')
            structural_error "SC006 artifact-reachability: the reference resolver could not read the tracked-file index"
            ;;
          *)
            structural_error "SC006 artifact-reachability: the reference resolver emitted an unrecognized diagnostic '$diagnostic_line'"
            ;;
        esac
        check_failed=1
        failed=1
      done < "$reference_output"
    fi
  fi
  [ "$check_failed" -ne 0 ] || structural_ok "SC006 artifact-reachability: local script, doc, test, fixture, and skill references resolve"

  check_failed=0
  for relative in "${skill_files[@]+"${skill_files[@]}"}"; do
    file="$root/$relative"
    marker=$(grep -Eo 'SKILLIFY(_[A-Z0-9]+)*_STUB|SKILL_CONTRACT_STUB|FM_SKILL_STUB' "$file" | head -n 1)
    if [ -n "$marker" ]; then
      structural_error "SC007 stub-sentinel: $relative contains forbidden placeholder marker '$marker'"
      check_failed=1
      failed=1
    fi
  done
  [ "$check_failed" -ne 0 ] || structural_ok "SC007 stub-sentinel: no tracked skill contains a forbidden placeholder marker"

  return "$failed"
}

# `placement` selects where the explicit trigger is declared. Both placements
# are documented escapes, so the fixtures exercise each one.
write_fixture_skill() {
  local file=$1 name=$2 include_internal=$3 trigger=$4 body=${5:-} placement=${6:-frontmatter}
  mkdir -p "$(dirname "$file")"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf '%s\n' 'description: Fixture capability.'
    if [ "$placement" = "frontmatter" ]; then
      printf 'trigger: %s\n' "$trigger"
    fi
    printf '%s\n' 'user-invocable: false'
    if [ "$include_internal" = "yes" ]; then
      printf '%s\n' 'metadata:' '  internal: true'
      if [ "$placement" = "metadata" ]; then
        printf '  trigger: %s\n' "$trigger"
      fi
    fi
    printf '%s\n\n# %s\n\n%s\n' '---' "$name" "$body"
  } > "$file"
}

write_fixture_agents() {
  local file=$1
  shift
  {
    printf '%s\n\n' '# Fixture instructions'
    printf '%s\n\n' '## 13. Agent-only reference skills'
    while [ "$#" -gt 0 ]; do
      printf -- '- `%s` - load when the %s fixture runs.\n' "$1" "$1"
      shift
    done
    printf '%s\n' '' '## 14. End'
  } > "$file"
}

make_contract_fixture() {
  local repo=$1 mutation=$2
  mkdir -p "$repo/bin" "$repo/docs" "$repo/tests"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fixture.sh"
  printf '# Fixture\n' > "$repo/docs/fixture.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/fixture.test.sh"
  write_fixture_skill "$repo/.agents/skills/alpha/SKILL.md" alpha yes \
    'load when the alpha fixture runs' 'Use `bin/fixture.sh`.'
  write_fixture_agents "$repo/AGENTS.md" alpha

  case "$mutation" in
    none) ;;
    mismatched-name)
      write_fixture_skill "$repo/.agents/skills/alpha/SKILL.md" beta yes \
        'load when the alpha fixture runs' 'Use `bin/fixture.sh`.'
      ;;
    missing-internal-metadata)
      write_fixture_skill "$repo/.agents/skills/alpha/SKILL.md" alpha no \
        'load when the alpha fixture runs' 'Use `bin/fixture.sh`.'
      ;;
    missing-trigger-pointer)
      printf '# Fixture instructions\n\nThe `alpha` skill owns this fixture.\n' > "$repo/AGENTS.md"
      ;;
    orphan-skill)
      printf '# Fixture instructions\n' > "$repo/AGENTS.md"
      ;;
    duplicate-trigger)
      write_fixture_skill "$repo/.agents/skills/alpha/SKILL.md" alpha yes \
        'load when the fixture alarm fires' 'Use `bin/fixture.sh`.'
      # beta declares the same trigger under `metadata:`, so the collision only
      # surfaces while both declared placements are honored.
      write_fixture_skill "$repo/.agents/skills/beta/SKILL.md" beta yes \
        'load when the fixture alarm fires' 'Use `bin/fixture.sh`.' metadata
      write_fixture_agents "$repo/AGENTS.md" alpha beta
      ;;
    stale-artifact)
      write_fixture_skill "$repo/.agents/skills/alpha/SKILL.md" alpha yes \
        'load when the alpha fixture runs' 'Read `docs/missing.md`.'
      ;;
    stub-sentinel)
      write_fixture_skill "$repo/.agents/skills/alpha/SKILL.md" alpha yes \
        'load when the alpha fixture runs' 'SKILLIFY_STUB'
      ;;
    *) fail "unknown skill-contract fixture mutation '$mutation'" ;;
  esac

  git -C "$repo" init -q
  git -C "$repo" add -A
}

classify_admission_fixture() {
  local file=$1 contexts durable_lines trigger_clear intents target_owner
  local harnesses backends name_kind readable override
  contexts=$(fixture_value "$file" contexts)
  durable_lines=$(fixture_value "$file" durable-lines)
  trigger_clear=$(fixture_value "$file" trigger-clear)
  intents=$(fixture_value "$file" intents)
  target_owner=$(fixture_value "$file" target-owner)
  harnesses=$(fixture_value "$file" harnesses)
  backends=$(fixture_value "$file" backends)
  name_kind=$(fixture_value "$file" name-kind)
  readable=$(fixture_value "$file" readable)
  override=$(fixture_value "$file" non-triviality-override)

  if [ "$contexts" -lt 2 ]; then
    printf '%s\n' 'non-skill|recurrence'
  elif [ "$durable_lines" -lt 20 ] && [ -z "$override" ]; then
    printf '%s\n' 'non-skill|non-triviality'
  elif [ "$trigger_clear" != "true" ]; then
    printf '%s\n' 'non-skill|clear-trigger'
  elif [ "$intents" -ne 1 ]; then
    printf '%s\n' 'refused-and-split|one-coherent-capability'
  elif [ -z "$target_owner" ] || [ -z "$harnesses" ] || [ -z "$backends" ]; then
    printf '%s\n' 'non-skill|named-target'
  elif [ "$name_kind" != "job" ]; then
    printf '%s\n' 'non-skill|job-not-tool'
  elif [ "$readable" != "true" ]; then
    printf '%s\n' 'needs-revision|smart-intern-readability'
  else
    printf '%s\n' 'skill-worthy|gates-passed'
  fi
}

test_current_skill_contract() {
  local output status=0 label_output label_status=0 emitted
  output=$(audit_skill_tree "$ROOT") || status=$?
  printf '%s\n' "$output"
  expect_code 0 "$status" "current tracked skill contract audit"
  assert_contains "$output" "ok - [$RECEIPT_LABEL] SC001 name-parity:" \
    "audit receipts no longer carry the structural-presence evidence label"
  # SC008 validates the label the reporters actually emitted, not a literal.
  emitted=$(emitted_receipt_labels "$output")
  [ -n "$emitted" ] || fail "current audit emitted no labelled receipts"
  label_output=$(validate_receipt_label "$emitted") || label_status=$?
  printf '%s\n' "$label_output"
  expect_code 0 "$label_status" "current audit evidence label"
}

# The fixtures below only pin routing decisions. This test pins the prose the
# fixtures encode, so weakening, reordering, or deleting the rubric fails here
# instead of passing silently against a shell reimplementation of itself.
test_admission_rubric_owner() {
  local phrase
  for phrase in \
    'Skill creation is fail-closed: the default answer is "not a skill" until every admission gate passes.' \
    '1. **Recurrence.**' \
    '2. **Non-triviality.**' \
    '3. **Clear trigger phrase.**' \
    '4. **One coherent capability.**' \
    '5. **Named target.**' \
    '6. **Job-not-tool naming.**' \
    'Only after gates 1 through 6 pass, ask whether a smart intern can follow the procedure without hidden context.' \
    'it never supplies authority, safety, permissions, tests, or failure paths and never substitutes for any of them.' \
    'One-off mechanics go to an existing script under `bin/` or to a brief section, not to a new skill.' \
    'Reusable procedures with no clear trigger go to `docs/`, not to a skill.' \
    'Multi-intent proposals are split first, then each proposed skill starts again at gate 1.' \
    'It must never write a live skill from `/stow` or from a task-completion path.'; do
    assert_grep "$phrase" "$CODING_GUIDELINES" "skill-admission rubric lost '$phrase'"
  done
  for phrase in \
    '`trigger:` declares the load condition' \
    '`trigger-owner:` names the single skill that owns a trigger phrase' \
    '`standalone: true` records that a skill is deliberately reachable'; do
    assert_grep "$phrase" "$CODING_GUIDELINES" "skill-admission rubric does not document the audit escape '$phrase'"
  done
  assert_grep 'materially expanding an existing skill' "$CODING_GUIDELINES" \
    "skill-admission rubric no longer scopes the gates to creation and scope expansion"
  pass "skill-admission rubric owns six gates, the fail-closed default, its routes, and its declared escapes"
}

test_admission_fixtures() {
  local fixture count=0 actual expected route files_created reason
  for fixture in "$ADMISSION_FIXTURES"/*.fixture; do
    count=$((count + 1))
    actual=$(classify_admission_fixture "$fixture")
    expected="$(fixture_value "$fixture" expected)|$(fixture_value "$fixture" expected-reason)"
    [ "$actual" = "$expected" ] || fail "$(basename "$fixture") classified as '$actual', expected '$expected'"
    route=$(fixture_value "$fixture" route)
    case "$(basename "$fixture"):$route" in
      one-off-helper.fixture:existing-script-or-brief) ;;
      trivial-recurring-helper.fixture:existing-script-or-brief) ;;
      recurring-coherent-capability.fixture:internal-skill) ;;
      recorded-non-triviality-override.fixture:internal-skill) ;;
      triggerless-reusable-procedure.fixture:docs-procedure) ;;
      multi-intent-proposal.fixture:split-and-reapply) ;;
      unnamed-target-owner.fixture:name-target-and-reapply) ;;
      unnamed-harness-axis.fixture:name-target-and-reapply) ;;
      unnamed-backend-axis.fixture:name-target-and-reapply) ;;
      tool-named-proposal.fixture:rename-and-reapply) ;;
      hidden-context-procedure.fixture:revise-and-reapply) ;;
      *) fail "$(basename "$fixture") has an unexpected admission route '$route'" ;;
    esac
    files_created=$(fixture_value "$fixture" files-created)
    [ "$files_created" = "0" ] || fail "$(basename "$fixture") created a skill before admission completed"
    pass "[rubric fixture] $(basename "$fixture") => $actual via $route"
  done
  [ "$count" -eq 11 ] || fail "expected exactly 11 skill-admission fixtures, found $count"

  # The override fixture is only meaningful while it stays under the gate-2
  # line-count threshold it is exempting itself from.
  fixture="$ADMISSION_FIXTURES/recorded-non-triviality-override.fixture"
  [ "$(fixture_value "$fixture" durable-lines)" -lt 20 ] ||
    fail "recorded-non-triviality-override.fixture no longer exercises the gate-2 override"
  [ -n "$(fixture_value "$fixture" non-triviality-override)" ] ||
    fail "recorded-non-triviality-override.fixture records no override reason"

  # Every classifier outcome must be reachable, so a deleted or inverted gate
  # fails here instead of leaving a branch nothing exercises.
  for reason in recurrence non-triviality clear-trigger one-coherent-capability \
    named-target job-not-tool smart-intern-readability gates-passed; do
    grep -Fqx "expected-reason: $reason" "$ADMISSION_FIXTURES"/*.fixture ||
      fail "no skill-admission fixture exercises the '$reason' gate outcome"
  done
}

# Control for the shared fixture builders: an unmutated fixture repo must be
# fully clean. Without it, drift in write_fixture_skill / write_fixture_agents
# would add a spurious receipt to every seeded case and still look green.
test_clean_contract_fixture() {
  local repo="$TMP_ROOT/clean-baseline" output status=0
  make_contract_fixture "$repo" none
  output=$(audit_skill_tree "$repo") || status=$?
  printf '%s\n' "$output"
  expect_code 0 "$status" "unmutated skill-contract fixture"
  assert_not_contains "$output" "not ok - [$RECEIPT_LABEL] " \
    "unmutated skill-contract fixture emitted a structural failure receipt"
  pass "[clean control] unmutated skill-contract fixture emits only passing receipts"
}

test_contract_failure_fixtures() {
  local fixture check mutation expected label repo output status other
  local count=0
  for fixture in "$CONTRACT_FIXTURES"/*.fixture; do
    count=$((count + 1))
    check=$(fixture_value "$fixture" check)
    mutation=$(fixture_value "$fixture" mutation)
    expected=$(fixture_value "$fixture" expected-receipt)
    status=0
    if [ "$mutation" = "false-behavioral-claim" ]; then
      label=$(fixture_value "$fixture" receipt-label)
      output=$(validate_receipt_label "$label") || status=$?
    else
      repo="$TMP_ROOT/$mutation"
      make_contract_fixture "$repo" "$mutation"
      output=$(audit_skill_tree "$repo") || status=$?
    fi
    [ "$status" -ne 0 ] || fail "$(basename "$fixture") did not fail"
    assert_contains "$output" "not ok - [$RECEIPT_LABEL] $expected" \
      "$(basename "$fixture") did not emit its specific structural error receipt"
    # One seeded defect must produce exactly one failing check.
    for other in $CONTRACT_CHECKS; do
      [ "$other" = "$check" ] && continue
      assert_not_contains "$output" "not ok - [$RECEIPT_LABEL] $other " \
        "$(basename "$fixture") also failed $other, so its receipt is not isolated"
    done
    pass "[seeded failure] $(basename "$fixture") => $expected"
  done
  [ "$count" -eq 8 ] || fail "expected exactly 8 skill-contract failure fixtures, found $count"
}

test_current_skill_contract
test_admission_rubric_owner
test_admission_fixtures
test_clean_contract_fixture
test_contract_failure_fixtures
