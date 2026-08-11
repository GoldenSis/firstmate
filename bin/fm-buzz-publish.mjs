#!/usr/bin/env node
// Publishing engine behind bin/fm-buzz-publish.sh: sign one bearings event, put
// it in the replay cache, then drain the cache to the loopback relay.
//
// This file may exit non-zero - that is deliberate. The fire-and-forget contract
// belongs to the shell wrapper, which is the only supported entry point and which
// converts runtime failures here into a logged exit 0. Keeping the engine honest
// about failure is what makes it testable; isolating runtime publication failures
// is what keeps Buzz off Firstmate's critical path.
//
// REPLAY CACHE LIFECYCLE
// bin/fm-buzz-lib.mjs owns signed-event identity and byte-preserving replay
// semantics. This engine owns active-cache and quarantine layout, mutation
// order, validation, recovery, pruning, and relay outcomes because every
// mutation must share the pinned cache-directory interface below.
// Active entries live at
// <replay-root>/<endpoint-digest>/<channel-id>/<created_at>-<event-id>.json,
// where endpoint-digest is SHA-256 of the complete normalized relay endpoint and
// channel-id is the exact canonical h tag. A complete EVENT frame is cached
// atomically before target tracking or network access, pruning is oldest-first
// within only the invoked channel partition while protecting the current event,
// and only a classified relay outcome removes a replay entry. The only children
// an endpoint partition may hold are canonical channel directories, entries
// awaiting migration, and the `.json.tmp` half of an interrupted write; every
// other child is quarantined as a corrupt partition node rather than skipped.
// Before submission, the drain derives the current publisher from the private
// key in its input envelope and retains any cached event signed by a different
// publisher. It never submits an old or foreign event while authenticating as
// the current publisher.
//
// The whole-tree half of a run - quarantine and endpoint-to-channel migration -
// is migrateReplayCache, a separate entry point so its caller can hold the
// whole-tree lock across a filesystem walk instead of across a relay round trip.
// main() therefore never walks outside the queue it was invoked for, and its
// prepare phase signs, caches, prunes, and tracks before its deliver phase makes
// network calls. bin/fm-buzz-key-lib.sh owns the lock ordering those phases use.
//
// Reads one JSON envelope on stdin so that neither the private key nor the
// projection - which carries task ids, project names, blockers and PR URLs -
// appears in a command line or in the process environment. Fields: privateKey,
// phase, content, relay, channelId, channelName, timeoutMs, replayDir,
// targetsFile, migration, preparation, maxCache.
//
// Legacy and explicitly discarded rotation entries are retained under
// _legacy-quarantine with payloads and manifests rather than silently deleted.
// Each claimed regular file moves through staging/<token>/{source,origin.json}
// into payloads/<token>.json, while corrupt cache nodes remain under
// corrupt/<token>/entry and invalid recovery residue remains under
// recovery-corrupt/<token>.invalid.
// Every manifests/<token>.json variant requires original_path,
// payload_reference, original_timestamps, and quarantine_timestamp.
// Regular-entry manifests additionally require legacy_host, source_device,
// source_inode, observed content hash and size, quarantine_reason, and the
// validated publisher_pubkey when the payload contains a signed event.
// Corrupt-node manifests additionally require corrupt_type and may carry a
// content hash when their retained node is readable.
// Recovery-residue manifests additionally require source_device, source_inode,
// corrupt_type, and recovery_error, while legacy_host, quarantine_reason, and
// publisher_pubkey are not part of that variant.
// A lowercase SHA-256 token binds stable source provenance: original path,
// device, and inode for regular files, or mode for corrupt partition nodes,
// without using access or link-mutated change time.
// Startup completes manifest temporaries before accounting for invalid recovery
// residue, then completes staged regular files and corrupt nodes before discovering
// new legacy entries, and it reports every unsettled mutation as a cleanup failure.

import {
  closeSync,
  constants,
  fstatSync,
  openSync,
  lstatSync,
  realpathSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
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
import { publicKeyFromPrivate } from "./fm-buzz-crypto.mjs";

const CACHE_PARTITION = /^[0-9a-f]{64}$/;
const CHANNEL_PARTITION = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
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
  try {
    const descriptorMetadata = fstatSync(pin.descriptor);
    if (
      descriptorMetadata.dev !== pin.dev ||
      descriptorMetadata.ino !== pin.ino
    ) {
      throw new Error(`cache directory identity changed during publication: ${resolved}`);
    }
    return operation(pin);
  } finally {
    assertReplayRoot();
    assertCacheDirectory(resolved);
  }
}

const DIRECTORY_RELATIVE_OPERATION = String.raw`
import errno
import json
import os
import stat
import sys

directory = 3
request = json.loads(sys.argv[1])

def metadata(value):
    return {
        "dev": value.st_dev,
        "ino": value.st_ino,
        "mode": value.st_mode,
        "nlink": value.st_nlink,
        "size": value.st_size,
        "atimeMs": value.st_atime * 1000,
        "mtimeMs": value.st_mtime * 1000,
        "ctimeMs": value.st_ctime * 1000,
        "birthtimeMs": getattr(value, "st_birthtime", value.st_ctime) * 1000,
        "file": stat.S_ISREG(value.st_mode),
        "directory": stat.S_ISDIR(value.st_mode),
        "symlink": stat.S_ISLNK(value.st_mode),
        "fifo": stat.S_ISFIFO(value.st_mode),
        "socket": stat.S_ISSOCK(value.st_mode),
        "blockDevice": stat.S_ISBLK(value.st_mode),
        "characterDevice": stat.S_ISCHR(value.st_mode),
    }

try:
    operation = request["operation"]
    name = request.get("name")
    result = None
    if operation == "mkdir":
        os.mkdir(name, request["mode"], dir_fd=directory)
    elif operation == "write":
        flags = os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        flags |= os.O_EXCL if request["flag"] == "wx" else os.O_TRUNC
        descriptor = os.open(name, flags, request["mode"], dir_fd=directory)
        try:
            payload = sys.stdin.buffer.read()
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
        finally:
            os.close(descriptor)
    elif operation == "rename":
        os.rename(request["source"], request["destination"], src_dir_fd=directory, dst_dir_fd=directory)
    elif operation == "unlink":
        os.unlink(name, dir_fd=directory)
    elif operation == "link":
        os.link(request["source"], request["destination"], src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
    elif operation == "rmdir":
        os.rmdir(name, dir_fd=directory)
    elif operation == "lstat":
        result = metadata(os.stat(name, dir_fd=directory, follow_symlinks=False))
    elif operation == "readdir":
        result = os.listdir(directory)
    elif operation == "readlink":
        result = os.readlink(name, dir_fd=directory)
    elif operation == "symlink":
        os.symlink(request["target"], name, dir_fd=directory)
    elif operation == "read_regular":
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(name, flags, dir_fd=directory)
        try:
            value = os.fstat(descriptor)
            if not stat.S_ISREG(value.st_mode):
                raise RuntimeError("cache entry is not a regular file")
            sys.stderr.write(json.dumps({"ok": True, "result": metadata(value)}) + "\n")
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
        finally:
            os.close(descriptor)
        sys.exit(0)
    else:
        raise RuntimeError(f"unsupported directory-relative operation: {operation}")
    print(json.dumps({"ok": True, "result": result}))
except OSError as error:
    print(json.dumps({
        "ok": False,
        "code": errno.errorcode.get(error.errno),
        "message": str(error),
    }), file=sys.stderr)
    sys.exit(1)
except Exception as error:
    print(json.dumps({"ok": False, "code": None, "message": str(error)}), file=sys.stderr)
    sys.exit(1)
`;

function cacheMetadata(value) {
  return {
    ...value,
    isFile: () => value.file,
    isDirectory: () => value.directory,
    isSymbolicLink: () => value.symlink,
    isFIFO: () => value.fifo,
    isSocket: () => value.socket,
    isBlockDevice: () => value.blockDevice,
    isCharacterDevice: () => value.characterDevice,
  };
}

function runPinnedCacheOperation(directory, operation, request = {}, input = undefined) {
  return withPinnedCacheDirectory(directory, (pin) => {
    const readOperation = operation === "read_regular";
    const result = spawnSync(
      "python3",
      ["-c", DIRECTORY_RELATIVE_OPERATION, JSON.stringify({ operation, ...request })],
      {
        encoding: readOperation ? undefined : "utf8",
        input,
        maxBuffer: 1024 * 1024 * 1024,
        stdio: ["pipe", "pipe", "pipe", pin.descriptor],
      },
    );
    if (result.error) {
      throw new Error(`directory-relative cache operation is unavailable: ${result.error.message}`);
    }
    const errorText = readOperation ? result.stderr.toString("utf8") : result.stderr;
    if (result.status !== 0) {
      let detail;
      try {
        detail = JSON.parse(errorText.trim());
      } catch {
        detail = { message: errorText.trim() || `operation exited ${result.status}` };
      }
      const error = new Error(`directory-relative cache ${operation} failed: ${detail.message}`);
      if (typeof detail.code === "string") error.code = detail.code;
      throw error;
    }
    if (readOperation) {
      const detail = JSON.parse(errorText.trim());
      return { bytes: result.stdout, metadata: cacheMetadata(detail.result) };
    }
    const detail = JSON.parse(result.stdout);
    return operation === "lstat" ? cacheMetadata(detail.result) : detail.result;
  });
}

function cacheMkdirSync(directory, options) {
  const resolved = path.resolve(directory);
  const parent = path.dirname(resolved);
  const result = runPinnedCacheOperation(parent, "mkdir", {
    name: path.basename(resolved),
    mode: options?.mode ?? 0o777,
  });
  pinCacheDirectory(resolved);
  return result;
}

function cacheWriteFileSync(file, data, options = {}) {
  const resolved = path.resolve(file);
  const input = Buffer.isBuffer(data) ? data : Buffer.from(data, options.encoding ?? "utf8");
  return runPinnedCacheOperation(
    path.dirname(resolved),
    "write",
    {
      name: path.basename(resolved),
      mode: options.mode ?? 0o666,
      flag: options.flag ?? "w",
    },
    input,
  );
}

function cacheMoveDirectoryTree(source, destination) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  const sourceMetadata = cacheLstatSync(resolvedSource);
  if (sourceMetadata.isSymbolicLink() || !sourceMetadata.isDirectory()) {
    throw new Error(`cache path ${resolvedSource} is not a regular directory`);
  }
  pinCacheDirectory(resolvedSource);
  try {
    const destinationMetadata = cacheLstatSync(resolvedDestination);
    if (destinationMetadata.isSymbolicLink() || !destinationMetadata.isDirectory()) {
      throw new Error(`cache path ${resolvedDestination} is not a regular directory`);
    }
    pinCacheDirectory(resolvedDestination);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    cacheMkdirSync(resolvedDestination, { mode: sourceMetadata.mode & 0o777 });
  }

  for (const name of cacheReaddirSync(resolvedSource)) {
    const sourceEntry = path.join(resolvedSource, name);
    const destinationEntry = path.join(resolvedDestination, name);
    const entryMetadata = cacheLstatSync(sourceEntry);
    if (entryMetadata.isDirectory() && !entryMetadata.isSymbolicLink()) {
      cacheMoveDirectoryTree(sourceEntry, destinationEntry);
      continue;
    }
    let destinationMetadata;
    try {
      destinationMetadata = cacheLstatSync(destinationEntry);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (destinationMetadata === undefined) {
      cacheRenameSync(sourceEntry, destinationEntry);
      continue;
    }
    if (entryMetadata.isSymbolicLink()) {
      const sourceTarget = runPinnedCacheOperation(resolvedSource, "readlink", {
        name: path.basename(sourceEntry),
      });
      const destinationTarget = runPinnedCacheOperation(resolvedDestination, "readlink", {
        name: path.basename(destinationEntry),
      });
      if (!destinationMetadata.isSymbolicLink() || destinationTarget !== sourceTarget) {
        throw new Error(`cross-directory cache move collision at ${resolvedDestination}`);
      }
    } else if (
      destinationMetadata.dev !== entryMetadata.dev ||
      destinationMetadata.ino !== entryMetadata.ino
    ) {
      throw new Error(`cross-directory cache move collision at ${resolvedDestination}`);
    }
    cacheUnlinkSync(sourceEntry);
  }
  cacheRmdirSync(resolvedSource);
}

function cacheRenameSync(source, destination) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  const sourceParent = path.dirname(resolvedSource);
  const destinationParent = path.dirname(resolvedDestination);
  if (sourceParent === destinationParent) {
    return runPinnedCacheOperation(sourceParent, "rename", {
      source: path.basename(resolvedSource),
      destination: path.basename(resolvedDestination),
    });
  }
  const sourceMetadata = cacheLstatSync(resolvedSource);
  // A directory cannot be hard-linked, so its children move through their pinned
  // parents before the empty source directory is removed.
  if (sourceMetadata.isDirectory()) {
    return cacheMoveDirectoryTree(resolvedSource, resolvedDestination);
  }
  if (sourceMetadata.isSymbolicLink()) {
    const target = runPinnedCacheOperation(sourceParent, "readlink", {
      name: path.basename(resolvedSource),
    });
    runPinnedCacheOperation(destinationParent, "symlink", {
      target,
      name: path.basename(resolvedDestination),
    });
  } else {
    cacheLinkAcrossPinnedDirectories(resolvedSource, resolvedDestination);
  }
  let destinationMetadata;
  try {
    destinationMetadata = cacheLstatSync(resolvedDestination);
    if (sourceMetadata.isSymbolicLink()) {
      const sourceTarget = runPinnedCacheOperation(sourceParent, "readlink", {
        name: path.basename(resolvedSource),
      });
      const destinationTarget = runPinnedCacheOperation(destinationParent, "readlink", {
        name: path.basename(resolvedDestination),
      });
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

const DIRECTORY_RELATIVE_LINK = String.raw`
import os
import sys

os.link(sys.argv[1], sys.argv[2], src_dir_fd=3, dst_dir_fd=4, follow_symlinks=False)
`;

function cacheLinkAcrossPinnedDirectories(source, destination) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  const sourceParent = path.dirname(resolvedSource);
  const destinationParent = path.dirname(resolvedDestination);
  const sourcePin = assertCacheDirectory(sourceParent);
  const destinationPin = assertCacheDirectory(destinationParent);
  const result = spawnSync(
    "python3",
    [
      "-c",
      DIRECTORY_RELATIVE_LINK,
      path.basename(resolvedSource),
      path.basename(resolvedDestination),
    ],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe", sourcePin.descriptor, destinationPin.descriptor],
    },
  );
  if (result.error) {
    throw new Error(`directory-relative cache link is unavailable: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const detail = result.stderr.trim();
    throw new Error(`directory-relative cache link failed${detail === "" ? "" : `: ${detail}`}`);
  }
  assertReplayRoot();
  assertCacheDirectory(sourceParent);
  assertCacheDirectory(destinationParent);
}

function cacheUnlinkSync(file) {
  const resolved = path.resolve(file);
  return runPinnedCacheOperation(path.dirname(resolved), "unlink", {
    name: path.basename(resolved),
  });
}

function cacheLinkSync(source, destination) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  const parent = path.dirname(resolvedSource);
  if (parent !== path.dirname(resolvedDestination)) {
    throw new Error("cache hard-link endpoints must share one pinned directory");
  }
  return runPinnedCacheOperation(parent, "link", {
    source: path.basename(resolvedSource),
    destination: path.basename(resolvedDestination),
  });
}

function cacheRmdirSync(directory) {
  const resolved = path.resolve(directory);
  const result = runPinnedCacheOperation(path.dirname(resolved), "rmdir", {
    name: path.basename(resolved),
  });
  const pin = replayDirectoryPins.get(resolved);
  if (pin) closeSync(pin.descriptor);
  replayDirectoryPins.delete(resolved);
  return result;
}

function cacheLstatSync(file) {
  const resolved = path.resolve(file);
  return runPinnedCacheOperation(path.dirname(resolved), "lstat", {
    name: path.basename(resolved),
  });
}

function cacheReaddirSync(directory) {
  return runPinnedCacheOperation(directory, "readdir");
}

function signedEventFromFrame(raw) {
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
  if (validation.idError) throw new Error("event id could not be computed");
  if (!validation.idMatches) throw new Error("event id does not match its content");
  if (validation.signatureError) throw new Error("event signature could not be checked");
  if (!validation.signatureValid) throw new Error("invalid event signature");
  return event;
}

function cachedEventFromFrame(raw, entry) {
  const event = signedEventFromFrame(raw);
  if (event.id !== entry.id || event.created_at !== entry.createdAt) {
    throw new Error("cache filename does not match the event");
  }
  return event;
}

function cachedEventChannelId(event) {
  const channels = event.tags.filter((tag) => Array.isArray(tag) && tag.length === 2 && tag[0] === "h");
  if (channels.length !== 1 || typeof channels[0][1] !== "string" || !CHANNEL_PARTITION.test(channels[0][1])) {
    throw new Error("event does not have exactly one canonical channel tag");
  }
  return channels[0][1];
}

function cacheEntryDescriptor(file) {
  const name = path.basename(file);
  const match = /^(\d+)-([0-9a-f]{64})\.json$/.exec(name);
  const createdAt = match ? Number(match[1]) : undefined;
  if (!match || !Number.isSafeInteger(createdAt)) return null;
  return { name, createdAt, id: match[2], file, malformed: false };
}

function validatedCachedPublisher(file) {
  const entry = cacheEntryDescriptor(file);
  if (entry === null) return null;
  let raw;
  try {
    raw = readRegularFile(file).bytes.toString("utf8");
  } catch (error) {
    throw new Error(`could not read signed cache payload ${file}: ${error.message}`);
  }
  try {
    return cachedEventFromFrame(raw, entry).pubkey;
  } catch {
    return null;
  }
}

function validatedSignedPublisher(file) {
  let raw;
  try {
    raw = readRegularFile(file).bytes.toString("utf8");
  } catch (error) {
    throw new Error(`could not read signed cache payload ${file}: ${error.message}`);
  }
  try {
    return signedEventFromFrame(raw).pubkey;
  } catch {
    return null;
  }
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
  return runPinnedCacheOperation(path.dirname(resolved), "read_regular", {
    name: path.basename(resolved),
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

function relayChannelCacheDirectory(replayDir, relay, channelId) {
  if (!CHANNEL_PARTITION.test(channelId)) throw new Error("channel id must be a canonical UUID");
  return path.join(relayCacheDirectory(replayDir, relay), channelId);
}

const DIRECTORY_RELATIVE_ROOT_PREPARATION = String.raw`
import json
import os
import stat
import sys

descriptor = 3
try:
    for name in sys.argv[1:]:
        try:
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            os.mkdir(name, 0o700, dir_fd=descriptor)
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeError(f"replay cache ancestor {name} is not a regular directory")
        child = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=descriptor,
        )
        if descriptor != 3:
            os.close(descriptor)
        descriptor = child
    metadata = os.fstat(descriptor)
    print(json.dumps({"dev": metadata.st_dev, "ino": metadata.st_ino}))
finally:
    if descriptor != 3:
        os.close(descriptor)
`;

function prepareReplayRootRelativeToPinnedRoot(requested) {
  const filesystemRoot = path.parse(requested).root;
  const rootDescriptor = openSync(
    filesystemRoot,
    constants.O_RDONLY | (constants.O_DIRECTORY ?? 0) | (constants.O_NOFOLLOW ?? 0),
  );
  try {
    const components = path.relative(filesystemRoot, requested).split(path.sep).filter(Boolean);
    const result = spawnSync(
      "python3",
      ["-c", DIRECTORY_RELATIVE_ROOT_PREPARATION, ...components],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe", rootDescriptor] },
    );
    if (result.error) {
      throw new Error(`directory-relative replay cache preparation is unavailable: ${result.error.message}`);
    }
    if (result.status !== 0) {
      const detail = result.stderr.trim();
      throw new Error(detail === "" ? "could not prepare replay cache root safely" : detail);
    }
    const identity = JSON.parse(result.stdout);
    if (!Number.isSafeInteger(identity.dev) || !Number.isSafeInteger(identity.ino)) {
      throw new Error("directory-relative replay cache preparation returned an invalid identity");
    }
    return identity;
  } finally {
    closeSync(rootDescriptor);
  }
}

function prepareCacheRoot(replayDir) {
  const requested = path.resolve(replayDir);
  const expected = prepareReplayRootRelativeToPinnedRoot(requested);
  const before = lstatSync(requested);
  if (before.isSymbolicLink() || !before.isDirectory()) {
    throw new Error(`replay cache path ${replayDir} is not a regular directory`);
  }
  const descriptor = openSync(
    requested,
    constants.O_RDONLY | (constants.O_DIRECTORY ?? 0) | (constants.O_NOFOLLOW ?? 0),
  );
  const pinned = fstatSync(descriptor);
  if (
    !pinned.isDirectory() ||
    pinned.dev !== expected.dev ||
    pinned.ino !== expected.ino ||
    before.dev !== expected.dev ||
    before.ino !== expected.ino ||
    realpathSync(requested) !== requested
  ) {
    closeSync(descriptor);
    throw new Error("replay cache root identity changed while it was being pinned");
  }
  replayRootPin = { path: requested, descriptor, dev: pinned.dev, ino: pinned.ino };
  replayDirectoryPins.set(requested, replayRootPin);
  assertReplayRoot();
  return requested;
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

function prepareRelayCacheDirectory(replayDir, relay, channelId) {
  const endpointDirectory = relayCacheDirectory(replayDir, relay);
  if (!containedCachePath(replayDir, endpointDirectory)) throw new Error("relay cache path escapes replay cache");
  try {
    const metadata = cacheLstatSync(endpointDirectory);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new Error(`relay cache path ${endpointDirectory} is not a regular directory`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    cacheMkdirSync(endpointDirectory, { mode: 0o700 });
  }
  const metadata = cacheLstatSync(endpointDirectory);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`relay cache path ${endpointDirectory} is not a regular directory`);
  }
  pinCacheDirectory(endpointDirectory);
  const channelDirectory = relayChannelCacheDirectory(replayDir, relay, channelId);
  try {
    const channelMetadata = cacheLstatSync(channelDirectory);
    if (channelMetadata.isSymbolicLink() || !channelMetadata.isDirectory()) {
      throw new Error(`channel cache path ${channelDirectory} is not a regular directory`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    cacheMkdirSync(channelDirectory, { mode: 0o700 });
  }
  return pinCacheDirectory(channelDirectory);
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

function canonicalIsoTimestamp(value) {
  if (typeof value !== "string") return false;
  try {
    return new Date(value).toISOString() === value;
  } catch {
    return false;
  }
}

function validQuarantineTimestamps(value) {
  return value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    ["atime_ms", "mtime_ms", "ctime_ms", "birthtime_ms"]
      .every((field) => Number.isFinite(value[field]));
}

function quarantineManifestVariant(manifest, token) {
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
    throw new Error("quarantine manifest is not an object");
  }
  if (typeof manifest.original_path !== "string" || manifest.original_path === "") {
    throw new Error("quarantine manifest has an invalid original_path");
  }
  if (!validQuarantineTimestamps(manifest.original_timestamps)) {
    throw new Error("quarantine manifest has invalid original_timestamps");
  }
  if (!canonicalIsoTimestamp(manifest.quarantine_timestamp)) {
    throw new Error("quarantine manifest has an invalid quarantine_timestamp");
  }
  const regularReference = path.join("payloads", `${token}.json`);
  const corruptReference = path.join("corrupt", token, "entry");
  const recoveryReference = path.join("recovery-corrupt", `${token}.invalid`);
  const recorded = manifest.publisher_pubkey;
  if (recorded !== null && recorded !== undefined &&
      (typeof recorded !== "string" || !CACHE_PARTITION.test(recorded))) {
    throw new Error("quarantine manifest has an invalid publisher identity");
  }
  if (manifest.payload_reference === regularReference) {
    if (
      !Number.isSafeInteger(manifest.source_device) || manifest.source_device < 0 ||
      !Number.isSafeInteger(manifest.source_inode) || manifest.source_inode < 0 ||
      typeof manifest.content_sha256_observed !== "string" ||
      !CACHE_PARTITION.test(manifest.content_sha256_observed) ||
      !Number.isSafeInteger(manifest.content_size_observed) || manifest.content_size_observed < 0 ||
      typeof manifest.quarantine_reason !== "string" || manifest.quarantine_reason === "" ||
      !(manifest.legacy_host === null || typeof manifest.legacy_host === "string")
    ) {
      throw new Error("regular quarantine manifest is malformed");
    }
    return "regular";
  }
  if (manifest.payload_reference === corruptReference) {
    if (
      typeof manifest.corrupt_type !== "string" || manifest.corrupt_type === "" ||
      !(manifest.content_sha256 === null ||
        (typeof manifest.content_sha256 === "string" && CACHE_PARTITION.test(manifest.content_sha256)))
    ) {
      throw new Error("corrupt-node quarantine manifest is malformed");
    }
    return "corrupt";
  }
  if (manifest.payload_reference === recoveryReference) {
    if (
      !Number.isSafeInteger(manifest.source_device) || manifest.source_device < 0 ||
      !Number.isSafeInteger(manifest.source_inode) || manifest.source_inode < 0 ||
      manifest.corrupt_type !== "invalid-quarantine-recovery-residue" ||
      typeof manifest.recovery_error !== "string" || manifest.recovery_error === "" ||
      !(recorded === null || recorded === undefined)
    ) {
      throw new Error("recovery-residue quarantine manifest is malformed");
    }
    return "recovery-residue";
  }
  throw new Error("quarantine manifest has an invalid payload_reference");
}

function requireQuarantinePayloadDirectory(directory) {
  let metadata;
  try {
    metadata = cacheLstatSync(directory);
  } catch (error) {
    if (error.code === "ENOENT") {
      throw new Error(`legacy quarantine payload path ${directory} is missing`);
    }
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`legacy quarantine payload path ${directory} is not a regular directory`);
  }
  return pinCacheDirectory(directory);
}

function readQuarantinePayloadBytes(payload) {
  try {
    return readRegularFile(payload).bytes;
  } catch (error) {
    throw new Error(`could not read legacy quarantine payload ${payload}: ${error.message}`);
  }
}

function quarantineManifestPayload(quarantineDir, manifest, token) {
  const variant = quarantineManifestVariant(manifest, token);
  let payloadParent;
  if (variant === "regular") {
    payloadParent = requireQuarantinePayloadDirectory(path.join(quarantineDir, "payloads"));
  } else if (variant === "corrupt") {
    const corruptDir = requireQuarantinePayloadDirectory(path.join(quarantineDir, "corrupt"));
    payloadParent = requireQuarantinePayloadDirectory(path.join(corruptDir, token));
  } else {
    payloadParent = requireQuarantinePayloadDirectory(path.join(quarantineDir, "recovery-corrupt"));
  }
  const payload = path.resolve(path.join(quarantineDir, manifest.payload_reference));
  if (!containedCachePath(payloadParent, payload) || path.dirname(payload) !== path.resolve(payloadParent)) {
    throw new Error("legacy quarantine payload path does not match its manifest variant");
  }
  let metadata;
  try {
    metadata = cacheLstatSync(payload);
  } catch (error) {
    if (error.code === "ENOENT") throw new Error(`legacy quarantine payload ${payload} is missing`);
    throw error;
  }
  let bytes = null;
  if (variant === "regular" || variant === "recovery-residue") {
    if (!metadata.isFile()) {
      throw new Error(`legacy quarantine payload ${payload} is not a regular file`);
    }
    if (metadata.dev !== manifest.source_device || metadata.ino !== manifest.source_inode) {
      throw new Error(`legacy quarantine payload ${payload} does not match its source identity`);
    }
  }
  if (variant === "regular") {
    bytes = readQuarantinePayloadBytes(payload);
    if (
      sha256(bytes) !== manifest.content_sha256_observed ||
      bytes.length !== manifest.content_size_observed
    ) {
      throw new Error(`legacy quarantine payload ${payload} does not match its observed content`);
    }
  }
  if (variant === "corrupt") {
    if (corruptNodeType(metadata) !== manifest.corrupt_type) {
      throw new Error(`legacy quarantine payload ${payload} does not match corrupt_type ${manifest.corrupt_type}`);
    }
    if (typeof manifest.content_sha256 === "string") {
      if (!metadata.isFile()) {
        throw new Error(`legacy quarantine payload ${payload} cannot provide its recorded content hash`);
      }
      bytes = readQuarantinePayloadBytes(payload);
      if (sha256(bytes) !== manifest.content_sha256) {
        throw new Error(`legacy quarantine payload ${payload} does not match its content hash`);
      }
    }
  }
  if (manifest.publisher_pubkey !== null && manifest.publisher_pubkey !== undefined) {
    if (!metadata.isFile() || validatedSignedPublisher(payload) !== manifest.publisher_pubkey) {
      throw new Error(`legacy quarantine payload ${payload} does not match its publisher identity`);
    }
  }
  return { variant, payload, metadata };
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
        const retained = quarantineManifestPayload(quarantineDir, existing, match[1]);
        if (retained.variant !== "recovery-residue" || existing.payload_reference !== expectedReference) {
          throw new Error("recovery-residue manifest does not match its payload");
        }
        continue;
      }
      const metadata = cacheLstatSync(residue);
      if (metadata.nlink > 1) {
        log(`deferred invalid recovery residue ${residue} until its source transaction resumes`);
        continue;
      }
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
      const token = requireQuarantineToken(match[1]);
      quarantineManifestPayload(quarantineDir, manifest, token);
      const final = quarantineManifestPath(manifestsDir, token);
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
  if (metadata.isDirectory()) return "directory";
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
  const publisherPubkey = metadata.isFile() ? validatedSignedPublisher(file) : null;
  const manifest = {
    original_path: originalPath,
    legacy_host: null,
    original_timestamps: metadataTimestamps(metadata),
    content_sha256: null,
    quarantine_timestamp: new Date().toISOString(),
    payload_reference: payloadReference,
    corrupt_type: type,
    publisher_pubkey: publisherPubkey,
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
  recoverQuarantineTransactions(
    quarantineDir,
    manifestsDir,
    recoveryCorruptDir,
    failures,
  );
  recoverInvalidRecoveryResidues(quarantineDir, manifestsDir, recoveryCorruptDir, failures);
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
      if (metadata.isFile()) {
        candidates.push({ file: candidate, legacyHost: null });
      } else {
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
          log(`could not quarantine unexpected replay cache path ${candidate}: ${error.message}`);
          failures.push(candidate);
        }
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
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
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
        log(`could not quarantine unexpected replay cache path ${candidate}: ${error.message}`);
        failures.push(candidate);
      }
      continue;
    }
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
    for (const legacyName of legacyNames) {
      const legacyFile = path.join(candidate, legacyName);
      try {
        const legacyMetadata = cacheLstatSync(legacyFile);
        if (legacyMetadata.isFile()) {
          candidates.push({ file: legacyFile, legacyHost });
        } else {
          quarantineCorruptPartitionNode(
            replayDir,
            quarantineDir,
            corruptDir,
            manifestsDir,
            legacyFile,
            legacyMetadata,
          );
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
        { publisherPubkey: validatedSignedPublisher(candidate.file) },
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

// The only children an endpoint partition may hold are canonical channel
// directories, `<created_at>-<event-id>.json` entries awaiting migration, and the
// `.json.tmp` half of an interrupted write. Anything else - a stray directory, a
// device node, a symlink standing in for a channel - was silently skipped by both
// the channel walk and the entry walk, so a frame parked under it was neither
// replayed, capped, quarantined, nor seen by rotation's outgoing-identity scan.
// Move it into the same accounted corrupt quarantine the root layer uses, so it
// is preserved and counted rather than invisible.
function quarantineNoncanonicalEndpointChildren(
  replayDir,
  endpointDirectory,
  quarantineDir,
  corruptDir,
  manifestsDir,
  failures,
) {
  let quarantined = 0;
  let names;
  try {
    names = cacheReaddirSync(endpointDirectory);
  } catch (error) {
    if (error.code === "ENOENT") return quarantined;
    log(`could not inspect endpoint cache directory ${endpointDirectory}: ${error.message}`);
    failures.push(endpointDirectory);
    return quarantined;
  }
  for (const name of names) {
    if (name.endsWith(".json") || name.endsWith(".json.tmp")) continue;
    const candidate = path.join(endpointDirectory, name);
    let metadata;
    try {
      metadata = cacheLstatSync(candidate);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      log(`could not inspect endpoint cache path ${candidate}: ${error.message}`);
      failures.push(candidate);
      continue;
    }
    if (CHANNEL_PARTITION.test(name) && metadata.isDirectory() && !metadata.isSymbolicLink()) continue;
    try {
      quarantineCorruptPartitionNode(
        replayDir,
        quarantineDir,
        corruptDir,
        manifestsDir,
        candidate,
        metadata,
      );
      quarantined += 1;
    } catch (error) {
      log(`could not quarantine noncanonical endpoint cache path ${candidate}: ${error.message}`);
      failures.push(candidate);
    }
  }
  return quarantined;
}

function migrateEndpointReplayEntries(replayDir) {
  const failures = [];
  let migrated = 0;
  let quarantined = 0;
  const topology = cacheEndpointDirectories(replayDir);
  failures.push(...topology.failures);
  const quarantineDir = prepareCacheDirectory(replayDir, LEGACY_QUARANTINE);
  const manifestsDir = prepareCacheDirectory(quarantineDir, "manifests");
  const payloadsDir = prepareCacheDirectory(quarantineDir, "payloads");
  const stagingDir = prepareCacheDirectory(quarantineDir, "staging");
  const corruptDir = prepareCacheDirectory(quarantineDir, "corrupt");
  const interruptedWriteQuarantine = {
    replayDir,
    quarantineDir,
    manifestsDir,
    payloadsDir,
    stagingDir,
  };
  for (const endpointDirectory of topology.directories) {
    const endpointSweep = sweepOrphanTemporaries(
      endpointDirectory,
      Date.now(),
      interruptedWriteQuarantine,
    );
    if (endpointSweep.failed > 0) failures.push(endpointDirectory);
    quarantined += endpointSweep.quarantined;
    const inventory = cacheEntries(endpointDirectory);
    failures.push(...inventory.failures);
    for (const entry of inventory.entries) {
      try {
        const metadata = cacheLstatSync(entry.file);
        if (!metadata.isFile()) {
          if (metadata.isSymbolicLink()) log(`cache entry is a symbolic link: ${entry.file}`);
          quarantineCorruptPartitionNode(
            replayDir,
            quarantineDir,
            corruptDir,
            manifestsDir,
            entry.file,
            metadata,
          );
          quarantined += 1;
          continue;
        }
        let event;
        let channelId;
        try {
          const raw = readRegularFile(entry.file).bytes.toString("utf8");
          event = cachedEventFromFrame(raw, entry);
          channelId = cachedEventChannelId(event);
        } catch (error) {
          quarantineLegacyEntry(
            replayDir,
            quarantineDir,
            manifestsDir,
            payloadsDir,
            stagingDir,
            entry.file,
            null,
            { reason: `endpoint-channel-migration: ${error.message}` },
          );
          quarantined += 1;
          continue;
        }
        const channelDirectory = prepareCacheDirectory(endpointDirectory, channelId);
        const destination = path.join(channelDirectory, entry.name);
        try {
          const destinationBytes = readRegularFile(destination).bytes;
          const sourceBytes = readRegularFile(entry.file).bytes;
          if (!destinationBytes.equals(sourceBytes)) {
            throw new Error(`channel cache migration collision at ${destination}`);
          }
          cacheUnlinkSync(entry.file);
        } catch (error) {
          if (error.code !== "ENOENT") throw error;
          cacheRenameSync(entry.file, destination);
        }
        migrated += 1;
      } catch (error) {
        log(`could not migrate endpoint-only cache entry ${entry.file}: ${error.message}`);
        failures.push(entry.file);
      }
    }
    quarantined += quarantineNoncanonicalEndpointChildren(
      replayDir,
      endpointDirectory,
      quarantineDir,
      corruptDir,
      manifestsDir,
      failures,
    );
    const channels = cacheChannelDirectories(endpointDirectory);
    failures.push(...channels.failures);
    for (const channelDirectory of channels.directories) {
      const channelSweep = sweepOrphanTemporaries(
        channelDirectory,
        Date.now(),
        interruptedWriteQuarantine,
      );
      if (channelSweep.failed > 0) failures.push(channelDirectory);
      quarantined += channelSweep.quarantined;
    }
  }
  if (migrated > 0) log(`migrated ${migrated} endpoint-only replay event(s) into channel partitions`);
  if (quarantined > 0) log(`quarantined ${quarantined} ambiguous endpoint-only replay entr${quarantined === 1 ? "y" : "ies"}`);
  return { failures, migrated, quarantined };
}

function replayPublisherEntries(cacheRoot, topologyProvider, description) {
  const topology = topologyProvider(cacheRoot);
  if (topology.failures.length > 0) {
    throw new Error(`could not inspect ${description} partitions:\n${topology.failures.map((file) => `  ${file}`).join("\n")}`);
  }
  const evidence = [];
  for (const directory of topology.directories) {
    const inventory = cacheEntries(directory);
    if (inventory.failures.length > 0) {
      throw new Error(`could not inspect ${description} entries:\n${inventory.failures.map((file) => `  ${file}`).join("\n")}`);
    }
    for (const entry of inventory.entries) {
      if (entry.malformed) throw new Error(`${description} entry ${entry.file} is invalid: ${entry.reason}`);
      let event;
      try {
        event = cachedEventFromFrame(readRegularFile(entry.file).bytes.toString("utf8"), entry);
      } catch (error) {
        throw new Error(`${description} entry ${entry.file} is invalid: ${error.message}`);
      }
      evidence.push({ path: entry.file, publisherPubkey: event.pubkey });
    }
    evidence.push(...temporaryReplayPublisherEntries(directory, description));
  }
  return evidence.sort((left, right) => left.path.localeCompare(right.path));
}

function activeReplayPublisherEntries(cacheRoot) {
  return replayPublisherEntries(cacheRoot, activeCacheDirectories, "active replay");
}

// Flat and host-keyed entries predate the endpoint-digest layout and are never
// activated or delivered - quarantineLegacyEntries moves them aside because their
// scheme and path are unrecoverable. They are still authorship evidence, though:
// each one names the publisher that signed it. Leaving them out of the identity
// scan let an ensure or a plain rotation mint a replacement over an identity this
// home demonstrably published under, which is the very state the orphan gate
// exists to refuse. Read-only on purpose: this reports, it does not migrate.
function legacyReplayPublisherEntries(cacheRoot) {
  const evidence = [];
  const inspectedFiles = new Set();
  const collect = (directory) => {
    let names;
    try {
      names = cacheReaddirSync(directory);
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw new Error(`could not inspect legacy replay directory ${directory}: ${error.message}`);
    }
    for (const name of names) {
      const file = path.join(directory, name);
      let metadata;
      try {
        metadata = cacheLstatSync(file);
      } catch (error) {
        if (error.code === "ENOENT") continue;
        throw new Error(`could not inspect legacy replay entry ${file}: ${error.message}`);
      }
      const expectedFile = name.endsWith(".json") || name.endsWith(".json.tmp");
      if (!metadata.isFile()) {
        if (expectedFile) throw new Error(`legacy replay entry ${file} is not a regular file`);
        continue;
      }
      inspectedFiles.add(file);
      const publisherPubkey = validatedSignedPublisher(file);
      if (publisherPubkey !== null) {
        evidence.push({ path: file, publisherPubkey });
      } else if (expectedFile) {
        throw new Error(`legacy replay entry ${file} is not a valid signed EVENT frame`);
      }
    }
  };
  collect(cacheRoot);
  let names;
  try {
    names = cacheReaddirSync(cacheRoot);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return evidence;
  }
  for (const name of names) {
    if (name === LEGACY_QUARANTINE || name.endsWith(".json") || name.endsWith(".json.tmp")) continue;
    const candidate = path.join(cacheRoot, name);
    let metadata;
    try {
      metadata = cacheLstatSync(candidate);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      throw new Error(`could not inspect legacy replay directory ${candidate}: ${error.message}`);
    }
    if (metadata.isSymbolicLink()) {
      throw new Error(`legacy replay path ${candidate} is a symbolic link`);
    }
    if (CACHE_PARTITION.test(name)) {
      if (metadata.isFile() && !inspectedFiles.has(candidate)) {
        const publisherPubkey = validatedSignedPublisher(candidate);
        if (publisherPubkey !== null) evidence.push({ path: candidate, publisherPubkey });
      }
      continue;
    }
    if (metadata.isFile()) {
      continue;
    }
    if (!metadata.isDirectory()) continue;
    pinCacheDirectory(candidate);
    collect(candidate);
  }
  return evidence;
}

function stagedQuarantinePublisherEntries(quarantineDir) {
  const stagingDir = path.join(quarantineDir, "staging");
  let metadata;
  try {
    metadata = cacheLstatSync(stagingDir);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`legacy quarantine staging path ${stagingDir} is not a regular directory`);
  }
  pinCacheDirectory(stagingDir);
  const payloadsDir = path.join(quarantineDir, "payloads");
  const evidence = [];
  for (const name of cacheReaddirSync(stagingDir)) {
    if (!QUARANTINE_TOKEN.test(name)) {
      throw new Error(`legacy quarantine staging transaction ${name} has a noncanonical name`);
    }
    const transactionDir = path.join(stagingDir, name);
    metadata = cacheLstatSync(transactionDir);
    if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
      throw new Error(`legacy quarantine staging transaction ${transactionDir} is not a regular directory`);
    }
    pinCacheDirectory(transactionDir);
    const originFile = path.join(transactionDir, "origin.json");
    const sourceFile = path.join(transactionDir, "source");
    let origin = null;
    let payload = null;
    try {
      origin = readQuarantineManifest(originFile);
      ({ payload } = stagedLegacyOrigin(origin, quarantineDir, payloadsDir, transactionDir));
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw new Error(`could not read legacy quarantine staging record ${originFile}: ${error.message}`);
      }
    }
    const recorded = origin?.publisher_pubkey;
    if (recorded !== null && recorded !== undefined) {
      if (typeof recorded !== "string" || !CACHE_PARTITION.test(recorded)) {
        throw new Error(`legacy quarantine staging record ${originFile} has an invalid publisher identity`);
      }
      evidence.push({ path: originFile, publisherPubkey: recorded });
      continue;
    }
    let candidate = sourceFile;
    try {
      metadata = cacheLstatSync(sourceFile);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      candidate = payload;
    }
    if (candidate === null) continue;
    if (candidate === payload) {
      try {
        metadata = cacheLstatSync(payloadsDir);
      } catch (error) {
        if (error.code === "ENOENT") continue;
        throw error;
      }
      if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
        throw new Error(`legacy quarantine payload path ${payloadsDir} is not a regular directory`);
      }
      pinCacheDirectory(payloadsDir);
    }
    const publisherPubkey = validatedSignedPublisher(candidate);
    if (publisherPubkey !== null) evidence.push({ path: candidate, publisherPubkey });
  }
  return evidence;
}

function quarantinedReplayPublisherEntries(cacheRoot) {
  const quarantineDir = path.join(cacheRoot, LEGACY_QUARANTINE);
  let metadata;
  try {
    metadata = cacheLstatSync(quarantineDir);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`legacy quarantine path ${quarantineDir} is not a regular directory`);
  }
  pinCacheDirectory(quarantineDir);
  const evidence = stagedQuarantinePublisherEntries(quarantineDir);
  const manifestsDir = path.join(quarantineDir, "manifests");
  try {
    metadata = cacheLstatSync(manifestsDir);
  } catch (error) {
    if (error.code === "ENOENT") return evidence;
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`legacy quarantine manifest path ${manifestsDir} is not a regular directory`);
  }
  pinCacheDirectory(manifestsDir);
  for (const name of cacheReaddirSync(manifestsDir).filter((candidate) => candidate.endsWith(".json"))) {
    const match = /^([0-9a-f]{64})\.json$/.exec(name);
    if (!match) throw new Error(`legacy quarantine manifest ${name} has a noncanonical name`);
    const manifestFile = quarantineManifestPath(manifestsDir, match[1]);
    let manifest;
    try {
      manifest = readQuarantineManifest(manifestFile);
    } catch (error) {
      throw new Error(`could not read legacy quarantine manifest ${manifestFile}: ${error.message}`);
    }
    let retained;
    try {
      retained = quarantineManifestPayload(quarantineDir, manifest, match[1]);
    } catch (error) {
      throw new Error(`legacy quarantine manifest ${manifestFile} is malformed or inconsistent: ${error.message}`);
    }
    const recorded = manifest.publisher_pubkey;
    if (recorded !== null && recorded !== undefined) {
      evidence.push({ path: manifestFile, publisherPubkey: recorded });
      continue;
    }
    if (retained.variant === "recovery-residue" || !retained.metadata.isFile()) continue;
    const publisherPubkey = validatedSignedPublisher(retained.payload);
    if (publisherPubkey !== null) evidence.push({ path: retained.payload, publisherPubkey });
  }
  return evidence;
}

function endpointReplayPublisherEntries(cacheRoot) {
  return replayPublisherEntries(cacheRoot, cacheEndpointDirectories, "endpoint replay");
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
  const cacheRoot = prepareCacheRoot(replayDir);
  return [
    ...activeReplayPublisherEntries(cacheRoot),
    ...endpointReplayPublisherEntries(cacheRoot),
    ...legacyReplayPublisherEntries(cacheRoot),
    ...quarantinedReplayPublisherEntries(cacheRoot),
  ]
    .sort((left, right) => left.path.localeCompare(right.path));
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
  const endpointMigration = migrateEndpointReplayEntries(cacheRoot);
  if (endpointMigration.failures.length > 0) {
    throw new Error(
      `could not migrate endpoint-only replay entries:\n${endpointMigration.failures.map((file) => `  ${file}`).join("\n")}`,
    );
  }
  const blocking = [
    ...activeReplayPublisherEntries(cacheRoot),
    ...endpointReplayPublisherEntries(cacheRoot),
    ...legacyReplayPublisherEntries(cacheRoot),
  ]
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

function temporaryReplayPublisherEntries(replayDir, description) {
  let names;
  try {
    names = cacheReaddirSync(replayDir);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw new Error(`could not inspect ${description} temporaries in ${replayDir}: ${error.message}`);
  }
  const evidence = [];
  for (const name of names.filter((candidate) => candidate.endsWith(".json.tmp"))) {
    const file = path.join(replayDir, name);
    let metadata;
    try {
      metadata = cacheLstatSync(file);
    } catch (error) {
      if (error.code === "ENOENT") continue;
      throw new Error(`could not inspect ${description} temporary ${file}: ${error.message}`);
    }
    if (metadata.isSymbolicLink() || !metadata.isFile()) {
      throw new Error(`${description} temporary ${file} is not a regular file`);
    }
    const publisherPubkey = validatedSignedPublisher(file);
    if (publisherPubkey !== null) evidence.push({ path: file, publisherPubkey });
  }
  return evidence;
}

function cacheEndpointDirectories(replayDir) {
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

function cacheChannelDirectories(endpointDirectory) {
  let names;
  try {
    names = cacheReaddirSync(endpointDirectory);
  } catch (error) {
    if (error.code === "ENOENT") return { directories: [], failures: [] };
    log(`could not inspect endpoint cache directory ${endpointDirectory}: ${error.message}`);
    return { directories: [], failures: [endpointDirectory] };
  }
  const directories = [];
  const failures = [];
  for (const name of names) {
    // `.json` entries are the endpoint-only migration's business and `.json.tmp`
    // is the orphan sweep's; everything else that is not a canonical channel
    // directory is corrupt state that quarantineNoncanonicalEndpointChildren
    // should already have moved aside. Reporting rather than skipping it is what
    // stops rotation from certifying a partition it never actually walked.
    if (name.endsWith(".json") || name.endsWith(".json.tmp")) continue;
    const directory = path.join(endpointDirectory, name);
    try {
      const metadata = cacheLstatSync(directory);
      if (!CHANNEL_PARTITION.test(name) || metadata.isSymbolicLink() || !metadata.isDirectory()) {
        log(`rejected channel cache path ${directory}`);
        failures.push(directory);
      } else {
        directories.push(pinCacheDirectory(directory));
      }
    } catch (error) {
      if (error.code === "ENOENT") continue;
      log(`could not inspect channel cache path ${directory}: ${error.message}`);
      failures.push(directory);
    }
  }
  return { directories, failures };
}

function activeCacheDirectories(replayDir) {
  const endpoints = cacheEndpointDirectories(replayDir);
  const directories = [];
  const failures = [...endpoints.failures];
  for (const endpointDirectory of endpoints.directories) {
    const channels = cacheChannelDirectories(endpointDirectory);
    directories.push(...channels.directories);
    failures.push(...channels.failures);
  }
  return { directories, failures };
}

// A `.json.tmp` is the half of cacheEvent's atomic write that a kill between the
// write and the rename leaves behind. It matches neither the drain's `.json`
// filter nor the cap's accounting, so without this it is never published, never
// counted, and never removed - one signed projection leaked per interrupted run,
// forever. Age-gated so a concurrent run's in-flight write is not changed out
// from under it; complete signed frames are recovered byte-for-byte, invalid
// frames are discarded, and valid conflicts are preserved in quarantine.
const ORPHAN_TMP_AGE_MS = 60000;

function sweepOrphanTemporaries(replayDir, now, quarantine = null) {
  let names;
  try {
    names = cacheReaddirSync(replayDir);
  } catch (error) {
    if (error.code === "ENOENT") return { swept: 0, failed: 0 };
    log(`could not inspect cache directory ${replayDir}: ${error.message}`);
    return { swept: 0, failed: 1 };
  }
  let recovered = 0;
  let discarded = 0;
  let quarantined = 0;
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
    let raw;
    try {
      raw = readRegularFile(file).bytes.toString("utf8");
    } catch (error) {
      log(`could not inspect interrupted cache write ${name}: ${error.message}`);
      failed += 1;
      continue;
    }
    let event;
    let channelId;
    try {
      event = signedEventFromFrame(raw);
      channelId = cachedEventChannelId(event);
    } catch (error) {
      const removal = removeCacheFile(replayDir, file, `discard invalid interrupted cache write ${name}`);
      if (removal.removed) discarded += 1;
      if (removal.failed) failed += 1;
      continue;
    }
    const directoryChannel = path.basename(replayDir);
    const wrongChannel = CHANNEL_PARTITION.test(directoryChannel) && directoryChannel !== channelId;
    const target = path.join(replayDir, `${event.created_at}-${event.id}.json`);
    let collision = false;
    if (!wrongChannel) {
      try {
        const existing = readRegularFile(target).bytes.toString("utf8");
        if (existing === raw) {
          cacheUnlinkSync(file);
          recovered += 1;
          continue;
        }
        collision = true;
      } catch (error) {
        if (error.code !== "ENOENT") {
          log(`could not recover interrupted cache write ${name}: ${error.message}`);
          failed += 1;
          continue;
        }
      }
    }
    if (!wrongChannel && !collision) {
      try {
        cacheRenameSync(file, target);
        recovered += 1;
      } catch (error) {
        log(`could not recover interrupted cache write ${name}: ${error.message}`);
        failed += 1;
      }
      continue;
    }
    if (quarantine === null) {
      log(`could not recover interrupted cache write ${name}: ${wrongChannel ? "channel tag does not match its cache partition" : "cache destination collision"}`);
      failed += 1;
      continue;
    }
    try {
      quarantineLegacyEntry(
        quarantine.replayDir,
        quarantine.quarantineDir,
        quarantine.manifestsDir,
        quarantine.payloadsDir,
        quarantine.stagingDir,
        file,
        null,
        {
          reason: wrongChannel
            ? "interrupted-cache-write-channel-mismatch"
            : "interrupted-cache-write-collision",
          publisherPubkey: event.pubkey,
        },
      );
      quarantined += 1;
    } catch (error) {
      log(`could not quarantine interrupted cache write ${name}: ${error.message}`);
      failed += 1;
    }
  }
  if (recovered > 0) log(`recovered ${recovered} interrupted cache write(s)`);
  if (discarded > 0) log(`discarded ${discarded} invalid interrupted cache write(s)`);
  if (quarantined > 0) log(`quarantined ${quarantined} conflicted interrupted cache write(s)`);
  return { recovered, discarded, quarantined, failed };
}

// Keep the cache bounded. An unbounded queue after a long relay outage would grow
// without limit and replay ancient fleet state; oldest-first is the right thing to
// drop because a newer bearings projection supersedes an older one anyway.
function pruneCache(replayDir, maxCache, protectedFile) {
  const now = Date.now();
  let failed = sweepOrphanTemporaries(replayDir, now).failed;
  const outcomes = new Map();
  const inventory = cacheEntries(replayDir);
  failed += inventory.failures.length;
  for (const file of inventory.failures) outcomes.set(`unreadable:${file}`, RETRYABLE);
  const entries = inventory.entries;
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

// The whole-tree half of a publish, split out so its lock is held for a
// filesystem walk rather than for a relay round trip. Quarantine and endpoint
// migration touch paths no single channel owns, so they cannot run under a
// per-queue lock; delivery must not run under a home-wide one.
export function migrateReplayCache(replayDir) {
  const cacheRoot = prepareCacheRoot(replayDir);
  const legacy = quarantineLegacyEntries(cacheRoot);
  const endpoint = migrateEndpointReplayEntries(cacheRoot);
  return { legacy: legacy.failures, endpoint: endpoint.failures };
}

function normalizeMigrationFailures(migration) {
  if (!migration || typeof migration !== "object" || Array.isArray(migration)) {
    throw new Error("missing envelope field: migration");
  }
  const read = (name) => {
    const value = migration[name];
    if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
      throw new Error(`invalid envelope field: migration.${name}`);
    }
    return value;
  };
  return { legacy: read("legacy"), endpoint: read("endpoint") };
}

function normalizePreparation(preparation, relayCacheDir) {
  if (preparation === null || typeof preparation !== "object" || Array.isArray(preparation)) {
    throw new Error("invalid envelope field: preparation");
  }
  if (!Number.isSafeInteger(preparation.failed) || preparation.failed < 0) {
    throw new Error("invalid envelope field: preparation.failed");
  }
  if (!Array.isArray(preparation.entries) || !Array.isArray(preparation.outcomes)) {
    throw new Error("invalid envelope field: preparation cache state");
  }
  const directory = path.resolve(relayCacheDir);
  const entries = preparation.entries.map((entry) => {
    if (
      entry === null ||
      typeof entry !== "object" ||
      Array.isArray(entry) ||
      typeof entry.name !== "string" ||
      !Number.isSafeInteger(entry.createdAt) ||
      typeof entry.id !== "string" ||
      !CACHE_PARTITION.test(entry.id) ||
      typeof entry.file !== "string" ||
      path.dirname(path.resolve(entry.file)) !== directory
    ) {
      throw new Error("invalid envelope field: preparation.entries");
    }
    return { ...entry, malformed: false };
  });
  const outcomes = preparation.outcomes.map((entry) => {
    if (
      !Array.isArray(entry) ||
      entry.length !== 2 ||
      typeof entry[0] !== "string" ||
      ![DELIVERED, PERMANENT, RETRYABLE].includes(entry[1])
    ) {
      throw new Error("invalid envelope field: preparation.outcomes");
    }
    return entry;
  });
  return { entries, outcomes, failed: preparation.failed };
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
    phase,
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
  if (!CHANNEL_PARTITION.test(channelId)) throw new Error("channel id must be a canonical UUID");
  if (phase !== "prepare" && phase !== "deliver") throw new Error("invalid envelope field: phase");
  resolveLoopbackRelayHost(relay);
  const currentPublisher = publicKeyFromPrivate(privateKey);
  const cacheRoot = prepareCacheRoot(replayDir);
  const relayCacheDir = prepareRelayCacheDirectory(cacheRoot, relay, channelId);

  if (phase === "prepare") {
    const event = buildBearingsEvent(channelId, content, privateKey, [
      ["fm-schema", "fm-bearings.v1"],
      ["nonce", randomBytes(16).toString("hex")],
    ]);
    const currentFile = cacheEvent(relayCacheDir, event);
    const cacheMaintenance = pruneCache(relayCacheDir, maxCache, currentFile);
    recordPublisherTarget(targetsFile, {
      relay,
      channel_id: channelId,
      publisher_pubkey: event.pubkey,
    });
    log(`signed event ${event.id} (${Buffer.byteLength(content, "utf8")} bytes) for channel ${channelId}`);
    process.stdout.write(JSON.stringify({
      entries: cacheMaintenance.entries,
      outcomes: [...cacheMaintenance.outcomes],
      failed: cacheMaintenance.failed,
    }));
    return 0;
  }

  const preparation = normalizePreparation(envelope.preparation, relayCacheDir);
  const migrationFailures = normalizeMigrationFailures(envelope.migration);
  let cleanupFailures = preparation.failed
    + migrationFailures.legacy.length
    + migrationFailures.endpoint.length;

  const pending = preparation.entries;
  // Final verdict per cache entry rather than running counters, because an entry
  // can be attempted twice: a pass that ran before a late NIP-42 handshake
  // completed is superseded by the one that ran after it, and incrementing
  // counters would report the same event as both retained and delivered.
  const outcome = new Map(preparation.outcomes);
  for (const file of migrationFailures.legacy) outcome.set(`legacy:${file}`, RETRYABLE);
  for (const file of migrationFailures.endpoint) outcome.set(`endpoint-migration:${file}`, RETRYABLE);
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
        let parsedChannelId;
        try {
          parsed = cachedEventFromFrame(raw, entry);
          parsedChannelId = cachedEventChannelId(parsed);
          if (parsedChannelId !== channelId) {
            throw new Error(`event channel ${parsedChannelId} does not match queue channel ${channelId}`);
          }
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
        try {
          recordPublisherTarget(targetsFile, {
            relay,
            channel_id: parsedChannelId,
            publisher_pubkey: parsed.pubkey,
          });
        } catch (error) {
          log(`could not record publisher target for cached event ${entry.id}: ${error.message}`);
          outcome.set(entry.file, RETRYABLE);
          continue;
        }
        if (parsed.pubkey !== currentPublisher) {
          log(
            `retaining cached event ${entry.id}: publisher ${parsed.pubkey} differs from authenticated publisher ${currentPublisher}`,
          );
          outcome.set(entry.file, RETRYABLE);
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
