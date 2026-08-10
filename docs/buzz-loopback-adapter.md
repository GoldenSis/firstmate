# Buzz loopback adapter (Milestone 1 proof of concept)

A one-way publisher that renders Firstmate's bearings projection into a private channel on a locally self-hosted Buzz relay.
It is additive: nothing in Firstmate reads it, depends on it, or waits for it.

This document is the reference for the adapter and the record of what was verified against a running relay.
Mechanics live in each script's own header and `--help`; this file covers the shape, the invariants, and the evidence.

## What it is

Buzz is Block's open-source Nostr-based workspace (Apache-2.0).
Its relevant property is that every message is an individually signed, individually verified event in an append-only log, and a private channel is enforced server-side - when membership is required - rather than trusted from the client.
The M1 stack deliberately does not require it, so nothing here relies on that enforcement; see invariant 2.
The adapter uses exactly that and nothing else: it signs one event per invocation carrying `bin/fm-bearings-snapshot.sh --json` verbatim, and publishes it to a private channel on a relay bound to loopback.

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
   The channel id is not a secret either: `channelIdForLabel` is a plain SHA-256 of the `FM_HOME` path, derived on purpose so a lost keypair cannot orphan the channel.
   A local process that created the group first would own it and could read the bearings projections published into it.
   That is an accepted risk for a proof of concept on a single-user laptop with a disposable stack; the boundary actually being relied on is "no other local user", not "no remote party".
   Closing it means enforcing membership, which belongs to Milestone 2 along with the rest of channel membership management.

   Disposable has to mean the exposure ends when the operator stops using the stack, so the relay carries `restart: "no"` and does not come back by itself after a reboot.
   The datastores do restart, because they only serve the internal compose network, and they self-resume across a host reboot still holding every published bearings projection.
   `docker compose -f docker-compose.buzz-loopback.yml down -v` is what ends the exposure for good, volumes included.
3. **Publishing is fire-and-forget.**
   `bin/fm-buzz-publish.sh` always exits 0.
   A non-zero exit from it is a bug, and `tests/fm-buzz-publish.test.sh` asserts both the behavior and the structure that produces it.
4. **No canvas for state.**
   Append-only messages only.
   A Buzz canvas is a single mutable TEXT column overwritten with no compare-and-set and no base hash, so publishing state into one would silently destroy concurrent captain edits with no error to either party.
   If a durable checkpoint is ever wanted, the surface with actual concurrency discipline is a NIP-AE engram with a base-hash precondition.
5. **No workflow approval gates.**
   Merge authority stays with `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` under `AGENTS.md` section 7.
   Buzz's own `request_approval` is unimplemented upstream and fails runs that reach it, and it must not be built on regardless.
   An approval that arrives via Buzz is evidence, never authority.

## Using it

Bring the relay up, publish, read back, tear down.

```
colima start                                                       # if the daemon is not running
docker compose -f docker-compose.buzz-loopback.yml up -d
bin/fm-buzz-keypair.sh                                             # once; prints the public key
bin/fm-buzz-publish.sh --refresh                                   # publish current bearings
bin/fm-buzz-inspect.sh --full                                      # read it back (human diagnostic)
docker compose -f docker-compose.buzz-loopback.yml down -v         # clean slate, volumes included
```

`bin/fm-buzz-publish.sh` reads the projection on stdin when `--refresh` is not given, so an already-captured snapshot can be republished without regenerating it.
That read is bounded (`FM_BUZZ_STDIN_TIMEOUT_S`, default 30) and refuses a terminal outright, because "never blocks Firstmate" has to mean the script terminates, not merely that it exits 0.
An expired read is discarded rather than published: a truncated projection is malformed JSON, and the `omitted[]` disclosure that makes a bounded projection honest sits at the end of it.
The rest of the runtime knobs (`FM_BUZZ_RELAY`, `FM_BUZZ_TIMEOUT_MS`, `FM_BUZZ_MAX_CACHE`, `FM_BUZZ_FORCE_FILE_STORE`) are listed with their defaults in [`configuration.md`](configuration.md#environment-variables), and the compose stack itself takes `BUZZ_IMAGE` and `BUZZ_LOOPBACK_PORT`; a non-default port needs a matching `FM_BUZZ_RELAY`.

The keypair is created once per home and stored in the OS keychain, falling back to a `0600` file when no keychain is reachable.
Both stores key on the resolved `FM_HOME` - the keychain through its account attribute, the fallback file through a digest of that account in its filename - so a secondmate home gets its own key and its own channel rather than publishing under the main home's identity.
The file store has to derive per-home too, not just the keychain: `XDG_DATA_HOME` follows the user rather than `FM_HOME`, so homes normally share one, and a fixed filename would break the invariant on exactly the hosts with no keychain to enforce it.

No command prints the private key, no keypair material is committed, and the key reaches no process's argv: `security -i` takes the keychain write on stdin, and `jq` receives the key through a file descriptor (`--rawfile`) rather than `--arg`.
An argv is world-readable through the process table, which is the whole reason for both.

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

## Idempotency, and why re-signing is the trap

A NIP-01 event id is a SHA-256 over `[0, pubkey, created_at, kind, tags, content]`, so `created_at` is part of the event's identity.
The relay dedupes on that id with `INSERT ... ON CONFLICT DO NOTHING`.
The consequence is sharp: resubmitting the byte-identical signed event is perfectly idempotent, while rebuilding and re-signing the same logical message mints a new id and lands a duplicate.

So the replay cache stores exact signed bytes and replays those bytes.
It is partitioned by relay host, using the layout in [`configuration.md`](configuration.md#operational-home-layout-and-state), so changing relays cannot expose one relay's queued snapshots to another.
It is written before any network attempt, which is what makes a kill between signing and delivery lossless.
An entry is removed when the relay acknowledges it, including a `duplicate:` answer, which means the relay already holds that id.
An entry is also removed when the rejection is permanent (`invalid:`, `blocked:`, `pow:`), because replaying it could never succeed and would loop forever.
A provisioning-shaped refusal (`auth-required:`, `restricted:`) is kept, since it can clear once the channel or membership exists.
The cache is capped at 100 entries, dropping oldest first, because a newer bearings projection supersedes an older one anyway.
A `.json.tmp` left by a kill between the cache write and its rename is swept once it is a minute old, so an interrupted run leaks neither an invisible file nor an unbounded pile of them.

`auth-required:` is a special case of "it can clear", and it can clear inside the same run.
The wait for a NIP-42 challenge has to be bounded, because an open relay never sends one and "no challenge yet" is indistinguishable from "no challenge ever" until a deadline passes.
So a relay that challenges late gets published to before the handshake finishes, and refuses everything for it.
The client answers that challenge when it lands and then re-offers exactly the events the unauthenticated window refused, which is what stops the same race being lost run after run with nothing published.
The honest worst case remains: if the challenge arrives after both windows, the run ends unauthenticated, the events stay cached, and the next run races it again.

## Verification evidence

Run on 2026-07-30 against `ghcr.io/block/buzz:main`, Docker server 29.5.2 under colima, Docker Compose v5.3.1, Node v22.23.0.

| Exit gate | Result |
|---|---|
| Legible on desktop | **pass** - read back off the relay with signature verified and the projection byte-identical, `omitted[]` included |
| Legible on mobile | **deferred: captain hands-on verification** - needs a Buzz mobile client; upstream still files mobile under "being wired up" and gates its richer surfaces to desktop |
| Kill mid-publish, no duplicate and no loss | **pass** - relay stopped mid-run, event retained in the cache, delivered on restart; relay held 3 events with no duplicate ids |
| Firstmate operational with Buzz down | **pass** - see below |
| Boundary respected | **pass** - no change to `AGENTS.md`, `projects/`, or the `state/*.meta` schema |

The independence check is structural as well as behavioral, which is the stronger form: nothing outside the `bin/fm-buzz-*` family references the adapter at all, so a stopped relay has no path by which to reach supervision.
`tests/fm-buzz-publish.test.sh` asserts that as a standing regression test.
With the relay stopped, `bin/fm-bearings-snapshot.sh --json`, `bin/fm-fleet-snapshot.sh --json` and `tasks-axi list` all exited 0 against an isolated home, and publishing exited 0 while enqueueing the signed event.

The exit-gate runs used an isolated `FM_HOME` rather than the live one.
`bin/fm-session-start.sh` and `bin/fm-watch-arm.sh` were deliberately not run against the live home, because taking the session lock or arming a watcher would have disrupted the running fleet; their independence from Buzz follows from the structural check above.

The automated suite runs against a stub relay (`tests/fm-buzz-stub-relay.mjs`) rather than the real stack, so it passes on a CI runner with no Docker.
The stub verifies every event's id and Schnorr signature before accepting it, so "the relay accepted it" is a real assertion rather than a stub agreeing with whatever it is sent.

## Known limitations

The Schnorr implementation in `bin/fm-buzz-crypto.mjs` is pure BigInt and therefore not constant time.
It exists because this host has no secp256k1 binding and the repo deliberately carries no npm dependency tree.
It is checked against the official BIP-340 vectors for 32-byte messages, including all ten negative cases, but it must not be reused for a key that guards anything.
That is the whole of NIP-01's usage and the whole of the coverage: the variable-length-message vectors (15-18) are excluded, and the signer rejects such messages outright rather than signing them.
That is acceptable for exactly this key: it signs fleet-status projections on a loopback relay, grants no authority, and is cheap to re-mint.

Buzz documents no key-rotation procedure, so `bin/fm-buzz-keypair.sh --rotate` is this adapter's.
It clears both stores - the keychain entry and the `0600` fallback file - plus `data/buzz-keypair.public`, then mints a fresh keypair and prints the new public key, and it refuses to report success if the old key is still loadable afterwards.
Rotating by hand is not offered because it does not work reliably: which store holds the key depends on the host, and the fallback file's name carries a digest of the home path, so deleting "the keychain entry" on a machine whose key lives in the file clears nothing and the next run re-prints the same public key.
Historical events stay signed by the retired key, which grants nothing and so needs no revocation.
The retired PUBLIC key is still evidence, though, when only this home ever held it: `bin/fm-buzz-inspect.sh --anonymous` decides whether a served event is this home's own content by its author, and the relay keeps serving pre-rotation events under a channel id that rotation does not change.
So rotation retains the retired public key in `data/buzz-keypair.public-history` before recording the new one, and the inspector attributes an event to this home if it was signed by any recorded key, current or retired.
Without that, rotating would make the probe report this home's own leaked projections as somebody else's content.

Retention assumes the retired key was never exposed.
If retiring due to suspected compromise, use `--compromised` so the key is not retained for verdict-matching.
A key whose private half somebody else may hold is no longer evidence of authorship at all: the channel id is not a secret, so that holder can mint an event the probe would report as this home's own leaked projection.
`--rotate --compromised` therefore declines to record the key it is retiring in that same run, at the cost of no longer attributing this home's genuine pre-rotation events.
It governs that key and no other: every rotation mints a fresh random key, so the key being retired is never one an earlier rotation already recorded, and a rotation cannot reach back to withdraw one.
An exposure that comes to light after the rotation that retired the key names the key instead - `bin/fm-buzz-keypair.sh --forget-key <hex>` drops exactly that public key from `data/buzz-keypair.public-history` and leaves every other recorded key, and this home's current key, alone.
It is its own operation rather than a rotation flag: nothing is minted, cleared, or re-recorded, and a key that is not in the recorded set is reported as such rather than treated as an error.
Either way the recorded-key set is settled before the private half is cleared, and the rotation stops rather than proceeding if it cannot be: once the key is forgotten nothing can derive the retired public key a second time, so a write failure at that point would permanently and silently cost the probe its attribution.
The outgoing key is accepted only as 64 lowercase hex characters, since `data/buzz-keypair.public` is a cache that can be truncated or half-written; anything else falls back to deriving the public half from the still-stored private key.
Ordinary rotation stops when the stored identity is unreadable, divergent, or inconsistent with that record, while `--rotate --compromised` is the explicit no-retention recovery path for removing every identifiable outgoing identity before minting a replacement.

Buzz is pre-1.0 with no long-term support branches and a very high release cadence, so `ghcr.io/block/buzz:main` can move under this adapter at any time.
The relay stack is disposable by design; `down -v` and `up -d` is the whole recovery procedure.

## Out of scope

Per-task rooms, artifact delivery, and channel membership management are Milestone 2.
NIP-OA signed approval provenance is Milestone 3.
Reading state back from Buzz, canvases, Buzz workflows, and any hosted account are out of scope permanently, or until the study that ruled them out is re-opened.

## Maintaining this file

Keep this file as the one place that states the adapter's invariants and its verification evidence.
Mechanics belong in each script's header and `--help`, not here.
When a fact here is superseded, rewrite it rather than appending a correction, and keep the evidence sections as evidence: exact commands, exact output, and the date they were run.
