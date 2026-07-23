---
name: prototype-lifecycle
description: >-
  Agent-only policy for question-first UI or logic-state prototypes inside the
  existing scout, decision-hold, promotion, and delivery lifecycles.
  Load before prototype intake, dispatch, supervision, completion, or promotion.
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
Do not persist experiment state or cause external side effects.
Prototype code, fixtures, screenshots, logs, and scratch commits are evidence only and never implementation authority.

Stop before accessing live NAS data, production accounts or routes, tailnet or remote-access policy, DNS, MX, or email control planes, subscriptions or billing, credentials, or recovery material.
The prototype lifecycle has no sensitive exception flag or worker attestation.
If the question genuinely requires one of those boundaries, stop and use an existing explicit captain-held or other higher-authority decision route, then rescope any later prototype to a safe local simulation.

## Evidence and completion

The surviving report must capture the registered question, classification, assumptions, alternatives, observed evidence, chosen decision, rejected options, unresolved risks, and expiry or disposal expectation.
A logic-state report must also state whether it reproduced a failure and therefore creates a regression-test obligation.
Use `bin/fm-prototype.sh` for registration, worktree binding, evidence completion, verification, and promotion preparation.
Its header and help own command syntax, manifest schema, exact evidence headings, digest rules, idempotency, and clean-worktree checks.

Run the existing decision-hold completion procedure after the prototype evidence gate.
The decision-hold lifecycle remains the only owner of unresolved captain decisions, their durable backlog holds, and answer routing.

## Promotion

A completed prototype still stops as knowledge-only work unless implementation is separately authorized.
When implementation is authorized, preserve the validated decision in the durable prototype record, remove all scratch code and commits, fixtures, credentials, debug artifacts, ignored residue, and other experiment state, and prepare promotion from the registered clean baseline.
`bin/fm-promote.sh` verifies that preparation before changing the scout into a ship task.

Implement the validated decision afresh on the normal ship branch and follow the project's existing selected delivery path with its normal tests and review.
Do not copy the prototype wholesale or treat a working experiment as production readiness.
When a logic-state prototype reproduced a failure, the fresh implementation must add a regression test for that failure.

The existing scout report, decision-hold, promotion, delivery-path, validation, merge-authority, and teardown contracts remain authoritative and are not replaced by this lifecycle.
