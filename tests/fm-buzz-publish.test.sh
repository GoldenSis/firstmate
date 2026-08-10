#!/usr/bin/env bash
# Behavior tests for the loopback Buzz bearings publisher.
#
# Covers the five cases the milestone's exit gate names, plus the two properties
# everything else rests on: that the signing is really BIP-340 (checked against
# the official 32-byte-message test vectors, not against our own verifier alone)
# and that the fire-and-forget contract has not been edited away.
#
# These run against tests/fm-buzz-stub-relay.mjs, not the real Buzz stack, so they
# pass on a CI runner with no Docker. The real relay was exercised by hand for the
# milestone's exit gate; see docs/buzz-loopback-adapter.md for that evidence.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEYPAIR="$ROOT/bin/fm-buzz-keypair.sh"
PUBLISH="$ROOT/bin/fm-buzz-publish.sh"
INSPECT="$ROOT/bin/fm-buzz-inspect.sh"
STUB="$ROOT/tests/fm-buzz-stub-relay.mjs"
TMP_ROOT=$(fm_test_tmproot fm-buzz)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  fm_test_cleanup
}
trap cleanup EXIT

# An isolated home whose keypair lands in a temp XDG dir and never in the
# developer's real login keychain.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/xdg"
  printf '%s\n' "$home"
}

# Portable file mode. Do NOT use the `stat -f <fmt> || stat -c <fmt>` fallback
# form: on Linux `stat -f` is *filesystem* stat, so it succeeds and prints a
# filesystem report instead of the mode, and the `-c` branch never runs.
file_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

run_keypair() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    "$KEYPAIR" "$@"
}

run_publish() {  # <home> <relay> [args...]
  local home=$1 relay=$2
  shift 2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_BUZZ_TIMEOUT_MS=8000 \
    "$PUBLISH" --relay "$relay" "$@"
}

run_inspect() {  # <home> <relay> [args...]
  local home=$1 relay=$2
  shift 2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    "$INSPECT" --relay "$relay" "$@"
}

# Start the stub on an ephemeral port and echo "<pid> <url>".
start_stub() {  # [stub args...]
  local out pid port line
  out=$(mktemp "$TMP_ROOT/stub.XXXXXX")
  node "$STUB" --port 0 "$@" > "$out" 2>/dev/null &
  pid=$!
  # Wait for the listening line rather than sleeping a fixed amount.
  for _ in $(seq 1 100); do
    line=$(head -1 "$out" 2>/dev/null)
    case $line in listening\ *) break ;; esac
    sleep 0.1
  done
  port=${line#listening }
  [ -n "$port" ] || { kill "$pid" 2>/dev/null; fail "stub relay did not start"; }
  printf '%s %s\n' "$pid" "ws://127.0.0.1:$port"
}

stop_stub() {  # <pid>
  local pid=$1 waited=0
  kill "$pid" 2>/dev/null
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    fail "stub relay $pid did not stop"
  fi
  STUB_PID=""
}

replay_count() {  # <home>
  local home=$1
  find "$home/state/buzz-replay" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

# Ask the custody library itself where a home's key file is, rather than hardcoding
# the name here: the per-home derivation is the thing under test, and a test that
# recomputed it would agree with a broken library by construction.
key_file() {  # <home> <xdg>
  ( XDG_DATA_HOME=$2 FM_BUZZ_FORCE_FILE_STORE=1
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-buzz-key-lib.sh"
    fm_buzz_key_fallback_file "$1" )
}

# --- the signing really is BIP-340 -----------------------------------------
#
# Everything else in this suite would still pass if the signer were subtly wrong
# and the stub's verifier were wrong in the same way, because both call the same
# module. The official vectors are the independent check that closes that gap.

test_bip340_official_vectors() {
  local result
  result=$(node -e '
    import(process.argv[1]).then(({ schnorrSign, schnorrVerify, publicKeyFromPrivate }) => {
      // Signing vectors 0-3 and the negative verification vectors 5-14 from
      // https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv
      // (only the 32-byte-message vectors; BIP-340 variable-length messages are
      // not part of NIP-01 and this signer does not accept them).
      const sign = [
        ["0000000000000000000000000000000000000000000000000000000000000003","f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9","0000000000000000000000000000000000000000000000000000000000000000","0000000000000000000000000000000000000000000000000000000000000000","e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0"],
        ["b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef","dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","0000000000000000000000000000000000000000000000000000000000000001","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a"],
        ["c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9","dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8","c87aa53824b4d7ae2eb035a2b5bbbccc080e76cdc6d1692c4b0b62d798e6d906","7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c","5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1bab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7"],
        ["0b432b2677937381aef05bb02a66ecd012773062cf3fa2549e44f58ed2401710","25d1dff95105f5253c4022f628a996ad3a0d95fbf21d468a1b33f8c160d8f517","ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","7eb0509757e246f19449885651611cb965ecc1a187dd51b64fda1edc9637d5ec97582b9cb13db3933705b32ba982af5af25fd78881ebb32771fc5922efc66ea3"]
      ];
      const badVerify = [
        ["eefdea4cdb677750a420fee807eacf21eb9898ae79b9768766e4faa04a2d4a34","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a14602975563cc27944640ac607cd107ae10923d9ef7a73c643e166be5ebeafa34b1ac553e2"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","1fa62e331edbc21c394792d2ab1100a7b432b013df3f6ff4f99fcb33e0e1515f28890b3edb6e7189b630448b515ce4f8622a954cfe545735aaea5134fccdb2bd"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e177769961764b3aa9b2ffcb6ef947b6887a226e8d7c93e00c5ed0c1834ff0d0c2e6da6"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","0000000000000000000000000000000000000000000000000000000000000000123dda8328af9c23a94c1feecfd123ba4fb73476f0d594dcb65c6425bd186051"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","00000000000000000000000000000000000000000000000000000000000000017615fbaf5ae28864013c099742deadb4dba87f11ac6754f93780d5a1837cf197"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","4a298dacae57395a15d0795ddbfd1dcb564da82b0f269bc70a74f8220429ba1d69e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f69e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e177769fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"],
        ["fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc30","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"]
      ];
      for (const [sk, pk, aux, msg, expected] of sign) {
        if (publicKeyFromPrivate(sk) !== pk) { console.log("bad-pubkey"); return; }
        if (schnorrSign(msg, sk, aux) !== expected) { console.log("bad-signature"); return; }
        if (!schnorrVerify(msg, pk, expected)) { console.log("bad-verify"); return; }
      }
      for (const [pk, msg, sig] of badVerify) {
        if (schnorrVerify(msg, pk, sig)) { console.log("accepted-invalid-signature"); return; }
      }
      console.log("ok");
    });
  ' "$ROOT/bin/fm-buzz-crypto.mjs")
  [ "$result" = "ok" ] || fail "BIP-340 official vectors failed: $result"
  pass "signing matches the official BIP-340 32-byte-message vectors and rejects all 10 invalid ones"
}

# --- (a) keypair generation ------------------------------------------------

test_keypair_is_idempotent_and_never_prints_the_private_key() {
  local home first second stored keyfile
  home=$(make_home keypair)
  keyfile=$(key_file "$home" "$home/xdg")

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  case $first in
    [0-9a-f]*) : ;;
    *) fail "keypair did not print a hex public key: $first" ;;
  esac
  [ "${#first}" -eq 64 ] || fail "public key has the wrong length: ${#first}"

  second=$(run_keypair "$home" 2>/dev/null) || fail "second keypair run failed"
  [ "$first" = "$second" ] \
    || fail "keypair is not idempotent: got $first then $second"

  assert_grep "$first" "$home/data/buzz-keypair.public" \
    "the public key was not recorded in data/buzz-keypair.public"

  # The private key must appear in NO output stream of either run.
  stored=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$keyfile")
  [ -n "$stored" ] || fail "no private key was stored"
  [ "$stored" != "$first" ] || fail "the public and private keys are identical"

  local combined
  combined=$(run_keypair "$home" 2>&1)
  assert_not_contains "$combined" "$stored" \
    "the private key leaked into the keypair script's output"

  # And the fallback file must not be world-readable.
  local mode
  mode=$(file_mode "$keyfile")
  [ "$mode" = "600" ] || fail "the key file mode is $mode, expected 600"

  pass "keypair generation is idempotent and never prints the private key"
}

# --- one key per home, in the store that cannot enforce it ------------------

test_two_homes_sharing_one_xdg_get_separate_keys() {
  # XDG_DATA_HOME follows the USER, not FM_HOME, so the realistic arrangement is
  # one XDG dir shared by the main home and every secondmate. The keychain keys on
  # the FM_HOME account and so is safe by construction; the file fallback has to
  # derive per-home too or a secondmate silently publishes under the main home's
  # identity on every non-Darwin host. Giving each synthetic home its own
  # XDG_DATA_HOME - which the rest of this suite does - cannot see that at all,
  # so this test deliberately shares one.
  local xdg main second main_key second_key main_file second_file
  xdg="$TMP_ROOT/shared-xdg"
  mkdir -p "$xdg"
  main=$(make_home per-home-main)
  second=$(make_home per-home-second)

  main_key=$(FM_HOME="$main" FM_DATA_OVERRIDE="$main/data" XDG_DATA_HOME="$xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 "$KEYPAIR" 2>/dev/null) \
    || fail "keypair creation failed for the main home"
  second_key=$(FM_HOME="$second" FM_DATA_OVERRIDE="$second/data" XDG_DATA_HOME="$xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 "$KEYPAIR" 2>/dev/null) \
    || fail "keypair creation failed for the second home"

  [ "$main_key" != "$second_key" ] \
    || fail "two homes sharing one XDG_DATA_HOME got the SAME public key ($main_key); the second home would publish under the first home's identity"

  main_file=$(key_file "$main" "$xdg")
  second_file=$(key_file "$second" "$xdg")
  [ "$main_file" != "$second_file" ] \
    || fail "both homes resolved to one key file: $main_file"
  assert_present "$main_file" "the main home's key file is missing"
  assert_present "$second_file" "the second home's key file is missing"

  # And the first home's key must survive the second home's creation unchanged.
  local reread
  reread=$(FM_HOME="$main" FM_DATA_OVERRIDE="$main/data" XDG_DATA_HOME="$xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 "$KEYPAIR" --public 2>/dev/null)
  [ "$reread" = "$main_key" ] \
    || fail "the second home's keypair overwrote the first home's key"

  pass "two homes sharing one XDG_DATA_HOME get separate keys"
}

test_rotation_replaces_the_key_in_whichever_store_holds_it() {
  # A rotation that clears one store and leaves the other is a rotation that
  # silently does not rotate: the next load finds the surviving key and re-prints
  # the same public key. On every host with no reachable keychain - which is this
  # suite, CI, and all of Linux - the key is in the fallback file, under a
  # digest-derived name no operator can delete by hand. So the check that matters
  # is behavioural: the public key must actually change.
  local home first second third keyfile stored combined code
  home=$(make_home rotate)
  keyfile=$(key_file "$home" "$home/xdg")

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  second=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$first" != "$second" ] \
    || fail "rotation re-printed the same public key ($first); the old key was never cleared"
  assert_grep "$second" "$home/data/buzz-keypair.public" \
    "rotation did not re-record the new public key"

  # The rotated-in key must be the one the publisher would now load.
  third=$(run_keypair "$home" --public 2>/dev/null) || fail "--public failed after rotation"
  [ "$third" = "$second" ] || fail "the stored key does not match the rotated public key"

  # And rotation must stay as silent about key material as creation is.
  combined=$(run_keypair "$home" --rotate 2>&1)
  stored=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$keyfile")
  [ -n "$stored" ] || fail "rotation left no usable key behind"
  assert_not_contains "$combined" "$stored" "the private key leaked into --rotate's output"

  run_keypair "$home" --rotate --public >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--rotate --public asks for two contradictory things"
  pass "rotation replaces the key in whichever store holds it"
}

test_public_flag_fails_before_a_keypair_exists() {
  local home output code
  home=$(make_home public-first)
  output=$(run_keypair "$home" --public 2>&1)
  code=$?
  expect_code 1 "$code" "--public with no keypair"
  assert_contains "$output" "no keypair exists yet" "--public gave an unhelpful error"
  pass "--public refuses before a keypair exists"
}

# --- (b) relay down --------------------------------------------------------

test_publish_with_relay_down_exits_zero_and_enqueues() {
  local home output code
  home=$(make_home relay-down)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Port 1 is reserved and nothing listens there, so this is a hard connection
  # refusal rather than a timeout.
  output=$(printf '%s' '{"schema":"fm-bearings.v1","omitted":["prs: not requested"]}' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?

  expect_code 0 "$code" "publish with the relay down must still exit 0"
  assert_contains "$output" "Firstmate is unaffected" \
    "publish did not log the fire-and-forget outcome"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "the signed event was not enqueued in the replay cache"
  pass "publish with the relay down exits 0 and enqueues the signed event"
}

test_publish_without_a_keypair_still_exits_zero() {
  local home code
  home=$(make_home no-key)
  printf '%s' '{"schema":"fm-bearings.v1"}' | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
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

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"must-stay-local"}' \
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

# --- (c) relay up ----------------------------------------------------------

test_publish_with_relay_up_delivers_and_lands() {
  local home relay output code content
  home=$(make_home relay-up)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --challenge)
EOF

  content='{"schema":"fm-bearings.v1","in_flight":[],"omitted":["prs: not requested (--include-prs)"]}'
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
  assert_contains "$readback" '"prs: not requested (--include-prs)"' \
    "the omitted[] disclosure did not survive publication verbatim"
  assert_contains "$readback" "$content" "the projection was altered in transit"

  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
  pass "publish with the relay up delivers, lands, and preserves omitted[] verbatim"
}

test_relay_switch_does_not_replay_another_relays_cache() {
  local home relay output readback stored_count
  home=$(make_home relay-switch)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Queue one projection for a relay that is down.
  printf '%s' '{"schema":"fm-bearings.v1","note":"relay-a-only"}' \
    | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "1" ] \
    || fail "relay A did not retain exactly one cached projection"

  # Switching to another relay must publish only the new projection. Relay A's
  # cached bytes remain queued for A and are invisible to B.
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"relay-b-only"}' \
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
  pass "switching relay hosts produces a cache miss for the prior relay"
}

# --- (d) reconnect replays the identical event id --------------------------

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
  printf '%s' '{"schema":"fm-bearings.v1","note":"mid-publish"}' \
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"after-reconnect"}' \
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"first"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "1" ] || fail "the first event was not cached"
  cached=$(find "$home/state/buzz-replay" -name '*.json' | head -1)
  stashed="$TMP_ROOT/stashed-$label-$(basename "$cached")"
  cp "$cached" "$stashed"

  # Drain it into a long-lived stub. The relay now holds this id.
  read -r STUB_PID relay <<EOF
$(start_stub --port "$port" "$@")
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"second"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "0" ] || fail "the cache did not drain against a live relay"

  # Put the very same bytes back, as an unacknowledged delivery would have. The
  # relay answers `duplicate:`, which must count as DELIVERED and evict the entry
  # rather than being retained and replayed forever.
  cp "$stashed" "$cached"
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"third"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"starve"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"late-challenge"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"past-window"}' \
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

test_permanent_rejection_is_not_replayed_forever() {
  local home relay
  home=$(make_home permanent)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --reject "invalid: malformed event")
EOF
  printf '%s' '{"schema":"fm-bearings.v1"}' | run_publish "$home" "$relay" >/dev/null 2>&1
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
  printf '%s' '{"schema":"fm-bearings.v1"}' | run_publish "$home" "$relay" >/dev/null 2>&1
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  [ "$(replay_count "$home")" = "1" ] \
    || fail "a retryable rejection must keep the event for a later replay"
  pass "a retryable rejection keeps the event cached"
}

# --- (e) the replay cache is capped ----------------------------------------

test_replay_cache_is_capped_at_100() {
  local home count i
  home=$(make_home cap)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  mkdir -p "$home/state/buzz-replay"

  # Seed 120 plausible cache entries with increasing timestamps, then publish
  # once against a dead relay: the prune must bring the cache to the cap,
  # keeping the newest and dropping the oldest.
  i=1
  while [ "$i" -le 120 ]; do
    printf '["EVENT",{"id":"%060d","created_at":%d}]' "$i" "$((1700000000 + i))" \
      > "$home/state/buzz-replay/$((1700000000 + i))-$(printf '%064d' "$i").json"
    i=$((i + 1))
  done
  [ "$(replay_count "$home")" = "120" ] || fail "cache seeding failed"

  printf '%s' '{"schema":"fm-bearings.v1"}' \
    | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1

  count=$(replay_count "$home")
  [ "$count" = "100" ] || fail "the replay cache is not capped at 100 (found $count)"

  # The newest must survive and the oldest must be gone.
  assert_present "$home/state/buzz-replay/$((1700000000 + 120))-$(printf '%064d' 120).json" \
    "the cap dropped a newer event instead of an older one"
  assert_absent "$home/state/buzz-replay/$((1700000000 + 1))-$(printf '%064d' 1).json" \
    "the cap did not drop the oldest event"
  pass "the replay cache is capped at 100, dropping oldest first"
}

test_an_interrupted_cache_write_is_swept_not_leaked() {
  # A `.json.tmp` is the half of the atomic cache write that a kill between the
  # write and the rename leaves behind. It matches neither the drain's filter nor
  # the cap's accounting, so unswept it is invisible AND immortal: never sent,
  # never counted, never removed, one leaked signed projection per interrupted
  # run. An in-flight write from a concurrent run must survive, though, so the
  # sweep is age-gated and this checks both halves.
  local home stale fresh count
  home=$(make_home orphan-tmp)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  mkdir -p "$home/state/buzz-replay"

  stale="$home/state/buzz-replay/1700000001-$(printf '%064d' 1).json.tmp"
  fresh="$home/state/buzz-replay/1700000002-$(printf '%064d' 2).json.tmp"
  printf '["EVENT",{"id":"%064d","created_at":1700000001}]' 1 > "$stale"
  printf '["EVENT",{"id":"%064d","created_at":1700000002}]' 2 > "$fresh"
  touch -t 202001010000 "$stale" || fail "could not age the stale temp file"

  printf '%s' '{"schema":"fm-bearings.v1","note":"orphan"}' \
    | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1

  assert_absent "$stale" "an interrupted cache write was left behind forever"
  assert_present "$fresh" "the sweep deleted a concurrent run's in-flight write"

  # And the surviving temp file must not be mistaken for a deliverable entry.
  count=$(replay_count "$home")
  [ "$count" = "1" ] \
    || fail "a .json.tmp was counted as a cache entry (found $count, expected only the new event)"
  pass "an interrupted cache write is swept, and a fresh one is not"
}

# --- the contract means TERMINATING, not just exiting 0 --------------------

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
  printf '%s' '{"schema":"fm-bearings.v1","note":"partial' >&9

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
  printf '%s' '{"schema":"fm-bearings.v1","note":"in-flight' >&8

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
  printf '%s' '{"schema":"fm-bearings.v1","note":"in-flight' >&8

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
  # A structural guard: the whole invariant rests on this script never dying on
  # an error and never exiting non-zero, and both are easy to reintroduce by
  # accident while editing.
  # Match an actual shell directive at the start of a line, not the header
  # comment that documents why the directive is banned.
  ! grep -nE '^[[:space:]]*set -[a-z]*e' "$PUBLISH" >/dev/null \
    || fail "bin/fm-buzz-publish.sh must not use set -e; it would break fire-and-forget"
  assert_grep 'exit 0' "$PUBLISH" "bin/fm-buzz-publish.sh lost its unconditional exit 0"
  [ "$(tail -1 "$PUBLISH")" = "exit 0" ] \
    || fail "bin/fm-buzz-publish.sh must end with an unconditional exit 0"
  pass "the fire-and-forget contract is structurally intact"
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

test_the_inspector_rejects_a_tampered_event() {
  # The inspector's whole job is answering "is the published projection legible AND
  # authentic?", and it is the only place a human looks for that answer. A relay
  # that serves a validly-signed id beside altered content passes a signature check
  # unchanged - the signature covers the id, not the bytes printed under it - so
  # only recomputing the id from what was served can catch it. This stub does
  # exactly that: it stores a real event and hands back other content with the id
  # and signature intact.
  local home relay clean tampered
  home=$(make_home tampered-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"authentic"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  clean=$(run_inspect "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$clean" "signature verified" \
    "an untouched event must read back as verified, or this test proves nothing"
  assert_contains "$clean" "authentic" "the projection did not read back"

  # Same home, same key, same channel - only the relay's honesty differs.
  read -r STUB_PID relay <<EOF
$(start_stub --tamper-on-read)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"authentic"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  tampered=$(run_inspect "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$tampered" "TAMPERED" \
    "the stub did not serve altered content, so the check under test was never reached"
  assert_not_contains "$tampered" "signature verified" \
    "altered content was reported as verified: the id is not being recomputed"
  assert_contains "$tampered" "INVALID" \
    "altered content was not reported as invalid"
  pass "the inspector refuses to call altered content verified"
}

test_an_anonymous_read_only_claims_privacy_when_the_relay_refuses() {
  # --anonymous is the only place this tool makes a SECURITY claim, and an empty
  # read is the weakest possible evidence for one: a wiped relay, a channel id
  # derived from another home, a publish that never landed, and a genuinely empty
  # channel are all indistinguishable from enforced privacy. Only the relay
  # refusing the subscription ON MEMBERSHIP GROUNDS separates them, so the
  # assurance is gated on that one refusal shape and everything else - including a
  # refusal for some other reason - must read INCONCLUSIVE.
  local home relay served refused unrelated untagged
  home=$(make_home anonymous-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Nothing published: an ordinary relay that serves the subscription and has
  # nothing to hand back. This is the ambiguous case.
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  served=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$served" "events:   0" "the empty read did not happen"
  assert_not_contains "$served" "refused:" \
    "the stub refused the subscription, so the ambiguous case was never reached"
  assert_contains "$served" "INCONCLUSIVE" \
    "an unrefused empty read must be reported as inconclusive"
  assert_not_contains "$served" "CORRECT" \
    "an unrefused empty read was reported as proof of privacy"
  assert_not_contains "$served" "That refusal is the assurance" \
    "the reassurance was printed without any refusal behind it"

  # A relay that enforces membership: same empty result, but it says why.
  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "restricted: not a channel member")
EOF
  refused=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$refused" "refused:  restricted: not a channel member" \
    "the relay's refusal reason did not reach the reader"
  assert_contains "$refused" "That refusal is the assurance" \
    "a refused subscription must still report the privacy assurance"
  assert_not_contains "$refused" "INCONCLUSIVE" \
    "a refused subscription is conclusive and must not be hedged"

  # A relay that refuses this read for a reason NIP-01 does not tag as being about
  # the reader. It carries no privacy conclusion, but the hedge must not swing the
  # other way either: the tool knows the reason is untagged, not that the relay
  # would have refused any other channel too.
  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "auth-required: we only serve authenticated readers")
EOF
  unrelated=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$unrelated" "auth-required: we only serve authenticated readers" \
    "a non-membership refusal must be reported in the relay's own words"
  assert_contains "$unrelated" "INCONCLUSIVE" \
    "a refusal that is not about membership must stay inconclusive"
  assert_not_contains "$unrelated" "That refusal is the assurance" \
    "a non-membership refusal was reported as proof of privacy"
  assert_not_contains "$unrelated" "never added to this private channel" \
    "a non-membership refusal was described as a membership refusal"
  assert_not_contains "$unrelated" "any reader asking for any channel" \
    "the hedge asserted a relay policy the refusal reason does not establish"

  # The same branch catches an UNTAGGED membership refusal, which is the case that
  # makes the strong hedge wrong: this really is the refusal the probe was looking
  # for, and the tool must say only that it cannot tell.
  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "not a member of this group")
EOF
  untagged=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$untagged" "not a member of this group" \
    "an untagged refusal must be reported in the relay's own words"
  assert_contains "$untagged" "INCONCLUSIVE" \
    "an untagged refusal cannot be read as a membership refusal"
  assert_contains "$untagged" "not machine-tagged as a membership refusal" \
    "the hedge must state the limit it actually knows"
  assert_not_contains "$untagged" "any reader asking for any channel" \
    "an untagged membership refusal was described as channel-independent"
  assert_not_contains "$untagged" "That refusal is the assurance" \
    "an untagged refusal was reported as proof of privacy"
  pass "an anonymous empty read claims privacy only on a membership refusal"
}

test_an_anonymous_read_that_returns_events_reports_the_breach() {
  # The one conclusive answer --anonymous can give, and it is the negative one: a
  # relay that serves the events to a stranger has no privacy to report. It has to
  # be stated, because every event below it prints `signature verified` and a
  # successful breach otherwise looks exactly like a successful legibility check.
  # This is not a hypothetical shape either - it is what the bundled stack does,
  # since it ships with membership enforcement off.
  local home relay breached
  home=$(make_home anonymous-readable)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"readable-by-a-stranger"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  breached=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$breached" "identity: ephemeral non-member" \
    "the read was not performed as a non-member, so nothing here is under test"
  assert_contains "$breached" "readable-by-a-stranger" \
    "the stranger did not actually receive the projection"
  assert_contains "$breached" \
    "The channel was readable by an identity that is not a member — this is a definite negative privacy result." \
    "a non-member read the private channel and the tool said nothing about it"
  assert_not_contains "$breached" "INCONCLUSIVE" \
    "a non-member reading the channel is conclusive, not inconclusive"
  pass "an anonymous read that returns events reports the breach"
}

test_no_firstmate_path_depends_on_buzz() {
  # Invariant: Buzz is additive. If any other Firstmate script, skill, workflow or
  # AGENTS.md instruction ever calls the adapter, a stopped relay could reach a
  # supervision path - which is precisely what must not happen.
  local callers
  callers=$(grep -rl 'fm-buzz' "$ROOT/bin" "$ROOT/tests" "$ROOT/.agents" \
    "$ROOT/.github" "$ROOT/AGENTS.md" 2>/dev/null \
    | grep -v '/fm-buzz-' || true)
  [ -z "$callers" ] \
    || fail "Buzz must stay off every Firstmate path, but it is referenced by:"$'\n'"$callers"
  pass "no Firstmate path depends on the Buzz adapter"
}

test_bip340_official_vectors
test_keypair_is_idempotent_and_never_prints_the_private_key
test_public_flag_fails_before_a_keypair_exists
test_rotation_replaces_the_key_in_whichever_store_holds_it
test_two_homes_sharing_one_xdg_get_separate_keys
test_publish_with_relay_down_exits_zero_and_enqueues
test_publish_without_a_keypair_still_exits_zero
test_non_loopback_env_relay_is_rejected_before_network
test_publish_with_relay_up_delivers_and_lands
test_relay_switch_does_not_replay_another_relays_cache
test_reconnect_replays_the_identical_event_id
test_replaying_a_known_event_is_deduped_and_evicted
test_an_unacknowledged_publish_does_not_starve_the_drain
test_a_late_auth_challenge_is_still_answered
test_a_challenge_past_the_handshake_window_still_lands_the_event
test_permanent_rejection_is_not_replayed_forever
test_retryable_rejection_is_kept
test_replay_cache_is_capped_at_100
test_an_interrupted_cache_write_is_swept_not_leaked
test_a_writer_that_never_closes_does_not_hang_the_publish
test_a_signalled_read_leaves_no_projection_in_temp
test_a_signalled_read_releases_the_callers_output
test_fire_and_forget_contract_is_intact
test_nothing_private_reaches_a_command_line
test_the_inspector_rejects_a_tampered_event
test_an_anonymous_read_only_claims_privacy_when_the_relay_refuses
test_an_anonymous_read_that_returns_events_reports_the_breach
test_no_firstmate_path_depends_on_buzz
