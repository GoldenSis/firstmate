#!/usr/bin/env node
// Durable publisher-target registry shared by Buzz publishing and key rotation.
//
// data/buzz-publisher-targets.jsonl contains one canonical JSON object per used
// relay/channel/publisher tuple. Each object has exactly relay, channel_id, and
// publisher_pubkey string fields. Relays use normalizeRelayEndpoint(), while
// channel identities are lowercase canonical UUIDs and publisher identities are
// lowercase 64-character hex values.
// Callers hold fm_buzz_key_transaction_lock across every read or rewrite, so a
// whole-file exact-destination replacement is atomic, concurrent publishes are
// serialized, duplicate tuples collapse, and an earlier target is never lost.
// Any malformed, non-regular, or symlinked existing registry fails closed.
//
// Usage:
//   node bin/fm-buzz-targets.mjs list FILE
//   node bin/fm-buzz-targets.mjs normalize-relay URL

import {
  lstatSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeRelayEndpoint } from "./fm-buzz-lib.mjs";

const HEX_64 = /^[0-9a-f]{64}$/;
const CHANNEL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

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

function canonicalTargets(targets) {
  const unique = new Map();
  for (const target of targets) {
    const normalized = normalizePublisherTarget(target);
    unique.set(targetIdentity(normalized), normalized);
  }
  return [...unique.values()].sort((left, right) => targetIdentity(left).localeCompare(targetIdentity(right)));
}

export function readPublisherTargets(file) {
  let metadata;
  try {
    metadata = lstatSync(file);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) {
    throw new Error(`publisher target registry ${file} is not a regular file`);
  }
  const raw = readFileSync(file, "utf8");
  const lines = raw.split("\n");
  const targets = [];
  for (const [index, line] of lines.entries()) {
    if (line === "" && index === lines.length - 1) continue;
    if (line.trim() === "") throw new Error(`publisher target registry ${file} has a blank record`);
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      throw new Error(`publisher target registry ${file} has invalid JSON on line ${index + 1}`);
    }
    try {
      const normalized = normalizePublisherTarget(parsed);
      if (
        parsed.relay !== normalized.relay ||
        parsed.channel_id !== normalized.channel_id ||
        parsed.publisher_pubkey !== normalized.publisher_pubkey
      ) {
        throw new Error("record is not canonical");
      }
      targets.push(normalized);
    } catch (error) {
      throw new Error(`publisher target registry ${file} has an invalid record on line ${index + 1}: ${error.message}`);
    }
  }
  const canonical = canonicalTargets(targets);
  if (canonical.length !== targets.length) {
    throw new Error(`publisher target registry ${file} contains duplicate records`);
  }
  return canonical;
}

function replaceRegistry(file, targets) {
  const directory = path.dirname(file);
  const directoryMetadata = lstatSync(directory);
  if (directoryMetadata.isSymbolicLink() || !directoryMetadata.isDirectory()) {
    throw new Error(`publisher target registry directory ${directory} is not a regular directory`);
  }
  try {
    const targetMetadata = lstatSync(file);
    if (targetMetadata.isSymbolicLink() || !targetMetadata.isFile()) {
      throw new Error(`publisher target registry ${file} is not a regular file`);
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary = path.join(
    directory,
    `.${path.basename(file)}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`,
  );
  const content = targets.map((target) => JSON.stringify(target)).join("\n") + "\n";
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
  const existing = readPublisherTargets(file);
  const merged = canonicalTargets([...existing, target]);
  if (merged.length === existing.length && existing.some((candidate) => targetIdentity(candidate) === targetIdentity(target))) {
    return target;
  }
  replaceRegistry(file, merged);
  return target;
}

function usage() {
  process.stderr.write("usage: fm-buzz-targets.mjs <list FILE|normalize-relay URL>\n");
}

async function cli() {
  const [operation, value, ...rest] = process.argv.slice(2);
  if (operation === "list" && value && rest.length === 0) {
    for (const target of readPublisherTargets(value)) {
      process.stdout.write(`${target.publisher_pubkey}\t${target.relay}\t${target.channel_id}\n`);
    }
    return;
  }
  if (operation === "normalize-relay" && value && rest.length === 0) {
    process.stdout.write(`${normalizeRelayEndpoint(value)}\n`);
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
