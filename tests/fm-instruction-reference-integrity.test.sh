#!/usr/bin/env bash
# Deterministic integrity gate for literal repo-owned routing references in the
# always-loaded Firstmate instruction surface.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKER="$ROOT/tests/fm-instruction-reference-integrity.test.sh"

diagnostic() {
  printf '%s:%s: %s: %s\n' "$1" "$2" "$3" "$4" >&2
}

tracked_resolves_exactly() {
  local tracked=$1 literal=$2 path
  path=${literal%/}
  printf '%s\n' "$tracked" | awk -v path="$path" '
    $0 == path || index($0, path "/") == 1 { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

tracked_resolves_ignoring_case() {
  local tracked=$1 literal=$2 path
  path=${literal%/}
  printf '%s\n' "$tracked" | awk -v path="$path" '
    BEGIN { path = tolower(path) }
    {
      candidate = tolower($0)
      if (candidate == path || index(candidate, path "/") == 1) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

extract_literal_references() {
  local agents=$1
  awk '
    function emit(line_number, literal) {
      sub(/^[[:space:]]+/, "", literal)
      sub(/[[:space:]]+$/, "", literal)
      if (literal == "" || literal ~ /[<>{}*?\[\]]/) {
        return
      }
      if (literal ~ /^https?:\/\// ||
          literal ~ /^(data|state|config|projects)\//) {
        return
      }
      if (literal ~ /^(bin|docs|tests)\// ||
          literal ~ /^\.agents\/skills\// ||
          literal ~ /^\.github\/workflows\// ||
          literal == "AGENTS.md" ||
          literal == "CLAUDE.md" ||
          literal == "CONTRIBUTING.md" ||
          literal == "LICENSE" ||
          literal == "README.md" ||
          literal == ".gitignore" ||
          literal == ".no-mistakes.yaml" ||
          literal == ".tasks.toml") {
        print line_number "\t" literal
      }
    }

    /^[[:space:]]*(```|~~~)/ {
      fenced = !fenced
      next
    }
    fenced {
      next
    }
    tolower($0) ~ /^[[:space:]]*(for example|example|examples|e\.g\.)[,:[:space:]]/ {
      next
    }
    {
      count = split($0, spans, "`")
      for (i = 2; i <= count; i += 2) {
        emit(NR, spans[i])
      }
    }
  ' "$agents"
}

extract_internal_skill_triggers() {
  local agents=$1
  awk '
    /^## 13\. Agent-only reference skills$/ {
      in_skills = 1
      next
    }
    in_skills && /^## / {
      exit
    }
    in_skills && /^- `[^`]+` - / {
      count = split($0, spans, "`")
      if (count >= 3 && spans[2] !~ /[<>{}*?\[\]\/]/) {
        print NR "\t" spans[2]
      }
    }
  ' "$agents"
}

check_instruction_references() {
  local repo=$1 agents="$1/AGENTS.md" claude="$1/CLAUDE.md"
  local tracked line literal skill target failed=0

  tracked=$(git -C "$repo" ls-files 2>/dev/null) || {
    diagnostic "AGENTS.md" 1 "AGENTS.md" "cannot read the tracked-file index"
    return 1
  }

  if [ ! -f "$agents" ]; then
    diagnostic "AGENTS.md" 1 "AGENTS.md" "missing always-loaded instruction file"
    failed=1
  elif ! tracked_resolves_exactly "$tracked" "AGENTS.md"; then
    diagnostic "AGENTS.md" 1 "AGENTS.md" "instruction file is not tracked with exact spelling and case"
    failed=1
  fi

  if [ ! -e "$claude" ] && [ ! -L "$claude" ]; then
    diagnostic "CLAUDE.md" 1 "CLAUDE.md" "missing symlink; expected exact target AGENTS.md"
    failed=1
  elif [ ! -L "$claude" ]; then
    diagnostic "CLAUDE.md" 1 "CLAUDE.md" "not a symlink; expected exact target AGENTS.md"
    failed=1
  elif [ "$(readlink "$claude")" != "AGENTS.md" ]; then
    diagnostic "CLAUDE.md" 1 "CLAUDE.md" "wrong symlink target; expected exact target AGENTS.md"
    failed=1
  fi
  if ! tracked_resolves_exactly "$tracked" "CLAUDE.md"; then
    diagnostic "CLAUDE.md" 1 "CLAUDE.md" "symlink is not tracked with exact spelling and case"
    failed=1
  fi

  if [ -f "$agents" ]; then
    while IFS=$'\t' read -r line literal; do
      [ -n "$literal" ] || continue
      if tracked_resolves_exactly "$tracked" "$literal"; then
        continue
      fi
      if tracked_resolves_ignoring_case "$tracked" "$literal"; then
        diagnostic "AGENTS.md" "$line" "$literal" "case does not match the tracked target"
      else
        diagnostic "AGENTS.md" "$line" "$literal" "no exact tracked target"
      fi
      failed=1
    done < <(extract_literal_references "$agents")

    while IFS=$'\t' read -r line skill; do
      [ -n "$skill" ] || continue
      target=".agents/skills/$skill/SKILL.md"
      if tracked_resolves_exactly "$tracked" "$target"; then
        continue
      fi
      if tracked_resolves_ignoring_case "$tracked" "$target"; then
        diagnostic "AGENTS.md" "$line" "$skill" "internal skill target has different tracked case"
      else
        diagnostic "AGENTS.md" "$line" "$skill" "missing exact internal skill target $target"
      fi
      failed=1
    done < <(extract_internal_skill_triggers "$agents")
  fi

  return "$failed"
}

if [ "${1:-}" = "--check" ]; then
  [ "$#" -eq 2 ] || {
    printf 'usage: %s --check <repo>\n' "$0" >&2
    exit 2
  }
  check_instruction_references "$2"
  exit $?
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-instruction-reference-integrity.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
SPACE_CWD="$TMP_ROOT/path containing spaces"
mkdir -p "$SPACE_CWD"

make_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/bin" \
    "$repo/docs" \
    "$repo/.agents/skills/alpha" \
    "$repo/.github/workflows" \
    "$repo/tests"
  printf '# fixture\n' > "$repo/README.md"
  printf '#!/usr/bin/env bash\n' > "$repo/bin/tool.sh"
  printf '# Guide\n' > "$repo/docs/guide.md"
  printf '%s\n' 'name: alpha' > "$repo/.agents/skills/alpha/SKILL.md"
  printf 'name: ci\n' > "$repo/.github/workflows/ci.yml"
  printf '#!/usr/bin/env bash\n' > "$repo/tests/gate.test.sh"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  git -C "$repo" init -q
}

run_check() {
  local repo=$1 out_var=$2 rc_var=$3 captured status=0
  captured=$(cd "$SPACE_CWD" && /bin/bash "$CHECKER" --check "$repo" 2>&1) || status=$?
  printf -v "$out_var" '%s' "$captured"
  printf -v "$rc_var" '%s' "$status"
}

test_current_instruction_surface_from_space_path() {
  local out rc
  run_check "$ROOT" out rc
  expect_code 0 "$rc" "current tracked instruction surface"
  [ -z "$out" ] || fail "clean current instruction surface emitted diagnostics"$'\n'"$out"
  pass "current instruction references resolve when checked from a path containing spaces"
}

test_reference_fixture_matrix() {
  local row label expectation mutation needle content repo out rc
  local -a cases=(
    'clean|pass|none||Use `bin/tool.sh`, `docs/guide.md`, `.agents/skills/alpha/SKILL.md`, `.github/workflows/`, `tests/gate.test.sh`, and `README.md`.\n\n## 13. Agent-only reference skills\n\n- `alpha` - load for the fixture.'
    'missing-file|fail|none|AGENTS.md:1: bin/missing.sh: no exact tracked target|Use `bin/missing.sh`.'
    'case-only|fail|case|AGENTS.md:1: docs/guide.md: case does not match the tracked target|Use `docs/guide.md`.'
    'missing-skill|fail|none|AGENTS.md:3: absent-skill: missing exact internal skill target .agents/skills/absent-skill/SKILL.md|## 13. Agent-only reference skills\n\n- `absent-skill` - load for the fixture.'
    'private-runtime|pass|none||Use `data/private.md`, `state/task.status`, `config/backend`, and `projects/example/README.md`.'
    'placeholder|pass|none||Use `bin/<name>.sh` for a selected name.'
    'glob|pass|none||Run `tests/*.test.sh`.'
    'url|pass|none||Read `https://example.invalid/docs/missing.md`.'
    'example|pass|none||Example: use `bin/missing.sh`.'
    'directory|pass|none||Inspect `docs/` and `.github/workflows/`.'
    'missing-directory|fail|none|AGENTS.md:1: docs/absent/: no exact tracked target|Inspect `docs/absent/`.'
  )

  for row in "${cases[@]}"; do
    IFS='|' read -r label expectation mutation needle content <<< "$row"
    repo="$TMP_ROOT/$label repo"
    make_fixture "$repo"
    printf '%b\n' "$content" > "$repo/AGENTS.md"
    if [ "$mutation" = "case" ]; then
      mv "$repo/docs/guide.md" "$repo/docs/guide.tmp"
      mv "$repo/docs/guide.tmp" "$repo/docs/Guide.md"
    fi
    git -C "$repo" add -A

    run_check "$repo" out rc
    if [ "$expectation" = "pass" ]; then
      expect_code 0 "$rc" "$label fixture"
      [ -z "$out" ] || fail "$label fixture emitted diagnostics"$'\n'"$out"
    else
      expect_code 1 "$rc" "$label fixture"
      assert_contains "$out" "$needle" "$label fixture lost its deterministic diagnostic"
      assert_not_contains "$out" "$repo" "$label fixture leaked its temporary absolute path"
      assert_not_contains "$out" "apply a fix" "$label fixture proposed remediation"
    fi
    pass "reference fixture: $label"
  done
}

test_claude_symlink_fixture_matrix() {
  local row label mutation needle repo out rc
  local -a cases=(
    'missing|missing|CLAUDE.md:1: CLAUDE.md: missing symlink; expected exact target AGENTS.md'
    'wrong|wrong|CLAUDE.md:1: CLAUDE.md: wrong symlink target; expected exact target AGENTS.md'
    'non-symlink|file|CLAUDE.md:1: CLAUDE.md: not a symlink; expected exact target AGENTS.md'
  )

  for row in "${cases[@]}"; do
    IFS='|' read -r label mutation needle <<< "$row"
    repo="$TMP_ROOT/claude-$label repo"
    make_fixture "$repo"
    printf 'Use `bin/tool.sh`.\n' > "$repo/AGENTS.md"
    case "$mutation" in
      missing)
        rm "$repo/CLAUDE.md"
        ;;
      wrong)
        rm "$repo/CLAUDE.md"
        ln -s README.md "$repo/CLAUDE.md"
        ;;
      file)
        rm "$repo/CLAUDE.md"
        printf '# duplicate instructions\n' > "$repo/CLAUDE.md"
        ;;
    esac
    git -C "$repo" add -A

    run_check "$repo" out rc
    expect_code 1 "$rc" "CLAUDE.md $label fixture"
    assert_contains "$out" "$needle" "CLAUDE.md $label fixture lost its deterministic diagnostic"
    assert_not_contains "$out" "$repo" "CLAUDE.md $label fixture leaked its temporary absolute path"
    pass "CLAUDE.md fixture: $label"
  done
}

test_semantic_owner_gate_remains_authoritative() {
  local out rc=0
  out=$(cd "$SPACE_CWD" && /bin/bash "$ROOT/tests/fm-instruction-owners.test.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "semantic instruction-owner gate"
  assert_contains "$out" "compressed AGENTS.md records the approved one-owner map" \
    "instruction-owner gate did not exercise semantic ownership"
  pass "semantic instruction-owner test remains authoritative alongside reference integrity"
}

test_current_instruction_surface_from_space_path
test_reference_fixture_matrix
test_claude_symlink_fixture_matrix
test_semantic_owner_gate_remains_authoritative
