#!/usr/bin/env bash
# Behavior tests for the loopback Buzz bearings publisher.
#
# Covers the five cases the milestone's exit gate names, plus the two properties
# everything else rests on: that the signing is really BIP-340 (checked against
# the official test vectors, not against our own verifier alone) and that the
# fire-and-forget contract has not been edited away.
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
  pass "signing matches the official BIP-340 vectors and rejects all 10 invalid ones"
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
  mode=$(stat -f '%Lp' "$keyfile" 2>/dev/null || stat -c '%a' "$keyfile")
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

  assert_contains "$readback" "1" "the relay did not store exactly one message"
  assert_contains "$readback" '"prs: not requested (--include-prs)"' \
    "the omitted[] disclosure did not survive publication verbatim"
  assert_contains "$readback" "$content" "the projection was altered in transit"

  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""
  pass "publish with the relay up delivers, lands, and preserves omitted[] verbatim"
}

# --- (d) reconnect replays the identical event id --------------------------

test_reconnect_replays_the_identical_event_id() {
  local home relay first_id after_kill stored
  home=$(make_home reconnect)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Kill mid-publish: the stub takes the event, then drops the socket before any
  # OK. The client cannot know whether it landed, so it must keep the event.
  read -r STUB_PID relay <<EOF
$(start_stub --drop-after-event)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"mid-publish"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  [ "$(replay_count "$home")" = "1" ] \
    || fail "an unacknowledged event must stay in the replay cache"
  first_id=$(find "$home/state/buzz-replay" -name '*.json' -exec basename {} \; | sed 's/^[0-9]*-//; s/\.json$//')

  # Reconnect to a fresh relay and publish again. The cached event must go out
  # under its ORIGINAL id - not a freshly signed one - so a relay that already
  # has it dedupes instead of storing a second copy.
  read -r STUB_PID relay <<EOF
$(start_stub)
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
  local home relay stashed cached output
  home=$(make_home "duplicate-$label")
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Publish against a dead relay purely to capture the exact signed bytes the
  # cache holds, then stash them.
  printf '%s' '{"schema":"fm-bearings.v1","note":"first"}' \
    | run_publish "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "1" ] || fail "the first event was not cached"
  cached=$(find "$home/state/buzz-replay" -name '*.json' | head -1)
  stashed="$TMP_ROOT/stashed-$label-$(basename "$cached")"
  cp "$cached" "$stashed"

  # Drain it into a long-lived stub. The relay now holds this id.
  read -r STUB_PID relay <<EOF
$(start_stub "$@")
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

test_the_private_key_reaches_no_command_line() {
  # A structural guard, for the same reason as the one above: an argv is
  # world-readable through the process table, and `--arg`/`-w <secret>` are the
  # obvious-looking spellings that put the key there. Both are one careless edit
  # away, and neither shows up in any behavioural assertion.
  # Match real shell lines only, never the header comments that explain why these
  # spellings are banned - the same distinction the fire-and-forget guard makes.
  local offenders
  offenders=$(grep -nE '^[[:space:]]*[^#]*--arg[[:space:]]+privateKey' \
    "$ROOT/bin/fm-buzz-publish.sh" "$ROOT/bin/fm-buzz-inspect.sh" || true)
  [ -z "$offenders" ] \
    || fail "the private key must reach jq through a file descriptor, not argv:"$'\n'"$offenders"

  offenders=$(grep -nE '^[[:space:]]*[^#]*security[[:space:]]+add-generic-password' \
    "$ROOT/bin/fm-buzz-key-lib.sh" || true)
  [ -z "$offenders" ] \
    || fail "the keychain write must go through 'security -i' so the secret is not in argv:"$'\n'"$offenders"

  pass "the private key reaches no command line"
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
test_two_homes_sharing_one_xdg_get_separate_keys
test_publish_with_relay_down_exits_zero_and_enqueues
test_publish_without_a_keypair_still_exits_zero
test_publish_with_relay_up_delivers_and_lands
test_reconnect_replays_the_identical_event_id
test_replaying_a_known_event_is_deduped_and_evicted
test_an_unacknowledged_publish_does_not_starve_the_drain
test_permanent_rejection_is_not_replayed_forever
test_retryable_rejection_is_kept
test_replay_cache_is_capped_at_100
test_a_writer_that_never_closes_does_not_hang_the_publish
test_fire_and_forget_contract_is_intact
test_the_private_key_reaches_no_command_line
test_no_firstmate_path_depends_on_buzz
