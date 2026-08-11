#!/usr/bin/env node
// Durable publisher-target and relay-authority registries for Buzz key rotation.
//
// data/buzz-publisher-targets.jsonl contains one canonical JSON object per used
// relay/channel/publisher tuple. Each object has exactly relay, channel_id, and
// publisher_pubkey string fields. Relays use normalizeRelayEndpoint(), while
// channel identities are lowercase canonical UUIDs and publisher identities are
// lowercase 64-character hex values.
// A target's canonical selector is the lowercase SHA-256 digest of the exact
// JSON.stringify() bytes of that normalized three-field object.
// Every mutation holds the registry's adjacent transaction lock while reading
// and replacing the complete file, so concurrent publishers cannot lose a tuple.
// Forgetting a selector removes only that object, and removes the registry file
// when no targets remain because an existing empty registry is corrupt state.
// Any malformed, non-regular, or symlinked existing registry fails closed.
// data/buzz-relay-authorities.jsonl contains one canonical JSON object per
// relay/channel pair, with exactly relay, channel_id, and signer_pubkey fields.
// The first verified kind-39002 snapshot records its signer unless strict mode
// requires an existing pin, and every later snapshot must match that signer.
// Relay identity retirement normalizes one complete endpoint, refuses while any
// publisher target still names it, and atomically removes every authority pin
// for that endpoint while preserving pins for every other endpoint.
// data/buzz-compromised-unverifiable-pairs.jsonl records relay/channel pairs
// that a compromised recovery could not authenticate because the recorded
// publisher identity no longer had matching readable private material.
// Each canonical object has channel_id, publisher_pubkey, reason, recorded_at,
// and relay fields, and retries preserve the first timestamp for an identical
// publisher/pair/reason record.
//
// Usage:
//   node bin/fm-buzz-targets.mjs list FILE
//   node bin/fm-buzz-targets.mjs list-with-ids FILE
//   node bin/fm-buzz-targets.mjs normalize-relay URL
//   node bin/fm-buzz-targets.mjs record-unverifiable TARGETS_FILE OUTPUT_FILE PUBKEY REASON
//   node bin/fm-buzz-targets.mjs forget-target FILE TARGET_HEX
//   node bin/fm-buzz-targets.mjs forget-relay-identity TARGETS_FILE AUTHORITIES_FILE ENDPOINT
//   node bin/fm-buzz-targets.mjs retire-unverifiable TARGETS_FILE OUTPUT_FILE REASON PUBKEY...

import {
  closeSync,
  fstatSync,
  lstatSync,
  openSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeRelayEndpoint } from "./fm-buzz-lib.mjs";

const HEX_64 = /^[0-9a-f]{64}$/;
const CHANNEL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const REGISTRY_LOCK_TIMEOUT_MS = 15000;
const REGISTRY_LOCK_STALE_MS = 5000;
const registryLockWaiter = new Int32Array(new SharedArrayBuffer(4));
let registryTestDelayConsumed = false;

function registryLockSleep(milliseconds) {
  Atomics.wait(registryLockWaiter, 0, 0, milliseconds);
}

function registryLockOwnerAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === "EPERM";
  }
}

function acquireRegistryLock(file) {
  const lock = `${path.resolve(file)}.registry-lock`;
  const deadline = Date.now() + REGISTRY_LOCK_TIMEOUT_MS;
  for (;;) {
    let descriptor;
    try {
      descriptor = openSync(lock, "wx", 0o600);
      writeFileSync(descriptor, `${process.pid}\n`);
      const metadata = fstatSync(descriptor);
      return { descriptor, lock, dev: metadata.dev, ino: metadata.ino };
    } catch (error) {
      if (descriptor !== undefined) closeSync(descriptor);
      if (error.code !== "EEXIST") throw error;
    }

    let metadata;
    let owner;
    try {
      metadata = lstatSync(lock);
      if (metadata.isSymbolicLink() || !metadata.isFile()) {
        throw new Error(`registry lock ${lock} is not a regular file`);
      }
      const raw = readFileSync(lock, "utf8").trim();
      owner = /^[1-9][0-9]*$/.test(raw) ? Number(raw) : null;
    } catch (error) {
      if (error.code === "ENOENT") continue;
      throw error;
    }

    if (!registryLockOwnerAlive(owner) && Date.now() - metadata.mtimeMs >= REGISTRY_LOCK_STALE_MS) {
      const stale = `${lock}.${process.pid}.${Date.now()}.stale`;
      try {
        renameSync(lock, stale);
        unlinkSync(stale);
        continue;
      } catch (error) {
        if (error.code === "ENOENT") continue;
        throw error;
      }
    }
    if (Date.now() >= deadline) throw new Error(`timed out waiting for registry lock ${lock}`);
    registryLockSleep(10);
  }
}

function releaseRegistryLock(held) {
  try {
    const descriptorMetadata = fstatSync(held.descriptor);
    const pathMetadata = lstatSync(held.lock);
    if (
      pathMetadata.isSymbolicLink() ||
      !pathMetadata.isFile() ||
      descriptorMetadata.dev !== held.dev ||
      descriptorMetadata.ino !== held.ino ||
      pathMetadata.dev !== held.dev ||
      pathMetadata.ino !== held.ino
    ) {
      throw new Error(`registry lock identity changed: ${held.lock}`);
    }
    unlinkSync(held.lock);
  } finally {
    closeSync(held.descriptor);
  }
}

function withRegistryLocks(files, operation) {
  const held = [];
  try {
    for (const file of [...new Set(files.map((value) => path.resolve(value)))].sort()) {
      held.push(acquireRegistryLock(file));
    }
    return operation();
  } finally {
    for (let index = held.length - 1; index >= 0; index -= 1) releaseRegistryLock(held[index]);
  }
}

function delayRegistryUpdateForTest() {
  const raw = process.env.FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS;
  if (raw === undefined || registryTestDelayConsumed) return;
  const milliseconds = Number(raw);
  if (!Number.isSafeInteger(milliseconds) || milliseconds < 0 || milliseconds > 5000) {
    throw new Error("invalid FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS");
  }
  registryTestDelayConsumed = true;
  registryLockSleep(milliseconds);
}

function normalizeHexIdentity(value, field) {
  if (typeof value !== "string") throw new Error(`${field} must be a string`);
  const normalized = value.trim().toLowerCase();
  if (!HEX_64.test(normalized)) throw new Error(`${field} must be 64 hexadecimal characters`);
  return normalized;
}

export function normalizePublisherTarget(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("publisher target must be an object");
  }
  const fields = Object.keys(value).sort();
  if (fields.join(",") !== "channel_id,publisher_pubkey,relay") {
    throw new Error("publisher target has unexpected fields");
  }
  return {
    relay: normalizeRelayEndpoint(value.relay),
    channel_id: normalizeChannelIdentity(value.channel_id),
    publisher_pubkey: normalizeHexIdentity(value.publisher_pubkey, "publisher_pubkey"),
  };
}

function normalizeChannelIdentity(value) {
  if (typeof value !== "string") throw new Error("channel_id must be a string");
  const normalized = value.trim().toLowerCase();
  if (!CHANNEL_UUID.test(normalized)) throw new Error("channel_id must be a canonical UUID");
  return normalized;
}

function targetIdentity(target) {
  return `${target.publisher_pubkey}\u0000${target.relay}\u0000${target.channel_id}`;
}

export function publisherTargetHex(value) {
  const target = normalizePublisherTarget(value);
  return createHash("sha256").update(JSON.stringify(target)).digest("hex");
}

function normalizeTargetHex(value) {
  if (typeof value !== "string" || !HEX_64.test(value)) {
    throw new Error("target hex must be 64 lowercase hexadecimal characters");
  }
  return value;
}

function relayChannelIdentity(value) {
  return `${value.relay}\u0000${value.channel_id}`;
}

function unverifiableIdentity(value) {
  return `${value.publisher_pubkey}\u0000${value.relay}\u0000${value.channel_id}\u0000${value.reason}`;
}

function canonicalTargets(targets) {
  const unique = new Map();
  for (const target of targets) {
    const normalized = normalizePublisherTarget(target);
    unique.set(targetIdentity(normalized), normalized);
  }
  return [...unique.values()].sort((left, right) => targetIdentity(left).localeCompare(targetIdentity(right)));
}

export function readPublisherTargets(file) {
  return readCanonicalRegistry(file, "publisher target", normalizePublisherTarget, targetIdentity);
}

function readCanonicalRegistry(file, label, normalize, identity) {
  let metadata;
  try {
    metadata = lstatSync(file);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`${label} registry ${file} is not a regular file`);
  }
  const raw = readFileSync(file, "utf8");
  if (raw.length === 0) throw new Error(`${label} registry ${file} is empty or truncated`);
  const lines = raw.split("\n");
  const records = [];
  for (const [index, line] of lines.entries()) {
    if (line === "" && index === lines.length - 1) continue;
    if (line.trim() === "") throw new Error(`${label} registry ${file} has a blank record`);
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      throw new Error(`${label} registry ${file} has invalid JSON on line ${index + 1}`);
    }
    try {
      const normalized = normalize(parsed);
      if (Object.entries(normalized).some(([field, value]) => parsed[field] !== value)) {
        throw new Error("record is not canonical");
      }
      records.push(normalized);
    } catch (error) {
      throw new Error(`${label} registry ${file} has an invalid record on line ${index + 1}: ${error.message}`);
    }
  }
  const identities = new Set(records.map(identity));
  if (identities.size !== records.length) {
    throw new Error(`${label} registry ${file} contains duplicate records`);
  }
  return records.sort((left, right) => identity(left).localeCompare(identity(right)));
}

function replaceRegistry(file, records, label) {
  const directory = path.dirname(file);
  const directoryMetadata = lstatSync(directory);
  if (directoryMetadata.isSymbolicLink() || !directoryMetadata.isDirectory()) {
    throw new Error(`${label} registry directory ${directory} is not a regular directory`);
  }
  try {
    const targetMetadata = lstatSync(file);
    if (targetMetadata.isSymbolicLink() || !targetMetadata.isFile()) {
      throw new Error(`${label} registry ${file} is not a regular file`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (records.length === 0) {
    try {
      unlinkSync(file);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    return;
  }
  const temporary = path.join(
    directory,
    `.${path.basename(file)}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`,
  );
  const content = records.map((record) => JSON.stringify(record)).join("\n") + "\n";
  writeFileSync(temporary, content, { mode: 0o600, flag: "wx" });
  try {
    renameSync(temporary, file);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch (cleanupError) {
      if (cleanupError.code !== "ENOENT") throw cleanupError;
    }
    throw error;
  }
}

export function recordPublisherTarget(file, value) {
  const target = normalizePublisherTarget(value);
  return withRegistryLocks([file], () => {
    const existing = readPublisherTargets(file);
    delayRegistryUpdateForTest();
    const merged = canonicalTargets([...existing, target]);
    if (merged.length === existing.length && existing.some((candidate) => targetIdentity(candidate) === targetIdentity(target))) {
      return target;
    }
    replaceRegistry(file, merged, "publisher target");
    return target;
  });
}

export function forgetPublisherTarget(file, value) {
  const targetHex = normalizeTargetHex(value);
  return withRegistryLocks([file], () => {
    const existing = readPublisherTargets(file);
    const matches = existing.filter((target) => publisherTargetHex(target) === targetHex);
    if (matches.length !== 1) throw new Error(`publisher target ${targetHex} was not found`);
    const remaining = existing.filter((target) => publisherTargetHex(target) !== targetHex);
    replaceRegistry(file, remaining, "publisher target");
    return matches[0];
  });
}

export function normalizeRelayAuthority(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("relay authority must be an object");
  }
  const fields = Object.keys(value).sort();
  if (fields.join(",") !== "channel_id,relay,signer_pubkey") {
    throw new Error("relay authority has unexpected fields");
  }
  return {
    relay: normalizeRelayEndpoint(value.relay),
    channel_id: normalizeChannelIdentity(value.channel_id),
    signer_pubkey: normalizeHexIdentity(value.signer_pubkey, "signer_pubkey"),
  };
}

export function readRelayAuthorities(file) {
  return readCanonicalRegistry(file, "relay authority", normalizeRelayAuthority, relayChannelIdentity);
}

export function verifyOrRecordRelayAuthority(file, value, options = {}) {
  const authority = normalizeRelayAuthority(value);
  if (typeof options.strict !== "boolean") throw new Error("relay authority strict mode must be boolean");
  return withRegistryLocks([file], () => {
    const existing = readRelayAuthorities(file);
    const pinned = existing.find((candidate) => relayChannelIdentity(candidate) === relayChannelIdentity(authority));
    if (pinned !== undefined) {
      if (pinned.signer_pubkey !== authority.signer_pubkey) {
        throw new Error(
          `relay membership authority mismatch: expected ${pinned.signer_pubkey}, received ${authority.signer_pubkey}`,
        );
      }
      return { authority: pinned, recorded: false };
    }
    if (options.strict) throw new Error("relay membership authority is not pinned in strict mode");
    const merged = [...existing, authority]
      .sort((left, right) => relayChannelIdentity(left).localeCompare(relayChannelIdentity(right)));
    replaceRegistry(file, merged, "relay authority");
    return { authority, recorded: true };
  });
}

export function forgetRelayIdentity(targetsFile, authoritiesFile, endpoint) {
  const relay = normalizeRelayEndpoint(endpoint);
  return withRegistryLocks([targetsFile, authoritiesFile], () => {
    const targets = readPublisherTargets(targetsFile).filter((target) => target.relay === relay);
    if (targets.length > 0) {
      const selectors = targets.map(publisherTargetHex).sort();
      throw new Error(
        `publisher targets still exist for relay ${relay}: ${selectors.join(", ")}`,
      );
    }
    const existing = readRelayAuthorities(authoritiesFile);
    const retiring = existing.filter((authority) => authority.relay === relay);
    const remaining = existing.filter((authority) => authority.relay !== relay);
    if (retiring.length > 0) replaceRegistry(authoritiesFile, remaining, "relay authority");
    return { relay, removed: retiring };
  });
}

export function normalizeCompromisedUnverifiablePair(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("compromised unverifiable pair must be an object");
  }
  const fields = Object.keys(value).sort();
  if (fields.join(",") !== "channel_id,publisher_pubkey,reason,recorded_at,relay") {
    throw new Error("compromised unverifiable pair has unexpected fields");
  }
  if (typeof value.reason !== "string" || value.reason.trim() === "" || value.reason !== value.reason.trim()) {
    throw new Error("reason must be a nonempty trimmed string");
  }
  if (typeof value.recorded_at !== "string" || new Date(value.recorded_at).toISOString() !== value.recorded_at) {
    throw new Error("recorded_at must be a canonical ISO timestamp");
  }
  return {
    relay: normalizeRelayEndpoint(value.relay),
    channel_id: normalizeChannelIdentity(value.channel_id),
    publisher_pubkey: normalizeHexIdentity(value.publisher_pubkey, "publisher_pubkey"),
    recorded_at: value.recorded_at,
    reason: value.reason,
  };
}

export function readCompromisedUnverifiablePairs(file) {
  return readCanonicalRegistry(
    file,
    "compromised unverifiable pair",
    normalizeCompromisedUnverifiablePair,
    unverifiableIdentity,
  );
}

export function recordCompromisedUnverifiablePairs(file, values) {
  const incoming = values.map(normalizeCompromisedUnverifiablePair);
  return withRegistryLocks([file], () => {
    const existing = readCompromisedUnverifiablePairs(file);
    const merged = new Map(existing.map((value) => [unverifiableIdentity(value), value]));
    for (const value of incoming) {
      const identity = unverifiableIdentity(value);
      if (!merged.has(identity)) merged.set(identity, value);
    }
    const records = [...merged.values()].sort((left, right) =>
      unverifiableIdentity(left).localeCompare(unverifiableIdentity(right)));
    if (records.length !== existing.length) {
      replaceRegistry(file, records, "compromised unverifiable pair");
    }
    return incoming;
  });
}

export function retirePublisherTargetsAsUnverifiable(targetsFile, outputFile, publisherPubkeys, reason) {
  if (!Array.isArray(publisherPubkeys) || publisherPubkeys.length === 0) {
    throw new Error("at least one publisher_pubkey is required");
  }
  if (typeof reason !== "string" || reason.trim() === "" || reason !== reason.trim()) {
    throw new Error("reason must be a nonempty trimmed string");
  }
  const publishers = new Set(publisherPubkeys.map((value) => normalizeHexIdentity(value, "publisher_pubkey")));
  return withRegistryLocks([targetsFile, outputFile], () => {
    const existing = readPublisherTargets(targetsFile);
    const retiring = existing.filter((target) => publishers.has(target.publisher_pubkey));
    if (retiring.length === 0) return [];
    const recordedAt = new Date().toISOString();
    const incoming = retiring.map((target) => ({ ...target, recorded_at: recordedAt, reason }));
    const recorded = readCompromisedUnverifiablePairs(outputFile);
    const merged = new Map(recorded.map((value) => [unverifiableIdentity(value), value]));
    for (const value of incoming) {
      const identity = unverifiableIdentity(value);
      if (!merged.has(identity)) merged.set(identity, value);
    }
    const records = [...merged.values()].sort((left, right) =>
      unverifiableIdentity(left).localeCompare(unverifiableIdentity(right)));
    if (records.length !== recorded.length) {
      replaceRegistry(outputFile, records, "compromised unverifiable pair");
    }
    const remaining = existing.filter((target) => !publishers.has(target.publisher_pubkey));
    replaceRegistry(targetsFile, remaining, "publisher target");
    return retiring;
  });
}

function usage() {
  process.stderr.write(
    "usage: fm-buzz-targets.mjs <list FILE|list-with-ids FILE|normalize-relay URL|record-unverifiable TARGETS_FILE OUTPUT_FILE PUBKEY REASON|forget-target FILE TARGET_HEX|forget-relay-identity TARGETS_FILE AUTHORITIES_FILE ENDPOINT|retire-unverifiable TARGETS_FILE OUTPUT_FILE REASON PUBKEY...>\n",
  );
}

async function cli() {
  const [operation, value, ...rest] = process.argv.slice(2);
  if (operation === "list" && value && rest.length === 0) {
    for (const target of readPublisherTargets(value)) {
      process.stdout.write(`${target.publisher_pubkey}\t${target.relay}\t${target.channel_id}\n`);
    }
    return;
  }
  if (operation === "list-with-ids" && value && rest.length === 0) {
    for (const target of readPublisherTargets(value)) {
      process.stdout.write(
        `${publisherTargetHex(target)}\t${target.publisher_pubkey}\t${target.relay}\t${target.channel_id}\n`,
      );
    }
    return;
  }
  if (operation === "normalize-relay" && value && rest.length === 0) {
    process.stdout.write(`${normalizeRelayEndpoint(value)}\n`);
    return;
  }
  if (operation === "record-unverifiable" && value && rest.length === 3) {
    const [outputFile, publisherPubkey, reason] = rest;
    const publisher = normalizeHexIdentity(publisherPubkey, "publisher_pubkey");
    const recordedAt = new Date().toISOString();
    const records = readPublisherTargets(value)
      .filter((target) => target.publisher_pubkey === publisher)
      .map((target) => ({ ...target, recorded_at: recordedAt, reason }));
    recordCompromisedUnverifiablePairs(outputFile, records);
    for (const record of records) process.stdout.write(`${record.relay}\t${record.channel_id}\n`);
    return;
  }
  if (operation === "forget-target" && value && rest.length === 1) {
    const target = forgetPublisherTarget(value, rest[0]);
    process.stdout.write(
      `${publisherTargetHex(target)}\t${target.publisher_pubkey}\t${target.relay}\t${target.channel_id}\n`,
    );
    return;
  }
  if (operation === "forget-relay-identity" && value && rest.length === 2) {
    const [authoritiesFile, endpoint] = rest;
    const result = forgetRelayIdentity(value, authoritiesFile, endpoint);
    process.stdout.write(`${result.relay}\t${result.removed.length}\n`);
    return;
  }
  if (operation === "retire-unverifiable" && value && rest.length >= 3) {
    const [outputFile, reason, ...publishers] = rest;
    for (const target of retirePublisherTargetsAsUnverifiable(value, outputFile, publishers, reason)) {
      process.stdout.write(
        `${publisherTargetHex(target)}\t${target.publisher_pubkey}\t${target.relay}\t${target.channel_id}\n`,
      );
    }
    return;
  }
  usage();
  process.exitCode = 2;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  cli().catch((error) => {
    process.stderr.write(`fm-buzz-targets: ${error.message}\n`);
    process.exitCode = 1;
  });
}
