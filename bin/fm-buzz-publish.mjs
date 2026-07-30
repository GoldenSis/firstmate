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
// Reads one JSON envelope on stdin so the private key never appears in a command
// line or in the process environment. Fields: privateKey, content, relay,
// channelId, channelName, timeoutMs, replayDir, maxCache.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, unlinkSync, renameSync } from "node:fs";
import path from "node:path";
import {
  buildBearingsEvent,
  buildChannelCreateEvent,
  classifyOkResponse,
  readStdin,
  withRelay,
  DELIVERED,
  PERMANENT,
} from "./fm-buzz-lib.mjs";

function log(message) {
  process.stderr.write(`fm-buzz-publish: ${message}\n`);
}

// Cache entries are named <created_at>-<id>.json. created_at is parsed back out
// for ordering rather than relying on lexicographic sort, which would misorder
// the moment the epoch gains a digit.
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

// Keep the cache bounded. An unbounded queue after a long relay outage would grow
// without limit and replay ancient fleet state; oldest-first is the right thing to
// drop because a newer bearings projection supersedes an older one anyway.
function pruneCache(replayDir, maxCache) {
  const entries = cacheEntries(replayDir);
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

  // Sign and cache first: from here on the event survives a crash, a kill, or a
  // relay that is not running at all.
  const event = buildBearingsEvent(channelId, content, privateKey, [
    ["fm-schema", "fm-bearings.v1"],
  ]);
  cacheEvent(replayDir, event);
  pruneCache(replayDir, maxCache);
  log(`signed event ${event.id} (${Buffer.byteLength(content, "utf8")} bytes) for channel ${channelId}`);

  const pending = cacheEntries(replayDir);
  let delivered = 0;
  let kept = 0;
  let discarded = 0;

  await withRelay(relay, privateKey, timeoutMs, async (api) => {
    await api.authenticateIfChallenged();

    // Idempotent channel provisioning. The relay answers `duplicate: channel
    // already exists` on every run after the first; a failure here is not fatal
    // because the channel may already exist and only the message matters.
    try {
      const create = buildChannelCreateEvent(
        channelId,
        channelName,
        "Firstmate bearings projections (read-only publisher)",
        privateKey,
      );
      const response = await api.publish(create);
      if (!response.accepted && !String(response.message).startsWith("duplicate:")) {
        log(`channel provisioning refused: ${response.message}`);
      }
    } catch (error) {
      log(`channel provisioning failed: ${error.message}`);
    }

    for (const entry of pending) {
      let raw;
      try {
        raw = readFileSync(entry.file, "utf8");
      } catch {
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
        discarded += 1;
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
        verdict = classifyOkResponse(response.accepted, response.message);
        if (verdict === PERMANENT) log(`permanently rejected ${entry.id}: ${response.message}`);
        if (verdict !== DELIVERED && verdict !== PERMANENT) {
          log(`retryable rejection for ${entry.id}: ${response.message}`);
        }
      } catch (error) {
        // Includes the genuinely-unknown case: sent, socket closed, no OK. The
        // entry stays cached and the relay's id dedupe makes the replay a no-op
        // if it did in fact land.
        log(`delivery unresolved for ${entry.id}: ${error.message}`);
        kept += 1;
        continue;
      }

      if (verdict === DELIVERED) delivered += 1;
      else if (verdict === PERMANENT) discarded += 1;
      else {
        kept += 1;
        continue;
      }
      try {
        unlinkSync(entry.file);
      } catch (error) {
        log(`could not drop settled cache entry ${entry.name}: ${error.message}`);
      }
    }
  });

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
