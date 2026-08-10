#!/usr/bin/env bash
# Deterministic structural audit for every tracked Firstmate skill plus the
# seeded skill-admission and contract-failure fixtures.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMISSION_FIXTURES="$ROOT/tests/fixtures/skill-admission"
CONTRACT_FIXTURES="$ROOT/tests/fixtures/skill-contract"
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
  printf 'ok - [structural presence] %s\n' "$1"
}

structural_error() {
  printf 'not ok - [structural presence] %s\n' "$1"
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

agent_trigger_names() {
  local agents=$1
  awk '
    /^## 13\. Agent-only reference skills$/ { section = 1; next }
    section && /^## / { exit }
    section && /^- `[^`]+` -/ {
      line = $0
      sub(/^- `/, "", line)
      sub(/`.*/, "", line)
      print line
    }
  ' "$agents"
}

skill_has_inbound_reference() {
  local root=$1 name=$2 current=$3 other
  while IFS= read -r other; do
    [ "$other" = "$current" ] && continue
    if grep -F -- "\`$name\`" "$root/$other" >/dev/null; then
      return 0
    fi
  done < <(tracked_skill_files "$root")
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
  if [ -n "$explicit" ]; then
    normalize_trigger "$explicit"
    return
  fi
  description=$(frontmatter_description "$file")
  printf '%s\n' "$description" | awk '{
    text = tolower($0)
    gsub(/[[:space:]]+/, " ", text)
    while (match(text, /(use|load) (before|whenever|when|on|after) [^.]+/)) {
      phrase = substr(text, RSTART, RLENGTH)
      sub(/[[:space:].;:]+$/, "", phrase)
      print phrase
      text = substr(text, RSTART + RLENGTH)
    }
  }'
}

extract_local_references() {
  local file=$1
  grep -Eo '(^|[[:space:](`"])(bin|docs|tests|\.agents/skills|skills)/[[:alnum:]_./*?<>-]*' "$file" |
    sed -E 's/^[[:space:](`"]+//' |
    LC_ALL=C sort -u
}

local_reference_exists() {
  local root=$1 reference=$2
  case "$reference" in
    *'<'*|*'>'*) return 0 ;;
    *'*'*|*'?'*) compgen -G "$root/$reference" >/dev/null ;;
    */) [ -d "$root/$reference" ] ;;
    *) [ -e "$root/$reference" ] ;;
  esac
}

validate_receipt_label() {
  local label=$1
  if [ "$label" = "structural presence" ]; then
    structural_ok "SC008 evidence-label: audit receipts identify structural presence and do not claim executed behavior"
    return 0
  fi
  structural_error "SC008 evidence-label: contract audit receipts must say 'structural presence', not '$label'"
  return 1
}

audit_skill_tree() {
  local root=$1 agents="$1/AGENTS.md" failed=0 check_failed=0
  local relative file directory_name declared_name user_invocable internal name
  local count referenced standalone entry trigger owner reference marker
  local trigger_rows trigger_groups phrase names
  local skill_count=0 internal_count=0 public_count=0

  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    skill_count=$((skill_count + 1))
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
  done < <(tracked_skill_files "$root")
  [ "$skill_count" -gt 0 ] || {
    structural_error "SC001 name-parity: no tracked skill files were found"
    check_failed=1
    failed=1
  }
  [ "$check_failed" -ne 0 ] || structural_ok "SC001 name-parity: $skill_count tracked skill directory names match frontmatter"

  check_failed=0
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
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
  done < <(tracked_skill_files "$root")
  [ "$check_failed" -ne 0 ] || structural_ok "SC002 frontmatter-posture: $internal_count internal skills declare invocability and metadata.internal"

  check_failed=0
  if [ ! -f "$agents" ]; then
    structural_error "SC003 trigger-pointer: AGENTS.md is missing"
    check_failed=1
    failed=1
  else
    while IFS= read -r relative; do
      [ -n "$relative" ] || continue
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
    done < <(tracked_skill_files "$root")
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if [ ! -f "$root/.agents/skills/$entry/SKILL.md" ]; then
        structural_error "SC003 trigger-pointer: AGENTS.md trigger '$entry' has no tracked internal skill"
        check_failed=1
        failed=1
      fi
    done < <(agent_trigger_names "$agents")
  fi
  [ "$check_failed" -ne 0 ] || structural_ok "SC003 trigger-pointer: every referenced agent-only skill has one precise AGENTS.md pointer"

  check_failed=0
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in .agents/skills/*) ;; *) continue ;; esac
    file="$root/$relative"
    name=$(basename "$(dirname "$relative")")
    user_invocable=$(frontmatter_scalar "$file" user-invocable)
    standalone=$(frontmatter_scalar "$file" standalone)
    [ -n "$standalone" ] || standalone=$(frontmatter_metadata_scalar "$file" standalone)
    referenced=0
    [ -f "$agents" ] && grep -F -- "\`$name\`" "$agents" >/dev/null && referenced=1
    if [ "$referenced" -eq 0 ] && ! skill_has_inbound_reference "$root" "$name" "$relative" &&
      [ "$user_invocable" != "true" ] && [ "$standalone" != "true" ]; then
      structural_error "SC004 orphan: agent-only skill '$name' has no AGENTS.md reference, inbound skill reference, or standalone posture"
      check_failed=1
      failed=1
    fi
  done < <(tracked_skill_files "$root")
  [ "$check_failed" -ne 0 ] || structural_ok "SC004 orphan: internal skills are reachable or explicitly standalone"

  check_failed=0
  trigger_rows=$(mktemp "$TMP_ROOT/triggers.XXXXXX")
  trigger_groups=$(mktemp "$TMP_ROOT/trigger-groups.XXXXXX")
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    name=$(basename "$(dirname "$relative")")
    owner=$(frontmatter_scalar "$file" trigger-owner)
    [ -n "$owner" ] || owner=$(frontmatter_metadata_scalar "$file" trigger-owner)
    while IFS= read -r trigger; do
      [ -n "$trigger" ] || continue
      printf '%s|%s|%s\n' "$trigger" "$name" "$owner" >> "$trigger_rows"
    done < <(frontmatter_triggers "$file")
  done < <(tracked_skill_files "$root")
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
  [ "$check_failed" -ne 0 ] || structural_ok "SC005 trigger-overlap: explicit frontmatter triggers have no unresolved collisions"

  check_failed=0
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    while IFS= read -r reference; do
      [ -n "$reference" ] || continue
      if ! local_reference_exists "$root" "$reference"; then
        structural_error "SC006 artifact-reachability: $relative references missing local target '$reference'"
        check_failed=1
        failed=1
      fi
    done < <(extract_local_references "$file")
  done < <(tracked_skill_files "$root")
  [ "$check_failed" -ne 0 ] || structural_ok "SC006 artifact-reachability: local script, doc, test, fixture, and skill references resolve"

  check_failed=0
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    marker=$(grep -Eo 'SKILLIFY(_[A-Z0-9]+)*_STUB|SKILL_CONTRACT_STUB|FM_SKILL_STUB' "$file" | head -n 1)
    if [ -n "$marker" ]; then
      structural_error "SC007 stub-sentinel: $relative contains forbidden placeholder marker '$marker'"
      check_failed=1
      failed=1
    fi
  done < <(tracked_skill_files "$root")
  [ "$check_failed" -ne 0 ] || structural_ok "SC007 stub-sentinel: no tracked skill contains a forbidden placeholder marker"

  return "$failed"
}

write_fixture_skill() {
  local file=$1 name=$2 include_internal=$3 trigger=$4 body=${5:-}
  mkdir -p "$(dirname "$file")"
  {
    printf '%s\n' '---'
    printf 'name: %s\n' "$name"
    printf '%s\n' 'description: Fixture capability.'
    printf 'trigger: %s\n' "$trigger"
    printf '%s\n' 'user-invocable: false'
    if [ "$include_internal" = "yes" ]; then
      printf '%s\n' 'metadata:' '  internal: true'
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
      write_fixture_skill "$repo/.agents/skills/beta/SKILL.md" beta yes \
        'load when the fixture alarm fires' 'Use `bin/fixture.sh`.'
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
  local output status=0 label_output label_status=0
  output=$(audit_skill_tree "$ROOT") || status=$?
  printf '%s\n' "$output"
  expect_code 0 "$status" "current tracked skill contract audit"
  label_output=$(validate_receipt_label 'structural presence') || label_status=$?
  printf '%s\n' "$label_output"
  expect_code 0 "$label_status" "current audit evidence label"
}

test_admission_fixtures() {
  local fixture count=0 actual expected route files_created
  for fixture in "$ADMISSION_FIXTURES"/*.fixture; do
    count=$((count + 1))
    actual=$(classify_admission_fixture "$fixture")
    expected="$(fixture_value "$fixture" expected)|$(fixture_value "$fixture" expected-reason)"
    [ "$actual" = "$expected" ] || fail "$(basename "$fixture") classified as '$actual', expected '$expected'"
    route=$(fixture_value "$fixture" route)
    case "$(basename "$fixture"):$route" in
      one-off-helper.fixture:existing-script-or-brief) ;;
      recurring-coherent-capability.fixture:internal-skill) ;;
      multi-intent-proposal.fixture:split-and-reapply) ;;
      *) fail "$(basename "$fixture") has an unexpected admission route '$route'" ;;
    esac
    files_created=$(fixture_value "$fixture" files-created)
    [ "$files_created" = "0" ] || fail "$(basename "$fixture") created a skill before admission completed"
    pass "[rubric fixture] $(basename "$fixture") => $actual via $route"
  done
  [ "$count" -eq 3 ] || fail "expected exactly 3 skill-admission fixtures, found $count"
}

test_contract_failure_fixtures() {
  local fixture mutation expected label repo output status
  local count=0
  for fixture in "$CONTRACT_FIXTURES"/*.fixture; do
    count=$((count + 1))
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
    assert_contains "$output" "not ok - [structural presence] $expected" \
      "$(basename "$fixture") did not emit its specific structural error receipt"
    pass "[seeded failure] $(basename "$fixture") => $expected"
  done
  [ "$count" -eq 8 ] || fail "expected exactly 8 skill-contract failure fixtures, found $count"
}

test_current_skill_contract
test_admission_fixtures
test_contract_failure_fixtures
