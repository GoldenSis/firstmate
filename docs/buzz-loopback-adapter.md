# Buzz loopback adapter

A one-way publisher that renders Firstmate's bearings projection into a private channel on a locally self-hosted Buzz relay, and each live crewmate's own status stream into a channel of its own.
It is additive: nothing in Firstmate reads it, depends on it, or waits for it.

This document is the reference for the adapter and the record of what was verified against a running relay.
Mechanics live in each script's own header and `--help`; this file covers the shape, the invariants, and the evidence.

## What it is

Buzz is Block's open-source Nostr-based workspace (Apache-2.0).
Its relevant property is that every message is an individually signed, individually verified event in an append-only log, and a private channel is enforced server-side - when membership is required - rather than trusted from the client.
The M1 stack deliberately does not require it, so nothing here relies on that enforcement; see invariant 2.
The fleet invocation signs an event carrying `bin/fm-bearings-snapshot.sh --json` verbatim and publishes it to a private channel on a relay bound to loopback.
`bin/fm-buzz-refresh.sh` is the single call that publishes that fleet event and then one validated single-task projection per live crewmate, each lane an ordinary invocation of the same publisher against its own channel.

The projection is already report-shaped, so the adapter is a renderer rather than a data model.
In particular the projection's `omitted[]` disclosure array is passed through untouched, because a bounded projection whose truncation disclosure was stripped in transit is worse than no projection at all: an absence stops being unambiguous.

## The five binding invariants

These are not style preferences.
Each one is the reason a specific failure mode cannot occur, and breaching any of them re-opens the question the study answered rather than extending it.

1. **Canonical projections stay Firstmate-owned.**
   The adapter is a one-way publisher.
   Buzz is a projection target, never a state source, so a relay that is stale or unreachable can never influence Firstmate's view.
   Firstmate's authoritative state is rebuilt from local durable records on every session start, and Buzz is not in that path.
2. **Loopback only.**
   The relay is published to `127.0.0.1` and nothing else, and there is no hosted `buzz.xyz` account.
   This is what makes Buzz's missing rate limiting irrelevant: upstream defines four rate-limit tiers but ships only a test-stub limiter, so an internet-exposed relay would have no flood or brute-force protection at the application layer.

   Loopback is not the same boundary as single-user, and the difference is worth stating rather than blurring.
   The relay runs open - no auth token, no membership enforcement - so any local process on this host, running as any user, can reach `127.0.0.1:3000` and publish.
   The channel id is not a secret either: `channelIdForLabel` hashes the UTF-8 string `firstmate-buzz-channel:<label>`, where the default label is the resolved `FM_HOME`, takes the first 16 bytes, and sets the UUID version and variant bits, derived on purpose so a lost keypair cannot orphan the channel.
   A local process that created the group first would own it and could read the bearings projections published into it.
   That is an accepted risk for a proof of concept on a single-user laptop with a disposable stack; the boundary actually being relied on is "no other local user", not "no remote party".
   Closing it means enforcing membership, which belongs to Milestone 2 along with the rest of channel membership management.

   Disposable has to mean the exposure ends when the operator stops using the stack, so the relay carries `restart: "no"` and does not come back by itself after a reboot.
   The datastores do restart, because they only serve the internal compose network, and they self-resume across a host reboot still holding every published bearings projection.
   `docker compose -f docker-compose.buzz-loopback.yml down -v` is what ends the exposure for good, volumes included.
   On first startup, `relay-key-init` generates one valid secp256k1 relay signing key inside the compose-managed `buzz-relay-key` volume with mode 0400 and ownership restricted to the relay user.
   The relay reads that key into `BUZZ_RELAY_PRIVATE_KEY` at process start, and no host bind mount or tracked file holds it.
   A relay container restart reuses the same volume and therefore the same kind-39002 signer, while `docker compose -f docker-compose.buzz-loopback.yml down -v` destroys the key with the other disposable data.
   The next `up -d` after that teardown creates a different relay signer and a clean trust boundary.
3. **Publishing is fire-and-forget.**
   `bin/fm-buzz-publish.sh` converts runtime publication failures into logged exit-0 non-events.
   A missing declared filesystem-safety prerequisite fails before publication with a non-zero startup error.
   An input that lacks the required `fm-bearings.v1` base fields, their documented types, the `in_flight[]` item shape, or a well-formed `omitted[]` disclosure fails before signing or caching.
4. **No canvas for state.**
   Append-only messages only.
   A Buzz canvas is a single mutable TEXT column overwritten with no compare-and-set and no base hash, so publishing state into one would silently destroy concurrent captain edits with no error to either party.
   If a durable checkpoint is ever wanted, the surface with actual concurrency discipline is a NIP-AE engram with a base-hash precondition.
5. **No workflow approval gates.**
   Merge authority stays with `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` under `AGENTS.md` section 7.
   Buzz's own `request_approval` is unimplemented upstream and fails runs that reach it, and it must not be built on regardless.
   An approval that arrives via Buzz is evidence, never authority.

## Per-crew lanes

The fleet channel answers "what is the fleet doing".
It does not answer "what is this one crewmate doing", because every crewmate's status is flattened into one document with nothing distinguishing them.
A lane fixes that: one channel per live task, carrying that task's own status stream and its identity, so the captain can open one place per crewmate and watch it work.

### The mechanism, and why it is (a)

Two mechanisms were on the table: a derived channel per task, or Buzz's native threads inside the existing channel.
This ships the derived channel, and did not half-build the other.
`channelIdForLabel` was made derivable on purpose - it hashes `firstmate-buzz-channel:<label>`, takes 16 bytes, and sets the v5 and variant bits - so a per-crew channel is a new NAME through a function that is already tested, and the replay cache is already partitioned by `<endpoint-digest>/<channel-id>/`, so multi-channel publication needs no new storage, no new lock, and no new wire protocol.
Threads would be tidier for a reader, but this adapter speaks only the NIP-01 and NIP-29 subset it needs; nothing in `bin/fm-buzz-lib.mjs` addresses a thread, so taking that route means new protocol surface on a pre-1.0 relay that can move under the adapter at any time.
Channel sprawl is the price paid, and it grows with lifetime task count because completed-task channels remain in the relay with their last projection.
Every lane id is recomputable from the home and the task id with nothing to persist, and `docker compose -f docker-compose.buzz-loopback.yml down -v` is the accepted cleanup for this disposable stack.

### The label

`crewChannelLabel(<fleet label>, <task id>)` returns `firstmate-crew:<sha256(fleet label)>:<task id>`, which is then hashed by the unchanged `channelIdForLabel`.
The fleet label is hashed rather than concatenated because appending is not injective: a home path that happened to end in the separator plus another id would derive the same string as a different home publishing that task.
A task id is restricted to `[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}`, matching the canonical task-creation validator while excluding the separator and a leading dot, so the encoding is unambiguous by construction; an id outside that set is refused rather than published to some other channel.
The fleet label itself is untouched, so the fleet channel keeps the exact id it has always had and a captain reading it does not silently lose their history.
`tests/fm-buzz-crew-lanes.test.sh` pins the derived id of a fixed label against its literal value, so a change to that derivation fails rather than quietly re-homing the channel.

### The name

The label decides where a lane goes; the name decides whether a human can find it.
Each lane is published with `--channel-name crew-<home qualifier>-<task id>`, where the stable eight-hex qualifier is the first segment of the unchanged channel id derived from the resolved home path.
The display name reaches the relay on the channel-creation event's `name` tag and is what a Buzz client lists the channel under.
Without it every lane inherits the publisher's default, `firstmate-bearings`, and a captain browsing the client reads one identical row per lane, separable only by UUID - correctly addressed and unreadable, which defeats the point of a lane.
The fleet channel is published with no name option at all, so that default still applies to it and the name a captain has been reading stays put alongside the id.
A name is display metadata and never touches the id derivation, which is why the two are separate options rather than one.
`crew-<home qualifier>-<task id>` cannot exceed the publisher's 100-character bound, because the qualifier is eight characters and a task id is already restricted to 64 characters by the grammar above.
`tests/fm-buzz-crew-lanes.test.sh` reads the channel-creation events back off the stub relay and asserts the published set is one name per crew plus the fleet's.

The name is set when the channel is created and never afterwards, which is a property of the relay rather than a choice made here.
Channel creation is idempotent by design - the publisher re-sends it on every run and the relay answers `duplicate: channel already exists` - so a channel that already exists keeps the name it was created with and a changed `--channel-name` has no visible effect on it.
Verified on the running loopback relay on 2026-08-20: after republishing every lane with task-specific display names, `select id, name from channels` still returned `firstmate-bearings` for all ten pre-existing lanes.
Renaming an existing channel would need a NIP-29 metadata-edit event, which is the new protocol surface this adapter declined to take on for threads and declines again here.
On this disposable stack the recovery is the one the compose file already documents: `docker compose -f docker-compose.buzz-loopback.yml down -v` drops the datastores, and the next refresh recreates every channel under its current name.

### What a lane carries

Each lane is itself a valid `fm-bearings.v1` projection with `view: "crew-lane"`: the same `home`, `generated` and `prs` identity, an `in_flight[]` narrowed to exactly one row, plus `crew{id,kind,harness,mode}` and the bounded `status_events[]` for that task.
Being a valid projection is what lets the publisher validate and sign it through the path it already had, with no second contract to keep in sync.
The fleet projection's `omitted[]` is carried through untouched and each lane's own bounds - events dropped by the line cap, a status log read only from its last bytes, per-event text truncation, an absent status log, an in-flight entry with no current task record, or a lane that could not be projected - are appended after it.

The per-crew lane non-widening contract was the load-bearing question here, so the reasoning is recorded rather than assumed.
A lane may carry only what the fleet projection already publishes about a task, at more depth, and never a surface that projection deliberately dropped.
The deliberate drops are the ones it enumerates in its own `omitted[]`: backlog item bodies, task paths, watch/steer actions, and healthy endpoint detail.
None of them appear in a lane, and `bin/fm-buzz-crew-lanes.sh` withholds worktree paths, home paths, status-log paths, endpoint targets and backends even though it has them in hand.
Status-line text is not on that list: the fleet projection already publishes it as `in_flight[].doing`, so a lane publishes more of the same stream, bounded and disclosed, rather than a new surface.
The lane set is exactly the `in_flight[]` set the fleet projection already published, so a task the fleet projection bounded away does not gain a lane by the back door.

`bin/fm-fleet-snapshot.sh --json` was checked before any new reader was written, as the rule requires.
It exposes per-task `kind`, `harness`, `mode` and `paths.status_log.last_event`, but only that last event - never the stream - so the stream is read from the path the canonical snapshot names, bounded and disclosed.
The snapshot is consulted once per refresh, and it is reconciled with the bearings projection by task id rather than assumed to be simultaneous.

### The trigger

Nothing auto-invokes any of this.
`bin/fm-buzz-refresh.sh` is one explicit call firstmate can make after a wake drain, and it is deliberately not a daemon, a watcher hook, a timer, or anything in a crewmate's own execution path.
That is what keeps invariant 3 real: Buzz stays off the critical path of both firstmate and every crewmate, so a relay that is down, slow, or absent cannot break a merge, a teardown, a wake drain, or a turn end.
The refresh forwards the fleet publication's exit status unchanged - the contract `bin/fm-buzz-publish.sh` already owned - and treats every crew-lane failure as a logged non-event, because an additive surface may never make anything louder than it was.
It also retries every nonempty cache partition for the selected relay, including lanes whose tasks have already completed, without signing a replacement projection.
The complete refresh has one absolute default 30-second deadline across snapshotting, lane projection, publisher lock waits, relay delivery, and cached replay inspection, and logs the work skipped when that deadline is spent.

## Using it

Bring the relay up, publish, read back, tear down.

### Prerequisites

Publishing requires Node.js with the global WebSocket API, `jq`, and Python 3.
Python 3 provides the descriptor-relative filesystem operations that keep replay-cache mutations inside pinned directories, so a missing `python3` is a loud non-zero startup error with an install-documentation pointer.

For native Docker:

```
docker compose -f docker-compose.buzz-loopback.yml up -d
bin/fm-buzz-keypair.sh                                             # once; prints the public key
bin/fm-buzz-refresh.sh                                             # publish the fleet channel and every crew lane
bin/fm-buzz-publish.sh --refresh                                   # or: the fleet channel alone
bin/fm-buzz-inspect.sh --full                                      # read it back (human diagnostic)
bin/fm-buzz-inspect.sh --crew <task id> --full                     # read one crewmate's lane back
docker compose -f docker-compose.buzz-loopback.yml down -v         # clean slate, volumes included
```

For Colima, create both loopback forwards before publishing:

```
colima start
buzz_colima_config=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-colima.XXXXXX")
buzz_colima_control="${buzz_colima_config}.sock"
colima ssh-config > "$buzz_colima_config"
docker compose -f docker-compose.buzz-loopback.yml up -d
ssh -F "$buzz_colima_config" -M -S "$buzz_colima_control" -fN \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:3000:127.0.0.1:3000 \
  -L '[::1]:3000:127.0.0.1:3000' colima
bin/fm-buzz-keypair.sh                                             # once; prints the public key
bin/fm-buzz-refresh.sh                                             # publish the fleet channel and every crew lane
bin/fm-buzz-inspect.sh --full                                      # read it back (human diagnostic)
docker compose -f docker-compose.buzz-loopback.yml down -v         # clean slate, volumes included
ssh -F "$buzz_colima_config" -S "$buzz_colima_control" -O exit colima
rm -f "$buzz_colima_config"
```

Bounded input and safe non-events keep optional publication from delaying or weakening Firstmate.
The header of `bin/fm-buzz-publish.sh` owns input, option, default, and termination mechanics.
[`configuration.md`](configuration.md#environment-variables) owns the runtime environment contract.
Its Buzz block also documents the Compose-only image and host-port overrides, including the required coupling between a custom host port and `FM_BUZZ_RELAY`.

Each home needs its own low-authority publishing identity so the main home and second mates cannot silently publish as one another when they share host storage.
Private-key custody keeps that identity out of logs, commits, command-line arguments, and other homes while retaining a fallback for hosts without a reachable keychain.
The header of `bin/fm-buzz-key-lib.sh` owns the exact store selection, per-home derivation, filename, permissions, and argument-safe read and write mechanics.

## Two facts about this host that are easy to lose

Both were established empirically on 2026-07-30 and cost real time to find.

**The relay resolves its tenant from the HTTP `Host` header.**
The bundled deployment community registers as `localhost:3000`, so a bare-IP host is rejected even though it is the same socket:

```
$ curl -i -H 'Host: 127.0.0.1:3000' ... http://127.0.0.1:3000/
HTTP/1.1 404 Not Found
relay: no community is configured for this host

$ curl -i -H 'Host: localhost:3000' ... http://127.0.0.1:3000/
HTTP/1.1 101 Switching Protocols
["AUTH","59d457592eec282d1cc1d98d1e715edf14d061c4c180b7a54426b89a53d04283"]
```

That is why the default relay URL is `ws://localhost:3000` and not `ws://127.0.0.1:3000`.
Both are loopback; only one is accepted.

**Under colima, a `0.0.0.0` publish reaches the LAN, and a `127.0.0.1` publish reaches nothing.**
Colima forwards published ports out of its VM over ssh.
A container published to `0.0.0.0` ends up bound `*:PORT` on the host and is reachable from the machine's LAN address, which would breach invariant 2 outright:

```
$ docker run -d -p 0.0.0.0:18080:80 nginx:alpine
$ curl -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/     # 200
$ curl -o /dev/null -w '%{http_code}' http://192.168.1.247:18080/ # 200  <- LAN reachable
$ lsof -nP -iTCP:18080 | grep LISTEN
ssh  ...  TCP *:18080 (LISTEN)
```

The compose file therefore publishes `127.0.0.1:3000:3000`, which colima does not forward at all, so on this host the relay needs an explicit loopback tunnel to be reachable:

```
colima ssh-config > /tmp/colima-ssh.config
ssh -F /tmp/colima-ssh.config -L 127.0.0.1:3000:127.0.0.1:3000 -N colima &
ssh -F /tmp/colima-ssh.config -L '[::1]:3000:127.0.0.1:3000'   -N colima &   # localhost resolves to ::1 first
```

The tunnel binds loopback only, verified with `lsof -nP -iTCP:3000` showing `127.0.0.1:3000 (LISTEN)` and `[::1]:3000 (LISTEN)`, never `*:3000`.
On a native Linux Docker host no tunnel is needed and the compose file works as written.

Note also that `docker compose` is not installed on this machine (the Docker CLI and colima are, the compose plugin is not).
Compose was driven from a throwaway container rather than installing anything durable on the host:

```
docker run -i --rm -v /var/run/docker.sock:/var/run/docker.sock docker:cli \
  compose -p buzz-loopback -f - up -d < docker-compose.buzz-loopback.yml
```

## Idempotency, and why rebuilding a replay is the trap

The header of `bin/fm-buzz-lib.mjs` owns the signed-event identity and byte-preserving replay contract.
The header and implementation of `bin/fm-buzz-publish.mjs` own active-cache and quarantine layout, write and recovery ordering, validation, pruning, accounting, notices, and cleanup.
The header and implementation of `bin/fm-buzz-lib.mjs` own relay acknowledgement classification and the late-authentication state machine.

## Verification evidence

Run on 2026-07-30 against `ghcr.io/block/buzz:main`, Docker server 29.5.2 under colima, Docker Compose v5.3.1, Node v22.23.0.

| Exit gate | Result |
|---|---|
| Legible on desktop | **pass** - read back off the relay with signature verified and the projection byte-identical, `omitted[]` included |
| Legible on mobile | **deferred: captain hands-on verification** - needs a Buzz mobile client; upstream still files mobile under "being wired up" and gates its richer surfaces to desktop |
| Kill mid-publish, no duplicate and no loss | **pass** - relay stopped mid-run, event retained in the cache, delivered on restart; relay held 3 events with no duplicate ids |
| Firstmate operational with Buzz down | **pass** - see below |
| Boundary respected | **pass** - no change to `AGENTS.md`, `projects/`, or the `state/*.meta` schema |

The independence check is structural as well as behavioral: no operational Firstmate path outside the `bin/fm-buzz-*` family invokes the adapter, so a stopped relay has no path by which to reach supervision.
`tests/fm-buzz-inspect.test.sh` asserts that as a standing regression test.
With the relay stopped, `bin/fm-bearings-snapshot.sh --json`, `bin/fm-fleet-snapshot.sh --json` and `tasks-axi list` all exited 0 against an isolated home, and publishing exited 0 while enqueueing the signed event.

The exit-gate runs used an isolated `FM_HOME` rather than the live one.
`bin/fm-session-start.sh` and `bin/fm-watch-arm.sh` were deliberately not run against the live home, because taking the session lock or arming a watcher would have disrupted the running fleet; their independence from Buzz follows from the structural check above.

The default automated lane runs against a stub relay (`tests/fm-buzz-stub-relay.mjs`) so it passes on a CI runner with no Docker.
The stub verifies every event's id and Schnorr signature before accepting it, so "the relay accepted it" is a real assertion rather than a stub agreeing with whatever it is sent.
Setting `FM_BUZZ_DOCKER_INTEGRATION=1` enables the opt-in Compose relay signer-lifecycle regression on a Docker-capable host.

## Known limitations

The purpose-limited Schnorr implementation is not constant time and must not protect an authoritative or privileged key.
The header of `bin/fm-buzz-crypto.mjs` owns its implementation limits, permitted scope, and vector-coverage contract.

Buzz documents no key-rotation procedure, so this adapter supplies one to keep historical projections attributable without trusting compromised identities.
Rotation must stay adapter-owned rather than manual because custody location varies by host and the fallback path is derived from the operational home.
The inspector uses current and uncompromised historical public keys as authorship evidence, while private-key exposure invalidates that evidence and requires explicit withdrawal.
`bin/fm-buzz-keypair.sh --help` owns the detailed rotation, compromised-recovery, and historical-key withdrawal decision procedure.

Buzz is pre-1.0 with no long-term support branches and a very high release cadence, so `ghcr.io/block/buzz:main` can move under this adapter at any time.
The relay stack is disposable by design, while durable adapter target records survive relay-volume disposal so rotation cannot mistake missing relay state for proof that a channel was retired.
`bin/fm-buzz-keypair.sh --help` owns the explicit target-retirement and rotation recovery procedure.

## Out of scope

Per-task lanes shipped; see [Per-crew lanes](#per-crew-lanes) above.
Artifact delivery and channel membership management are still Milestone 2.
NIP-OA signed approval provenance is Milestone 3.
Reading state back from Buzz, canvases, Buzz workflows, and any hosted account are out of scope permanently, or until the study that ruled them out is re-opened.

## Maintaining this file

Keep this file as the one place that states the adapter's invariants and its verification evidence.
Mechanics belong in each script's header and `--help`, not here.
When a fact here is superseded, rewrite it rather than appending a correction, and keep the evidence sections as evidence: exact commands, exact output, and the date they were run.
