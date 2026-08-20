#!/usr/bin/env bash
# fm-buzz-refresh.sh - the one entry point that publishes the fleet channel and
# every per-crew lane to the loopback Buzz relay.
#
# ============================ FIRE-AND-FORGET ==============================
# CREW-LANE FAILURES ARE LOGGED NON-EVENTS. THE FLEET PUBLICATION'S EXIT STATUS
# IS FORWARDED UNCHANGED.
#
# The fleet publication is the pre-existing behavior and keeps the contract
# bin/fm-buzz-publish.sh already owns: runtime publication failures exit 0, while
# a missing Python 3 and an invalid fm-bearings.v1 projection exit non-zero. Crew
# lanes are additive and may never make anything louder, so a lane that fails to
# project, address, or publish is logged and skipped. A relay that is down, slow,
# or absent is a non-event for the whole run: the wrapper still exits 0.
#
# Consequences that follow from the contract, for anyone editing this file:
#   - Do not add `set -e`. It is absent on purpose.
#   - Do not let a lane failure change the exit status.
#   - A lane failure the operator needs to see is a stderr line, never a status.
# tests/fm-buzz-crew-lanes.test.sh asserts exit 0 with the relay stopped, and
# also greps this file to assert `set -e` has not crept back in.
# ===========================================================================
#
# WHY THIS EXISTS
# Nothing auto-invokes Buzz. This is the single explicit call firstmate can make
# after a wake drain, so the captain can open one place and watch the fleet work.
# It is deliberately NOT a daemon, a watcher hook, a timer, or anything inside a
# crewmate's own execution path: Buzz stays off the critical path of firstmate and
# of every crewmate, which is what keeps a stopped relay unable to break a merge,
# a teardown, a wake drain, or a turn end.
#
# WHAT IT PUBLISHES
#   1. The fleet channel, exactly as before. Its label is unchanged - this home's
#      resolved FM_HOME, or --channel-label - so the channel keeps the id it has
#      always had and a captain's reading history is preserved.
#   2. One lane per in-flight task, each into its own derived channel. The label
#      is bin/fm-buzz-lib.mjs's crewChannelLabel(<fleet label>, <task id>), which
#      is a new NAME through the same channelIdForLabel derivation, not a new
#      derivation. bin/fm-buzz-crew-lanes.sh owns what a lane contains.
#
# HOW A LANE IS NAMED, AND WHY IT IS NOT THE LABEL. Each lane is published with
# --channel-name crew-<home qualifier>-<task id>, so a captain browsing a Buzz
# client can distinguish the same task id in two homes. The name is display
# metadata and never touches the id derivation. The fleet channel is published
# with NO name option, which leaves the publisher's own default in place and keeps
# the name a captain has been reading alongside the id they have been reading.
#
# The replay cache already partitions by <endpoint-digest>/<channel-id>, and the
# delivery lock is already scoped per endpoint-and-channel, so publishing into
# several channels needs no new storage, no new lock, and no new protocol: each
# lane is one ordinary bin/fm-buzz-publish.sh invocation against its own channel.
# Lanes are published one at a time for that reason - the locks are per queue, and
# serial invocations keep the whole-tree replay barrier uncontended.
# Nonempty replay partitions are retried even when their tasks are no longer live,
# so a projection cached before task completion is not stranded indefinitely.
#
# One bearings snapshot is taken and reused for both the fleet publication and the
# lane projection, so the two agree on what was in flight. bin/fm-buzz-crew-lanes.sh
# consults the canonical fleet snapshot once more for the identity and status
# stream it needs; that second read is off the critical path and is reconciled by
# id, with any in-flight entry it cannot match disclosed rather than guessed at.
#
# Usage:
#   fm-buzz-refresh.sh                    publish the fleet channel and every lane
#   fm-buzz-refresh.sh --fleet-only       publish only the fleet channel
#   fm-buzz-refresh.sh --relay <url>      override the relay (default ws://localhost:3000)
#   fm-buzz-refresh.sh --channel-label <s>
#                                         override the fleet channel-derivation label
#   fm-buzz-refresh.sh --timeout <ms>     relay timeout, passed through
#   fm-buzz-refresh.sh --help             this text
#
# The complete run is bounded by FM_BUZZ_REFRESH_TIMEOUT_S (default 30 seconds).
#
# This script reads Firstmate state only through the read-only bearings and fleet
# snapshots and never reads Buzz into Firstmate state. Buzz is a projection
# target, never a state source.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
TIMEOUT_MS=""
REFRESH_TIMEOUT_S=${FM_BUZZ_REFRESH_TIMEOUT_S:-30}
FLEET_ONLY=0
ARGUMENT_ERROR=0
REFRESH_DEADLINE=""
PUBLISH_DEADLINE_REACHED=0
ACTIVE_WATCHDOG_PID=""
REFRESH_INTERRUPTED=0
BOUNDED_OUTPUT=""
BOUNDED_DIAGNOSTIC=""

log() {
  printf 'fm-buzz-refresh: %s\n' "$1" >&2
}

run_before_deadline() {
  [ "$REFRESH_INTERRUPTED" -eq 0 ] || exit 0
  python3 -c '
import os
import signal
import subprocess
import sys
import time

class ForwardedSignal(BaseException):
    def __init__(self, signum):
        self.signum = signum


deadline = float(sys.argv[1])
process = None
finished = False
pending_signal = None


def signal_group(signum):
    if process is None:
        return
    try:
        os.killpg(process.pid, signum)
    except (ProcessLookupError, PermissionError):
        pass


def group_exists():
    if process is None:
        return False
    try:
        os.killpg(process.pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def forward_signal(signum, _frame):
    global pending_signal
    pending_signal = signum
    if process is None:
        return
    signal_group(signum)
    raise ForwardedSignal(signum)


for forwarded in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(forwarded, forward_signal)

remaining = deadline - time.monotonic()
if remaining <= 0:
    raise SystemExit(124)

result = 124
try:
    if pending_signal is not None:
        raise ForwardedSignal(pending_signal)
    process = subprocess.Popen(sys.argv[2:], start_new_session=True)
    if pending_signal is not None:
        signal_group(pending_signal)
        raise ForwardedSignal(pending_signal)
    grace = min(0.2, remaining / 4)
    result = process.wait(timeout=max(0, deadline - time.monotonic() - grace))
    finished = True
except OSError as error:
    print(error, file=sys.stderr)
    result = 127
except subprocess.TimeoutExpired:
    result = 124
except ForwardedSignal as interrupted:
    result = 128 + interrupted.signum
finally:
    for forwarded in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(forwarded, signal.SIG_IGN)
    if process is not None:
        signal_group(signal.SIGTERM)
        cleanup_deadline = time.monotonic() + min(0.2, max(0, deadline - time.monotonic()))
        if not finished:
            try:
                process.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass
        while group_exists() and time.monotonic() < cleanup_deadline:
            time.sleep(0.01)
        if group_exists():
            signal_group(signal.SIGKILL)
        if process.poll() is None:
            process.wait()
raise SystemExit(result)
' "$REFRESH_DEADLINE" "$@" <&0 &
  ACTIVE_WATCHDOG_PID=$!
  if [ "$REFRESH_INTERRUPTED" -ne 0 ]; then
    interrupt_refresh
  fi
  wait "$ACTIVE_WATCHDOG_PID"
  local status=$?
  ACTIVE_WATCHDOG_PID=""
  return "$status"
}

capture_before_deadline() {
  local status
  BOUNDED_OUTPUT=""
  BOUNDED_DIAGNOSTIC=""
  : > "$CAPTURE_OUTPUT" || return 127
  : > "$CAPTURE_DIAGNOSTIC" || return 127
  run_before_deadline "$@" > "$CAPTURE_OUTPUT" 2> "$CAPTURE_DIAGNOSTIC"
  status=$?
  BOUNDED_OUTPUT=$(cat -- "$CAPTURE_OUTPUT" 2>/dev/null)
  BOUNDED_DIAGNOSTIC=$(cat -- "$CAPTURE_DIAGNOSTIC" 2>/dev/null)
  return "$status"
}

refresh_remaining_ms() {
  python3 -c '
import sys
import time

remaining = max(0, int((float(sys.argv[1]) - time.monotonic()) * 1000))
print(remaining)
' "$REFRESH_DEADLINE"
}

classify_deadline() {
  local status=$1 remaining
  if [ "$status" -eq 124 ]; then
    PUBLISH_DEADLINE_REACHED=1
    return 0
  fi
  remaining=$(refresh_remaining_ms) || return 1
  if [ "$remaining" -le 0 ]; then
    PUBLISH_DEADLINE_REACHED=1
    return 0
  fi
  return 1
}

report_phase() {  # <status> <deadline message> <failure message>
  local status=$1 deadline_message=$2 failure_message=$3
  if classify_deadline "$status"; then
    log "$deadline_message"
    return 124
  fi
  if [ "$status" -ne 0 ]; then
    log "$failure_message"
    return 1
  fi
  return 0
}

capture_key_helper_before_deadline() {
  local helper=$1
  shift
  # shellcheck disable=SC2016
  capture_before_deadline bash -c '. "$1"; shift; "$@"' \
    bash "$SCRIPT_DIR/fm-buzz-key-lib.sh" "$helper" "$@"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --fleet-only) FLEET_ONLY=1 ;;
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
      awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) log "unknown argument: $1"; ARGUMENT_ERROR=1 ;;
  esac
  shift
done

# Every spool below holds fleet data - task ids, project names, blockers, PR URLs
# - in a shared temporary directory, so none of them may outlive this run.
PROJECTION=""
LANES=""
DOCUMENT=""
MIGRATION_STATE=""
CAPTURE_OUTPUT=""
CAPTURE_DIAGNOSTIC=""
# shellcheck disable=SC2329 # Invoked by the traps below.
cleanup() {
  [ -n "$DOCUMENT" ] && rm -f -- "$DOCUMENT"
  [ -n "$PROJECTION" ] && rm -f -- "$PROJECTION"
  [ -n "$LANES" ] && rm -f -- "$LANES"
  [ -n "$MIGRATION_STATE" ] && rm -f -- "$MIGRATION_STATE"
  [ -n "$CAPTURE_OUTPUT" ] && rm -f -- "$CAPTURE_OUTPUT"
  [ -n "$CAPTURE_DIAGNOSTIC" ] && rm -f -- "$CAPTURE_DIAGNOSTIC"
  DOCUMENT=""
  PROJECTION=""
  LANES=""
  MIGRATION_STATE=""
  CAPTURE_OUTPUT=""
  CAPTURE_DIAGNOSTIC=""
}
trap cleanup EXIT
# A signal is still a non-event for the fleet: drop the spools and take the same
# exit 0 a stopped relay takes, rather than leaving a projection in a shared
# temporary directory.
interrupt_refresh() {
  REFRESH_INTERRUPTED=1
  [ -n "$ACTIVE_WATCHDOG_PID" ] || return 0
  trap '' INT TERM HUP
  kill -TERM "$ACTIVE_WATCHDOG_PID" 2>/dev/null
  wait "$ACTIVE_WATCHDOG_PID" 2>/dev/null
  ACTIVE_WATCHDOG_PID=""
  cleanup
  exit 0
}
trap interrupt_refresh INT TERM HUP

publish_bounded() {  # <file or empty> <publisher arguments...>
  local file=$1 remaining_ms remaining_s requested effective lock_timeout status
  shift
  local args=("$@")
  PUBLISH_DEADLINE_REACHED=0
  remaining_ms=$(refresh_remaining_ms) || return 127
  if [ "$remaining_ms" -le 0 ]; then
    PUBLISH_DEADLINE_REACHED=1
    return 124
  fi
  requested=${TIMEOUT_MS:-${FM_BUZZ_TIMEOUT_MS:-15000}}
  case $requested in
    ''|*[!0-9]*|0|0*) ;;
    *)
      effective=$requested
      [ "$effective" -gt "$remaining_ms" ] && effective=$remaining_ms
      args+=(--timeout "$effective")
      ;;
  esac
  if [ -n "$TIMEOUT_MS" ]; then
    case $TIMEOUT_MS in ''|*[!0-9]*|0|0*) args+=(--timeout "$TIMEOUT_MS") ;; esac
  fi
  lock_timeout=${FM_BUZZ_LOCK_TIMEOUT_S:-30}
  remaining_s=$(((remaining_ms + 999) / 1000))
  case $lock_timeout in
    ''|*[!0-9]*|0|0*) ;;
    *) [ "$lock_timeout" -gt "$remaining_s" ] && lock_timeout=$remaining_s ;;
  esac
  if [ -n "$file" ]; then
    FM_BUZZ_LOCK_TIMEOUT_S=$lock_timeout FM_BUZZ_MIGRATION_STATE_FILE=$MIGRATION_STATE \
      run_before_deadline "$SCRIPT_DIR/fm-buzz-publish.sh" "${args[@]}" < "$file"
  else
    FM_BUZZ_LOCK_TIMEOUT_S=$lock_timeout FM_BUZZ_MIGRATION_STATE_FILE=$MIGRATION_STATE \
      run_before_deadline "$SCRIPT_DIR/fm-buzz-publish.sh" "${args[@]}" < /dev/null
  fi
  status=$?
  classify_deadline "$status" >/dev/null
  return "$status"
}

publish_document() {  # <channel label> <file> [channel name]
  local label=$1 file=$2 name=${3:-}
  local args=(--relay "$RELAY" --channel-label "$label")
  [ -n "$name" ] && args+=(--channel-name "$name")
  publish_bounded "$file" "${args[@]}"
}

replay_channel() {  # <channel id>
  publish_bounded "" --relay "$RELAY" --replay-channel "$1"
}

refresh() {
  local home_label home_channel home_qualifier fleet_label fleet_channel
  local lane_count=0 disclosure_count=0 lane_failures=0 replay_count=0 replay_failures=0
  local addressed_channels="" pending_channels="" replay_channels=""
  local replay_total=0 replay_index=0 lane_total=0 lane_index=0 skipped=0
  local phase_status=0 lane_rows=""

  REFRESH_DEADLINE=$(python3 -c \
    'import sys, time; print(time.monotonic() + int(sys.argv[1]))' "$REFRESH_TIMEOUT_S") || {
    log "could not start the refresh deadline"
    return 0
  }

  PROJECTION=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-refresh.XXXXXX") || {
    log "could not create a temporary file for the projection"
    return 0
  }
  MIGRATION_STATE=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-migration.XXXXXX") || {
    log "could not create a temporary file for cache migration state"
    return 0
  }
  CAPTURE_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-bounded-output.XXXXXX") || {
    log "could not create a temporary file for bounded output"
    return 0
  }
  CAPTURE_DIAGNOSTIC=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-bounded-error.XXXXXX") || {
    log "could not create a temporary file for bounded diagnostics"
    return 0
  }
  run_before_deadline "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json > "$PROJECTION" 2>/dev/null
  report_phase "$?" \
    "refresh deadline reached while taking the bearings snapshot; publish was skipped" \
    "bearings snapshot failed; skipping publish" || return 0

  capture_key_helper_before_deadline fm_buzz_key_account "$FM_HOME"
  phase_status=$?
  home_label=$BOUNDED_OUTPUT
  report_phase "$phase_status" \
    "refresh deadline reached while deriving the home label; publish was skipped" \
    "could not derive the home label; skipping publish" || return 0
  capture_key_helper_before_deadline fm_buzz_channel_id "$SCRIPT_DIR" "$home_label"
  phase_status=$?
  home_channel=$BOUNDED_OUTPUT
  report_phase "$phase_status" \
    "refresh deadline reached while deriving the home qualifier; publish was skipped" \
    "could not derive the home qualifier; skipping publish" || return 0
  home_qualifier=${home_channel%%-*}
  fleet_label=$CHANNEL_LABEL
  if [ -z "$fleet_label" ]; then
    fleet_label=$home_label
  fi
  capture_key_helper_before_deadline fm_buzz_channel_id "$SCRIPT_DIR" "$fleet_label"
  phase_status=$?
  fleet_channel=$BOUNDED_OUTPUT
  report_phase "$phase_status" \
    "refresh deadline reached while deriving the fleet channel; publish was skipped" \
    "could not derive the fleet channel; skipping publish" || return 0
  addressed_channels=" $fleet_channel "

  publish_document "$fleet_label" "$PROJECTION"
  FLEET_STATUS=$?
  classify_deadline "$FLEET_STATUS" >/dev/null
  if [ "$FLEET_STATUS" -eq 124 ]; then
    FLEET_STATUS=0
  fi

  if [ "$PUBLISH_DEADLINE_REACHED" -eq 1 ]; then
    if [ "$FLEET_ONLY" -eq 1 ]; then
      log "refresh deadline reached while publishing the fleet channel"
    else
      log "refresh deadline reached after the fleet channel; crew lanes and cached queue replay were skipped"
    fi
    return "$FLEET_STATUS"
  fi
  [ "$FLEET_ONLY" -eq 1 ] && return "$FLEET_STATUS"

  LANES=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-lanes.XXXXXX") || {
    log "could not create a temporary file for the crew lanes"
    return "$FLEET_STATUS"
  }
  run_before_deadline "$SCRIPT_DIR/fm-buzz-crew-lanes.sh" --projection "$PROJECTION" > "$LANES"
  report_phase "$?" \
    "refresh deadline reached while projecting crew lanes; cached queue replay was skipped" \
    "crew lanes could not be projected; the fleet channel is unaffected" || return "$FLEET_STATUS"

  local lane id label channel disclosure_only publish_status
  DOCUMENT=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-lane.XXXXXX") || {
    log "could not create a temporary file for a crew lane"
    return "$FLEET_STATUS"
  }
  capture_before_deadline jq 'length' "$LANES"
  phase_status=$?
  lane_total=$BOUNDED_OUTPUT
  report_phase "$phase_status" \
    "refresh deadline reached while reading the crew lane set; crew lanes and cached queue replay were skipped" \
    "crew lanes could not be read; the fleet channel is unaffected" || return "$FLEET_STATUS"
  capture_before_deadline jq -c '.[]' "$LANES"
  phase_status=$?
  lane_rows=$BOUNDED_OUTPUT
  report_phase "$phase_status" \
    "refresh deadline reached while reading the crew lane set; crew lanes and cached queue replay were skipped" \
    "crew lanes could not be read; the fleet channel is unaffected" || return "$FLEET_STATUS"
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    lane_index=$((lane_index + 1))
    capture_before_deadline jq -r '.id // empty' <<<"$lane"
    phase_status=$?
    id=$BOUNDED_OUTPUT
    skipped=$((lane_total - lane_index + 1))
    report_phase "$phase_status" \
      "refresh deadline reached; ${skipped} live crew lane(s) and cached queue replay were skipped" \
      "a crew lane carried no task id; skipping it"
    phase_status=$?
    case $phase_status in
      124) break ;;
      1) lane_failures=$((lane_failures + 1)); continue ;;
    esac
    if [ -z "$id" ]; then
      log "a crew lane carried no task id; skipping it"
      lane_failures=$((lane_failures + 1))
      continue
    fi
    capture_before_deadline jq -r '.disclosure_only // false' <<<"$lane"
    phase_status=$?
    disclosure_only=$BOUNDED_OUTPUT
    skipped=$((lane_total - lane_index + 1))
    report_phase "$phase_status" \
      "refresh deadline reached; ${skipped} live crew lane(s) and cached queue replay were skipped" \
      "could not read the lane kind for $id; skipping it"
    phase_status=$?
    case $phase_status in
      124) break ;;
      1) lane_failures=$((lane_failures + 1)); continue ;;
    esac
    capture_key_helper_before_deadline fm_buzz_crew_channel_label \
      "$SCRIPT_DIR" "$fleet_label" "$id"
    phase_status=$?
    label=$BOUNDED_OUTPUT
    skipped=$((lane_total - lane_index + 1))
    report_phase "$phase_status" \
      "refresh deadline reached; ${skipped} live crew lane(s) and cached queue replay were skipped" \
      "could not derive a lane channel for $id; skipping it"
    phase_status=$?
    case $phase_status in
      124) break ;;
      1) lane_failures=$((lane_failures + 1)); continue ;;
    esac
    capture_key_helper_before_deadline fm_buzz_channel_id \
      "$SCRIPT_DIR" "$label"
    phase_status=$?
    channel=$BOUNDED_OUTPUT
    skipped=$((lane_total - lane_index + 1))
    report_phase "$phase_status" \
      "refresh deadline reached; ${skipped} live crew lane(s) and cached queue replay were skipped" \
      "could not derive a lane channel for $id; skipping it"
    phase_status=$?
    case $phase_status in
      124) break ;;
      1) lane_failures=$((lane_failures + 1)); continue ;;
    esac
    addressed_channels="${addressed_channels}${channel} "
    capture_before_deadline jq -e '.projection' <<<"$lane"
    phase_status=$?
    printf '%s\n' "$BOUNDED_OUTPUT" > "$DOCUMENT"
    skipped=$((lane_total - lane_index + 1))
    report_phase "$phase_status" \
      "refresh deadline reached; ${skipped} live crew lane(s) and cached queue replay were skipped" \
      "could not read the lane projection for $id; skipping it"
    phase_status=$?
    case $phase_status in
      124) break ;;
      1) lane_failures=$((lane_failures + 1)); continue ;;
    esac
    publish_document "$label" "$DOCUMENT" "crew-${home_qualifier}-$id"
    publish_status=$?
    if classify_deadline "$publish_status"; then
      if [ "$publish_status" -eq 0 ]; then
        if [ "$disclosure_only" = true ]; then
          disclosure_count=$((disclosure_count + 1))
        else
          lane_count=$((lane_count + 1))
        fi
      fi
      skipped=$((lane_total - lane_index))
      [ "$publish_status" -ne 0 ] && skipped=$((skipped + 1))
      log "refresh deadline reached; ${skipped} live crew lane(s) and cached queue replay were skipped"
      break
    elif [ "$publish_status" -eq 0 ]; then
      if [ "$disclosure_only" = true ]; then
        disclosure_count=$((disclosure_count + 1))
      else
        lane_count=$((lane_count + 1))
      fi
    else
      log "the lane for $id did not publish; the fleet channel is unaffected"
      lane_failures=$((lane_failures + 1))
    fi
  done <<EOF
$lane_rows
EOF
  rm -f -- "$DOCUMENT"
  DOCUMENT=""

  if [ "$PUBLISH_DEADLINE_REACHED" -eq 0 ]; then
    # shellcheck disable=SC2016 # Node source, not a shell expansion.
    capture_before_deadline node -e '
      import(process.argv[1]).then(({ listPendingReplayChannels }) => {
        process.stdout.write(`${listPendingReplayChannels(process.argv[2], process.argv[3]).join("\n")}\n`);
      }).catch((error) => {
        process.stderr.write(`${error.message}\n`);
        process.exitCode = 1;
      });
    ' "$SCRIPT_DIR/fm-buzz-publish.mjs" "$(fm_buzz_replay_cache_dir "$STATE")" "$RELAY"
    phase_status=$?
    report_phase "$phase_status" \
      "refresh deadline reached while inspecting cached queue replay" \
      "could not inspect cached queue replay: $BOUNDED_DIAGNOSTIC"
    phase_status=$?
    case $phase_status in
      0)
        pending_channels=$BOUNDED_OUTPUT
        [ -z "$BOUNDED_DIAGNOSTIC" ] \
          || printf '%s\n' "$BOUNDED_DIAGNOSTIC" >&2
        ;;
      *) replay_failures=$((replay_failures + 1)) ;;
    esac
    while IFS= read -r channel; do
      [ -n "$channel" ] || continue
      case $addressed_channels in *" $channel "*) continue ;; esac
      replay_channels="${replay_channels}${channel}
"
      replay_total=$((replay_total + 1))
    done <<EOF
$pending_channels
EOF
    while IFS= read -r channel; do
      [ -n "$channel" ] || continue
      replay_index=$((replay_index + 1))
      replay_channel "$channel"
      publish_status=$?
      if classify_deadline "$publish_status"; then
        [ "$publish_status" -eq 0 ] && replay_count=$((replay_count + 1))
        skipped=$((replay_total - replay_index))
        [ "$publish_status" -ne 0 ] && skipped=$((skipped + 1))
        log "refresh deadline reached; ${skipped} cached queue(s) were skipped"
        break
      elif [ "$publish_status" -eq 0 ]; then
        replay_count=$((replay_count + 1))
      else
        log "cached queue $channel did not replay; the fleet channel is unaffected"
        replay_failures=$((replay_failures + 1))
      fi
    done <<EOF
$replay_channels
EOF
  fi

  # Deliberately not "published": the publisher owns delivery and reports its own
  # failures, and a fire-and-forget run cannot truthfully claim one landed.
  log "handed the fleet channel and ${lane_count} crew lane(s) to the publisher"
  [ "$disclosure_count" -gt 0 ] \
    && log "handed ${disclosure_count} crew-lane omission disclosure(s) to the publisher"
  [ "$lane_failures" -gt 0 ] && log "${lane_failures} crew lane(s) were skipped"
  [ "$replay_count" -gt 0 ] && log "retried ${replay_count} cached queue(s)"
  [ "$replay_failures" -gt 0 ] && log "${replay_failures} cached queue replay attempt(s) were skipped"
  return "$FLEET_STATUS"
}

if ! command -v python3 >/dev/null 2>&1; then
  log "python3 is required for safe replay-cache operations; see docs/buzz-loopback-adapter.md#prerequisites"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq is unavailable; skipping publish"
  exit 0
fi
case $REFRESH_TIMEOUT_S in
  ''|*[!0-9]*|0|0*)
    log "FM_BUZZ_REFRESH_TIMEOUT_S must be a positive integer without a leading zero"
    exit 0
    ;;
esac

FLEET_STATUS=0
if [ "$ARGUMENT_ERROR" -eq 1 ]; then
  exit 1
fi
refresh
REFRESH_STATUS=$?
exit "$REFRESH_STATUS"
