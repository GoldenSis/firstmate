#!/usr/bin/env bash
# Buzz replay-cache, partition, quarantine, and filesystem-safety behavior tests.
set -u

# shellcheck source=tests/fm-buzz-test-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-buzz-test-lib.sh"

test_publisher_target_is_recorded_only_after_cache() {
  local home replay outside output code
  home=$(make_home target-after-cache)
  run_keypair "$home" >/dev/null 2>&1 || fail "target-after-cache keypair setup failed"
  replay="$home/state/buzz-replay"
  outside="$home/outside-quarantine"
  mkdir -p "$replay" "$outside"
  ln -s "$outside" "$replay/_legacy-quarantine" \
    || fail "could not create the cache-failure fixture"

  output=$(test_projection "cache-must-precede-target" \
    | run_publish "$home" "ws://127.0.0.1:1/cache-failure" 2>&1)
  code=$?
  expect_code 0 "$code" "cache failure through the fire-and-forget wrapper"
  assert_contains "$output" "not a regular directory" \
    "the cache failure fixture did not stop publication"
  assert_absent "$home/data/buzz-publisher-targets.jsonl" \
    "a failed cache write left a phantom publisher target"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the cache failure unexpectedly retained an active projection"
  pass "publisher targets are recorded only after durable caching"
}

test_cache_cap_is_enforced_before_target_registry_failure() {
  local home relay targets output code
  home=$(make_home cache-cap-before-target-failure)
  run_keypair "$home" >/dev/null 2>&1 || fail "cache-cap target-failure keypair setup failed"
  relay="ws://127.0.0.1:1/cache-cap-target-failure"
  test_projection "cached-one" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  test_projection "cached-two" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "2" ] || fail "cache-cap target-failure fixture did not seed two entries"
  targets="$home/data/buzz-publisher-targets.jsonl"
  printf '%s\n' '{"relay":"ws://localhost:3000"}' > "$targets"

  output=$(test_projection "current-before-target-error" \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  code=$?
  expect_code 0 "$code" "target-registry failure through the fire-and-forget wrapper"
  assert_contains "$output" "publisher target registry" \
    "the malformed target registry did not stop target recording"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "a target-registry failure bypassed the replay cache cap"
  pass "cache pruning precedes fallible publisher-target recording"
}

test_rotation_uses_the_authoritative_replay_cache_path() {
  local home relay channel old keyfile private cache_file cache_name output code
  home=$(make_home authoritative-replay-path)
  old=$(run_keypair "$home" 2>/dev/null) || fail "authoritative-replay keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private=$(jq -r '.private_key' "$keyfile")
  relay="ws://127.0.0.1:1/authoritative-replay"
  channel="abababab-cdcd-5efe-8123-456789abcdef"
  cache_file=$(seed_replay_event "$home" "$relay" "$private" 1700000110 "$channel" authoritative-path) \
    || fail "could not seed the authoritative replay path"
  cache_name=$(basename "$cache_file")

  output=$(FM_BUZZ_REPLAY_DIR="$home/state/wrong-replay" run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a misleading replay override"
  assert_contains "$output" "$cache_name" \
    "rotation inspected a split replay tree instead of the authoritative cache"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "a replay-path override bypassed pending-event rotation safety"
  assert_present "$cache_file" "replay-path validation removed the pending event"
  pass "publishing and rotation share one authoritative replay cache path"
}

test_relay_switch_does_not_replay_another_relays_cache() {
  local home relay output readback stored_count
  home=$(make_home relay-switch)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Queue one projection for a relay that is down.
  test_projection "relay-a-only" \
    | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "1" ] \
    || fail "relay A did not retain exactly one cached projection"

  # Switching to another relay must publish only the new projection. Relay A's
  # cached bytes remain queued for A and are invisible to B.
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(test_projection "relay-b-only" \
    | run_publish "$home" "$relay" 2>&1)
  assert_contains "$output" "delivered=1" \
    "relay B did not receive exactly its own newly cached projection"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "switching relays drained or duplicated relay A's cached projection"

  readback=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_STREAM_MESSAGE] }));
      process.stdout.write(String(events.length) + "\n");
      for (const event of events) process.stdout.write(event.content + "\n");
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")
  stored_count=$(printf '%s\n' "$readback" | sed -n '1p')
  [ "$stored_count" = "1" ] \
    || fail "relay B stored $stored_count messages, expected exactly its own one"
  assert_contains "$readback" "relay-b-only" "relay B did not store its own projection"
  assert_not_contains "$readback" "relay-a-only" \
    "relay B received a projection cached for relay A"

  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
  pass "switching relay endpoints produces a cache miss for the prior relay"
}

test_endpoint_only_cache_entries_migrate_to_their_exact_channel() {
  local home old_private keyfile relay port channel_a channel_b endpoint seeded legacy migrated before after output readback
  home=$(make_home endpoint-channel-migration)
  run_keypair "$home" >/dev/null 2>&1 || fail "endpoint migration keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  old_private=$(jq -r '.private_key' "$keyfile")
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  port=${relay##*:}
  stop_stub "$STUB_PID"
  channel_a=$(channel_id_for_label endpoint-migration-a)
  channel_b=$(channel_id_for_label endpoint-migration-b)
  endpoint=$(relay_cache_dir "$home" "$relay") || fail "could not derive endpoint cache directory"
  seeded=$(seed_replay_event "$home" "$relay" "$old_private" 1700000120 "$channel_a" endpoint-migration-a) \
    || fail "could not seed endpoint migration event"
  legacy="$endpoint/$(basename "$seeded")"
  mv "$seeded" "$legacy" || fail "could not create endpoint-only cache fixture"
  rmdir "$(dirname "$seeded")" || fail "could not remove the channel directory fixture"
  before=$(shasum -a 256 "$legacy" | awk '{print $1}')

  read -r STUB_PID relay <<EOF
$(start_stub --port "$port")
EOF
  output=$(test_projection "endpoint-migration-b" \
    | run_publish "$home" "$relay" --channel-label endpoint-migration-b 2>&1)

  migrated="$endpoint/$channel_a/$(basename "$legacy")"
  assert_absent "$legacy" "an endpoint-only entry remained outside a channel partition"
  assert_present "$migrated" "an endpoint-only entry was not migrated to its h-tag channel"
  after=$(shasum -a 256 "$migrated" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "endpoint channel migration changed the cached frame bytes"
  assert_contains "$output" "migrated 1 endpoint-only replay event" \
    "endpoint channel migration was not reported"
  readback=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_STREAM_MESSAGE] }));
      process.stdout.write(events.map((event) => event.content).join("\n"));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")
  stop_stub "$STUB_PID"
  assert_contains "$readback" "endpoint-migration-b" "channel B did not publish its own projection"
  assert_not_contains "$readback" "endpoint-migration-a" "channel B replayed the migrated channel A entry"
  [ -d "$endpoint/$channel_b" ] || fail "channel B did not receive its own cache partition"
  pass "endpoint-only replay entries migrate without cross-channel delivery"
}

test_noncanonical_endpoint_children_are_quarantined_and_accounted() {
  local home relay channel endpoint stray output manifests payloads
  home=$(make_home noncanonical-endpoint-child)
  run_keypair "$home" >/dev/null 2>&1 || fail "noncanonical child keypair setup failed"
  relay="ws://127.0.0.1:1"
  channel=$(default_channel_id "$home")
  seed_replay_event "$home" "$relay" \
    "$(new_private_key)" 1700000001 "$channel" noncanonical-neighbour >/dev/null \
    || fail "could not seed a channel entry"
  endpoint=$(relay_cache_dir "$home" "$relay")

  # A child that is neither a canonical channel directory nor an entry awaiting
  # migration used to be skipped by both walks, so a frame parked under it was
  # invisible to replay, to the cap, and to rotation's outgoing-identity scan.
  stray="$endpoint/not-a-channel"
  mkdir -p "$stray"
  printf '%s' '["EVENT",{}]' > "$stray/1700000002-deadbeef.json"

  output=$(test_projection "noncanonical" \
    | run_publish "$home" "$relay" 2>&1)
  expect_code 0 "$?" "a noncanonical endpoint child through fire-and-forget"
  assert_absent "$stray" "the noncanonical endpoint child was left in place"
  manifests="$home/state/buzz-replay/_legacy-quarantine/manifests"
  payloads="$home/state/buzz-replay/_legacy-quarantine/corrupt"
  [ "$(find "$manifests" -name '*.json' | wc -l | tr -d ' ')" != "0" ] \
    || fail "the noncanonical endpoint child was discarded without a manifest"
  grep -Rql "not-a-channel" "$manifests" >/dev/null \
    || fail "no quarantine manifest records the noncanonical endpoint child"
  [ "$(find "$payloads" -name '1700000002-deadbeef.json' | wc -l | tr -d ' ')" = "1" ] \
    || fail "the noncanonical endpoint child's payload was not preserved"
  pass "noncanonical endpoint children are quarantined rather than silently skipped"
}

test_unexpected_root_signed_frame_remains_identity_evidence() {
  local home relay replay private public channel seeded unexpected output code manifest
  home=$(make_home unexpected-root-signed-frame)
  relay="ws://127.0.0.1:1/unexpected-root"
  replay="$home/state/buzz-replay"
  private=$(new_private_key)
  public=$(public_from_private "$private")
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000130 "$channel" unexpected-root) \
    || fail "could not seed an unexpected-root signed frame"
  unexpected="$replay/signed-frame-without-a-cache-name"
  mv "$seeded" "$unexpected"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with unexpected-root publisher evidence"
  assert_contains "$output" "$public" \
    "an unexpected-root signed frame was omitted from the read-only identity inventory"
  assert_present "$unexpected" "read-only identity inspection mutated the unexpected root frame"

  rm -f "$unexpected"
  run_keypair "$home" >/dev/null 2>&1 || fail "unexpected-root quarantine keypair setup failed"
  seeded=$(seed_replay_event \
    "$home" "$relay" "$private" 1700000131 "$channel" unexpected-root-quarantine) \
    || fail "could not seed the unexpected-root quarantine fixture"
  mv "$seeded" "$unexpected"
  output=$(test_projection "quarantine-unexpected-root" \
    | run_publish "$home" "$relay" 2>&1)
  assert_absent "$unexpected" "an unexpected root cache child was not quarantined"
  manifest=$(grep -Fl "signed-frame-without-a-cache-name" \
    "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "an unexpected root cache child has no quarantine manifest"
  [ "$(jq -r '.publisher_pubkey' "$manifest")" = "$public" ] \
    || fail "unexpected-root quarantine dropped validated publisher evidence"
  assert_contains "$output" "quarantined corrupt cache partition path" \
    "unexpected-root quarantine was not reported"
  pass "unexpected root signed frames remain durable publisher evidence"
}

test_missing_manifest_backed_quarantine_payloads_fail_closed() {
  local home replay quarantine token manifest output code
  home=$(make_home missing-regular-quarantine-payload)
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  token=$(printf '%064d' 71)
  mkdir -p "$quarantine/manifests" "$quarantine/payloads"
  manifest="$quarantine/manifests/$token.json"
  jq -cn --arg token "$token" '{
    original_path:"legacy.json",
    legacy_host:"localhost:3000",
    original_timestamps:{atime_ms:0,mtime_ms:0,ctime_ms:0,birthtime_ms:0},
    quarantine_timestamp:"1970-01-01T00:00:00.000Z",
    payload_reference:("payloads/" + $token + ".json"),
    publisher_pubkey:null,
    source_device:1,
    source_inode:1,
    content_sha256_observed:"0000000000000000000000000000000000000000000000000000000000000000",
    content_size_observed:0,
    quarantine_reason:"missing-payload-fixture"
  }' > "$manifest"
  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with a missing regular quarantine payload"
  assert_contains "$output" "legacy quarantine payload" \
    "a missing regular quarantine payload did not fail closed"
  assert_absent "$home/data/buzz-keypair.public" \
    "missing regular quarantine evidence allowed a replacement identity"

  home=$(make_home missing-corrupt-quarantine-payload)
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  token=$(printf '%064d' 72)
  mkdir -p "$quarantine/manifests" "$quarantine/corrupt/$token"
  manifest="$quarantine/manifests/$token.json"
  jq -cn --arg token "$token" '{
    original_path:"corrupt-node",
    legacy_host:null,
    original_timestamps:{atime_ms:0,mtime_ms:0,ctime_ms:0,birthtime_ms:0},
    quarantine_timestamp:"1970-01-01T00:00:00.000Z",
    payload_reference:("corrupt/" + $token + "/entry"),
    publisher_pubkey:null,
    source_device:1,
    source_inode:1,
    source_mode:33188,
    payload_device:1,
    payload_inode:1,
    payload_mode:33188,
    corrupt_type:"regular-file",
    content_sha256:"0000000000000000000000000000000000000000000000000000000000000000"
  }' > "$manifest"
  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with a missing corrupt quarantine payload"
  assert_contains "$output" "legacy quarantine payload" \
    "a missing corrupt quarantine payload did not fail closed"
  assert_absent "$home/data/buzz-keypair.public" \
    "missing corrupt quarantine evidence allowed a replacement identity"
  pass "missing manifest-backed quarantine payloads fail identity checks closed"
}

test_relay_cache_partition_uses_the_normalized_complete_endpoint() {
  local result
  result=$(node -e '
    import(process.argv[1]).then(({ normalizeRelayEndpoint, relayCacheKey }) => {
      const a = "ws://relay:3000/a";
      const b = "ws://relay:3000/b";
      const rootUpper = "ws://Relay:3000/";
      const rootLower = "ws://relay:3000";
      const facts = {
        distinctPaths: relayCacheKey(a) !== relayCacheKey(b),
        canonicalRoot: normalizeRelayEndpoint(rootUpper) === normalizeRelayEndpoint(rootLower),
        sharedRootPartition: relayCacheKey(rootUpper) === relayCacheKey(rootLower),
        distinctSchemes: relayCacheKey(rootLower) !== relayCacheKey("wss://relay:3000"),
      };
      process.stdout.write(JSON.stringify(facts));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs")
  [ "$result" = '{"distinctPaths":true,"canonicalRoot":true,"sharedRootPartition":true,"distinctSchemes":true}' ] \
    || fail "relay endpoint normalization or cache partitioning drifted: $result"
  pass "relay caches key the normalized complete endpoint"
}

test_legacy_replay_entries_are_quarantined_with_a_manifest() {
  local home relay replay legacy_dir legacy_file quarantine manifest payload output readback second
  home=$(make_home legacy-replay-quarantine)
  run_keypair "$home" >/dev/null 2>&1 || fail "legacy quarantine keypair setup failed"
  replay="$home/state/buzz-replay"
  legacy_dir="$replay/localhost%3A3000"
  legacy_file="$legacy_dir/1700000000-$(printf '%064d' 9).json"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$legacy_dir"
  printf '%s' '["EVENT",{"legacy_marker":"must-not-be-delivered"}]' > "$legacy_file"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(test_projection "fresh-after-legacy" \
    | run_publish "$home" "$relay" 2>&1)

  assert_absent "$legacy_file" "a legacy replay entry remained in its active queue"
  manifest=$(find "$quarantine/manifests" -type f -name '*.json' | head -1)
  [ -n "$manifest" ] || fail "a quarantined legacy entry has no manifest"
  payload="$quarantine/$(jq -r '.payload_reference' "$manifest")"
  assert_present "$payload" "a quarantined legacy entry has no payload"
  [ "$(cat "$payload")" = '["EVENT",{"legacy_marker":"must-not-be-delivered"}]' ] \
    || fail "legacy quarantine changed the signed payload bytes"
  jq -e \
    --arg original "localhost%3A3000/$(basename "$legacy_file")" \
    '.original_path == $original and
     .legacy_host == "localhost:3000" and
     (.original_timestamps.atime_ms | type) == "number" and
     (.original_timestamps.mtime_ms | type) == "number" and
     (.original_timestamps.ctime_ms | type) == "number" and
     (.original_timestamps.birthtime_ms | type) == "number" and
     (.quarantine_timestamp | type) == "string" and
     (.payload_reference | type) == "string"' "$manifest" >/dev/null \
    || fail "legacy quarantine manifest omitted required provenance"
  assert_contains "$output" "legacy replay quarantine: 1 entry(s) at " \
    "publish startup did not report the legacy quarantine"
  assert_contains "$output" "/_legacy-quarantine" \
    "publish startup did not name the legacy quarantine directory"

  readback=$(run_inspect "$home" "$relay" 2>&1)
  assert_contains "$readback" "fresh-after-legacy" "the fresh projection did not land"
  assert_not_contains "$readback" "must-not-be-delivered" \
    "a legacy entry was delivered despite its unknown endpoint"
  second=$(test_projection "quarantine-retry" \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$second" "legacy replay quarantine: 1 entry(s) at " \
    "a later startup stopped reporting existing quarantined entries"
  assert_contains "$second" "/_legacy-quarantine" \
    "a later startup did not name the legacy quarantine directory"
  [ "$(find "$quarantine/manifests" -type f -name '*.json' | wc -l | tr -d ' ')" = "1" ] \
    || fail "legacy quarantine retry duplicated the manifest"
  [ "$(find "$quarantine/payloads" -type f -name '*.json' | wc -l | tr -d ' ')" = "1" ] \
    || fail "legacy quarantine retry duplicated or removed the payload"
  pass "legacy replay entries are quarantined without endpoint inference or delivery"
}

test_legacy_quarantine_claims_the_source_before_reading() {
  local home relay replay legacy_dir legacy_file quarantine writer manifests payloads output
  home=$(make_home legacy-quarantine-source-claim)
  run_keypair "$home" >/dev/null 2>&1 || fail "legacy source-claim keypair setup failed"
  replay="$home/state/buzz-replay"
  legacy_dir="$replay/localhost%3A3000"
  legacy_file="$legacy_dir/1700000000-$(printf '%064d' 8).json"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$legacy_dir"
  printf '%s' 'legacy-old-bytes' > "$legacy_file"
  (
    while [ -e "$legacy_file" ]; do sleep 0.01; done
    printf '%s' 'legacy-new-bytes' > "$legacy_file"
  ) &
  writer=$!
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(test_projection "claim-before-read" \
    | run_publish "$home" "$relay" 2>&1)
  wait "$writer" || fail "legacy in-place writer fixture failed"
  assert_present "$legacy_file" \
    "a newer legacy entry created after the staging rename was deleted"
  [ "$(cat "$legacy_file")" = "legacy-new-bytes" ] \
    || fail "legacy quarantine changed the newer source bytes"
  payloads=$(grep -rl 'legacy-old-bytes' "$quarantine/payloads" 2>/dev/null | wc -l | tr -d ' ')
  [ "$payloads" = "1" ] || fail "the atomically claimed legacy bytes were not quarantined once"

  test_projection "claim-retry" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  stop_stub "$STUB_PID"
  assert_absent "$legacy_file" "the replacement legacy entry was not quarantined on retry"
  manifests=$(find "$quarantine/manifests" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$manifests" = "2" ] \
    || fail "collision-safe legacy retries produced $manifests manifests instead of two"
  payloads=$(find "$quarantine/payloads" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$payloads" = "2" ] \
    || fail "collision-safe legacy retries produced $payloads payloads instead of two"
  assert_contains "$output" "legacy replay quarantine: 1 entry(s)" \
    "the first staged quarantine transaction was not reported"
  pass "legacy quarantine atomically claims sources and preserves later bytes"
}

test_legacy_quarantine_retains_open_writer_appends() {
  local home relay replay legacy_dir legacy_file quarantine payload
  home=$(make_home legacy-quarantine-open-writer)
  run_keypair "$home" >/dev/null 2>&1 || fail "legacy open-writer keypair setup failed"
  replay="$home/state/buzz-replay"
  legacy_dir="$replay/localhost%3A3000"
  legacy_file="$legacy_dir/1700000000-$(printf '%064d' 7).json"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$legacy_dir"
  printf '%s' 'claimed-before-append' > "$legacy_file"
  exec 9>> "$legacy_file"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "open-writer-quarantine" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  printf '%s' '-appended-through-open-fd' >&9
  exec 9>&-
  stop_stub "$STUB_PID"
  payload=$(find "$quarantine/payloads" -type f -name '*.json' | head -1)
  [ -n "$payload" ] || fail "open-writer quarantine did not retain a payload"
  [ "$(cat "$payload")" = 'claimed-before-append-appended-through-open-fd' ] \
    || fail "quarantine discarded bytes appended through an already-open writer"
  pass "legacy quarantine retains the claimed inode for open writers"
}

test_quarantine_retry_reuses_link_stable_transaction_identity() {
  local home replay legacy_dir legacy_file quarantine output manifests payloads staging
  home=$(make_home quarantine-link-stable-retry)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine retry keypair setup failed"
  replay="$home/state/buzz-replay"
  legacy_dir="$replay/localhost%3A3000"
  legacy_file="$legacy_dir/1700000000-$(printf '%064d' 6).json"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$legacy_dir" "$quarantine/manifests" "$quarantine/payloads" \
    "$quarantine/staging" "$quarantine/corrupt" "$quarantine/recovery-corrupt"
  printf '%s' 'link-stable-quarantine-payload' > "$legacy_file"
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const { createHash } = require("node:crypto");
    const replay = process.argv[1];
    const source = process.argv[2];
    const quarantine = process.argv[3];
    const metadata = fs.lstatSync(source);
    const originalPath = path.relative(replay, source);
    const token = createHash("sha256").update(JSON.stringify({
      original_path: originalPath,
      device: metadata.dev,
      inode: metadata.ino,
    })).digest("hex");
    const transaction = path.join(quarantine, "staging", token);
    fs.mkdirSync(transaction);
    fs.writeFileSync(path.join(transaction, "origin.json"), JSON.stringify({
      original_path: originalPath,
      legacy_host: "localhost:3000",
      original_timestamps: {
        atime_ms: metadata.atimeMs,
        mtime_ms: metadata.mtimeMs,
        ctime_ms: metadata.ctimeMs,
        birthtime_ms: metadata.birthtimeMs,
      },
      transaction_token: token,
      payload_reference: path.join("payloads", token + ".json"),
      source_device: metadata.dev,
      source_inode: metadata.ino,
      quarantine_reason: "legacy-cache-migration",
      publisher_pubkey: null,
    }));
    fs.linkSync(source, path.join(transaction, "source"));
  ' "$replay" "$legacy_file" "$quarantine" \
    || fail "could not seed the interrupted hard-link quarantine transaction"

  output=$(test_projection "recover-link-stable-quarantine" \
    | run_publish "$home" "ws://127.0.0.1:1/link-stable-quarantine" 2>&1)
  assert_absent "$legacy_file" "quarantine retry left the already-claimed legacy source active"
  manifests=$(find "$quarantine/manifests" -type f -name '*.json' | wc -l | tr -d ' ')
  payloads=$(find "$quarantine/payloads" -type f -name '*.json' | wc -l | tr -d ' ')
  staging=$(find "$quarantine/staging" -mindepth 1 -print -quit 2>/dev/null)
  [ "$manifests" = "1" ] || fail "hard-link crash recovery duplicated the quarantine manifest"
  [ "$payloads" = "1" ] || fail "hard-link crash recovery duplicated the quarantine payload"
  [ -z "$staging" ] || fail "hard-link crash recovery left a staged transaction behind"
  assert_contains "$output" "legacy replay quarantine: 1 entry(s)" \
    "hard-link crash recovery did not report the single retained entry"
  pass "quarantine retries reuse transaction identity after hard-link ctime changes"
}

test_quarantine_recovers_atomic_manifest_temporaries() {
  local home replay quarantine regular_token corrupt_token recovery_token mismatch_token digest_token
  local token
  home=$(make_home quarantine-temporary-recovery)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine temporary keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$quarantine/staging" \
    "$quarantine/corrupt/fixture" "$quarantine/recovery-corrupt"
  # shellcheck disable=SC2016
  read -r regular_token corrupt_token recovery_token mismatch_token digest_token <<EOF
$(node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const { createHash } = require("node:crypto");
    const [quarantine, manifests] = process.argv.slice(1);
    const timestamps = (metadata) => ({
      atime_ms: metadata.atimeMs,
      mtime_ms: metadata.mtimeMs,
      ctime_ms: metadata.ctimeMs,
      birthtime_ms: metadata.birthtimeMs,
    });
    const tokenFor = (originalPath, metadata, includeMode = false) => {
      const provenance = {
        original_path: originalPath,
        device: metadata.dev,
        inode: metadata.ino,
      };
      if (includeMode) provenance.mode = metadata.mode;
      return createHash("sha256").update(JSON.stringify(provenance)).digest("hex");
    };
    const write = (token, suffix, manifest) => {
      fs.writeFileSync(`${manifests}/${token}.json${suffix}.tmp`, `${JSON.stringify(manifest)}\n`);
    };
    const regularSeed = `${quarantine}/payloads/regular.fixture`;
    fs.writeFileSync(regularSeed, "regular-manifest-payload");
    const regularMetadata = fs.statSync(regularSeed);
    const regular = tokenFor("legacy/regular.json", regularMetadata);
    const regularPayload = `${quarantine}/payloads/${regular}.json`;
    fs.renameSync(regularSeed, regularPayload);
    const regularBytes = fs.readFileSync(regularPayload);
    const regularManifest = {
      original_path: "legacy/regular.json",
      legacy_host: "localhost:3000",
      original_timestamps: timestamps(regularMetadata),
      quarantine_timestamp: new Date(0).toISOString(),
      payload_reference: `payloads/${regular}.json`,
      source_device: regularMetadata.dev,
      source_inode: regularMetadata.ino,
      content_sha256_observed: createHash("sha256").update(regularBytes).digest("hex"),
      content_size_observed: regularBytes.length,
      quarantine_reason: "temporary-recovery-fixture",
      publisher_pubkey: null,
    };
    write(regular, ".4242", regularManifest);
    const corruptSeed = `${quarantine}/corrupt/fixture/entry`;
    fs.writeFileSync(corruptSeed, "corrupt-manifest-payload");
    const corruptMetadata = fs.statSync(corruptSeed);
    const corrupt = tokenFor("legacy/corrupt-node", corruptMetadata, true);
    fs.renameSync(`${quarantine}/corrupt/fixture`, `${quarantine}/corrupt/${corrupt}`);
    const corruptPayload = `${quarantine}/corrupt/${corrupt}/entry`;
    const corruptBytes = fs.readFileSync(corruptPayload);
    write(corrupt, "", {
      original_path: "legacy/corrupt-node",
      legacy_host: null,
      original_timestamps: timestamps(corruptMetadata),
      quarantine_timestamp: new Date(0).toISOString(),
      payload_reference: `corrupt/${corrupt}/entry`,
      source_device: corruptMetadata.dev,
      source_inode: corruptMetadata.ino,
      source_mode: corruptMetadata.mode,
      payload_device: corruptMetadata.dev,
      payload_inode: corruptMetadata.ino,
      payload_mode: corruptMetadata.mode,
      corrupt_type: "regular-file",
      content_sha256: createHash("sha256").update(corruptBytes).digest("hex"),
      publisher_pubkey: null,
    });
    const recoverySeed = `${quarantine}/recovery-corrupt/recovery.fixture`;
    fs.writeFileSync(recoverySeed, "recovery-manifest-payload");
    const recoveryMetadata = fs.statSync(recoverySeed);
    const recovery = tokenFor("manifests/interrupted.json.tmp", recoveryMetadata);
    const recoveryPayload = `${quarantine}/recovery-corrupt/${recovery}.invalid`;
    fs.renameSync(recoverySeed, recoveryPayload);
    write(recovery, ".4243", {
      original_path: "manifests/interrupted.json.tmp",
      original_timestamps: timestamps(recoveryMetadata),
      quarantine_timestamp: new Date(0).toISOString(),
      payload_reference: `recovery-corrupt/${recovery}.invalid`,
      source_device: recoveryMetadata.dev,
      source_inode: recoveryMetadata.ino,
      corrupt_type: "invalid-quarantine-recovery-residue",
      recovery_error: "temporary-recovery-fixture",
    });
    const mismatchSeed = `${quarantine}/payloads/mismatch.fixture`;
    fs.writeFileSync(mismatchSeed, "provenance-mismatch-payload");
    const mismatchMetadata = fs.statSync(mismatchSeed);
    const expectedMismatch = tokenFor("legacy/mismatch.json", mismatchMetadata);
    const mismatch = `${expectedMismatch[0] === "0" ? "1" : "0"}${expectedMismatch.slice(1)}`;
    fs.renameSync(mismatchSeed, `${quarantine}/payloads/${mismatch}.json`);
    const mismatchBytes = fs.readFileSync(`${quarantine}/payloads/${mismatch}.json`);
    write(mismatch, "", {
      original_path: "legacy/mismatch.json",
      legacy_host: null,
      original_timestamps: timestamps(mismatchMetadata),
      quarantine_timestamp: new Date(0).toISOString(),
      payload_reference: `payloads/${mismatch}.json`,
      source_device: mismatchMetadata.dev,
      source_inode: mismatchMetadata.ino,
      content_sha256_observed: createHash("sha256").update(mismatchBytes).digest("hex"),
      content_size_observed: mismatchBytes.length,
      quarantine_reason: "temporary-recovery-fixture",
      publisher_pubkey: null,
    });
    const digestSeed = `${quarantine}/payloads/digest.fixture`;
    fs.writeFileSync(digestSeed, "digest-mismatch-payload");
    const digestMetadata = fs.statSync(digestSeed);
    const digestMismatch = tokenFor("legacy/digest.json", digestMetadata);
    const digestPayload = `${quarantine}/payloads/${digestMismatch}.json`;
    fs.renameSync(digestSeed, digestPayload);
    write(digestMismatch, "", {
      original_path: "legacy/digest.json",
      legacy_host: null,
      original_timestamps: timestamps(digestMetadata),
      quarantine_timestamp: new Date(0).toISOString(),
      payload_reference: `payloads/${digestMismatch}.json`,
      source_device: digestMetadata.dev,
      source_inode: digestMetadata.ino,
      content_sha256_observed: "0".repeat(64),
      content_size_observed: fs.statSync(digestPayload).size,
      quarantine_reason: "temporary-recovery-fixture",
      publisher_pubkey: null,
    });
    process.stdout.write(`${regular} ${corrupt} ${recovery} ${mismatch} ${digestMismatch}\n`);
  ' "$quarantine" "$quarantine/manifests")
EOF

  test_projection "recover-manifest-temp" \
    | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  for token in "$regular_token" "$corrupt_token" "$recovery_token"; do
    assert_present "$quarantine/manifests/$token.json" \
      "quarantine did not recover manifest temporary variant $token"
  done
  assert_absent "$quarantine/manifests/$mismatch_token.json" \
    "quarantine finalized a manifest whose token did not bind its payload"
  assert_absent "$quarantine/manifests/$digest_token.json" \
    "quarantine finalized a manifest whose observed digest did not match"
  grep -l 'does not match its observed content' "$quarantine/manifests"/*.json >/dev/null 2>&1 \
    || fail "quarantine did not retain the observed-content failure reason"
  [ -z "$(find "$quarantine/manifests" -type f -name '*.tmp' -print -quit)" ] \
    || fail "quarantine left a manifest temporary active"
  pass "quarantine recovery validates and completes every manifest variant"
}

test_quarantine_recovery_rejects_noncanonical_tokens() {
  local home replay quarantine staging corrupt token source output
  home=$(make_home quarantine-token-validation)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine-token keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  token=$(printf '%064d' 4)
  staging="$quarantine/staging/$token"
  corrupt="$quarantine/corrupt/$token"
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$staging" "$corrupt"
  source="$staging/source"
  printf '%s' 'staged-payload' > "$source"
  node -e '
    const fs = require("node:fs");
    const metadata = fs.lstatSync(process.argv[1]);
    fs.writeFileSync(process.argv[2], JSON.stringify({
      original_path: "localhost%3A3000/legacy.json",
      legacy_host: "localhost:3000",
      original_timestamps: { atime_ms: 1, mtime_ms: 2, ctime_ms: 3, birthtime_ms: 4 },
      transaction_token: "../../../../escaped-staged",
      payload_reference: "payloads/" + process.argv[3] + ".json",
      source_device: metadata.dev,
      source_inode: metadata.ino,
    }));
  ' "$source" "$staging/origin.json" "$token"
  printf '%s' 'corrupt-entry' > "$corrupt/entry"
  jq -n '{
    token:"../../../../escaped-corrupt",
    manifest:{
      original_path:"corrupt-entry",
      legacy_host:null,
      original_timestamps:{atime_ms:1,mtime_ms:2,ctime_ms:3,birthtime_ms:4},
      quarantine_timestamp:"2026-08-11T00:00:00.000Z",
      payload_reference:"corrupt/entry",
      corrupt_type:"regular-file"
    }
  }' > "$corrupt/origin.json"

  output=$(test_projection "token-validation" \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  assert_absent "$home/escaped-staged.json" \
    "a persisted staging token escaped the quarantine directory"
  assert_absent "$home/escaped-corrupt.json" \
    "a persisted corrupt-record token escaped the quarantine directory"
  assert_contains "$output" "quarantine transaction token" \
    "invalid recovery tokens were not diagnosed"
  pass "quarantine recovery rejects noncanonical transaction tokens"
}

test_invalid_quarantine_temporaries_are_accounted_for() {
  local home replay quarantine token temporary output second residue manifest
  home=$(make_home invalid-quarantine-temporary)
  run_keypair "$home" >/dev/null 2>&1 || fail "invalid-quarantine-temporary keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  token=$(printf '%064d' 5)
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$quarantine/staging" \
    "$quarantine/corrupt" "$quarantine/recovery-corrupt"
  temporary="$quarantine/manifests/$token.json.tmp"
  printf '%s' '{"truncated":' > "$temporary"

  output=$(test_projection "invalid-quarantine-temp" \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  assert_absent "$temporary" "an invalid quarantine temporary remained active"
  residue=$(find "$quarantine/recovery-corrupt" -type f -print -quit 2>/dev/null)
  [ -n "$residue" ] || fail "an invalid quarantine temporary was not retained as corrupt evidence"
  manifest=$(grep -l 'invalid-quarantine-recovery-residue' \
    "$quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "invalid quarantine residue was omitted from manifest accounting"
  assert_contains "$output" "quarantined invalid recovery residue" \
    "invalid quarantine residue was not diagnosed"
  rm "$manifest"
  second=$(test_projection "recover-invalid-residue" \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  manifest=$(grep -l 'invalid-quarantine-recovery-residue' \
    "$quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -z "$manifest" ] || fail "a residue without source provenance was assigned a replacement manifest"
  assert_present "$residue" "residue recovery discarded the retained invalid bytes"
  assert_contains "$second" "recovery-residue provenance manifest is missing" \
    "residue recovery did not fail closed without its source provenance"
  pass "invalid quarantine temporaries move into accounted corrupt state"
}

test_invalid_quarantine_residue_retries_use_link_stable_identity() {
  local home replay quarantine token temporary preload sentinel first second residues manifests
  home=$(make_home invalid-quarantine-residue-retry)
  run_keypair "$home" >/dev/null 2>&1 || fail "residue retry keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  token=$(printf '%064d' 15)
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$quarantine/staging" \
    "$quarantine/corrupt" "$quarantine/recovery-corrupt"
  temporary="$quarantine/manifests/$token.json.tmp"
  printf '%s' '{"truncated":' > "$temporary"
  preload="$home/fail-residue-hard-link.mjs"
  sentinel="$home/residue-link-interrupted"
  cat > "$preload" <<'EOF'
import { createRequire, syncBuiltinESMExports } from "node:module";
const fs = createRequire(import.meta.url)("node:fs");
const childProcess = createRequire(import.meta.url)("node:child_process");
const originalSpawnSync = childProcess.spawnSync;
childProcess.spawnSync = function guardedSpawnSync(command, args, options) {
  const result = originalSpawnSync.call(childProcess, command, args, options);
  if (
    command === "python3" &&
    String(args?.[1]).includes("os.link") &&
    String(args?.[3]).endsWith(".invalid") &&
    !fs.existsSync(process.env.FM_TEST_RESIDUE_SENTINEL)
  ) {
    fs.writeFileSync(process.env.FM_TEST_RESIDUE_SENTINEL, "interrupted\n");
    return { ...result, status: 1, stderr: "simulated residue hard-link interruption\n" };
  }
  return result;
};
syncBuiltinESMExports();
EOF
  first=$(test_projection "residue-retry-first" \
    | NODE_OPTIONS="--import=$preload" FM_TEST_RESIDUE_SENTINEL="$sentinel" \
      run_publish "$home" "ws://127.0.0.1:1/residue-retry" 2>&1)
  assert_present "$sentinel" "the residue retry fixture did not interrupt the hard-link claim"
  assert_present "$temporary" "the interrupted residue claim unexpectedly removed its source"
  assert_contains "$first" "simulated residue hard-link interruption" \
    "the interrupted residue claim was not accounted for"

  second=$(test_projection "residue-retry-second" \
    | run_publish "$home" "ws://127.0.0.1:1/residue-retry" 2>&1)
  residues=$(find "$quarantine/recovery-corrupt" -type f -name '*.invalid' | wc -l | tr -d ' ')
  manifests=$(grep -l 'invalid-quarantine-recovery-residue' \
    "$quarantine/manifests"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$residues" = "1" ] || fail "residue retry duplicated the quarantined payload"
  [ "$manifests" = "1" ] || fail "residue retry duplicated the quarantine manifest"
  assert_absent "$temporary" "residue retry left the original temporary active"
  assert_contains "$second" "quarantined invalid recovery residue" \
    "residue retry did not finish the interrupted transaction"
  pass "invalid quarantine residue retries reuse link-stable provenance"
}

test_quarantine_manifest_inspection_failures_are_accounted_for() {
  local home replay quarantine manifest tools real_python relay output
  home=$(make_home quarantine-manifest-inspection)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine-manifest keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$quarantine/staging" \
    "$quarantine/corrupt" "$quarantine/recovery-corrupt"
  manifest="$quarantine/manifests/$(printf '%064d' 8).json"
  printf '%s\n' '{}' > "$manifest"
  manifest="$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")"
  tools="$home/tools"
  mkdir -p "$tools"
  real_python=$(command -v python3)
  cat > "$tools/python3" <<'EOF'
#!/usr/bin/env bash
case ${3:-} in
  *'"operation":"lstat"'*'"name":"'"$FM_TEST_QUARANTINE_MANIFEST_NAME"'"'*)
    parent=$("$FM_TEST_REAL_PYTHON" -c 'import os; os.fchdir(3); print(os.getcwd())')
    if [ "$parent/$FM_TEST_QUARANTINE_MANIFEST_NAME" = "$FM_TEST_QUARANTINE_MANIFEST" ]; then
      printf '%s\n' '{"ok":false,"code":"EACCES","message":"simulated manifest inspection failure"}' >&2
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_PYTHON" "$@"
EOF
  chmod +x "$tools/python3"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(test_projection "manifest-accounting" \
    | PATH="$tools:$PATH" FM_TEST_REAL_PYTHON="$real_python" \
      FM_TEST_QUARANTINE_MANIFEST="$manifest" \
      FM_TEST_QUARANTINE_MANIFEST_NAME="$(basename "$manifest")" \
      run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"
  assert_contains "$output" "could not inspect legacy quarantine manifest" \
    "a quarantine-manifest inspection failure was not diagnosed"
  assert_contains "$output" "delivered=1 retained=1 discarded=0 cleanup_failed=1" \
    "a quarantine-manifest inspection failure was omitted from outcome accounting"
  assert_contains "$output" "publish did not complete; Firstmate is unaffected" \
    "a quarantine-manifest inspection failure bypassed the safe wrapper outcome"
  pass "quarantine manifest inspection failures remain visible in accounting"
}

# --- (d) reconnect replays the identical event id --------------------------

test_replay_cache_is_capped_at_100() {
  local home relay cache_dir private channel oldest newest count
  home=$(make_home cap)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  relay="ws://127.0.0.1:1"
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$cache_dir"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  channel=$(default_channel_id "$home")

  # Seed 120 valid cache entries with increasing timestamps, then publish
  # once against a dead relay: the prune must bring the cache to the cap,
  # keeping the newest and dropping the oldest.
  # shellcheck disable=SC2016
  printf '%s' "$private" | node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    let privateKey = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { privateKey += chunk; });
    process.stdin.on("end", async () => {
      const { KIND_STREAM_MESSAGE, signEvent } = await import(process.argv[1]);
      for (let i = 1; i <= 120; i += 1) {
        const event = signEvent({
          created_at: 1700000000 + i,
          kind: KIND_STREAM_MESSAGE,
          tags: [["h", process.argv[3]]],
          content: JSON.stringify({ schema: "fm-bearings.v1", note: `cap-${i}` }),
        }, privateKey.trim());
        fs.writeFileSync(
          path.join(process.argv[2], `${event.created_at}-${event.id}.json`),
          JSON.stringify(["EVENT", event]),
        );
      }
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$cache_dir" "$channel" \
    || fail "could not seed valid cap fixtures"
  oldest=$(find "$cache_dir" -type f -name '1700000001-*.json' -print -quit)
  newest=$(find "$cache_dir" -type f -name '1700000120-*.json' -print -quit)
  [ "$(replay_count "$home")" = "120" ] || fail "cache seeding failed"

  test_projection \
    | run_publish "$home" "$relay" >/dev/null 2>&1

  count=$(replay_count "$home")
  [ "$count" = "100" ] || fail "the replay cache is not capped at 100 (found $count)"

  # The newest must survive and the oldest must be gone.
  assert_present "$newest" \
    "the cap dropped a newer event instead of an older one"
  assert_absent "$oldest" \
    "the cap did not drop the oldest event"
  pass "the replay cache is capped at 100, dropping oldest first"
}

test_cache_limit_must_be_a_positive_integer() {
  local home invalid output code
  home=$(make_home invalid-cache-limit)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  for invalid in 0 -5 abc; do
    output=$(test_projection "invalid-limit" \
      | FM_BUZZ_MAX_CACHE=$invalid run_publish "$home" "ws://127.0.0.1:1" 2>&1)
    code=$?
    expect_code 0 "$code" "invalid cache limit $invalid through the fire-and-forget wrapper"
    assert_contains "$output" "invalid FM_BUZZ_MAX_CACHE value '$invalid'" \
      "invalid cache limit $invalid was not diagnosed"
    assert_not_contains "$output" "signed event" \
      "invalid cache limit $invalid reached signing"
    [ "$(replay_count "$home")" = "0" ] \
      || fail "invalid cache limit $invalid created a replay entry"
  done
  pass "cache limits reject zero, negative, and nonnumeric values before signing"
}

test_cache_limit_one_preserves_the_pending_event() {
  local home relay output clock cache_dir private channel old
  home=$(make_home cache-limit-one)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  clock="$TMP_ROOT/fixed-buzz-clock.mjs"
  printf '%s\n' 'Date.now = () => 1700000000000;' > "$clock"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$cache_dir"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  channel=$(default_channel_id "$home")
  old=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" limit-one-old) \
    || fail "could not seed the same-second cache entry"

  output=$(test_projection "limit-one" \
    | NODE_OPTIONS="--import=$clock" FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "delivered=1 retained=0 discarded=0 cleanup_failed=0" \
    "a same-second cache tie removed the just-signed event before delivery accounting"
  assert_absent "$old" "same-second pruning kept an older entry instead of the current event"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the cache-limit-one event remained after acknowledgement"
  pass "a cache limit of one protects the current event across same-second ties"
}

test_concurrent_publishers_serialize_the_cache_lifecycle() {
  local home relay first_output second_output first_pid second_pid lock waited
  home=$(make_home concurrent-cache)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  first_output="$home/first-publish.out"
  second_output="$home/second-publish.out"
  lock="$home/state/.buzz-replay-publish.lock"
  read -r STUB_PID relay <<EOF
$(start_stub --silent-ok)
EOF

  (test_projection "concurrent-first" \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" --timeout 1500) \
    > "$first_output" 2>&1 &
  first_pid=$!
  waited=0
  while [ ! -L "$lock" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -L "$lock" ] || fail "the first publisher never acquired cache ownership"

  (test_projection "concurrent-second" \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" --timeout 1500) \
    > "$second_output" 2>&1 &
  second_pid=$!
  sleep 0.1
  kill -0 "$second_pid" 2>/dev/null || fail "the second publisher exited before cache ownership cleared"
  assert_not_contains "$(cat "$second_output")" "signed event" \
    "the second publisher signed and pruned while another projection was in flight"

  wait "$first_pid" || fail "the first concurrent publisher failed its fire-and-forget contract"
  wait "$second_pid" || fail "the second concurrent publisher failed its fire-and-forget contract"
  stop_stub "$STUB_PID"
  assert_contains "$(cat "$first_output")" "signed event" "the first concurrent projection was not processed"
  assert_contains "$(cat "$second_output")" "signed event" "the second concurrent projection was not processed"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "concurrent cache pruning lost every in-flight projection"
  pass "concurrent publishers serialize signing, pruning, and delivery accounting"
}

test_replay_cache_rejects_symlink_boundaries() {
  local ancestor_home root_home relay_home entry_home outside replay relay digest link target output manifest payload code
  ancestor_home=$(make_home cache-ancestor-symlink)
  run_keypair "$ancestor_home" >/dev/null 2>&1 || fail "ancestor-symlink keypair setup failed"
  outside="$ancestor_home/outside-state"
  rmdir "$ancestor_home/state"
  mkdir "$outside"
  ln -s "$outside" "$ancestor_home/state"
  output=$(node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      migrateReplayCache(process.argv[2]);
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$ancestor_home/state/buzz-replay" 2>&1)
  code=$?
  expect_code 1 "$code" "direct replay migration through a symlinked ancestor"
  assert_contains "$output" "replay cache ancestor" \
    "the replay engine accepted a symlinked ancestor"
  output=$(test_projection "ancestor-symlink" \
    | run_publish "$ancestor_home" "ws://127.0.0.1:1" 2>&1)
  assert_contains "$output" "replay cache ancestor" \
    "a replay-root ancestor symlink was not rejected"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "a replay-root ancestor symlink redirected mutation outside the cache"

  root_home=$(make_home cache-root-symlink)
  run_keypair "$root_home" >/dev/null 2>&1 || fail "root-symlink keypair setup failed"
  outside="$root_home/outside-cache"
  mkdir "$outside"
  rm -rf "$root_home/state/buzz-replay"
  ln -s "$outside" "$root_home/state/buzz-replay"
  output=$(test_projection "root-symlink" \
    | run_publish "$root_home" "ws://127.0.0.1:1" 2>&1)
  assert_contains "$output" "replay cache path" "a replay-root symlink was not rejected"
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "a replay-root symlink redirected cache mutation outside the cache"

  relay_home=$(make_home cache-relay-symlink)
  run_keypair "$relay_home" >/dev/null 2>&1 || fail "relay-symlink keypair setup failed"
  replay="$relay_home/state/buzz-replay"
  relay="ws://127.0.0.1:1/a"
  digest=$(node -e '
    import(process.argv[1]).then(({ relayCacheKey }) => process.stdout.write(relayCacheKey(process.argv[2])));
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay")
  outside="$relay_home/outside-relay-cache"
  mkdir -p "$replay" "$outside"
  ln -s "$outside" "$replay/$digest"
  output=$(test_projection "relay-symlink" \
    | run_publish "$relay_home" "$relay" 2>&1)
  assert_contains "$output" "quarantined corrupt cache partition path" \
    "a relay-directory symlink was not quarantined as corrupt state"
  [ -d "$replay/$digest" ] && [ ! -L "$replay/$digest" ] \
    || fail "a quarantined relay-directory symlink still blocked partition creation"
  manifest=$(grep -l '"corrupt_type": "symbolic-link"' \
    "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "a quarantined relay-directory symlink has no manifest"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  [ -L "$payload" ] || fail "the quarantined relay-directory symlink has no payload reference"
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "a relay-directory symlink redirected cache mutation outside the cache"

  entry_home=$(make_home cache-entry-symlink)
  run_keypair "$entry_home" >/dev/null 2>&1 || fail "entry-symlink keypair setup failed"
  replay="$entry_home/state/buzz-replay"
  relay="ws://127.0.0.1:1"
  digest=$(node -e '
    import(process.argv[1]).then(({ relayCacheKey }) => process.stdout.write(relayCacheKey(process.argv[2])));
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay")
  mkdir -p "$replay/$digest"
  target="$entry_home/outside-entry.json"
  printf '%s' '{"outside":true}' > "$target"
  link="$replay/$digest/1700000000-$(printf '%064d' 7).json"
  ln -s "$target" "$link"
  output=$(test_projection "entry-symlink" \
    | run_publish "$entry_home" "$relay" 2>&1)
  assert_contains "$output" "cache entry is a symbolic link" \
    "a cache-entry symlink was treated as a replayable event"
  assert_absent "$link" "a rejected cache-entry symlink remained queued"
  [ "$(cat "$target")" = '{"outside":true}' ] \
    || fail "cache-entry cleanup mutated the symlink target"
  pass "replay cache mutations reject root, relay, and entry symlinks"
}

test_replay_cache_pins_the_root_before_mutation() {
  local home replay held outside preload output
  home=$(make_home replay-root-pin)
  run_keypair "$home" >/dev/null 2>&1 || fail "replay-root pin keypair setup failed"
  replay="$home/state/buzz-replay"
  held="$home/state/buzz-replay-original"
  outside="$home/outside-replay-root"
  preload="$home/replay-root-swap.mjs"
  mkdir -p "$replay" "$outside"
  cat > "$preload" <<'EOF'
import path from "node:path";
import { createRequire, syncBuiltinESMExports } from "node:module";

const fs = createRequire(import.meta.url)("node:fs");

const originalRealpathSync = fs.realpathSync;
let swapped = false;
fs.realpathSync = function guardedRealpathSync(value, ...args) {
  const candidate = path.resolve(String(value));
  const replayRoot = path.resolve(process.env.FM_TEST_REPLAY_ROOT);
  if (!swapped && candidate === replayRoot) {
    swapped = true;
    fs.renameSync(replayRoot, process.env.FM_TEST_REPLAY_HELD);
    fs.symlinkSync(process.env.FM_TEST_REPLAY_OUTSIDE, replayRoot, "dir");
  }
  return originalRealpathSync.call(fs, value, ...args);
};
syncBuiltinESMExports();
EOF
  output=$(test_projection "root-pin" \
    | NODE_OPTIONS="--import=$preload" \
      FM_TEST_REPLAY_ROOT="$replay" \
      FM_TEST_REPLAY_HELD="$held" \
      FM_TEST_REPLAY_OUTSIDE="$outside" \
      run_publish "$home" ws://127.0.0.1:9 2>&1)
  assert_contains "$output" "replay cache root identity changed" \
    "a replay-root symlink swap was not diagnosed"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "a replay-root symlink swap redirected a cache mutation outside the pinned root"
  pass "replay cache root identity is pinned before mutation"
}

test_replay_cache_pins_descendant_directories() {
  local home relay replay digest channel partition held outside tools real_python escape_log swap_log output
  home=$(make_home replay-descendant-pin)
  run_keypair "$home" >/dev/null 2>&1 || fail "replay-descendant keypair setup failed"
  relay="ws://127.0.0.1:1/descendant"
  replay="$home/state/buzz-replay"
  digest=$(node -e '
    import(process.argv[1]).then(({ relayCacheKey }) => process.stdout.write(relayCacheKey(process.argv[2])));
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay")
  channel=$(default_channel_id "$home")
  partition="$replay/$digest/$channel"
  held="$home/held-replay-partition"
  outside="$home/outside-replay-partition"
  tools="$home/tools"
  real_python=$(command -v python3)
  escape_log="$home/replay-descendant-escape.log"
  swap_log="$home/replay-descendant-swap.log"
  mkdir -p "$partition" "$outside" "$tools"
  cat > "$tools/python3" <<'EOF'
#!/usr/bin/env bash
request=${3:-}
case $request in
  *'"operation":"write"'*'"name":"'*'.json.tmp"'*)
    parent=$("$FM_TEST_REAL_PYTHON" -c 'import os; os.fchdir(3); print(os.getcwd())')
    if [ "$parent" = "$FM_TEST_CACHE_PARTITION" ] && [ ! -e "$FM_TEST_CACHE_SWAP_LOG" ]; then
      "$FM_TEST_REAL_PYTHON" -c '
import os
os.rename(os.environ["FM_TEST_CACHE_PARTITION"], os.environ["FM_TEST_CACHE_HELD"])
os.symlink(os.environ["FM_TEST_CACHE_OUTSIDE"], os.environ["FM_TEST_CACHE_PARTITION"])
'
      printf 'swapped %s\n' "$FM_TEST_CACHE_PARTITION" > "$FM_TEST_CACHE_SWAP_LOG"
    fi
    "$FM_TEST_REAL_PYTHON" "$@"
    code=$?
    name=${request#*'"name":"'}
    name=${name%%'"'*}
    if [ -e "$FM_TEST_CACHE_OUTSIDE/$name" ]; then
      printf '%s\n' "$FM_TEST_CACHE_OUTSIDE/$name" > "$FM_TEST_CACHE_ESCAPE_LOG"
    fi
    exit "$code"
    ;;
esac
exec "$FM_TEST_REAL_PYTHON" "$@"
EOF
  chmod +x "$tools/python3"
  output=$(test_projection "descendant-pin" \
    | PATH="$tools:$PATH" FM_TEST_REAL_PYTHON="$real_python" \
      FM_TEST_CACHE_HELD="$held" \
      FM_TEST_CACHE_OUTSIDE="$outside" \
      FM_TEST_CACHE_PARTITION="$partition" \
      FM_TEST_CACHE_ESCAPE_LOG="$escape_log" \
      FM_TEST_CACHE_SWAP_LOG="$swap_log" \
      run_publish "$home" "$relay" 2>&1)
  grep -F 'swapped ' "$swap_log" >/dev/null \
    || fail "the descendant-swap fixture did not exercise a cache mutation: $(cat "$swap_log" 2>/dev/null)"
  assert_absent "$escape_log" \
    "a descendant-directory swap redirected a cache mutation outside the replay root"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] \
    || fail "a descendant-directory swap left replay data outside the pinned cache"
  assert_contains "$output" "cache directory identity changed" \
    "a descendant-directory swap was not diagnosed"
  if grep -Eq 'process\.chdir' "$ROOT/bin/fm-buzz-publish.mjs"; then
    fail "cache mutations still change process cwd instead of using pinned descriptors"
  fi
  pass "replay cache mutations stay relative to pinned directory descriptors"
}

test_cross_directory_quarantine_claims_cannot_follow_swapped_sources() {
  local home relay replay legacy held outside preload output
  home=$(make_home quarantine-cross-directory-swap)
  run_keypair "$home" >/dev/null 2>&1 || fail "cross-directory quarantine keypair setup failed"
  replay="$home/state/buzz-replay"
  legacy="$replay/localhost%3A3000"
  held="$home/held-legacy-cache"
  outside="$home/outside-legacy-cache"
  preload="$home/quarantine-source-swap.mjs"
  mkdir -p "$legacy" "$outside"
  printf '%s' '["EVENT",{"legacy":"original"}]' > "$legacy/1700000000-$(printf '%064d' 6).json"
  printf '%s' 'outside-must-remain' > "$outside/1700000000-$(printf '%064d' 6).json"
  cat > "$preload" <<'EOF'
import { createRequire, syncBuiltinESMExports } from "node:module";

const fs = createRequire(import.meta.url)("node:fs");
const childProcess = createRequire(import.meta.url)("node:child_process");
const originalSpawnSync = childProcess.spawnSync;
let swapped = false;
childProcess.spawnSync = function guardedSpawnSync(command, args, options) {
  if (
    !swapped &&
    command === "python3" &&
    String(args?.[1]).includes("os.link(sys.argv[1], sys.argv[2]")
  ) {
    swapped = true;
    const sourceParent = process.env.FM_TEST_CACHE_SOURCE;
    fs.renameSync(sourceParent, process.env.FM_TEST_CACHE_HELD);
    fs.symlinkSync(process.env.FM_TEST_CACHE_OUTSIDE, sourceParent, "dir");
  }
  return originalSpawnSync.call(childProcess, command, args, options);
};
syncBuiltinESMExports();
EOF
  output=$(test_projection "cross-directory-swap" \
    | NODE_OPTIONS="--import=$preload" \
      FM_TEST_CACHE_HELD="$held" \
      FM_TEST_CACHE_OUTSIDE="$outside" \
      FM_TEST_CACHE_SOURCE="$legacy" \
      run_publish "$home" ws://127.0.0.1:1 2>&1)
  assert_contains "$output" "cache directory identity changed" \
    "a swapped cross-directory source was not rejected"
  assert_present "$outside/1700000000-$(printf '%064d' 6).json" \
    "quarantine moved a swapped external source into the replay cache"
  [ "$(cat "$outside/1700000000-$(printf '%064d' 6).json")" = "outside-must-remain" ] \
    || fail "quarantine mutated a swapped external source"
  assert_present "$held/1700000000-$(printf '%064d' 6).json" \
    "quarantine lost the originally claimed legacy inode"
  pass "cross-directory quarantine claims reject swapped source paths"
}

test_replay_root_creation_rejects_an_ancestor_swap_before_pinning() {
  local home replay state held outside preload swap_log output code
  home=$(make_home replay-root-ancestor-swap)
  state="$home/state"
  replay="$state/buzz-replay"
  held="$home/held-state"
  outside="$home/outside-state"
  preload="$home/replay-root-ancestor-swap.mjs"
  swap_log="$home/replay-root-ancestor-swap.log"
  mkdir -p "$outside/buzz-replay"
  cat > "$preload" <<'EOF'
import { createRequire, syncBuiltinESMExports } from "node:module";

const fs = createRequire(import.meta.url)("node:fs");
const childProcess = createRequire(import.meta.url)("node:child_process");
const originalSpawnSync = childProcess.spawnSync;
let swapped = false;
childProcess.spawnSync = function guardedSpawnSync(command, args, options) {
  const result = originalSpawnSync.call(childProcess, command, args, options);
  if (!swapped && command === "python3" && String(args?.[1]).includes("replay cache ancestor")) {
    swapped = true;
    fs.renameSync(process.env.FM_TEST_CACHE_STATE, process.env.FM_TEST_CACHE_HELD);
    fs.symlinkSync(process.env.FM_TEST_CACHE_OUTSIDE, process.env.FM_TEST_CACHE_STATE, "dir");
    fs.writeFileSync(process.env.FM_TEST_CACHE_SWAP_LOG, "swapped\n");
  }
  return result;
};
syncBuiltinESMExports();
EOF
  output=$(NODE_OPTIONS="--import=$preload" \
    FM_TEST_CACHE_STATE="$state" \
    FM_TEST_CACHE_HELD="$held" \
    FM_TEST_CACHE_OUTSIDE="$outside" \
    FM_TEST_CACHE_SWAP_LOG="$swap_log" \
    node -e '
      import(process.argv[1]).then(({ migrateReplayCache }) => migrateReplayCache(process.argv[2]));
    ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" 2>&1)
  code=$?
  expect_code 1 "$code" "a replay-root ancestor swap during safe creation"
  assert_present "$swap_log" "the replay-root ancestor swap fixture did not run"
  assert_contains "$output" "replay cache root identity changed" \
    "an ancestor swap was not rejected before the replay root was pinned"
  [ -z "$(find "$outside/buzz-replay" -mindepth 1 -print -quit)" ] \
    || fail "an ancestor swap redirected replay mutation outside the requested boundary"
  assert_present "$held/buzz-replay" "the safely created replay root was not retained"
  pass "replay-root creation stays bound to pinned ancestor handles"
}

test_quarantine_header_defines_each_manifest_variant() {
  assert_grep 'Every manifests/<token>.json variant requires' "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine header does not define common manifest fields"
  assert_grep 'Regular-entry manifests additionally require' "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine header does not define regular-entry fields"
  assert_grep 'Corrupt-node manifests additionally require' "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine header does not define corrupt-node fields"
  assert_grep 'Recovery-residue manifests additionally require' "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine header does not define recovery-residue fields"
  pass "the quarantine producer documents each manifest variant"
}

test_cross_directory_quarantine_directory_moves_pin_both_parents() {
  local home replay endpoint source held outside tools real_python output swap_log
  home=$(make_home quarantine-directory-destination-swap)
  run_keypair "$home" >/dev/null 2>&1 || fail "directory-destination quarantine keypair setup failed"
  replay="$home/state/buzz-replay"
  endpoint="$replay/$(printf '%064d' 7)"
  source="$endpoint/not-a-channel"
  held="$home/held-quarantine-destination"
  outside="$home/outside-quarantine-destination"
  tools="$home/tools"
  real_python=$(command -v python3)
  swap_log="$home/quarantine-directory-destination-swap.log"
  mkdir -p "$source" "$outside" "$tools"
  printf '%s' 'original-directory' > "$source/original.txt"
  cat > "$tools/python3" <<'EOF'
#!/usr/bin/env bash
case ${3:-} in
  *'"operation":"mkdir"'*'"name":"entry"'*)
    parent=$("$FM_TEST_REAL_PYTHON" -c 'import os; os.fchdir(3); print(os.getcwd())')
    case $parent in
      *'/_legacy-quarantine/corrupt/'*)
        if [ ! -e "$FM_TEST_CACHE_SWAP_LOG" ]; then
          FM_TEST_CACHE_DESTINATION="$parent" "$FM_TEST_REAL_PYTHON" -c '
import os
os.rename(os.environ["FM_TEST_CACHE_DESTINATION"], os.environ["FM_TEST_CACHE_HELD"])
os.symlink(os.environ["FM_TEST_CACHE_OUTSIDE"], os.environ["FM_TEST_CACHE_DESTINATION"])
'
          printf '%s\n' "$parent" > "$FM_TEST_CACHE_SWAP_LOG"
        fi
        ;;
    esac
    ;;
esac
exec "$FM_TEST_REAL_PYTHON" "$@"
EOF
  chmod +x "$tools/python3"
  output=$(test_projection "directory-source-swap" \
    | PATH="$tools:$PATH" FM_TEST_REAL_PYTHON="$real_python" \
      FM_TEST_CACHE_HELD="$held" \
      FM_TEST_CACHE_OUTSIDE="$outside" \
      FM_TEST_CACHE_SWAP_LOG="$swap_log" \
      run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  assert_present "$swap_log" "the destination-swap fixture did not exercise a directory move"
  assert_contains "$output" "cache directory identity changed" \
    "a swapped directory destination parent was not diagnosed"
  assert_absent "$outside/entry/original.txt" \
    "a directory quarantine move followed the swapped external destination"
  assert_present "$source/original.txt" \
    "a rejected directory quarantine move removed the original source"
  pass "cross-directory directory moves keep both parents pinned"
}

test_partition_shaped_special_nodes_are_quarantined_and_unblocked() {
  local home relay replay digest fifo output manifest payload
  home=$(make_home corrupt-partition-node)
  run_keypair "$home" >/dev/null 2>&1 || fail "corrupt-partition keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  replay="$home/state/buzz-replay"
  digest=$(node -e '
    import(process.argv[1]).then(({ relayCacheKey }) => process.stdout.write(relayCacheKey(process.argv[2])));
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay")
  mkdir -p "$replay"
  fifo="$replay/$digest"
  mkfifo "$fifo" || fail "could not create a partition-shaped FIFO"

  output=$(test_projection "after-corrupt-partition" \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"
  assert_contains "$output" "quarantined corrupt cache partition path" \
    "a partition-shaped FIFO was not accounted for as corrupt state"
  assert_contains "$output" "$digest (fifo)" \
    "the corrupt-partition diagnosis omitted the FIFO partition identity"
  [ -d "$replay/$digest" ] && [ ! -L "$replay/$digest" ] \
    || fail "a partition-shaped FIFO still blocked the active relay partition"
  manifest=$(grep -l '"corrupt_type": "fifo"' \
    "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "a quarantined partition-shaped FIFO has no manifest"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  [ -p "$payload" ] || fail "the corrupt-partition manifest does not reference the quarantined FIFO"
  assert_contains "$output" "delivered=1" \
    "a partition-shaped FIFO prevented delivery after quarantine"
  pass "partition-shaped special nodes are quarantined without blocking delivery"
}

test_corrupt_quarantine_payloads_are_provenance_and_content_bound() {
  local home private relay channel seeded replay corrupt_path manifest payload retained digest output code
  home=$(make_home corrupt-quarantine-provenance)
  run_keypair "$home" >/dev/null 2>&1 || fail "corrupt quarantine provenance setup failed"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  relay="ws://127.0.0.1:1/corrupt-quarantine-provenance"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000204 "$channel" corrupt-provenance) \
    || fail "could not seed corrupt quarantine provenance evidence"
  replay="$home/state/buzz-replay"
  corrupt_path="$replay/$(printf '%064d' 9)"
  mv "$seeded" "$corrupt_path"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not quarantine the corrupt provenance fixture"
  manifest=$(grep -l '"corrupt_type": "regular-file"' \
    "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "corrupt provenance fixture has no regular-file manifest"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  retained="$payload.retained"
  cp "$payload" "$retained"
  digest=$(node -e '
    const fs = require("node:fs");
    const { createHash } = require("node:crypto");
    process.stdout.write(createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
  ' "$payload")
  [ "$(jq -r '.content_sha256' "$manifest")" = "$digest" ] \
    || fail "regular corrupt quarantine did not retain its payload digest"

  printf '%s' 'tampered-corrupt-quarantine-payload' > "$payload"
  # shellcheck disable=SC2016
  output=$(node -e '
    import(process.argv[1]).then(({ inspectActiveReplayPublisherCache }) => {
      inspectActiveReplayPublisherCache(process.argv[2]);
    }).catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" 2>&1)
  code=$?
  expect_code 1 "$code" "corrupt quarantine payload changed in place"
  assert_contains "$output" "does not match its content hash" \
    "corrupt quarantine accepted changed bytes from the recorded inode"

  cp "$retained" "$payload"
  mv "$payload" "$payload.replaced"
  cp "$retained" "$payload"
  # shellcheck disable=SC2016
  output=$(node -e '
    import(process.argv[1]).then(({ inspectActiveReplayPublisherCache }) => {
      inspectActiveReplayPublisherCache(process.argv[2]);
    }).catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" 2>&1)
  code=$?
  expect_code 1 "$code" "corrupt quarantine payload replaced by another regular file"
  assert_contains "$output" "does not match its source provenance" \
    "corrupt quarantine accepted an unrelated regular-file payload"
  pass "corrupt quarantine payloads remain bound to source provenance and content"
}

test_corrupt_quarantine_recovers_from_retained_record_interruption() {
  local home private relay channel seeded replay corrupt_path preload sentinel first transaction token origin manifest
  home=$(make_home corrupt-quarantine-retained-interruption)
  run_keypair "$home" >/dev/null 2>&1 || fail "corrupt retained-interruption setup failed"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  relay="ws://127.0.0.1:1/corrupt-retained-interruption"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000206 "$channel" retained-interruption) \
    || fail "could not seed the retained-interruption fixture"
  replay="$home/state/buzz-replay"
  corrupt_path="$replay/$(printf '%064d' 10)"
  mv "$seeded" "$corrupt_path"
  preload="$home/fail-corrupt-retained-record.mjs"
  sentinel="$home/corrupt-retained-record-interrupted"
  cat > "$preload" <<'EOF'
import { createRequire, syncBuiltinESMExports } from "node:module";
const fs = createRequire(import.meta.url)("node:fs");
const childProcess = createRequire(import.meta.url)("node:child_process");
const originalSpawnSync = childProcess.spawnSync;
let originWrites = 0;
childProcess.spawnSync = function guardedSpawnSync(command, args, options) {
  const result = originalSpawnSync.call(childProcess, command, args, options);
  let request = null;
  try {
    request = JSON.parse(String(args?.[2]));
  } catch {}
  if (command === "python3" && request?.operation === "write" && request.name === "origin.json.tmp") {
    originWrites += 1;
    if (originWrites === 2 && !fs.existsSync(process.env.FM_TEST_CORRUPT_RECORD_SENTINEL)) {
      fs.writeFileSync(process.env.FM_TEST_CORRUPT_RECORD_SENTINEL, "interrupted\n");
      return {
        ...result,
        status: 1,
        stdout: "",
        stderr: '{"code":"EIO","message":"simulated retained-record interruption"}\n',
      };
    }
  }
  return result;
};
syncBuiltinESMExports();
EOF
  first=$(test_projection "interrupt-retained-record" \
    | NODE_OPTIONS="--import=$preload" FM_TEST_CORRUPT_RECORD_SENTINEL="$sentinel" \
      run_publish "$home" "$relay" 2>&1)
  assert_present "$sentinel" "the retained-record fixture did not interrupt the second provenance write"
  assert_contains "$first" "simulated retained-record interruption" \
    "the retained-record interruption was not diagnosed"
  transaction=$(find "$replay/_legacy-quarantine/corrupt" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [ -n "$transaction" ] || fail "the interrupted corrupt quarantine has no transaction"
  token=$(basename "$transaction")
  origin="$transaction/origin.json"
  jq -e '.phase == "prepared" and .manifest.payload_device == null and .manifest.payload_inode == null' \
    "$origin" >/dev/null || fail "the interrupted corrupt quarantine did not retain prepared provenance"
  assert_absent "$corrupt_path" "the retained-record interruption left the original corrupt path active"
  assert_present "$transaction/entry" "the retained-record interruption lost the quarantined payload"
  assert_absent "$replay/_legacy-quarantine/manifests/$token.json" \
    "the interrupted corrupt transaction was finalized without retained provenance"

  test_projection "recover-retained-record" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  manifest="$replay/_legacy-quarantine/manifests/$token.json"
  assert_present "$manifest" "the prepared corrupt transaction did not recover on retry"
  assert_absent "$origin" "recovered corrupt quarantine left its prepared record active"
  jq -e '.payload_device != null and .payload_inode != null and .payload_mode != null' \
    "$manifest" >/dev/null || fail "recovered corrupt quarantine lacks retained payload provenance"
  pass "corrupt quarantine recovers after retention precedes its durable payload record"
}

test_replay_cache_never_reads_non_regular_entries() {
  local home relay cache_dir fifo output_file publisher waited
  home=$(make_home cache-special-file)
  run_keypair "$home" >/dev/null 2>&1 || fail "special-file keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$cache_dir"
  fifo="$cache_dir/1700000000-$(printf '%064d' 8).json"
  mkfifo "$fifo" || fail "could not create cache FIFO fixture"
  output_file="$home/cache-special-file.out"

  (test_projection "regular-after-fifo" \
    | run_publish "$home" "$relay") > "$output_file" 2>&1 &
  publisher=$!
  waited=0
  while kill -0 "$publisher" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if kill -0 "$publisher" 2>/dev/null; then
    kill -KILL "$publisher" 2>/dev/null
    wait "$publisher" 2>/dev/null
    stop_stub "$STUB_PID"
    fail "a cache FIFO blocked publishing past the relay deadline"
  fi
  wait "$publisher" || fail "a rejected cache FIFO broke fire-and-forget"
  stop_stub "$STUB_PID"

  assert_contains "$(cat "$output_file")" "cache entry is not a regular file" \
    "a cache FIFO was not rejected before reading"
  assert_absent "$fifo" "a safely removable cache FIFO remained active"
  assert_contains "$(cat "$output_file")" "delivered=1" \
    "a cache FIFO prevented the regular projection from delivery"
  pass "replay reads accept only regular cache files"
}

test_relay_timeout_must_fit_the_node_timer_range() {
  local home invalid output code
  home=$(make_home invalid-relay-timeout)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  for invalid in 0 -1 1.5 2147483648; do
    output=$(test_projection "invalid-relay-timeout" \
      | run_publish "$home" "ws://127.0.0.1:1" --timeout "$invalid" 2>&1)
    code=$?
    expect_code 0 "$code" "invalid relay timeout $invalid through the fire-and-forget wrapper"
    assert_contains "$output" "invalid relay timeout" "relay timeout $invalid was not rejected"
    assert_not_contains "$output" "signed event" "relay timeout $invalid reached signing"
    [ "$(replay_count "$home")" = "0" ] || fail "relay timeout $invalid created a cache entry"
  done
  pass "relay timeouts fit the supported Node timer range before signing"
}

test_malformed_cache_names_are_discarded_or_accounted_for() {
  local home relay replay removable retained private channel signed malformed_signed
  local wrong_channel wrong_seeded wrong_signed quarantine_manifest output
  home=$(make_home malformed-cache-names)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  replay=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$replay"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  channel=$(default_channel_id "$home")
  signed=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" malformed-signed) \
    || fail "could not seed the malformed-name signed cache entry"
  malformed_signed="$replay/signed-but-malformed.json"
  mv "$signed" "$malformed_signed"
  wrong_channel=$(channel_id_for_label malformed-wrong-channel)
  wrong_seeded=$(seed_replay_event \
    "$home" "$relay" "$private" 1700000001 "$wrong_channel" malformed-wrong-channel) \
    || fail "could not seed the wrong-channel signed cache entry"
  wrong_signed="$replay/signed-wrong-channel"
  mv "$wrong_seeded" "$wrong_signed"
  removable="$replay/not-an-event.json"
  retained="$replay/still-not-an-event.json"
  printf '%s' '{"malformed":true}' > "$removable"
  mkdir "$retained"

  output=$(test_projection "malformed-cache-name" \
    | FM_BUZZ_MAX_CACHE=3 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "dropping invalid cache entry not-an-event.json" \
    "a malformed cache filename was silently ignored"
  assert_contains "$output" "could not drop invalid cache entry still-not-an-event.json" \
    "a failed malformed-entry cleanup was silently ignored"
  assert_contains "$output" "delivered=2 retained=1 discarded=1 cleanup_failed=1" \
    "malformed cache filenames were not truthfully accounted for"
  assert_absent "$malformed_signed" "a signed malformed-name cache entry was not recovered"
  assert_absent "$wrong_signed" "a wrong-channel signed cache entry remained active"
  quarantine_manifest=$(grep -l 'noncanonical-cache-entry-channel-mismatch' \
    "$home/state/buzz-replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$quarantine_manifest" ] \
    || fail "a wrong-channel signed cache entry was discarded without quarantine"
  assert_absent "$removable" "a removable malformed cache entry survived cleanup"
  assert_present "$retained" "the failed-cleanup fixture disappeared unexpectedly"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "malformed cache entries escaped the configured cap"
  pass "malformed cache filenames are discarded or retained with truthful accounting"
}

test_unexpected_root_symlinks_are_quarantined_and_accounted_for() {
  local home relay replay loop output
  home=$(make_home cache-stat-failure)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  replay="$home/state/buzz-replay"
  mkdir -p "$replay"
  loop="$replay/uninspectable-relay"
  ln -s "$(basename "$loop")" "$loop" || fail "could not create the stat-failure fixture"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF

  output=$(test_projection "stat-failure" \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "quarantined corrupt cache partition path" \
    "an unexpected root symlink was not quarantined"
  assert_contains "$output" "uninspectable-relay" \
    "the quarantined root symlink did not identify the affected path"
  assert_contains "$output" "delivered=1 retained=0 discarded=0 cleanup_failed=0" \
    "a quarantined root symlink was reported as unresolved cleanup"
  assert_not_contains "$output" "publish did not complete; Firstmate is unaffected" \
    "a settled root symlink quarantine failed the publication"
  pass "unexpected root symlinks are quarantined with truthful accounting"
}

test_an_interrupted_cache_write_is_recovered_or_discarded_safely() {
  local home relay cache_dir private channel complete target payload stale fresh count
  home=$(make_home orphan-tmp)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  relay="ws://127.0.0.1:1"
  channel=$(default_channel_id "$home")
  cache_dir=$(channel_cache_dir "$home" "$relay" "$channel") \
    || fail "could not derive cache partition"
  mkdir -p "$cache_dir"

  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  target=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" interrupted-complete) \
    || fail "could not seed a complete interrupted cache write"
  payload=$(cat "$target")
  complete="$target.tmp"
  mv "$target" "$complete"
  stale="$cache_dir/1700000001-$(printf '%064d' 1).json.tmp"
  fresh="$cache_dir/1700000002-$(printf '%064d' 2).json.tmp"
  printf '["EVENT",{"id":"%064d","created_at":1700000001}]' 1 > "$stale"
  printf '["EVENT",{"id":"%064d","created_at":1700000002}]' 2 > "$fresh"
  touch -t 202001010000 "$complete" "$stale" || fail "could not age the interrupted writes"

  test_projection "orphan" \
    | run_publish "$home" "$relay" >/dev/null 2>&1

  assert_absent "$complete" "a complete interrupted cache write was left stranded"
  assert_present "$target" "a complete interrupted cache write was not recovered"
  [ "$(cat "$target")" = "$payload" ] \
    || fail "recovering a complete interrupted cache write changed its signed bytes"
  assert_absent "$stale" "a provably invalid interrupted cache write was retained"
  assert_present "$fresh" "the sweep deleted a concurrent run's in-flight write"

  count=$(replay_count "$home")
  [ "$count" = "2" ] \
    || fail "interrupted-write recovery produced the wrong replay count (found $count)"
  pass "interrupted cache writes recover complete frames and discard only invalid bytes"
}

test_unreadable_cache_entry_is_retained_as_retryable() {
  local home relay cache_dir unreadable output
  home=$(make_home unreadable-cache)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "prime-cache" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  [ -d "$cache_dir" ] || fail "relay-specific cache directory was not created"
  unreadable="$cache_dir/1700000000-$(printf '%064d' 7).json"
  mkdir "$unreadable"

  output=$(test_projection "read-error" \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "cache entry is not a regular file" \
    "a non-regular cache entry reached the replay reader"
  assert_contains "$output" "retained=1" \
    "unreadable cache entry was omitted from retained outcome accounting"
  assert_present "$unreadable" "unreadable cache entry was discarded instead of retained"
  pass "non-ENOENT cache read failures remain retryable and accounted for"
}

test_parseable_cache_corruption_is_discarded_without_replay() {
  local home relay port cached cache_dir wrong_frame empty_frame notice_frame output
  home=$(make_home parseable-cache-corruption)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  port=${relay##*:}
  stop_stub "$STUB_PID"
  test_projection "valid-frame" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  cached=$(find "$home/state/buzz-replay" -type f -name '*.json' | head -1)
  [ -n "$cached" ] || fail "valid cache fixture was not created"
  cache_dir=$(dirname "$cached")
  wrong_frame="$cache_dir/1700000001-$(printf '%064d' 1).json"
  empty_frame="$cache_dir/1700000002-$(printf '%064d' 2).json"
  notice_frame="$cache_dir/1700000003-$(printf '%064d' 3).json"
  mv "$cached" "$wrong_frame"
  printf '{}' > "$empty_frame"
  printf '["NOTICE","not an event"]' > "$notice_frame"

  read -r STUB_PID relay <<EOF
$(start_stub --port "$port")
EOF
  output=$(test_projection "fresh-event" \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "dropping invalid cache entry" \
    "parseable corrupt cache entries were not diagnosed"
  assert_contains "$output" "delivered=2 retained=0 discarded=2 cleanup_failed=0" \
    "parseable cache entries were not truthfully recovered or discarded"
  assert_absent "$wrong_frame" "a cache frame whose filename disagreed with its event was left noncanonical"
  assert_absent "$empty_frame" "an object-only cache entry was retained"
  assert_absent "$notice_frame" "a non-EVENT cache frame was retained"
  [ "$(replay_count "$home")" = "0" ] || fail "corrupt cache entries remained after cleanup"
  pass "cached replay validates complete EVENT frames and their filenames"
}

test_cache_prune_failures_are_reported_and_accounted_for() {
  local home relay replay first second output count
  home=$(make_home cache-prune-failure)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  replay=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$replay"
  first="$replay/1700000001-$(printf '%064d' 1).json"
  second="$replay/1700000002-$(printf '%064d' 2).json"
  mkdir "$first" "$second"
  output=$(test_projection "prune-failure" \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "could not drop invalid cache entry" \
    "a non-ENOENT cache cleanup failure was silently ignored"
  assert_contains "$output" "cleanup_failed=2" \
    "prune failures were omitted from outcome accounting"
  assert_contains "$output" "publish did not complete; Firstmate is unaffected" \
    "cache cleanup failure did not reach the fire-and-forget conversion"
  count=$(replay_count "$home")
  [ "$count" = "2" ] || fail "the prune failure fixture changed unexpectedly (found $count entries)"
  pass "cache prune failures remain visible in cleanup outcome accounting"
}

# --- the contract means TERMINATING, not just exiting 0 --------------------

read -r ROTATION_GUARD_PID ROTATION_GUARD_RELAY <<EOF
$(start_stub)
EOF

test_publisher_target_is_recorded_only_after_cache
test_cache_cap_is_enforced_before_target_registry_failure
test_rotation_uses_the_authoritative_replay_cache_path
test_relay_switch_does_not_replay_another_relays_cache
test_endpoint_only_cache_entries_migrate_to_their_exact_channel
test_noncanonical_endpoint_children_are_quarantined_and_accounted
test_unexpected_root_signed_frame_remains_identity_evidence
test_missing_manifest_backed_quarantine_payloads_fail_closed
test_relay_cache_partition_uses_the_normalized_complete_endpoint
test_legacy_replay_entries_are_quarantined_with_a_manifest
test_legacy_quarantine_claims_the_source_before_reading
test_legacy_quarantine_retains_open_writer_appends
test_quarantine_retry_reuses_link_stable_transaction_identity
test_quarantine_recovers_atomic_manifest_temporaries
test_quarantine_recovery_rejects_noncanonical_tokens
test_invalid_quarantine_temporaries_are_accounted_for
test_invalid_quarantine_residue_retries_use_link_stable_identity
test_quarantine_manifest_inspection_failures_are_accounted_for
test_replay_cache_is_capped_at_100
test_cache_limit_must_be_a_positive_integer
test_cache_limit_one_preserves_the_pending_event
test_concurrent_publishers_serialize_the_cache_lifecycle
test_replay_cache_rejects_symlink_boundaries
test_replay_cache_pins_the_root_before_mutation
test_replay_root_creation_rejects_an_ancestor_swap_before_pinning
test_replay_cache_pins_descendant_directories
test_cross_directory_quarantine_claims_cannot_follow_swapped_sources
test_cross_directory_quarantine_directory_moves_pin_both_parents
test_quarantine_header_defines_each_manifest_variant
test_partition_shaped_special_nodes_are_quarantined_and_unblocked
test_corrupt_quarantine_payloads_are_provenance_and_content_bound
test_corrupt_quarantine_recovers_from_retained_record_interruption
test_replay_cache_never_reads_non_regular_entries
test_relay_timeout_must_fit_the_node_timer_range
test_malformed_cache_names_are_discarded_or_accounted_for
test_unexpected_root_symlinks_are_quarantined_and_accounted_for
test_an_interrupted_cache_write_is_recovered_or_discarded_safely
test_unreadable_cache_entry_is_retained_as_retryable
test_parseable_cache_corruption_is_discarded_without_replay
test_cache_prune_failures_are_reported_and_accounted_for
