# The Kestra execution seam (M1)

Firstmate can ask a Git-reviewed Kestra flow to run, then read what happened.
That is the whole of milestone 1, and the boundary is deliberate: every scrap of authority stays outside Kestra.

The seam exists because a Kestra execution is far more legible than an opaque shell run.
It carries a declarative topology, per-task state histories, retry attempts, replay lineage, logs, and artifacts.
None of that makes Kestra a decision-maker.
A `SUCCESS` state is evidence that a task ran; it is not approval, not authorization, and not a business decision, and nothing in these adapters lets a flow result approve, merge, route, or unlock anything.

## Data flow

```text
unchanged Git YAML -> authorized deployer -> immutable Kestra flow -> verified revision record
firstmate request  -> allow-list/input adapter -> execution bound to the recorded revision
execution state/logs/task outputs at that revision -> read-only adapter -> firstmate report
```

Four pieces implement it.

| Piece | Owner |
| --- | --- |
| Flow sources | `kestra/flows/*.yaml` |
| Deploy-after-merge and revision record | `bin/fm-kestra-deploy.sh` |
| Run adapter | `bin/fm-kestra-run.sh` |
| Read-only evidence | `bin/fm-kestra-status.sh` |

Each script's header comment is the authoritative description of its behavior, flags, and refusals; `bin/fm-kestra-lib.sh` owns the shared configuration, the static-flow grammar, the revision record format, and the HTTP gate.
Read the header before first use rather than relying on this page.

## Static flows only

M1 permits only static tracked flows (captain decision, 2026-09-30).
Every task field is literal text, no Pebble expression appears anywhere in a flow, and no script or shell task type is admitted.
The seam therefore never has to reproduce Kestra's template semantics locally, and a permitted task cannot render an input, a secret, or any other server-side value.
Four review rounds had kept finding new gaps between a local approximation of those semantics and Kestra's own; narrowing the grammar removed the surface instead of patching it again.

The cost is visible in `kestra/flows/m1_shape.yaml`: its typed inputs are declared, validated on both sides, and recorded on the execution as evidence, but no task reads them, and its branch has a literal condition so one arm always runs and the other is always reported as never run.
A data-driven branch would need an allow-listed expression grammar, which is a deferred decision below.

## Revision binding

Git review decides what a flow says; the revision record decides what runs.
Deployment updates the namespace, reads every flow back at the revision Kestra reported, requires that revision's source to be the reviewed bytes, and only then records the revision against the flow's Git blob id.
Multipart uploads protect newline-terminated sources with a final, unindented comment so Kestra's upload trimming cannot change literal artifact content.
Revision verification accepts that exact framing and preserves source EOF newlines; a source ending in whitespace without a final newline is refused before upload.
A run refuses when the flow has no record, when the tracked flow's blob no longer matches the recorded one, when Kestra cannot return the recorded revision with matching source, or when the created execution reports another revision.
The thing reviewed in Git is therefore provably the thing that runs, and a flow edited on the server or redeployed outside this path cannot be executed through the seam.

## Boundary rationale and ownership

Git review is the authority for which flow identities and source bytes are addressable.
The deploy and run script headers own the exact source-resolution, verification, and refusal rules, while `bin/fm-kestra-lib.sh` owns the supported YAML shape, task and input allow-lists, validator regex subset, and request matrix.
Unsupported source constructs fail closed because approximating Kestra's semantics locally would make the adapter a weaker validator.
INT bounds must use unquoted decimal integers without leading zeros, avoiding YAML octal interpretation.

Kestra is never given permission to pull and reconcile Git itself, because upstream documents that Git-driven synchronization can delete objects depending on the source-of-truth setting.
The seam pushes reviewed source while keeping reconciliation authority outside Kestra.

The status script header owns the evidence modes and the checks that bind every read to reviewed flow identity.
Replay lineage remains evidence, while performing replay remains authority and therefore stays outside this milestone.

## Runtime boundary

The version, edition, asset, checksum, endpoint, and transport contract has one owner in the header and functions of `bin/fm-kestra-lib.sh`.
The pin avoids a floating runtime target, and the local-only posture avoids turning this narrow seam into a general Kestra deployment surface.
M1 installs no plugins and does not adopt the official quickstart's privileged host integrations.

## Local configuration

`docs/configuration.md` owns where `config/kestra.env` and the revision record live and whether they are inherited, and `docs/examples/kestra-env` is the copyable shape.
`bin/fm-kestra-lib.sh` owns the exact file validation and credential-handling mechanics.
The broad Kestra OSS identity remains a disclosure risk even though the adapters expose only narrow operations.

## Synthetic data only

No captain-private, financial, personal, or otherwise sensitive data goes through any M1 flow.
Retention, redaction, and artifact-size limits are not designed yet, and Kestra persists inputs in logs, outputs, and artifacts.
Every M1 task is read-only or synthetic for a second reason as well: retries duplicate side effects, and no idempotency rules exist yet.

## Testing

`tests/fm-kestra-seam.test.sh` is the contract suite and runs hermetically by default: no network, no Java, no Kestra server.
It drives the adapters against a fakebin `curl` that serves recorded response shapes and logs every request, which is what lets a test prove the seam never *attempted* a denied call.

One boundary is worth stating plainly rather than leaving implied.
The hermetic suite asserts what the seam does; it cannot assert what Kestra's engine does.
The retry obligation is therefore split into three claims:

1. the reviewed flow configures three total attempts, asserted statically against the tracked YAML;
2. the status adapter reports the attempts, the `FAILED -> RETRYING -> RUNNING` transitions, the per-attempt error logs, and revision-accurate suppressed tasks without losing or inventing any of them, asserted against recorded execution and flow-revision shapes;
3. Kestra's engine actually performing three attempts, which the hermetic suite does not assert.

Claim 3 is covered by the opt-in live section at the end of that file, which runs only when `FM_KESTRA_LIVE=1` is set and the pinned loopback runtime has the tracked flows deployed through the deploy script.
The same live section is what confirms that Kestra returns a flow's submitted source unchanged at a recorded revision; the hermetic fake models that round trip, it does not prove it.
Every test name says which claim it belongs to, so no assertion reads as stronger than it is.

## Deferred decisions and where they attach

M1 does not decide any of the following, and the seam is built so each can be added without redesign.

**Open Source versus Enterprise Edition.**
Role-based access control, service accounts and API tokens, single sign-on, immutable audit logs, multi-tenancy, plugin allow-lists, and read-only secrets are documented Enterprise capabilities.
Buying is the captain's call and is tracked separately.
It attaches at `fm_kestra_load_config` and `fm_kestra_request` in `bin/fm-kestra-lib.sh`: an API token would replace the Basic Auth config file without touching any caller.

**An expression grammar for data-driven flows.**
If a later milestone needs a branch that reads an input, the allow-list belongs in the text-field rule of `fm_kestra_parse_flow`, as an exact grammar of permitted expressions rather than a deny-list of dangerous ones.

**Who may deploy, execute, replay, restart, and read artifacts, as durable policy.**
It attaches at the role argument of `fm_kestra_request`, which already partitions deploy, run, and read, and at the revision record, which already separates the act of deploying from the act of running.

**Idempotency and replay rules for future mutable tasks.**
Nothing in M1 mutates anything outside Kestra's own storage.
A mutable task would need an idempotency key or an explicit non-retry policy declared in the flow, and `fm_kestra_parse_flow` is where that requirement would be enforced at deploy time.

**Retention, redaction, artifact limits, and network policy for non-synthetic data.**
Artifact reads already pass through one function that refuses undeclared URIs, so a size or redaction rule has one place to live.

**High availability.**
H2 local mode is a development convenience.
M1 does not attempt a production architecture.
