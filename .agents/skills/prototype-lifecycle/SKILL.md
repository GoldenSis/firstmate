---
name: prototype-lifecycle
description: >-
  Agent-only policy for question-first UI or logic-state prototypes inside the
  existing scout, decision-hold, promotion, and delivery lifecycles.
  Load before prototype intake, dispatch, supervision, completion, promotion,
  or teardown, including teardown after promotion.
user-invocable: false
metadata:
  internal: true
---

# Prototype lifecycle

Use a prototype only to answer one explicit uncertainty that discussion, a sketch, or a state table cannot resolve cheaply enough.
Classify the experiment as exactly `ui` or `logic-state` before any worker starts.
Keep it an ordinary scout with a durable report rather than adding a task kind, tracker, or delivery mode.

## Safe experiment envelope

Run the experiment only in its registered isolated worktree.
Use synthetic or minimized fixtures by default.
Do not persist runtime experiment state or cause external side effects; retain decision-bearing source artifacts only under the evidence policy below.
Prototype code, fixtures, screenshots, logs, and scratch commits are evidence only and never implementation authority.

Stop before accessing live NAS data, production accounts or routes, tailnet or remote-access policy, DNS, MX, or email control planes, subscriptions or billing, credentials, or recovery material.
The prototype lifecycle has no sensitive exception flag or worker attestation.
If the question genuinely requires one of those boundaries, stop and use an existing explicit captain-held or other higher-authority decision route, then rescope any later prototype to a safe local simulation.

## Evidence and completion

The surviving report must capture the registered question, classification, assumptions, alternatives, observed evidence, chosen decision, rejected options, unresolved risks, and expiry or disposal expectation.
A logic-state report must also state whether it reproduced a failure and therefore creates a regression-test obligation.
For `logic-state`, commit the validated artifact on the local throwaway branch `proto/<task-id>` before calling `bin/fm-prototype.sh complete`, which records its branch and commit independently of promotion.
Retain reducers or state machines where they preserve the decision more precisely than prose, under the decision cited in [the architecture guide](../../../docs/architecture.md#two-task-shapes).
Keep only the decision-bearing artifact on that branch; remove credentials, debug artifacts, ignored residue, and unrelated experiment state before completion.
Preserve pre-launch ignored files unchanged as required by the helper's clean-worktree checks.
Completion retries verify the same artifact, and evidence updates preserve its recorded identity.
Use `bin/fm-prototype.sh` for registration, worktree binding, evidence completion, verification, and promotion preparation.
Its header and help own command syntax, manifest schema, exact evidence headings, digest rules, idempotency, and clean-worktree checks.

Run the existing decision-hold completion procedure after the prototype evidence gate.
The decision-hold lifecycle remains the only owner of unresolved captain decisions, their durable backlog holds, and answer routing.

## Cleanup

UI prototypes leave their durable report and manifest; their scratch artifacts remain disposable.
Teardown verifies and preserves the recorded logic-state branch before and after promotion for consultation under the report's expiry or disposal expectation; a missing, renamed, or moved reference blocks cleanup.
Explicitly approved cancellation may discard unfinished scratch before an artifact identity is recorded; recorded artifacts remain protected even during forced cleanup.
`bin/fm-prototype.sh` and `bin/fm-teardown.sh` own the cancellation and missing-worktree recovery checks; expiry is a report expectation, not automatic branch deletion.

## Promotion

A completed prototype still stops as knowledge-only work unless implementation is separately authorized.
When implementation is authorized, preserve the validated decision in the durable prototype record.
For `logic-state`, promotion preparation verifies the artifact recorded at completion.
For `ui`, remove all scratch code and commits, fixtures, credentials, debug artifacts, ignored residue, and other experiment state, and prepare promotion from the registered clean baseline; the report remains the surviving record.
`bin/fm-promote.sh` verifies that preparation and restores the clean baseline before changing the scout into a ship task, excluding any retained artifact from the ship branch.

Implement the validated decision afresh on the normal ship branch and follow the project's existing selected delivery path with its normal tests and review.
Do not copy the prototype wholesale or treat a working experiment as production readiness.
When a logic-state prototype reproduced a failure, the fresh implementation must add a regression test for that failure.

The existing scout report, decision-hold, promotion, delivery-path, validation, merge-authority, and teardown contracts remain authoritative and are not replaced by this lifecycle.
