---
name: model-fusion
description: >-
  Agent-only policy for running independent explicit-model opinions, synthesizing
  consensus/divergence/discarded ideas, and sealing a validator-authored red gate
  before an authorized builder starts. Load before model-fusion intake, dispatch,
  synthesis, validation-gate sealing, or promotion.
user-invocable: false
metadata:
  internal: true
---

# Model fusion

Use model fusion only when independent model perspectives can materially improve a real design or implementation decision.
Ordinary parallel delegation, one model sampled more than once, and routine implementation do not qualify.

## Opinion and synthesis policy

1. Resolve at least two distinct explicit `(harness, model)` profiles through the normal dispatch rules and captain overrides.
2. Reject an implicit `model=default`; prefer vendor diversity when it is available, but distinct concrete model identities are the required invariant.
3. Give every opinion scout the same canonical task text or recorded SHA-256 digest and its normal isolated scout worktree.
4. Give an opinion scout no sibling task id, path, report, synthesis, or hidden sibling context, and do not cross-feed opinions during supervision.
5. Spawn opinion legs individually because batch dispatch has one shared profile.
6. Wait until every opinion report is complete before creating the synthesis brief.
7. Scaffold the synthesis with `bin/fm-brief.sh <id> <repo> --scout --fusion-synthesis` and pass only the completed opinion report paths and digests.
8. Require the synthesis report to cite every input and contain `Consensus`, `Divergence`, and `Discarded ideas` sections.
9. Classify every divergence as `complementary` or `contradictory`, give a reason for every discarded idea, and write `None` plus a reason when a category is empty.
10. Run the existing decision-hold completion procedure before treating the synthesis as complete.

The synthesis is knowledge evidence, not implementation, product, or merge authority.
Stop after knowledge-only completion unless the captain or existing configured authority has separately authorized implementation.

## Validator-before-builder policy

After implementation is authorized, spawn one separate ordinary validator scout on the same untouched base.
The validator authors focused executable tests only, exports them as a test-only patch plus a literal argv entrypoint, and seals them through `bin/fm-fusion-gate.sh`.
The helper's header and help are the sole owner of package fields, hashes, path checks, baseline-red proof, exact commands, and replay mechanics.

Do not promote the marked synthesis scout until `bin/fm-fusion-gate.sh verify <id>` succeeds.
The promoted builder runs the sealed gate expecting red before production edits, changes production code, and runs the same sealed gate expecting green before committing.
Gate failure output is executable-specification feedback to the same builder, not a review finding.
The validator does not return after sealing, inspect the built branch, issue a clean verdict, push, merge, or drive the delivery pipeline.

If the gate is defective, stop the builder and have a validator author a new immutable revision with a reason.
The builder never edits gate-managed test bytes or weakens the gate.
The seal is tamper-evident, not an adversarial same-user security boundary.

## Existing authority remains exclusive

Keep every participant an ordinary scout or promoted ship task in its active `FM_HOME`.
Use existing project isolation, dispatch, backlog dependencies, decision holds, promotion, selected delivery paths, merge authority, and one live supervision cycle unchanged.
The pre-builder red/green loop ends before shipping validation begins.
For a no-mistakes project, the same ship worker starts the post-commit pipeline and no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI.
For direct-PR and local-only projects, continue through their existing delivery paths without adding a reviewer.

Do not add a fusion task kind, delivery mode, general run state machine, post-build validator, manual clean verdict, or no-mistakes integration.
