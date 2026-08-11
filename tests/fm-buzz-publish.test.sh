#!/usr/bin/env bash
# Buzz publishing, relay delivery, input, and fire-and-forget behavior tests.
set -u

# shellcheck source=tests/fm-buzz-test-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-buzz-test-lib.sh"

test_publish_with_relay_down_exits_zero_and_enqueues() {
  local home output code
  home=$(make_home relay-down)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Port 1 is reserved and nothing listens there, so this is a hard connection
  # refusal rather than a timeout.
  output=$(test_projection "" '[{"surface":"prs","reveal":"--include-prs"}]' \
    | jq -c '.in_flight = [{id:"task-1",kind:"ship",state:"running",doing:"testing"}]' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?

  expect_code 0 "$code" "publish with the relay down must still exit 0"
  assert_contains "$output" "Firstmate is unaffected" \
    "publish did not log the fire-and-forget outcome"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "the signed event was not enqueued in the replay cache"
  pass "publish with the relay down exits 0 and enqueues the signed event"
}

test_missing_python3_is_a_loud_prerequisite_failure() {
  local home tools tool output code
  home=$(make_home missing-python3)
  tools="$home/prerequisite-tools"
  mkdir -p "$tools"
  for tool in bash dirname jq; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  output=$(PATH="$tools" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$PUBLISH" --relay ws://127.0.0.1:1 </dev/null 2>&1)
  code=$?
  expect_code 1 "$code" "publish without the required python3 runtime"
  assert_contains "$output" \
    "python3 is required for safe replay-cache operations; see docs/buzz-loopback-adapter.md#prerequisites" \
    "missing python3 was silently converted into an optional publish failure"
  pass "missing python3 fails loudly before publication"
}

test_missing_global_websocket_is_rejected_before_publication() {
  local home tools tool real_node output code
  home=$(make_home missing-websocket)
  tools="$home/prerequisite-tools"
  mkdir -p "$tools"
  real_node=$(command -v node)
  for tool in bash dirname jq python3; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  cat > "$tools/node" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-e" ] && [[ ${2:-} == *'globalThis.WebSocket'* ]]; then
  exit 1
fi
exec "$FM_TEST_REAL_NODE" "$@"
EOF
  chmod +x "$tools/node"
  output=$(PATH="$tools" FM_TEST_REAL_NODE="$real_node" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$PUBLISH" --relay ws://127.0.0.1:1 </dev/null 2>&1)
  code=$?
  expect_code 0 "$code" "publish without the global WebSocket API"
  assert_contains "$output" "Node.js does not provide the global WebSocket API" \
    "missing WebSocket support reached publication"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "missing WebSocket support still cached an event"
  pass "missing global WebSocket support is rejected before publication"
}

test_same_second_identical_publishes_have_distinct_signed_identities() {
  local home clock cache files ids nonces
  home=$(make_home same-second-identical)
  run_keypair "$home" >/dev/null 2>&1 || fail "same-second keypair setup failed"
  clock="$home/fixed-clock.cjs"
  cat > "$clock" <<'EOF'
Date.now = () => 1700000000000;
EOF

  test_projection "same-second" \
    | NODE_OPTIONS="--require=$clock" run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  test_projection "same-second" \
    | NODE_OPTIONS="--require=$clock" run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  cache=$(channel_cache_dir "$home" "ws://127.0.0.1:1" "$(default_channel_id "$home")")
  files=$(find "$cache" -name '*.json' -type f | sort)
  [ "$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] \
    || fail "identical same-second publishes collapsed into one cache entry"
  ids=$(printf '%s\n' "$files" | xargs -n1 jq -r '.[1].id' | sort -u)
  [ "$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] \
    || fail "identical same-second publishes reused an event id"
  nonces=$(printf '%s\n' "$files" | xargs -n1 jq -r '.[1].tags[] | select(.[0] == "nonce") | .[1]' | sort -u)
  [ "$(printf '%s\n' "$nonces" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] \
    || fail "identical same-second publishes did not carry distinct nonce tags"
  pass "same-second identical publishes retain distinct signed identities"
}

test_replayed_events_are_tracked_before_delivery() {
  local home other relay channel other_private other_public old_file preload sentinel output targets readback
  home=$(make_home replay-target-tracking)
  other=$(make_home replay-target-tracking-other)
  run_keypair "$home" >/dev/null 2>&1 || fail "replay target-tracking keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "replay target-tracking alternate key setup failed"
  other_private=$(jq -r '.private_key' "$(key_file "$other" "$other/xdg")")
  channel=$(default_channel_id "$home")
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  old_file=$(seed_replay_event "$home" "$relay" "$other_private" 1700000130 "$channel" replay-untracked) \
    || fail "could not seed untracked replay event"
  preload="$home/fail-second-target-replace.cjs"
  sentinel="$home/target-replace-completed"
  cat > "$preload" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");
const { syncBuiltinESMExports } = require("node:module");
const originalRenameSync = fs.renameSync;
fs.renameSync = function guardedRenameSync(source, destination, ...args) {
  if (path.resolve(String(destination)) === path.resolve(process.env.FM_TEST_TARGETS_FILE)) {
    if (fs.existsSync(process.env.FM_TEST_TARGETS_SENTINEL)) {
      const error = new Error("simulated replay target tracking failure");
      error.code = "EACCES";
      throw error;
    }
    fs.writeFileSync(process.env.FM_TEST_TARGETS_SENTINEL, "ready\n");
  }
  return originalRenameSync.call(fs, source, destination, ...args);
};
syncBuiltinESMExports();
EOF
  output=$(test_projection "replay-current" \
    | NODE_OPTIONS="--require=$preload" FM_TEST_TARGETS_FILE="$home/data/buzz-publisher-targets.jsonl" \
      FM_TEST_TARGETS_SENTINEL="$sentinel" \
      run_publish "$home" "$relay" 2>&1)
  assert_contains "$output" "could not record publisher target for cached event" \
    "an untracked replay event reached delivery after target persistence failed"
  assert_present "$old_file" "target tracking failure evicted the untracked replay event"
  targets=$(cat "$home/data/buzz-publisher-targets.jsonl")
  assert_not_contains "$targets" "$other_public" \
    "the failure fixture unexpectedly persisted the replayed publisher target"
  readback=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_STREAM_MESSAGE] }));
      process.stdout.write(events.map((event) => event.content).join("\n"));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")
  stop_stub "$STUB_PID"
  assert_contains "$readback" "replay-current" "the tracked current event did not publish"
  assert_not_contains "$readback" "replay-untracked" "an untracked replay event was sent to the relay"
  pass "every replayed event persists its exact target before delivery"
}

test_malformed_projection_is_rejected_before_signing() {
  local home output code
  home=$(make_home malformed-projection)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  output=$(printf '%s' '{"schema":"fm-bearings.v1","omitted":[]' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 1 "$code" "malformed projection contract"
  assert_contains "$output" "not one valid JSON value" \
    "malformed projection did not take the explicit rejection path"
  assert_not_contains "$output" "signed event" "malformed projection was signed"
  [ "$(replay_count "$home")" = "0" ] || fail "malformed projection entered the replay cache"
  pass "malformed projections are rejected before signing"
}

test_missing_projection_schema_is_rejected_before_signing() {
  local home output code
  home=$(make_home missing-projection-schema)
  run_keypair "$home" >/dev/null 2>&1 || fail "missing-schema keypair setup failed"
  output=$(test_projection | jq -c 'del(.schema)' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 1 "$code" "projection without schema"
  assert_contains "$output" "projection field schema" \
    "missing schema did not identify the rejected field"
  assert_not_contains "$output" "signed event" "schema-less projection was signed"
  [ "$(replay_count "$home")" = "0" ] || fail "schema-less projection entered the replay cache"
  pass "missing projection schema is rejected before signing"
}

test_malformed_projection_omitted_is_rejected_before_signing() {
  local home output code
  home=$(make_home malformed-projection-omitted)
  run_keypair "$home" >/dev/null 2>&1 || fail "malformed-omitted keypair setup failed"
  output=$(test_projection "" '[{"surface":"prs"}]' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 1 "$code" "projection with malformed omitted"
  assert_contains "$output" "projection field omitted" \
    "malformed omitted did not identify the rejected field"
  assert_not_contains "$output" "signed event" "projection with malformed omitted was signed"
  [ "$(replay_count "$home")" = "0" ] || fail "malformed omitted entered the replay cache"
  pass "malformed projection omitted is rejected before signing"
}

test_duplicate_projection_fields_are_rejected_before_signing() {
  local home field projection output code
  home=$(make_home duplicate-projection-fields)
  run_keypair "$home" >/dev/null 2>&1 || fail "duplicate-field keypair setup failed"
  while IFS='|' read -r field projection; do
    output=$(printf '%s' "$projection" | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
    code=$?
    expect_code 1 "$code" "projection with duplicate $field"
    assert_contains "$output" "duplicate field \"$field\"" \
      "duplicate $field was not identified"
    assert_not_contains "$output" "signed event" "projection with duplicate $field was signed"
    [ "$(replay_count "$home")" = "0" ] \
      || fail "projection with duplicate $field entered the replay cache"
  done <<'EOF'
schema|{"schema":"untrusted","schema":"fm-bearings.v1","home":"test/home","generated":"2026-08-10T00:00:00Z","prs":"not_requested","in_flight":[],"omitted":[]}
state|{"schema":"fm-bearings.v1","home":"test/home","generated":"2026-08-10T00:00:00Z","prs":"not_requested","in_flight":[{"id":"task-1","kind":"ship","state":null,"state":"running","doing":"testing"}],"omitted":[]}
EOF
  pass "duplicate projection fields are rejected recursively before signing"
}

test_oversized_projection_is_rejected_before_signing() {
  local home output code
  home=$(make_home oversized-projection)
  run_keypair "$home" >/dev/null 2>&1 || fail "oversized-projection keypair setup failed"
  output=$(test_projection "oversized-projection" \
    | FM_BUZZ_MAX_PROJECTION_BYTES=128 run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 1 "$code" "projection over the configured byte limit"
  assert_contains "$output" "exceeds FM_BUZZ_MAX_PROJECTION_BYTES (128 bytes)" \
    "oversized projection did not identify the byte limit"
  assert_not_contains "$output" "signed event" "oversized projection was signed"
  [ "$(replay_count "$home")" = "0" ] || fail "oversized projection entered the replay cache"
  pass "oversized projections are rejected before signing"
}

test_required_projection_fields_are_validated_before_signing() {
  local home field filter projection output code
  home=$(make_home required-projection-fields)
  run_keypair "$home" >/dev/null 2>&1 || fail "required-field keypair setup failed"
  while IFS='|' read -r field filter; do
    projection=$(test_projection | jq -c "$filter") \
      || fail "could not build invalid $field projection fixture"
    output=$(printf '%s' "$projection" | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
    code=$?
    expect_code 1 "$code" "projection with invalid $field"
    assert_contains "$output" "projection field $field" \
      "invalid $field did not identify the rejected field"
    assert_not_contains "$output" "signed event" "projection with invalid $field was signed"
    [ "$(replay_count "$home")" = "0" ] \
      || fail "projection with invalid $field entered the replay cache"
  done <<'EOF'
home|del(.home)
home|.home = null
generated|del(.generated)
generated|.generated = 123
prs|del(.prs)
prs|.prs = []
in_flight|del(.in_flight)
in_flight|.in_flight = {}
in_flight|.in_flight = [{id:"task-1",kind:"ship",state:"running"}]
EOF
  pass "required projection fields and types are rejected before signing"
}

test_refresh_preserves_the_snapshot_bytes_including_its_trailing_newline() {
  local home expected event result
  home=$(make_home refresh-verbatim)
  expected="$home/expected-snapshot.json"
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_BEARINGS_NOW=2026-08-10T00:00:00Z \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$expected" 2>/dev/null \
    || fail "could not capture the expected bearings snapshot"

  FM_BEARINGS_NOW=2026-08-10T00:00:00Z \
    run_publish "$home" "ws://127.0.0.1:1" --refresh >/dev/null 2>&1
  event=$(find "$home/state/buzz-replay" -name '*.json' -type f | head -1)
  [ -n "$event" ] || fail "refresh did not cache a signed event"
  result=$(node -e '
    const fs = require("node:fs");
    Promise.all([import(process.argv[1]), import(process.argv[2])]).then(([lib, crypto]) => {
      const expected = fs.readFileSync(process.argv[3], "utf8");
      const frame = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
      const event = frame[1];
      if (!expected.endsWith("\n")) return process.stdout.write("fixture-lost-newline");
      if (event.content !== expected) return process.stdout.write("content-changed");
      if (lib.computeEventId(event) !== event.id) return process.stdout.write("id-mismatch");
      if (!crypto.schnorrVerify(event.id, event.pubkey, event.sig)) return process.stdout.write("bad-signature");
      process.stdout.write("ok");
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$ROOT/bin/fm-buzz-crypto.mjs" "$expected" "$event")
  [ "$result" = "ok" ] || fail "refresh did not sign the snapshot bytes verbatim: $result"
  pass "refresh preserves the snapshot bytes including its trailing newline"
}

test_publish_without_a_keypair_still_exits_zero() {
  local home code
  home=$(make_home no-key)
  test_projection | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  code=$?
  expect_code 0 "$code" "publish with no keypair must still exit 0"
  pass "publish with no keypair exits 0"
}

test_non_loopback_env_relay_is_rejected_before_network() {
  local home guard sentinel output code
  home=$(make_home relay-allowlist)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Replace Node's network boundary for this one invocation. Reaching the
  # WebSocket constructor records durable evidence before throwing, so the test
  # distinguishes an allowlist rejection from a fast DNS or connection failure.
  guard="$TMP_ROOT/network-guard.mjs"
  sentinel="$TMP_ROOT/network-attempted"
  cat > "$guard" <<'EOF'
import { writeFileSync } from "node:fs";
globalThis.WebSocket = class NetworkAttempt {
  constructor() {
    writeFileSync(process.env.FM_BUZZ_NETWORK_SENTINEL, "attempted\n");
    throw new Error("network boundary reached");
  }
};
EOF

  output=$(test_projection "must-stay-local" \
    | env FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
      XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
      FM_BUZZ_RELAY="wss://evil.example" FM_BUZZ_NETWORK_SENTINEL="$sentinel" \
      NODE_OPTIONS="--import=$guard" "$PUBLISH" 2>&1)
  code=$?

  expect_code 0 "$code" "a rejected relay must preserve fire-and-forget"
  assert_contains "$output" "rejected relay host: evil.example" \
    "the publisher did not identify the rejected host"
  assert_absent "$sentinel" "a non-loopback relay reached the network boundary"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "a projection was cached before the non-loopback relay was rejected"
  pass "FM_BUZZ_RELAY rejects a non-loopback host before cache or network access"
}

test_credential_bearing_relays_are_rejected_before_signing_or_caching() {
  local home relay output code
  home=$(make_home relay-credentials)
  run_keypair "$home" >/dev/null 2>&1 || fail "credential-relay keypair setup failed"
  for relay in 'ws://operator@127.0.0.1:1' 'ws://operator:secret@127.0.0.1:1'; do
    output=$(test_projection "no-credential-relay" \
      | run_publish "$home" "$relay" 2>&1)
    code=$?
    expect_code 0 "$code" "credential-bearing relay through fire-and-forget"
    assert_contains "$output" "credential-bearing relay URLs are not supported" \
      "credential-bearing relay $relay was not rejected"
    assert_not_contains "$output" "signed event" \
      "credential-bearing relay $relay reached signing"
    [ "$(replay_count "$home")" = "0" ] \
      || fail "credential-bearing relay $relay created replay data"
  done
  pass "credential-bearing relays are rejected before signing or caching"
}

test_rotation_rejects_credential_relays_without_logging_credentials() {
  local home old output code
  home=$(make_home rotation-credential-redaction)
  old=$(run_keypair "$home" 2>/dev/null) || fail "rotation credential fixture setup failed"
  output=$(FM_BUZZ_KEYPAIR_RELAY='ws://operator:super-secret@localhost:3000/private' \
    run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a credential-bearing relay"
  assert_contains "$output" "credential-bearing relay URLs are not supported" \
    "rotation did not diagnose the unsupported credential-bearing relay"
  assert_not_contains "$output" "operator" "rotation logged the relay username"
  assert_not_contains "$output" "super-secret" "rotation logged the relay password"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "credential-bearing relay validation changed the publishing key"
  pass "rotation rejects credential relays without logging credentials"
}

# --- (c) relay up ----------------------------------------------------------

test_publish_with_relay_up_delivers_and_lands() {
  local home relay output code content
  home=$(make_home relay-up)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --challenge)
EOF

  content=$(test_projection "" '[{"surface":"prs: not requested","reveal":"--include-prs"}]')
  output=$(printf '%s' "$content" | run_publish "$home" "$relay" 2>&1)
  code=$?
  expect_code 0 "$code" "publish with the relay up"
  assert_contains "$output" "delivered=1" "the event was not delivered"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the replay cache was not drained after delivery"

  # Read it back off the relay and confirm the projection survived verbatim,
  # omitted[] disclosure included.
  local readback
  readback=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_STREAM_MESSAGE] }));
      process.stdout.write(String(events.length) + "\n");
      if (events[0]) process.stdout.write(events[0].content + "\n");
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")

  local stored_count
  stored_count=$(printf '%s\n' "$readback" | sed -n '1p')
  [ "$stored_count" = "1" ] \
    || fail "the relay stored $stored_count messages, expected exactly one"
  assert_contains "$readback" '"surface":"prs: not requested"' \
    "the omitted[] disclosure did not survive publication verbatim"
  assert_contains "$readback" "$content" "the projection was altered in transit"

  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
  pass "publish with the relay up delivers, lands, and preserves omitted[] verbatim"
}

test_same_endpoint_channel_queues_are_isolated() {
  local home relay port channel_a channel_b directory_a before after output readback
  home=$(make_home same-endpoint-channel-isolation)
  run_keypair "$home" >/dev/null 2>&1 || fail "channel isolation keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  port=${relay##*:}
  stop_stub "$STUB_PID"
  channel_a=$(channel_id_for_label same-endpoint-a)
  channel_b=$(channel_id_for_label same-endpoint-b)
  test_projection "same-endpoint-a-one" \
    | run_publish "$home" "$relay" --channel-label same-endpoint-a >/dev/null 2>&1
  test_projection "same-endpoint-a-two" \
    | run_publish "$home" "$relay" --channel-label same-endpoint-a >/dev/null 2>&1
  directory_a=$(channel_cache_dir "$home" "$relay" "$channel_a")
  [ "$(find "$directory_a" -type f -name '*.json' | wc -l | tr -d ' ')" = "2" ] \
    || fail "channel A did not retain two isolated replay entries"
  before=$(find "$directory_a" -type f -name '*.json' -print0 | sort -z | xargs -0 shasum -a 256)

  read -r STUB_PID relay <<EOF
$(start_stub --port "$port")
EOF
  output=$(test_projection "same-endpoint-b" \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" --channel-label same-endpoint-b 2>&1)
  after=$(find "$directory_a" -type f -name '*.json' -print0 | sort -z | xargs -0 shasum -a 256)
  [ "$before" = "$after" ] || fail "channel B inspected or mutated channel A replay bytes"
  [ "$(find "$directory_a" -type f -name '*.json' | wc -l | tr -d ' ')" = "2" ] \
    || fail "channel B pruned or drained channel A replay entries"
  assert_contains "$output" "delivered=1" "channel B did not drain its own queue"
  readback=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_NIP29_CREATE_GROUP, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_NIP29_CREATE_GROUP, KIND_STREAM_MESSAGE] }));
      process.stdout.write(events.map((event) => JSON.stringify({
        kind: event.kind,
        channel: event.tags.find((tag) => tag[0] === "h")?.[1],
        content: event.content,
      })).join("\n"));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")
  stop_stub "$STUB_PID"
  assert_contains "$readback" "$channel_b" "channel B was not provisioned"
  assert_not_contains "$readback" "$channel_a" "channel B provisioned channel A"
  assert_not_contains "$readback" "same-endpoint-a" "channel B delivered a channel A projection"
  [ -d "$(channel_cache_dir "$home" "$relay" "$channel_b")" ] \
    || fail "channel B did not use its exact channel partition"
  pass "same-endpoint channel queues are provisioned and drained independently"
}

test_channel_delivery_locks_do_not_share_one_home_wide_queue() {
  local home relay port channel_a channel_b lock_a lock_b holder output waiter waiter_output waited intent
  home=$(make_home channel-delivery-locks)
  run_keypair "$home" >/dev/null 2>&1 || fail "delivery lock keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  port=${relay##*:}
  channel_a=$(channel_id_for_label delivery-lock-a)
  channel_b=$(channel_id_for_label delivery-lock-b)
  lock_a=$(delivery_lock_path "$home" "$relay" "$channel_a")
  lock_b=$(delivery_lock_path "$home" "$relay" "$channel_b")
  [ "$lock_a" != "$lock_b" ] || fail "two channels on one relay share a delivery lock"

  # Stand in for a channel-A publish whose relay is slow: its queue is owned, the
  # rest of the home is not. Channel B must not spend its deadline waiting on it.
  mkdir -p "$home/state"
  holder=$(hold_lock "$lock_a") || fail "could not hold channel A's delivery lock"
  output=$(test_projection "delivery-lock-b" \
    | FM_BUZZ_LOCK_TIMEOUT_S=2 run_publish "$home" "$relay" --channel-label delivery-lock-b 2>&1)
  assert_contains "$output" "delivered=1" \
    "channel B could not publish while channel A's queue was held"
  assert_not_contains "$output" "could not acquire" \
    "channel B waited on ownership channel A was holding"

  waiter_output="$home/channel-a-waiter.out"
  (test_projection "delivery-lock-a-waiter" \
    | FM_BUZZ_LOCK_TIMEOUT_S=2 run_publish "$home" "$relay" --channel-label delivery-lock-a) \
    > "$waiter_output" 2>&1 &
  waiter=$!
  waited=0
  intent=""
  while [ -z "$intent" ] && [ "$waited" -lt 200 ]; do
    intent=$(find "$home/state" -maxdepth 1 -name '.buzz-replay-intent-*.lock' -print -quit 2>/dev/null)
    [ -n "$intent" ] || sleep 0.01
    waited=$((waited + 1))
  done
  [ -n "$intent" ] || fail "the channel-A waiter did not register delivery intent"
  output=$(test_projection "delivery-lock-b-during-a-wait" \
    | FM_BUZZ_LOCK_TIMEOUT_S=1 run_publish "$home" "$relay" --channel-label delivery-lock-b 2>&1)
  assert_contains "$output" "delivered=1" \
    "a channel-A waiter convoyed channel B on whole-tree ownership"
  assert_not_contains "$output" "replay cache ownership" \
    "a channel-A waiter retained whole-tree ownership"
  wait "$waiter" || fail "the channel-A waiter violated fire-and-forget"

  output=$(test_projection "delivery-lock-a" \
    | FM_BUZZ_LOCK_TIMEOUT_S=1 run_publish "$home" "$relay" --channel-label delivery-lock-a 2>&1)
  assert_contains "$output" "could not acquire this queue's delivery ownership" \
    "a second channel A publish ignored the held queue"
  release_lock "$holder"
  stop_stub "$STUB_PID"
  [ "$(find "$(channel_cache_dir "$home" "$relay" "$channel_a")" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
    || fail "the refused channel A publish cached a projection anyway"
  pass "delivery ownership is scoped per endpoint and channel, not per home"
}

test_network_delivery_does_not_hold_the_key_transaction_lock() {
  local home relay slow_output slow waited fast_output
  home=$(make_home network-key-lock)
  run_keypair "$home" >/dev/null 2>&1 || fail "network key-lock setup failed"
  slow_output="$home/slow-channel.out"
  read -r STUB_PID relay <<EOF
$(start_stub --challenge --challenge-delay-ms 2500)
EOF

  (test_projection "slow-channel-a" \
    | FM_BUZZ_LOCK_TIMEOUT_S=5 run_publish "$home" "$relay" --channel-label slow-channel-a) \
    > "$slow_output" 2>&1 &
  slow=$!
  waited=0
  while ! grep -F 'signed event' "$slow_output" >/dev/null 2>&1 && [ "$waited" -lt 300 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  grep -F 'signed event' "$slow_output" >/dev/null 2>&1 || {
    kill "$slow" 2>/dev/null
    stop_stub "$STUB_PID"
    fail "the slow channel never completed signing and caching"
  }

  fast_output=$(test_projection "fast-channel-b" \
    | FM_BUZZ_LOCK_TIMEOUT_S=1 run_publish "$home" "ws://127.0.0.1:1" \
      --channel-label fast-channel-b 2>&1)
  assert_contains "$fast_output" "signed event" \
    "channel B could not sign while channel A was waiting on the relay"
  assert_not_contains "$fast_output" "publishing key ownership" \
    "channel A held the key transaction lock during network delivery"
  wait "$slow" || fail "the slow channel violated the fire-and-forget contract"
  stop_stub "$STUB_PID"
  pass "network delivery releases the key transaction lock after durable caching"
}

test_reconnect_replays_the_identical_event_id() {
  local home relay port first_id after_kill stored
  home=$(make_home reconnect)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Kill mid-publish: the stub takes the event, then drops the socket before any
  # OK. The client cannot know whether it landed, so it must keep the event.
  read -r STUB_PID relay <<EOF
$(start_stub --drop-after-event)
EOF
  port=${relay##*:}
  test_projection "mid-publish" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  stop_stub "$STUB_PID"

  [ "$(replay_count "$home")" = "1" ] \
    || fail "an unacknowledged event must stay in the replay cache"
  first_id=$(find "$home/state/buzz-replay" -name '*.json' -exec basename {} \; | sed 's/^[0-9]*-//; s/\.json$//')

  # Reconnect to the same relay host and publish again. The cached event must go out
  # under its ORIGINAL id - not a freshly signed one - so a relay that already
  # has it dedupes instead of storing a second copy.
  read -r STUB_PID relay <<EOF
$(start_stub --port "$port")
EOF
  test_projection "after-reconnect" \
    | run_publish "$home" "$relay" >/dev/null 2>&1

  stored=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_STREAM_MESSAGE] }));
      process.stdout.write(events.map((e) => e.id).join("\n"));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")

  assert_contains "$stored" "$first_id" \
    "the reconnect did not replay the original event id"

  # Publishing the very same cached bytes again must not create a second copy.
  after_kill=$(printf '%s\n' "$stored" | sort | uniq -d)
  [ -z "$after_kill" ] || fail "the relay stored duplicate event ids: $after_kill"

  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
  pass "reconnect replays the identical event id and produces no duplicate"
}

replaying_a_known_event_is_deduped_and_evicted() {  # <label> [stub args...]
  # The `duplicate:` -> DELIVERED classification is what makes replay idempotent,
  # and it is only reachable against a relay that ALREADY holds the id - which a
  # reconnect to a fresh stub never is. One long-lived stub, and the same signed
  # bytes offered twice, is the only shape that exercises it.
  local label=$1
  shift
  local home relay port stashed cached output
  home=$(make_home "duplicate-$label")
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Reserve a relay URL, stop it, then publish against that dead URL to capture
  # the exact signed bytes the host-keyed cache holds.
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  port=${relay##*:}
  stop_stub "$STUB_PID"
  test_projection "first" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "1" ] || fail "the first event was not cached"
  cached=$(find "$home/state/buzz-replay" -name '*.json' | head -1)
  stashed="$TMP_ROOT/stashed-$label-$(basename "$cached")"
  cp "$cached" "$stashed"

  # Drain it into a long-lived stub. The relay now holds this id.
  read -r STUB_PID relay <<EOF
$(start_stub --port "$port" "$@")
EOF
  test_projection "second" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "0" ] || fail "the cache did not drain against a live relay"

  # Put the very same bytes back, as an unacknowledged delivery would have. The
  # relay answers `duplicate:`, which must count as DELIVERED and evict the entry
  # rather than being retained and replayed forever.
  cp "$stashed" "$cached"
  output=$(test_projection "third" \
    | run_publish "$home" "$relay" 2>&1)

  assert_contains "$output" "delivered=2" \
    "a duplicate must count as delivered, not retained"
  assert_contains "$output" "retained=0" \
    "a duplicate was retained instead of evicted"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "a relay-deduped event must be evicted from the replay cache"

  # And the relay must hold one copy of that id, not two.
  local ids duplicates
  ids=$(node -e '
    import(process.argv[1]).then(async ({ withRelay, KIND_STREAM_MESSAGE }) => {
      const { generateKeypair } = await import(process.argv[3]);
      const { events } = await withRelay(process.argv[2], generateKeypair().privateKey, 8000,
        async (api) => api.query({ kinds: [KIND_STREAM_MESSAGE] }));
      process.stdout.write(events.map((e) => e.id).join("\n"));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$ROOT/bin/fm-buzz-crypto.mjs")
  duplicates=$(printf '%s\n' "$ids" | sort | uniq -d)
  [ -z "$duplicates" ] || fail "the relay stored the replayed event twice: $duplicates"

  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
  pass "replaying an event the relay already has is deduped and evicted ($label)"
}

test_replaying_a_known_event_is_deduped_and_evicted() {
  # Both relay answers for a known id. The refusing one is the case that actually
  # exercises classifyOkResponse's `duplicate:` branch: an accepted=true answer is
  # DELIVERED on the first line and never consults the message at all, so a suite
  # that only modelled that shape would pass with the branch broken.
  replaying_a_known_event_is_deduped_and_evicted accepted
  replaying_a_known_event_is_deduped_and_evicted refused --duplicate-refused
}

test_an_unacknowledged_publish_does_not_starve_the_drain() {
  # The channel-create publish runs BEFORE the replay drain, so if one publish can
  # consume the whole connection budget the drain never starts and the run dies
  # before a single cached event is attempted. Against a relay that acknowledges
  # nothing, each publish must give up on its own deadline and the run must still
  # reach its summary.
  local home relay output
  home=$(make_home starve)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --silent-ok)
EOF
  output=$(test_projection "starve" \
    | run_publish "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$output" "delivered=0 retained=1" \
    "the cached event was never attempted; one stalled publish ate the whole budget"
  assert_not_contains "$output" "relay timeout after" \
    "the connection-wide timeout fired, so no publish had a deadline of its own"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "an unacknowledged event must stay cached"
  pass "one unacknowledged publish does not starve the replay drain"
}

test_a_late_auth_challenge_is_still_answered() {
  # NIP-42 gives a signal in both directions - the relay's AUTH frame, and the OK
  # it keys to the auth event's id - and the client must wait for those frames
  # rather than guess when they arrive. A fixed nap before looking for the
  # challenge loses the race on any loaded or cold relay, and then every event
  # comes back `auth-required:`, is classified retryable, and is retained run after
  # run with nothing but a stderr line to show for it. This stub challenges late
  # and refuses unauthenticated events, so a guessed wait cannot pass it.
  local home relay output
  home=$(make_home late-challenge)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --challenge --challenge-delay-ms 250)
EOF
  output=$(test_projection "late-challenge" \
    | run_publish "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$output" "delivered=1" \
    "the late challenge was never answered, so the relay refused the event"
  assert_not_contains "$output" "auth-required" \
    "an event was published before the NIP-42 handshake finished"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the event was retained even though the connection was authenticated"
  pass "a challenge that lands late is still answered before anything is published"
}

test_a_challenge_past_the_handshake_window_still_lands_the_event() {
  # The window that waits for the challenge cannot be unbounded - an open relay
  # never sends one and would pay the whole deadline for nothing - so a challenge
  # can always arrive after it closes. That is the case this pins: 800ms against a
  # 500ms window, which means the first pass really does publish unauthenticated
  # and really is refused `auth-required:`. What must not follow is the failure
  # this replaced: refused, classified retryable, retained, and the same race lost
  # again on every future run, so the home never publishes at all. The challenge is
  # answered from the frame handler, the second window collects that answer, and
  # exactly the refused events are re-offered.
  local home relay output
  home=$(make_home past-window-challenge)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --challenge --challenge-delay-ms 800)
EOF
  output=$(test_projection "past-window" \
    | run_publish "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$output" "auth-required" \
    "the first pass was expected to publish before the challenge arrived; this test no longer covers the late-challenge branch"
  assert_contains "$output" "authenticated after the handshake window" \
    "the challenge that arrived after the window was never settled"
  assert_contains "$output" "delivered=1" \
    "the event refused before authentication was never re-attempted"
  assert_contains "$output" "retained=0" \
    "an event refused only for want of authentication was left in the cache"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the event was retained even though the connection ended up authenticated"
  pass "a challenge arriving past the handshake window still lands the refused event"
}

test_foreign_author_cache_entries_are_not_drained_by_the_current_publisher() {
  local home relay foreign_private foreign_public channel foreign_file output
  home=$(make_home foreign-author-cache)
  run_keypair "$home" >/dev/null 2>&1 || fail "foreign-author cache keypair setup failed"
  foreign_private=$(new_private_key) || fail "could not mint a foreign cache publisher"
  foreign_public=$(public_from_private "$foreign_private") \
    || fail "could not derive the foreign cache publisher"
  channel=$(default_channel_id "$home")
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  foreign_file=$(seed_replay_event \
    "$home" "$relay" "$foreign_private" 1700000400 "$channel" foreign-author-cache) \
    || fail "could not seed a foreign-author cache entry"

  output=$(test_projection "current-publisher" \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_present "$foreign_file" "the current publisher evicted another author\'s cached event"
  assert_contains "$output" "publisher $foreign_public differs from authenticated publisher" \
    "the foreign-author cache entry was not diagnosed"
  assert_contains "$output" "delivered=1 retained=1" \
    "the foreign-author cache entry was not retained outside relay outcome classification"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "the current publisher changed the foreign-author replay entry"
  pass "relay drains retain events authored by another publisher identity"
}

test_permanent_rejection_is_not_replayed_forever() {
  local home relay
  home=$(make_home permanent)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --reject "invalid: malformed event")
EOF
  test_projection | run_publish "$home" "$relay" >/dev/null 2>&1
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  [ "$(replay_count "$home")" = "0" ] \
    || fail "a permanently rejected event must be dropped, not replayed forever"
  pass "a permanently rejected event is dropped from the replay cache"
}

test_retryable_rejection_is_kept() {
  local home relay
  home=$(make_home retryable)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --reject "restricted: not a channel member")
EOF
  test_projection | run_publish "$home" "$relay" >/dev/null 2>&1
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  [ "$(replay_count "$home")" = "1" ] \
    || fail "a retryable rejection must keep the event for a later replay"
  pass "a retryable rejection keeps the event cached"
}

test_truthy_non_boolean_ok_is_not_accepted() {
  local home duplicate_home relay output
  home=$(make_home truthy-ok-permanent)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --truthy-ok --reject "invalid: malformed acknowledgement fixture")
EOF
  output=$(test_projection "truthy-ok" \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "delivered=0 retained=1" \
    "a truthy non-boolean OK field was treated as relay acceptance"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "a malformed OK field made a permanent-rejection note evict the cached event"

  duplicate_home=$(make_home truthy-ok-duplicate)
  run_keypair "$duplicate_home" >/dev/null 2>&1 || fail "duplicate fixture keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub --truthy-ok --duplicate-refused)
EOF
  test_projection "truthy-duplicate-first" \
    | run_publish "$duplicate_home" "$relay" >/dev/null 2>&1
  output=$(test_projection "truthy-duplicate-second" \
    | run_publish "$duplicate_home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "delivered=0 retained=2" \
    "a malformed OK field made a duplicate note count as delivery"
  [ "$(replay_count "$duplicate_home")" = "2" ] \
    || fail "a duplicate note evicted an event without a boolean acknowledgement"
  pass "relay notes are classified only with a boolean acknowledgement"
}

# --- (e) the replay cache is capped ----------------------------------------

test_publish_lock_acquisition_is_validated_bounded_and_interruptible() {
  local home lock projection out_file result invalid code pid waited ready holder tools real_mktemp mktemp_log
  home=$(make_home bounded-publish-lock)
  lock="$home/state/.buzz-replay-publish.lock"
  projection="$home/projection.json"
  out_file="$home/publish-lock.out"
  ready="$home/publish-lock-ready"
  run_keypair "$home" >/dev/null 2>&1 || fail "publish-lock fixture setup failed"
  test_projection "publish-lock" > "$projection"

  for invalid in 0 -1 abc 2147483648; do
    result=$(FM_BUZZ_LOCK_TIMEOUT_S=$invalid run_publish "$home" "ws://127.0.0.1:1" \
      < "$projection" 2>&1)
    code=$?
    expect_code 0 "$code" "invalid publish-lock deadline $invalid"
    assert_contains "$result" "FM_BUZZ_LOCK_TIMEOUT_S must be a positive integer" \
      "invalid publish-lock deadline $invalid was not rejected"
  done

  mkdir "$lock"
  : > "$lock/blocker"
  env FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
    FM_BUZZ_LOCK_TIMEOUT_S=1 "$PUBLISH" --relay "ws://127.0.0.1:1" \
    < "$projection" > "$out_file" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    fail "an uncreatable publish lock exceeded its acquisition deadline"
  fi
  wait "$pid"
  code=$?
  expect_code 0 "$code" "uncreatable publish lock through the fire-and-forget wrapper"
  assert_contains "$(cat "$out_file")" "could not acquire replay cache ownership within 1s" \
    "an uncreatable publish lock did not report its bounded refusal"

  rm -rf "$lock"
  tools="$home/uncreatable-lock-tools"
  real_mktemp=$(command -v mktemp)
  mktemp_log="$home/uncreatable-lock-mktemp.log"
  mkdir -p "$tools"
  cat > "$tools/mktemp" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case $argument in
    *'.buzz-replay-publish.lock'*.owner.*)
      printf '%s\n' "$argument" >> "$FM_TEST_MKTEMP_LOG"
      exit 1
      ;;
  esac
done
exec "$FM_TEST_REAL_MKTEMP" "$@"
EOF
  chmod +x "$tools/mktemp"
  env PATH="$tools:$PATH" FM_TEST_REAL_MKTEMP="$real_mktemp" FM_TEST_MKTEMP_LOG="$mktemp_log" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
    FM_BUZZ_LOCK_TIMEOUT_S=1 "$PUBLISH" --relay "ws://127.0.0.1:1" \
    < "$projection" > "$out_file" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    fail "an uncreatable lock parent bypassed the acquisition deadline"
  fi
  wait "$pid"
  code=$?
  expect_code 0 "$code" "uncreatable lock parent through the fire-and-forget wrapper"
  assert_no_grep '.steal.steal' "$mktemp_log" \
    "lock acquisition recursively descended through nested steal locks"
  assert_contains "$(cat "$out_file")" "could not acquire replay cache ownership within 1s" \
    "an uncreatable lock parent did not report its bounded refusal"

  (
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$lock"
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null
    fail "the persistent publish-lock fixture did not acquire ownership"
  }

  # shellcheck disable=SC2031
  env FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
    FM_BUZZ_LOCK_TIMEOUT_S=1 "$PUBLISH" --relay "ws://127.0.0.1:1" \
    < "$projection" > "$out_file" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    kill "$holder" 2>/dev/null
    wait "$pid" "$holder" 2>/dev/null
    fail "a persistently held publish lock exceeded its acquisition deadline"
  fi
  wait "$pid"
  code=$?
  expect_code 0 "$code" "persistently held publish lock through the fire-and-forget wrapper"
  assert_contains "$(cat "$out_file")" "could not acquire replay cache ownership within 1s" \
    "a persistently held publish lock did not report its bounded refusal"

  # shellcheck disable=SC2031
  env FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
    FM_BUZZ_LOCK_TIMEOUT_S=30 "$PUBLISH" --relay "ws://127.0.0.1:1" \
    < "$projection" > "$out_file" 2>&1 &
  pid=$!
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || {
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    fail "the interrupted publisher was not waiting for cache ownership"
  }
  kill -TERM "$pid" 2>/dev/null
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    kill "$holder" 2>/dev/null
    wait "$pid" "$holder" 2>/dev/null
    fail "a signal did not terminate the publish-lock wait"
  fi
  wait "$pid"
  code=$?
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  expect_code 0 "$code" "interrupted publish-lock wait through the fire-and-forget wrapper"
  assert_contains "$(cat "$out_file")" "interrupted while waiting for replay cache ownership" \
    "an interrupted publish-lock wait was not diagnosed"
  assert_contains "$(cat "$out_file")" "Firstmate is unaffected" \
    "an interrupted publish-lock wait bypassed the exit-0 conversion path"
  pass "publish-lock waits validate deadlines, time out, and honor signals"
}

test_a_writer_that_never_closes_does_not_hang_the_publish() {
  # Exit status 0 is worth nothing to a caller if the script never returns, and an
  # unbounded `cat` on stdin is the one place that can happen. A fifo whose write
  # end this test holds open is a writer that never sends EOF: the read must hit
  # its deadline, log, and still exit 0 - and it must not publish the partial read.
  local home fifo output code
  home=$(make_home stdin-stall)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  fifo="$TMP_ROOT/stall.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" || fail "could not create the test fifo"

  # Read-write, so opening it does not block waiting for the other end to appear;
  # holding it open is what makes this a writer that never sends EOF.
  exec 9<>"$fifo"
  printf '%s' '{"schema":"fm-bearings.v1","omitted":[],"note":"partial' >&9

  # Run it detached and give it a wall-clock budget of its own. If the bound ever
  # regresses this must FAIL, not inherit the hang it is testing for - a suite
  # that hangs in CI reports nothing at all.
  local spool pid waited
  spool="$TMP_ROOT/stall.out"
  FM_BUZZ_STDIN_TIMEOUT_S=2 run_publish "$home" "ws://127.0.0.1:1" < "$fifo" > "$spool" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    exec 9>&-
    rm -f "$fifo"
    fail "the publish never returned; an unbounded stdin read hangs the caller"
  fi
  wait "$pid"
  code=$?
  output=$(cat "$spool")
  exec 9>&-
  rm -f "$fifo"

  expect_code 0 "$code" "a stalled stdin read must still exit 0"
  assert_contains "$output" "could not read the projection from stdin within 2s" \
    "the bounded read did not report its deadline"
  assert_contains "$output" "Firstmate is unaffected" \
    "the stalled read did not go through the fire-and-forget conversion"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "a truncated projection must never be signed and enqueued"
  pass "a writer that never closes stdin cannot hang the publish"
}

test_invalid_stdin_timeouts_are_rejected_before_reading() {
  local home invalid fifo spool pid waited output code
  home=$(make_home invalid-stdin-timeout)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  for invalid in 0 -1 nope 2147483648 999999999999999999999999999999; do
    fifo="$TMP_ROOT/invalid-timeout-$invalid.fifo"
    spool="$TMP_ROOT/invalid-timeout-$invalid.out"
    rm -f "$fifo"
    mkfifo "$fifo" || fail "could not create invalid-timeout fifo"
    exec 7<>"$fifo"
    printf '%s' '{"schema":"fm-bearings.v1","omitted":[],"note":"partial' >&7
    env FM_BUZZ_STDIN_TIMEOUT_S="$invalid" FM_HOME="$home" \
      FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
      XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
      "$PUBLISH" --relay "ws://127.0.0.1:1" < "$fifo" > "$spool" 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
      exec 7>&-
      rm -f "$fifo"
      fail "invalid stdin timeout $invalid left the publisher blocked on its reader"
    fi
    wait "$pid"
    code=$?
    output=$(cat "$spool")
    exec 7>&-
    rm -f "$fifo"
    expect_code 0 "$code" "invalid stdin timeout $invalid must still exit 0"
    assert_contains "$output" "FM_BUZZ_STDIN_TIMEOUT_S must be a positive integer" \
      "invalid stdin timeout $invalid was not rejected"
  done
  [ "$(replay_count "$home")" = "0" ] \
    || fail "an invalid stdin timeout allowed a partial projection into the replay cache"
  pass "invalid stdin timeout values are rejected before starting a reader"
}

test_required_option_operands_are_not_consumed_as_flags() {
  local home output code option following
  home=$(make_home missing-option-operands)

  for option in --relay --channel-label --timeout; do
    following=--refresh
    output=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
      XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
      "$PUBLISH" "$option" "$following" 2>&1)
    code=$?
    expect_code 0 "$code" "publish option $option without a value"
    assert_contains "$output" "$option requires a value" \
      "publish option $option consumed the following flag as its value"
    assert_not_contains "$output" "signed event" "publish option $option reached signing without a value"
  done

  for option in --relay --channel-label --limit; do
    output=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
      XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
      "$INSPECT" "$option" --anonymous 2>&1)
    code=$?
    expect_code 2 "$code" "inspect option $option without a value"
    assert_contains "$output" "$option requires a value" \
      "inspect option $option consumed the following flag as its value"
  done
  pass "publish and inspect reject missing option operands before shifting"
}

test_unknown_publish_options_are_safe_non_events() {
  local home output code
  home=$(make_home unknown-publish-option)
  run_keypair "$home" >/dev/null 2>&1 || fail "unknown-option keypair setup failed"
  output=$(test_projection "must-not-publish" \
    | run_publish "$home" ws://127.0.0.1:9 --relai ws://127.0.0.1:3000 2>&1)
  code=$?
  expect_code 0 "$code" "unknown publish option through the fire-and-forget wrapper"
  assert_contains "$output" "unknown argument: --relai" \
    "unknown publish option was not diagnosed"
  assert_not_contains "$output" "signed event" \
    "unknown publish option fell through to default publication"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "unknown publish option created replay state"
  assert_absent "$home/data/buzz-publisher-targets.jsonl" \
    "unknown publish option recorded a publisher target"
  pass "unknown publish options are logged safe non-events"
}

test_a_signalled_read_leaves_no_projection_in_temp() {
  # The spool holds the bearings projection - task ids, project names, blockers,
  # PR URLs - in a shared temp directory. Being killed mid-read is precisely the
  # case the watchdog exists for, so it is precisely the case that must not leave
  # that content lying around with no owner.
  local home fifo spooldir pid waited
  home=$(make_home stdin-signal)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  spooldir="$TMP_ROOT/stdin-signal-tmp"
  mkdir -p "$spooldir"
  fifo="$TMP_ROOT/signal.fifo"
  rm -f "$fifo"
  mkfifo "$fifo" || fail "could not create the test fifo"

  # Read-write, so this end never sends EOF and the read is still in flight when
  # the signal lands.
  exec 8<>"$fifo"
  printf '%s' '{"schema":"fm-bearings.v1","omitted":[],"note":"in-flight' >&8

  # `env` rather than run_publish, so the recorded pid is the script itself: a
  # signal sent to an intervening subshell would never reach the trap under test.
  env TMPDIR="$spooldir" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" XDG_DATA_HOME="$home/xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
    "$PUBLISH" --relay "ws://127.0.0.1:1" < "$fifo" > /dev/null 2>&1 &
  pid=$!

  waited=0
  while [ -z "$(find "$spooldir" -name 'fm-buzz-stdin.*' 2>/dev/null)" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ -z "$(find "$spooldir" -name 'fm-buzz-stdin.*' 2>/dev/null)" ]; then
    kill "$pid" 2>/dev/null
    exec 8>&-
    rm -f "$fifo"
    fail "the read never spooled, so this test is not exercising the signal path"
  fi

  kill -TERM "$pid" 2>/dev/null
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  exec 8>&-
  rm -f "$fifo"

  [ -z "$(find "$spooldir" -name 'fm-buzz-stdin.*' 2>/dev/null)" ] \
    || fail "a signalled run left the bearings projection behind in $spooldir"
  pass "a signalled stdin read leaves no projection in the temp directory"
}

test_a_signalled_read_releases_the_callers_output() {
  # The other half of the signal path, and the half the spool test cannot see
  # because it discards the output. The background reader is not reaped by the
  # signal: it keeps running against a deleted spool while holding the stderr this
  # script inherited, so a caller doing `out=$(fm-buzz-publish.sh ... 2>&1)` blocks
  # on that pipe long after the script exited - the same caller-side hang the read
  # watchdog exists to prevent, reached from the other direction.
  #
  # Asserted by pipe lifetime, which is the property that actually matters: the
  # output goes down a fifo whose only reader is this test's `cat`, so that reader
  # sees EOF exactly when the last writer - script, watchdog, or leaked reader -
  # lets go. It never returning IS the caller hanging.
  local home fifo outfifo outlog pid drainer waited
  home=$(make_home stdin-signal-output)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  fifo="$TMP_ROOT/signal-output-stdin.fifo"
  outfifo="$TMP_ROOT/signal-output.fifo"
  outlog="$TMP_ROOT/signal-output.log"
  rm -f "$fifo" "$outfifo"
  mkfifo "$fifo" || fail "could not create the test stdin fifo"
  mkfifo "$outfifo" || fail "could not create the test output fifo"

  exec 8<>"$fifo"
  printf '%s' '{"schema":"fm-bearings.v1","omitted":[],"note":"in-flight' >&8

  # The drainer opens the read end first so the script's open of the write end
  # does not block, and it is the only reader, so its exit means EOF.
  cat "$outfifo" > "$outlog" &
  drainer=$!

  env TMPDIR="$TMP_ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" XDG_DATA_HOME="$home/xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 FM_BUZZ_TIMEOUT_MS=8000 \
    "$PUBLISH" --relay "ws://127.0.0.1:1" < "$fifo" > "$outfifo" 2>&1 &
  pid=$!

  waited=0
  while [ -z "$(find "$TMP_ROOT" -maxdepth 1 -name 'fm-buzz-stdin.*' 2>/dev/null)" ] \
    && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  kill -TERM "$pid" 2>/dev/null
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  # Generous, because a surviving reader would hold this open forever and the only
  # honest way to tell "slow" from "never" is to wait longer than anything on this
  # path legitimately takes. The watchdog's own worst case is one second.
  waited=0
  while kill -0 "$drainer" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  if kill -0 "$drainer" 2>/dev/null; then
    kill "$drainer" 2>/dev/null
    exec 8>&-
    rm -f "$fifo" "$outfifo"
    fail "a signalled run left a reader holding the caller's output open"
  fi

  exec 8>&-
  rm -f "$fifo" "$outfifo"
  pass "a signalled read releases the caller's output instead of holding it open"
}

# --- the contract itself ---------------------------------------------------

test_fire_and_forget_contract_is_intact() {
  # A structural guard: runtime publication errors remain non-blocking while
  # prerequisite and projection-contract failures stay loud.
  # Match an actual shell directive at the start of a line, not the header
  # comment that documents why the directive is banned.
  ! grep -nE '^[[:space:]]*set -[a-z]*e' "$PUBLISH" >/dev/null \
    || fail "bin/fm-buzz-publish.sh must not use set -e; it would break fire-and-forget"
  assert_grep 'exit 0' "$PUBLISH" "bin/fm-buzz-publish.sh lost its unconditional exit 0"
  [ "$(tail -1 "$PUBLISH")" = "exit 0" ] \
    || fail "bin/fm-buzz-publish.sh must end with an unconditional exit 0"
  [ "$(grep -Ec '^[[:space:]]*exit 1$' "$PUBLISH")" = "2" ] \
    || fail "bin/fm-buzz-publish.sh must reserve non-zero exits for prerequisites and invalid projections"
  grep -Eq 'PREREQUISITE_STATUS.*-eq 2' "$PUBLISH" \
    || fail "the python3 prerequisite exit is not narrowly gated"
  grep -Eq 'PUBLISH_STATUS.*-eq 2' "$PUBLISH" \
    || fail "the invalid-projection exit is not narrowly gated"
  pass "runtime failures remain fire-and-forget while contract failures stay loud"
}

test_nothing_private_reaches_a_command_line() {
  # A structural guard, for the same reason as the one above: an argv is
  # world-readable through the process table, and `--arg`/`-w <secret>` are the
  # obvious-looking spellings that put a secret there. Both are one careless edit
  # away, and neither shows up in any behavioural assertion.
  #
  # The projection is guarded alongside the key rather than after it, because it is
  # private for the same reason the stdin spool is: task ids, project names,
  # blockers, PR URLs. It was on jq's argv for exactly as long as it took someone
  # to notice that the fix for the key had not been applied to it.
  # Match real shell lines only, never the header comments that explain why these
  # spellings are banned - the same distinction the fire-and-forget guard makes.
  local offenders
  offenders=$(grep -nE '^[[:space:]]*[^#]*--arg[[:space:]]+(privateKey|content)' \
    "$ROOT/bin/fm-buzz-publish.sh" "$ROOT/bin/fm-buzz-inspect.sh" || true)
  [ -z "$offenders" ] \
    || fail "the key and the projection must reach jq through a file descriptor, not argv:"$'\n'"$offenders"

  offenders=$(grep -nE '^[[:space:]]*[^#]*security[[:space:]]+add-generic-password' \
    "$ROOT/bin/fm-buzz-key-lib.sh" || true)
  [ -z "$offenders" ] \
    || fail "the keychain write must go through 'security -i' so the secret is not in argv:"$'\n'"$offenders"

  pass "neither the private key nor the projection reaches a command line"
}

read -r ROTATION_GUARD_PID ROTATION_GUARD_RELAY <<EOF
$(start_stub)
EOF

test_publish_with_relay_down_exits_zero_and_enqueues
test_missing_python3_is_a_loud_prerequisite_failure
test_missing_global_websocket_is_rejected_before_publication
test_same_second_identical_publishes_have_distinct_signed_identities
test_replayed_events_are_tracked_before_delivery
test_malformed_projection_is_rejected_before_signing
test_missing_projection_schema_is_rejected_before_signing
test_malformed_projection_omitted_is_rejected_before_signing
test_duplicate_projection_fields_are_rejected_before_signing
test_oversized_projection_is_rejected_before_signing
test_required_projection_fields_are_validated_before_signing
test_refresh_preserves_the_snapshot_bytes_including_its_trailing_newline
test_publish_without_a_keypair_still_exits_zero
test_non_loopback_env_relay_is_rejected_before_network
test_credential_bearing_relays_are_rejected_before_signing_or_caching
test_rotation_rejects_credential_relays_without_logging_credentials
test_publish_with_relay_up_delivers_and_lands
test_same_endpoint_channel_queues_are_isolated
test_channel_delivery_locks_do_not_share_one_home_wide_queue
test_network_delivery_does_not_hold_the_key_transaction_lock
test_reconnect_replays_the_identical_event_id
test_replaying_a_known_event_is_deduped_and_evicted
test_an_unacknowledged_publish_does_not_starve_the_drain
test_a_late_auth_challenge_is_still_answered
test_a_challenge_past_the_handshake_window_still_lands_the_event
test_foreign_author_cache_entries_are_not_drained_by_the_current_publisher
test_permanent_rejection_is_not_replayed_forever
test_retryable_rejection_is_kept
test_truthy_non_boolean_ok_is_not_accepted
test_publish_lock_acquisition_is_validated_bounded_and_interruptible
test_a_writer_that_never_closes_does_not_hang_the_publish
test_invalid_stdin_timeouts_are_rejected_before_reading
test_required_option_operands_are_not_consumed_as_flags
test_unknown_publish_options_are_safe_non_events
test_a_signalled_read_leaves_no_projection_in_temp
test_a_signalled_read_releases_the_callers_output
test_fire_and_forget_contract_is_intact
test_nothing_private_reaches_a_command_line
