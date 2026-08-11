#!/usr/bin/env bash
# Behavior tests for the loopback Buzz bearings publisher.
#
# Covers key custody and rotation, byte-preserving signing, relay delivery and
# replay, cache and quarantine safety, anonymous privacy diagnostics, official
# BIP-340 vectors, and the fire-and-forget boundary.
#
# The default lane uses tests/fm-buzz-stub-relay.mjs and needs no Docker.
# FM_BUZZ_DOCKER_INTEGRATION=1 enables the opt-in Compose relay signer-lifecycle
# regression; docs/buzz-loopback-adapter.md records the milestone evidence.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEYPAIR="$ROOT/bin/fm-buzz-keypair.sh"
PUBLISH="$ROOT/bin/fm-buzz-publish.sh"
INSPECT="$ROOT/bin/fm-buzz-inspect.sh"
STUB="$ROOT/tests/fm-buzz-stub-relay.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-buzz.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

STUB_PID=""
ROTATION_GUARD_PID=""
ROTATION_GUARD_RELAY=""
BUZZ_DOCKER_PROJECT=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  [ -n "$ROTATION_GUARD_PID" ] && kill "$ROTATION_GUARD_PID" 2>/dev/null
  if [ -n "$BUZZ_DOCKER_PROJECT" ] && command -v docker >/dev/null 2>&1; then
    docker compose -p "$BUZZ_DOCKER_PROJECT" -f "$ROOT/docker-compose.buzz-loopback.yml" \
      down -v >/dev/null 2>&1 || true
  fi
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
    FM_BUZZ_RELAY="${FM_BUZZ_KEYPAIR_RELAY:-${ROTATION_GUARD_RELAY:-ws://localhost:3000}}" \
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

publish_signed_fixture() {  # <private-key> <relay> <channel> <note>
  local private_key=$1 relay=$2 channel=$3 note=$4
  printf '%s' "$private_key" | node -e '
    let privateKey = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { privateKey += chunk; });
    process.stdin.on("end", async () => {
      const { buildBearingsEvent, withRelay } = await import(process.argv[1]);
      const event = buildBearingsEvent(
        process.argv[3],
        JSON.stringify({ schema: "fm-bearings.v1", note: process.argv[4] }),
        privateKey,
      );
      await withRelay(process.argv[2], privateKey, 8000, async (api) => {
        const response = await api.publish(event);
        if (response.accepted !== true) throw new Error(response.message);
      });
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$channel" "$note"
}

publish_membership_fixture() {  # <relay> <channel> <member-pubkey>
  local relay=$1 channel=$2 member=$3
  printf '%s' "2" | node -e '
    let privateKey = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { privateKey += chunk; });
    process.stdin.on("end", async () => {
      privateKey = privateKey.trim().padStart(64, "0");
      const {
        nowSeconds,
        signEvent,
        withRelay,
      } = await import(process.argv[1]);
      const created = signEvent({
        created_at: nowSeconds(),
        kind: 9007,
        tags: [["h", process.argv[3]], ["name", "membership-fixture"], ["visibility", "private"]],
        content: "",
      }, privateKey);
      const added = signEvent({
        created_at: nowSeconds() + 1,
        kind: 9000,
        tags: [["h", process.argv[3]], ["p", process.argv[4]]],
        content: "",
      }, privateKey);
      await withRelay(process.argv[2], privateKey, 8000, async (api) => {
        for (const event of [created, added]) {
          const response = await api.publish(event);
          if (response.accepted !== true) throw new Error(response.message);
        }
      });
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$channel" "$member"
}

query_membership_signer() {  # <private-key> <relay> <channel>
  local private=$1 relay=$2 channel=$3
  # shellcheck disable=SC2016
  printf '%s' "$private" | node -e '
    let privateKey = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { privateKey += chunk; });
    process.stdin.on("end", async () => {
      const { queryCurrentChannelMembership } = await import(process.argv[1]);
      const membership = await queryCurrentChannelMembership(
        process.argv[2],
        privateKey.trim(),
        process.argv[3],
        15000,
      );
      process.stdout.write(`${membership.signerPubkey}\n`);
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay" "$channel"
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
  find "$home/state/buzz-replay" -path '*/_legacy-quarantine' -prune -o \
    -name '*.json' -print 2>/dev/null | wc -l | tr -d ' '
}

relay_cache_dir() {  # <home> <relay>
  local home=$1 relay=$2 digest
  digest=$(node -e '
    import(process.argv[1]).then(({ relayCacheKey }) => process.stdout.write(relayCacheKey(process.argv[2])));
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay") || return 1
  printf '%s/state/buzz-replay/%s\n' "$home" "$digest"
}

channel_id_for_label() {  # <label>
  node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$1"
}

default_channel_id() {  # <home>
  channel_id_for_label "$(cd "$1" && pwd -P)"
}

channel_cache_dir() {  # <home> <relay> <channel>
  printf '%s/%s\n' "$(relay_cache_dir "$1" "$2")" "$3"
}

seed_replay_event() {  # <home> <relay> <private-key> <created-at> <channel> <note>
  local home=$1 relay=$2 private=$3 created_at=$4 channel=$5 note=$6 directory
  directory=$(channel_cache_dir "$home" "$relay" "$channel") || return 1
  mkdir -p "$directory"
  # shellcheck disable=SC2016
  printf '%s' "$private" | node -e '
    const { writeFileSync } = require("node:fs");
    const path = require("node:path");
    let privateKey = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { privateKey += chunk; });
    process.stdin.on("end", async () => {
      const { KIND_STREAM_MESSAGE, signEvent } = await import(process.argv[1]);
      const event = signEvent({
        created_at: Number(process.argv[3]),
        kind: KIND_STREAM_MESSAGE,
        tags: [["h", process.argv[4]]],
        content: JSON.stringify({ schema: "fm-bearings.v1", note: process.argv[5] }),
      }, privateKey.trim());
      const file = path.join(process.argv[2], `${event.created_at}-${event.id}.json`);
      writeFileSync(file, JSON.stringify(["EVENT", event]), { mode: 0o600, flag: "wx" });
      process.stdout.write(`${file}\n`);
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$directory" "$created_at" "$channel" "$note"
}

# Ask the custody library itself where a home's key file is, rather than hardcoding
# the name here: the per-home derivation is the thing under test, and a test that
# recomputed it would agree with a broken library by construction.
key_file() {  # <home> <xdg>
  # shellcheck disable=SC2030
  ( XDG_DATA_HOME=$2 FM_BUZZ_FORCE_FILE_STORE=1
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-buzz-key-lib.sh"
    fm_buzz_key_fallback_file "$1" )
}

public_from_private() {  # <private-key>
  # shellcheck disable=SC2016
  printf '%s' "$1" | node -e '
    let privateKey = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { privateKey += chunk; });
    process.stdin.on("end", async () => {
      const { publicKeyFromPrivate } = await import(process.argv[1]);
      process.stdout.write(`${publicKeyFromPrivate(privateKey)}\n`);
    });
  ' "$ROOT/bin/fm-buzz-crypto.mjs"
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
  local tools="$TMP_ROOT/public-record-failure-tools" real_node
  mkdir -p "$tools"
  real_node=$(command -v node)
  cat > "$tools/node" <<EOF
#!/usr/bin/env bash
if [ "\${FM_FAIL_BUZZ_PUBLIC_MV:-0}" = "1" ]; then
  for arg in "\$@"; do
    case \$arg in
      */buzz-keypair.public) exit 1 ;;
    esac
  done
fi
if [ -n "\${FM_RACE_BUZZ_REPLACE_TARGET:-}" ]; then
  for arg in "\$@"; do
    if [ "\$arg" = "\$FM_RACE_BUZZ_REPLACE_TARGET" ]; then
      rm -f -- "\$FM_RACE_BUZZ_REPLACE_TARGET"
      mkdir "\$FM_RACE_BUZZ_REPLACE_TARGET"
      break
    fi
  done
fi
exec "$real_node" "\$@"
EOF
  chmod +x "$tools/node"
  printf '%s\n' "$tools"
}

make_delayed_derive_tools() {
  local tools="$TMP_ROOT/delayed-derive-tools" real_node
  mkdir -p "$tools"
  real_node=$(command -v node)
  cat > "$tools/node" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case \$arg in
    *publicKeyFromPrivate*)
      : > "\$FM_DELAY_BUZZ_DERIVE_READY"
      waited=0
      while [ ! -e "\$FM_DELAY_BUZZ_DERIVE_RELEASE" ] && [ "\$waited" -lt 1000 ]; do
        sleep 0.01
        waited=\$((waited + 1))
      done
      [ -e "\$FM_DELAY_BUZZ_DERIVE_RELEASE" ] || exit 70
      break
      ;;
  esac
done
exec "$real_node" "\$@"
EOF
  chmod +x "$tools/node"
  printf '%s\n' "$tools"
}

make_delayed_publish_tools() {
  local tools="$TMP_ROOT/delayed-publish-tools" real_node
  mkdir -p "$tools"
  real_node=$(command -v node)
  cat > "$tools/node" <<EOF
#!/usr/bin/env bash
delayed=0
for arg in "\$@"; do
  case \$arg in
    */fm-buzz-publish.mjs)
      delayed=1
      : > "\$FM_DELAY_BUZZ_PUBLISH_READY"
      waited=0
      while [ ! -e "\$FM_DELAY_BUZZ_PUBLISH_RELEASE" ] && [ "\$waited" -lt 1000 ]; do
        sleep 0.01
        waited=\$((waited + 1))
      done
      [ -e "\$FM_DELAY_BUZZ_PUBLISH_RELEASE" ] || exit 70
      break
      ;;
  esac
done
if [ "\$delayed" -eq 1 ] && [ -n "\${FM_DELAY_BUZZ_REMOVE_TARGETS:-}" ]; then
  "$real_node" "\$@"
  status=\$?
  rm -f -- "\$FM_DELAY_BUZZ_REMOVE_TARGETS"
  exit "\$status"
fi
exec "$real_node" "\$@"
EOF
  chmod +x "$tools/node"
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

test_rotation_refuses_or_quarantines_outgoing_pending_events() {
  local home other relay channel old old_private other_private old_file_one old_file_two other_file
  local keyfile private_before history_before output code rotated quarantine manifests
  home=$(make_home rotation-pending-cache)
  other=$(make_home rotation-pending-cache-other)
  relay="ws://127.0.0.1:1/pending-rotation"
  channel="11111111-1111-5111-8111-111111111111"
  old=$(run_keypair "$home" 2>/dev/null) || fail "pending-cache rotation keypair setup failed"
  run_keypair "$other" >/dev/null 2>&1 || fail "pending-cache other-author setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  old_private=$(jq -r '.private_key' "$keyfile")
  other_private=$(jq -r '.private_key' "$(key_file "$other" "$other/xdg")")
  old_file_one=$(seed_replay_event "$home" "$relay" "$old_private" 1700000100 "$channel" pending-one) \
    || fail "could not seed the first outgoing replay entry"
  old_file_two=$(seed_replay_event "$home" "$relay" "$old_private" 1700000101 "$channel" pending-two) \
    || fail "could not seed the second outgoing replay entry"
  other_file=$(seed_replay_event "$home" "$relay" "$other_private" 1700000102 "$channel" other-author) \
    || fail "could not seed the other-author replay entry"
  private_before=$(cat "$keyfile")
  history_before=$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with outgoing-authored pending replay entries"
  assert_contains "$output" "pending replay cache contains 2 outgoing-authored event(s)" \
    "rotation refusal did not report the exact pending-entry count"
  assert_contains "$output" "$old_file_one" "rotation refusal omitted the first blocking path"
  assert_contains "$output" "$old_file_two" "rotation refusal omitted the second blocking path"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "pending-cache refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "pending-cache refusal changed the stored private key"
  [ "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)" = "$history_before" ] \
    || fail "pending-cache refusal changed public-key history"
  assert_present "$old_file_one" "pending-cache refusal removed the first outgoing entry"
  assert_present "$old_file_two" "pending-cache refusal removed the second outgoing entry"
  assert_present "$other_file" "pending-cache refusal removed another publisher's entry"

  output=$(run_keypair "$home" --rotate --discard-pending-cache 2>&1)
  code=$?
  expect_code 0 "$code" "rotation with explicit pending-cache quarantine"
  assert_contains "$output" "quarantined 2 outgoing-authored pending replay event(s)" \
    "rotation override did not report the exact quarantined-entry count"
  rotated=$(printf '%s\n' "$output" | tail -1)
  [ "$rotated" != "$old" ] || fail "pending-cache override did not replace the publishing identity"
  assert_absent "$old_file_one" "pending-cache override left the first outgoing entry active"
  assert_absent "$old_file_two" "pending-cache override left the second outgoing entry active"
  assert_present "$other_file" "pending-cache override removed another publisher's entry"
  quarantine="$home/state/buzz-replay/_legacy-quarantine"
  manifests=$(find "$quarantine/manifests" -type f -name '*.json' -print)
  [ "$(printf '%s\n' "$manifests" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] \
    || fail "pending-cache override did not retain exactly two quarantine manifests"
  for manifest in $manifests; do
    jq -e --arg publisher "$old" \
      '.quarantine_reason == "pending-key-rotation" and .publisher_pubkey == $publisher' \
      "$manifest" >/dev/null \
      || fail "pending-cache quarantine manifest omitted its rotation provenance"
    assert_present "$quarantine/$(jq -r '.payload_reference' "$manifest")" \
      "pending-cache quarantine manifest referenced no retained payload"
  done
  pass "rotation refuses or explicitly quarantines outgoing pending replay entries"
}

test_rotation_refuses_an_existing_private_channel_before_mutation() {
  local home relay old channel resolved_home private_file private_before history_before output code readback
  home=$(make_home rotate-existing-private-channel)
  old=$(run_keypair "$home" 2>/dev/null) || fail "rotation membership fixture setup failed"
  private_file=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$private_file")
  history_before=$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"membership-must-survive"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  resolved_home=$(cd "$home" && pwd -P)
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$resolved_home") || fail "could not derive the rotation fixture channel"

  output=$(FM_BUZZ_KEYPAIR_RELAY="$relay" run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation of an identity owning an existing private channel"
  assert_contains "$output" "current membership on relay $relay, channel $channel" \
    "rotation refusal did not name the existing private-channel membership"
  assert_contains "$output" "Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity." \
    "rotation refusal omitted the required membership explanation"
  assert_contains "$output" "https://github.com/block/buzz/blob/main/ARCHITECTURE.md" \
    "rotation refusal omitted the Buzz architecture reference"
  assert_contains "$output" "https://github.com/block/buzz/blob/main/NOSTR.md" \
    "rotation refusal omitted the Nostr reference"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "rotation refusal changed the recorded public key"
  [ "$(cat "$private_file")" = "$private_before" ] \
    || fail "rotation refusal changed the stored private key"
  [ "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)" = "$history_before" ] \
    || fail "rotation refusal changed public-key history"
  readback=$(run_inspect "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"
  assert_contains "$readback" "membership-must-survive" \
    "rotation membership preflight changed the existing channel state"
  pass "rotation refuses an existing private channel before key mutation"
}

test_rotation_reports_every_membership_blocker() {
  local home old keyfile private_before relay normalized_relay targets channel_a channel_b
  local target_a target_b output code relay_instruction_count
  home=$(make_home aggregate-membership-blockers)
  old=$(run_keypair "$home" 2>/dev/null) || fail "aggregate-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel_a="31313131-4242-5353-8464-757575757575"
  channel_b="32323232-4343-5454-8565-767676767676"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel_a" "$old" \
    || fail "could not seed the first blocking membership"
  publish_membership_fixture "$relay" "$channel_b" "$old" \
    || fail "could not seed the second blocking membership"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the aggregate-membership relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      for (let index = 4; index < process.argv.length - 1; index += 2) {
        recordPublisherTarget(process.argv[3], {
          relay: process.argv[index],
          channel_id: process.argv[index + 1],
          publisher_pubkey: process.argv[process.argv.length - 1],
        });
      }
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$normalized_relay" "$channel_a" "$normalized_relay" "$channel_b" "$old" \
    || fail "could not seed aggregate-membership targets"
  target_a=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_a" '$4 == channel { print $1 }')
  target_b=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_b" '$4 == channel { print $1 }')

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with multiple blocking memberships"
  assert_contains "$output" "target $target_a has current membership on relay $normalized_relay, channel $channel_a" \
    "rotation refusal omitted the first blocking relay/channel pair"
  assert_contains "$output" "target $target_b has current membership on relay $normalized_relay, channel $channel_b" \
    "rotation refusal omitted the second blocking relay/channel pair"
  assert_contains "$output" "--forget-target $target_a" \
    "rotation refusal omitted the first target-retirement command"
  assert_contains "$output" "--forget-target $target_b" \
    "rotation refusal omitted the second target-retirement command"
  relay_instruction_count=$(printf '%s\n' "$output" \
    | grep -Fc -- "--forget-relay-identity $normalized_relay")
  [ "$relay_instruction_count" = "1" ] \
    || fail "rotation refusal did not deduplicate the shared relay-retirement command"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "aggregate membership refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "aggregate membership refusal changed the stored private key"
  pass "rotation reports every membership blocker and complete retirement sequence"
}

test_rotation_query_errors_report_every_target_on_the_endpoint() {
  local home other old other_public relay targets channel_a channel_b target_a target_b output code
  home=$(make_home aggregate-membership-query-errors)
  other=$(make_home aggregate-membership-query-errors-other)
  old=$(run_keypair "$home" 2>/dev/null) || fail "query-error keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "query-error alternate key setup failed"
  relay="ws://127.0.0.1:1/aggregate-query-error"
  channel_a="33333333-4444-5555-8666-777777777777"
  channel_b="34343434-4545-5656-8767-787878787878"
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[5], publisher_pubkey: process.argv[6],
      });
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[7], publisher_pubkey: process.argv[8],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$relay" "$channel_a" "$old" "$channel_b" "$other_public" \
    || fail "could not seed query-error retirement targets"
  target_a=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_a" '$4 == channel { print $1 }')
  target_b=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_b" '$4 == channel { print $1 }')

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with an unverifiable target endpoint"
  assert_contains "$output" "could not verify current membership for target $target_a" \
    "rotation did not report the membership query error"
  assert_contains "$output" "--forget-target $target_a" \
    "query-error recovery omitted the queried target"
  assert_contains "$output" "--forget-target $target_b" \
    "query-error recovery omitted another durable target on the affected endpoint"
  assert_contains "$output" "--forget-relay-identity $relay" \
    "query-error recovery omitted the affected relay identity"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "query-error retirement reporting changed the publishing identity"
  pass "membership query errors report every target needed to retire the endpoint"
}

test_publisher_target_overrides_are_recorded_and_guard_rotation() {
  local home relay label channel old keyfile private_before targets targets_before output code normalized_relay
  home=$(make_home tracked-rotation-target)
  old=$(run_keypair "$home" 2>/dev/null) || fail "tracked-target keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  label="non-default-private-channel"
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the tracked override channel"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"tracked-override"}' \
    | run_publish "$home" "$relay" --channel-label "$label" >/dev/null 2>&1
  targets="$home/data/buzz-publisher-targets.jsonl"
  assert_present "$targets" "publish did not create the publisher-target registry"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the tracked relay"
  jq -e \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    'select(.relay == $relay and .channel_id == $channel and .publisher_pubkey == $publisher)' \
    "$targets" >/dev/null \
    || fail "publish did not persist the normalized relay/channel/publisher tuple"
  targets_before=$(cat "$targets")

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with a tracked non-default private channel"
  assert_contains "$output" "channel $channel" \
    "rotation refusal did not name the tracked override channel"
  assert_contains "$output" "relay $normalized_relay" \
    "rotation refusal did not name the tracked override relay"
  assert_contains "$output" "Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity." \
    "tracked-target refusal omitted the M1 membership explanation"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "tracked-target refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "tracked-target refusal changed the private key"
  [ "$(cat "$targets")" = "$targets_before" ] \
    || fail "tracked-target refusal changed the target registry"
  pass "publisher target overrides are recorded and guard rotation"
}

test_publisher_target_updates_are_concurrent_and_fail_closed() {
  local home relay publisher first second targets output code
  home=$(make_home publisher-target-concurrency)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "publisher-target concurrency setup failed"
  targets="$home/data/buzz-publisher-targets.jsonl"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  (printf '%s' '{"schema":"fm-bearings.v1","note":"target-one"}' \
    | run_publish "$home" "$relay" --channel-label target-one >/dev/null 2>&1) &
  first=$!
  (printf '%s' '{"schema":"fm-bearings.v1","note":"target-two"}' \
    | run_publish "$home" "$relay" --channel-label target-two >/dev/null 2>&1) &
  second=$!
  wait "$first" || fail "first concurrent target publish failed"
  wait "$second" || fail "second concurrent target publish failed"
  stop_stub "$STUB_PID"
  [ "$(jq -s --arg publisher "$publisher" '[.[] | select(.publisher_pubkey == $publisher)] | length' "$targets")" = "2" ] \
    || fail "concurrent publisher-target updates lost or duplicated a tuple"

  printf '%s\n' '{"relay":"ws://localhost:3000"}' > "$targets"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a malformed publisher-target registry"
  assert_contains "$output" "could not validate $targets" \
    "malformed publisher-target state did not fail closed"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$publisher" ] \
    || fail "malformed publisher-target state allowed key mutation"

  : > "$targets"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with an empty publisher-target registry"
  assert_contains "$output" "empty or truncated" \
    "an empty publisher-target registry was treated as first use"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$publisher" ] \
    || fail "empty publisher-target state allowed key mutation"
  pass "publisher target updates serialize and malformed state fails closed"
}

test_forget_target_attests_exact_retirement() {
  local home other relay label channel old other_public targets normalized_relay other_channel
  local target_hex output code replacement
  home=$(make_home forget-publisher-target)
  other=$(make_home forget-publisher-target-other)
  old=$(run_keypair "$home" 2>/dev/null) || fail "forget-target keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "forget-target unrelated publisher setup failed"
  label="retired-private-channel"
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the retired target channel"
  other_channel="12121212-3434-5656-8787-909090909090"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"target-retirement"}' \
    | run_publish "$home" "$relay" --channel-label "$label" >/dev/null 2>&1
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the retired target relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4],
        channel_id: process.argv[5],
        publisher_pubkey: process.argv[6],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$normalized_relay" "$other_channel" "$other_public" \
    || fail "could not seed the unrelated publisher target"
  target_hex=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel" '$4 == channel { print $1 }')
  [ "${#target_hex}" = 64 ] || fail "the tracked target has no canonical target hex"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation before target retirement"
  assert_contains "$output" "target $target_hex" \
    "rotation refusal did not expose the exact target identifier"
  assert_contains "$output" "docker compose -f docker-compose.buzz-loopback.yml down -v" \
    "rotation refusal omitted the disposable-relay retirement step"
  assert_contains "$output" "--forget-target $target_hex" \
    "rotation refusal omitted its exact target-retirement command"
  assert_contains "$output" "--forget-relay-identity $normalized_relay" \
    "rotation refusal omitted its exact relay-identity retirement command"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "pre-retirement refusal changed the publishing identity"

  stop_stub "$STUB_PID"
  output=$(run_keypair "$home" --forget-target "$target_hex" 2>&1)
  code=$?
  expect_code 0 "$code" "exact target retirement after relay reset"
  assert_contains "$output" "forgotten target: $target_hex" \
    "target retirement did not confirm the exact record"
  assert_not_contains "$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets")" "$target_hex" \
    "target retirement left the selected record behind"
  assert_grep "$other_public" "$targets" \
    "target retirement removed an unrelated publisher target"

  replacement=$(run_keypair "$home" --rotate 2>/dev/null) \
    || fail "rotation did not proceed after exact target retirement"
  [ "$replacement" != "$old" ] || fail "post-retirement rotation kept the old identity"
  pass "exact target retirement unblocks rotation without dropping unrelated targets"
}

test_forget_relay_identity_requires_exact_target_retirement() {
  local home other old other_public relay normalized_relay port targets authorities
  local channel_a channel_b other_channel other_relay target_a target_b output code
  local first_private first_signer second_private second_signer other_signer
  home=$(make_home forget-relay-identity)
  other=$(make_home forget-relay-identity-other)
  old=$(run_keypair "$home" 2>/dev/null) || fail "relay-identity keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "relay-identity unrelated publisher setup failed"
  first_private=$(printf '%064d' 4)
  first_signer=$(public_from_private "$first_private") || fail "could not derive the first relay signer"
  second_private=$(printf '%064d' 5)
  second_signer=$(public_from_private "$second_private") || fail "could not derive the replacement relay signer"
  other_signer=$(public_from_private "$(printf '%064d' 6)") || fail "could not derive the unrelated relay signer"
  channel_a="13131313-2424-5353-8464-757575757575"
  channel_b="14141414-2525-5656-8787-989898989898"
  other_channel="15151515-2626-5757-8888-a9a9a9a9a9a9"
  other_relay="ws://127.0.0.1:65534/unrelated"
  read -r STUB_PID relay <<EOF
$(start_stub --membership-private-key "$first_private")
EOF
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the relay identity"
  other_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$other_relay") \
    || fail "could not normalize the unrelated relay identity"
  port=${relay##*:}
  publish_membership_fixture "$relay" "$channel_a" "$old" \
    || fail "could not seed the first retired channel"
  publish_membership_fixture "$relay" "$channel_b" "$old" \
    || fail "could not seed the second retired channel"
  targets="$home/data/buzz-publisher-targets.jsonl"
  authorities="$home/data/buzz-relay-authorities.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      const file = process.argv[3];
      for (let index = 4; index < process.argv.length; index += 3) {
        recordPublisherTarget(file, {
          relay: process.argv[index],
          channel_id: process.argv[index + 1],
          publisher_pubkey: process.argv[index + 2],
        });
      }
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$normalized_relay" "$channel_a" "$old" \
    "$normalized_relay" "$channel_b" "$old" \
    "$other_relay" "$other_channel" "$other_public" \
    || fail "could not seed relay-retirement targets"
  {
    jq -cn --arg relay "$normalized_relay" --arg channel "$channel_a" --arg signer "$first_signer" \
      '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}'
    jq -cn --arg relay "$normalized_relay" --arg channel "$channel_b" --arg signer "$first_signer" \
      '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}'
    jq -cn --arg relay "$other_relay" --arg channel "$other_channel" --arg signer "$other_signer" \
      '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}'
  } > "$authorities"
  target_a=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_a" '$4 == channel { print $1 }')
  target_b=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_b" '$4 == channel { print $1 }')

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation before relay retirement"
  assert_contains "$output" "docker compose -f docker-compose.buzz-loopback.yml down -v" \
    "rotation refusal named the wrong compose retirement command"
  assert_contains "$output" "--forget-target $target_a" \
    "rotation refusal omitted the blocking target selector"
  assert_contains "$output" "--forget-relay-identity $normalized_relay" \
    "rotation refusal omitted the blocking relay endpoint"

  run_keypair "$home" --forget-target "$target_a" >/dev/null 2>&1 \
    || fail "could not attest the first target retirement"
  [ "$(jq -s --arg relay "$normalized_relay" '[.[] | select(.relay == $relay)] | length' "$authorities")" = "2" ] \
    || fail "target retirement implicitly removed relay authority pins"
  output=$(run_keypair "$home" --forget-relay-identity "$normalized_relay" 2>&1)
  code=$?
  expect_code 1 "$code" "relay identity retirement with a remaining target"
  assert_contains "$output" "$target_b" \
    "relay identity retirement did not name the remaining target"
  [ "$(jq -s --arg relay "$normalized_relay" '[.[] | select(.relay == $relay)] | length' "$authorities")" = "2" ] \
    || fail "refused relay identity retirement changed authority pins"

  run_keypair "$home" --forget-target "$target_b" >/dev/null 2>&1 \
    || fail "could not attest the second target retirement"
  output=$(run_keypair "$home" --forget-relay-identity "$normalized_relay" 2>&1)
  code=$?
  expect_code 0 "$code" "relay identity retirement after every target"
  assert_contains "$output" "forgotten relay identity: $normalized_relay (2 authority record(s))" \
    "relay identity retirement did not report the exact endpoint and pin count"
  [ "$(jq -s --arg relay "$normalized_relay" '[.[] | select(.relay == $relay)] | length' "$authorities")" = "0" ] \
    || fail "relay identity retirement left an authority pin for the retired endpoint"
  jq -e --arg relay "$other_relay" --arg signer "$other_signer" \
    'select(.relay == $relay and .signer_pubkey == $signer)' "$authorities" >/dev/null \
    || fail "relay identity retirement removed an unrelated endpoint pin"
  assert_grep "$other_public" "$targets" \
    "relay identity retirement removed an unrelated publisher target"

  stop_stub "$STUB_PID"
  read -r STUB_PID relay <<EOF
$(start_stub --port "$port" --membership-private-key "$second_private")
EOF
  publish_membership_fixture "$relay" "$channel_a" "$old" \
    || fail "could not seed the recreated relay membership"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4],
        channel_id: process.argv[5],
        publisher_pubkey: process.argv[6],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$normalized_relay" "$channel_a" "$old" \
    || fail "could not record the recreated relay target"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation after recreated relay TOFU"
  assert_contains "$output" "current membership" \
    "the recreated relay did not reach the membership guard"
  jq -e --arg relay "$normalized_relay" --arg channel "$channel_a" --arg signer "$second_signer" \
    'select(.relay == $relay and .channel_id == $channel and .signer_pubkey == $signer)' \
    "$authorities" >/dev/null \
    || fail "the recreated relay did not pin its replacement signer"
  jq -e --arg relay "$other_relay" --arg signer "$other_signer" \
    'select(.relay == $relay and .signer_pubkey == $signer)' "$authorities" >/dev/null \
    || fail "re-pinning the recreated relay changed an unrelated endpoint pin"
  pass "relay identity retirement requires exact target retirement and permits TOFU re-pinning"
}

test_rotation_checks_authoritative_current_membership() {
  local home relay old channel keyfile private_before targets normalized_relay output code
  home=$(make_home current-membership-rotation)
  old=$(run_keypair "$home" 2>/dev/null) || fail "current-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="11111111-2222-5333-8444-555555555555"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel" "$old" \
    || fail "could not seed creator-independent current membership"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the membership relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation of a publisher added by another channel creator"
  assert_contains "$output" "relay $normalized_relay" \
    "current-membership refusal did not name the normalized relay"
  assert_contains "$output" "channel $channel" \
    "current-membership refusal did not name the channel"
  assert_contains "$output" "Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity." \
    "current-membership refusal omitted the required M1 explanation"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "current-membership refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "current-membership refusal changed the stored private key"
  [ "$(jq -s 'length' "$home/data/buzz-relay-authorities.jsonl")" = "1" ] \
    || fail "the first authoritative membership query did not pin its signer"
  pass "rotation checks current membership independently of channel creation"
}

test_rotation_fails_closed_on_unverifiable_membership() {
  local mode expected home relay old channel keyfile private_before targets normalized_relay output code
  for mode in --malform-membership --ambiguous-membership --empty-membership; do
    case $mode in
      --malform-membership) expected="malformed current membership state" ;;
      --ambiguous-membership) expected="ambiguous current membership state" ;;
      --empty-membership) expected="malformed current membership state" ;;
    esac
    home=$(make_home "membership-${mode#--}")
    old=$(run_keypair "$home" 2>/dev/null) || fail "unverifiable-membership keypair setup failed"
    keyfile=$(key_file "$home" "$home/xdg")
    private_before=$(cat "$keyfile")
    channel="22222222-3333-5444-8555-666666666666"
    read -r STUB_PID relay <<EOF
$(start_stub "$mode")
EOF
    publish_membership_fixture "$relay" "$channel" "$old" \
      || fail "could not seed unverifiable current membership"
    normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
      || fail "could not normalize the unverifiable-membership relay"
    targets="$home/data/buzz-publisher-targets.jsonl"
    jq -cn \
      --arg relay "$normalized_relay" \
      --arg channel "$channel" \
      --arg publisher "$old" \
      '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"

    output=$(run_keypair "$home" --rotate 2>&1)
    code=$?
    stop_stub "$STUB_PID"
    expect_code 1 "$code" "rotation with $expected"
    assert_contains "$output" "$expected" "rotation did not diagnose $expected"
    assert_contains "$output" "relay $normalized_relay, channel $channel" \
      "unverifiable-membership refusal did not name its target pair"
    [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
      || fail "unverifiable-membership refusal changed the recorded public key"
    [ "$(cat "$keyfile")" = "$private_before" ] \
      || fail "unverifiable-membership refusal changed the stored private key"
  done

  home=$(make_home membership-missing)
  old=$(run_keypair "$home" 2>/dev/null) || fail "missing-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="33333333-4444-5555-8666-777777777777"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the missing-membership relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with no current membership snapshot"
  assert_contains "$output" "no current membership state" \
    "rotation treated a missing membership snapshot as authoritative absence"
  assert_contains "$output" "relay $normalized_relay, channel $channel" \
    "missing-membership refusal did not name its target pair"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "missing-membership refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "missing-membership refusal changed the stored private key"
  pass "rotation fails closed on missing, empty, malformed, or ambiguous membership"
}

test_rotation_pins_and_verifies_relay_membership_authority() {
  local home relay old channel keyfile private_before targets authorities normalized_relay
  local expected_signer actual_private actual_signer output code strict_home strict_old
  home=$(make_home membership-authority-mismatch)
  old=$(run_keypair "$home" 2>/dev/null) || fail "membership-authority keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="44444444-5555-5666-8777-888888888888"
  actual_private=$(printf '%064d' 4)
  actual_signer=$(public_from_private "$actual_private") \
    || fail "could not derive the actual membership signer"
  expected_signer=$(public_from_private "$(printf '%064d' 5)") \
    || fail "could not derive the pinned membership signer"
  read -r STUB_PID relay <<EOF
$(start_stub --membership-private-key "$actual_private")
EOF
  publish_membership_fixture "$relay" "$channel" "$old" \
    || fail "could not seed membership-authority state"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the membership-authority relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  authorities="$home/data/buzz-relay-authorities.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg signer "$expected_signer" \
    '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}' > "$authorities"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with a changed relay membership signer"
  assert_contains "$output" "relay $normalized_relay, channel $channel" \
    "relay-authority mismatch did not name its target pair"
  assert_contains "$output" "relay membership authority mismatch" \
    "relay-authority mismatch was not diagnosed"
  assert_contains "$output" "expected $expected_signer, received $actual_signer" \
    "relay-authority mismatch did not identify both signers"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "relay-authority mismatch changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "relay-authority mismatch changed the stored private key"

  strict_home=$(make_home membership-authority-strict)
  strict_old=$(run_keypair "$strict_home" 2>/dev/null) \
    || fail "strict membership-authority keypair setup failed"
  channel="55555555-6666-5777-8888-999999999999"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel" "$strict_old" \
    || fail "could not seed strict membership-authority state"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the strict membership-authority relay"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$strict_old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' \
    > "$strict_home/data/buzz-publisher-targets.jsonl"
  output=$(FM_BUZZ_REQUIRE_PINNED_RELAY_AUTHORITY=1 run_keypair "$strict_home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "strict rotation without a pinned relay authority"
  assert_contains "$output" "relay membership authority is not pinned in strict mode" \
    "strict membership-authority mode trusted its first signer"
  [ "$(cat "$strict_home/data/buzz-keypair.public")" = "$strict_old" ] \
    || fail "strict unpinned-authority refusal changed the recorded public key"
  assert_absent "$strict_home/data/buzz-relay-authorities.jsonl" \
    "strict membership-authority mode recorded a first-use signer"
  pass "rotation pins and verifies relay membership authority"
}

test_empty_relay_authority_registry_fails_closed() {
  local home old keyfile private_before channel relay normalized_relay targets authorities output code
  home=$(make_home empty-relay-authority)
  old=$(run_keypair "$home" 2>/dev/null) || fail "empty-authority keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="77777777-8888-5999-8aaa-bbbbbbbbbbbb"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel" "$old" \
    || fail "could not seed empty-authority membership state"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the empty-authority relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  authorities="$home/data/buzz-relay-authorities.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  : > "$authorities"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with an empty relay-authority registry"
  assert_contains "$output" "empty or truncated" \
    "an empty relay-authority registry was treated as TOFU first use"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "empty relay-authority state allowed public-key mutation"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "empty relay-authority state allowed private-key mutation"
  pass "empty security registries are corrupt rather than first use"
}

test_rotation_stops_or_recovers_when_the_outgoing_private_key_is_unusable() {
  # data/buzz-keypair.public is a cache, not the authority. A half-written one
  # holds something that is not a key at all, and retaining that would leave a
  # history entry no reader can attribute while looking exactly like retention
  # that worked - the stored private half is what settles it. And when neither
  # source can name the outgoing key, the rotation must STOP: the very next step
  # forgets the private half, after which nothing can derive that key again.
  local home first second third history keyfile output code targets artifact unrelated
  local current_channel unrelated_channel current_relay unrelated_relay
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

  targets="$home/data/buzz-publisher-targets.jsonl"
  artifact="$home/data/buzz-compromised-unverifiable-pairs.jsonl"
  unrelated=$(public_from_private "$(printf '%064d' 9)") \
    || fail "could not derive the unrelated publisher fixture"
  current_channel="19191919-2020-5151-8282-939393939393"
  unrelated_channel="29292929-3030-5151-8282-949494949494"
  current_relay="ws://localhost:3000/current-compromised"
  unrelated_relay="ws://localhost:3000/unrelated-retired"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4],
        channel_id: process.argv[5],
        publisher_pubkey: process.argv[6],
      });
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[7],
        channel_id: process.argv[8],
        publisher_pubkey: process.argv[9],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$current_relay" "$current_channel" "$second" \
    "$unrelated_relay" "$unrelated_channel" "$unrelated" \
    || fail "could not seed scoped compromised-recovery targets"
  printf '%s\n' "$unrelated" >> "$history"
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
  assert_grep "$unrelated" "$history" \
    "compromised recovery purged an unrelated historical publisher"
  jq -e --arg publisher "$unrelated" 'select(.publisher_pubkey == $publisher)' "$targets" >/dev/null \
    || fail "compromised recovery retired an unrelated publisher target"
  if jq -e --arg publisher "$second" 'select(.publisher_pubkey == $publisher)' "$targets" >/dev/null; then
    fail "compromised recovery left the implicated publisher target active"
  fi
  jq -e --arg publisher "$second" 'select(.publisher_pubkey == $publisher)' "$artifact" >/dev/null \
    || fail "compromised recovery did not record the implicated unverifiable target"
  if jq -e --arg publisher "$unrelated" 'select(.publisher_pubkey == $publisher)' "$artifact" >/dev/null; then
    fail "compromised recovery recorded an unrelated publisher as unverifiable"
  fi
  pass "rotation refuses or recovers explicitly when private material is unusable"
}

test_compromised_orphan_recovery_records_unverifiable_memberships() {
  local home old keyfile targets artifact relay normalized_relay channel output code replacement
  home=$(make_home compromised-unverifiable-membership)
  old=$(run_keypair "$home" 2>/dev/null) || fail "unverifiable-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  targets="$home/data/buzz-publisher-targets.jsonl"
  artifact="$home/data/buzz-compromised-unverifiable-pairs.jsonl"
  relay="ws://localhost:3000/unverifiable"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the unverifiable-membership relay"
  channel="66666666-7777-5888-8999-aaaaaaaaaaaa"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  rm "$keyfile"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "plain rotation with an orphaned tracked identity"
  assert_contains "$output" "has no stored private key" \
    "plain rotation did not refuse the orphaned identity"
  assert_absent "$artifact" "plain rotation recorded a compromised-recovery artifact"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "plain orphan refusal changed the recorded identity"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised recovery with unverifiable tracked memberships"
  replacement=$(printf '%s\n' "$output" | tail -1)
  [ "$replacement" != "$old" ] || fail "compromised orphan recovery did not replace the identity"
  assert_contains "$output" "they may be stranded and are recorded in $artifact" \
    "compromised recovery omitted the unverifiable-membership warning"
  assert_contains "$output" "$normalized_relay" \
    "compromised recovery warning omitted the affected relay"
  assert_contains "$output" "$channel" \
    "compromised recovery warning omitted the affected channel"
  jq -e \
    --arg publisher "$old" \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    'select(
      .publisher_pubkey == $publisher and
      .relay == $relay and
      .channel_id == $channel and
      (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
      (.reason | contains("has no stored private key"))
    )' "$artifact" >/dev/null \
    || fail "compromised recovery artifact omitted canonical identity, pair, time, or reason"
  pass "compromised orphan recovery records every unverifiable tracked membership"
}

test_orphan_identity_evidence_requires_compromised_recovery() {
  local home relay old keyfile public_file targets cache_file cache_name targets_before cache_before
  local output code replacement artifact manifest history unrelated_history_key
  home=$(make_home orphan-identity-evidence)
  old=$(run_keypair "$home" 2>/dev/null) || fail "orphan-evidence keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  public_file="$home/data/buzz-keypair.public"
  targets="$home/data/buzz-publisher-targets.jsonl"
  relay="ws://127.0.0.1:1/orphan-evidence"
  printf '%s' '{"schema":"fm-bearings.v1","note":"orphan-evidence"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  cache_file=$(find "$home/state/buzz-replay" -type f -name '*.json' | head -1)
  assert_present "$cache_file" "orphan-evidence setup did not create a replay entry"
  cache_name=$(basename "$cache_file")
  targets_before=$(cat "$targets")
  cache_before=$(cat "$cache_file")
  rm "$keyfile" "$public_file"
  history="$home/data/buzz-keypair.public-history"
  unrelated_history_key=$(public_from_private "$(printf '%064d' 8)") \
    || fail "could not derive unrelated orphan-history fixture key"
  printf '%s\n%s\n' "$old" "$unrelated_history_key" > "$history"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with orphan identity evidence"
  assert_contains "$output" "orphan identity evidence exists" \
    "default ensure did not refuse orphan identity evidence"
  assert_contains "$output" "orphan publisher target records present" \
    "default ensure did not name orphan target evidence"
  assert_contains "$output" "$cache_name" \
    "default ensure did not name orphan replay evidence"
  [ "$(cat "$targets")" = "$targets_before" ] || fail "default ensure changed orphan target state"
  [ "$(cat "$cache_file")" = "$cache_before" ] || fail "default ensure changed orphan replay bytes"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "plain rotation with orphan identity evidence"
  assert_contains "$output" "orphan publisher target records are present" \
    "plain rotation did not refuse orphan target state"
  assert_contains "$output" "$cache_name" "plain rotation did not name orphan replay state"
  [ "$(cat "$targets")" = "$targets_before" ] || fail "plain rotation changed orphan target state"
  [ "$(cat "$cache_file")" = "$cache_before" ] || fail "plain rotation changed orphan replay bytes"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 1 "$code" "compromised orphan recovery without cache disposition"
  assert_contains "$output" "retry with --discard-pending-cache" \
    "compromised recovery bypassed the explicit pending-cache disposition"

  output=$(run_keypair "$home" --rotate --compromised --discard-pending-cache 2>&1)
  code=$?
  expect_code 0 "$code" "explicit compromised orphan recovery"
  replacement=$(printf '%s\n' "$output" | tail -1)
  [ "$replacement" != "$old" ] || fail "compromised orphan recovery reused the orphan identity"
  artifact="$home/data/buzz-compromised-unverifiable-pairs.jsonl"
  assert_present "$artifact" "compromised orphan recovery created no durable warning artifact"
  jq -e --arg publisher "$old" 'select(.publisher_pubkey == $publisher)' "$artifact" >/dev/null \
    || fail "compromised orphan recovery artifact omitted the orphan publisher"
  assert_absent "$targets" "compromised orphan recovery left its retired target active"
  assert_absent "$cache_file" "compromised orphan recovery left its replay entry active"
  manifest=$(grep -l 'pending-key-rotation' \
    "$home/state/buzz-replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "compromised orphan recovery did not quarantine pending replay evidence"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$old" \
    "compromised orphan recovery left the orphan publisher trusted in history"
  assert_contains "$(cat "$history" 2>/dev/null)" "$unrelated_history_key" \
    "compromised orphan recovery removed an unrelated historical key"
  assert_contains "$output" "they may be stranded and are recorded in $artifact" \
    "compromised orphan recovery omitted its stranded-pair warning"
  pass "orphan identity evidence requires explicit compromised recovery"
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
    FM_FAKE_SECURITY_STATE_FILE="$keychain_state" FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" \
    "$KEYPAIR" --rotate 2>&1)
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
    FM_FAKE_SECURITY_STATE_FILE="$keychain_state" FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" \
    "$KEYPAIR" --rotate --compromised 2>&1)
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
    FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" "$KEYPAIR" --rotate 2>&1)
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
    FM_FAKE_SECURITY_DELETE=not-found FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" \
    "$KEYPAIR" --rotate 2>&1)
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
    FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" "$KEYPAIR" --rotate 2>&1)
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
  [ "$(cat "$rotate_home/data/buzz-keypair.public")" = "$old" ] \
    || fail "failed rotation removed the last recoverable public identity record"
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
    # shellcheck disable=SC2031
    export XDG_DATA_HOME="$fallback_home/xdg" FM_BUZZ_FORCE_FILE_STORE=1
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

test_key_record_replace_is_exact_destination() {
  local tools home target output code
  tools=$(make_public_record_failure_tools)
  home=$(make_home exact-key-record-replace)
  target="$home/data/buzz-keypair.public"

  output=$(PATH="$tools:$PATH" FM_RACE_BUZZ_REPLACE_TARGET="$target" \
    run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "public record replacement raced by a directory target"
  assert_contains "$output" "could not record" \
    "a directory race was treated as successful public-record persistence"
  [ -d "$target" ] || fail "the exact-destination race fixture was unexpectedly replaced"
  [ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "record replacement redirected its temporary file inside the raced directory"
  pass "key record replacement cannot be redirected by a directory race"
}

test_keypair_transactions_are_serialized_per_home() {
  local home ready output holder worker waited current lock
  home=$(make_home serialized-keypair)
  ready="$home/key-lock-ready"
  output="$home/keypair-output"
  lock=$(bash -c '. "$1"; fm_buzz_key_transaction_lock "$2"' \
    _ "$ROOT/bin/fm-buzz-key-lib.sh" "$home/data") \
    || fail "could not resolve the shared key transaction lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    sleep 1
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$ready" &
  holder=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "the keypair lock fixture did not acquire its lock"

  run_keypair "$home" > "$output" 2>&1 &
  worker=$!
  sleep 0.1
  kill -0 "$worker" 2>/dev/null \
    || fail "keypair creation did not wait for the active per-home transaction"
  assert_absent "$home/data/buzz-keypair.public" \
    "keypair creation mutated public state before acquiring the transaction lock"

  wait "$holder" || fail "the keypair lock fixture failed"
  wait "$worker" || fail "serialized keypair creation failed"
  current=$(run_keypair "$home" --public 2>/dev/null) || fail "serialized keypair was unreadable"
  [ "$(tail -1 "$output")" = "$current" ] \
    || fail "serialized keypair output disagrees with its recorded identity"
  ! grep -F '.buzz-keypair.lock' "$ROOT/bin/fm-buzz-keypair.sh" "$ROOT/bin/fm-buzz-publish.sh" >/dev/null \
    || fail "a key transaction caller duplicated the lock-path contract"
  pass "keypair ensure, rotation, and withdrawal share one home transaction lock"
}

test_public_read_cannot_restore_a_concurrently_retired_identity() {
  local home tools ready release output reader waited old rotated observed recorded
  home=$(make_home concurrent-public-read)
  tools=$(make_delayed_derive_tools)
  ready="$home/public-derive-ready"
  release="$home/public-derive-release"
  output="$home/public-output"
  old=$(run_keypair "$home" 2>/dev/null) || fail "concurrent public-read fixture setup failed"

  (PATH="$tools:$PATH" FM_DELAY_BUZZ_DERIVE_READY="$ready" \
    FM_DELAY_BUZZ_DERIVE_RELEASE="$release" run_keypair "$home" --public > "$output" 2>&1) &
  reader=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || {
    kill "$reader" 2>/dev/null
    fail "the public read did not pause after loading the outgoing key"
  }

  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || {
    : > "$release"
    wait "$reader" 2>/dev/null
    fail "rotation failed while the public read was paused"
  }
  : > "$release"
  wait "$reader" || fail "the concurrent public read failed"

  observed=$(tail -1 "$output")
  recorded=$(cat "$home/data/buzz-keypair.public")
  [ "$observed" = "$old" ] || fail "the paused public read did not observe the outgoing identity"
  [ "$recorded" = "$rotated" ] \
    || fail "a read-only --public call restored the concurrently retired identity"
  pass "--public cannot rewrite a public record after concurrent rotation"
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

test_publisher_target_is_recorded_only_after_cache() {
  local home replay outside output code
  home=$(make_home target-after-cache)
  run_keypair "$home" >/dev/null 2>&1 || fail "target-after-cache keypair setup failed"
  replay="$home/state/buzz-replay"
  outside="$home/outside-quarantine"
  mkdir -p "$replay" "$outside"
  ln -s "$outside" "$replay/_legacy-quarantine" \
    || fail "could not create the cache-failure fixture"

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"cache-must-precede-target"}' \
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"cached-one"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  printf '%s' '{"schema":"fm-bearings.v1","note":"cached-two"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "2" ] || fail "cache-cap target-failure fixture did not seed two entries"
  targets="$home/data/buzz-publisher-targets.jsonl"
  printf '%s\n' '{"relay":"ws://localhost:3000"}' > "$targets"

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"current-before-target-error"}' \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" 2>&1)
  code=$?
  expect_code 0 "$code" "target-registry failure through the fire-and-forget wrapper"
  assert_contains "$output" "publisher target registry" \
    "the malformed target registry did not stop target recording"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "a target-registry failure bypassed the replay cache cap"
  pass "cache pruning precedes fallible publisher-target recording"
}

test_replayed_events_are_tracked_before_delivery() {
  local home other relay channel other_private other_public old_file preload output targets readback
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
  cat > "$preload" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");
const { syncBuiltinESMExports } = require("node:module");
const originalRenameSync = fs.renameSync;
let replacements = 0;
fs.renameSync = function guardedRenameSync(source, destination, ...args) {
  if (path.resolve(String(destination)) === path.resolve(process.env.FM_TEST_TARGETS_FILE)) {
    replacements += 1;
    if (replacements === 2) {
      const error = new Error("simulated replay target tracking failure");
      error.code = "EACCES";
      throw error;
    }
  }
  return originalRenameSync.call(fs, source, destination, ...args);
};
syncBuiltinESMExports();
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"replay-current"}' \
    | NODE_OPTIONS="--require=$preload" FM_TEST_TARGETS_FILE="$home/data/buzz-publisher-targets.jsonl" \
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

test_credential_bearing_relays_are_rejected_before_signing_or_caching() {
  local home relay output code
  home=$(make_home relay-credentials)
  run_keypair "$home" >/dev/null 2>&1 || fail "credential-relay keypair setup failed"
  for relay in 'ws://operator@127.0.0.1:1' 'ws://operator:secret@127.0.0.1:1'; do
    output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"no-credential-relay"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"endpoint-migration-b"}' \
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"same-endpoint-a-one"}' \
    | run_publish "$home" "$relay" --channel-label same-endpoint-a >/dev/null 2>&1
  printf '%s' '{"schema":"fm-bearings.v1","note":"same-endpoint-a-two"}' \
    | run_publish "$home" "$relay" --channel-label same-endpoint-a >/dev/null 2>&1
  directory_a=$(channel_cache_dir "$home" "$relay" "$channel_a")
  [ "$(find "$directory_a" -type f -name '*.json' | wc -l | tr -d ' ')" = "2" ] \
    || fail "channel A did not retain two isolated replay entries"
  before=$(find "$directory_a" -type f -name '*.json' -print0 | sort -z | xargs -0 shasum -a 256)

  read -r STUB_PID relay <<EOF
$(start_stub --port "$port")
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"same-endpoint-b"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"fresh-after-legacy"}' \
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
  second=$(printf '%s' '{"schema":"fm-bearings.v1","note":"quarantine-retry"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"claim-before-read"}' \
    | run_publish "$home" "$relay" 2>&1)
  wait "$writer" || fail "legacy in-place writer fixture failed"
  assert_present "$legacy_file" \
    "a newer legacy entry created after the staging rename was deleted"
  [ "$(cat "$legacy_file")" = "legacy-new-bytes" ] \
    || fail "legacy quarantine changed the newer source bytes"
  payloads=$(grep -rl 'legacy-old-bytes' "$quarantine/payloads" 2>/dev/null | wc -l | tr -d ' ')
  [ "$payloads" = "1" ] || fail "the atomically claimed legacy bytes were not quarantined once"

  printf '%s' '{"schema":"fm-bearings.v1","note":"claim-retry"}' \
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
  printf '%s' '{"schema":"fm-bearings.v1","note":"open-writer-quarantine"}' \
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
      birthtime_ms: metadata.birthtimeMs,
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

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"recover-link-stable-quarantine"}' \
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
  local home relay replay quarantine payload content digest token temporary final
  home=$(make_home quarantine-temporary-recovery)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine temporary keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$quarantine/staging" "$quarantine/corrupt"
  payload="$quarantine/payloads/recovered-payload.json"
  content='legacy-payload-for-temporary-recovery'
  printf '%s' "$content" > "$payload"
  digest=$(node -e '
    const { createHash } = require("node:crypto");
    process.stdout.write(createHash("sha256").update(process.argv[1]).digest("hex"));
  ' "$content")
  token=$(printf '%064d' 6)
  temporary="$quarantine/manifests/$token.json.4242.tmp"
  final="$quarantine/manifests/$token.json"
  jq -n \
    --arg digest "$digest" \
    '{original_path:"localhost%3A3000/legacy.json",
      legacy_host:"localhost:3000",
      original_timestamps:{atime_ms:1,mtime_ms:2,ctime_ms:3,birthtime_ms:4},
      content_sha256:$digest,
      quarantine_timestamp:"2026-08-11T00:00:00.000Z",
      payload_reference:"payloads/recovered-payload.json"}' > "$temporary"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"recover-manifest-temp"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  stop_stub "$STUB_PID"
  assert_present "$final" "quarantine did not recover the atomic manifest temporary"
  assert_absent "$temporary" "quarantine left the recovered manifest temporary behind"
  [ "$(jq -r '.payload_reference' "$final")" = "payloads/recovered-payload.json" ] \
    || fail "recovered quarantine manifest changed its payload reference"
  pass "quarantine recovers current and historical atomic temporary names"
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

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"token-validation"}' \
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

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"invalid-quarantine-temp"}' \
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
  second=$(printf '%s' '{"schema":"fm-bearings.v1","note":"recover-invalid-residue"}' \
    | run_publish "$home" "ws://127.0.0.1:1" 2>&1)
  manifest=$(grep -l 'invalid-quarantine-recovery-residue' \
    "$quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "an interrupted residue transaction was not recovered"
  assert_present "$residue" "residue recovery discarded the retained invalid bytes"
  assert_contains "$second" "recovered invalid recovery residue" \
    "residue recovery did not report deterministic completion"
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
const originalLinkSync = fs.linkSync;
fs.linkSync = function guardedLinkSync(source, destination, ...args) {
  if (
    String(destination).endsWith(".invalid") &&
    !fs.existsSync(process.env.FM_TEST_RESIDUE_SENTINEL)
  ) {
    originalLinkSync.call(fs, source, destination, ...args);
    fs.writeFileSync(process.env.FM_TEST_RESIDUE_SENTINEL, "interrupted\n");
    const error = new Error("simulated residue hard-link interruption");
    error.code = "EACCES";
    throw error;
  }
  return originalLinkSync.call(fs, source, destination, ...args);
};
syncBuiltinESMExports();
EOF
  first=$(printf '%s' '{"schema":"fm-bearings.v1","note":"residue-retry-first"}' \
    | NODE_OPTIONS="--import=$preload" FM_TEST_RESIDUE_SENTINEL="$sentinel" \
      run_publish "$home" "ws://127.0.0.1:1/residue-retry" 2>&1)
  assert_present "$sentinel" "the residue retry fixture did not interrupt the hard-link claim"
  assert_present "$temporary" "the interrupted residue claim unexpectedly removed its source"
  assert_contains "$first" "simulated residue hard-link interruption" \
    "the interrupted residue claim was not accounted for"

  second=$(printf '%s' '{"schema":"fm-bearings.v1","note":"residue-retry-second"}' \
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
  local home replay quarantine manifest preload relay output
  home=$(make_home quarantine-manifest-inspection)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine-manifest keypair setup failed"
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$quarantine/manifests" "$quarantine/payloads" "$quarantine/staging" \
    "$quarantine/corrupt" "$quarantine/recovery-corrupt"
  manifest="$quarantine/manifests/$(printf '%064d' 8).json"
  printf '%s\n' '{}' > "$manifest"
  manifest="$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")"
  preload="$home/quarantine-manifest-failure.mjs"
  cat > "$preload" <<'EOF'
import path from "node:path";
import { createRequire, syncBuiltinESMExports } from "node:module";

const fs = createRequire(import.meta.url)("node:fs");
const originalLstatSync = fs.lstatSync;
fs.lstatSync = function guardedLstatSync(value, ...args) {
  if (path.resolve(String(value)) === path.resolve(process.env.FM_TEST_QUARANTINE_MANIFEST)) {
    const error = new Error("simulated manifest inspection failure");
    error.code = "EACCES";
    throw error;
  }
  return originalLstatSync.call(fs, value, ...args);
};
syncBuiltinESMExports();
EOF
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"manifest-accounting"}' \
    | NODE_OPTIONS="--import=$preload" FM_TEST_QUARANTINE_MANIFEST="$manifest" \
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
  local home relay cache_dir count i
  home=$(make_home cap)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  relay="ws://127.0.0.1:1"
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$cache_dir"

  # Seed 120 plausible cache entries with increasing timestamps, then publish
  # once against a dead relay: the prune must bring the cache to the cap,
  # keeping the newest and dropping the oldest.
  i=1
  while [ "$i" -le 120 ]; do
    printf '["EVENT",{"id":"%060d","created_at":%d}]' "$i" "$((1700000000 + i))" \
      > "$cache_dir/$((1700000000 + i))-$(printf '%064d' "$i").json"
    i=$((i + 1))
  done
  [ "$(replay_count "$home")" = "120" ] || fail "cache seeding failed"

  printf '%s' '{"schema":"fm-bearings.v1"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1

  count=$(replay_count "$home")
  [ "$count" = "100" ] || fail "the replay cache is not capped at 100 (found $count)"

  # The newest must survive and the oldest must be gone.
  assert_present "$cache_dir/$((1700000000 + 120))-$(printf '%064d' 120).json" \
    "the cap dropped a newer event instead of an older one"
  assert_absent "$cache_dir/$((1700000000 + 1))-$(printf '%064d' 1).json" \
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
  local home relay output clock cache_dir old
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
  old="$cache_dir/1700000000-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.json"
  printf '%s' '["EVENT",{}]' > "$old"

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

  (printf '%s' '{"schema":"fm-bearings.v1","note":"concurrent-first"}' \
    | FM_BUZZ_MAX_CACHE=1 run_publish "$home" "$relay" --timeout 1500) \
    > "$first_output" 2>&1 &
  first_pid=$!
  waited=0
  while [ ! -L "$lock" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -L "$lock" ] || fail "the first publisher never acquired cache ownership"

  (printf '%s' '{"schema":"fm-bearings.v1","note":"concurrent-second"}' \
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

test_publish_lock_acquisition_is_validated_bounded_and_interruptible() {
  local home lock projection out_file result invalid code pid waited ready holder tools real_mktemp mktemp_log
  home=$(make_home bounded-publish-lock)
  lock="$home/state/.buzz-replay-publish.lock"
  projection="$home/projection.json"
  out_file="$home/publish-lock.out"
  ready="$home/publish-lock-ready"
  run_keypair "$home" >/dev/null 2>&1 || fail "publish-lock fixture setup failed"
  printf '%s' '{"schema":"fm-bearings.v1","note":"publish-lock"}' > "$projection"

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

test_publish_signing_is_serialized_with_compromised_rotation() {
  local home tools ready release publish_output rotate_output old publisher rotation waited relay new
  home=$(make_home publish-rotation-serialization)
  tools=$(make_delayed_publish_tools)
  ready="$home/publish-engine-ready"
  release="$home/publish-engine-release"
  publish_output="$home/publish-engine.out"
  rotate_output="$home/rotation.out"
  old=$(run_keypair "$home" 2>/dev/null) || fail "publish-rotation keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub --reject "restricted: channel fixture stays uncreated")
EOF

  (printf '%s' '{"schema":"fm-bearings.v1","note":"signed-before-compromised-rotation"}' \
    | PATH="$tools:$PATH" FM_DELAY_BUZZ_PUBLISH_READY="$ready" \
      FM_DELAY_BUZZ_PUBLISH_RELEASE="$release" \
      FM_DELAY_BUZZ_REMOVE_TARGETS="$home/data/buzz-publisher-targets.jsonl" \
      run_publish "$home" "$relay") \
    > "$publish_output" 2>&1 &
  publisher=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || {
    kill "$publisher" 2>/dev/null
    stop_stub "$STUB_PID"
    fail "the publisher did not pause at the signing boundary"
  }

  run_keypair "$home" --rotate --compromised --discard-pending-cache > "$rotate_output" 2>&1 &
  rotation=$!
  sleep 0.1
  kill -0 "$rotation" 2>/dev/null || {
    : > "$release"
    wait "$publisher" "$rotation" 2>/dev/null
    stop_stub "$STUB_PID"
    fail "compromised rotation did not wait for in-flight signing"
  }
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "compromised rotation withdrew the key before the delayed publisher signed"

  : > "$release"
  wait "$publisher" || fail "the serialized publisher violated fire-and-forget"
  wait "$rotation" || fail "compromised rotation failed after publishing released the key"
  stop_stub "$STUB_PID"
  new=$(tail -1 "$rotate_output")

  assert_contains "$(cat "$publish_output")" "signed event" \
    "the delayed projection was not signed under the protected transaction"
  assert_contains "$(cat "$publish_output")" "retained=1" \
    "the delayed projection was not durably cached before rotation"
  assert_contains "$(cat "$rotate_output")" "quarantined 1 outgoing-authored pending replay event" \
    "the explicit rotation override did not quarantine the delayed projection"
  [ "$new" != "$old" ] || fail "compromised rotation did not replace the publishing identity"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$old" \
    "compromised rotation retained the protected outgoing identity"
  pass "publishing signs before compromised rotation can withdraw its key"
}

test_replay_cache_rejects_symlink_boundaries() {
  local root_home relay_home entry_home outside replay relay digest link target output manifest payload
  root_home=$(make_home cache-root-symlink)
  run_keypair "$root_home" >/dev/null 2>&1 || fail "root-symlink keypair setup failed"
  outside="$root_home/outside-cache"
  mkdir "$outside"
  rm -rf "$root_home/state/buzz-replay"
  ln -s "$outside" "$root_home/state/buzz-replay"
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"root-symlink"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"relay-symlink"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"entry-symlink"}' \
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"root-pin"}' \
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
  local home relay replay digest partition held outside preload escape_log swap_log output
  home=$(make_home replay-descendant-pin)
  run_keypair "$home" >/dev/null 2>&1 || fail "replay-descendant keypair setup failed"
  relay="ws://127.0.0.1:1/descendant"
  replay="$home/state/buzz-replay"
  digest=$(node -e '
    import(process.argv[1]).then(({ relayCacheKey }) => process.stdout.write(relayCacheKey(process.argv[2])));
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$relay")
  partition="$replay/$digest"
  held="$home/held-replay-partition"
  outside="$home/outside-replay-partition"
  preload="$home/replay-descendant-swap.mjs"
  escape_log="$home/replay-descendant-escape.log"
  swap_log="$home/replay-descendant-swap.log"
  mkdir -p "$partition" "$outside"
  cat > "$preload" <<'EOF'
import path from "node:path";
import { createRequire, syncBuiltinESMExports } from "node:module";

const fs = createRequire(import.meta.url)("node:fs");

const originalWriteFileSync = fs.writeFileSync;
const replayRoot = fs.realpathSync(process.env.FM_TEST_REPLAY_ROOT);
let swapped = false;
fs.writeFileSync = function guardedWriteFileSync(file, ...args) {
  const absolute = path.resolve(String(file));
  const parent = path.dirname(absolute);
  originalWriteFileSync(process.env.FM_TEST_CACHE_SWAP_LOG, `write ${absolute} root ${replayRoot}\n`, { flag: "a" });
  if (
    !swapped &&
    parent.startsWith(`${replayRoot}${path.sep}`) &&
    path.basename(absolute).endsWith(".json.tmp")
  ) {
    swapped = true;
    fs.renameSync(parent, process.env.FM_TEST_CACHE_HELD);
    fs.symlinkSync(process.env.FM_TEST_CACHE_OUTSIDE, parent, "dir");
    originalWriteFileSync(process.env.FM_TEST_CACHE_SWAP_LOG, `swapped ${parent}\n`, { flag: "a" });
  }
  const result = originalWriteFileSync.call(fs, file, ...args);
  const escaped = path.join(process.env.FM_TEST_CACHE_OUTSIDE, path.basename(String(file)));
  if (fs.existsSync(escaped)) {
    originalWriteFileSync(process.env.FM_TEST_CACHE_ESCAPE_LOG, `${escaped}\n`, { flag: "a" });
  }
  return result;
};
syncBuiltinESMExports();
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"descendant-pin"}' \
    | NODE_OPTIONS="--import=$preload" \
      FM_TEST_REPLAY_ROOT="$replay" \
      FM_TEST_CACHE_HELD="$held" \
      FM_TEST_CACHE_OUTSIDE="$outside" \
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
  pass "replay cache descendant directories stay pinned during mutation"
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
import path from "node:path";
import { createRequire, syncBuiltinESMExports } from "node:module";

const fs = createRequire(import.meta.url)("node:fs");
const originalLinkSync = fs.linkSync;
let swapped = false;
fs.linkSync = function guardedLinkSync(source, destination, ...args) {
  const absoluteSource = path.resolve(String(source));
  if (!swapped && path.basename(String(destination)) === "source") {
    swapped = true;
    const sourceParent = path.dirname(absoluteSource);
    fs.renameSync(sourceParent, process.env.FM_TEST_CACHE_HELD);
    fs.symlinkSync(process.env.FM_TEST_CACHE_OUTSIDE, sourceParent, "dir");
  }
  return originalLinkSync.call(fs, source, destination, ...args);
};
syncBuiltinESMExports();
EOF
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"cross-directory-swap"}' \
    | NODE_OPTIONS="--import=$preload" \
      FM_TEST_CACHE_HELD="$held" \
      FM_TEST_CACHE_OUTSIDE="$outside" \
      run_publish "$home" ws://127.0.0.1:1 2>&1)
  assert_contains "$output" "unexpected source identity" \
    "a swapped cross-directory source was not rejected"
  assert_present "$outside/1700000000-$(printf '%064d' 6).json" \
    "quarantine moved a swapped external source into the replay cache"
  [ "$(cat "$outside/1700000000-$(printf '%064d' 6).json")" = "outside-must-remain" ] \
    || fail "quarantine mutated a swapped external source"
  assert_present "$held/1700000000-$(printf '%064d' 6).json" \
    "quarantine lost the originally claimed legacy inode"
  pass "cross-directory quarantine claims reject swapped source paths"
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

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"after-corrupt-partition"}' \
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

  (printf '%s' '{"schema":"fm-bearings.v1","note":"regular-after-fifo"}' \
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
    output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"invalid-relay-timeout"}' \
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
  local home relay replay removable retained output
  home=$(make_home malformed-cache-names)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  replay=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$replay"
  removable="$replay/not-an-event.json"
  retained="$replay/still-not-an-event.json"
  printf '%s' '{"malformed":true}' > "$removable"
  mkdir "$retained"

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

  assert_contains "$output" "rejected cache directory symlink" \
    "a cache child symlink was silently ignored"
  assert_contains "$output" "uninspectable-relay" \
    "the cache child stat failure did not identify the affected path"
  assert_contains "$output" "delivered=1 retained=1 discarded=0 cleanup_failed=1" \
    "a cache child stat failure was omitted from retained or cleanup accounting"
  assert_contains "$output" "publish did not complete; Firstmate is unaffected" \
    "a cache child stat failure did not reach the fire-and-forget conversion"
  pass "cache directory inspection failures remain visible in outcome accounting"
}

test_an_interrupted_cache_write_is_swept_not_leaked() {
  # A `.json.tmp` is the half of the atomic cache write that a kill between the
  # write and the rename leaves behind. It matches neither the drain's filter nor
  # the cap's accounting, so unswept it is invisible AND immortal: never sent,
  # never counted, never removed, one leaked signed projection per interrupted
  # run. An in-flight write from a concurrent run must survive, though, so the
  # sweep is age-gated and this checks both halves.
  local home relay cache_dir stale fresh count
  home=$(make_home orphan-tmp)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  relay="ws://127.0.0.1:1"
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$cache_dir"

  stale="$cache_dir/1700000001-$(printf '%064d' 1).json.tmp"
  fresh="$cache_dir/1700000002-$(printf '%064d' 2).json.tmp"
  printf '["EVENT",{"id":"%064d","created_at":1700000001}]' 1 > "$stale"
  printf '["EVENT",{"id":"%064d","created_at":1700000002}]' 2 > "$fresh"
  touch -t 202001010000 "$stale" || fail "could not age the stale temp file"

  printf '%s' '{"schema":"fm-bearings.v1","note":"orphan"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1

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
  cache_dir=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  [ -d "$cache_dir" ] || fail "relay-specific cache directory was not created"
  unreadable="$cache_dir/1700000000-$(printf '%064d' 7).json"
  mkdir "$unreadable"

  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"read-error"}' \
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
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  replay=$(channel_cache_dir "$home" "$relay" "$(default_channel_id "$home")") \
    || fail "could not derive cache partition"
  mkdir -p "$replay"
  first="$replay/1700000001-$(printf '%064d' 1).json"
  second="$replay/1700000002-$(printf '%064d' 2).json"
  mkdir "$first" "$second"
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"prune-failure"}' \
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

  for invalid in 0 -1 nope 2147483648 999999999999999999999999999999; do
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
  output=$(printf '%s' '{"schema":"fm-bearings.v1","note":"must-not-publish"}' \
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

test_multiline_current_key_record_cannot_expand_authorship() {
  local home other relay current appended inspected
  home=$(make_home multiline-current-key)
  other=$(make_home multiline-current-key-other)
  current=$(run_keypair "$home" 2>/dev/null) || fail "multiline current-key setup failed"
  appended=$(run_keypair "$other" 2>/dev/null) || fail "multiline current-key second identity setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"authorship-needs-singular-record"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  printf '%s\n%s\n' "$current" "$appended" > "$home/data/buzz-keypair.public"

  inspected=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$inspected" "authorship-needs-singular-record" \
    "the multiline current-key fixture did not return its event"
  assert_contains "$inspected" "unknown (no publisher public key recorded for this home)" \
    "a multiline current-key record still established authorship"
  assert_contains "$inspected" "INCONCLUSIVE" \
    "malformed current-key attribution produced a definite privacy verdict"
  assert_not_contains "$inspected" \
    "The channel was readable by an identity that is not a member" \
    "an appended current key expanded trust for the anonymous verdict"
  pass "current-key attribution requires exactly one normalized record"
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
  local home relay retired retired_private retired_upper rotated leaked channel label
  home=$(make_home rotated-breach)
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"
  retired_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' \
    "$(key_file "$home" "$home/xdg")")
  label=$(cd "$home" && pwd -P)
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the rotated fixture channel"
  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$rotated" != "$retired" ] || fail "rotation did not replace the key, so nothing here is under test"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_signed_fixture "$retired_private" "$relay" "$channel" "published-before-rotation" \
    || fail "could not seed the pre-rotation signed event"
  retired_private=""
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
  local home relay retired retired_private rotated history withdrawn after code label channel
  home=$(make_home forget-key)
  history="$home/data/buzz-keypair.public-history"
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"
  retired_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' \
    "$(key_file "$home" "$home/xdg")")
  label=$(cd "$home" && pwd -P)
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the withdrawal fixture channel"
  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  assert_grep "$retired" "$history" \
    "the ordinary rotation did not retain the key the withdrawal is about"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_signed_fixture "$retired_private" "$relay" "$channel" "signed-by-the-leaked-key" \
    || fail "could not seed the withdrawn-key event"
  retired_private=""

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

test_compose_relay_signer_survives_restart_but_not_volume_teardown() {
  local project port home relay old_private channel first second third
  if [ "${FM_BUZZ_DOCKER_INTEGRATION:-0}" != "1" ]; then
    pass "compose relay signer lifecycle is available with FM_BUZZ_DOCKER_INTEGRATION=1"
    return
  fi
  command -v docker >/dev/null 2>&1 \
    || fail "FM_BUZZ_DOCKER_INTEGRATION=1 but docker is unavailable"
  docker compose version >/dev/null 2>&1 \
    || fail "FM_BUZZ_DOCKER_INTEGRATION=1 but docker compose is unavailable"
  docker info >/dev/null 2>&1 \
    || fail "FM_BUZZ_DOCKER_INTEGRATION=1 but the docker daemon is unavailable"
  project="buzz-loopback-test-$$"
  BUZZ_DOCKER_PROJECT=$project
  # shellcheck disable=SC2016
  port=$(node -e '
    const server = require("node:net").createServer();
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => process.stdout.write(`${port}\n`));
    });
  ') || fail "could not reserve a loopback port for the compose integration"
  home=$(make_home compose-relay-signer)
  run_keypair "$home" >/dev/null 2>&1 || fail "compose signer keypair setup failed"
  old_private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$(cd "$home" && pwd -P)") \
    || fail "could not derive the compose integration channel"
  relay="ws://localhost:$port"

  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" up -d --wait --wait-timeout 240 \
    || fail "could not start the disposable Buzz integration stack"
  printf '%s' '{"schema":"fm-bearings.v1","note":"signer-before-restart"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  first=$(query_membership_signer "$old_private" "$relay" "$channel") \
    || fail "could not read the initial compose membership signer"

  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" restart relay >/dev/null \
    || fail "could not restart the disposable Buzz relay"
  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" up -d --wait --wait-timeout 240 >/dev/null \
    || fail "the restarted disposable Buzz relay did not become ready"
  second=$(query_membership_signer "$old_private" "$relay" "$channel") \
    || fail "could not read the restarted compose membership signer"
  [ "$second" = "$first" ] || fail "relay restart changed the TOFU membership signer"

  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" down -v >/dev/null \
    || fail "could not destroy the disposable Buzz volumes"
  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" up -d --wait --wait-timeout 240 >/dev/null \
    || fail "could not recreate the disposable Buzz integration stack"
  printf '%s' '{"schema":"fm-bearings.v1","note":"signer-after-volume-teardown"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  third=$(query_membership_signer "$old_private" "$relay" "$channel") \
    || fail "could not read the recreated compose membership signer"
  [ "$third" != "$first" ] || fail "down -v retained the disposable relay signing key"
  docker compose -p "$project" -f "$ROOT/docker-compose.buzz-loopback.yml" \
    down -v >/dev/null 2>&1 || true
  BUZZ_DOCKER_PROJECT=""
  pass "compose relay signer survives restart and changes after down -v"
}

test_quarantine_lifecycle_has_one_pinned_cache_owner() {
  assert_absent "$ROOT/bin/fm-buzz-quarantine.mjs" \
    "the quarantine callback middleman still splits lifecycle ownership"
  assert_grep "function quarantineLegacyEntries" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the pinned cache owner does not own legacy quarantine orchestration"
  assert_grep "function recoverStagedLegacyEntries" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the pinned cache owner does not own quarantine recovery"
  assert_grep "staging/<token>/{source,origin.json}" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine owner does not document its staging and payload layout"
  assert_grep "A manifest at manifests/<token>.json identifies a record" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine owner does not document manifest identity"
  assert_grep "Startup first accounts for invalid recovery residue" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine owner does not document recovery order"
  assert_grep "<replay-root>/<endpoint-digest>/<channel-id>/<created_at>-<event-id>.json" \
    "$ROOT/bin/fm-buzz-publish.mjs" \
    "the active-cache owner does not document its partition and entry layout"
  assert_grep "query authoritative membership state for safe key" "$ROOT/bin/fm-buzz-lib.mjs" \
    "the relay-client scope omits rotation membership queries"
  assert_grep 'FM_BUZZ_DOCKER_INTEGRATION=1` enables the opt-in Compose' "$ROOT/docs/buzz-loopback-adapter.md" \
    "the adapter guide does not distinguish the opt-in Docker lane"
  assert_grep "header of .*fm-buzz-publish.sh.* owns input, option, default, and termination mechanics" \
    "$ROOT/docs/buzz-loopback-adapter.md" \
    "the adapter guide does not point runtime mechanics to their owner"
  assert_no_grep "runLegacyQuarantineLifecycle" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the publisher still delegates through the callback facade"
  pass "quarantine lifecycle and pinned mutations have one owner"
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

read -r ROTATION_GUARD_PID ROTATION_GUARD_RELAY <<EOF
$(start_stub)
EOF

test_bip340_official_vectors
test_keypair_is_idempotent_and_never_prints_the_private_key
test_public_flag_fails_before_a_keypair_exists
test_rotation_replaces_the_key_in_whichever_store_holds_it
test_a_compromised_rotation_does_not_keep_the_retired_key
test_rotation_refuses_or_quarantines_outgoing_pending_events
test_rotation_refuses_an_existing_private_channel_before_mutation
test_rotation_reports_every_membership_blocker
test_rotation_query_errors_report_every_target_on_the_endpoint
test_publisher_target_overrides_are_recorded_and_guard_rotation
test_publisher_target_updates_are_concurrent_and_fail_closed
test_forget_target_attests_exact_retirement
test_forget_relay_identity_requires_exact_target_retirement
test_rotation_checks_authoritative_current_membership
test_rotation_fails_closed_on_unverifiable_membership
test_rotation_pins_and_verifies_relay_membership_authority
test_empty_relay_authority_registry_fails_closed
test_rotation_stops_or_recovers_when_the_outgoing_private_key_is_unusable
test_compromised_orphan_recovery_records_unverifiable_memberships
test_orphan_identity_evidence_requires_compromised_recovery
test_rotation_compares_the_recorded_key_with_stored_private_material
test_rotation_detects_and_cleans_up_divergent_stores
test_orphaned_public_record_requires_compromised_recovery
test_forget_key_refuses_when_history_cannot_be_read
test_keychain_errors_refuse_rotation_without_minting_a_fallback_key
test_public_record_failures_are_fatal_and_retryable
test_key_record_targets_reject_non_files
test_key_record_replace_is_exact_destination
test_keypair_transactions_are_serialized_per_home
test_public_read_cannot_restore_a_concurrently_retired_identity
test_public_key_history_is_normalized_consistently
test_two_homes_sharing_one_xdg_get_separate_keys
test_publish_with_relay_down_exits_zero_and_enqueues
test_publisher_target_is_recorded_only_after_cache
test_cache_cap_is_enforced_before_target_registry_failure
test_replayed_events_are_tracked_before_delivery
test_rotation_uses_the_authoritative_replay_cache_path
test_malformed_projection_is_rejected_before_signing
test_refresh_preserves_the_snapshot_bytes_including_its_trailing_newline
test_publish_without_a_keypair_still_exits_zero
test_non_loopback_env_relay_is_rejected_before_network
test_credential_bearing_relays_are_rejected_before_signing_or_caching
test_rotation_rejects_credential_relays_without_logging_credentials
test_publish_with_relay_up_delivers_and_lands
test_relay_switch_does_not_replay_another_relays_cache
test_endpoint_only_cache_entries_migrate_to_their_exact_channel
test_same_endpoint_channel_queues_are_isolated
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
test_concurrent_publishers_serialize_the_cache_lifecycle
test_publish_lock_acquisition_is_validated_bounded_and_interruptible
test_publish_signing_is_serialized_with_compromised_rotation
test_replay_cache_rejects_symlink_boundaries
test_replay_cache_pins_the_root_before_mutation
test_replay_cache_pins_descendant_directories
test_cross_directory_quarantine_claims_cannot_follow_swapped_sources
test_partition_shaped_special_nodes_are_quarantined_and_unblocked
test_replay_cache_never_reads_non_regular_entries
test_relay_timeout_must_fit_the_node_timer_range
test_malformed_cache_names_are_discarded_or_accounted_for
test_cache_directory_stat_failures_are_accounted_for
test_an_interrupted_cache_write_is_swept_not_leaked
test_unreadable_cache_entry_is_retained_as_retryable
test_parseable_cache_corruption_is_discarded_without_replay
test_cache_prune_failures_are_reported_and_accounted_for
test_a_writer_that_never_closes_does_not_hang_the_publish
test_invalid_stdin_timeouts_are_rejected_before_reading
test_required_option_operands_are_not_consumed_as_flags
test_unknown_publish_options_are_safe_non_events
test_a_signalled_read_leaves_no_projection_in_temp
test_a_signalled_read_releases_the_callers_output
test_fire_and_forget_contract_is_intact
test_nothing_private_reaches_a_command_line
test_the_inspector_rejects_a_tampered_event
test_an_anonymous_read_only_claims_privacy_when_the_relay_refuses
test_an_anonymous_read_that_returns_events_reports_the_breach
test_multiline_current_key_record_cannot_expand_authorship
test_an_anonymous_read_of_unverifiable_events_claims_no_breach
test_malformed_relay_events_are_assessed_independently
test_wrong_kind_event_cannot_produce_a_privacy_breach_verdict
test_an_anonymous_read_of_a_foreign_authors_event_claims_no_breach
test_a_rotated_home_still_recognises_its_own_leaked_events
test_forget_key_withdraws_an_already_retired_key
test_an_anonymous_read_of_a_foreign_channel_claims_no_verdict
test_a_membership_refusal_for_an_empty_foreign_channel_is_inconclusive
test_an_anonymous_read_of_this_homes_own_label_still_reaches_a_verdict
test_compose_relay_signer_survives_restart_but_not_volume_teardown
test_quarantine_lifecycle_has_one_pinned_cache_owner
test_no_firstmate_path_depends_on_buzz
