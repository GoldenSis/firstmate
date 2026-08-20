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
# --channel-name crew-<task id>, so a captain browsing a Buzz client reads a list
# of crews rather than a column of UUIDs. The name is display metadata and never
# touches the id derivation. The fleet channel is published with NO name option,
# which leaves the publisher's own default in place and keeps the name a captain
# has been reading alongside the id they have been reading.
#
# The replay cache already partitions by <endpoint-digest>/<channel-id>, and the
# delivery lock is already scoped per endpoint-and-channel, so publishing into
# several channels needs no new storage, no new lock, and no new protocol: each
# lane is one ordinary bin/fm-buzz-publish.sh invocation against its own channel.
# Lanes are published one at a time for that reason - the locks are per queue, and
# serial invocations keep the whole-tree replay barrier uncontended.
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
# This script reads Firstmate state only through the read-only bearings and fleet
# snapshots and never reads Buzz into Firstmate state. Buzz is a projection
# target, never a state source.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
TIMEOUT_MS=""
FLEET_ONLY=0
ARGUMENT_ERROR=0

log() {
  printf 'fm-buzz-refresh: %s\n' "$1" >&2
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
# shellcheck disable=SC2329 # Invoked by the traps below.
cleanup() {
  [ -n "$DOCUMENT" ] && rm -f -- "$DOCUMENT"
  [ -n "$PROJECTION" ] && rm -f -- "$PROJECTION"
  [ -n "$LANES" ] && rm -f -- "$LANES"
  DOCUMENT=""
  PROJECTION=""
  LANES=""
}
trap cleanup EXIT
# A signal is still a non-event for the fleet: drop the spools and take the same
# exit 0 a stopped relay takes, rather than leaving a projection in a shared
# temporary directory.
trap 'cleanup; exit 0' INT TERM HUP

publish_args() {  # <channel label> [channel name]
  printf '%s\n' --relay
  printf '%s\n' "$RELAY"
  printf '%s\n' --channel-label
  printf '%s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '%s\n' --channel-name
    printf '%s\n' "$2"
  fi
  if [ -n "$TIMEOUT_MS" ]; then
    printf '%s\n' --timeout
    printf '%s\n' "$TIMEOUT_MS"
  fi
}

# Publish one already-built projection into one channel. Every caller feeds the
# document on stdin, which is how it stays off a command line.
publish_document() {  # <channel label> <file> [channel name]
  local label=$1 file=$2 name=${3:-} args=()
  while IFS= read -r argument; do
    args+=("$argument")
  done < <(publish_args "$label" "$name")
  "$SCRIPT_DIR/fm-buzz-publish.sh" "${args[@]}" < "$file"
}

refresh() {
  local fleet_label lane_count=0 lane_failures=0

  PROJECTION=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-refresh.XXXXXX") || {
    log "could not create a temporary file for the projection"
    return 1
  }
  if ! "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json > "$PROJECTION" 2>/dev/null; then
    log "bearings snapshot failed; skipping publish"
    return 1
  fi

  fleet_label=$CHANNEL_LABEL
  if [ -z "$fleet_label" ]; then
    fleet_label=$(fm_buzz_key_account "$FM_HOME")
  fi

  publish_document "$fleet_label" "$PROJECTION"
  FLEET_STATUS=$?

  [ "$FLEET_ONLY" -eq 1 ] && return "$FLEET_STATUS"

  LANES=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-lanes.XXXXXX") || {
    log "could not create a temporary file for the crew lanes"
    return "$FLEET_STATUS"
  }
  if ! "$SCRIPT_DIR/fm-buzz-crew-lanes.sh" --projection "$PROJECTION" > "$LANES"; then
    log "crew lanes could not be projected; the fleet channel is unaffected"
    return "$FLEET_STATUS"
  fi

  local lane id label
  DOCUMENT=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-lane.XXXXXX") || {
    log "could not create a temporary file for a crew lane"
    return "$FLEET_STATUS"
  }
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    id=$(printf '%s' "$lane" | jq -r '.id // empty') || id=""
    if [ -z "$id" ]; then
      log "a crew lane carried no task id; skipping it"
      lane_failures=$((lane_failures + 1))
      continue
    fi
    if ! label=$(fm_buzz_crew_channel_label "$SCRIPT_DIR" "$fleet_label" "$id" 2>/dev/null); then
      log "could not derive a lane channel for $id; skipping it"
      lane_failures=$((lane_failures + 1))
      continue
    fi
    if ! printf '%s' "$lane" | jq -e '.projection' > "$DOCUMENT"; then
      log "could not read the lane projection for $id; skipping it"
      lane_failures=$((lane_failures + 1))
      continue
    fi
    # No length guard here: a task id is restricted to 64 characters by
    # crewChannelLabel, which the label derivation above has already enforced, so
    # `crew-<id>` cannot reach the publisher's 100-character bound.
    if publish_document "$label" "$DOCUMENT" "crew-$id"; then
      lane_count=$((lane_count + 1))
    else
      log "the lane for $id did not publish; the fleet channel is unaffected"
      lane_failures=$((lane_failures + 1))
    fi
  done < <(jq -c '.[]' "$LANES" 2>/dev/null)
  rm -f -- "$DOCUMENT"
  DOCUMENT=""

  # Deliberately not "published": the publisher owns delivery and reports its own
  # failures, and a fire-and-forget run cannot truthfully claim one landed.
  log "handed the fleet channel and ${lane_count} crew lane(s) to the publisher"
  [ "$lane_failures" -gt 0 ] && log "${lane_failures} crew lane(s) were skipped"
  return "$FLEET_STATUS"
}

if ! command -v jq >/dev/null 2>&1; then
  log "jq is unavailable; skipping publish"
  exit 0
fi

FLEET_STATUS=0
if [ "$ARGUMENT_ERROR" -eq 1 ]; then
  exit 1
fi
refresh
REFRESH_STATUS=$?
exit "$REFRESH_STATUS"
