---
name: firstmate-coding-guidelines
description: >-
  Agent-only reference for changing firstmate's shared, tracked material per AGENTS.md section 1.
  Use before editing any of that material, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
  Covers the knowledge-placement decision tree, the one-owner rule for contracts, the inline-stub pattern for content moved into a skill, AGENTS.md size discipline, skill admission, trigger hygiene, and repo style rules (one sentence per line, plain dash, no agent co-author, shellcheck-clean bin scripts, colocated tests, and backend-verification evidence).
user-invocable: false
metadata:
  internal: true
---

# firstmate-coding-guidelines

Load this before changing firstmate's shared, tracked material, as defined by `AGENTS.md` section 1.
It exists because `AGENTS.md` grew from 585 to 958 lines between its last two restructures, entirely from conditional detail added inline instead of routed to its right home.
Applying the rules below on every change is what keeps that from happening again.

## Knowledge-placement decision tree

Before writing a new fact anywhere in this repo, ask where it belongs, in this order.

1. Does the firstmate AGENT need this on every session or every turn to operate?
   If yes: `AGENTS.md`, inline.
2. Does the agent need it only in a nameable situation - a spawn, a recovery, a specific wake type, a specific lifecycle step?
   If yes: an agent-only skill under `.agents/skills/`, plus a one-line trigger pointer left inline in `AGENTS.md` (usually section 13).
3. Is it human/reference detail - a wire format, a verification record, a mechanism narrative, an incident writeup?
   If yes: `docs/`.
4. Is it mechanics - exact flags, exact commands, exact paths?
   If yes: the script's own header comment plus its `--help` output, not prose in `AGENTS.md` or a skill.

Stop at the first tier that answers yes.
Do not place a fact at a more convenient tier than the one this tree gives you.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly once.
Every other mention of it is a one-line cross-reference, never a restatement.
A single deliberate one-line reinforcement at a genuine risk point is allowed, for example a "don't forget X" placed exactly where forgetting X is costly.
Restating the contract's substance a second time is not allowed: the two copies will drift the moment only one is edited.
When you touch a contract, grep the repo for its other mentions and update the cross-references, not duplicate the change into a second full copy.

## Inline-stub pattern

When content moves out of `AGENTS.md` into a skill, decide what stays behind by asking one question: what must survive with no skill loaded?
That is the trigger condition for loading the skill, plus any safety-critical fact that fires on a wake the skill itself is not loaded for.
Everything else - the procedure, the mechanism, the surrounding detail - moves out completely.
Do not leave a partial restatement behind "just in case".
A partial copy is exactly the duplication the one-owner rule forbids.
The model to copy is `AGENTS.md` section 8's "Away-mode stub": it keeps only the marker format, the ownership-transfer rule, and the exit condition inline, and points everything else at the `/afk` skill.

## Size discipline

Apply the decision tree above to every line you are about to add to `AGENTS.md`.
If an addition needs more than a few lines of conditional detail (detail that matters only in a specific situation) or reference detail (a wire format, an exact schema, historical rationale), you are almost certainly adding it to the wrong file.
`AGENTS.md`'s token cost is paid by every session of every fleet member, every time, whether or not that session ever hits the situation the new lines describe.
A skill's cost is paid only by the sessions that actually load it.
When in doubt, write the fact into the skill or doc first, and add only the one-line trigger to `AGENTS.md`.

## Trigger hygiene

A new skill is dead weight if nothing loads it.
Every new skill needs its load trigger declared inline: section 13 for agent-only reference skills, or the relevant operating section for anything else.
State the trigger as a condition ("load before X", "load on Y wake"), never as a vague pointer.
Briefs for tasks that touch firstmate's own tracked material should tell the crewmate to load this skill.
`bin/fm-brief.sh`'s `REPO` argument is a caller-supplied string with no reliable signal that it names firstmate's own repo, unlike a project registered in `data/projects.md`, so there is no clean point inside the scaffold to detect this case automatically.
Firstmate adds this skill's load instruction to firstmate-repo briefs by hand instead.
`CONTRIBUTING.md`'s "Development" section carries the same instruction as a durable reminder.

## Skill-admission rubric

Skill creation is fail-closed: the default answer is "not a skill" until every admission gate passes.
Apply all six gates before creating a new skill directory, and again before materially expanding an existing skill's scope.
Routine edits inside a skill's already-admitted scope - a correction, a clarification, a structural fix - do not reopen admission.

1. **Recurrence.**
   The behavior must have been requested or expected at least twice in distinct contexts.
   A first-of-its-kind procedure belongs in an existing script, brief boilerplate, or documentation until recurrence is demonstrated.
2. **Non-triviality.**
   A procedure shorter than roughly 20 lines of durable instruction normally belongs in a script or brief section rather than a skill.
   This threshold is a heuristic, not a hard law, but any override must record why the procedure still needs conditional judgment that those smaller owners cannot express.
3. **Clear trigger phrase.**
   A user or agent must be able to say when to invoke the skill in one plain-English clause.
   Refuse triggers that depend on implicit dispatch, an unnamed resolver, or vague model judgment.
4. **One coherent capability.**
   The proposal must serve one intent that is invoked as a unit.
   If it spans distinctly invoked intents, stop before creating files, propose scoped splits, and re-apply gates 1 through 6 independently to every proposed skill.
5. **Named target.**
   Name the knowledge or contract owner that the skill belongs to.
   Also name every primary harness and runtime backend with which the skill must remain compatible, including axes found not applicable after inspection.
   A proposal that assumes one harness or omits its target owner fails admission.
6. **Job-not-tool naming.**
   Name the job the operator is trying to accomplish, not the command or tool used along the way.
   `investigate-failure` names a job, while `run-jest-verbose` names a tool operation.

Only after gates 1 through 6 pass, ask whether a smart intern can follow the procedure without hidden context.
That readability check can require clearer writing, but it never supplies authority, safety, permissions, tests, or failure paths and never substitutes for any of them.

Route a failed proposal to its smallest honest owner.
One-off mechanics go to an existing script under `bin/` or to a brief section, not to a new skill.
Reusable procedures with no clear trigger go to `docs/`, not to a skill.
Multi-intent proposals are split first, then each proposed skill starts again at gate 1.
End-of-task pattern extraction may create a `skillify-candidate` backlog note for a separate future ship task.
It must never write a live skill from `/stow` or from a task-completion path.

The seeded decisions in `tests/fixtures/skill-admission/` and their assertions in `tests/fm-skill-contract.test.sh` pin one routing decision per gate outcome, so every gate above has a fixture that fails when the gate is weakened or dropped.
That same test anchors the gate headings, the fail-closed default, and the routing rules above, so weakening this section fails the suite rather than passing silently.

### Declared audit escapes

`tests/fm-skill-contract.test.sh` honors three frontmatter keys, each a recorded decision rather than a way to silence a receipt.

- `trigger:` declares the load condition explicitly, and when present it replaces the description-derived phrases the SC005 overlap check compares for that skill.
- `trigger-owner:` names the single skill that owns a trigger phrase claimed by more than one skill; SC005 clears the overlap only when every claimant names the same owner, and the named owner must itself be one of the claiming skills rather than a third arbitrating skill.
- `standalone: true` records that a skill is deliberately reachable without an `AGENTS.md` pointer, and it is the only thing that clears the SC004 orphan check for a skill whose sole inbound evidence is prose inside another skill.

Declare any of the three nested under `metadata:`, which is where every tracked skill already keeps its private frontmatter keys and the only placement this repo has verified across its supported harnesses.
The audit also tolerates a top-level declaration, so an inherited skill that spells one at the top level still reads correctly.
Reach for one only when the collision or the standalone posture is genuine.
Deleting content or narrowing a real trigger to quiet a receipt is never the remedy.

## Compatibility and enforcement

Before changing shared tracked behavior, review every affected supported primary harness and runtime backend rather than checking only the adapters active in the current fleet.
Mark an axis not applicable only after inspecting its integration surface, and update the corresponding verification evidence when behavior changes.

For critical safety, routing, startup, and supervision infrastructure, prefer deterministic and idempotent enforcement over relying on agent memory alone.
Keep instructions as the authority and discovery layer, but make repeated execution converge safely and make invalid or unsafe states fail closed wherever the runtime can enforce them.

## Repo style rules

- Put one full sentence per line in tracked Markdown.
- Never wrap multiple sentences onto one physical line.
- Plain dash `-`, never an em dash.
- Never add an agent name as a commit co-author.
- `bin/*.sh` and `bin/backends/*.sh` must pass `shellcheck`.
- Run `bin/fm-lint.sh` before treating a script change as done; it is the single owner of the lint definition (file set, config, and pinned shellcheck version) that CI and the no-mistakes pre-push gate both invoke, and it refuses to run under any other shellcheck version.
- Colocate tests with the existing pattern in `tests/`, name them `<subject>.test.sh`, and extend an existing script rather than inventing a new runner.
- A backend-verification doc (`docs/*-backend.md`) records empirical facts, not assumptions.
- Include the date, version, exact commands run, and exact output.
- Write incidents the same way, as evidence, not narrative alone.
