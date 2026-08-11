#!/usr/bin/env bash
# fm-buzz-publish.sh - publish one bearings projection to the loopback Buzz relay.
#
# ============================ FIRE-AND-FORGET ==============================
# THIS SCRIPT ALWAYS EXITS 0. A NON-ZERO EXIT FROM THIS SCRIPT IS A BUG.
#
# Every failure path - relay down, connection refused, timeout, NIP-42 auth
# failure, event rejected, signing error, missing keypair, missing node, missing
# jq, unreadable replay cache, malformed snapshot, anything at all - must be
# caught, logged to stderr, and followed by exit 0. Nothing here may ever
# propagate a non-zero status into a caller.
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
#   - Do not add a `|| exit 1`, an `exit $?`, or a bare `exit` on any path.
#   - A failure the operator needs to see is a stderr line, never an exit code.
#   - The engine (bin/fm-buzz-publish.mjs) MAY exit non-zero; converting that into
#     a logged success is this wrapper's whole job.
# tests/fm-buzz-publish.test.sh asserts exit 0 with the relay stopped, and also
# greps this file to assert `set -e` has not crept back in.
# ===========================================================================
#
# The published event is one append-only NIP-29 channel message whose content is
# the `fm-bearings-snapshot.sh --json` projection VERBATIM, including its
# omitted[] disclosure array. The disclosure is what makes a bounded projection
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
#   fm-buzz-publish.sh --timeout <ms>  relay timeout (default 15000)
#   fm-buzz-publish.sh --help          this text
#
# Cache ownership waits at most FM_BUZZ_LOCK_TIMEOUT_S seconds (default 30).
# Invalid deadlines, acquisition timeouts, and interrupted waits are logged and
# converted to the same exit-0 non-event as every other publishing failure.
# Lock ordering is replay-cache ownership first and the per-home key transaction
# second; the publishing key is loaded and spent while both are held.
#
# Relay host note: the default is ws://localhost:3000, not ws://127.0.0.1:3000.
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
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
TIMEOUT_MS=${FM_BUZZ_TIMEOUT_MS:-15000}
MAX_CACHE=${FM_BUZZ_MAX_CACHE:-100}
REFRESH=0
REPLAY_DIR="$STATE/buzz-replay"
TARGETS_FILE="$DATA/buzz-publisher-targets.jsonl"

STDIN_TIMEOUT_S=${FM_BUZZ_STDIN_TIMEOUT_S:-30}
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
KEYPAIR_LOCK=""
PUBLISH_INTERRUPTED=0
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

# Spool stdin into the caller's file under a total deadline. Reports status only;
# the caller owns the spool and reads it afterwards.
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
  cat <&0 > "$spool" &
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

normalize_shell_timeout() {
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
  STDIN_TIMEOUT_S=$(normalize_shell_timeout "$STDIN_TIMEOUT_S") || return 1
}

validate_publish_lock_timeout() {
  PUBLISH_LOCK_TIMEOUT_S=$(normalize_shell_timeout "$PUBLISH_LOCK_TIMEOUT_S") || return 1
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
  command -v node >/dev/null 2>&1 || { log "node is unavailable; skipping publish"; return 1; }
  command -v jq >/dev/null 2>&1 || { log "jq is unavailable; skipping publish"; return 1; }
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
    # A terminal on stdin means nobody is piping a projection in at all, so this
    # is answerable without waiting out the deadline below.
    if [ -t 0 ]; then
      log "stdin is a terminal; pipe the projection in or use --refresh"
      return 1
    fi
    if ! read_stdin_bounded "$STDIN_SPOOL"; then
      drop_stdin_spool
      log "could not read the projection from stdin within ${STDIN_TIMEOUT_S}s"
      return 1
    fi
  fi
  [ -s "$STDIN_SPOOL" ] || {
    drop_stdin_spool
    log "the projection is empty; skipping publish"
    return 1
  }
  jq -s -e 'length == 1' "$STDIN_SPOOL" >/dev/null 2>&1 || {
    drop_stdin_spool
    log "the projection is not one valid JSON value; skipping publish"
    return 1
  }

  local label=$CHANNEL_LABEL
  if [ -z "$label" ]; then
    label=$(fm_buzz_key_account "$FM_HOME")
  fi

  local channel
  channel=$(fm_buzz_channel_id "$SCRIPT_DIR" "$label") || {
    log "could not derive the channel id"
    return 1
  }

  if [ -L "$REPLAY_DIR" ] || { [ -e "$REPLAY_DIR" ] && [ ! -d "$REPLAY_DIR" ]; }; then
    log "replay cache path $REPLAY_DIR is not a regular directory"
    return 1
  fi
  mkdir -p "$REPLAY_DIR" 2>/dev/null || { log "could not create $REPLAY_DIR"; return 1; }
  [ -d "$REPLAY_DIR" ] && [ ! -L "$REPLAY_DIR" ] \
    || { log "replay cache path $REPLAY_DIR is not a regular directory"; return 1; }
  chmod 0700 "$REPLAY_DIR" 2>/dev/null || true
  PUBLISH_LOCK="$STATE/.buzz-replay-publish.lock"
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

  local key load_status rc
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

  # The envelope goes down a pipe, and neither private value is passed with `--arg`,
  # which would put it in jq's world-readable argv. The key reaches jq through a
  # file descriptor, while --rawfile reads the projection spool's bytes verbatim.
  # The remaining --arg values - relay URL, channel id, cache path - are not secrets.
  jq -n \
    --rawfile privateKey <(printf '%s' "$key") \
    --rawfile content "$STDIN_SPOOL" \
    --arg relay "$RELAY" \
    --arg channelId "$channel" \
    --arg replayDir "$REPLAY_DIR" \
    --arg targetsFile "$TARGETS_FILE" \
    --argjson timeoutMs "$TIMEOUT_MS" \
    --argjson maxCache "$MAX_CACHE" \
    '{privateKey:$privateKey, content:$content, relay:$relay, channelId:$channelId,
      replayDir:$replayDir, targetsFile:$targetsFile,
      timeoutMs:$timeoutMs, maxCache:$maxCache}' \
    | node "$SCRIPT_DIR/fm-buzz-publish.mjs"
  rc=$?
  fm_lock_release "$KEYPAIR_LOCK"
  KEYPAIR_LOCK=""
  fm_lock_release "$PUBLISH_LOCK"
  PUBLISH_LOCK=""
  drop_stdin_spool
  return "$rc"
}

ARGUMENT_ERROR=0
while [ "$#" -gt 0 ]; do
  case $1 in
    --refresh) REFRESH=1 ;;
    --relay|--channel-label|--timeout)
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

if [ "$ARGUMENT_ERROR" -eq 1 ] || ! publish; then
  # The single conversion point: a real failure becomes a logged non-event.
  log "publish did not complete; Firstmate is unaffected"
fi

# The contract. Do not make this conditional.
exit 0
