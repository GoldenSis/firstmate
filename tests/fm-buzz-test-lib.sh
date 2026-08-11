#!/usr/bin/env bash
# Shared fixtures for the subject-focused Buzz behavior suites.
# This file is sourced by tests and is not an independent test entry point.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEYPAIR="$ROOT/bin/fm-buzz-keypair.sh"
PUBLISH="$ROOT/bin/fm-buzz-publish.sh"
INSPECT="$ROOT/bin/fm-buzz-inspect.sh"
STUB="$ROOT/tests/fm-buzz-stub-relay.mjs"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-buzz.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
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

# Ask the custody library where the rotation stage lives and how to write one, for
# the same reason key_file does: the layout is what is under test.
rotation_stage_file() {  # <home>
  # shellcheck disable=SC1091
  ( . "$ROOT/bin/fm-buzz-key-lib.sh"; fm_buzz_key_stage_file "$1/data" )
}

write_rotation_stage() {  # <home> <phase> <private-key> <public-key> [ordinary|compromised]
  # shellcheck disable=SC1091
  ( . "$ROOT/bin/fm-buzz-key-lib.sh"; fm_buzz_key_stage_write "$1/data" "$2" "$3" "$4" "${5:-ordinary}" )
}

delivery_lock_path() {  # <home> <relay> <channel>
  local normalized
  normalized=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$2") || return 1
  # shellcheck disable=SC1091
  ( . "$ROOT/bin/fm-buzz-key-lib.sh"; fm_buzz_replay_delivery_lock "$1/state" "$normalized" "$3" )
}

# Hold a lock from a live background process, so the holder is a real owner rather
# than a hand-forged directory the acquire path would rightly treat as stale.
#
# The holder's stdout and stderr are closed off deliberately: this runs inside a
# command substitution, which waits for every writer to the capture pipe, so a
# holder that inherited them would hang the caller until it exited - which is
# precisely never.
hold_lock() {  # <lock path> -> holder pid
  local lock=$1 pid
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    trap "fm_lock_release \"\$2\"; exit 0" TERM INT
    fm_lock_try_acquire "$2" || exit 1
    while :; do sleep 0.2; done
  ' bash "$ROOT" "$lock" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ -e "$lock" ] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  return 1
}

release_lock() {  # <holder pid>
  kill -TERM "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

new_private_key() {
  # shellcheck disable=SC2016
  node -e '
    import(process.argv[1]).then(({ generateKeypair }) => {
      process.stdout.write(`${generateKeypair().privateKey}\n`);
    });
  ' "$ROOT/bin/fm-buzz-crypto.mjs"
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
