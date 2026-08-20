#!/usr/bin/env bash
# Per-crew Buzz lane tests: label derivation, lane content, partition isolation,
# and the fire-and-forget contract of the refresh entry point.
#
# Hermetic: no live relay (the shared stub, or nothing listening at all), no
# network beyond loopback, no Docker. The fleet fixture is a real isolated home,
# so the lanes are projected by the real bin/fm-fleet-snapshot.sh rather than by a
# hand-written stand-in that could agree with a broken projector.
set -u

# shellcheck source=tests/fm-buzz-test-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-buzz-test-lib.sh"

REFRESH="$ROOT/bin/fm-buzz-refresh.sh"
LANES="$ROOT/bin/fm-buzz-crew-lanes.sh"

# The fleet channel's derived id, pinned as a literal. This is the whole
# backwards-compatibility claim: a captain who has been reading the fleet channel
# must not silently lose their history, so the derivation of the DEFAULT label
# shape - a resolved home path - may not move. A change here is a re-homing, not
# a refactor, and it has to be argued rather than absorbed.
PINNED_FLEET_LABEL=/fixture/firstmate-home
PINNED_FLEET_CHANNEL=1e2da966-a2fc-57b8-8fa6-123b49816c75

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/tmux"
fm_fake_exit0 "$FAKEBIN" no-mistakes

crew_channel_label() {  # <fleet label> <task id>
  # shellcheck disable=SC1091
  ( . "$ROOT/bin/fm-buzz-key-lib.sh"; fm_buzz_crew_channel_label "$ROOT/bin" "$1" "$2" )
}

crew_channel_id() {  # <home> <task id>
  channel_id_for_label "$(crew_channel_label "$(cd "$1" && pwd -P)" "$2")"
}

home_qualifier() {  # <home>
  local channel
  channel=$(default_channel_id "$1") || return 1
  printf '%s\n' "${channel%%-*}"
}

# A home with two live tasks whose status streams are distinguishable on sight,
# so a lane carrying the wrong crew's events cannot pass by accident.
TASK_A_EVENTS=(
  "working: task-a is setting up"
  "working: task-a is writing the fix"
  "done: task-a PR https://github.com/acme/repo/pull/3 checks green"
)
TASK_B_EVENTS=(
  "working: task-b is reading the code"
  "blocked: task-b needs a credential"
)

make_fleet_home() {  # <name>
  local home=$1 event
  home=$(make_home "$1")
  mkdir -p "$home/projects/wt" "$home/config"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] task-a - Ship the thing (repo: firstmate) (kind: ship) (since 2026-08-10)
- [ ] task-b - Investigate the thing (repo: firstmate) (kind: scout) (since 2026-08-10)

## Queued

## Done
EOF
  fm_write_meta "$home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "worktree=$home/projects/wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  : > "$home/state/task-a.status"
  for event in "${TASK_A_EVENTS[@]}"; do
    printf '%s\n' "$event" >> "$home/state/task-a.status"
  done
  fm_write_meta "$home/state/task-b.meta" \
    "window=firstmate:fm-task-b" \
    "worktree=$home/projects/wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  : > "$home/state/task-b.status"
  for event in "${TASK_B_EVENTS[@]}"; do
    printf '%s\n' "$event" >> "$home/state/task-b.status"
  done
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed for $home"
  printf '%s\n' "$home"
}

run_refresh() {  # <home> <relay> [args...]
  local home=$1 relay=$2
  shift 2
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_BUZZ_TIMEOUT_MS=8000 \
    "$REFRESH" --relay "$relay" "$@"
}

run_lanes() {  # <home> [args...]
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$LANES" "$@"
}

bearings_json() {  # <home>
  PATH="$FAKEBIN:$PATH" FM_HOME="$1" "$ROOT/bin/fm-bearings-snapshot.sh" --json
}

# The single cached event in one channel's partition, as its JSON content.
cached_content() {  # <home> <relay> <channel>
  local directory file
  directory=$(channel_cache_dir "$1" "$2" "$3") || return 1
  file=$(find "$directory" -type f -name '*.json' 2>/dev/null | head -1)
  [ -n "$file" ] || return 1
  jq -r '.[1].content' "$file"
}

cached_event_count() {  # <home> <relay> <channel>
  local directory
  directory=$(channel_cache_dir "$1" "$2" "$3") || return 1
  find "$directory" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

test_the_default_fleet_channel_id_is_unchanged() {
  local home derived
  derived=$(channel_id_for_label "$PINNED_FLEET_LABEL")
  [ "$derived" = "$PINNED_FLEET_CHANNEL" ] \
    || fail "the fleet channel derivation moved: $PINNED_FLEET_LABEL now derives $derived, not $PINNED_FLEET_CHANNEL"

  # And the refresh entry point addresses that same channel for a real home,
  # rather than a new one that merely happens to be derived the same way.
  home=$(make_fleet_home fleet-channel-pin)
  run_refresh "$home" "ws://127.0.0.1:1" >/dev/null 2>&1
  [ "$(cached_event_count "$home" "ws://127.0.0.1:1" "$(default_channel_id "$home")")" = "1" ] \
    || fail "the refresh did not publish the fleet projection into this home's existing channel"
  pass "the default fleet channel id is unchanged and still the refresh target"
}

test_two_task_ids_derive_two_well_formed_distinct_channels() {
  local home fleet_label channel_a channel_b fleet_channel uuid
  home=$(make_fleet_home distinct-lane-channels)
  fleet_label=$(cd "$home" && pwd -P)
  channel_a=$(crew_channel_id "$home" task-a)
  channel_b=$(crew_channel_id "$home" task-b)
  fleet_channel=$(channel_id_for_label "$fleet_label")

  uuid='^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  printf '%s' "$channel_a" | grep -Eq "$uuid" || fail "task-a derived a malformed channel: $channel_a"
  printf '%s' "$channel_b" | grep -Eq "$uuid" || fail "task-b derived a malformed channel: $channel_b"
  [ "$channel_a" != "$channel_b" ] || fail "two task ids derived one channel"
  [ "$channel_a" != "$fleet_channel" ] || fail "a lane collided with the fleet channel"
  [ "$channel_b" != "$fleet_channel" ] || fail "a lane collided with the fleet channel"

  # The label itself, not just the hash of it, so a change to the encoding is
  # visible rather than showing up only as a moved channel id.
  [ "$(crew_channel_label "$PINNED_FLEET_LABEL" task-a)" \
      = "firstmate-crew:$(printf '%s' "$PINNED_FLEET_LABEL" | shasum -a 256 | awk '{print $1}'):task-a" ] \
    || fail "the crew label encoding changed"

  # A task id outside the accepted set is refused rather than published somewhere.
  crew_channel_label "$PINNED_FLEET_LABEL" 'task/../fleet' >/dev/null 2>&1 \
    && fail "a task id containing a separator was accepted"
  crew_channel_label "$PINNED_FLEET_LABEL" '-task' >/dev/null 2>&1 \
    || fail "a canonical task id beginning with a hyphen was rejected"
  crew_channel_label "$PINNED_FLEET_LABEL" '_task' >/dev/null 2>&1 \
    || fail "a canonical task id beginning with an underscore was rejected"
  crew_channel_label "$PINNED_FLEET_LABEL" '.task' >/dev/null 2>&1 \
    && fail "a task id beginning with a dot was accepted"
  pass "two task ids derive two well-formed, distinct, non-colliding channels"
}

test_a_lane_carries_its_own_status_lines_and_identity() {
  local home lane content events
  home=$(make_fleet_home lane-content)
  lane=$(run_lanes "$home" --projection <(bearings_json "$home")) \
    || fail "the lane projection failed"

  content=$(printf '%s' "$lane" | jq -c 'map(select(.id == "task-a")) | .[0].projection')
  [ -n "$content" ] && [ "$content" != null ] || fail "no lane was projected for task-a"

  [ "$(printf '%s' "$content" | jq -r '.schema')" = "fm-bearings.v1" ] \
    || fail "a lane is not a valid fm-bearings.v1 projection"
  [ "$(printf '%s' "$content" | jq -r '.view')" = "crew-lane" ] \
    || fail "a lane does not mark itself as a crew lane"
  [ "$(printf '%s' "$content" | jq -r '.crew.id')" = "task-a" ] || fail "the lane lost its task id"
  [ "$(printf '%s' "$content" | jq -r '.crew.kind')" = "ship" ] || fail "the lane lost its kind"
  [ "$(printf '%s' "$content" | jq -r '.crew.harness')" = "claude" ] || fail "the lane lost its harness"
  [ "$(printf '%s' "$content" | jq -r '.crew.mode')" = "no-mistakes" ] \
    || fail "the lane lost its delivery mode"
  [ "$(printf '%s' "$content" | jq -c '[.in_flight[].id]')" = '["task-a"]' ] \
    || fail "the lane's in_flight is not narrowed to its own task"

  events=$(printf '%s' "$content" | jq -r '.status_events | join("\n")')
  [ "$events" = "$(printf '%s\n' "${TASK_A_EVENTS[@]}")" ] \
    || fail "the lane did not carry task-a's status lines verbatim: $events"

  # Deliberately dropped surfaces stay dropped: a lane is depth on an already
  # published surface, never a new one (the per-crew lane non-widening contract).
  printf '%s' "$content" | grep -q 'projects/wt' \
    && fail "the lane widened the projection with a worktree path"
  printf '%s' "$content" | jq -e 'has("paths") or has("actions") or has("endpoints") or has("bodies")' \
    >/dev/null 2>&1 && fail "the lane widened the projection with a dropped surface"
  pass "a lane carries its own status lines and identifying fields"
}

test_lane_events_never_land_in_another_lanes_partition() {
  local home relay channel_a channel_b fleet_channel content_a content_b
  home=$(make_fleet_home lane-partitions)
  relay=ws://127.0.0.1:1
  run_refresh "$home" "$relay" >/dev/null 2>&1
  channel_a=$(crew_channel_id "$home" task-a)
  channel_b=$(crew_channel_id "$home" task-b)
  fleet_channel=$(default_channel_id "$home")

  [ "$(replay_count "$home")" = "3" ] \
    || fail "expected one fleet event and two lane events in the replay cache"
  [ "$(cached_event_count "$home" "$relay" "$channel_a")" = "1" ] \
    || fail "task-a's partition does not hold exactly its own event"
  [ "$(cached_event_count "$home" "$relay" "$channel_b")" = "1" ] \
    || fail "task-b's partition does not hold exactly its own event"
  [ "$(cached_event_count "$home" "$relay" "$fleet_channel")" = "1" ] \
    || fail "the fleet partition does not hold exactly the fleet projection"

  content_a=$(cached_content "$home" "$relay" "$channel_a")
  content_b=$(cached_content "$home" "$relay" "$channel_b")
  printf '%s' "$content_a" | grep -q 'task-b is reading the code' \
    && fail "task-b's status events landed in task-a's partition"
  printf '%s' "$content_b" | grep -q 'task-a is writing the fix' \
    && fail "task-a's status events landed in task-b's partition"
  [ "$(printf '%s' "$content_a" | jq -r '.crew.id')" = "task-a" ] \
    || fail "task-a's partition holds another crew's lane"
  [ "$(printf '%s' "$content_b" | jq -r '.crew.id')" = "task-b" ] \
    || fail "task-b's partition holds another crew's lane"
  pass "each lane's events stay in that lane's own partition"
}

test_lanes_reach_the_relay_and_read_back_as_one_crews_stream() {
  local home relay output readback
  home=$(make_fleet_home lane-readback)
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  output=$(run_refresh "$home" "$relay" 2>&1)
  expect_code 0 "$?" "refresh with the relay up"
  assert_contains "$output" "handed the fleet channel and 2 crew lane(s) to the publisher" \
    "the refresh did not address both lanes"
  [ "$(replay_count "$home")" = "0" ] \
    || fail "the replay cache was not drained after delivery"

  readback=$(run_inspect "$home" "$relay" --crew task-a --full 2>&1) \
    || fail "reading task-a's lane back failed"
  assert_contains "$readback" "task-a is writing the fix" \
    "task-a's lane did not read back with its own status events"
  printf '%s' "$readback" | grep -q 'task-b needs a credential' \
    && fail "task-a's lane read back with another crew's status events"
  stop_stub "$STUB_PID"
  pass "each lane reaches the relay and reads back as one crew's stream"
}

test_each_lane_is_named_for_its_crew() {
  local home relay names qualifier
  home=$(make_fleet_home lane-naming)
  qualifier=$(home_qualifier "$home")
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  run_refresh "$home" "$relay" >/dev/null 2>&1
  expect_code 0 "$?" "refresh with the relay up"
  names=$(query_channel_names "$relay") || fail "the stub served no channel-creation events"
  stop_stub "$STUB_PID"

  # What a captain browsing a Buzz client actually reads. Addressing the lanes
  # correctly is not enough: three channels sharing one name are three identical
  # rows, which is the state this test exists to keep the adapter out of.
  [ "$names" = "$(printf 'crew-%s-task-a\ncrew-%s-task-b\nfirstmate-bearings' "$qualifier" "$qualifier")" ] \
    || fail "the published channel names were not one per crew plus the fleet: $names"
  pass "each lane is named for its crew and the fleet channel keeps its name"
}

test_two_homes_publish_distinguishable_lane_names() {
  local home_a home_b qualifier_a qualifier_b relay names expected
  home_a=$(make_fleet_home lane-home-a)
  home_b=$(make_fleet_home lane-home-b)
  qualifier_a=$(home_qualifier "$home_a")
  qualifier_b=$(home_qualifier "$home_b")
  [ "$qualifier_a" != "$qualifier_b" ] || fail "the two fixture homes share a display qualifier"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  run_refresh "$home_a" "$relay" >/dev/null 2>&1
  expect_code 0 "$?" "refresh from the first home"
  run_refresh "$home_b" "$relay" >/dev/null 2>&1
  expect_code 0 "$?" "refresh from the second home"
  names=$(query_channel_names "$relay") || fail "the stub served no channel-creation events"
  stop_stub "$STUB_PID"
  expected=$(printf 'crew-%s-task-a\ncrew-%s-task-b\ncrew-%s-task-a\ncrew-%s-task-b\nfirstmate-bearings\nfirstmate-bearings\n' \
    "$qualifier_a" "$qualifier_a" "$qualifier_b" "$qualifier_b" | sort)
  [ "$names" = "$expected" ] || fail "two homes produced ambiguous channel names: $names"
  pass "two homes sharing a relay publish distinguishable lane names"
}

test_completed_lane_replay_is_not_stranded() {
  local home relay relay_port readback names qualifier
  home=$(make_fleet_home completed-lane-replay)
  qualifier=$(home_qualifier "$home")
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  relay_port=${relay##*:}
  stop_stub "$STUB_PID"
  run_refresh "$home" "$relay" >/dev/null 2>&1
  [ "$(replay_count "$home")" = "3" ] || fail "the relay outage did not cache the fleet and lane events"
  grep -v 'task-a - Ship the thing' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  rm -f "$home/state/task-a.meta" "$home/state/task-a.status"

  read -r STUB_PID relay <<EOF
$(start_stub --port "$relay_port")
EOF
  run_refresh "$home" "$relay" >/dev/null 2>&1
  expect_code 0 "$?" "refresh after task-a completed"
  [ "$(replay_count "$home")" = "0" ] || fail "the completed task's replay partition stayed cached"
  readback=$(run_inspect "$home" "$relay" --crew task-a --full 2>&1) \
    || fail "the completed task's cached lane did not reach the relay"
  assert_contains "$readback" "task-a is writing the fix" \
    "the completed task's cached status stream was not replayed"
  names=$(query_channel_names "$relay") || fail "the replayed lane was not provisioned"
  stop_stub "$STUB_PID"
  assert_contains "$names" "crew-${qualifier}-task-a" \
    "the replayed lane lost its cached display name"
  pass "completed lane replay drains independently of current liveness"
}

test_the_fleet_omitted_disclosure_survives_untouched() {
  local home projection fleet_omitted lane_omitted
  home=$(make_fleet_home omitted-passthrough)
  projection=$(bearings_json "$home")
  fleet_omitted=$(printf '%s' "$projection" | jq -c '.omitted')
  [ "$(printf '%s' "$fleet_omitted" | jq 'length')" -gt 0 ] \
    || fail "the fixture projection disclosed nothing, so the passthrough is untested"

  lane_omitted=$(printf '%s' "$projection" \
    | run_lanes "$home" \
    | jq -c --argjson n "$(printf '%s' "$fleet_omitted" | jq 'length')" \
        'map(select(.id == "task-a")) | .[0].projection.omitted[:$n]')
  [ "$lane_omitted" = "$fleet_omitted" ] \
    || fail "the fleet omitted[] disclosure did not survive into the lane untouched"

  # And a lane's own bound discloses itself rather than silently truncating.
  lane_omitted=$(printf '%s' "$projection" \
    | FM_BUZZ_CREW_STATUS_LINES=1 run_lanes "$home" \
    | jq -r 'map(select(.id == "task-a")) | .[0].projection.omitted[] | .surface')
  assert_contains "$lane_omitted" "status events for task-a showing 1 of 3" \
    "a bounded lane did not disclose what it dropped"
  pass "the fleet omitted[] disclosure survives untouched and lane bounds disclose themselves"
}

test_an_unreachable_or_refusing_relay_is_a_non_event() {
  local home output code
  home=$(make_fleet_home relay-down)
  output=$(run_refresh "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 0 "$code" "refresh with nothing listening must still exit 0"
  assert_contains "$output" "Firstmate is unaffected" \
    "the refresh did not log the fire-and-forget outcome"
  [ "$(replay_count "$home")" = "3" ] \
    || fail "the fleet event and both lane events were not enqueued"

  home=$(make_fleet_home relay-refuses)
  local relay
  read -r STUB_PID relay <<EOF
$(start_stub --reject "blocked: not right now")
EOF
  output=$(run_refresh "$home" "$relay" 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 0 "$code" "refresh against a refusing relay must still exit 0"
  assert_contains "$output" "blocked: not right now" \
    "the relay's refusal was not surfaced to the operator"
  pass "an unreachable or refusing relay leaves the fleet unaffected and exits 0"
}

test_fire_and_forget_contract_is_intact() {
  grep -Eq '^[[:space:]]*set -e' "$REFRESH" \
    && fail "set -e crept back into the refresh entry point"
  grep -q 'FIRE-AND-FORGET' "$REFRESH" \
    || fail "the refresh entry point lost its fire-and-forget contract block"
  pass "the refresh entry point's fire-and-forget contract is intact"
}

test_lane_documents_stay_out_of_process_arguments() {
  local home guard_bin leak real_jq
  home=$(make_fleet_home lane-argv)
  printf '%s\n' "working: fm-buzz-argv-sentinel" "${TASK_A_EVENTS[@]}" \
    > "$home/state/task-a.status"
  guard_bin="$home/jq-guard"
  leak="$home/jq-argv-leak"
  real_jq=$(command -v jq)
  mkdir -p "$guard_bin"
  cat > "$guard_bin/jq" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  case $argument in
    *fm-buzz-argv-sentinel*) : > "$FM_BUZZ_ARGV_LEAK" ;;
  esac
done
exec "$FM_BUZZ_REAL_JQ" "$@"
SH
  chmod +x "$guard_bin/jq"

  (
    export FM_BUZZ_ARGV_LEAK="$leak" FM_BUZZ_REAL_JQ="$real_jq"
    PATH="$guard_bin:$PATH" run_lanes "$home" --projection <(bearings_json "$home") >/dev/null
  ) || fail "the guarded lane projection failed"
  [ ! -e "$leak" ] || fail "status content crossed a jq process argument"
  ! grep -Eq -- '--argjson[[:space:]]+task[[:space:]]' "$LANES" \
    || fail "a lane document is still passed through process arguments"
  pass "lane documents stay out of process arguments"
}

test_refresh_setup_failures_are_non_events() {
  local home broken_bin output code
  home=$(make_fleet_home refresh-setup-failures)
  broken_bin="$home/no-mktemp"
  mkdir -p "$broken_bin"
  cat > "$broken_bin/mktemp" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$broken_bin/mktemp"

  output=$(PATH="$broken_bin:$PATH" run_refresh "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 0 "$code" "refresh with an unavailable temporary spool"
  assert_contains "$output" "could not create a temporary file for the projection" \
    "the temporary-spool failure was not logged"

  output=$(FM_BEARINGS_IN_FLIGHT=0 run_refresh "$home" "ws://127.0.0.1:1" 2>&1)
  code=$?
  expect_code 0 "$code" "refresh with a failed bearings snapshot"
  assert_contains "$output" "bearings snapshot failed; skipping publish" \
    "the bearings-snapshot failure was not logged"
  pass "refresh setup failures are logged non-events"
}

test_status_read_failures_are_not_reported_as_present() {
  local home guard_bin real_tail lanes errors
  home=$(make_fleet_home status-read-race)
  guard_bin="$home/tail-guard"
  errors="$home/status-read-errors"
  real_tail=$(command -v tail)
  mkdir -p "$guard_bin"
  cat > "$guard_bin/tail" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then
  exit 1
fi
exec "$FM_BUZZ_REAL_TAIL" "$@"
SH
  chmod +x "$guard_bin/tail"
  lanes=$(PATH="$guard_bin:$PATH" FM_BUZZ_REAL_TAIL="$real_tail" \
    run_lanes "$home" --projection <(bearings_json "$home") 2>"$errors") \
    || fail "the lane projector failed after a raced status read"
  [ "$(printf '%s' "$lanes" | jq 'length')" = "0" ] \
    || fail "a failed status read still produced a present status stream"
  assert_contains "$(cat "$errors")" "could not read the status stream" \
    "the failed status read was not disclosed"
  pass "status read failures are not reported as present streams"
}

test_refresh_deadline_bounds_a_silent_relay() {
  local home relay output started elapsed
  home=$(make_fleet_home refresh-deadline)
  read -r STUB_PID relay <<EOF
$(start_stub --silent-ok)
EOF
  started=$(date +%s)
  output=$(FM_BUZZ_REFRESH_TIMEOUT_S=2 run_refresh "$home" "$relay" 2>&1)
  expect_code 0 "$?" "refresh against a silent relay"
  elapsed=$(($(date +%s) - started))
  stop_stub "$STUB_PID"
  [ "$elapsed" -le 5 ] || fail "the two-second refresh budget took ${elapsed}s"
  assert_contains "$output" "refresh deadline reached after the fleet channel" \
    "the refresh did not report which work its deadline skipped"
  [ "$(replay_count "$home")" = "1" ] \
    || fail "the refresh continued publishing crew lanes after its deadline"
  pass "one refresh-wide deadline bounds a silent relay"
}

test_channel_labels_preserve_embedded_newlines() {
  local home relay label channel
  home=$(make_fleet_home newline-channel-label)
  relay=ws://127.0.0.1:1
  label=$'fleet\nlabel'
  channel=$(channel_id_for_label "$label")

  run_refresh "$home" "$relay" --fleet-only --channel-label "$label" >/dev/null 2>&1
  expect_code 0 "$?" "refresh with a newline in the channel label"
  [ "$(cached_event_count "$home" "$relay" "$channel")" = "1" ] \
    || fail "the channel label was split while constructing publisher arguments"
  pass "channel labels preserve embedded newlines"
}

test_the_default_fleet_channel_id_is_unchanged
test_two_task_ids_derive_two_well_formed_distinct_channels
test_a_lane_carries_its_own_status_lines_and_identity
test_lane_events_never_land_in_another_lanes_partition
test_lanes_reach_the_relay_and_read_back_as_one_crews_stream
test_each_lane_is_named_for_its_crew
test_two_homes_publish_distinguishable_lane_names
test_completed_lane_replay_is_not_stranded
test_the_fleet_omitted_disclosure_survives_untouched
test_an_unreachable_or_refusing_relay_is_a_non_event
test_fire_and_forget_contract_is_intact
test_lane_documents_stay_out_of_process_arguments
test_refresh_setup_failures_are_non_events
test_status_read_failures_are_not_reported_as_present
test_refresh_deadline_bounds_a_silent_relay
test_channel_labels_preserve_embedded_newlines
