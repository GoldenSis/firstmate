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

make_fake_keychain_tools() {
  local tools="$TMP_ROOT/fake-keychain-tools"
  mkdir -p "$tools"
  cat > "$tools/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
  cat > "$tools/security" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
  find-generic-password)
    if [ -n "${FM_FAKE_SECURITY_STATE_FILE:-}" ]; then
      [ -f "$FM_FAKE_SECURITY_STATE_FILE" ] || exit 44
      cat "$FM_FAKE_SECURITY_STATE_FILE"
      exit 0
    fi
    case ${FM_FAKE_SECURITY_FIND:-not-found} in
      found) printf '%s\n' "${FM_FAKE_SECURITY_PRIVATE:-}"; exit 0 ;;
      not-found) exit 44 ;;
      error) exit 51 ;;
    esac
    ;;
  delete-generic-password)
    if [ -n "${FM_FAKE_SECURITY_STATE_FILE:-}" ]; then
      [ -f "$FM_FAKE_SECURITY_STATE_FILE" ] || exit 44
      rm -f "$FM_FAKE_SECURITY_STATE_FILE"
      exit 0
    fi
    case ${FM_FAKE_SECURITY_DELETE:-not-found} in
      success) exit 0 ;;
      not-found) exit 44 ;;
      error) exit 51 ;;
    esac
    ;;
  -i) exit 1 ;;
esac
exit 1
EOF
  chmod +x "$tools/uname" "$tools/security"
  printf '%s\n' "$tools"
}

make_forget_read_failure_tools() {
  local tools="$TMP_ROOT/forget-read-failure-tools"
  mkdir -p "$tools"
  cat > "$tools/grep" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$tools/grep"
  printf '%s\n' "$tools"
}

make_public_record_failure_tools() {
  local tools="$TMP_ROOT/public-record-failure-tools"
  mkdir -p "$tools"
  cat > "$tools/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${FM_FAIL_BUZZ_PUBLIC_MV:-0}" = "1" ]; then
  for arg in "$@"; do
    case $arg in
      */buzz-keypair.public) exit 1 ;;
    esac
  done
fi
exec /bin/mv "$@"
EOF
  chmod +x "$tools/mv"
  printf '%s\n' "$tools"
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

test_a_compromised_rotation_does_not_keep_the_retired_key() {
  # Retention rests on the retired key being one only this home ever held, and the
  # commonest reason to rotate breaks exactly that premise: a private half that may
  # have leaked is a key somebody else holds too, and the channel id is not a
  # secret, so that somebody can mint an event the probe would report as this
  # home's own leaked projection. --compromised is how a rotation says so: it
  # declines to record the outgoing key, and withdraws it if it is already there.
  local home first second third history code
  home=$(make_home rotate-compromised)
  history="$home/data/buzz-keypair.public-history"

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  second=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "compromised rotation failed"
  [ "$first" != "$second" ] \
    || fail "the compromised rotation re-printed the same public key; nothing was replaced"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$first" \
    "a compromised rotation kept the retired key in the recorded set"

  # Declining to retain has to mean the outgoing key is absent from the recorded
  # set afterwards, not merely that this run did not add it. A key an EARLIER
  # rotation retired is a different key and out of this flag's reach: see
  # test_forget_key_withdraws_an_already_retired_key for that one.
  printf '%s\n' "$second" >> "$history"
  third=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "second compromised rotation failed"
  [ "$third" != "$second" ] \
    || fail "the second compromised rotation did not replace the key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$second" \
    "a compromised rotation left an already-recorded copy of the retired key in place"

  # An ordinary rotation must still retain, or the flag would be describing the
  # default rather than an opt-out.
  assert_grep "$third" "$home/data/buzz-keypair.public" \
    "the compromised rotation did not record the new public key"
  run_keypair "$home" --rotate >/dev/null 2>&1 || fail "ordinary rotation failed"
  assert_grep "$third" "$history" \
    "an ordinary rotation stopped retaining the key it retired"

  run_keypair "$home" --compromised >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--compromised without --rotate describes nothing"
  pass "a compromised rotation does not keep the retired key"
}

test_rotation_stops_or_recovers_when_the_outgoing_private_key_is_unusable() {
  # data/buzz-keypair.public is a cache, not the authority. A half-written one
  # holds something that is not a key at all, and retaining that would leave a
  # history entry no reader can attribute while looking exactly like retention
  # that worked - the stored private half is what settles it. And when neither
  # source can name the outgoing key, the rotation must STOP: the very next step
  # forgets the private half, after which nothing can derive that key again.
  local home first second third history keyfile output code
  home=$(make_home rotate-unusable)
  history="$home/data/buzz-keypair.public-history"
  keyfile=$(key_file "$home" "$home/xdg")

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  printf 'deadbeefdeadbeef\n' > "$home/data/buzz-keypair.public"
  second=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$first" != "$second" ] || fail "rotation did not replace the key"
  assert_grep "$first" "$history" \
    "a truncated recorded file cost the rotation the key it was retiring"
  assert_no_grep "deadbeefdeadbeef" "$history" \
    "a truncated recorded file was recorded as though it were a key"

  printf '{"private_key": "unreadable"}\n' > "$keyfile"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "a rotation that cannot name its outgoing key"
  assert_contains "$output" "$keyfile" \
    "the rotation failed without naming the unreadable private key file"
  assert_grep "$first" "$history" \
    "a refused rotation still rewrote the recorded key set"
  assert_grep "$second" "$home/data/buzz-keypair.public" \
    "a refused rotation disturbed the recorded current public key"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "a compromised rotation with unreadable private material"
  assert_contains "$output" "$keyfile" \
    "the compromised recovery did not name the unreadable private key file"
  assert_contains "$output" "no outgoing public key will be retained" \
    "the compromised recovery did not diagnose its no-retention path"
  third=$(printf '%s\n' "$output" | tail -1)
  [ "$third" != "$second" ] || fail "compromised recovery did not replace the unreadable key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$second" \
    "compromised recovery retained the unreadable outgoing key"
  assert_grep "$first" "$history" \
    "compromised recovery disturbed an earlier uncompromised retired key"
  pass "rotation refuses or recovers explicitly when private material is unusable"
}

test_rotation_compares_the_recorded_key_with_stored_private_material() {
  local home other first mismatched history output recovered code
  home=$(make_home rotate-mismatch)
  other=$(make_home rotate-mismatch-other)
  history="$home/data/buzz-keypair.public-history"
  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  mismatched=$(run_keypair "$other" 2>/dev/null) || fail "second keypair creation failed"
  printf '%s\n' "$mismatched" > "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "a rotation whose recorded and derived public keys disagree"
  assert_contains "$output" "does not match the stored private key" \
    "the mismatch refusal did not identify the conflicting sources"
  assert_grep "$mismatched" "$home/data/buzz-keypair.public" \
    "the refused mismatch rotation changed the recorded key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$first" \
    "the refused mismatch rotation retained a key before validation completed"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "a compromised rotation whose key records disagree"
  assert_contains "$output" "does not match the stored private key" \
    "the compromised mismatch recovery did not diagnose the mismatch"
  assert_contains "$output" "no outgoing public key will be retained" \
    "the compromised mismatch recovery did not use the no-retention path"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$first" ] || fail "compromised mismatch recovery kept the stored key"
  [ "$recovered" != "$mismatched" ] || fail "compromised mismatch recovery adopted the bad record"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$first" \
    "compromised mismatch recovery retained the derived outgoing key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$mismatched" \
    "compromised mismatch recovery retained the mismatched recorded key"
  pass "rotation compares recorded and derived public keys before retiring either"
}

test_rotation_detects_and_cleans_up_divergent_stores() {
  local tools home keyfile keychain_state keychain_private keychain_public file_public
  local file_before history_before output recovered code
  tools=$(make_fake_keychain_tools)
  home=$(make_home rotate-divergent-stores)
  keyfile=$(key_file "$home" "$home/xdg")
  keychain_state="$home/keychain-private"
  keychain_private=0000000000000000000000000000000000000000000000000000000000000003
  keychain_public=f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9
  file_public=$(run_keypair "$home" 2>/dev/null) || fail "fallback keypair setup failed"
  printf '%s\n' "$keychain_private" > "$keychain_state"
  printf '%s\n%s\n' "$file_public" "$keychain_public" \
    > "$home/data/buzz-keypair.public-history"
  file_before=$(cat "$keyfile")
  history_before=$(cat "$home/data/buzz-keypair.public-history")

  output=$(PATH="$tools:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_FAKE_SECURITY_STATE_FILE="$keychain_state" "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "ordinary rotation with divergent private-key stores"
  assert_contains "$output" "$keychain_public" \
    "the divergence refusal did not identify the keychain public key"
  assert_contains "$output" "$file_public" \
    "the divergence refusal did not identify the fallback public key"
  [ "$(cat "$keychain_state")" = "$keychain_private" ] \
    || fail "ordinary divergence refusal changed the keychain private key"
  [ "$(cat "$keyfile")" = "$file_before" ] \
    || fail "ordinary divergence refusal changed the fallback private key"
  [ "$(cat "$home/data/buzz-keypair.public-history")" = "$history_before" ] \
    || fail "ordinary divergence refusal changed public-key history"
  assert_grep "$file_public" "$home/data/buzz-keypair.public" \
    "ordinary divergence refusal changed the current public record"

  output=$(PATH="$tools:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_FAKE_SECURITY_STATE_FILE="$keychain_state" "$KEYPAIR" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised rotation with divergent private-key stores"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$keychain_public" ] || fail "compromised divergence recovery reused the keychain identity"
  [ "$recovered" != "$file_public" ] || fail "compromised divergence recovery reused the fallback identity"
  assert_absent "$keychain_state" "compromised divergence recovery left the keychain private key"
  [ "$(cat "$keyfile")" != "$file_before" ] \
    || fail "compromised divergence recovery left the fallback private key unchanged"
  assert_not_contains "$(cat "$keyfile" 2>/dev/null)" "$keychain_private" \
    "compromised divergence recovery copied the old keychain key into the fallback store"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$keychain_public" \
    "compromised divergence recovery retained the keychain identity"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$file_public" \
    "compromised divergence recovery retained the fallback identity"
  assert_grep "$recovered" "$home/data/buzz-keypair.public" \
    "compromised divergence recovery did not record the replacement identity"
  pass "rotation refuses divergent stores or purges both through compromised recovery"
}

test_orphaned_public_record_requires_compromised_recovery() {
  local home orphan history keyfile output recovered code
  home=$(make_home rotate-orphan)
  history="$home/data/buzz-keypair.public-history"
  keyfile=$(key_file "$home" "$home/xdg")
  orphan=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  rm -f "$keyfile"
  printf '%s\n' "$orphan" > "$history"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "ordinary rotation with an orphaned public record"
  assert_contains "$output" "has no stored private key" \
    "ordinary rotation did not diagnose the inconsistent recorded-key state"
  assert_grep "$orphan" "$home/data/buzz-keypair.public" \
    "ordinary rotation removed the orphaned record instead of refusing"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default key creation with an orphaned public record"
  assert_contains "$output" "recover with --rotate --compromised" \
    "default key creation did not preserve the explicit orphan recovery path"
  assert_grep "$orphan" "$home/data/buzz-keypair.public" \
    "default key creation overwrote the orphaned public record"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised rotation with an orphaned public record"
  assert_contains "$output" "no outgoing public key will be retained" \
    "compromised orphan recovery did not identify its no-retention path"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$orphan" ] || fail "compromised orphan recovery reused the orphaned key"
  assert_grep "$recovered" "$home/data/buzz-keypair.public" \
    "compromised orphan recovery did not record the replacement key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$orphan" \
    "compromised orphan recovery retained the orphaned key"
  pass "orphaned public records require explicit compromised recovery"
}

test_forget_key_refuses_when_history_cannot_be_read() {
  local tools home retired history before output code
  tools=$(make_forget_read_failure_tools)
  home=$(make_home forget-key-read-error)
  history="$home/data/buzz-keypair.public-history"
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"
  run_keypair "$home" --rotate >/dev/null 2>&1 || fail "rotation fixture setup failed"
  before=$(cat "$history")

  output=$(PATH="$tools:$PATH" run_keypair "$home" --forget-key "$retired" 2>&1)
  code=$?
  expect_code 1 "$code" "--forget-key when public-key history cannot be read"
  assert_contains "$output" "could not read $history" \
    "--forget-key treated a history read error as an absent key"
  [ "$(cat "$history")" = "$before" ] || fail "failed --forget-key changed public-key history"
  pass "--forget-key refuses when public-key history cannot be read"
}

test_keychain_errors_refuse_rotation_without_minting_a_fallback_key() {
  local tools private public home lookup_home forced_home forced_public output code fallback
  tools=$(make_fake_keychain_tools)
  private=0000000000000000000000000000000000000000000000000000000000000003
  public=f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9

  home=$(make_home keychain-delete-error)
  printf '%s\n' "$public" > "$home/data/buzz-keypair.public"
  output=$(PATH="$tools:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_FAKE_SECURITY_FIND=found \
    FM_FAKE_SECURITY_PRIVATE="$private" FM_FAKE_SECURITY_DELETE=error \
    "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation when keychain deletion fails"
  assert_contains "$output" "could not verify removal of the old key" \
    "keychain deletion failure was mistaken for successful absence"
  fallback=$(key_file "$home" "$home/xdg")
  assert_absent "$fallback" "rotation minted a fallback key while the keychain entry remained"
  assert_grep "$public" "$home/data/buzz-keypair.public" \
    "failed keychain deletion disturbed the current public key record"

  lookup_home=$(make_home keychain-lookup-error)
  printf '%s\n' "$public" > "$lookup_home/data/buzz-keypair.public"
  output=$(PATH="$tools:$PATH" FM_HOME="$lookup_home" FM_DATA_OVERRIDE="$lookup_home/data" \
    XDG_DATA_HOME="$lookup_home/xdg" FM_FAKE_SECURITY_FIND=error \
    FM_FAKE_SECURITY_DELETE=not-found "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation when the keychain cannot be read"
  assert_contains "$output" "login keychain could not be read" \
    "keychain lookup failure was mistaken for an absent key"
  fallback=$(key_file "$lookup_home" "$lookup_home/xdg")
  assert_absent "$fallback" "lookup failure minted a fallback key that could shadow the keychain entry"

  forced_home=$(make_home force-file-keychain-error)
  forced_public=$(run_keypair "$forced_home" 2>/dev/null) || fail "forced-file keypair setup failed"
  output=$(PATH="$tools:$PATH" FM_HOME="$forced_home" FM_DATA_OVERRIDE="$forced_home/data" \
    XDG_DATA_HOME="$forced_home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_FAKE_SECURITY_FIND=error FM_FAKE_SECURITY_DELETE=not-found \
    "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "forced-file rotation when preferred-store absence is unverifiable"
  assert_contains "$output" "login keychain could not be read" \
    "forced-file rotation skipped inspection of the preferred keychain store"
  assert_grep "$forced_public" "$forced_home/data/buzz-keypair.public" \
    "failed forced-file rotation disturbed the current public key record"
  pass "keychain lookup and deletion errors refuse rotation without fallback minting"
}

test_public_record_failures_are_fatal_and_retryable() {
  local tools create_home create_file create_output create_private retry_private created code
  local rotate_home rotate_file old rotate_output rotated_private retry_rotated replacement
  tools=$(make_public_record_failure_tools)

  create_home=$(make_home public-record-create-failure)
  create_file=$(key_file "$create_home" "$create_home/xdg")
  create_output=$(PATH="$tools:$PATH" FM_FAIL_BUZZ_PUBLIC_MV=1 run_keypair "$create_home" 2>&1)
  code=$?
  expect_code 1 "$code" "key creation when the public record cannot be persisted"
  assert_contains "$create_output" "private key remains stored for a safe retry" \
    "creation did not diagnose its retryable public-record failure"
  assert_absent "$create_home/data/buzz-keypair.public" \
    "creation reported a failed public record but left one behind"
  create_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$create_file")
  created=$(PATH="$tools:$PATH" run_keypair "$create_home" 2>/dev/null) \
    || fail "creation retry did not repair the public record"
  retry_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$create_file")
  [ "$create_private" = "$retry_private" ] || fail "creation retry replaced retained private material"
  assert_grep "$created" "$create_home/data/buzz-keypair.public" \
    "creation retry did not persist the retained key's public record"

  rotate_home=$(make_home public-record-rotate-failure)
  rotate_file=$(key_file "$rotate_home" "$rotate_home/xdg")
  old=$(run_keypair "$rotate_home" 2>/dev/null) || fail "rotation fixture setup failed"
  rotate_output=$(PATH="$tools:$PATH" FM_FAIL_BUZZ_PUBLIC_MV=1 \
    run_keypair "$rotate_home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation when the replacement public record cannot be persisted"
  assert_contains "$rotate_output" "private key remains stored for a safe retry" \
    "rotation did not diagnose its retryable public-record failure"
  rotated_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$rotate_file")
  replacement=$(PATH="$tools:$PATH" run_keypair "$rotate_home" 2>/dev/null) \
    || fail "rotation retry did not repair the public record"
  retry_rotated=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$rotate_file")
  [ "$rotated_private" = "$retry_rotated" ] || fail "rotation retry replaced retained private material"
  [ "$replacement" != "$old" ] || fail "rotation failure did not retain the replacement private key"
  assert_grep "$old" "$rotate_home/data/buzz-keypair.public-history" \
    "failed public-record persistence lost the ordinarily retired key"
  pass "public record failures are fatal while retained private material makes retry safe"
}

test_key_record_targets_reject_non_files() {
  local fallback_home fallback output code public_home public_target history_home old history_target

  fallback_home=$(make_home fallback-directory-target)
  fallback=$(key_file "$fallback_home" "$fallback_home/xdg")
  mkdir -p "$fallback"
  output=$(
    XDG_DATA_HOME="$fallback_home/xdg"
    FM_BUZZ_FORCE_FILE_STORE=1
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-buzz-key-lib.sh"
    fm_buzz_key_store "$fallback_home" \
      0000000000000000000000000000000000000000000000000000000000000003
  )
  code=$?
  expect_code 1 "$code" "fallback storage with a directory target"
  [ -z "$output" ] || fail "fallback storage reported success for a directory target"
  [ -z "$(find "$fallback" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the fallback writer moved its temporary file into a directory target"

  public_home=$(make_home public-directory-symlink-target)
  run_keypair "$public_home" >/dev/null 2>&1 || fail "public target fixture setup failed"
  rm -f "$public_home/data/buzz-keypair.public"
  public_target="$public_home/data/public-target"
  mkdir "$public_target"
  ln -s "$(basename "$public_target")" "$public_home/data/buzz-keypair.public"
  output=$(run_keypair "$public_home" 2>&1)
  code=$?
  expect_code 1 "$code" "key creation with a public-record directory symlink"
  assert_contains "$output" "could not record" \
    "a public-record directory symlink was treated as a successful write"
  [ -z "$(find "$public_target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the public-record writer moved its temporary file through a directory symlink"

  history_home=$(make_home history-directory-symlink-target)
  old=$(run_keypair "$history_home" 2>/dev/null) || fail "history target fixture setup failed"
  history_target="$history_home/data/history-target"
  mkdir "$history_target"
  ln -s "$(basename "$history_target")" "$history_home/data/buzz-keypair.public-history"
  output=$(run_keypair "$history_home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a history directory symlink"
  assert_contains "$output" "history target" \
    "rotation did not diagnose the invalid public-key history target"
  [ "$(run_keypair "$history_home" --public 2>/dev/null)" = "$old" ] \
    || fail "rotation mutated the key before rejecting the history directory symlink"
  [ -z "$(find "$history_target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the history writer moved its temporary file through a directory symlink"
  pass "public, history, and fallback records reject non-file targets"
}

test_public_key_history_is_normalized_consistently() {
  local home history first first_upper second second_upper third
  home=$(make_home normalized-history)
  history="$home/data/buzz-keypair.public-history"
  first=$(run_keypair "$home" 2>/dev/null) || fail "normalized history fixture setup failed"
  first_upper=$(printf '%s' "$first" | tr 'a-f' 'A-F')
  printf '  %s  \r\n%s\nnot-a-key\n' "$first_upper" "$first" > "$history"

  second=$(run_keypair "$home" --rotate 2>/dev/null) || fail "normalized history rotation failed"
  [ "$(cat "$history")" = "$first" ] \
    || fail "ordinary rotation did not normalize and deduplicate public-key history"

  second_upper=$(printf '%s' "$second" | tr 'a-f' 'A-F')
  printf '\t%s\r\n %s \n' "$first_upper" "$second_upper" > "$history"
  third=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "normalized compromised rotation failed"
  [ "$third" != "$second" ] || fail "compromised rotation did not replace the current key"
  [ "$(cat "$history")" = "$first" ] \
    || fail "compromised rotation did not normalize history while purging the outgoing key"

  printf '  %s  \r\n' "$first_upper" > "$history"
  run_keypair "$home" --forget-key "$first" >/dev/null 2>&1 \
    || fail "--forget-key did not match a normalized history entry"
  assert_absent "$history" "--forget-key left a case- or whitespace-variant history entry trusted"
  pass "public-key history uses one normalization for retention, purge, and withdrawal"
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

test_malformed_projection_is_rejected_before_signing() {
  local home output code
  home=$(make_home malformed-projection)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  output=$(printf '%s' '{"schema":"fm-bearings.v1"' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 0 "$code" "malformed projection through the fire-and-forget wrapper"
  assert_contains "$output" "not one valid JSON value" \
    "malformed projection did not take the explicit rejection path"
  assert_not_contains "$output" "signed event" "malformed projection was signed"
  [ "$(replay_count "$home")" = "0" ] || fail "malformed projection entered the replay cache"
  pass "malformed projections are rejected before signing"
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

test_truthy_non_boolean_ok_is_not_accepted() {
  local home duplicate_home relay output
  home=$(make_home truthy-ok-permanent)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --truthy-ok --reject "invalid: malformed acknowledgement fixture")
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"truthy-ok"}' \
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"truthy-duplicate-first"}' \
    | run_publish "$duplicate_home" "$relay" >/dev/null 2>&1
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"truthy-duplicate-second"}' \
    | run_publish "$duplicate_home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "delivered=0 retained=2" \
    "a malformed OK field made a duplicate note count as delivery"
  [ "$(replay_count "$duplicate_home")" = "2" ] \
    || fail "a duplicate note evicted an event without a boolean acknowledgement"
  pass "relay notes are classified only with a boolean acknowledgement"
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

test_cache_limit_must_be_a_positive_integer() {
  local home invalid output code
  home=$(make_home invalid-cache-limit)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  for invalid in 0 -5 abc; do
    output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"invalid-limit"}' \
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
  local home relay output clock old
  home=$(make_home cache-limit-one)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  clock="$TMP_ROOT/fixed-buzz-clock.mjs"
  printf '%s\n' 'Date.now = () => 1700000000000;' > "$clock"
  mkdir -p "$home/state/buzz-replay"
  old="$home/state/buzz-replay/1700000000-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.json"
  printf '%s' '["EVENT",{}]' > "$old"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"limit-one"}' \
    | NODE_OPTIONS="--import=$clock" FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "delivered=1 retained=0 discarded=0 cleanup_failed=0" \
    "a same-second cache tie removed the just-signed event before delivery accounting"
  assert_absent "$old" "same-second pruning kept an older entry instead of the current event"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the cache-limit-one event remained after acknowledgement"
  pass "a cache limit of one protects the current event across same-second ties"
}

test_malformed_cache_names_are_discarded_or_accounted_for() {
  local home relay replay removable retained output
  home=$(make_home malformed-cache-names)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  replay="$home/state/buzz-replay"
  mkdir -p "$replay"
  removable="$replay/not-an-event.json"
  retained="$replay/still-not-an-event.json"
  printf '%s' '{"malformed":true}' > "$removable"
  mkdir "$retained"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"malformed-cache-name"}' \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "dropping invalid cache entry not-an-event.json" \
    "a malformed cache filename was silently ignored"
  assert_contains "$output" "could not drop invalid cache entry still-not-an-event.json" \
    "a failed malformed-entry cleanup was silently ignored"
  assert_contains "$output" "retained=1 discarded=1 cleanup_failed=1" \
    "malformed cache filenames were not truthfully accounted for"
  assert_absent "$removable" "a removable malformed cache entry survived cleanup"
  assert_present "$retained" "the failed-cleanup fixture disappeared unexpectedly"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "malformed cache entries escaped the configured cap"
  pass "malformed cache filenames are discarded or retained with truthful accounting"
}

test_cache_directory_stat_failures_are_accounted_for() {
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

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"stat-failure"}' \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "could not inspect cache path" \
    "a non-ENOENT cache child stat failure was silently ignored"
  assert_contains "$output" "uninspectable-relay" \
    "the cache child stat failure did not identify the affected path"
  assert_contains "$output" "delivered=1 retained=1 discarded=0 cleanup_failed=1" \
    "a cache child stat failure was omitted from retained or cleanup accounting"
  assert_contains "$output" "publish did not complete; Firstmate is unaffected" \
    "a cache child stat failure did not reach the fire-and-forget conversion"
  pass "cache directory stat failures remain visible in outcome accounting"
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

test_unreadable_cache_entry_is_retained_as_retryable() {
  local home relay cache_dir unreadable output
  home=$(make_home unreadable-cache)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"prime-cache"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  cache_dir=$(find "$home/state/buzz-replay" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$cache_dir" ] || fail "relay-specific cache directory was not created"
  unreadable="$cache_dir/1700000000-$(printf '%064d' 7).json"
  mkdir "$unreadable"

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"read-error"}' \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "could not read cache entry" \
    "non-ENOENT cache read failure was mistaken for concurrent deletion"
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"valid-frame"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"fresh-event"}' \
    | run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "dropping invalid cache entry" \
    "parseable corrupt cache entries were not diagnosed"
  assert_contains "$output" "delivered=1 retained=0 discarded=3 cleanup_failed=0" \
    "parseable corrupt cache entries were not truthfully discarded"
  assert_absent "$wrong_frame" "a cache frame whose filename disagreed with its event was replayed"
  assert_absent "$empty_frame" "an object-only cache entry was retained"
  assert_absent "$notice_frame" "a non-EVENT cache frame was retained"
  [ "$(replay_count "$home")" = "0" ] || fail "corrupt cache entries remained after cleanup"
  pass "cached replay validates complete EVENT frames and their filenames"
}

test_cache_prune_failures_are_reported_and_accounted_for() {
  local home relay replay first second output count
  home=$(make_home cache-prune-failure)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  replay="$home/state/buzz-replay"
  mkdir -p "$replay"
  first="$replay/1700000001-$(printf '%064d' 1).json"
  second="$replay/1700000002-$(printf '%064d' 2).json"
  mkdir "$first" "$second"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"prune-failure"}' \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$output" "could not prune cache entry" \
    "a non-ENOENT prune failure was silently ignored"
  assert_contains "$output" "cleanup_failed=2" \
    "prune failures were omitted from outcome accounting"
  assert_contains "$output" "publish did not complete; Firstmate is unaffected" \
    "cache cleanup failure did not reach the fire-and-forget conversion"
  count=$(replay_count "$home")
  [ "$count" = "2" ] || fail "the prune failure fixture changed unexpectedly (found $count entries)"
  pass "cache prune failures remain visible in cleanup outcome accounting"
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

test_invalid_stdin_timeouts_are_rejected_before_reading() {
  local home invalid fifo spool pid waited output code
  home=$(make_home invalid-stdin-timeout)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  for invalid in 0 -1 nope; do
    fifo="$TMP_ROOT/invalid-timeout-$invalid.fifo"
    spool="$TMP_ROOT/invalid-timeout-$invalid.out"
    rm -f "$fifo"
    mkfifo "$fifo" || fail "could not create invalid-timeout fifo"
    exec 7<>"$fifo"
    printf '%s' '{"schema":"fm-bearings.v1","note":"partial' >&7
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

test_an_anonymous_read_of_unverifiable_events_claims_no_breach() {
  # The accusation is only as good as the frames it rests on. A relay that serves
  # altered content is the same relay the verdict would be quoting, so events that
  # do not recompute to their own id - or that are not tagged for this channel -
  # cannot establish that a non-member read THIS channel. Same anti-overclaim rule
  # as the reassurance and the hedge, applied to the accusation.
  local home relay tampered
  home=$(make_home anonymous-tampered)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --tamper-on-read)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"readable-by-a-stranger"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  tampered=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$tampered" "TAMPERED" \
    "the stub did not serve altered content, so the check under test was never reached"
  assert_contains "$tampered" "INVALID" \
    "altered content was not reported as invalid"
  assert_not_contains "$tampered" \
    "The channel was readable by an identity that is not a member" \
    "a definite breach was declared over content the tool itself reports as forged"
  assert_contains "$tampered" "INCONCLUSIVE" \
    "unverifiable served events must be reported as inconclusive"
  assert_contains "$tampered" "served by relay but not" \
    "the served-but-unverifiable events were not reported separately"
  pass "an anonymous read of unverifiable events claims no breach"
}

test_malformed_relay_events_are_assessed_independently() {
  local home relay malformed code
  home=$(make_home malformed-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --malform-on-read)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"malformed-on-read"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  malformed=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  code=$?
  stop_stub "$STUB_PID"

  expect_code 0 "$code" "inspection of malformed relay events"
  assert_contains "$malformed" "events:   4" \
    "the stub did not serve every independently malformed event"
  assert_contains "$malformed" "malformed id" "a malformed id was not classified as invalid"
  assert_contains "$malformed" "malformed tags" "malformed tags were not classified as invalid"
  assert_contains "$malformed" "malformed created_at" \
    "a malformed timestamp was not classified as invalid"
  assert_contains "$malformed" "malformed content" \
    "malformed content was not classified as invalid"
  assert_contains "$malformed" "INCONCLUSIVE" \
    "malformed served events did not leave the privacy result inconclusive"
  assert_not_contains "$malformed" \
    "The channel was readable by an identity that is not a member" \
    "malformed events produced a definite privacy verdict"
  pass "malformed relay events are invalidated independently without aborting inspection"
}

test_wrong_kind_event_cannot_produce_a_privacy_breach_verdict() {
  local home relay inspected
  home=$(make_home wrong-kind-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub --wrong-kind-on-read)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"wrong-kind"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  inspected=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$inspected" "events:   1" \
    "stub did not serve the signed wrong-kind channel event"
  assert_contains "$inspected" "unexpected event kind" \
    "wrong-kind event was not classified as invalid"
  assert_contains "$inspected" "this home's publisher" \
    "wrong-kind fixture did not pass publisher attribution"
  assert_contains "$inspected" "INCONCLUSIVE" \
    "wrong-kind event did not leave the privacy result inconclusive"
  assert_not_contains "$inspected" \
    "The channel was readable by an identity that is not a member" \
    "wrong-kind event produced a definite negative privacy verdict"
  pass "wrong-kind events cannot produce a privacy-breach verdict"
}

test_an_anonymous_read_of_a_foreign_authors_event_claims_no_breach() {
  # id, signature and `h` tag are all satisfiable by a stranger: the channel id is
  # a digest of the home path, printed by this very tool and sent to the relay in
  # the filter, so anyone who can publish to the open loopback relay can mint a
  # keypair and sign a perfectly valid event tagged for this channel. Nothing about
  # that event says this home's projection leaked, so it must not trigger the
  # verdict. The publisher's PUBLIC key is the evidence that separates the two, and
  # bin/fm-buzz-keypair.sh records it exactly where an anonymous read can find it.
  local home other relay label foreign
  home=$(make_home anonymous-foreign)
  other=$(make_home anonymous-foreign-stranger)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  run_keypair "$other" >/dev/null 2>&1 || fail "stranger keypair setup failed"

  # The label the inspected home derives its channel from, resolved the same way
  # bin/fm-buzz-key-lib.sh resolves it.
  label=$(cd "$home" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  # A different home, a different key, aimed at this home's channel.
  printf '%s' '{"schema":"fm-bearings.v1","note":"planted-by-a-stranger"}' \
    | run_publish "$other" "$relay" --channel-label "$label" >/dev/null 2>&1
  foreign=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$foreign" "events:   1" \
    "the planted event was not served, so the check under test was never reached"
  assert_contains "$foreign" "signature verified" \
    "the planted event must verify, or it fails an earlier gate and proves nothing"
  assert_contains "$foreign" "channel   this channel" \
    "the planted event must carry this channel's h tag, or an earlier gate catches it"
  assert_contains "$foreign" "NOT this home's publisher" \
    "the foreign author was not reported"
  assert_not_contains "$foreign" \
    "The channel was readable by an identity that is not a member" \
    "a definite breach was declared over an event this home's publisher never wrote"
  assert_contains "$foreign" "INCONCLUSIVE" \
    "an event from a foreign author must be reported as inconclusive"
  pass "an anonymous read of a foreign author's event claims no breach"
}

test_a_rotated_home_still_recognises_its_own_leaked_events() {
  # Rotation mints a new key but changes neither the channel id (a digest of the
  # home path) nor the relay's stored events, so this home's pre-rotation
  # projections keep sitting on the relay signed by the retired key. Attributing
  # only the current key would make the probe answer INCONCLUSIVE over exactly the
  # leak it exists to catch - a false negative created by the home's own key
  # hygiene. The retired PUBLIC key is retained precisely so that cannot happen.
  local home relay retired retired_upper rotated leaked
  home=$(make_home rotated-breach)
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"published-before-rotation"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$rotated" != "$retired" ] || fail "rotation did not replace the key, so nothing here is under test"
  retired_upper=$(printf '%s' "$retired" | tr 'a-f' 'A-F')
  printf '  %s  \r\n' "$retired_upper" > "$home/data/buzz-keypair.public-history"
  leaked=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$(tr 'A-F' 'a-f' < "$home/data/buzz-keypair.public-history")" "$retired" \
    "rotation dropped the retired public key instead of retaining it"
  assert_contains "$leaked" "published-before-rotation" \
    "the pre-rotation event was not served, so the check under test was never reached"
  assert_contains "$leaked" "this home's publisher" \
    "an event signed by a retired key of this home was not attributed to it"
  assert_contains "$leaked" \
    "The channel was readable by an identity that is not a member — this is a definite negative privacy result." \
    "rotation blinded the probe to this home's own leaked content"
  assert_not_contains "$leaked" "INCONCLUSIVE" \
    "a leak of this home's own pre-rotation content is conclusive, not inconclusive"

  # The recorded file is the cheap source of the outgoing key, not the only one:
  # once it is gone the stored private half is the last thing that can name what
  # this home was publishing under, and rotation clears that. So a second rotation
  # with no recorded file must still retain the key it is retiring.
  rm -f "$home/data/buzz-keypair.public"
  run_keypair "$home" --rotate >/dev/null 2>&1 || fail "second rotation failed"
  assert_grep "$rotated" "$home/data/buzz-keypair.public-history" \
    "a rotation with no recorded public key lost the key it retired"
  assert_grep "$retired" "$home/data/buzz-keypair.public-history" \
    "a later rotation dropped an earlier retired key"
  pass "a rotated home still recognises its own leaked events"
}

test_forget_key_withdraws_an_already_retired_key() {
  # The case --compromised cannot reach. Every rotation mints a fresh random key,
  # so the key a rotation is retiring is never one an earlier rotation recorded:
  # an exposure that comes to light AFTER the rotation that retired the key has to
  # name the key it means. Once withdrawn, an event signed by that key is no
  # longer evidence of anything - anyone holding the leaked private half could
  # have minted it against a channel id that is not a secret - so the probe must
  # fall back to INCONCLUSIVE rather than report this home's own leak.
  local home relay retired rotated history withdrawn after code
  home=$(make_home forget-key)
  history="$home/data/buzz-keypair.public-history"
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"signed-by-the-leaked-key"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  assert_grep "$retired" "$history" \
    "the ordinary rotation did not retain the key the withdrawal is about"

  withdrawn=$(run_keypair "$home" --forget-key "$retired" 2>&1)
  code=$?
  expect_code 0 "$code" "--forget-key on a recorded key"
  assert_contains "$withdrawn" "no longer recorded" \
    "--forget-key withdrew the key without saying so"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$retired" \
    "--forget-key left the named key in the recorded set"
  assert_grep "$rotated" "$home/data/buzz-keypair.public" \
    "--forget-key disturbed this home's current key"

  after=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$after" "signed-by-the-leaked-key" \
    "the event was not served, so the check under test was never reached"
  assert_contains "$after" "NOT this home's publisher" \
    "an event signed by a withdrawn key was still attributed to this home"
  assert_not_contains "$after" \
    "The channel was readable by an identity that is not a member" \
    "a withdrawn key still carried the verdict it was withdrawn to stop carrying"
  assert_contains "$after" "INCONCLUSIVE" \
    "an event signed by a withdrawn key must be reported as inconclusive"

  # Naming a key that is not recorded changes nothing and says so, so a repeat run
  # is safe; naming this home's CURRENT key says that rotation is what retires it.
  run_keypair "$home" --forget-key "$retired" >/dev/null 2>&1
  code=$?
  expect_code 0 "$code" "--forget-key on a key that is not recorded"
  assert_contains "$(run_keypair "$home" --forget-key "$rotated" 2>&1)" \
    "CURRENT publishing key" \
    "--forget-key on this home's current key implied the key had been withdrawn"
  run_keypair "$home" --forget-key "not-a-key" >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--forget-key with a value that is not a public key"
  # A lost argument must be an error, not a silent fall through into minting.
  run_keypair "$home" --forget-key >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--forget-key with no key named"
  pass "--forget-key withdraws an already-retired key"
}

test_an_anonymous_read_of_a_foreign_channel_claims_no_verdict() {
  # --channel-label points the read at a channel derived from some other home's
  # label, and the only publishing keys on this disk are this home's own. No served
  # event can be attributed either way, so the conclusive answer is unreachable and
  # must not be printed - and the fix is to say so, not to go reading another
  # home's files.
  local home other relay label foreign
  home=$(make_home foreign-channel-reader)
  other=$(make_home foreign-channel-owner)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  run_keypair "$other" >/dev/null 2>&1 || fail "other home keypair setup failed"

  label=$(cd "$other" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"another-homes-projection"}' \
    | run_publish "$other" "$relay" >/dev/null 2>&1
  foreign=$(run_inspect "$home" "$relay" --anonymous --channel-label "$label" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$foreign" "events:   1" \
    "the other home's event was not served, so the check under test was never reached"
  assert_contains "$foreign" "signature verified" \
    "the served event must verify, or it fails an earlier gate and proves nothing"
  assert_not_contains "$foreign" \
    "The channel was readable by an identity that is not a member" \
    "a definite verdict was declared for a channel this home cannot attribute"
  assert_contains "$foreign" "INCONCLUSIVE" \
    "a channel not derived from this home must be reported as inconclusive"
  assert_contains "$foreign" \
    "cannot verify authorship for a channel not derived from this home" \
    "the reason the verdict is unreachable was not stated"
  assert_contains "$foreign" "unattributable (channel not derived from this home)" \
    "the served event was reported as if this home could judge its author"
  pass "an anonymous read of a foreign channel claims no verdict"
}

test_a_membership_refusal_for_an_empty_foreign_channel_is_inconclusive() {
  local home other relay label foreign
  home=$(make_home foreign-empty-reader)
  other=$(make_home foreign-empty-owner)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  label=$(cd "$other" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "restricted: not a channel member")
EOF
  foreign=$(run_inspect "$home" "$relay" --anonymous --channel-label "$label" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$foreign" "events:   0" "the empty foreign read did not occur"
  assert_contains "$foreign" "INCONCLUSIVE" \
    "a foreign channel received a positive privacy verdict"
  assert_contains "$foreign" "not derived from this home" \
    "the inspector did not explain why a foreign-channel refusal is inconclusive"
  assert_not_contains "$foreign" "That refusal is the assurance" \
    "a membership refusal reassured the reader about a foreign channel"
  pass "membership refusals for empty foreign channels remain inconclusive"
}

test_an_anonymous_read_of_this_homes_own_label_still_reaches_a_verdict() {
  # What rules the conclusive answer out is the channel belonging to another home,
  # not --channel-label being typed. Spelling this home's own resolved path out is
  # a natural way to check which channel id a label derives to, and it inspects
  # precisely this home's channel with precisely this home's keys on disk - so
  # deciding attributability from the flag's presence would throw the verdict away
  # over a real leak of this home's own content.
  local home relay label explicit
  home=$(make_home own-label-explicit)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Resolved the same way bin/fm-buzz-key-lib.sh resolves this home's own label.
  label=$(cd "$home" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"own-label-spelled-out"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  explicit=$(run_inspect "$home" "$relay" --anonymous --channel-label "$label" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$explicit" "own-label-spelled-out" \
    "the event was not served, so the check under test was never reached"
  assert_contains "$explicit" "this home's publisher" \
    "this home's own event was not attributed to it when its label was passed explicitly"
  assert_contains "$explicit" \
    "The channel was readable by an identity that is not a member — this is a definite negative privacy result." \
    "spelling out this home's own label suppressed the verdict over a real leak"
  assert_not_contains "$explicit" "INCONCLUSIVE" \
    "a leak of this home's own content is conclusive, not inconclusive"
  assert_not_contains "$explicit" "channel not derived from this home" \
    "this home's own label was treated as another home's"
  pass "an anonymous read of this home's own label still reaches a verdict"
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
test_a_compromised_rotation_does_not_keep_the_retired_key
test_rotation_stops_or_recovers_when_the_outgoing_private_key_is_unusable
test_rotation_compares_the_recorded_key_with_stored_private_material
test_rotation_detects_and_cleans_up_divergent_stores
test_orphaned_public_record_requires_compromised_recovery
test_forget_key_refuses_when_history_cannot_be_read
test_keychain_errors_refuse_rotation_without_minting_a_fallback_key
test_public_record_failures_are_fatal_and_retryable
test_key_record_targets_reject_non_files
test_public_key_history_is_normalized_consistently
test_two_homes_sharing_one_xdg_get_separate_keys
test_publish_with_relay_down_exits_zero_and_enqueues
test_malformed_projection_is_rejected_before_signing
test_refresh_preserves_the_snapshot_bytes_including_its_trailing_newline
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
test_truthy_non_boolean_ok_is_not_accepted
test_replay_cache_is_capped_at_100
test_cache_limit_must_be_a_positive_integer
test_cache_limit_one_preserves_the_pending_event
test_malformed_cache_names_are_discarded_or_accounted_for
test_cache_directory_stat_failures_are_accounted_for
test_an_interrupted_cache_write_is_swept_not_leaked
test_unreadable_cache_entry_is_retained_as_retryable
test_parseable_cache_corruption_is_discarded_without_replay
test_cache_prune_failures_are_reported_and_accounted_for
test_a_writer_that_never_closes_does_not_hang_the_publish
test_invalid_stdin_timeouts_are_rejected_before_reading
test_a_signalled_read_leaves_no_projection_in_temp
test_a_signalled_read_releases_the_callers_output
test_fire_and_forget_contract_is_intact
test_nothing_private_reaches_a_command_line
test_the_inspector_rejects_a_tampered_event
test_an_anonymous_read_only_claims_privacy_when_the_relay_refuses
test_an_anonymous_read_that_returns_events_reports_the_breach
test_an_anonymous_read_of_unverifiable_events_claims_no_breach
test_malformed_relay_events_are_assessed_independently
test_wrong_kind_event_cannot_produce_a_privacy_breach_verdict
test_an_anonymous_read_of_a_foreign_authors_event_claims_no_breach
test_a_rotated_home_still_recognises_its_own_leaked_events
test_forget_key_withdraws_an_already_retired_key
test_an_anonymous_read_of_a_foreign_channel_claims_no_verdict
test_a_membership_refusal_for_an_empty_foreign_channel_is_inconclusive
test_an_anonymous_read_of_this_homes_own_label_still_reaches_a_verdict
test_no_firstmate_path_depends_on_buzz
