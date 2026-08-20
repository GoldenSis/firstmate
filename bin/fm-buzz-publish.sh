#!/usr/bin/env bash
# fm-buzz-publish.sh - publish one bearings projection to the loopback Buzz relay.
#
# ============================ FIRE-AND-FORGET ==============================
# RUNTIME PUBLISH FAILURES EXIT 0. MISSING PYTHON 3 AND INPUT-CONTRACT FAILURES EXIT NON-ZERO.
#
# Every failure path - relay down, connection refused, timeout, NIP-42 auth
# failure, event rejected, signing error, missing keypair, missing node or its
# WebSocket API, missing jq, or unreadable replay cache - is caught, logged to
# stderr, and followed by exit 0. Python 3 is the declared prerequisite for the
# descriptor-relative filesystem operations that enforce the cache boundary, so
# its absence is a loud startup error rather than an optional publish failure.
# An invalid fm-bearings.v1 input is also loud because signing data outside the
# projection contract would make the publisher attest to content it did not check.
# Relay-supplied rejection diagnostics render C0 and C1 terminal controls as
# visible `\uXXXX` escapes before they reach stderr.
#
# Why the contract is this absolute: Buzz is an additive reporting surface and
# nothing in Firstmate's operation may depend on it. If this script could fail, a
# stopped relay would be able to break a merge, a teardown, a wake drain, or a
# turn end - and Buzz would have become load-bearing for supervision, which is
# exactly the outcome the study that authorized this work ruled out. Publishing
# is downstream of everything and blocks nothing.
#
# Consequences that follow from the contract, for anyone editing this file:
#   - Do not add `set -e`. It is absent on purpose.
#   - Do not add another `|| exit 1`, an `exit $?`, or a bare `exit` path.
#   - A failure the operator needs to see is a stderr line, never an exit code,
#     except for missing Python 3 or an invalid fm-bearings.v1 projection.
#   - The engine (bin/fm-buzz-publish.mjs) MAY exit non-zero; converting that into
#     a logged success is this wrapper's whole job.
# tests/fm-buzz-publish.test.sh asserts exit 0 with the relay stopped, and also
# greps this file to assert `set -e` has not crept back in.
# ===========================================================================
#
# ONE INVOCATION, ONE CHANNEL. This script publishes one projection into one
# channel, and that is still true now that the adapter has per-crew lanes: a lane
# is just another invocation with --channel-label set to that crewmate's derived
# label. bin/fm-buzz-refresh.sh is the single entry point that walks the fleet
# channel and every lane; bin/fm-buzz-crew-lanes.sh owns what a lane contains and
# bin/fm-buzz-lib.mjs's crewChannelLabel owns how a lane label is derived. Nothing
# here changed for the fleet channel, whose label derivation is byte-identical to
# what it always was, so it keeps the channel id a captain has been reading.
#
# THE NAME IS NOT THE LABEL. The label derives the channel id and must never move
# for an existing channel; the display name is what a Buzz client lists a channel
# under, and it is free to change. They are separate options because every lane
# needs its own name while the fleet channel keeps the one it has always had. A
# lane that inherits the default name is addressed correctly and still unreadable:
# a captain browsing the client sees one row per lane, all called
# firstmate-bearings, distinguishable only by UUID.
#
# The published event is one append-only NIP-29 channel message whose content is
# the `fm-bearings-snapshot.sh --json` projection VERBATIM, including its
# omitted[] disclosure array. A per-crew lane is itself a valid fm-bearings.v1
# projection narrowed to one task, so it is validated and signed by this same
# path with no second contract. The disclosure is what makes a bounded projection
# honest - it states what was dropped and how to reveal it - so it is passed
# through untouched rather than summarised or stripped.
#
# This script reads Firstmate state only through the snapshot's read-only command,
# writes signed projections to Buzz, maintains local replay and legacy-
# quarantine state under state/buzz-replay, and records used publisher targets
# under data/buzz-publisher-targets.jsonl. It never reads Buzz into Firstmate
# state. Buzz is a projection target, never a state source;
# bin/fm-buzz-inspect.mjs is a human diagnostic and is not consumed here.
#
# Usage:
#   fm-buzz-publish.sh                 read the projection JSON on stdin
#   fm-buzz-publish.sh --refresh       invoke bin/fm-bearings-snapshot.sh --json
#   fm-buzz-publish.sh --relay <url>   override the relay (default ws://localhost:3000)
#   fm-buzz-publish.sh --channel-label <s>
#                                      override the channel-derivation label
#   fm-buzz-publish.sh --channel-name <s>
#                                      the channel's display name, at most 100
#                                      printable characters (default
#                                      firstmate-bearings)
#   fm-buzz-publish.sh --replay-channel <uuid>
#                                      drain one existing cache partition without
#                                      signing a new projection
#   fm-buzz-publish.sh --timeout <ms>  relay timeout, integer 1..2147483647 (default 15000)
#   fm-buzz-publish.sh --help          this text
#
# Each publisher lock acquisition waits at most FM_BUZZ_LOCK_TIMEOUT_S seconds
# (default 30).
# Projection input is capped at FM_BUZZ_MAX_PROJECTION_BYTES bytes (default and
# hard ceiling 1048576); an oversized projection is rejected before signing.
# Invalid deadlines, acquisition timeouts, and interrupted waits are logged and
# converted to the same exit-0 non-event as every other publishing failure.
# bin/fm-buzz-key-lib.sh owns the lock ordering and phase-boundary contract used
# to isolate whole-tree migration, per-channel delivery, signing, and rotation.
#
# Relay host note: the default is ws://localhost:3000, not ws://127.0.0.1:3000.
# Relay URLs must use ws or wss, contain no credentials, and name 127.0.0.1,
# localhost, or [::1].
# Buzz resolves its tenant from the HTTP Host header and the bundled deployment
# community is registered as `localhost:3000`, so a bare-IP Host is answered with
# `relay: no community is configured for this host`. Both spellings are loopback;
# only one is accepted. See docs/buzz-loopback-adapter.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"
# shellcheck source=bin/fm-buzz-projection-lib.sh
. "$SCRIPT_DIR/fm-buzz-projection-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
CHANNEL_NAME=""
REPLAY_CHANNEL=""
TIMEOUT_MS=${FM_BUZZ_TIMEOUT_MS:-15000}
MAX_CACHE=${FM_BUZZ_MAX_CACHE:-100}
REFRESH=0
REPLAY_DIR=$(fm_buzz_replay_cache_dir "$STATE") || {
  printf 'fm-buzz-publish: could not resolve the replay cache path\n' >&2
  exit 0
}
TARGETS_FILE="$DATA/buzz-publisher-targets.jsonl"

STDIN_TIMEOUT_S=${FM_BUZZ_STDIN_TIMEOUT_S:-30}
MAX_PROJECTION_BYTES=${FM_BUZZ_MAX_PROJECTION_BYTES:-1048576}
PUBLISH_LOCK_TIMEOUT_S=${FM_BUZZ_LOCK_TIMEOUT_S:-30}

log() {
  printf 'fm-buzz-publish: %s\n' "$1" >&2
}

# The projection spool holds the bearings projection - task ids, project names,
# blockers, PR URLs - in a shared temp directory, so it must not outlive the run
# that created it. The in-line `rm` covers the ordinary returns; this covers the
# signalled ones, which is exactly the case the read watchdog exists for.
#
# The handler deliberately does NOT exit: a trapped signal interrupts the pending
# `wait`, the read reports failure, and the script falls through to its single
# unconditional `exit 0` on its own. Adding an `exit` here would put a second exit
# on a signal path, and swallowing the signal without one would make the script
# unkillable; letting the normal tail run does neither.
#
# The background reader goes with it. On the signalled path nothing else reaps it:
# the script falls through to `exit 0` while the `cat` keeps running against a
# deleted inode, still holding the stderr this script inherited - so a caller doing
# `output=$(fm-buzz-publish.sh ... 2>&1)` blocks on that pipe until the writer that
# feeds it finally closes. That is the same caller-side hang the read watchdog
# exists to prevent, arrived at from the other direction. On the ordinary paths the
# reader has already been reaped and the pid cleared, so the kill is a no-op.
STDIN_SPOOL=""
STDIN_READER=""
PUBLISH_LOCK=""
DELIVERY_INTENT_LOCK=""
DELIVERY_LOCK=""
KEYPAIR_LOCK=""
PUBLISH_INTERRUPTED=0
# Released highest-numbered first, matching the ordering fm-buzz-key-lib.sh owns.
drop_stdin_spool() {
  if [ -n "$STDIN_READER" ]; then
    kill "$STDIN_READER" 2>/dev/null
    STDIN_READER=""
  fi
  if [ -n "$STDIN_SPOOL" ]; then
    rm -f -- "$STDIN_SPOOL"
    STDIN_SPOOL=""
  fi
  if [ -n "$KEYPAIR_LOCK" ]; then
    fm_lock_release "$KEYPAIR_LOCK"
    KEYPAIR_LOCK=""
  fi
  if [ -n "$DELIVERY_LOCK" ]; then
    fm_lock_release "$DELIVERY_LOCK"
    DELIVERY_LOCK=""
  fi
  if [ -n "$DELIVERY_INTENT_LOCK" ]; then
    fm_lock_release "$DELIVERY_INTENT_LOCK"
    DELIVERY_INTENT_LOCK=""
  fi
  if [ -n "$PUBLISH_LOCK" ]; then
    fm_lock_release "$PUBLISH_LOCK"
    PUBLISH_LOCK=""
  fi
}
# shellcheck disable=SC2329 # Invoked by the signal traps below.
interrupt_publish() {
  PUBLISH_INTERRUPTED=1
  drop_stdin_spool
}
trap drop_stdin_spool EXIT
trap interrupt_publish INT TERM HUP

# Spool stdin into the caller's file under a total deadline and byte limit.
# Reports status only; the caller owns the spool and reads it afterwards.
#
# The spool path is the CALLER's, and this function is invoked as a plain command
# rather than inside `$(...)`, both for the same reason: a command substitution
# runs in a subshell, where a trap set out here does not fire and an assignment
# made in there never reaches the trap's variable. Spooling from the main shell is
# what lets the signal handler above see the file at all - and what lets the signal
# interrupt the `wait` below instead of being deferred until the substitution ends.
#
# An unbounded read is the one way this script could fail to RETURN even though it
# cannot fail to exit non-zero, and for a caller a hang is strictly worse than a
# refusal - "never blocks Firstmate" has to mean termination, not just status 0.
# A writer that produces some bytes and then never closes its end would otherwise
# park `cat` forever, so a watchdog kills the read at the deadline.
#
# An expired read is DISCARDED, never published: half a projection is not a
# smaller projection, it is malformed JSON, and the omitted[] disclosure that
# makes a bounded projection honest is at the end of it. Truncating silently
# would turn "this was cut short" into an unmarked absence, which is the one thing
# the disclosure exists to prevent.
#
# The watchdog polls in one-second steps instead of sleeping the whole deadline in
# one go, and gives up its stdout and stderr on the way in. Both matter: a plain
# `sleep $deadline` leaves an orphan holding this script's output pipe open long
# after the read finished, and a caller doing `output=$(fm-buzz-publish.sh ...)`
# blocks on that fd until it drains - which would reintroduce, in the caller, the
# very hang this function exists to prevent.
read_stdin_bounded() {  # <spool>
  local spool=$1 reader watchdog rc
  # Published to the script scope so the signal handler can reap it too; cleared
  # again below once `wait` has.
  python3 -c '
import sys

output_path, maximum = sys.argv[1], int(sys.argv[2])
written = 0
with open(output_path, "wb", buffering=0) as output:
    while written <= maximum:
        chunk = sys.stdin.buffer.read(min(65536, maximum + 1 - written))
        if not chunk:
            break
        output.write(chunk)
        written += len(chunk)
raise SystemExit(42 if written > maximum else 0)
' "$spool" "$MAX_PROJECTION_BYTES" <&0 &
  STDIN_READER=$!
  reader=$STDIN_READER
  (
    exec >/dev/null 2>&1
    local elapsed=0
    while [ "$elapsed" -lt "$STDIN_TIMEOUT_S" ]; do
      sleep 1
      kill -0 "$reader" 2>/dev/null || exit 0
      elapsed=$((elapsed + 1))
    done
    kill "$reader" 2>/dev/null
  ) &
  watchdog=$!
  wait "$reader" 2>/dev/null
  rc=$?
  STDIN_READER=""
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return "$rc"
}

normalize_positive_integer() {
  local normalized=$1
  case $normalized in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "${normalized#0}" != "$normalized" ]; do
    normalized=${normalized#0}
  done
  [ -n "$normalized" ] || return 1
  [ "${#normalized}" -lt 10 ] \
    || { [ "${#normalized}" -eq 10 ] && [ "$normalized" -le 2147483647 ]; } \
    || return 1
  printf '%s\n' "$normalized"
}

validate_stdin_timeout() {
  STDIN_TIMEOUT_S=$(normalize_positive_integer "$STDIN_TIMEOUT_S") || return 1
}

validate_projection_byte_limit() {
  MAX_PROJECTION_BYTES=$(normalize_positive_integer "$MAX_PROJECTION_BYTES") || return 1
  [ "$MAX_PROJECTION_BYTES" -le 1048576 ]
}

validate_publish_lock_timeout() {
  PUBLISH_LOCK_TIMEOUT_S=$(normalize_positive_integer "$PUBLISH_LOCK_TIMEOUT_S") || return 1
}

acquire_bounded_lock() {  # <lock>
  local lock=$1 attempts=0 max_attempts
  max_attempts=$((PUBLISH_LOCK_TIMEOUT_S * 10))
  while [ "$attempts" -lt "$max_attempts" ]; do
    [ "$PUBLISH_INTERRUPTED" -eq 0 ] || return 2
    if fm_lock_try_acquire "$lock"; then
      if [ "$PUBLISH_INTERRUPTED" -eq 0 ]; then
        return 0
      fi
      fm_lock_release "$lock"
      return 2
    fi
    [ "$PUBLISH_INTERRUPTED" -eq 0 ] || return 2
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

# Everything substantive runs inside this function so the tail of the script can
# hold the single unconditional `exit 0` that the contract above demands.
publish() {
  local read_status projection_bytes
  case $MAX_CACHE in
    ''|0|*[!0-9]*|0*)
      log "invalid FM_BUZZ_MAX_CACHE value '$MAX_CACHE': expected a positive integer"
      return 1
      ;;
  esac
  if ! validate_publish_lock_timeout; then
    log "FM_BUZZ_LOCK_TIMEOUT_S must be a positive integer no greater than 2147483647"
    return 1
  fi
  if ! validate_projection_byte_limit; then
    log "FM_BUZZ_MAX_PROJECTION_BYTES must be a positive integer no greater than 1048576"
    return 1
  fi

  if [ -z "$REPLAY_CHANNEL" ]; then
    STDIN_SPOOL=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-stdin.XXXXXX") || {
      log "could not create a temporary file for the projection"
      return 1
    }
    if [ "$REFRESH" -eq 1 ]; then
      "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json > "$STDIN_SPOOL" 2>/dev/null || {
        drop_stdin_spool
        log "bearings snapshot failed; skipping publish"
        return 1
      }
    else
      if ! validate_stdin_timeout; then
        drop_stdin_spool
        log "FM_BUZZ_STDIN_TIMEOUT_S must be a positive integer no greater than 2147483647"
        return 1
      fi
      if [ -t 0 ]; then
        log "stdin is a terminal; pipe the projection in or use --refresh"
        return 1
      fi
      read_stdin_bounded "$STDIN_SPOOL"
      read_status=$?
      if [ "$read_status" -ne 0 ]; then
        drop_stdin_spool
        if [ "$read_status" -eq 42 ]; then
          log "the projection exceeds FM_BUZZ_MAX_PROJECTION_BYTES (${MAX_PROJECTION_BYTES} bytes)"
          return 2
        fi
        log "could not read the projection from stdin within ${STDIN_TIMEOUT_S}s"
        return 1
      fi
    fi
    projection_bytes=$(wc -c < "$STDIN_SPOOL" | tr -d '[:space:]') || {
      drop_stdin_spool
      log "could not measure the projection"
      return 1
    }
    if [ "$projection_bytes" -gt "$MAX_PROJECTION_BYTES" ]; then
      drop_stdin_spool
      log "the projection exceeds FM_BUZZ_MAX_PROJECTION_BYTES (${MAX_PROJECTION_BYTES} bytes)"
      return 2
    fi
    [ -s "$STDIN_SPOOL" ] || {
      drop_stdin_spool
      log "the projection is empty; skipping publish"
      return 1
    }
    fm_buzz_validate_projection_json "$STDIN_SPOOL" || {
      drop_stdin_spool
      return 2
    }
    fm_buzz_validate_projection_contract "$STDIN_SPOOL" || {
      drop_stdin_spool
      return 2
    }
  fi

  local label=$CHANNEL_LABEL channel=$REPLAY_CHANNEL
  if [ -z "$channel" ]; then
    if [ -z "$label" ]; then
      label=$(fm_buzz_key_account "$FM_HOME")
    fi
    channel=$(fm_buzz_channel_id "$SCRIPT_DIR" "$label") || {
      log "could not derive the channel id"
      return 1
    }
  fi

  # The delivery lock is scoped to the queue this run owns, so it has to agree
  # with the cache partitioning on what "this relay" means - hence the same
  # normalization the cache digest uses, which also rejects credential-bearing
  # URLs before any of them can reach a lock name, a log line, or the network.
  local normalized_relay
  fm_buzz_capture node "$SCRIPT_DIR/fm-buzz-targets.mjs" normalize-relay "$RELAY" || {
    log "$FM_BUZZ_CAPTURED_DIAGNOSTIC"
    return 1
  }
  normalized_relay=$FM_BUZZ_CAPTURED_OUTPUT

  if [ -L "$REPLAY_DIR" ] || { [ -e "$REPLAY_DIR" ] && [ ! -d "$REPLAY_DIR" ]; }; then
    log "replay cache path $REPLAY_DIR is not a regular directory"
    return 1
  fi
  if [ -L "$STATE" ] || { [ -e "$STATE" ] && [ ! -d "$STATE" ]; }; then
    log "replay cache ancestor $STATE is not a regular directory"
    return 1
  fi
  PUBLISH_LOCK=$(fm_buzz_replay_transaction_lock "$STATE") || {
    log "could not resolve replay cache ownership"
    drop_stdin_spool
    return 1
  }
  acquire_bounded_lock "$PUBLISH_LOCK"
  lock_status=$?
  if [ "$lock_status" -ne 0 ]; then
    if [ "$lock_status" -eq 2 ]; then
      log "interrupted while waiting for replay cache ownership"
    else
      log "could not acquire replay cache ownership within ${PUBLISH_LOCK_TIMEOUT_S}s"
    fi
    drop_stdin_spool
    return 1
  fi

  # Whole-tree work, and the only thing the whole-tree lock is held for. Its
  # failures still have to reach this run's accounting, so they travel to the
  # delivery step in the envelope instead of being recomputed there.
  local migration
  # shellcheck disable=SC2016
  migration=$(node -e '
    const [modulePath, replayDir] = process.argv.slice(1);
    import(modulePath).then(({ migrateReplayCache }) => {
      process.stdout.write(JSON.stringify(migrateReplayCache(replayDir)));
    }).catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
  ' "$SCRIPT_DIR/fm-buzz-publish.mjs" "$REPLAY_DIR") || {
    log "could not settle the replay cache; skipping publish"
    drop_stdin_spool
    return 1
  }
  DELIVERY_LOCK=$(fm_buzz_replay_delivery_lock "$STATE" "$normalized_relay" "$channel") || {
    log "could not resolve this queue's delivery ownership"
    drop_stdin_spool
    return 1
  }
  DELIVERY_INTENT_LOCK=$(fm_buzz_replay_delivery_intent "$STATE" "$normalized_relay" "$channel" "$$") || {
    log "could not resolve this queue's delivery intent"
    drop_stdin_spool
    return 1
  }
  if ! fm_lock_try_acquire "$DELIVERY_INTENT_LOCK"; then
    log "could not register this queue's delivery intent"
    drop_stdin_spool
    return 1
  fi
  fm_lock_release "$PUBLISH_LOCK"
  PUBLISH_LOCK=""
  if [ -n "${FM_TEST_BUZZ_BEFORE_DELIVERY_LOCK_READY:-}" ]; then
    : > "$FM_TEST_BUZZ_BEFORE_DELIVERY_LOCK_READY"
    while [ ! -e "${FM_TEST_BUZZ_BEFORE_DELIVERY_LOCK_RELEASE:-}" ]; do
      [ "$PUBLISH_INTERRUPTED" -eq 0 ] || return 1
      sleep 0.01
    done
  fi
  acquire_bounded_lock "$DELIVERY_LOCK"
  local delivery_lock_status=$?
  if [ "$delivery_lock_status" -ne 0 ]; then
    if [ "$delivery_lock_status" -eq 2 ]; then
      log "interrupted while waiting for this queue's delivery ownership"
    else
      log "could not acquire this queue's delivery ownership within ${PUBLISH_LOCK_TIMEOUT_S}s"
    fi
    drop_stdin_spool
    return 1
  fi

  mkdir -p "$DATA" 2>/dev/null || {
    log "could not create $DATA"
    drop_stdin_spool
    return 1
  }
  KEYPAIR_LOCK=$(fm_buzz_key_transaction_lock "$DATA") || {
    log "could not resolve publishing key ownership"
    drop_stdin_spool
    return 1
  }
  acquire_bounded_lock "$KEYPAIR_LOCK"
  keypair_lock_status=$?
  if [ "$keypair_lock_status" -ne 0 ]; then
    if [ "$keypair_lock_status" -eq 2 ]; then
      log "interrupted while waiting for publishing key ownership"
    else
      log "could not acquire publishing key ownership within ${PUBLISH_LOCK_TIMEOUT_S}s"
    fi
    drop_stdin_spool
    return 1
  fi

  local key load_status rc preparation
  key=$(fm_buzz_key_load "$FM_HOME")
  load_status=$?
  if [ "$load_status" -ne 0 ]; then
    if [ "$load_status" -eq 1 ]; then
      log "no publishing keypair for this home; run bin/fm-buzz-keypair.sh first"
    else
      log "the stored publishing key could not be read; skipping publish"
    fi
    drop_stdin_spool
    return 1
  fi
  [ -n "$key" ] || { drop_stdin_spool; log "the stored publishing key is empty"; return 1; }

  # An unset name is an ABSENT envelope field, not an empty one: the engine's
  # default is what keeps the fleet channel named as it always was, and an empty
  # string would rename it to nothing.
  local name_field='{}'
  if [ -n "$CHANNEL_NAME" ]; then
    name_field=$(jq -n --arg channelName "$CHANNEL_NAME" '{channelName:$channelName}') || {
      drop_stdin_spool
      log "could not encode the channel name"
      return 1
    }
  fi

  # The envelope goes down a pipe, and neither private value is passed with `--arg`,
  # which would put it in jq's world-readable argv. The key reaches jq through a
  # file descriptor, while --rawfile reads the projection spool's bytes verbatim.
  # The remaining --arg values - relay URL, channel id, cache path - are not secrets.
  if [ -n "$REPLAY_CHANNEL" ]; then
    preparation=$(jq -n \
      --rawfile privateKey <(printf '%s' "$key") \
      --arg phase replay \
      --arg relay "$RELAY" \
      --arg channelId "$channel" \
      --arg replayDir "$REPLAY_DIR" \
      --arg targetsFile "$TARGETS_FILE" \
      --argjson timeoutMs "$TIMEOUT_MS" \
      --argjson maxCache "$MAX_CACHE" \
      --argjson migration "$migration" \
      --argjson channelName "$name_field" \
      '{phase:$phase, privateKey:$privateKey, relay:$relay, channelId:$channelId,
        replayDir:$replayDir, targetsFile:$targetsFile, migration:$migration,
        timeoutMs:$timeoutMs, maxCache:$maxCache} + $channelName' \
      | node "$SCRIPT_DIR/fm-buzz-publish.mjs")
  else
    preparation=$(jq -n \
      --rawfile privateKey <(printf '%s' "$key") \
      --rawfile content "$STDIN_SPOOL" \
      --arg phase prepare \
      --arg relay "$RELAY" \
      --arg channelId "$channel" \
      --arg replayDir "$REPLAY_DIR" \
      --arg targetsFile "$TARGETS_FILE" \
      --argjson timeoutMs "$TIMEOUT_MS" \
      --argjson maxCache "$MAX_CACHE" \
      --argjson migration "$migration" \
      --argjson channelName "$name_field" \
      '{phase:$phase, privateKey:$privateKey, content:$content, relay:$relay, channelId:$channelId,
        replayDir:$replayDir, targetsFile:$targetsFile, migration:$migration,
        timeoutMs:$timeoutMs, maxCache:$maxCache} + $channelName' \
      | node "$SCRIPT_DIR/fm-buzz-publish.mjs")
  fi
  rc=$?
  fm_lock_release "$KEYPAIR_LOCK"
  KEYPAIR_LOCK=""
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$DELIVERY_LOCK"
    DELIVERY_LOCK=""
    drop_stdin_spool
    return "$rc"
  fi

  jq -n \
    --rawfile privateKey <(printf '%s' "$key") \
    --arg phase deliver \
    --arg relay "$RELAY" \
    --arg channelId "$channel" \
    --arg replayDir "$REPLAY_DIR" \
    --arg targetsFile "$TARGETS_FILE" \
    --argjson timeoutMs "$TIMEOUT_MS" \
    --argjson maxCache "$MAX_CACHE" \
    --argjson migration "$migration" \
    --argjson preparation "$preparation" \
    --argjson channelName "$name_field" \
    '{phase:$phase, privateKey:$privateKey, relay:$relay, channelId:$channelId,
      replayDir:$replayDir, targetsFile:$targetsFile, migration:$migration,
      preparation:$preparation, timeoutMs:$timeoutMs, maxCache:$maxCache} + $channelName' \
    | node "$SCRIPT_DIR/fm-buzz-publish.mjs"
  rc=$?
  fm_lock_release "$DELIVERY_LOCK"
  DELIVERY_LOCK=""
  fm_lock_release "$DELIVERY_INTENT_LOCK"
  DELIVERY_INTENT_LOCK=""
  drop_stdin_spool
  return "$rc"
}

check_publish_prerequisites() {
  command -v python3 >/dev/null 2>&1 || {
    log "python3 is required for safe replay-cache operations; see docs/buzz-loopback-adapter.md#prerequisites"
    return 2
  }
  command -v node >/dev/null 2>&1 || { log "node is unavailable; skipping publish"; return 1; }
  node -e 'if (typeof globalThis.WebSocket !== "function") process.exit(1)' >/dev/null 2>&1 || {
    log "Node.js does not provide the global WebSocket API; skipping publish"
    return 1
  }
  command -v jq >/dev/null 2>&1 || { log "jq is unavailable; skipping publish"; return 1; }
}

ARGUMENT_ERROR=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --refresh) REFRESH=1 ;;
    --relay|--channel-label|--channel-name|--replay-channel|--timeout)
      option=$1
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        log "$option requires a value"
        ARGUMENT_ERROR=1
      else
        case $2 in
          --*) log "$option requires a value"; ARGUMENT_ERROR=1 ;;
          *)
            shift
            case $option in
              --relay) RELAY=$1 ;;
              --channel-label) CHANNEL_LABEL=$1 ;;
              --channel-name)
                # The name reaches the relay and then a reader's channel list, so
                # it is bounded and printable-only here rather than trusted from
                # the caller.
                if printf '%s' "$1" | LC_ALL=C grep -q '[^[:print:]]'; then
                  log "--channel-name must contain printable characters only"
                  ARGUMENT_ERROR=1
                elif [ "${#1}" -gt 100 ]; then
                  log "--channel-name is limited to 100 characters"
                  ARGUMENT_ERROR=1
                else
                  CHANNEL_NAME=$1
                fi
                ;;
              --replay-channel) REPLAY_CHANNEL=$1 ;;
              --timeout) TIMEOUT_MS=$1 ;;
            esac
            ;;
        esac
      fi
      ;;
    --help|-h)
      # Print the header comment block and stop at the first line of code, so
      # help never drifts out of sync with a hardcoded line range.
      awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) log "unknown argument: $1"; ARGUMENT_ERROR=1 ;;
  esac
  shift
done

if [ -n "$REPLAY_CHANNEL" ] && { [ "$REFRESH" -eq 1 ] || [ -n "$CHANNEL_LABEL" ]; }; then
  log "--replay-channel cannot be combined with --refresh or --channel-label"
  ARGUMENT_ERROR=1
fi

PREREQUISITE_STATUS=0
if [ "$ARGUMENT_ERROR" -eq 0 ]; then
  check_publish_prerequisites
  PREREQUISITE_STATUS=$?
fi
if [ "$PREREQUISITE_STATUS" -eq 2 ]; then
  exit 1
fi

PUBLISH_STATUS=0
if [ "$ARGUMENT_ERROR" -eq 1 ] || [ "$PREREQUISITE_STATUS" -ne 0 ]; then
  PUBLISH_STATUS=1
else
  publish
  PUBLISH_STATUS=$?
fi
if [ "$PUBLISH_STATUS" -eq 2 ]; then
  exit 1
fi
if [ "$PUBLISH_STATUS" -ne 0 ]; then
  # The single conversion point: a real failure becomes a logged non-event.
  log "publish did not complete; Firstmate is unaffected"
fi

# The contract. Do not make this conditional.
exit 0
