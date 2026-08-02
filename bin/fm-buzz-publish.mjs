#!/usr/bin/env node
// Publishing engine behind bin/fm-buzz-publish.sh: sign one bearings event, put
// it in the replay cache, then drain the cache to the loopback relay.
//
// This file may exit non-zero - that is deliberate. The fire-and-forget contract
// belongs to the shell wrapper, which is the only supported entry point and which
// converts every failure here into a logged exit 0. Keeping the engine honest
// about failure is what makes it testable; keeping the wrapper unconditionally
// successful is what keeps Buzz off Firstmate's critical path.
//
// THE REPLAY CACHE IS THE QUEUE
// The signed event is written to the cache BEFORE any network attempt, so a kill
// between signing and delivery loses nothing: the next run finds the event and
// replays it. Replay resends the exact stored bytes, never a re-signed event,
// because a NIP-01 event id covers `created_at` - re-signing the same logical
// message would mint a new id and the relay would store it as a second event
// instead of deduping it away. A cache entry is removed when the relay
// acknowledges it (including `duplicate:`, which means the relay already has that
// id) or when the rejection is permanent and replaying could never succeed.
//
// Reads one JSON envelope on stdin so that neither the private key nor the
// projection - which carries task ids, project names, blockers and PR URLs -
// appears in a command line or in the process environment. Fields: privateKey,
// content, relay, channelId, channelName, timeoutMs, replayDir, maxCache.

import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  readdirSync,
  statSync,
  unlinkSync,
  renameSync,
} from "node:fs";
import path from "node:path";
import {
  buildBearingsEvent,
  buildChannelCreateEvent,
  classifyOkResponse,
  readStdin,
  resolveLoopbackRelayHost,
  withRelay,
  DELIVERED,
  PERMANENT,
  RETRYABLE,
} from "./fm-buzz-lib.mjs";

function log(message) {
  process.stderr.write(`fm-buzz-publish: ${message}\n`);
}

// Each relay host gets its own directory, with entries named
// <created_at>-<id>.json. The directory is part of the cache key: changing relay
// host (including its port) cannot expose one relay's queued snapshots to
// another. created_at is parsed back out for ordering rather than relying on
// lexicographic sort, which would misorder the moment the epoch gains a digit.
function relayCacheDirectory(replayDir, relayHost) {
  return path.join(replayDir, encodeURIComponent(relayHost));
}

function cacheEntries(replayDir) {
  let names;
  try {
    names = readdirSync(replayDir);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.endsWith(".json"))
    .map((name) => {
      const match = /^(\d+)-([0-9a-f]{64})\.json$/.exec(name);
      if (!match) return null;
      return { name, createdAt: Number(match[1]), id: match[2], file: path.join(replayDir, name) };
    })
    .filter(Boolean)
    .sort((a, b) => (a.createdAt - b.createdAt) || a.id.localeCompare(b.id));
}

// The cap remains global across relay hosts. A separate 100-entry allowance per
// port would let repeated local relay switches grow the private queue without
// bound, so pruning considers both keyed directories and pre-key legacy files.
function cacheDirectories(replayDir) {
  let names;
  try {
    names = readdirSync(replayDir);
  } catch {
    return [replayDir];
  }
  const directories = [replayDir];
  for (const name of names) {
    const directory = path.join(replayDir, name);
    try {
      if (statSync(directory).isDirectory()) directories.push(directory);
    } catch {
      // Vanished under us, or not readable.
    }
  }
  return directories;
}

// A `.json.tmp` is the half of cacheEvent's atomic write that a kill between the
// write and the rename leaves behind. It matches neither the drain's `.json`
// filter nor the cap's accounting, so without this it is never published, never
// counted, and never removed - one signed projection leaked per interrupted run,
// forever. Age-gated so a concurrent run's in-flight write is not deleted out
// from under it; an incomplete entry is dropped rather than repaired, because
// only a completed rename means the bytes are whole enough to send.
const ORPHAN_TMP_AGE_MS = 60000;

function sweepOrphanTemporaries(replayDir, now) {
  let names;
  try {
    names = readdirSync(replayDir);
  } catch {
    return 0;
  }
  let swept = 0;
  for (const name of names) {
    if (!name.endsWith(".json.tmp")) continue;
    const file = path.join(replayDir, name);
    try {
      if (now - statSync(file).mtimeMs < ORPHAN_TMP_AGE_MS) continue;
      unlinkSync(file);
      swept += 1;
    } catch {
      // Vanished under us, or never ours to remove.
    }
  }
  if (swept > 0) log(`swept ${swept} interrupted cache write(s)`);
  return swept;
}

// Keep the cache bounded. An unbounded queue after a long relay outage would grow
// without limit and replay ancient fleet state; oldest-first is the right thing to
// drop because a newer bearings projection supersedes an older one anyway.
function pruneCache(replayDir, maxCache) {
  const directories = cacheDirectories(replayDir);
  const now = Date.now();
  for (const directory of directories) sweepOrphanTemporaries(directory, now);
  const entries = directories
    .flatMap((directory) => cacheEntries(directory))
    .sort((a, b) => (a.createdAt - b.createdAt) || a.id.localeCompare(b.id));
  const excess = entries.length - maxCache;
  if (excess <= 0) return 0;
  let dropped = 0;
  for (const entry of entries.slice(0, excess)) {
    try {
      unlinkSync(entry.file);
      dropped += 1;
    } catch {
      // A file that vanished under us needs no action.
    }
  }
  if (dropped > 0) log(`replay cache over ${maxCache}; dropped ${dropped} oldest event(s)`);
  return dropped;
}

// Write the frame atomically so a crash mid-write cannot leave a truncated event
// in the cache that would be replayed forever and rejected every time.
function cacheEvent(replayDir, event) {
  mkdirSync(replayDir, { recursive: true, mode: 0o700 });
  const frame = JSON.stringify(["EVENT", event]);
  const target = path.join(replayDir, `${event.created_at}-${event.id}.json`);
  const tmp = `${target}.tmp`;
  writeFileSync(tmp, frame, { mode: 0o600 });
  renameSync(tmp, target);
  return target;
}

async function main() {
  const envelope = JSON.parse(await readStdin());
  const {
    privateKey,
    content,
    relay,
    channelId,
    channelName = "firstmate-bearings",
    timeoutMs = 15000,
    replayDir,
    maxCache = 100,
  } = envelope;

  for (const [name, value] of Object.entries({ privateKey, content, relay, channelId, replayDir })) {
    if (typeof value !== "string" || value === "") throw new Error(`missing envelope field: ${name}`);
  }
  const relayHost = resolveLoopbackRelayHost(relay);
  const relayCacheDir = relayCacheDirectory(replayDir, relayHost);

  // Sign and cache first: from here on the event survives a crash, a kill, or a
  // relay that is not running at all.
  const event = buildBearingsEvent(channelId, content, privateKey, [
    ["fm-schema", "fm-bearings.v1"],
  ]);
  cacheEvent(relayCacheDir, event);
  pruneCache(replayDir, maxCache);
  log(`signed event ${event.id} (${Buffer.byteLength(content, "utf8")} bytes) for channel ${channelId}`);

  const pending = cacheEntries(relayCacheDir);
  // Final verdict per cache entry rather than running counters, because an entry
  // can be attempted twice: a pass that ran before a late NIP-42 handshake
  // completed is superseded by the one that ran after it, and incrementing
  // counters would report the same event as both retained and delivered.
  const outcome = new Map();
  const authRefused = new Set();

  await withRelay(relay, privateKey, timeoutMs, async (api) => {
    // A challenged relay that refuses or never answers the response will refuse
    // the events too, and `auth-required:` on its own does not say why. Naming the
    // handshake outcome once is what makes that stderr line diagnosable.
    const auth = await api.authenticateIfChallenged();
    if (auth === "refused" || auth === "unacknowledged") log(`NIP-42 authentication ${auth}`);

    // Idempotent channel provisioning. The relay answers `duplicate: channel
    // already exists` on every run after the first; a failure here is not fatal
    // because the channel may already exist and only the message matters.
    // Returns true when the refusal was `auth-required:`, which is a statement
    // about the handshake rather than about the channel.
    const provisionChannel = async () => {
      try {
        const create = buildChannelCreateEvent(
          channelId,
          channelName,
          "Firstmate bearings projections (read-only publisher)",
          privateKey,
        );
        const response = await api.publish(create);
        const message = String(response.message);
        if (!response.accepted && !message.startsWith("duplicate:")) {
          log(`channel provisioning refused: ${message}`);
          return message.startsWith("auth-required:");
        }
      } catch (error) {
        log(`channel provisioning failed: ${error.message}`);
      }
      return false;
    };

    // Offer `entries` to the relay, recording each one's verdict. Returns true if
    // anything was refused for want of authentication.
    const drain = async (entries) => {
      let authBlocked = false;
      for (const entry of entries) {
        let raw;
        try {
          raw = readFileSync(entry.file, "utf8");
        } catch {
          outcome.delete(entry.id);
          continue; // pruned or removed concurrently
        }
        let parsed;
        try {
          parsed = JSON.parse(raw)[1];
        } catch {
          // A corrupt cache entry can never be delivered; drop it rather than
          // retrying it on every future run.
          log(`dropping unparseable cache entry ${entry.name}`);
          try {
            unlinkSync(entry.file);
          } catch { /* already gone */ }
          outcome.set(entry.id, PERMANENT);
          continue;
        }
        // The relay verdict and the cache eviction are settled separately on
        // purpose. Evicting inside the publish try meant a failed unlink AFTER a
        // successful delivery was caught as "delivery unresolved" and counted as
        // retained - reporting a landed event as lost and turning a local
        // filesystem hiccup into a non-zero exit. The event's fate is decided by
        // the relay; a leftover file is only a redundant replay, which the relay's
        // id dedupe absorbs.
        let verdict;
        try {
          const response = await api.publish(parsed, raw);
          const message = String(response.message);
          verdict = classifyOkResponse(response.accepted, message);
          if (verdict === PERMANENT) log(`permanently rejected ${entry.id}: ${message}`);
          if (verdict !== DELIVERED && verdict !== PERMANENT) {
            log(`retryable rejection for ${entry.id}: ${message}`);
            if (message.startsWith("auth-required:")) {
              authBlocked = true;
              authRefused.add(entry.id);
            }
          }
        } catch (error) {
          // Includes the genuinely-unknown case: sent, socket closed, no OK. The
          // entry stays cached and the relay's id dedupe makes the replay a no-op
          // if it did in fact land.
          log(`delivery unresolved for ${entry.id}: ${error.message}`);
          outcome.set(entry.id, RETRYABLE);
          continue;
        }

        outcome.set(entry.id, verdict);
        if (verdict !== DELIVERED && verdict !== PERMANENT) continue;
        try {
          unlinkSync(entry.file);
        } catch (error) {
          log(`could not drop settled cache entry ${entry.name}: ${error.message}`);
        }
      }
      return authBlocked;
    };

    const blockedByProvisioning = await provisionChannel();
    const blockedByDrain = await drain(pending);

    // `auth-required:` here means the handshake window closed before the relay's
    // challenge arrived, not that this home may not publish. Settling that
    // challenge and re-offering exactly what it refused is what keeps a relay
    // that challenges late from wedging the cache: without it the same race is
    // re-run every time and the home never publishes at all.
    if (blockedByProvisioning || blockedByDrain) {
      const late = await api.completeLateAuthentication();
      if (late === "authenticated") {
        const retry = pending.filter((entry) => authRefused.has(entry.id));
        log(`authenticated after the handshake window; re-attempting ${retry.length} refused event(s)`);
        await provisionChannel();
        await drain(retry);
      } else if (late === "refused" || late === "unacknowledged") {
        log(`NIP-42 authentication ${late} after the handshake window; refused events stay cached`);
      }
    }
  });

  let delivered = 0;
  let kept = 0;
  let discarded = 0;
  for (const verdict of outcome.values()) {
    if (verdict === DELIVERED) delivered += 1;
    else if (verdict === PERMANENT) discarded += 1;
    else kept += 1;
  }

  log(`delivered=${delivered} retained=${kept} discarded=${discarded} relay=${relay}`);
  return kept === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    log(`failed: ${error.message}`);
    process.exit(1);
  },
);
