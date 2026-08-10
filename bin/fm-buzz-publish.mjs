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
  lstatSync,
  realpathSync,
  unlinkSync,
  renameSync,
} from "node:fs";
import path from "node:path";
import {
  buildBearingsEvent,
  buildChannelCreateEvent,
  classifyOkResponse,
  readStdin,
  relayCacheKey,
  resolveLoopbackRelayHost,
  validateSignedEvent,
  withRelay,
  DELIVERED,
  KIND_STREAM_MESSAGE,
  PERMANENT,
  RETRYABLE,
} from "./fm-buzz-lib.mjs";

function log(message) {
  process.stderr.write(`fm-buzz-publish: ${message}\n`);
}

function cachedEventFromFrame(raw, entry) {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch {
    throw new Error("invalid JSON");
  }
  if (!Array.isArray(frame) || frame.length !== 2 || frame[0] !== "EVENT") {
    throw new Error("not a complete EVENT frame");
  }
  const event = frame[1];
  const validation = validateSignedEvent(event);
  if (!validation.eventObject) throw new Error("event is not an object");
  if (!validation.validId) throw new Error("malformed event id");
  if (!validation.validPubkey) throw new Error("malformed event pubkey");
  if (!validation.validSignature) throw new Error("malformed event signature");
  if (!validation.validTimestamp) throw new Error("malformed event timestamp");
  if (event.kind !== KIND_STREAM_MESSAGE) throw new Error("unexpected event kind");
  if (!validation.validTags) throw new Error("malformed event tags");
  if (!validation.validContent) throw new Error("malformed event content");
  if (event.id !== entry.id || event.created_at !== entry.createdAt) {
    throw new Error("cache filename does not match the event");
  }
  if (validation.idError) throw new Error("event id could not be computed");
  if (!validation.idMatches) throw new Error("event id does not match its content");
  if (validation.signatureError) throw new Error("event signature could not be checked");
  if (!validation.signatureValid) throw new Error("invalid event signature");
  return event;
}

function containedCachePath(replayDir, candidate) {
  const relative = path.relative(replayDir, path.resolve(candidate));
  return relative !== "" && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function removeCacheFile(replayDir, file, description) {
  if (!containedCachePath(replayDir, file)) {
    log(`could not ${description}: path escapes replay cache`);
    return { removed: false, failed: true };
  }
  try {
    unlinkSync(file);
    return { removed: true, failed: false };
  } catch (error) {
    if (error.code === "ENOENT") return { removed: false, failed: false };
    log(`could not ${description}: ${error.message}`);
    return { removed: false, failed: true };
  }
}

// Each normalized relay endpoint gets its own digest directory, with entries
// named <created_at>-<id>.json. created_at is parsed back out for ordering rather than relying on
// lexicographic sort, which would misorder the moment the epoch gains a digit.
function relayCacheDirectory(replayDir, relay) {
  return path.join(replayDir, relayCacheKey(relay));
}

function prepareCacheRoot(replayDir) {
  const requested = path.resolve(replayDir);
  mkdirSync(requested, { recursive: true, mode: 0o700 });
  const metadata = lstatSync(requested);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`replay cache path ${replayDir} is not a regular directory`);
  }
  return realpathSync(requested);
}

function prepareRelayCacheDirectory(replayDir, relay) {
  const directory = relayCacheDirectory(replayDir, relay);
  if (!containedCachePath(replayDir, directory)) throw new Error("relay cache path escapes replay cache");
  try {
    const metadata = lstatSync(directory);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new Error(`relay cache path ${directory} is not a regular directory`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    mkdirSync(directory, { mode: 0o700 });
  }
  const metadata = lstatSync(directory);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`relay cache path ${directory} is not a regular directory`);
  }
  const resolved = realpathSync(directory);
  if (!containedCachePath(replayDir, resolved)) throw new Error("relay cache path escapes replay cache");
  return directory;
}

function cacheEntries(replayDir) {
  let names;
  try {
    names = readdirSync(replayDir);
  } catch (error) {
    if (error.code === "ENOENT") return { entries: [], failures: [] };
    log(`could not inspect cache directory ${replayDir}: ${error.message}`);
    return { entries: [], failures: [replayDir] };
  }
  const entries = [];
  const failures = [];
  for (const name of names.filter((candidate) => candidate.endsWith(".json"))) {
    const file = path.join(replayDir, name);
    if (!containedCachePath(replayDir, file)) {
      failures.push(file);
      continue;
    }
    let metadata;
    try {
      metadata = lstatSync(file);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      log(`could not inspect cache entry ${file}: ${error.message}`);
      failures.push(file);
      continue;
    }
    const match = /^(\d+)-([0-9a-f]{64})\.json$/.exec(name);
    const createdAt = match ? Number(match[1]) : undefined;
    if (metadata.isSymbolicLink() || !match || !Number.isSafeInteger(createdAt)) {
      entries.push({
        name,
        file,
        malformed: true,
        reason: metadata.isSymbolicLink() ? "cache entry is a symbolic link" : "malformed cache filename",
      });
      continue;
    }
    entries.push({ name, createdAt, id: match[2], file, malformed: false });
  }
  entries.sort((a, b) => {
      if (a.malformed !== b.malformed) return a.malformed ? -1 : 1;
      if (a.malformed) return a.name.localeCompare(b.name);
      return (a.createdAt - b.createdAt) || a.id.localeCompare(b.id);
    });
  return { entries, failures };
}

// The cap remains global across relay hosts. A separate 100-entry allowance per
// port would let repeated local relay switches grow the private queue without
// bound, so pruning considers both keyed directories and pre-key legacy files.
function cacheDirectories(replayDir) {
  let names;
  try {
    names = readdirSync(replayDir);
  } catch (error) {
    if (error.code === "ENOENT") return { directories: [replayDir], failures: [] };
    log(`could not inspect cache directory ${replayDir}: ${error.message}`);
    return { directories: [replayDir], failures: [replayDir] };
  }
  const directories = [replayDir];
  const failures = [];
  for (const name of names) {
    if (name.endsWith(".json") || name.endsWith(".json.tmp")) continue;
    const directory = path.join(replayDir, name);
    try {
      const metadata = lstatSync(directory);
      if (metadata.isSymbolicLink()) {
        log(`rejected cache directory symlink ${directory}`);
        failures.push(directory);
      } else if (metadata.isDirectory()) {
        directories.push(directory);
      }
    } catch (error) {
      if (error.code === "ENOENT") continue;
      log(`could not inspect cache path ${directory}: ${error.message}`);
      failures.push(directory);
    }
  }
  return { directories, failures };
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
  } catch (error) {
    if (error.code === "ENOENT") return { swept: 0, failed: 0 };
    log(`could not inspect cache directory ${replayDir}: ${error.message}`);
    return { swept: 0, failed: 1 };
  }
  let swept = 0;
  let failed = 0;
  for (const name of names) {
    if (!name.endsWith(".json.tmp")) continue;
    const file = path.join(replayDir, name);
    let modified;
    try {
      modified = lstatSync(file).mtimeMs;
    } catch (error) {
      if (error.code !== "ENOENT") {
        log(`could not inspect interrupted cache write ${name}: ${error.message}`);
        failed += 1;
      }
      continue;
    }
    if (now - modified < ORPHAN_TMP_AGE_MS) continue;
    const removal = removeCacheFile(replayDir, file, `sweep interrupted cache write ${name}`);
    if (removal.removed) swept += 1;
    if (removal.failed) failed += 1;
  }
  if (swept > 0) log(`swept ${swept} interrupted cache write(s)`);
  return { swept, failed };
}

// Keep the cache bounded. An unbounded queue after a long relay outage would grow
// without limit and replay ancient fleet state; oldest-first is the right thing to
// drop because a newer bearings projection supersedes an older one anyway.
function pruneCache(replayDir, maxCache, protectedFile) {
  const topology = cacheDirectories(replayDir);
  const directories = topology.directories;
  const now = Date.now();
  let failed = topology.failures.length;
  const outcomes = new Map(topology.failures.map((file) => [`uninspected:${file}`, RETRYABLE]));
  for (const directory of directories) failed += sweepOrphanTemporaries(directory, now).failed;
  const inventories = directories.map((directory) => cacheEntries(directory));
  for (const inventory of inventories) {
    failed += inventory.failures.length;
    for (const file of inventory.failures) outcomes.set(`unreadable:${file}`, RETRYABLE);
  }
  const entries = inventories.flatMap((inventory) => inventory.entries);
  const validEntries = [];
  let malformedRetained = 0;
  for (const entry of entries) {
    if (!entry.malformed) {
      validEntries.push(entry);
      continue;
    }
    log(`dropping invalid cache entry ${entry.name}: ${entry.reason}`);
    const removal = removeCacheFile(replayDir, entry.file, `drop invalid cache entry ${entry.name}`);
    if (removal.removed) outcomes.set(`invalid:${entry.file}`, PERMANENT);
    if (removal.failed) {
      failed += 1;
      malformedRetained += 1;
      outcomes.set(`invalid:${entry.file}`, RETRYABLE);
    }
  }
  validEntries.sort((a, b) => (a.createdAt - b.createdAt) || a.id.localeCompare(b.id));
  const excess = validEntries.length + malformedRetained - maxCache;
  if (excess <= 0) return { entries: validEntries, dropped: 0, failed, outcomes };
  let dropped = 0;
  const pruned = new Set();
  for (const entry of validEntries) {
    if (dropped >= excess) break;
    if (entry.file === protectedFile) continue;
    const removal = removeCacheFile(replayDir, entry.file, `prune cache entry ${entry.name}`);
    if (removal.removed) {
      dropped += 1;
      pruned.add(entry.file);
    }
    if (removal.failed) failed += 1;
  }
  if (dropped > 0) log(`replay cache over ${maxCache}; dropped ${dropped} oldest event(s)`);
  return {
    entries: validEntries.filter((entry) => !pruned.has(entry.file)),
    dropped,
    failed,
    outcomes,
  };
}

// Write the frame atomically so a crash mid-write cannot leave a truncated event
// in the cache that would be replayed forever and rejected every time.
function cacheEvent(replayDir, event) {
  const metadata = lstatSync(replayDir);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`relay cache path ${replayDir} is not a regular directory`);
  }
  const frame = JSON.stringify(["EVENT", event]);
  const target = path.join(replayDir, `${event.created_at}-${event.id}.json`);
  const tmp = `${target}.tmp`;
  const root = path.dirname(replayDir);
  if (!containedCachePath(root, target) || !containedCachePath(root, tmp)) {
    throw new Error("cache event path escapes replay cache");
  }
  writeFileSync(tmp, frame, { mode: 0o600, flag: "wx" });
  try {
    renameSync(tmp, target);
  } catch (error) {
    try {
      unlinkSync(tmp);
    } catch (cleanupError) {
      if (cleanupError.code !== "ENOENT") log(`could not remove interrupted cache write: ${cleanupError.message}`);
    }
    throw error;
  }
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
  if (!Number.isSafeInteger(maxCache) || maxCache <= 0) {
    throw new Error(`invalid FM_BUZZ_MAX_CACHE value ${JSON.stringify(maxCache)}: expected a positive integer`);
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2147483647) {
    throw new Error(`invalid relay timeout ${JSON.stringify(timeoutMs)}: expected an integer from 1 to 2147483647`);
  }
  resolveLoopbackRelayHost(relay);
  const cacheRoot = prepareCacheRoot(replayDir);
  const relayCacheDir = prepareRelayCacheDirectory(cacheRoot, relay);

  // Sign and cache first: from here on the event survives a crash, a kill, or a
  // relay that is not running at all.
  const event = buildBearingsEvent(channelId, content, privateKey, [
    ["fm-schema", "fm-bearings.v1"],
  ]);
  const currentFile = cacheEvent(relayCacheDir, event);
  const cacheMaintenance = pruneCache(cacheRoot, maxCache, currentFile);
  let cleanupFailures = cacheMaintenance.failed;
  log(`signed event ${event.id} (${Buffer.byteLength(content, "utf8")} bytes) for channel ${channelId}`);

  const pending = cacheMaintenance.entries.filter((entry) => path.dirname(entry.file) === relayCacheDir);
  // Final verdict per cache entry rather than running counters, because an entry
  // can be attempted twice: a pass that ran before a late NIP-42 handshake
  // completed is superseded by the one that ran after it, and incrementing
  // counters would report the same event as both retained and delivered.
  const outcome = new Map(cacheMaintenance.outcomes);
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
        if (classifyOkResponse(response.accepted, message) !== DELIVERED) {
          log(`channel provisioning refused: ${message}`);
          return response.accepted === false && message.startsWith("auth-required:");
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
        } catch (error) {
          if (error.code === "ENOENT") {
            outcome.delete(entry.file);
            continue;
          }
          log(`could not read cache entry ${entry.name}: ${error.message}`);
          outcome.set(entry.file, RETRYABLE);
          continue;
        }
        let parsed;
        try {
          parsed = cachedEventFromFrame(raw, entry);
        } catch (error) {
          log(`dropping invalid cache entry ${entry.name}: ${error.message}`);
          const removal = removeCacheFile(cacheRoot, entry.file, `drop invalid cache entry ${entry.name}`);
          if (removal.failed) {
            cleanupFailures += 1;
            outcome.set(entry.file, RETRYABLE);
          } else {
            outcome.set(entry.file, PERMANENT);
          }
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
            if (response.accepted === false && message.startsWith("auth-required:")) {
              authBlocked = true;
              authRefused.add(entry.id);
            }
          }
        } catch (error) {
          // Includes the genuinely-unknown case: sent, socket closed, no OK. The
          // entry stays cached and the relay's id dedupe makes the replay a no-op
          // if it did in fact land.
          log(`delivery unresolved for ${entry.id}: ${error.message}`);
          outcome.set(entry.file, RETRYABLE);
          continue;
        }

        outcome.set(entry.file, verdict);
        if (verdict !== DELIVERED && verdict !== PERMANENT) continue;
        const removal = removeCacheFile(cacheRoot, entry.file, `drop settled cache entry ${entry.name}`);
        if (removal.failed) cleanupFailures += 1;
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

  log(
    `delivered=${delivered} retained=${kept} discarded=${discarded} cleanup_failed=${cleanupFailures} relay=${relay}`,
  );
  return kept === 0 && cleanupFailures === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    log(`failed: ${error.message}`);
    process.exit(1);
  },
);
