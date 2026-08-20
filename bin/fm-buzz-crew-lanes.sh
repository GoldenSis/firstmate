#!/usr/bin/env bash
# fm-buzz-crew-lanes.sh - project one bearings projection into per-crew lane documents.
#
# Read-only. It prints a JSON array on stdout and mutates nothing: no locks, no
# cache, no network, no relay. Publication is bin/fm-buzz-publish.sh's job and
# addressing a lane is bin/fm-buzz-refresh.sh's; this script only decides what a
# lane CONTAINS.
#
# WHAT A LANE IS
# One document per in-flight task, so a reader who opens a crewmate's channel
# sees that crewmate's status stream and nothing else. Each lane is itself a valid
# `fm-bearings.v1` projection - same schema, same home/generated/prs identity,
# and an in_flight[] narrowed to exactly one row - so the publisher validates and
# signs it through the path it already has, with no second contract to keep in
# sync. Two fields are added on top:
#   crew{id,kind,harness,mode}  identity, so a lane reads standalone.
#   status_events[]             the bounded status stream for that task.
# `view:"crew-lane"` marks the narrowing, so a lane is never mistaken for the
# fleet projection by a reader that only looked at `schema`.
#
# WHERE THE DATA COMES FROM, AND WHY THAT IS THE WHOLE LIST
# The fleet projection on stdin supplies home, generated, prs, the in_flight row,
# and the omitted[] disclosure. bin/fm-fleet-snapshot.sh --json - the canonical
# read-only snapshot, consulted once - supplies kind, harness, mode, and the path
# of each task's status log. The status stream itself is read from that named
# path, because the canonical snapshot exposes only `last_event`, never the
# stream; that check is what AGENTS.md-era guidance means by looking before
# writing a new reader, and the result is recorded in docs/buzz-loopback-adapter.md.
#
# NO WIDENING (per-crew lane non-widening contract). A lane may carry only what the fleet
# projection already publishes about a task, at more depth - never a surface the
# fleet projection deliberately dropped. The dropped surfaces are the ones the
# projection enumerates in its own omitted[]: backlog bodies, task paths,
# watch/steer actions, and endpoint detail. None of them appear here. Worktree
# paths, home paths, status-log paths, endpoint targets, and backends are
# deliberately NOT copied into a lane even though this script has them in hand.
# Status-line text is not a dropped surface: the fleet projection already
# publishes it as in_flight[].doing, so a lane publishes more of the same stream,
# bounded and disclosed, rather than something new.
#
# Every bound discloses itself in the lane's own omitted[], appended AFTER the
# fleet projection's entries, which are carried through untouched. A bounded
# projection whose truncation disclosure was stripped is worse than no projection,
# because an absence stops being unambiguous.
#
# The lane set is exactly the in_flight[] set the fleet projection already
# published, so a task the fleet projection bounded away does not gain a lane by
# the back door. An in_flight entry with no current task record in the snapshot -
# the two reads are taken moments apart, so a task can land between them - is
# skipped and disclosed rather than guessed at.
#
# Usage:
#   fm-buzz-crew-lanes.sh                      read the projection JSON on stdin
#   fm-buzz-crew-lanes.sh --projection <file>  read it from a file instead
#   fm-buzz-crew-lanes.sh --help               this text
#
# Bounds (all overridable, all disclosed when they bite):
#   FM_BUZZ_CREW_STATUS_LINES       status events per lane           (default 40)
#   FM_BUZZ_CREW_STATUS_BYTES       bytes read per status log        (default 16384)
#   FM_BUZZ_CREW_STATUS_LINE_CHARS  characters per status event      (default 200)
#   FM_BUZZ_CREW_INPUT_BYTES        projection input cap             (default 1048576)
#
# Exit status: 0 with the array on stdout, 1 on a bad input or an unreadable
# snapshot. This script is NOT the fire-and-forget boundary - bin/fm-buzz-refresh.sh
# is - so a failure here is visible rather than converted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-buzz-projection-lib.sh
. "$SCRIPT_DIR/fm-buzz-projection-lib.sh"

STATUS_LINES=${FM_BUZZ_CREW_STATUS_LINES:-40}
STATUS_BYTES=${FM_BUZZ_CREW_STATUS_BYTES:-16384}
STATUS_LINE_CHARS=${FM_BUZZ_CREW_STATUS_LINE_CHARS:-200}
INPUT_BYTES=${FM_BUZZ_CREW_INPUT_BYTES:-1048576}
PROJECTION_FILE=""

log() {
  printf 'fm-buzz-crew-lanes: %s\n' "$1" >&2
}

validate_bound() {  # <name> <value>
  case $2 in
    ''|*[!0-9]*|0|0*)
      log "$1 must be a positive integer without a leading zero"
      return 1
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --projection)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        log "--projection requires a value"
        exit 1
      fi
      case $2 in
        --*) log "--projection requires a value"; exit 1 ;;
      esac
      shift
      PROJECTION_FILE=$1
      ;;
    --help|-h)
      awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) log "unknown argument: $1"; exit 1 ;;
  esac
  shift
done

for bound in FM_BUZZ_CREW_STATUS_LINES:$STATUS_LINES \
             FM_BUZZ_CREW_STATUS_BYTES:$STATUS_BYTES \
             FM_BUZZ_CREW_STATUS_LINE_CHARS:$STATUS_LINE_CHARS \
             FM_BUZZ_CREW_INPUT_BYTES:$INPUT_BYTES; do
  validate_bound "${bound%%:*}" "${bound#*:}" || exit 1
done

command -v jq >/dev/null 2>&1 || { log "jq is unavailable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { log "python3 is unavailable"; exit 1; }

SPOOL=""
STATUS_SPOOL=""
STATUS_WINDOW_SPOOL=""
cleanup() {
  [ -n "$STATUS_WINDOW_SPOOL" ] && rm -f -- "$STATUS_WINDOW_SPOOL"
  [ -n "$STATUS_SPOOL" ] && rm -f -- "$STATUS_SPOOL"
  [ -n "$SPOOL" ] && rm -f -- "$SPOOL"
  STATUS_WINDOW_SPOOL=""
  STATUS_SPOOL=""
  SPOOL=""
}
trap cleanup EXIT

SPOOL=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-crew-lanes.XXXXXX") || {
  log "could not create a temporary file for the projection"
  exit 1
}
STATUS_SPOOL=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-crew-status.XXXXXX") || {
  log "could not create a temporary file for status events"
  exit 1
}
STATUS_WINDOW_SPOOL=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-crew-status-window.XXXXXX") || {
  log "could not create a temporary file for the bounded status window"
  exit 1
}

if [ -n "$PROJECTION_FILE" ]; then
  [ -r "$PROJECTION_FILE" ] || { log "cannot read the projection file: $PROJECTION_FILE"; exit 1; }
  head -c "$((INPUT_BYTES + 1))" < "$PROJECTION_FILE" > "$SPOOL" || {
    log "could not read $PROJECTION_FILE"
    exit 1
  }
else
  if [ -t 0 ]; then
    log "stdin is a terminal; pipe a bearings projection in or use --projection"
    exit 1
  fi
  head -c "$((INPUT_BYTES + 1))" > "$SPOOL" || {
    log "could not read the projection from stdin"
    exit 1
  }
fi

if [ "$(wc -c < "$SPOOL" | tr -d '[:space:]')" -gt "$INPUT_BYTES" ]; then
  log "the projection exceeds FM_BUZZ_CREW_INPUT_BYTES (${INPUT_BYTES} bytes)"
  exit 1
fi

fm_buzz_validate_projection_json "$SPOOL" || exit 1
fm_buzz_validate_projection_contract "$SPOOL" || exit 1

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || {
  log "the canonical fleet snapshot failed; no lanes projected"
  exit 1
}

# Bounded read of one status log, as JSON. The byte bound is applied from the END
# of the file, because the interesting events are the recent ones and a status log
# only grows at the tail. A byte-bounded tail can start mid-line; that partial
# leading line is dropped rather than published as if it were a whole event.
status_events_json() {  # <path>
  local path=$1 bytes=0 byte_truncated=false input=$STATUS_SPOOL
  if [ ! -f "$path" ]; then
    jq -n '{present:false,events:[],line_truncated:false,byte_truncated:false,total:0,shown:0}'
    return 0
  fi
  if ! tail -c "$((STATUS_BYTES + 1))" < "$path" > "$STATUS_SPOOL"; then
    return 1
  fi
  bytes=$(wc -c < "$STATUS_SPOOL" | tr -d '[:space:]')
  case $bytes in ''|*[!0-9]*) bytes=0 ;; esac
  if [ "$bytes" -gt "$STATUS_BYTES" ]; then
    byte_truncated=true
    tail -c "$STATUS_BYTES" < "$STATUS_SPOOL" > "$STATUS_WINDOW_SPOOL" || return 1
    input=$STATUS_WINDOW_SPOOL
  fi
  jq -Rn \
    --argjson max_lines "$STATUS_LINES" \
    --argjson max_chars "$STATUS_LINE_CHARS" \
    --argjson byte_truncated "$byte_truncated" '
      [inputs | select(test("^[[:space:]]*$") | not)] as $lines
      | (if $byte_truncated and ($lines | length) > 0 then $lines[1:] else $lines end) as $whole
      | ($whole | length) as $total
      | (if $total > $max_lines then $whole[-$max_lines:] else $whole end) as $kept
      | {
          present: true,
          total: $total,
          shown: ($kept | length),
          line_truncated: ($kept | any(. | length > $max_chars)),
          byte_truncated: $byte_truncated,
          events: ($kept | map(if length > $max_chars then .[:$max_chars] else . end))
        }' < "$input"
}

LANES='[]'
MISSING_TASKS=0
FAILED_LANES=0
FIRST_SKIPPED_ID=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  task=$(printf '%s' "$SNAPSHOT" | jq -c --arg id "$id" 'first(.tasks[] | select(.id == $id)) // empty')
  if [ -z "$task" ]; then
    MISSING_TASKS=$((MISSING_TASKS + 1))
    [ -n "$FIRST_SKIPPED_ID" ] || FIRST_SKIPPED_ID=$id
    continue
  fi
  status_path=$(printf '%s' "$task" | jq -r '.paths.status_log.path // ""')
  status=$(status_events_json "$status_path") || {
    log "could not read the status stream for $id"
    FAILED_LANES=$((FAILED_LANES + 1))
    [ -n "$FIRST_SKIPPED_ID" ] || FIRST_SKIPPED_ID=$id
    continue
  }
  lane=$(printf '%s\n%s\n' "$task" "$status" | jq -sc \
    --arg id "$id" \
    --argjson status_lines "$STATUS_LINES" \
    --argjson status_bytes "$STATUS_BYTES" \
    --argjson status_chars "$STATUS_LINE_CHARS" \
    --slurpfile projection "$SPOOL" '
      .[0] as $task
      | .[1] as $status
      | $projection[0]
      | first(.in_flight[] | select(.id == $id)) as $row
      | {
          schema: "fm-bearings.v1",
          view: "crew-lane",
          home: .home,
          generated: .generated,
          prs: .prs,
          in_flight: [$row],
          crew: {
            id: $id,
            kind: (if ($task.kind // "") == "" then "unknown" else $task.kind end),
            harness: (if ($task.harness // "") == "" then "unknown" else $task.harness end),
            mode: (if ($task.mode // "") == "" then "unknown" else $task.mode end)
          },
          status_events: $status.events,
          omitted: (.omitted
            + (if $status.present then []
               else [{surface: "status events for \($id): no status log recorded",
                      reveal: "inspect the task on the fleet view"}] end)
            + (if $status.byte_truncated
               then [{surface: "status events for \($id) read from the last \($status_bytes) bytes only",
                      reveal: "raise FM_BUZZ_CREW_STATUS_BYTES"}] else [] end)
            + (if $status.total > $status.shown
               then [{surface: "status events for \($id) showing \($status.shown) of \($status.total)",
                      reveal: "raise FM_BUZZ_CREW_STATUS_LINES"}] else [] end)
            + (if $status.line_truncated
               then [{surface: "status event text for \($id) truncated at \($status_chars) characters",
                      reveal: "raise FM_BUZZ_CREW_STATUS_LINE_CHARS"}] else [] end))
        }
    ') || {
    log "could not project a lane for $id"
    FAILED_LANES=$((FAILED_LANES + 1))
    [ -n "$FIRST_SKIPPED_ID" ] || FIRST_SKIPPED_ID=$id
    continue
  }
  LANES=$(printf '%s\n%s\n' "$LANES" "$lane" \
    | jq -sc --arg id "$id" '. as $documents | $documents[0] + [{id: $id, projection: $documents[1]}]') || {
    log "could not collect the lane for $id"
    exit 1
  }
done <<EOF
$(jq -r '.in_flight[].id // empty' "$SPOOL")
EOF

# A lane that could not be projected is disclosed in every lane that could, for
# the same reason every other bound is: a reader must never mistake a bounded
# lane set for the whole fleet.
if [ "$MISSING_TASKS" -gt 0 ] || [ "$FAILED_LANES" -gt 0 ]; then
  [ "$MISSING_TASKS" -eq 0 ] \
    || log "$MISSING_TASKS crew lane(s) skipped: no current task record"
  [ "$FAILED_LANES" -eq 0 ] \
    || log "$FAILED_LANES crew lane(s) skipped: current task or status data could not be projected"
  DISCLOSURES=$(jq -cn \
    --argjson missing "$MISSING_TASKS" \
    --argjson failed "$FAILED_LANES" '
      (if $missing > 0 then [{
        surface: "crew lanes: \($missing) in-flight entr\(if $missing == 1 then "y" else "ies" end) had no current task record",
        reveal: "re-run after the fleet settles"
      }] else [] end)
      + (if $failed > 0 then [{
        surface: "crew lanes: \($failed) in-flight entr\(if $failed == 1 then "y" else "ies" end) could not be projected from current task or status data",
        reveal: "inspect the projector diagnostics and re-run"
      }] else [] end)') || {
    log "could not build the unprojected-lane disclosure"
    exit 1
  }
  LANES=$(jq -c --argjson disclosures "$DISCLOSURES" \
    'map(.projection.omitted += $disclosures)' <<<"$LANES") || {
    log "could not record the unprojected-lane disclosure"
    exit 1
  }
  if [ "$(jq 'length' <<<"$LANES")" -eq 0 ]; then
    LANES=$(jq -c \
      --arg id "$FIRST_SKIPPED_ID" \
      --argjson disclosures "$DISCLOSURES" '
        first(.in_flight[] | select(.id == $id)) as $row
        | [{
            id: $id,
            disclosure_only: true,
            projection: {
              schema: "fm-bearings.v1",
              view: "crew-lane",
              home: .home,
              generated: .generated,
              prs: .prs,
              in_flight: [$row],
              crew: {id: $id, kind: $row.kind, harness: "unknown", mode: "unknown"},
              status_events: [],
              omitted: (.omitted + $disclosures + [{
                surface: "crew lane for \($id) carries omission disclosure only",
                reveal: "inspect the projector diagnostics and re-run"
              }])
            }
          }]' \
      "$SPOOL") || {
      log "could not build the all-skipped omission disclosure"
      exit 1
    }
  fi
fi

printf '%s\n' "$LANES"
