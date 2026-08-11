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
// REPLAY CACHE LIFECYCLE
// bin/fm-buzz-lib.mjs owns signed-event identity and byte-preserving replay
// semantics. This engine owns active-cache and quarantine layout, mutation
// order, validation, recovery, pruning, and relay outcomes because every
// mutation must share the pinned cache-directory interface below.
// Active entries live at <replay-root>/<endpoint-digest>/<created_at>-<event-id>.json,
// where endpoint-digest is SHA-256 of the complete normalized relay endpoint.
// A complete EVENT frame is cached atomically before target tracking or network
// access, pruning is oldest-first across active partitions while protecting the
// current event, and only a classified relay outcome removes a replay entry.
//
// Reads one JSON envelope on stdin so that neither the private key nor the
// projection - which carries task ids, project names, blockers and PR URLs -
// appears in a command line or in the process environment. Fields: privateKey,
// content, relay, channelId, channelName, timeoutMs, replayDir, targetsFile,
// maxCache.
//
// Legacy and explicitly discarded rotation entries are retained under
// _legacy-quarantine with payloads and manifests rather than silently deleted.
// Each claimed regular file moves through staging/<token>/{source,origin.json}
// into payloads/<token>.json, while corrupt cache nodes remain under
// corrupt/<token>/entry and invalid recovery residue remains under
// recovery-corrupt/<token>.invalid.
// A manifest at manifests/<token>.json identifies a record by original_path,
// legacy_host, payload_reference, source device and inode, corrupt_type,
// quarantine_reason, and publisher_pubkey, and records original timestamps,
// quarantine time, plus observed content evidence when the payload is readable.
// A lowercase SHA-256 token binds stable source provenance: original path,
// device, inode, and birthtime for regular files, or mode for corrupt partition
// nodes, without using access or link-mutated change time.
// Startup first accounts for invalid recovery residue, then completes manifest
// temporaries, staged regular files, and corrupt nodes before discovering new
// legacy entries, and it reports every unsettled mutation as a cleanup failure.

import {
  closeSync,
  constants,
  fstatSync,
  linkSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
  openSync,
  readlinkSync,
  readdirSync,
  lstatSync,
  realpathSync,
  rmdirSync,
  symlinkSync,
  unlinkSync,
  renameSync,
} from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
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
import { recordPublisherTarget } from "./fm-buzz-targets.mjs";

const CACHE_PARTITION = /^[0-9a-f]{64}$/;
const LEGACY_QUARANTINE = "_legacy-quarantine";

function log(message) {
  process.stderr.write(`fm-buzz-publish: ${message}\n`);
}

let replayRootPin = null;
const replayDirectoryPins = new Map();

function assertReplayRoot() {
  if (replayRootPin === null) return;
  const descriptorMetadata = fstatSync(replayRootPin.descriptor);
  const pathMetadata = lstatSync(replayRootPin.path);
  if (
    pathMetadata.isSymbolicLink() ||
    !pathMetadata.isDirectory() ||
    pathMetadata.dev !== replayRootPin.dev ||
    pathMetadata.ino !== replayRootPin.ino ||
    descriptorMetadata.dev !== replayRootPin.dev ||
    descriptorMetadata.ino !== replayRootPin.ino ||
    realpathSync(replayRootPin.path) !== replayRootPin.path
  ) {
    throw new Error("replay cache root identity changed during publication");
  }
}

function assertCacheDirectory(directory) {
  const resolved = path.resolve(directory);
  const pin = replayDirectoryPins.get(resolved);
  if (!pin) throw new Error(`cache directory is not pinned: ${resolved}`);
  const descriptorMetadata = fstatSync(pin.descriptor);
  const pathMetadata = lstatSync(resolved);
  if (
    pathMetadata.isSymbolicLink() ||
    !pathMetadata.isDirectory() ||
    pathMetadata.dev !== pin.dev ||
    pathMetadata.ino !== pin.ino ||
    descriptorMetadata.dev !== pin.dev ||
    descriptorMetadata.ino !== pin.ino ||
    realpathSync(resolved) !== resolved
  ) {
    throw new Error(`cache directory identity changed during publication: ${resolved}`);
  }
  return pin;
}

function pinCacheDirectory(directory) {
  assertReplayRoot();
  const resolved = path.resolve(directory);
  if (resolved !== replayRootPin.path && !containedCachePath(replayRootPin.path, resolved)) {
    throw new Error("cache directory escapes replay cache");
  }
  const existing = replayDirectoryPins.get(resolved);
  if (existing) {
    assertCacheDirectory(resolved);
    return resolved;
  }
  const pathMetadata = lstatSync(resolved);
  if (pathMetadata.isSymbolicLink() || !pathMetadata.isDirectory() || realpathSync(resolved) !== resolved) {
    throw new Error(`cache path ${resolved} is not a regular directory`);
  }
  const descriptor = openSync(
    resolved,
    constants.O_RDONLY | (constants.O_DIRECTORY ?? 0) | (constants.O_NOFOLLOW ?? 0),
  );
  const descriptorMetadata = fstatSync(descriptor);
  if (
    !descriptorMetadata.isDirectory() ||
    descriptorMetadata.dev !== pathMetadata.dev ||
    descriptorMetadata.ino !== pathMetadata.ino
  ) {
    closeSync(descriptor);
    throw new Error(`cache directory identity changed while it was being pinned: ${resolved}`);
  }
  replayDirectoryPins.set(resolved, {
    path: resolved,
    descriptor,
    dev: descriptorMetadata.dev,
    ino: descriptorMetadata.ino,
  });
  assertCacheDirectory(resolved);
  return resolved;
}

function withPinnedCacheDirectory(directory, operation) {
  const resolved = path.resolve(directory);
  const pin = assertCacheDirectory(resolved);
  const previous = process.cwd();
  process.chdir(resolved);
  try {
    const current = lstatSync(".");
    const descriptorMetadata = fstatSync(pin.descriptor);
    if (
      !current.isDirectory() ||
      current.dev !== pin.dev ||
      current.ino !== pin.ino ||
      descriptorMetadata.dev !== pin.dev ||
      descriptorMetadata.ino !== pin.ino
    ) {
      throw new Error(`cache directory identity changed during publication: ${resolved}`);
    }
    return operation();
  } finally {
    process.chdir(previous);
    assertReplayRoot();
    assertCacheDirectory(resolved);
  }
}

function cacheMkdirSync(directory, options) {
  const resolved = path.resolve(directory);
  const parent = path.dirname(resolved);
  const result = withPinnedCacheDirectory(parent, () => mkdirSync(path.basename(resolved), options));
  pinCacheDirectory(resolved);
  return result;
}

function cacheWriteFileSync(file, ...args) {
  const resolved = path.resolve(file);
  return withPinnedCacheDirectory(path.dirname(resolved), () => writeFileSync(path.basename(resolved), ...args));
}

function cacheRenameSync(source, destination) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  const sourceParent = path.dirname(resolvedSource);
  const destinationParent = path.dirname(resolvedDestination);
  if (sourceParent === destinationParent) {
    return withPinnedCacheDirectory(sourceParent, () => renameSync(
      path.basename(resolvedSource),
      path.basename(resolvedDestination),
    ));
  }
  const sourceMetadata = cacheLstatSync(resolvedSource);
  if (sourceMetadata.isSymbolicLink()) {
    const target = withPinnedCacheDirectory(sourceParent, () => readlinkSync(path.basename(resolvedSource)));
    withPinnedCacheDirectory(destinationParent, () => symlinkSync(
      target,
      path.basename(resolvedDestination),
    ));
  } else {
    withPinnedCacheDirectory(destinationParent, () => linkSync(
      resolvedSource,
      path.basename(resolvedDestination),
    ));
  }
  let destinationMetadata;
  try {
    destinationMetadata = cacheLstatSync(resolvedDestination);
    if (sourceMetadata.isSymbolicLink()) {
      const sourceTarget = withPinnedCacheDirectory(sourceParent, () => readlinkSync(path.basename(resolvedSource)));
      const destinationTarget = withPinnedCacheDirectory(
        destinationParent,
        () => readlinkSync(path.basename(resolvedDestination)),
      );
      if (!destinationMetadata.isSymbolicLink() || destinationTarget !== sourceTarget) {
        throw new Error("cross-directory cache move copied an unexpected symbolic link");
      }
    } else if (
      destinationMetadata.dev !== sourceMetadata.dev ||
      destinationMetadata.ino !== sourceMetadata.ino
    ) {
      throw new Error("cross-directory cache move linked an unexpected source identity");
    }
  } catch (error) {
    try {
      cacheUnlinkSync(resolvedDestination);
    } catch (cleanupError) {
      if (cleanupError.code !== "ENOENT") {
        log(`could not remove failed cross-directory cache link ${resolvedDestination}: ${cleanupError.message}`);
      }
    }
    throw error;
  }
  const currentSourceMetadata = cacheLstatSync(resolvedSource);
  if (
    currentSourceMetadata.dev !== sourceMetadata.dev ||
    currentSourceMetadata.ino !== sourceMetadata.ino
  ) {
    throw new Error("cross-directory cache move source identity changed before removal");
  }
  cacheUnlinkSync(resolvedSource);
}

function cacheUnlinkSync(file) {
  const resolved = path.resolve(file);
  return withPinnedCacheDirectory(path.dirname(resolved), () => unlinkSync(path.basename(resolved)));
}

function cacheLinkSync(source, destination) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  const parent = path.dirname(resolvedSource);
  if (parent !== path.dirname(resolvedDestination)) {
    throw new Error("cache hard-link endpoints must share one pinned directory");
  }
  return withPinnedCacheDirectory(parent, () => linkSync(
    path.basename(resolvedSource),
    path.basename(resolvedDestination),
  ));
}

function cacheRmdirSync(directory) {
  const resolved = path.resolve(directory);
  const result = withPinnedCacheDirectory(
    path.dirname(resolved),
    () => rmdirSync(path.basename(resolved)),
  );
  const pin = replayDirectoryPins.get(resolved);
  if (pin) closeSync(pin.descriptor);
  replayDirectoryPins.delete(resolved);
  return result;
}

function cacheLstatSync(file) {
  const resolved = path.resolve(file);
  return withPinnedCacheDirectory(path.dirname(resolved), () => lstatSync(path.basename(resolved)));
}

function cacheReaddirSync(directory) {
  return withPinnedCacheDirectory(directory, () => readdirSync("."));
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

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function readRegularFile(file) {
  const resolved = path.resolve(file);
  return withPinnedCacheDirectory(path.dirname(resolved), () => {
    const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0);
    const descriptor = openSync(path.basename(resolved), flags);
    try {
      const metadata = fstatSync(descriptor);
      if (!metadata.isFile()) throw new Error(`cache entry ${file} is not a regular file`);
      return { bytes: readFileSync(descriptor), metadata };
    } finally {
      closeSync(descriptor);
    }
  });
}

function removeCacheFile(replayDir, file, description) {
  if (!containedCachePath(replayDir, file)) {
    log(`could not ${description}: path escapes replay cache`);
    return { removed: false, failed: true };
  }
  try {
    cacheUnlinkSync(file);
    return { removed: true, failed: false };
  } catch (error) {
    if (error.code === "ENOENT") return { removed: false, failed: false };
    log(`could not ${description}: ${error.message}`);
    return { removed: false, failed: true };
  }
}

function relayCacheDirectory(replayDir, relay) {
  return path.join(replayDir, relayCacheKey(relay));
}

function prepareCacheRoot(replayDir) {
  const requested = path.resolve(replayDir);
  mkdirSync(requested, { recursive: true, mode: 0o700 });
  const before = lstatSync(requested);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(`replay cache path ${replayDir} is not a regular directory`);
  }
  const resolved = realpathSync(requested);
  const after = lstatSync(requested);
  if (
    after.isSymbolicLink() ||
    !after.isDirectory() ||
    before.dev !== after.dev ||
    before.ino !== after.ino
  ) {
    throw new Error("replay cache root identity changed while it was being opened");
  }
  const descriptor = openSync(
    resolved,
    constants.O_RDONLY | (constants.O_DIRECTORY ?? 0) | (constants.O_NOFOLLOW ?? 0),
  );
  const pinned = fstatSync(descriptor);
  if (!pinned.isDirectory() || pinned.dev !== after.dev || pinned.ino !== after.ino) {
    closeSync(descriptor);
    throw new Error("replay cache root identity changed while it was being pinned");
  }
  replayRootPin = { path: resolved, descriptor, dev: pinned.dev, ino: pinned.ino };
  replayDirectoryPins.set(resolved, replayRootPin);
  assertReplayRoot();
  return resolved;
}

function prepareCacheDirectory(replayDir, name) {
  const directory = path.join(replayDir, name);
  if (!containedCachePath(replayDir, directory)) throw new Error("cache directory escapes replay cache");
  try {
    const metadata = cacheLstatSync(directory);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new Error(`cache path ${directory} is not a regular directory`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    cacheMkdirSync(directory, { mode: 0o700 });
  }
  return pinCacheDirectory(directory);
}

function prepareRelayCacheDirectory(replayDir, relay) {
  const directory = relayCacheDirectory(replayDir, relay);
  if (!containedCachePath(replayDir, directory)) throw new Error("relay cache path escapes replay cache");
  try {
    const metadata = cacheLstatSync(directory);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new Error(`relay cache path ${directory} is not a regular directory`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    cacheMkdirSync(directory, { mode: 0o700 });
  }
  const metadata = cacheLstatSync(directory);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`relay cache path ${directory} is not a regular directory`);
  }
  return pinCacheDirectory(directory);
}

const QUARANTINE_TOKEN = /^[0-9a-f]{64}$/;

function requireQuarantineToken(value) {
  if (typeof value !== "string" || !QUARANTINE_TOKEN.test(value)) {
    throw new Error("invalid quarantine transaction token");
  }
  return value;
}

function quarantineManifestPath(manifestsDir, token) {
  const canonical = requireQuarantineToken(token);
  const final = path.resolve(path.join(manifestsDir, `${canonical}.json`));
  if (!containedCachePath(manifestsDir, final) || path.dirname(final) !== path.resolve(manifestsDir)) {
    throw new Error("quarantine manifest path escapes manifest directory");
  }
  return final;
}

function stagedLegacyOrigin(origin, quarantineDir, payloadsDir, transactionDir) {
  const directoryToken = requireQuarantineToken(path.basename(transactionDir));
  const originToken = requireQuarantineToken(origin?.transaction_token);
  if (originToken !== directoryToken) throw new Error("quarantine transaction token does not match its directory");
  const payload = path.resolve(path.join(payloadsDir, `${originToken}.json`));
  const referenced = path.resolve(path.join(quarantineDir, origin?.payload_reference ?? ""));
  if (referenced !== payload || !containedCachePath(payloadsDir, payload)) {
    throw new Error("quarantine payload reference does not match its transaction token");
  }
  if (
    !Number.isSafeInteger(origin?.source_device) ||
    !Number.isSafeInteger(origin?.source_inode) ||
    origin.source_device < 0 ||
    origin.source_inode < 0
  ) {
    throw new Error("quarantine source identity is malformed");
  }
  assertCacheDirectory(transactionDir);
  return { token: originToken, payload };
}

function corruptPartitionRecord(record, quarantineDir, transactionDir) {
  const directoryToken = requireQuarantineToken(path.basename(transactionDir));
  const recordToken = requireQuarantineToken(record?.token);
  if (recordToken !== directoryToken) throw new Error("quarantine transaction token does not match its directory");
  if (record.manifest === null || typeof record.manifest !== "object" || Array.isArray(record.manifest)) {
    throw new Error("corrupt quarantine manifest is malformed");
  }
  const expectedReference = path.join("corrupt", recordToken, "entry");
  const referenced = path.resolve(path.join(quarantineDir, record.manifest.payload_reference ?? ""));
  const expected = path.resolve(path.join(quarantineDir, expectedReference));
  if (record.manifest.payload_reference !== expectedReference || referenced !== expected) {
    throw new Error("corrupt quarantine payload reference does not match its transaction token");
  }
  assertCacheDirectory(transactionDir);
  return { token: recordToken, manifest: record.manifest };
}

function quarantineManifestIdentity(manifest) {
  return JSON.stringify({
    original_path: manifest.original_path,
    legacy_host: manifest.legacy_host,
    payload_reference: manifest.payload_reference,
    source_device: manifest.source_device ?? null,
    source_inode: manifest.source_inode ?? null,
    corrupt_type: manifest.corrupt_type ?? null,
    quarantine_reason: manifest.quarantine_reason ?? "legacy-cache-migration",
    publisher_pubkey: manifest.publisher_pubkey ?? null,
  });
}

function metadataTimestamps(metadata) {
  return {
    atime_ms: metadata.atimeMs,
    mtime_ms: metadata.mtimeMs,
    ctime_ms: metadata.ctimeMs,
    birthtime_ms: metadata.birthtimeMs,
  };
}

function writeJsonAtomically(file, value) {
  const temporary = `${file}.tmp`;
  cacheWriteFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  try {
    cacheRenameSync(temporary, file);
  } catch (error) {
    try {
      cacheUnlinkSync(temporary);
    } catch (cleanupError) {
      if (cleanupError.code !== "ENOENT") log(`could not remove quarantine temporary ${temporary}: ${cleanupError.message}`);
    }
    throw error;
  }
}

function readQuarantineManifest(file) {
  const { bytes } = readRegularFile(file);
  return JSON.parse(bytes.toString("utf8"));
}

function finalizeQuarantineManifest(stage, final, expected) {
  try {
    cacheLinkSync(stage, final);
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    const existing = readQuarantineManifest(final);
    if (quarantineManifestIdentity(existing) !== quarantineManifestIdentity(expected)) {
      throw new Error(`quarantine manifest collision at ${final}`);
    }
  }
  try {
    cacheUnlinkSync(stage);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function finalizeQuarantineRecord(final, expected) {
  try {
    const existing = readQuarantineManifest(final);
    if (quarantineManifestIdentity(existing) !== quarantineManifestIdentity(expected)) {
      throw new Error(`quarantine manifest collision at ${final}`);
    }
    return existing;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  writeJsonAtomically(final, expected);
  return expected;
}

function quarantineInvalidRecoveryResidue(
  quarantineDir,
  manifestsDir,
  recoveryCorruptDir,
  source,
  reason,
) {
  const metadata = cacheLstatSync(source);
  const originalPath = path.relative(quarantineDir, source);
  const token = requireQuarantineToken(sha256(JSON.stringify({
    original_path: originalPath,
    device: metadata.dev,
    inode: metadata.ino,
    ctime_ms: metadata.ctimeMs,
    birthtime_ms: metadata.birthtimeMs,
  })));
  const destination = path.join(recoveryCorruptDir, `${token}.invalid`);
  try {
    const existing = cacheLstatSync(destination);
    if (existing.dev !== metadata.dev || existing.ino !== metadata.ino) {
      throw new Error(`recovery-residue quarantine collision at ${destination}`);
    }
    cacheUnlinkSync(source);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    cacheRenameSync(source, destination);
  }
  const manifest = {
    original_path: originalPath,
    legacy_host: null,
    original_timestamps: metadataTimestamps(metadata),
    quarantine_timestamp: new Date().toISOString(),
    payload_reference: path.relative(quarantineDir, destination),
    source_device: metadata.dev,
    source_inode: metadata.ino,
    corrupt_type: "invalid-quarantine-recovery-residue",
    recovery_error: String(reason),
  };
  finalizeQuarantineRecord(quarantineManifestPath(manifestsDir, token), manifest);
  log(`quarantined invalid recovery residue ${source} at ${destination}`);
}

function recoverInvalidRecoveryResidues(quarantineDir, manifestsDir, recoveryCorruptDir, failures) {
  for (const name of cacheReaddirSync(recoveryCorruptDir)) {
    const match = /^([0-9a-f]{64})\.invalid$/.exec(name);
    const residue = path.join(recoveryCorruptDir, name);
    if (!match) {
      log(`could not account for invalid recovery residue ${residue}: invalid residue name`);
      failures.push(residue);
      continue;
    }
    const final = quarantineManifestPath(manifestsDir, match[1]);
    const expectedReference = path.relative(quarantineDir, residue);
    try {
      let existing;
      try {
        existing = readQuarantineManifest(final);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      if (existing !== undefined) {
        if (
          existing.corrupt_type !== "invalid-quarantine-recovery-residue" ||
          existing.payload_reference !== expectedReference
        ) {
          throw new Error("recovery-residue manifest does not match its payload");
        }
        continue;
      }
      const metadata = cacheLstatSync(residue);
      finalizeQuarantineRecord(final, {
        original_path: expectedReference,
        legacy_host: null,
        original_timestamps: metadataTimestamps(metadata),
        quarantine_timestamp: new Date().toISOString(),
        payload_reference: expectedReference,
        source_device: metadata.dev,
        source_inode: metadata.ino,
        corrupt_type: "invalid-quarantine-recovery-residue",
        recovery_error: "recovered incomplete residue transaction",
      });
      log(`recovered invalid recovery residue ${residue}`);
    } catch (error) {
      log(`could not account for invalid recovery residue ${residue}: ${error.message}`);
      failures.push(residue);
    }
  }
}

function recoverAtomicJson(file, recovery) {
  const directory = path.dirname(file);
  const basename = path.basename(file);
  const temporaryPattern = new RegExp(`^${basename.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:\\.\\d+)?\\.tmp$`);
  const temporaries = cacheReaddirSync(directory)
    .filter((name) => temporaryPattern.test(name))
    .sort();
  let existing;
  try {
    existing = readQuarantineManifest(file);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  for (const name of temporaries) {
    const temporary = path.join(directory, name);
    let candidate;
    try {
      candidate = readQuarantineManifest(temporary);
    } catch (error) {
      try {
        quarantineInvalidRecoveryResidue(
          recovery.quarantineDir,
          recovery.manifestsDir,
          recovery.recoveryCorruptDir,
          temporary,
          error.message,
        );
      } catch (quarantineError) {
        log(`could not quarantine invalid recovery residue ${temporary}: ${quarantineError.message}`);
        recovery.failures.push(temporary);
      }
      continue;
    }
    if (existing === undefined) {
      cacheRenameSync(temporary, file);
      existing = candidate;
      continue;
    }
    if (JSON.stringify(existing) !== JSON.stringify(candidate)) {
      try {
        quarantineInvalidRecoveryResidue(
          recovery.quarantineDir,
          recovery.manifestsDir,
          recovery.recoveryCorruptDir,
          temporary,
          "quarantine temporary collision",
        );
      } catch (error) {
        log(`could not quarantine conflicting recovery residue ${temporary}: ${error.message}`);
        recovery.failures.push(temporary);
      }
      continue;
    }
    cacheUnlinkSync(temporary);
  }
  return existing;
}

function recoverQuarantineTransactions(
  quarantineDir,
  manifestsDir,
  payloadsDir,
  recoveryCorruptDir,
  failures,
) {
  const temporaryPattern = /^([0-9a-f]{64})\.json(?:\.\d+)?\.tmp$/;
  for (const name of cacheReaddirSync(manifestsDir).filter((candidate) => candidate.endsWith(".tmp"))) {
    const stage = path.join(manifestsDir, name);
    try {
      const match = temporaryPattern.exec(name);
      if (!match) throw new Error("invalid quarantine temporary name");
      const manifest = readQuarantineManifest(stage);
      const payload = path.resolve(path.join(path.dirname(manifestsDir), manifest.payload_reference));
      if (!containedCachePath(payloadsDir, payload)) {
        throw new Error("quarantine transaction path escapes replay cache");
      }
      const { bytes } = readRegularFile(payload);
      if (typeof manifest.content_sha256 === "string" && sha256(bytes) !== manifest.content_sha256) {
        throw new Error("quarantine payload digest mismatch");
      }
      const final = quarantineManifestPath(manifestsDir, match[1]);
      finalizeQuarantineManifest(stage, final, manifest);
    } catch (error) {
      try {
        quarantineInvalidRecoveryResidue(
          quarantineDir,
          manifestsDir,
          recoveryCorruptDir,
          stage,
          error.message,
        );
      } catch (quarantineError) {
        log(`could not recover legacy cache quarantine transaction ${stage}: ${quarantineError.message}`);
        failures.push(stage);
      }
    }
  }
}

function completeStagedLegacyEntry(quarantineDir, manifestsDir, payloadsDir, transactionDir) {
  const originFile = path.join(transactionDir, "origin.json");
  const stagedFile = path.join(transactionDir, "source");
  const origin = readQuarantineManifest(originFile);
  const { token, payload } = stagedLegacyOrigin(origin, quarantineDir, payloadsDir, transactionDir);
  try {
    const stagedMetadata = cacheLstatSync(stagedFile);
    let payloadMetadata;
    try {
      payloadMetadata = cacheLstatSync(payload);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (payloadMetadata !== undefined) {
      if (payloadMetadata.dev !== stagedMetadata.dev || payloadMetadata.ino !== stagedMetadata.ino) {
        throw new Error(`quarantine payload collision at ${payload}`);
      }
      cacheUnlinkSync(stagedFile);
    } else {
      cacheRenameSync(stagedFile, payload);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const payloadMetadata = cacheLstatSync(payload);
  if (
    !payloadMetadata.isFile() ||
    payloadMetadata.dev !== origin.source_device ||
    payloadMetadata.ino !== origin.source_inode
  ) {
    throw new Error(`quarantine payload identity mismatch at ${payload}`);
  }
  const { bytes } = readRegularFile(payload);
  const final = quarantineManifestPath(manifestsDir, token);
  const manifest = {
    original_path: origin.original_path,
    legacy_host: origin.legacy_host,
    original_timestamps: origin.original_timestamps,
    quarantine_timestamp: new Date().toISOString(),
    payload_reference: origin.payload_reference,
    source_device: origin.source_device,
    source_inode: origin.source_inode,
    content_sha256_observed: sha256(bytes),
    content_size_observed: bytes.length,
    quarantine_reason: origin.quarantine_reason ?? "legacy-cache-migration",
    publisher_pubkey: origin.publisher_pubkey ?? null,
  };
  finalizeQuarantineRecord(final, manifest);
  cacheUnlinkSync(originFile);
  cacheRmdirSync(transactionDir);
}

function recoverStagedLegacyEntries(
  quarantineDir,
  manifestsDir,
  payloadsDir,
  stagingDir,
  recoveryCorruptDir,
  failures,
) {
  const recovery = { quarantineDir, manifestsDir, recoveryCorruptDir, failures };
  for (const name of cacheReaddirSync(stagingDir)) {
    const transactionDir = path.join(stagingDir, name);
    try {
      const metadata = cacheLstatSync(transactionDir);
      if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
        throw new Error("staging transaction is not a regular directory");
      }
      pinCacheDirectory(transactionDir);
      const originFile = path.join(transactionDir, "origin.json");
      const origin = recoverAtomicJson(originFile, recovery);
      const stagedFile = path.join(transactionDir, "source");
      if (origin !== undefined) {
        const { payload } = stagedLegacyOrigin(origin, quarantineDir, payloadsDir, transactionDir);
        let claimed = false;
        try {
          cacheLstatSync(stagedFile);
          claimed = true;
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
        }
        try {
          cacheLstatSync(payload);
          claimed = true;
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
        }
        if (claimed) {
          completeStagedLegacyEntry(quarantineDir, manifestsDir, payloadsDir, transactionDir);
          continue;
        }
      }
      try {
        cacheUnlinkSync(originFile);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      for (const temporary of cacheReaddirSync(transactionDir).filter((name) => name.startsWith("origin.json") && name.endsWith(".tmp"))) {
        cacheUnlinkSync(path.join(transactionDir, temporary));
      }
      cacheRmdirSync(transactionDir);
    } catch (error) {
      log(`could not recover staged legacy cache entry ${transactionDir}: ${error.message}`);
      failures.push(transactionDir);
    }
  }
}

function quarantineLegacyEntry(
  replayDir,
  quarantineDir,
  manifestsDir,
  payloadsDir,
  stagingDir,
  file,
  legacyHost,
  options = {},
) {
  const originalPath = path.relative(replayDir, file);
  if (!containedCachePath(replayDir, file)) throw new Error("legacy cache entry escapes replay cache");
  const metadata = cacheLstatSync(file);
  if (!metadata.isFile()) throw new Error("legacy cache entry is not a regular file");
  const transactionToken = requireQuarantineToken(sha256(JSON.stringify({
    original_path: originalPath,
    device: metadata.dev,
    inode: metadata.ino,
    birthtime_ms: metadata.birthtimeMs,
  })));
  const transactionDir = prepareCacheDirectory(stagingDir, transactionToken);
  const originFile = path.join(transactionDir, "origin.json");
  const stagedFile = path.join(transactionDir, "source");
  const payloadReference = path.join("payloads", `${transactionToken}.json`);
  writeJsonAtomically(originFile, {
    original_path: originalPath,
    legacy_host: legacyHost,
    original_timestamps: metadataTimestamps(metadata),
    transaction_token: transactionToken,
    payload_reference: payloadReference,
    source_device: metadata.dev,
    source_inode: metadata.ino,
    quarantine_reason: options.reason ?? "legacy-cache-migration",
    publisher_pubkey: options.publisherPubkey ?? null,
  });
  cacheRenameSync(file, stagedFile);
  completeStagedLegacyEntry(quarantineDir, manifestsDir, payloadsDir, transactionDir);
}

function decodeLegacyHost(name) {
  try {
    const decoded = decodeURIComponent(name);
    if (encodeURIComponent(decoded) !== name) throw new Error("non-canonical encoding");
    const relay = `ws://${decoded}`;
    const host = resolveLoopbackRelayHost(relay);
    const parsed = new URL(relay);
    if (parsed.pathname !== "/" || parsed.search !== "" || parsed.hash !== "") {
      throw new Error("not a host-only relay identity");
    }
    return host;
  } catch (error) {
    log(`legacy cache directory ${name} has no valid encoded loopback host identity: ${error.message}`);
    return null;
  }
}

function corruptNodeType(metadata) {
  if (metadata.isSymbolicLink()) return "symbolic-link";
  if (metadata.isFIFO()) return "fifo";
  if (metadata.isSocket()) return "socket";
  if (metadata.isCharacterDevice()) return "character-device";
  if (metadata.isBlockDevice()) return "block-device";
  if (metadata.isFile()) return "regular-file";
  return "non-directory";
}

function finalizeCorruptPartitionRecord(quarantineDir, manifestsDir, transactionDir) {
  const originFile = path.join(transactionDir, "origin.json");
  const record = readQuarantineManifest(originFile);
  const validated = corruptPartitionRecord(record, quarantineDir, transactionDir);
  const final = quarantineManifestPath(manifestsDir, validated.token);
  finalizeQuarantineRecord(final, validated.manifest);
  try {
    cacheUnlinkSync(originFile);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function recoverCorruptPartitionNodes(quarantineDir, corruptDir, manifestsDir, failures) {
  for (const name of cacheReaddirSync(corruptDir)) {
    const transactionDir = path.join(corruptDir, name);
    try {
      const metadata = cacheLstatSync(transactionDir);
      if (metadata.isSymbolicLink() || !metadata.isDirectory()) continue;
      pinCacheDirectory(transactionDir);
      const originFile = path.join(transactionDir, "origin.json");
      const entry = path.join(transactionDir, "entry");
      cacheLstatSync(originFile);
      cacheLstatSync(entry);
      finalizeCorruptPartitionRecord(quarantineDir, manifestsDir, transactionDir);
    } catch (error) {
      if (error.code !== "ENOENT") {
        log(`could not recover corrupt cache partition ${transactionDir}: ${error.message}`);
        failures.push(transactionDir);
      }
    }
  }
}

function quarantineCorruptPartitionNode(replayDir, quarantineDir, corruptDir, manifestsDir, file, metadata) {
  const originalPath = path.relative(replayDir, file);
  const type = corruptNodeType(metadata);
  const token = requireQuarantineToken(sha256(JSON.stringify({
    original_path: originalPath,
    device: metadata.dev,
    inode: metadata.ino,
    mode: metadata.mode,
  })));
  const transactionDir = prepareCacheDirectory(corruptDir, token);
  const entry = path.join(transactionDir, "entry");
  const originFile = path.join(transactionDir, "origin.json");
  const payloadReference = path.join("corrupt", token, "entry");
  const manifest = {
    original_path: originalPath,
    legacy_host: null,
    original_timestamps: metadataTimestamps(metadata),
    content_sha256: null,
    quarantine_timestamp: new Date().toISOString(),
    payload_reference: payloadReference,
    corrupt_type: type,
  };
  try {
    const existing = cacheLstatSync(entry);
    if (existing.dev !== metadata.dev || existing.ino !== metadata.ino) {
      throw new Error(`corrupt partition quarantine collision at ${entry}`);
    }
    cacheUnlinkSync(file);
    finalizeCorruptPartitionRecord(quarantineDir, manifestsDir, transactionDir);
    return;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  writeJsonAtomically(originFile, { token, manifest });
  cacheRenameSync(file, entry);
  finalizeCorruptPartitionRecord(quarantineDir, manifestsDir, transactionDir);
  log(`quarantined corrupt cache partition path ${file} (${type}) at ${path.join(quarantineDir, payloadReference)}`);
}

function quarantineManifestCount(manifestsDir, failures = []) {
  let count = 0;
  for (const name of cacheReaddirSync(manifestsDir)) {
    if (!name.endsWith(".json")) continue;
    try {
      if (cacheLstatSync(path.join(manifestsDir, name)).isFile()) count += 1;
    } catch (error) {
      if (error.code !== "ENOENT") {
        const file = path.join(manifestsDir, name);
        log(`could not inspect legacy quarantine manifest ${name}: ${error.message}`);
        failures.push(file);
      }
    }
  }
  return count;
}

function quarantineLegacyEntries(replayDir) {
  const failures = [];
  const quarantineDir = prepareCacheDirectory(replayDir, LEGACY_QUARANTINE);
  const manifestsDir = prepareCacheDirectory(quarantineDir, "manifests");
  const payloadsDir = prepareCacheDirectory(quarantineDir, "payloads");
  const stagingDir = prepareCacheDirectory(quarantineDir, "staging");
  const corruptDir = prepareCacheDirectory(quarantineDir, "corrupt");
  const recoveryCorruptDir = prepareCacheDirectory(quarantineDir, "recovery-corrupt");
  recoverInvalidRecoveryResidues(quarantineDir, manifestsDir, recoveryCorruptDir, failures);
  recoverQuarantineTransactions(
    quarantineDir,
    manifestsDir,
    payloadsDir,
    recoveryCorruptDir,
    failures,
  );
  recoverStagedLegacyEntries(
    quarantineDir,
    manifestsDir,
    payloadsDir,
    stagingDir,
    recoveryCorruptDir,
    failures,
  );
  recoverCorruptPartitionNodes(quarantineDir, corruptDir, manifestsDir, failures);

  let names;
  try {
    names = cacheReaddirSync(replayDir);
  } catch (error) {
    log(`could not inspect replay cache for legacy entries: ${error.message}`);
    failures.push(replayDir);
    const count = quarantineManifestCount(manifestsDir, failures);
    return { failures, count };
  }

  const candidates = [];
  for (const name of names) {
    if (name === LEGACY_QUARANTINE) continue;
    const candidate = path.join(replayDir, name);
    let metadata;
    try {
      metadata = cacheLstatSync(candidate);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      log(`could not inspect cache path ${candidate}: ${error.message}`);
      failures.push(candidate);
      continue;
    }
    if (name.endsWith(".json")) {
      if (metadata.isFile()) candidates.push({ file: candidate, legacyHost: null });
      else {
        log(`legacy cache entry ${candidate} is not a regular file; left in place`);
        failures.push(candidate);
      }
      continue;
    }
    if (CACHE_PARTITION.test(name)) {
      if (metadata.isDirectory() && !metadata.isSymbolicLink()) continue;
      try {
        quarantineCorruptPartitionNode(
          replayDir,
          quarantineDir,
          corruptDir,
          manifestsDir,
          candidate,
          metadata,
        );
      } catch (error) {
        log(`could not quarantine corrupt cache partition path ${candidate}: ${error.message}`);
        failures.push(candidate);
      }
      continue;
    }
    if (metadata.isSymbolicLink()) {
      log(`rejected cache directory symlink ${candidate}`);
      failures.push(candidate);
      continue;
    }
    if (!metadata.isDirectory()) continue;
    pinCacheDirectory(candidate);
    let legacyNames;
    try {
      legacyNames = cacheReaddirSync(candidate);
    } catch (error) {
      log(`could not inspect legacy cache directory ${candidate}: ${error.message}`);
      failures.push(candidate);
      continue;
    }
    const legacyHost = decodeLegacyHost(name);
    for (const legacyName of legacyNames.filter((entry) => entry.endsWith(".json"))) {
      const legacyFile = path.join(candidate, legacyName);
      try {
        if (cacheLstatSync(legacyFile).isFile()) candidates.push({ file: legacyFile, legacyHost });
        else {
          log(`legacy cache entry ${legacyFile} is not a regular file; left in place`);
          failures.push(legacyFile);
        }
      } catch (error) {
        if (error.code === "ENOENT") continue;
        log(`could not inspect legacy cache entry ${legacyFile}: ${error.message}`);
        failures.push(legacyFile);
      }
    }
  }

  for (const candidate of candidates) {
    try {
      quarantineLegacyEntry(
        replayDir,
        quarantineDir,
        manifestsDir,
        payloadsDir,
        stagingDir,
        candidate.file,
        candidate.legacyHost,
      );
    } catch (error) {
      log(`could not quarantine legacy cache entry ${candidate.file}: ${error.message}`);
      failures.push(candidate.file);
    }
  }
  const count = quarantineManifestCount(manifestsDir, failures);
  if (count > 0) log(`legacy replay quarantine: ${count} entry(s) at ${quarantineDir}`);
  return { failures, count };
}

function activeReplayPublisherEntries(cacheRoot) {
  const topology = cacheDirectories(cacheRoot);
  if (topology.failures.length > 0) {
    throw new Error(`could not inspect active replay partitions:\n${topology.failures.map((file) => `  ${file}`).join("\n")}`);
  }
  const active = [];
  for (const directory of topology.directories) {
    const inventory = cacheEntries(directory);
    if (inventory.failures.length > 0) {
      throw new Error(`could not inspect active replay entries:\n${inventory.failures.map((file) => `  ${file}`).join("\n")}`);
    }
    for (const entry of inventory.entries) {
      if (entry.malformed) throw new Error(`active replay entry ${entry.file} is invalid: ${entry.reason}`);
      let raw;
      try {
        raw = readRegularFile(entry.file).bytes.toString("utf8");
      } catch (error) {
        throw new Error(`could not read active replay entry ${entry.file}: ${error.message}`);
      }
      let event;
      try {
        event = cachedEventFromFrame(raw, entry);
      } catch (error) {
        throw new Error(`active replay entry ${entry.file} is invalid: ${error.message}`);
      }
      active.push({ path: entry.file, publisherPubkey: event.pubkey });
    }
  }
  return active.sort((left, right) => left.path.localeCompare(right.path));
}

export function inspectActiveReplayPublisherCache(replayDir) {
  let metadata;
  try {
    metadata = lstatSync(replayDir);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`replay cache path ${replayDir} is not a regular directory`);
  }
  return activeReplayPublisherEntries(prepareCacheRoot(replayDir));
}

export function protectOutgoingPublisherCache(replayDir, publisherPubkeys, options = {}) {
  const publishers = Array.isArray(publisherPubkeys) ? publisherPubkeys : [publisherPubkeys];
  if (publishers.length === 0 || publishers.some((value) => !/^[0-9a-f]{64}$/.test(value))) {
    throw new Error("outgoing publishers must be 64 lowercase hexadecimal characters");
  }
  const publisherSet = new Set(publishers);
  if (typeof options.discard !== "boolean") {
    throw new Error("pending-cache discard mode must be boolean");
  }
  const cacheRoot = prepareCacheRoot(replayDir);
  const legacyMigration = quarantineLegacyEntries(cacheRoot);
  if (legacyMigration.failures.length > 0) {
    throw new Error(
      `could not settle replay quarantine:\n${legacyMigration.failures.map((file) => `  ${file}`).join("\n")}`,
    );
  }
  const blocking = activeReplayPublisherEntries(cacheRoot)
    .filter((entry) => publisherSet.has(entry.publisherPubkey));
  const paths = blocking.map((entry) => entry.path);
  if (!options.discard || blocking.length === 0) {
    return { count: blocking.length, paths, quarantined: [] };
  }
  const quarantineDir = prepareCacheDirectory(cacheRoot, LEGACY_QUARANTINE);
  const manifestsDir = prepareCacheDirectory(quarantineDir, "manifests");
  const payloadsDir = prepareCacheDirectory(quarantineDir, "payloads");
  const stagingDir = prepareCacheDirectory(quarantineDir, "staging");
  const quarantined = [];
  for (const entry of blocking) {
    quarantineLegacyEntry(
      cacheRoot,
      quarantineDir,
      manifestsDir,
      payloadsDir,
      stagingDir,
      entry.path,
      null,
      { reason: "pending-key-rotation", publisherPubkey: entry.publisherPubkey },
    );
    quarantined.push(entry.path);
  }
  const failures = [];
  quarantineManifestCount(manifestsDir, failures);
  if (failures.length > 0) {
    throw new Error(`could not verify replay quarantine manifests:\n${failures.map((file) => `  ${file}`).join("\n")}`);
  }
  return { count: blocking.length, paths, quarantined };
}

function cacheEntries(replayDir) {
  let names;
  try {
    names = cacheReaddirSync(replayDir);
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
      metadata = cacheLstatSync(file);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      log(`could not inspect cache entry ${file}: ${error.message}`);
      failures.push(file);
      continue;
    }
    const match = /^(\d+)-([0-9a-f]{64})\.json$/.exec(name);
    const createdAt = match ? Number(match[1]) : undefined;
    if (!metadata.isFile() || !match || !Number.isSafeInteger(createdAt)) {
      entries.push({
        name,
        file,
        malformed: true,
        reason: metadata.isSymbolicLink()
          ? "cache entry is a symbolic link"
          : !metadata.isFile()
            ? "cache entry is not a regular file"
            : "malformed cache filename",
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

// The cap remains global across normalized relay endpoints. A separate 100-entry
// allowance per endpoint would let repeated local relay switches grow the private
// queue without bound. Legacy entries are quarantined outside this active set.
function cacheDirectories(replayDir) {
  let names;
  try {
    names = cacheReaddirSync(replayDir);
  } catch (error) {
    if (error.code === "ENOENT") return { directories: [], failures: [] };
    log(`could not inspect cache directory ${replayDir}: ${error.message}`);
    return { directories: [], failures: [replayDir] };
  }
  const directories = [];
  const failures = [];
  for (const name of names) {
    if (!CACHE_PARTITION.test(name)) continue;
    const directory = path.join(replayDir, name);
    try {
      const metadata = cacheLstatSync(directory);
      if (metadata.isSymbolicLink()) {
        log(`rejected cache directory symlink ${directory}`);
        failures.push(directory);
      } else if (metadata.isDirectory()) {
        directories.push(pinCacheDirectory(directory));
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
    names = cacheReaddirSync(replayDir);
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
      modified = cacheLstatSync(file).mtimeMs;
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
  const metadata = cacheLstatSync(replayDir);
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
  cacheWriteFileSync(tmp, frame, { mode: 0o600, flag: "wx" });
  try {
    cacheRenameSync(tmp, target);
  } catch (error) {
    try {
      cacheUnlinkSync(tmp);
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
    targetsFile,
    maxCache = 100,
  } = envelope;

  for (const [name, value] of Object.entries({ privateKey, content, relay, channelId, replayDir, targetsFile })) {
    if (typeof value !== "string" || value === "") throw new Error(`missing envelope field: ${name}`);
  }
  if (!Number.isSafeInteger(maxCache) || maxCache <= 0) {
    throw new Error(`invalid FM_BUZZ_MAX_CACHE value ${JSON.stringify(maxCache)}: expected a positive integer`);
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2147483647) {
    throw new Error(`invalid relay timeout ${JSON.stringify(timeoutMs)}: expected an integer from 1 to 2147483647`);
  }
  resolveLoopbackRelayHost(relay);
  const event = buildBearingsEvent(channelId, content, privateKey, [
    ["fm-schema", "fm-bearings.v1"],
  ]);
  const cacheRoot = prepareCacheRoot(replayDir);
  const legacyMigration = quarantineLegacyEntries(cacheRoot);
  const relayCacheDir = prepareRelayCacheDirectory(cacheRoot, relay);

  // Cache the signed event before network access: from here on it survives a
  // crash, a kill, or a relay that is not running at all.
  const currentFile = cacheEvent(relayCacheDir, event);
  const cacheMaintenance = pruneCache(cacheRoot, maxCache, currentFile);
  recordPublisherTarget(targetsFile, {
    relay,
    channel_id: channelId,
    publisher_pubkey: event.pubkey,
  });
  let cleanupFailures = cacheMaintenance.failed + legacyMigration.failures.length;
  log(`signed event ${event.id} (${Buffer.byteLength(content, "utf8")} bytes) for channel ${channelId}`);

  const pending = cacheMaintenance.entries.filter((entry) => path.dirname(entry.file) === relayCacheDir);
  // Final verdict per cache entry rather than running counters, because an entry
  // can be attempted twice: a pass that ran before a late NIP-42 handshake
  // completed is superseded by the one that ran after it, and incrementing
  // counters would report the same event as both retained and delivered.
  const outcome = new Map(cacheMaintenance.outcomes);
  for (const file of legacyMigration.failures) outcome.set(`legacy:${file}`, RETRYABLE);
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
          raw = readRegularFile(entry.file).bytes.toString("utf8");
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

if (
  !process.execArgv.some((argument) => argument === "-e" || argument === "--eval") &&
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main().then(
    (code) => process.exit(code),
    (error) => {
      log(`failed: ${error.message}`);
      process.exit(1);
    },
  );
}
