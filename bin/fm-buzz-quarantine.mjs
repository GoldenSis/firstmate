#!/usr/bin/env node
// Legacy replay-cache quarantine lifecycle for bin/fm-buzz-publish.mjs.
//
// Active entries from the former flat and host-keyed layouts are never delivered
// or deleted because their complete relay endpoint cannot be recovered.
// The publisher supplies its pinned cache-mutation interface, while this module
// owns migration discovery, recovery ordering, failure accounting, and notices.
// Payload and manifest schema details remain owned by the publisher helpers that
// perform each pinned transaction.

import path from "node:path";

export const CACHE_PARTITION = /^[0-9a-f]{64}$/;
export const LEGACY_QUARANTINE = "_legacy-quarantine";

export function runLegacyQuarantineLifecycle(operations) {
  const {
    replayDir,
    log,
    prepareCacheDirectory,
    recoverInvalidRecoveryResidues,
    recoverQuarantineTransactions,
    recoverStagedLegacyEntries,
    recoverCorruptPartitionNodes,
    cacheReaddirSync,
    cacheLstatSync,
    pinCacheDirectory,
    decodeLegacyHost,
    quarantineCorruptPartitionNode,
    quarantineLegacyEntry,
    quarantineManifestCount,
  } = operations;
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
