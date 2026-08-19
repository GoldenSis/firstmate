# The Kestra execution seam (M1)

Firstmate can ask a Git-reviewed Kestra flow to run, then read what happened.
That is the whole of milestone 1, and the boundary is deliberate: every scrap of authority stays outside Kestra.

The seam exists because a Kestra execution is far more legible than an opaque shell run.
It carries a declarative topology, per-task state histories, retry attempts, replay lineage, logs, and artifacts.
None of that makes Kestra a decision-maker.
A `SUCCESS` state is evidence that a task ran; it is not approval, not authorization, and not a business decision, and nothing in these adapters lets a flow result approve, merge, route, or unlock anything.

## Data flow

```text
reviewed Git YAML   -> authorized deployer -> immutable Kestra flow
firstmate request   -> allow-list/input adapter -> Kestra execution ID
Kestra state/logs/declared outputs -> read-only adapter -> firstmate report
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

## What the seam refuses

The allow-list is the tracked `kestra/flows/` directory itself.
A flow identity with no reviewed source in Git is not addressable, so the set of runnable flows changes only through Git review.

`bin/fm-kestra-deploy.sh` refuses a flow whose namespace is not the one namespace named in local config, a flow missing the `system.readOnly: "true"` label, a task type outside `io.kestra.plugin.core.`, and any input schema or validator regex the run adapter could not faithfully pre-check.
It always updates the namespace with `delete=false`.
Kestra is never given permission to pull and reconcile Git itself, because upstream documents that Git-driven synchronization can delete objects depending on the source-of-truth setting.
The seam pushes; Kestra never pulls.

`bin/fm-kestra-run.sh` accepts only `--flow` and `--input` and refuses every other argument by name.
Inputs are validated against the reviewed flow's declared schema before the first byte leaves the machine, so a rejected input never creates an execution.

`bin/fm-kestra-status.sh` returns execution state, task logs, declared outputs, and artifacts the execution itself declared as outputs.
An artifact URI the execution did not publish is refused, which keeps the adapter an evidence reader rather than a storage browser.

Underneath all three, `fm_kestra_path_allowed` in `bin/fm-kestra-lib.sh` gates every request by role.
Replay, restart, resume, kill, state override, flow deletion, secret access, and namespace administration are unreachable from every role, so an argument-parsing bug still cannot reach a mutating endpoint.
Replay *lineage* stays readable, because knowing an execution was derived from another one is evidence.

## Version pin

| Item | Value |
| --- | --- |
| Product | Kestra Open Source Edition |
| Version | 1.3.34 |
| Asset | <https://github.com/kestra-io/kestra/releases/download/v1.3.34/kestra-1.3.34> |
| SHA-256 | `de846ac42e2b35a2e55301d01335de6ea30eab77fd69570f238e06ea28149a4b` |

`fm_kestra_pinned_version` and `fm_kestra_pinned_sha256` in `bin/fm-kestra-lib.sh` are the single source of those two values.
Verify a downloaded asset before running it:

```sh
shasum -a 256 kestra-1.3.34
# must print the SHA-256 above
```

No `latest` tag and no unversioned image is supported.
The standalone asset needs Java 21 or newer and ships core plugins only, which is exactly what M1 wants: no plugin installation, so no added supply-chain or runtime surface.

Bind the main and management servers to loopback.
Do not mount the Docker socket and do not mount host `/tmp`; the official quickstart's shape is rejected here.

## Local configuration

Endpoint and credential live in `config/kestra.env`, which is gitignored.
Nothing under `kestra/` or `bin/` carries a value.
`docs/examples/kestra-env` is the copyable shape.

Kestra OSS authenticates one broad Basic Auth identity that can create, execute, replay, change state, and delete through the same API and UI.
Treat that credential as a disclosure risk.
The adapters hand it to `curl` through a mode-0600 config file that is removed on exit, and never place it in argv, so it does not appear in a process listing or a shell history.

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
2. the status adapter reports the attempts, the `FAILED -> RETRYING -> RUNNING` transitions, the per-attempt error logs, and the suppressed following task without losing or inventing any of them, asserted against a recorded execution shape;
3. Kestra's engine actually performing three attempts, which the hermetic suite does not assert.

Claim 3 is covered by the opt-in live section at the end of that file, which runs only when `FM_KESTRA_LIVE=1` is set and a real loopback Kestra 1.3.34 has the tracked flows deployed.
Every test name says which claim it belongs to, so no assertion reads as stronger than it is.

Two endpoint shapes are used by the read adapter but were not exercised against a live server during this milestone: `GET /logs/{executionId}` for task logs and `GET /executions/{executionId}/file?path=...` for artifact bytes.
The live section is what confirms them.

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
