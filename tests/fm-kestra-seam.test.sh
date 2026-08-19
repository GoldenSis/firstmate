#!/usr/bin/env bash
# Contract tests for firstmate's Kestra execution seam (M1).
#
# WHAT THESE TESTS ARE, AND WHAT THEY ARE NOT.
#
# The default suite is hermetic: no network, no Java, no Kestra server. The Kestra
# HTTP surface is replaced by a fakebin `curl` that serves recorded response shapes
# and logs every request, exactly like tests/fm-x-mode.test.sh stubs the X relay.
# That makes one boundary explicit and worth stating rather than glossing:
#
#   These tests assert what the SEAM does. They cannot assert what Kestra's engine
#   does. Nothing here proves Kestra retries a failing task three times.
#
# The retry obligation is therefore split into two claims that CAN be checked
# honestly without a server, plus one that cannot:
#   1. the reviewed flow CONFIGURES three attempts  - asserted statically against
#      the tracked YAML;
#   2. the status adapter REPORTS the attempts, the FAILED -> RETRYING -> RUNNING
#      transitions, the per-attempt error logs, and the suppressed following task
#      without losing or inventing any of them - asserted against a recorded
#      execution shape;
#   3. Kestra's engine actually performing three attempts - NOT asserted here. The
#      prototype observed it empirically against Kestra OSS 1.3.34, and the opt-in
#      live section at the end of this file re-checks it against a real server when
#      FM_KESTRA_LIVE=1 is set. It is skipped by default.
# Every test name below says which of those it is, so no assertion reads as
# stronger than it is.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The adapters use the real jq; make it resolvable wherever it is installed. The
# fakebin is prepended after this so the fake curl still wins.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
command -v jq >/dev/null 2>&1 || fail "jq is required for the Kestra seam tests"

TMP_ROOT=$(fm_test_tmproot fm-kestra-seam)
FLOWS="$ROOT/kestra/flows"

DEPLOY="$ROOT/bin/fm-kestra-deploy.sh"
RUN="$ROOT/bin/fm-kestra-run.sh"
STATUS="$ROOT/bin/fm-kestra-status.sh"

NS=firstmate.m1

# --- recorded response shapes ----------------------------------------------
#
# These mirror the execution JSON Kestra OSS 1.3.34 returned during the prototype:
# a state history, a taskRunList with per-task attempt arrays, declared outputs.
# The failure shape is the one that matters most - three attempts, the retry
# transitions, and NO taskRun for the task after the failure.

EXEC_SUCCESS_JSON='{
  "id": "EXECSUCCESS1",
  "namespace": "firstmate.m1",
  "flowId": "m1_shape",
  "state": {"current": "SUCCESS", "histories": [
    {"state": "CREATED"}, {"state": "RUNNING"}, {"state": "SUCCESS"}]},
  "taskRunList": [
    {"taskId": "begin", "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]}, "attempts": [{"state": {"current": "SUCCESS"}}]},
    {"taskId": "finish", "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]}, "attempts": [{"state": {"current": "SUCCESS"}}]}
  ],
  "outputs": {
    "summary": "finished synthetic-alpha via safe",
    "artifact": "kestra:///firstmate/m1/m1-shape/executions/EXECSUCCESS1/tasks/artifact/AAA/1.txt"
  }
}'

EXEC_FAILURE_JSON='{
  "id": "EXECFAILURE1",
  "namespace": "firstmate.m1",
  "flowId": "m1_controlled_failure",
  "state": {"current": "FAILED", "histories": [
    {"state": "CREATED"}, {"state": "RUNNING"}, {"state": "FAILED"},
    {"state": "RETRYING"}, {"state": "RUNNING"}, {"state": "FAILED"},
    {"state": "RETRYING"}, {"state": "RUNNING"}, {"state": "FAILED"}]},
  "taskRunList": [
    {"taskId": "before_failure", "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]}, "attempts": [{"state": {"current": "SUCCESS"}}]},
    {"taskId": "always_fails", "state": {"current": "FAILED", "histories": [
      {"state": "CREATED"}, {"state": "RUNNING"}, {"state": "FAILED"},
      {"state": "RETRYING"}, {"state": "RUNNING"}, {"state": "FAILED"},
      {"state": "RETRYING"}, {"state": "RUNNING"}, {"state": "FAILED"}]},
      "attempts": [
        {"state": {"current": "FAILED"}},
        {"state": {"current": "FAILED"}},
        {"state": {"current": "FAILED"}}]}
  ],
  "outputs": {}
}'

EXEC_REPLAY_JSON='{
  "id": "EXECREPLAY1",
  "namespace": "firstmate.m1",
  "flowId": "m1_shape",
  "originalId": "EXECSUCCESS1",
  "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]},
  "taskRunList": [],
  "outputs": {}
}'

LOGS_FAILURE_JSON='[
  {"taskId": "before_failure", "attemptNumber": 0, "level": "INFO", "message": "controlled failure begins"},
  {"taskId": "always_fails", "attemptNumber": 0, "level": "ERROR", "message": "synthetic controlled failure, attempt=0"},
  {"taskId": "always_fails", "attemptNumber": 1, "level": "ERROR", "message": "synthetic controlled failure, attempt=1"},
  {"taskId": "always_fails", "attemptNumber": 2, "level": "ERROR", "message": "synthetic controlled failure, attempt=2"}
]'

# --- the fake Kestra HTTP surface -------------------------------------------
#
# One fakebin curl. It appends `<METHOD> <URL>` to FAKE_CURL_LOG, records how the
# credential reached it, and answers from the recorded shapes above. Any request
# the seam is not supposed to make still gets LOGGED, so a test can prove the seam
# never attempted it.

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
method=GET url="" cfg="" formstrings=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    --config) cfg=$2; shift 2 ;;
    --form-string) formstrings="$formstrings $2"; shift 2 ;;
    --max-time|-H|--data-binary|-F|-o|-w|-m) shift 2 ;;
    -sS|-s|-S) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
{
  printf '%s %s\n' "$method" "$url"
  printf 'ARGV %s\n' "$argv"
  printf 'FORM%s\n' "$formstrings"
  if [ -n "$cfg" ]; then
    printf 'AUTHFILE mode=%s\n' "$(ls -l "$cfg" | cut -c1-10)"
  else
    printf 'AUTHFILE none\n'
  fi
} >> "$FAKE_CURL_LOG"

path=${url#*/api/v1/main}
case "$method $path" in
  'POST /flows/validate') printf '[]' ;;
  'POST /flows/bulk'*) printf '[]' ;;
  'POST /executions/firstmate.m1/m1_shape'*) printf '{"id":"EXECSUCCESS1"}' ;;
  'POST /executions/firstmate.m1/m1_controlled_failure'*) printf '{"id":"EXECFAILURE1"}' ;;
  'GET /executions/EXECSUCCESS1/file'*) printf 'label=synthetic-alpha\nunits=3\nroute=safe\n' ;;
  'GET /executions/EXECSUCCESS1') printf '%s' "$FAKE_EXEC_SUCCESS" ;;
  'GET /executions/EXECFAILURE1') printf '%s' "$FAKE_EXEC_FAILURE" ;;
  'GET /executions/EXECREPLAY1') printf '%s' "$FAKE_EXEC_REPLAY" ;;
  'GET /logs/EXECFAILURE1') printf '%s' "$FAKE_LOGS_FAILURE" ;;
  *) printf '{}' ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# seam_env <workdir>: run a seam script with the fake HTTP surface and a loopback
# endpoint. FM_KESTRA_CONFIG points at a path that does not exist, so these runs
# exercise the environment path and never depend on an operator's local config.
seam() {
  local workdir=$1 fakebin
  shift
  fakebin=$(make_fake_curl "$workdir")
  env -i \
    PATH="$fakebin:$BASE_PATH" \
    HOME="$workdir" \
    TMPDIR="$workdir" \
    FAKE_CURL_LOG="$workdir/curl.log" \
    FAKE_EXEC_SUCCESS="$EXEC_SUCCESS_JSON" \
    FAKE_EXEC_FAILURE="$EXEC_FAILURE_JSON" \
    FAKE_EXEC_REPLAY="$EXEC_REPLAY_JSON" \
    FAKE_LOGS_FAILURE="$LOGS_FAILURE_JSON" \
    FM_KESTRA_CONFIG="$workdir/absent-kestra.env" \
    FM_KESTRA_BASE_URL="${SEAM_BASE_URL:-http://127.0.0.1:18080}" \
    FM_KESTRA_TENANT=main \
    FM_KESTRA_NAMESPACE="$NS" \
    FM_KESTRA_USER=synthetic-operator \
    FM_KESTRA_PASSWORD="$SEAM_PASSWORD" \
    ${SEAM_FLOWS_DIR:+FM_KESTRA_FLOWS_DIR="$SEAM_FLOWS_DIR"} \
    "$@"
}

SEAM_PASSWORD='Synthetic-M1-Only'
SEAM_FLOWS_DIR=""
SEAM_BASE_URL=""

workdir() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  : > "$d/curl.log"
  printf '%s\n' "$d"
}

# ===========================================================================
# 1. Typed input rejection, before any execution is created
# ===========================================================================

test_typed_input_rejection_happens_before_any_request() {
  local d out rc
  for case_name in \
    'units=9:units must be <= 5' \
    'route=unsafe:route must be one of' \
    'label=real-data:label must match'
  do
    local bad=${case_name%%:*} expect=${case_name#*:}
    d=$(workdir "reject-${bad%%=*}")
    rc=0
    out=$(seam "$d" "$RUN" --flow m1_shape \
      --input units=3 --input route=safe --input label=synthetic-alpha \
      --input "$bad" 2>&1) || rc=$?
    expect_code 2 "$rc" "invalid input $bad must be refused"
    assert_contains "$out" "input ${expect#input }" "refusal must name the offending input ($bad)"
    # The whole point: nothing was launched.
    [ ! -s "$d/curl.log" ] || fail "invalid input $bad must be refused before any request is made"
  done
  pass "typed input rejection refuses out-of-range, off-enum, and regex-violating values before any request"
}

test_undeclared_input_is_refused() {
  local d out rc
  d=$(workdir reject-undeclared)
  rc=0
  out=$(seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input label=synthetic-alpha \
    --input surprise=1 2>&1) || rc=$?
  expect_code 2 "$rc" "an input the flow never declared must be refused"
  assert_contains "$out" "not declared by this flow" "refusal must say the input is undeclared"
  [ ! -s "$d/curl.log" ] || fail "an undeclared input must be refused before any request"
  pass "an input the reviewed flow does not declare is refused rather than forwarded"
}

test_missing_required_input_is_refused() {
  local d out rc
  d=$(workdir reject-missing)
  rc=0
  out=$(seam "$d" "$RUN" --flow m1_shape --input units=3 2>&1) || rc=$?
  expect_code 2 "$rc" "a missing required input must be refused"
  assert_contains "$out" "missing required input" "refusal must name the missing requirement"
  [ ! -s "$d/curl.log" ] || fail "a missing required input must be refused before any request"
  pass "a missing required input is refused before any request"
}

# ===========================================================================
# 2. An allowed execution returns an opaque execution ID
# ===========================================================================

test_allowed_execution_returns_one_opaque_id() {
  local d out rc posts
  d=$(workdir allow-run)
  rc=0
  out=$(seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input label=synthetic-alpha 2>&1) || rc=$?
  expect_code 0 "$rc" "an allow-listed flow with valid inputs must run"
  [ "$out" = "EXECSUCCESS1" ] || fail "the run adapter must print only the execution id, got: $out"

  posts=$(grep -c "^POST " "$d/curl.log" || true)
  [ "$posts" -eq 1 ] || fail "exactly one execution must be created, saw $posts POSTs"
  assert_grep "POST http://127.0.0.1:18080/api/v1/main/executions/firstmate.m1/m1_shape" \
    "$d/curl.log" "the execution must be created in the allow-listed namespace"
  assert_grep "FORM units=3 route=safe label=synthetic-alpha" "$d/curl.log" \
    "validated inputs must be sent as literal form strings"
  pass "an allowed flow with valid inputs creates exactly one execution and returns its opaque id"
}

test_credential_never_reaches_argv_and_the_auth_file_is_private() {
  local d
  d=$(workdir credential)
  seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input label=synthetic-alpha >/dev/null 2>&1 \
    || fail "run must succeed for the credential check"
  assert_no_grep "$SEAM_PASSWORD" "$d/curl.log" "the credential must never appear in curl argv"
  assert_no_grep "synthetic-operator" "$d/curl.log" "the account name must never appear in curl argv"
  assert_grep "AUTHFILE mode=-rw-------" "$d/curl.log" \
    "the credential must be handed over through a mode-0600 file"
  pass "the Basic Auth credential never enters argv and its transient file is mode 0600"
}

# ===========================================================================
# 3. Terminal failure after the configured three attempts
# ===========================================================================

test_tracked_flow_configures_exactly_three_attempts() {
  # Claim 1: the REVIEWED SOURCE configures three total attempts. This is a static
  # assertion about Git-reviewed material, independent of any server.
  local file="$FLOWS/m1_controlled_failure.yaml"
  assert_present "$file" "the controlled-failure flow must be tracked"
  assert_grep "maxAttempts: 3" "$file" "the controlled-failure flow must configure three attempts"
  assert_grep "type: io.kestra.plugin.core.execution.Fail" "$file" \
    "the controlled-failure flow must fail deliberately, not by accident"
  pass "the reviewed controlled-failure flow configures exactly three attempts (static, no server)"
}

test_status_adapter_reports_three_attempts_and_the_retry_transitions() {
  # Claim 2: given an execution that failed after three attempts, the adapter
  # surfaces the attempt count and every retry transition. This asserts the
  # ADAPTER's reporting, not Kestra's engine.
  local d out rc
  d=$(workdir failure-state)
  rc=0
  out=$(seam "$d" "$STATUS" state EXECFAILURE1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading a failed execution must succeed"
  assert_contains "$out" "state: FAILED" "the terminal state must be reported"
  assert_contains "$out" "task: always_fails state=FAILED attempts=3" \
    "the adapter must report exactly three attempts for the failing task"
  assert_contains "$out" \
    "history: CREATED -> RUNNING -> FAILED -> RETRYING -> RUNNING -> FAILED -> RETRYING -> RUNNING -> FAILED" \
    "the adapter must report the retry transitions in order, not just the terminal state"
  assert_contains "$out" \
    "history=CREATED,RUNNING,FAILED,RETRYING,RUNNING,FAILED,RETRYING,RUNNING,FAILED" \
    "the failing task's own transition history must survive to the report"
  pass "the status adapter reports three attempts and every retry transition (adapter reporting, not engine behaviour)"
}

test_status_adapter_reports_every_attempt_log_line() {
  local d out rc
  d=$(workdir failure-logs)
  rc=0
  out=$(seam "$d" "$STATUS" logs EXECFAILURE1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading task logs must succeed"
  local n
  for n in 0 1 2; do
    assert_contains "$out" "task=always_fails attempt=$n" \
      "the log for attempt $n must reach the report"
    assert_contains "$out" "synthetic controlled failure, attempt=$n" \
      "the error message for attempt $n must reach the report"
  done
  pass "the status adapter surfaces the per-attempt retry logs without collapsing them"
}

# ===========================================================================
# 4. Suppression of the task following a terminal failure
# ===========================================================================

test_task_after_a_terminal_failure_is_reported_as_not_run() {
  local d out rc
  d=$(workdir suppression)
  rc=0
  out=$(seam "$d" "$STATUS" state EXECFAILURE1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading a failed execution must succeed"
  assert_contains "$out" "not-run: after_failure" \
    "the task following the terminal failure must be reported as never run"
  assert_not_contains "$out" "task: after_failure" \
    "the suppressed task must not be reported as having run"
  # Suppression is only meaningful if the tasks that DID run are still reported.
  assert_contains "$out" "task: before_failure state=SUCCESS" \
    "tasks that ran before the failure must still be reported"
  pass "the task after a terminal failure is reported as not-run, by comparing the reviewed flow to the execution"
}

# ===========================================================================
# 5. Replay lineage is readable; replay itself is denied
# ===========================================================================

test_replay_lineage_is_readable() {
  local d out rc
  d=$(workdir lineage)
  rc=0
  out=$(seam "$d" "$STATUS" lineage EXECREPLAY1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading replay lineage must succeed"
  assert_contains "$out" "execution: EXECREPLAY1" "lineage must name the execution"
  assert_contains "$out" "original: EXECSUCCESS1" "lineage must name the execution it was derived from"
  pass "replay lineage is readable through the read-only adapter"
}

test_replay_is_denied_through_every_entrypoint() {
  local d out rc
  d=$(workdir deny-replay)

  rc=0
  out=$(seam "$d" "$RUN" --flow m1_shape --replay EXECSUCCESS1 2>&1) || rc=$?
  expect_code 2 "$rc" "the run adapter must refuse --replay"
  assert_contains "$out" "refused" "the run adapter's replay refusal must say so"

  rc=0
  out=$(seam "$d" "$STATUS" replay EXECSUCCESS1 2>&1) || rc=$?
  expect_code 2 "$rc" "the status adapter must refuse a replay subcommand"
  assert_contains "$out" "read-only" "the status adapter must state that it is read-only"

  assert_no_grep "replay" "$d/curl.log" "no replay request may ever reach the server"
  pass "replay is refused by both entrypoints and no replay request is ever attempted"
}

# ===========================================================================
# 6. Authority denial
# ===========================================================================

test_a_flow_with_no_reviewed_source_is_not_addressable() {
  local d out rc
  d=$(workdir deny-flow)
  rc=0
  out=$(seam "$d" "$RUN" --flow arbitrary_flow 2>&1) || rc=$?
  expect_code 2 "$rc" "a flow with no tracked source must be refused"
  assert_contains "$out" "not allow-listed" "the refusal must say the identity is not allow-listed"
  [ ! -s "$d/curl.log" ] || fail "a non-allow-listed flow must be refused before any request"

  # Path traversal and namespace escape are the same refusal, not a special case.
  local bad
  for bad in '../../etc/passwd' 'other.namespace/m1_shape' 'm1_shape;rm'; do
    rc=0
    out=$(seam "$d" "$RUN" --flow "$bad" 2>&1) || rc=$?
    expect_code 2 "$rc" "flow identity '$bad' must be refused"
  done
  [ ! -s "$d/curl.log" ] || fail "no malformed flow identity may reach the server"
  pass "a flow identity with no reviewed Git source is not addressable, and neither is a malformed one"
}

test_every_mutating_verb_is_refused_by_the_run_adapter() {
  local d out rc verb
  d=$(workdir deny-verbs)
  for verb in --restart --resume --kill --replay --delete --update --task --taskrun-id \
    --state --set-state --secret --namespace --force
  do
    rc=0
    out=$(seam "$d" "$RUN" --flow m1_shape "$verb" x 2>&1) || rc=$?
    expect_code 2 "$rc" "the run adapter must refuse $verb"
    assert_contains "$out" "refused" "the refusal of $verb must say so"
  done
  [ ! -s "$d/curl.log" ] || fail "no refused verb may reach the server"
  pass "the run adapter refuses every mutating verb by name and reaches the server for none of them"
}

test_every_mutating_operation_is_refused_by_the_status_adapter() {
  local d out rc op
  d=$(workdir deny-status)
  for op in replay restart resume kill delete update execute deploy set-state secrets; do
    rc=0
    out=$(seam "$d" "$STATUS" "$op" EXECSUCCESS1 2>&1) || rc=$?
    expect_code 2 "$rc" "the status adapter must refuse '$op'"
    assert_contains "$out" "read-only" "the refusal of '$op' must state read-only"
  done
  [ ! -s "$d/curl.log" ] || fail "no refused status operation may reach the server"
  pass "the status adapter refuses every state-changing operation and reaches the server for none of them"
}

test_the_http_gate_refuses_mutating_paths_for_every_role() {
  # Defence in depth: even a caller that built a mutating path by hand is refused
  # by the gate, so the denial does not depend on argument parsing alone.
  local out rc
  out=$(FM_KESTRA_NAMESPACE="$NS" bash -c '
    . "$1/bin/fm-kestra-lib.sh"
    for role in deploy run read; do
      for probe in \
        "POST /executions/firstmate.m1/m1_shape/replay" \
        "POST /executions/EXECSUCCESS1/restart" \
        "POST /executions/EXECSUCCESS1/resume" \
        "DELETE /flows/firstmate.m1/m1_shape" \
        "PUT /flows/firstmate.m1/m1_shape" \
        "GET /namespaces/firstmate.m1/secrets" \
        "POST /executions/EXECSUCCESS1/state" \
        "POST /apitokens" \
        "POST /flows/bulk?delete=true&namespace=firstmate.m1" \
        "POST /flows/bulk?delete=false&namespace=firstmate.m1&extra=1" \
        "POST /flows/bulk?delete=false&namespace=someone.else" \
        "POST /executions/firstmate.m1/m1_shape/eval"
      do
        method=${probe%% *}
        path=${probe#* }
        if fm_kestra_path_allowed "$role" "$method" "$path"; then
          printf "ALLOWED %s %s %s\n" "$role" "$method" "$path"
        fi
      done
    done
    # The legitimate shapes must still pass, or the gate is merely broken.
    fm_kestra_path_allowed deploy POST "/flows/validate" || printf "DENIED deploy validate\n"
    fm_kestra_path_allowed deploy POST "/flows/bulk?delete=false&namespace=firstmate.m1" \
      || printf "DENIED deploy bulk\n"
    fm_kestra_path_allowed run POST "/executions/firstmate.m1/m1_shape" || printf "DENIED run execute\n"
    fm_kestra_path_allowed read GET "/executions/EXECSUCCESS1" || printf "DENIED read execution\n"
    fm_kestra_path_allowed read GET "/logs/EXECFAILURE1" || printf "DENIED read logs\n"
  ' _ "$ROOT" 2>&1) || rc=$?
  [ -z "$out" ] || fail "HTTP gate role matrix is wrong:"$'\n'"$out"
  pass "the HTTP gate denies replay, restart, resume, deletion, state override, secrets, tokens, deletion-enabled updates, and execution sub-resources for every role"
}

test_a_run_may_not_target_another_namespace() {
  local out
  out=$(FM_KESTRA_NAMESPACE=firstmate.m1 bash -c '
    . "$1/bin/fm-kestra-lib.sh"
    fm_kestra_path_allowed run POST "/executions/other.namespace/m1_shape" \
      && printf "ALLOWED other namespace\n"
    exit 0
  ' _ "$ROOT" 2>&1)
  [ -z "$out" ] || fail "the run role must not reach a namespace outside the allow-list"
  pass "the run role can only launch executions inside the one allow-listed namespace"
}

# ===========================================================================
# 7. Deployment authority
# ===========================================================================

test_check_mode_accepts_the_tracked_flows_without_config_or_network() {
  local d out rc
  d=$(workdir deploy-check)
  rc=0
  out=$(env -i PATH="$BASE_PATH" HOME="$d" "$DEPLOY" --check 2>&1) || rc=$?
  expect_code 0 "$rc" "the tracked flows must pass static validation"
  assert_contains "$out" "$NS/m1_shape" "the shape flow must validate"
  assert_contains "$out" "$NS/m1_controlled_failure" "the controlled-failure flow must validate"
  pass "deploy --check validates the tracked flows with no config, no credential, and no network"
}

# fixture_flow <dir> <name> <body>: write a throwaway flow source.
fixture_flow() {
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/$2.yaml"
}

check_fixture() {
  local dir=$1 rc=0 out
  out=$(env -i PATH="$BASE_PATH" HOME="$dir" FM_KESTRA_FLOWS_DIR="$dir" "$DEPLOY" --check 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

test_deploy_refuses_a_flow_without_the_read_only_label() {
  local d out rc
  d="$TMP_ROOT/no-readonly"
  fixture_flow "$d" mutable 'id: mutable
namespace: firstmate.m1

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "hello"'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a flow without system.readOnly must be refused"
  assert_contains "$out" 'missing label system.readOnly' "the refusal must name the missing label"
  pass "the deployer refuses a flow that the Kestra UI editor could still change"
}

test_deploy_refuses_a_task_type_outside_the_core_plugin_allow_list() {
  local d out rc
  d="$TMP_ROOT/plugin-type"
  fixture_flow "$d" plugged 'id: plugged
namespace: firstmate.m1

labels:
  system.readOnly: "true"

tasks:
  - id: shell
    type: io.kestra.plugin.scripts.shell.Commands
    commands:
      - echo hi'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a non-core task type must be refused"
  assert_contains "$out" "outside the core-plugin allow-list" "the refusal must name the plugin boundary"
  pass "the deployer refuses a task type that would require installing a plugin"
}

test_deploy_refuses_an_input_it_cannot_pre_check() {
  local d out rc
  d="$TMP_ROOT/unknown-input"
  fixture_flow "$d" exotic 'id: exotic
namespace: firstmate.m1

labels:
  system.readOnly: "true"

inputs:
  - id: payload
    type: JSON
    required: true

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "hello"'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "an input type the adapter cannot pre-check must be refused"
  assert_contains "$out" "cannot pre-check" "the refusal must say the adapter cannot pre-check the input"
  pass "the deployer refuses an input schema the run adapter could not fully validate"
}

test_deploy_refuses_a_validator_the_adapter_cannot_faithfully_pre_check() {
  local d out rc
  d="$TMP_ROOT/java-regex"
  fixture_flow "$d" javare 'id: javare
namespace: firstmate.m1

labels:
  system.readOnly: "true"

inputs:
  - id: code
    type: STRING
    required: true
    validator: ^\d+$

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "hello"'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a Java-only regex construct must be refused"
  assert_contains "$out" "POSIX ERE" "the refusal must explain the regex-engine mismatch"
  pass "the deployer refuses a validator the local pre-check would evaluate differently from Kestra"
}

test_deploy_refuses_a_namespace_outside_the_allow_list() {
  local d out rc
  d=$(workdir deploy-ns)
  local flows="$TMP_ROOT/other-ns"
  fixture_flow "$flows" elsewhere 'id: elsewhere
namespace: someone.else

labels:
  system.readOnly: "true"

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "hello"'
  rc=0
  # The prefix stays INSIDE the command substitution: an assignment prefix on an
  # assignment would leak into the rest of the suite.
  out=$(SEAM_FLOWS_DIR="$flows" seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 2 "$rc" "a flow outside the allow-listed namespace must be refused"
  assert_contains "$out" "only $NS is allow-listed" "the refusal must name the allow-listed namespace"
  [ ! -s "$d/curl.log" ] || fail "a namespace refusal must happen before any request"
  pass "the deployer refuses to update any namespace but the one allow-listed in local config"
}

test_deploy_never_enables_deletion() {
  local d rc
  d=$(workdir deploy-run)
  rc=0
  seam "$d" "$DEPLOY" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "deploying the tracked flows must succeed against the fake server"
  assert_grep "flows/bulk?delete=false&namespace=$NS" "$d/curl.log" \
    "the namespace update must disable deletion"
  assert_grep "POST http://127.0.0.1:18080/api/v1/main/flows/validate" "$d/curl.log" \
    "flows must be validated server-side before the update"
  assert_no_grep "delete=true" "$d/curl.log" "deletion must never be enabled"
  # Kestra must never be handed Git reconciliation; the seam pushes instead.
  assert_no_grep "/git" "$d/curl.log" "the deployer must never ask Kestra to reconcile Git"
  pass "the deployer validates first, then updates the allow-listed namespace with deletion disabled"
}

# ===========================================================================
# 8. Endpoint, artifact, and data-boundary rules
# ===========================================================================

test_a_non_loopback_endpoint_is_refused() {
  local d out rc
  d=$(workdir loopback)
  rc=0
  out=$(SEAM_BASE_URL=https://kestra.example.com seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input label=synthetic-alpha 2>&1) || rc=$?
  expect_code 2 "$rc" "a non-loopback endpoint must be refused"
  assert_contains "$out" "must be loopback" "the refusal must name the loopback rule"
  [ ! -s "$d/curl.log" ] || fail "a non-loopback endpoint must be refused before any request"

  rc=0
  out=$(SEAM_BASE_URL='http://user:pass@127.0.0.1:18080' seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input label=synthetic-alpha 2>&1) || rc=$?
  expect_code 2 "$rc" "an endpoint embedding credentials must be refused"
  assert_contains "$out" "must not embed credentials" "the refusal must name the credential rule"
  pass "the seam refuses any endpoint that is not credential-free loopback"
}

test_only_a_declared_artifact_can_be_read() {
  local d out rc uri
  d=$(workdir artifact)
  uri='kestra:///firstmate/m1/m1-shape/executions/EXECSUCCESS1/tasks/artifact/AAA/1.txt'
  rc=0
  out=$(seam "$d" "$STATUS" artifact EXECSUCCESS1 "$uri" 2>&1) || rc=$?
  expect_code 0 "$rc" "an artifact the execution declared must be readable"
  assert_contains "$out" "label=synthetic-alpha" "the declared artifact's bytes must be returned"

  rc=0
  out=$(seam "$d" "$STATUS" artifact EXECSUCCESS1 'kestra:///somewhere/else/secret.txt' 2>&1) || rc=$?
  expect_code 2 "$rc" "an undeclared artifact URI must be refused"
  assert_contains "$out" "not declared as an output" "the refusal must say the URI was never declared"
  assert_no_grep "somewhere/else" "$d/curl.log" "an undeclared artifact must never be fetched"
  pass "only artifacts the execution declared as outputs are readable; anything else is refused"
}

test_declared_outputs_are_reported() {
  local d out rc
  d=$(workdir outputs)
  rc=0
  out=$(seam "$d" "$STATUS" outputs EXECSUCCESS1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading declared outputs must succeed"
  assert_contains "$out" "output: summary=finished synthetic-alpha via safe" \
    "declared flow outputs must be reported"
  pass "the status adapter reports the flow's declared outputs"
}

# ===========================================================================
# 9. Tracked material invariants
# ===========================================================================

test_every_tracked_flow_is_read_only_and_core_only() {
  local file stray
  for file in "$FLOWS"/*.yaml; do
    assert_grep 'system.readOnly: "true"' "$file" "$file must carry the read-only label"
    assert_grep "namespace: $NS" "$file" "$file must declare the allow-listed namespace"
    # Ask the library's own parser rather than re-rolling a weaker grep here: a
    # task's retry block has its own `type:` and a naive grep would flag it.
    stray=$(bash -c '. "$1/bin/fm-kestra-lib.sh"; fm_kestra_task_types "$2"' _ "$ROOT" "$file" \
      | grep -v '^io\.kestra\.plugin\.core\.' || true)
    [ -z "$stray" ] || fail "$file uses task types outside the core plugins: $stray"
  done
  pass "every tracked flow is read-only-labelled, core-plugin-only, and in the allow-listed namespace"
}

test_no_credential_or_endpoint_value_is_committed() {
  # kestra/ and bin/ describe the config's SHAPE; they never carry a value.
  local hits
  hits=$(grep -rIn -E '(FM_KESTRA_PASSWORD|FM_KESTRA_USER)=[^ "'"'"']' \
    "$ROOT/kestra" "$ROOT/bin" "$ROOT/docs" 2>/dev/null || true)
  [ -z "$hits" ] || fail "a credential value is present in tracked seam material:"$'\n'"$hits"
  assert_grep "config/kestra.env" "$ROOT/.gitignore" "local Kestra config must be gitignored"
  assert_present "$ROOT/docs/examples/kestra-env" "the config shape must be documented as a copyable example"
  pass "no credential or endpoint value is committed, and local Kestra config is gitignored"
}

test_the_pinned_version_and_checksum_are_stated_once() {
  local out
  out=$(bash -c '. "$1/bin/fm-kestra-lib.sh"; fm_kestra_pinned_version; fm_kestra_pinned_sha256' \
    _ "$ROOT")
  assert_contains "$out" "1.3.34" "the pinned Kestra version must be stated in code"
  assert_contains "$out" "de846ac42e2b35a2e55301d01335de6ea30eab77fd69570f238e06ea28149a4b" \
    "the pinned asset checksum must be stated in code"
  assert_no_grep "latest" "$ROOT/bin/fm-kestra-deploy.sh" "no floating version tag may appear"
  pass "the Kestra version and asset checksum are pinned in code, with no floating tag"
}

test_no_prototype_artifact_is_present() {
  # The prototype's local admin credential, H2 database, downloaded runtime, and
  # throwaway driver are forbidden inputs; assert none of them followed us here.
  # The needles are assembled at runtime so this file does not contain them
  # literally; that keeps the scan honest about its own directory instead of
  # excluding itself from the check.
  local hits proto_dir proto_ns proto_pass
  proto_dir='kestra-prototype''-r1'
  proto_ns='prototype''.firstmate'
  proto_pass='Synthetic''1!'
  hits=$(grep -rIln -e "$proto_dir" -e "$proto_ns" -e "$proto_pass" \
    "$ROOT/bin" "$ROOT/kestra" "$ROOT/tests" "$ROOT/docs" 2>/dev/null || true)
  [ -z "$hits" ] || fail "prototype material leaked into tracked files:"$'\n'"$hits"
  assert_absent "$ROOT/.$proto_dir" "no prototype runtime directory may exist"
  pass "no prototype flow, fixture, credential, runtime, or driver appears in this seam"
}

# ===========================================================================
# 10. Opt-in live check (skipped by default)
# ===========================================================================
#
# This is the ONLY place Kestra's own engine behaviour is asserted. It needs a real
# Kestra OSS 1.3.34 server on loopback with the tracked flows already deployed, and
# it runs only when FM_KESTRA_LIVE=1 is set explicitly.

test_live_engine_behaviour() {
  if [ "${FM_KESTRA_LIVE:-0}" != "1" ]; then
    pass "SKIP live engine check (set FM_KESTRA_LIVE=1 with a real loopback Kestra 1.3.34 to run it)"
    return 0
  fi
  local id out
  id=$("$RUN" --flow m1_controlled_failure) || fail "live: could not launch the controlled-failure flow"
  # The flow retries with a 0.5s interval; observed wall-clock gaps were about a
  # second each during the prototype, so poll rather than sleeping a fixed guess.
  local waited=0
  while [ "$waited" -lt 60 ]; do
    out=$("$STATUS" state "$id") || fail "live: could not read execution $id"
    case "$out" in *"state: FAILED"*) break ;; esac
    sleep 2
    waited=$((waited + 2))
  done
  assert_contains "$out" "task: always_fails state=FAILED attempts=3" \
    "live: Kestra must make exactly three attempts"
  assert_contains "$out" "RETRYING" "live: the retry transitions must be observable"
  assert_contains "$out" "not-run: after_failure" "live: the following task must never run"
  out=$("$STATUS" logs "$id") || fail "live: could not read logs for $id"
  assert_contains "$out" "attempt=2" "live: every attempt must be logged"
  pass "live: Kestra made three attempts, showed the retry transitions, and suppressed the following task"
}

test_typed_input_rejection_happens_before_any_request
test_undeclared_input_is_refused
test_missing_required_input_is_refused
test_allowed_execution_returns_one_opaque_id
test_credential_never_reaches_argv_and_the_auth_file_is_private
test_tracked_flow_configures_exactly_three_attempts
test_status_adapter_reports_three_attempts_and_the_retry_transitions
test_status_adapter_reports_every_attempt_log_line
test_task_after_a_terminal_failure_is_reported_as_not_run
test_replay_lineage_is_readable
test_replay_is_denied_through_every_entrypoint
test_a_flow_with_no_reviewed_source_is_not_addressable
test_every_mutating_verb_is_refused_by_the_run_adapter
test_every_mutating_operation_is_refused_by_the_status_adapter
test_the_http_gate_refuses_mutating_paths_for_every_role
test_a_run_may_not_target_another_namespace
test_check_mode_accepts_the_tracked_flows_without_config_or_network
test_deploy_refuses_a_flow_without_the_read_only_label
test_deploy_refuses_a_task_type_outside_the_core_plugin_allow_list
test_deploy_refuses_an_input_it_cannot_pre_check
test_deploy_refuses_a_validator_the_adapter_cannot_faithfully_pre_check
test_deploy_refuses_a_namespace_outside_the_allow_list
test_deploy_never_enables_deletion
test_a_non_loopback_endpoint_is_refused
test_only_a_declared_artifact_can_be_read
test_declared_outputs_are_reported
test_every_tracked_flow_is_read_only_and_core_only
test_no_credential_or_endpoint_value_is_committed
test_the_pinned_version_and_checksum_are_stated_once
test_no_prototype_artifact_is_present
test_live_engine_behaviour
