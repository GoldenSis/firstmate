# The Kestra execution seam (M1)

Firstmate can ask a Git-reviewed Kestra flow to run, then read what happened.
That is the whole of milestone 1, and the boundary is deliberate: every scrap of authority stays outside Kestra.

The seam exists because a Kestra execution is far more legible than an opaque shell run.
It carries a declarative topology, per-task state histories, retry attempts, replay lineage, logs, and artifacts.
None of that makes Kestra a decision-maker.
A `SUCCESS` state is evidence that a task ran; it is not approval, not authorization, and not a business decision, and nothing in these adapters lets a flow result approve, merge, route, or unlock anything.

## Data flow

```text
unchanged Git YAML -> authorized deployer -> immutable Kestra flow
firstmate request   -> allow-list/input adapter -> Kestra execution ID
allow-listed execution/revision/logs/outputs -> read-only adapter -> firstmate report
```

Four pieces implement it.

| Piece | Owner |
| --- | --- |
| Flow sources | `kestra/flows/*.yaml` |
| Deploy-after-merge | `bin/fm-kestra-deploy.sh` |
| Run adapter | `bin/fm-kestra-run.sh` |
| Read-only evidence | `bin/fm-kestra-status.sh` |

Each script's header comment is the authoritative description of its behavior, flags, and refusals; `bin/fm-kestra-lib.sh` owns the shared configuration, parsing, and HTTP gate contracts.
Read the header before first use rather than relying on this page.

## Boundary rationale and ownership

Git review is the authority for which flow identities and source bytes are addressable.
The deploy and run script headers own the exact source-resolution and validation rules, while `bin/fm-kestra-lib.sh` owns the supported YAML shape, task and input allow-lists, and request matrix.
Unsupported source constructs fail closed because approximating Kestra's semantics locally would make the adapter a weaker validator.

Kestra is never given permission to pull and reconcile Git itself, because upstream documents that Git-driven synchronization can delete objects depending on the source-of-truth setting.
The seam pushes reviewed source while keeping reconciliation authority outside Kestra.

The status script header owns the evidence modes and the checks that bind every read to reviewed flow identity.
Replay lineage remains evidence, while performing replay remains authority and therefore stays outside this milestone.

## Runtime boundary

The version, edition, asset, checksum, endpoint, and transport contract has one owner in the header and functions of `bin/fm-kestra-lib.sh`.
The pin avoids a floating runtime target, and the local-only posture avoids turning this narrow seam into a general Kestra deployment surface.
M1 installs no plugins and does not adopt the official quickstart's privileged host integrations.

## Local configuration

`docs/configuration.md` owns where `config/kestra.env` lives and whether it is inherited, and `docs/examples/kestra-env` is the copyable shape.
`bin/fm-kestra-lib.sh` owns the exact file validation and credential-handling mechanics.
The broad Kestra OSS identity remains a disclosure risk even though the adapters expose only narrow operations.

## Synthetic data only

No captain-private, financial, personal, or otherwise sensitive data goes through any M1 flow.
Retention, redaction, and artifact-size limits are not designed yet, and Kestra persists inputs in logs, rendered templates, outputs, and artifacts.
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

Claim 3 is covered by the opt-in live section at the end of that file, which runs only when `FM_KESTRA_LIVE=1` is set and the pinned loopback runtime has the tracked flows deployed.
Every test name says which claim it belongs to, so no assertion reads as stronger than it is.

The live section confirms the server-dependent request shapes that the library's request matrix owns.

## Deferred decisions and where they attach

M1 does not decide any of the following, and the seam is built so each can be added without redesign.

**Open Source versus Enterprise Edition.**
Role-based access control, service accounts and API tokens, single sign-on, immutable audit logs, multi-tenancy, plugin allow-lists, and read-only secrets are documented Enterprise capabilities.
Buying is the captain's call and is tracked separately.
It attaches at `fm_kestra_load_config` and `fm_kestra_request` in `bin/fm-kestra-lib.sh`: an API token would replace the Basic Auth config file without touching any caller.

**Who may deploy, execute, replay, restart, and read artifacts, as durable policy.**
It attaches at the role argument of `fm_kestra_request`, which already partitions deploy, run, and read.

**Idempotency and replay rules for future mutable tasks.**
Nothing in M1 mutates anything outside Kestra's own storage.
A mutable task would need an idempotency key or an explicit non-retry policy declared in the flow, and `fm_kestra_check_flow` is where that requirement would be enforced at deploy time.

**Retention, redaction, artifact limits, and network policy for non-synthetic data.**
Artifact reads already pass through one function that refuses undeclared URIs, so a size or redaction rule has one place to live.

**High availability.**
H2 local mode is a development convenience.
M1 does not attempt a production architecture.
