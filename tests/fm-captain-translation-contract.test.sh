#!/usr/bin/env bash
# Static regression tests for the captain-facing plain-English translation
# contract kept as a concise AGENTS.md section 9 stub and fully owned by
# docs/architecture.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
ARCHITECTURE="$ROOT/docs/architecture.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"

section_9() {
  awk '
    /^## 9\. Escalation and captain etiquette$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

translation_owner() {
  awk '
    /^## Internal.*plain translation table/ { found = 1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$ARCHITECTURE"
}

[ -n "$(translation_owner)" ] \
  || fail "docs/architecture.md lost the internal-to-plain translation table heading, so no contract below can be checked"

test_section_9_keeps_stub_and_points_to_full_owner() {
  local stub owner
  stub=$(section_9)
  owner=$(translation_owner)
  assert_contains "$stub" "Translate internal state into the project outcome, consequence, and next decision" \
    "section 9 lost the positive captain-facing translation stub"
  assert_contains "$stub" "using the captain's nouns" \
    "section 9 no longer requires captain-owned nouns"
  assert_contains "$stub" "\`docs/architecture.md\` owns the full internal" \
    "section 9 does not point to the full translation owner"
  assert_contains "$owner" "Every captain-facing message must translate internal state into the project outcome, consequence, and next decision." \
    "architecture docs lost the full positive translation contract"
  assert_contains "$owner" "When evidence uses an internal label, rewrite it before sending:" \
    "architecture docs no longer own the rewrite mapping list"
  pass "section 9 keeps the translation stub and points to the full owner"
}

test_scout_remains_allowed_house_vocabulary() {
  local stub owner
  stub=$(section_9)
  owner=$(translation_owner)
  assert_contains "$stub" '"Scout" and "second mate" are accepted house vocabulary.' \
    "section 9 does not preserve scout as allowed house vocabulary"
  assert_contains "$owner" "Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation" \
    "full translation owner does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$owner" "scout -> investigation" \
    "translation owner must not map scout to investigation"
  assert_not_contains "$owner" "scout, ship" \
    "translation owner must not add scout to the internal-vocabulary ban"
  assert_not_contains "$owner" "secondmate -> domain supervisor" \
    "translation owner must not map secondmate to domain supervisor"
  pass "scout remains allowed in private captain chat"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(translation_owner)
  for phrase in \
    "fail-closed" \
    "fails closed" \
    "fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "translation owner does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside and lets work continue when the check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(translation_owner)
  for phrase in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contract" "$phrase" "translation owner mapping list is missing '$phrase'"
  done
  pass "architecture owner maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local stub owner
  stub=$(section_9)
  owner=$(translation_owner)
  assert_contains "$stub" "Never relay worker reports, status lines, tool output, or validation labels verbatim into captain chat" \
    "section 9 stub does not reject verbatim internal evidence in captain chat"
  assert_contains "$owner" "Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into captain chat." \
    "translation owner does not reject all verbatim internal evidence"
  assert_contains "$owner" "Private evidence reports may retain exact identifiers, paths, status lines, validation labels, and internal terms" \
    "translation owner does not preserve private evidence precision"
  assert_contains "$owner" "the captain-facing chat summary that points to the report still follows this translation rule" \
    "translation owner does not keep chat summaries plain English"
  pass "captain chat rejects verbatim internal evidence while private reports stay precise"
}

test_outward_facing_skill_points_reference_section_9_owner() {
  assert_grep "using \`AGENTS.md\` section 9's captain-facing translation contract" "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference section 9 at captain handoff"
  assert_grep "Acknowledge** in \`AGENTS.md\` section 9 language" "$AFK" \
    "afk acknowledgement does not reference section 9"
  assert_grep "Captain, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "as decisions from Bearings' Captain's Call section under \`AGENTS.md\` section 9" "$DECISION" \
    "decision relay does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9; do not mention metadata, harness, window, or worktree" "$RECOVERY" \
    "stuck-worker failure does not reference section 9"
  assert_grep "under \`AGENTS.md\` section 9 that the requested worker runtime is not verified yet" "$HARNESS" \
    "runtime fallback does not reference section 9"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep "translate status prefixes and return-channel evidence through \`AGENTS.md\` section 9" "$CODEXAPP" \
    "Codex Desktop result reporting does not reference section 9"
  assert_grep "It supplements \`AGENTS.md\` section 9; apply both, and this public-channel rule wins wherever it is stricter." "$FMX" \
    "X reply safety does not state that it supplements section 9"
  assert_grep "under \`AGENTS.md\` section 9 without firstmate's internal vocabulary" "$UPDATE" \
    "Firstmate update reporting does not reference section 9"
  pass "outward-facing skill handoffs point to the section 9 owner"
}

test_translation_owner_is_not_duplicated_into_skills() {
  local duplicate_count file
  duplicate_count=0
  for file in "$BOOTSTRAP" "$AFK" "$DECISION" "$RECOVERY" "$HARNESS" "$CODEXAPP" "$UPDATE"; do
    if grep -Fq "When evidence uses an internal label, rewrite it before sending:" "$file"; then
      duplicate_count=$((duplicate_count + 1))
    fi
  done
  [ "$duplicate_count" -eq 0 ] || fail "skills duplicated the architecture mapping owner"
  pass "skills cross-reference the translation contract instead of duplicating the mapping list"
}

test_section_9_keeps_stub_and_points_to_full_owner
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_outward_facing_skill_points_reference_section_9_owner
test_translation_owner_is_not_duplicated_into_skills
