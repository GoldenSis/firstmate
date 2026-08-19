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
  "flowRevision": 1,
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
  "flowRevision": 2,
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
  "flowRevision": 1,
  "originalId": "EXECSUCCESS1",
  "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]},
  "taskRunList": [],
  "outputs": {}
}'

EXEC_FOREIGN_NAMESPACE_JSON='{
  "id": "EXECFOREIGNNS",
  "namespace": "someone.else",
  "flowId": "m1_shape",
  "flowRevision": 1,
  "state": {"current": "SUCCESS", "histories": []},
  "taskRunList": [],
  "outputs": {"artifact": "kestra:///foreign.txt"}
}'

EXEC_UNTRACKED_FLOW_JSON='{
  "id": "EXECUNTRACKED",
  "namespace": "firstmate.m1",
  "flowId": "not_reviewed",
  "flowRevision": 1,
  "state": {"current": "SUCCESS", "histories": []},
  "taskRunList": [],
  "outputs": {"artifact": "kestra:///untracked.txt"}
}'

EXEC_HISTORICAL_JSON='{
  "id": "EXECHISTORICAL1",
  "namespace": "firstmate.m1",
  "flowId": "m1_controlled_failure",
  "flowRevision": 1,
  "state": {"current": "FAILED", "histories": [
    {"state": "CREATED"}, {"state": "RUNNING"}, {"state": "FAILED"}]},
  "taskRunList": [
    {"taskId": "before_failure", "state": {"current": "SUCCESS", "histories": []}, "attempts": []},
    {"taskId": "always_fails", "state": {"current": "FAILED", "histories": []}, "attempts": []}
  ],
  "outputs": {}
}'

EXEC_MISSING_REVISION_JSON='{
  "id": "EXECNOREVISION",
  "namespace": "firstmate.m1",
  "flowId": "m1_controlled_failure",
  "state": {"current": "FAILED", "histories": []},
  "taskRunList": [],
  "outputs": {}
}'

FLOW_FAILURE_REVISION_JSON='{
  "revision": 2,
  "source": "id: m1_controlled_failure\nnamespace: firstmate.m1\n\nlabels:\n  system.readOnly: true\n\ntasks:\n  - id: before_failure\n    type: io.kestra.plugin.core.log.Log\n    message: controlled failure begins\n  - id: always_fails\n    type: io.kestra.plugin.core.execution.Fail\n    errorMessage: synthetic controlled failure\n  - id: after_failure\n    type: io.kestra.plugin.core.log.Log\n    message: this task must not run"
}'

FLOW_FAILURE_OLD_REVISION_JSON='{
  "revision": 1,
  "source": "id: m1_controlled_failure\nnamespace: firstmate.m1\n\nlabels:\n  system.readOnly: true\n\ntasks:\n  - id: before_failure\n    type: io.kestra.plugin.core.log.Log\n    message: controlled failure begins\n  - id: always_fails\n    type: io.kestra.plugin.core.execution.Fail\n    errorMessage: synthetic controlled failure"
}'

FLOW_SHAPE_REVISION_JSON='{
  "revision": 1,
  "source": "id: m1_shape\nnamespace: firstmate.m1\n\nlabels:\n  system.readOnly: true\n\ntasks:\n  - id: begin\n    type: io.kestra.plugin.core.log.Log\n    message: begin\n  - id: finish\n    type: io.kestra.plugin.core.debug.Return\n    format: finish"
}'

VALIDATION_OK_JSON='[
  {"constraints": null},
  {"constraints": null}
]'

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
    -X|--request) method=$2; shift 2 ;;
    --config) cfg=$2; shift 2 ;;
    --form-string) formstrings="$formstrings $2"; shift 2 ;;
    --max-time|--noproxy|-H|--data-binary|-F|-o|-w|-m) shift 2 ;;
    -q|--fail-with-body|-sS|-s|-S) shift ;;
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
  printf 'AUTHENV user=%s password=%s\n' "${FM_KESTRA_USER+x}" "${FM_KESTRA_PASSWORD+x}"
} >> "$FAKE_CURL_LOG"

path=${url#*/api/v1/main}
if [ -n "${FAKE_CURL_FAIL_MATCH:-}" ]; then
  case "$path" in
    *"$FAKE_CURL_FAIL_MATCH"*)
      printf '%s' "${FAKE_CURL_FAIL_BODY:-synthetic HTTP failure}"
      exit 22
      ;;
  esac
fi
case "$method $path" in
  'POST /flows/validate') printf '%s' "$FAKE_VALIDATE_RESPONSE" ;;
  'POST /flows/bulk'*) printf '[]' ;;
  'POST /executions/firstmate.m1/m1_shape'*) printf '{"id":"EXECSUCCESS1"}' ;;
  'POST /executions/firstmate.m1/m1_controlled_failure'*) printf '{"id":"EXECFAILURE1"}' ;;
  'GET /executions/EXECSUCCESS1/file'*) printf 'label=synthetic-alpha\nunits=3\nroute=safe\n' ;;
  'GET /executions/EXECSUCCESS1') printf '%s' "$FAKE_EXEC_SUCCESS" ;;
  'GET /executions/EXECFAILURE1') printf '%s' "$FAKE_EXEC_FAILURE" ;;
  'GET /executions/EXECREPLAY1') printf '%s' "$FAKE_EXEC_REPLAY" ;;
  'GET /executions/EXECFOREIGNNS') printf '%s' "$FAKE_EXEC_FOREIGN_NAMESPACE" ;;
  'GET /executions/EXECUNTRACKED') printf '%s' "$FAKE_EXEC_UNTRACKED_FLOW" ;;
  'GET /executions/EXECHISTORICAL1') printf '%s' "$FAKE_EXEC_HISTORICAL" ;;
  'GET /executions/EXECNOREVISION') printf '%s' "$FAKE_EXEC_MISSING_REVISION" ;;
  'GET /flows/firstmate.m1/m1_controlled_failure?revision=1&source=true') printf '%s' "$FAKE_FLOW_FAILURE_OLD_REVISION" ;;
  'GET /flows/firstmate.m1/m1_controlled_failure?revision=2&source=true') printf '%s' "$FAKE_FLOW_FAILURE_REVISION" ;;
  'GET /flows/firstmate.m1/m1_shape?revision=1&source=true') printf '%s' "$FAKE_FLOW_SHAPE_REVISION" ;;
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
    HTTP_PROXY="${SEAM_PROXY:-}" \
    HTTPS_PROXY="${SEAM_PROXY:-}" \
    FAKE_CURL_LOG="$workdir/curl.log" \
    FAKE_EXEC_SUCCESS="$EXEC_SUCCESS_JSON" \
    FAKE_EXEC_FAILURE="$EXEC_FAILURE_JSON" \
    FAKE_EXEC_REPLAY="$EXEC_REPLAY_JSON" \
    FAKE_EXEC_FOREIGN_NAMESPACE="$EXEC_FOREIGN_NAMESPACE_JSON" \
    FAKE_EXEC_UNTRACKED_FLOW="$EXEC_UNTRACKED_FLOW_JSON" \
    FAKE_EXEC_HISTORICAL="$EXEC_HISTORICAL_JSON" \
    FAKE_EXEC_MISSING_REVISION="$EXEC_MISSING_REVISION_JSON" \
    FAKE_FLOW_FAILURE_REVISION="$FLOW_FAILURE_REVISION_JSON" \
    FAKE_FLOW_FAILURE_OLD_REVISION="$FLOW_FAILURE_OLD_REVISION_JSON" \
    FAKE_FLOW_SHAPE_REVISION="$FLOW_SHAPE_REVISION_JSON" \
    FAKE_LOGS_FAILURE="$LOGS_FAILURE_JSON" \
    FAKE_VALIDATE_RESPONSE="${SEAM_VALIDATE_RESPONSE:-$VALIDATION_OK_JSON}" \
    FAKE_CURL_FAIL_MATCH="${SEAM_FAIL_MATCH:-}" \
    FAKE_CURL_FAIL_BODY="${SEAM_FAIL_BODY:-}" \
    FM_KESTRA_CONFIG="$workdir/absent-kestra.env" \
    FM_KESTRA_BASE_URL="${SEAM_BASE_URL:-http://127.0.0.1:18080}" \
    FM_KESTRA_TENANT=main \
    FM_KESTRA_NAMESPACE="${SEAM_NAMESPACE:-$NS}" \
    FM_KESTRA_USER=synthetic-operator \
    FM_KESTRA_PASSWORD="$SEAM_PASSWORD" \
    "$@"
}

SEAM_PASSWORD='Synthetic-M1-Only'
SEAM_BASE_URL=""
SEAM_NAMESPACE=""
SEAM_VALIDATE_RESPONSE=""
SEAM_FAIL_MATCH=""
SEAM_FAIL_BODY=""
SEAM_PROXY=""

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

test_malformed_and_multiline_input_values_are_refused() {
  local d out rc bad case_name expected
  for bad in 'units=1-2' 'units=-'; do
    d=$(workdir "reject-${bad#*=}")
    rc=0
    out=$(seam "$d" "$RUN" --flow m1_shape \
      --input route=safe --input label=synthetic-alpha --input "$bad" 2>&1) || rc=$?
    expect_code 2 "$rc" "malformed integer $bad must be refused"
    assert_contains "$out" "must be an integer" "the malformed integer refusal must name its type"
    [ ! -s "$d/curl.log" ] || fail "malformed integer $bad must be refused before any request"
  done

  for case_name in \
    '18446744073709551619:must be <= 5' \
    '-18446744073709551613:must be >= 1'
  do
    bad=${case_name%%:*}
    expected=${case_name#*:}
    d=$(workdir "reject-wide-${bad#-}")
    rc=0
    out=$(seam "$d" "$RUN" --flow m1_shape \
      --input route=safe --input label=synthetic-alpha --input "units=$bad" 2>&1) || rc=$?
    expect_code 2 "$rc" "out-of-range arbitrary-length integer $bad must be refused"
    assert_contains "$out" "$expected" \
      "arbitrary-length integer comparison must preserve the mathematical sign and magnitude"
    [ ! -s "$d/curl.log" ] \
      || fail "out-of-range arbitrary-length integer $bad reached the request layer"
  done

  d=$(workdir reject-multiline)
  rc=0
  out=$(seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input $'label=synthetic-alpha\ninjected=value' 2>&1) || rc=$?
  expect_code 2 "$rc" "a multiline string input must be refused"
  assert_contains "$out" "single-line value" "the multiline refusal must name the line boundary"
  [ ! -s "$d/curl.log" ] || fail "a multiline input must be refused before any request"
  pass "integer syntax, arbitrary-length ranges, and single-line serialization are validated before any request"
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
  SEAM_PROXY=http://127.0.0.1:65535 seam "$d" "$RUN" --flow m1_shape \
    --input units=3 --input route=safe --input label=synthetic-alpha >/dev/null 2>&1 \
    || fail "run must succeed for the credential check"
  assert_no_grep "$SEAM_PASSWORD" "$d/curl.log" "the credential must never appear in curl argv"
  assert_no_grep "synthetic-operator" "$d/curl.log" "the account name must never appear in curl argv"
  assert_grep "AUTHFILE mode=-rw-------" "$d/curl.log" \
    "the credential must be handed over through a mode-0600 file"
  assert_grep "AUTHENV user= password=" "$d/curl.log" \
    "curl must not inherit the credential variables from the adapter environment"
  assert_grep 'ARGV -q --noproxy * --config ' "$d/curl.log" \
    "curl must ignore user config and bypass every proxy before loading the credential"
  pass "the Basic Auth credential is isolated from argv, the child environment, curl config, and proxies"
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
  pass "the task after a terminal failure is reported as not-run from the execution's recorded flow revision"
}

test_state_uses_the_recorded_revision_instead_of_the_current_flow() {
  local d out rc
  d=$(workdir historical-revision)
  assert_grep 'id: after_failure' "$FLOWS/m1_controlled_failure.yaml" \
    "the current tracked flow must contain the task added after the historical execution"
  rc=0
  out=$(seam "$d" "$STATUS" state EXECHISTORICAL1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading a historical execution must succeed"
  assert_not_contains "$out" "not-run: after_failure" \
    "a task added after the execution's recorded revision must not be called suppressed"
  assert_grep '/flows/firstmate.m1/m1_controlled_failure?revision=1&source=true' "$d/curl.log" \
    "suppression evidence must resolve the execution's recorded flowRevision"
  pass "not-run evidence comes from the exact flow revision that executed"
}

test_state_says_when_revision_accurate_suppression_is_unavailable() {
  local d out rc
  d=$(workdir missing-revision)
  rc=0
  out=$(seam "$d" "$STATUS" state EXECNOREVISION 2>&1) || rc=$?
  expect_code 0 "$rc" "state evidence without flowRevision must remain readable"
  assert_contains "$out" "not-run: unavailable: execution has no valid flowRevision" \
    "the adapter must explicitly omit suppression evidence it cannot make revision-accurate"
  pass "missing revision data produces an explicit unavailable marker instead of a silent partial answer"
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

test_every_status_read_is_bound_to_the_allow_list_before_follow_up() {
  local execution kind needle command d out rc requests
  for execution in EXECFOREIGNNS EXECUNTRACKED; do
    case "$execution" in
      EXECFOREIGNNS) kind="foreign namespace"; needle="refused" ;;
      EXECUNTRACKED) kind="untracked flow"; needle="not allow-listed" ;;
    esac
    for command in state logs outputs lineage artifact; do
      d=$(workdir "deny-read-$execution-$command")
      rc=0
      if [ "$command" = artifact ]; then
        out=$(seam "$d" "$STATUS" artifact "$execution" 'kestra:///blocked.txt' 2>&1) || rc=$?
      else
        out=$(seam "$d" "$STATUS" "$command" "$execution" 2>&1) || rc=$?
      fi
      expect_code 2 "$rc" "$command must refuse an execution from a $kind"
      assert_contains "$out" "$needle" \
        "$command must explain that the execution is outside the allow-list"
      assert_not_contains "$out" "execution:" \
        "$command must print no evidence before the allow-list decision"
      requests=$(grep -Ec '^(GET|POST) ' "$d/curl.log" || true)
      [ "$requests" -eq 1 ] \
        || fail "$command made a follow-up request for a $kind execution ($requests requests)"
    done
  done
  pass "every status subcommand refuses foreign namespaces and untracked flows before output or follow-up requests"
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

test_the_http_gate_allows_only_exact_role_paths() {
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
        "POST /executions/firstmate.m1/m1_shape/eval" \
        "GET /executions/webhook/firstmate.m1/m1_shape/key" \
        "GET /executions/EXECSUCCESS1/unknown" \
        "GET /logs/EXECFAILURE1/extra"
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
    fm_kestra_path_allowed read GET "/executions/EXECSUCCESS1/file?path=kestra%3A%2F%2Fartifact" \
      || printf "DENIED read artifact\n"
    fm_kestra_path_allowed read GET "/flows/firstmate.m1/m1_shape?revision=1&source=true" \
      || printf "DENIED read flow revision\n"
  ' _ "$ROOT" 2>&1) || rc=$?
  [ -z "$out" ] || fail "HTTP gate role matrix is wrong:"$'\n'"$out"
  pass "the HTTP gate admits only the exact deploy, run, execution, log, artifact, and revision paths"
}

test_the_http_gate_accepts_no_raw_curl_options() {
  local attack body d out rc role
  for role in deploy run read; do
    for attack in request url proxy config; do
      d=$(workdir "structured-$role-$attack")
      body="$d/body.yaml"
      printf 'id: harmless\n' > "$body"
      rc=0
      # shellcheck disable=SC2016 # The child shell owns its positional parameters.
      out=$(seam "$d" bash -c '
        . "$1/bin/fm-kestra-lib.sh"
        fm_kestra_load_config
        role=$2
        body=$3
        case "$4" in
          request) set -- -X DELETE ;;
          url) set -- --url http://example.invalid/ ;;
          proxy) set -- --proxy http://127.0.0.1:65535 ;;
          config) set -- -K "$body" ;;
        esac
        case "$role" in
          deploy) fm_kestra_request deploy POST /flows/validate "$body" "$@" ;;
          run) fm_kestra_request run POST /executions/firstmate.m1/m1_shape safe=value "$@" ;;
          read) fm_kestra_request read GET /executions/EXECSUCCESS1 "$@" ;;
        esac
      ' _ "$ROOT" "$role" "$body" "$attack" 2>&1) || rc=$?
      expect_code 2 "$rc" "$role must refuse raw curl option injection through $attack"
      assert_contains "$out" "refused:" "$role must identify the structured request refusal"
      [ ! -s "$d/curl.log" ] \
        || fail "$role launched curl after a raw option injection attempt through $attack"
    done
  done
  pass "deploy, run, and read construct requests only from role-specific structured values"
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
  local dir=$1 file repo rc=0 out
  file=$(find "$dir" -maxdepth 1 -type f -name '*.yaml' | head -1)
  repo="$dir/repo"
  mkdir -p "$repo/bin" "$repo/kestra/flows"
  cp "$ROOT/bin/fm-kestra-lib.sh" "$ROOT/bin/fm-kestra-deploy.sh" "$repo/bin/"
  cp "$file" "$repo/kestra/flows/"
  git -C "$repo" init -q
  git -C "$repo" add bin kestra/flows
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  out=$(env -i PATH="$BASE_PATH" HOME="$dir" "$repo/bin/fm-kestra-deploy.sh" --check 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

test_flow_discovery_uses_only_canonical_unchanged_git_sources() {
  local d out rc
  d="$TMP_ROOT/tracked-flow-root"
  mkdir -p "$d/bin" "$d/kestra/flows" "$d/ignored"
  cp "$ROOT/bin/fm-kestra-lib.sh" "$d/bin/fm-kestra-lib.sh"
  fixture_flow "$d/kestra/flows" tracked 'id: tracked
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: hello'
  git -C "$d" init -q
  git -C "$d" add bin/fm-kestra-lib.sh kestra/flows/tracked.yaml
  git -C "$d" -c user.name=Test -c user.email=test@example.invalid commit -qm initial

  out=$(FM_KESTRA_FLOWS_DIR="$d/ignored" bash -c '. "$1"; fm_kestra_flows_dir' \
    _ "$ROOT/bin/fm-kestra-lib.sh")
  [ "$out" = "$FLOWS" ] || fail "FM_KESTRA_FLOWS_DIR changed the production flow root: $out"

  fixture_flow "$d/kestra/flows" untracked 'id: untracked'
  rc=0
  out=$(bash -c '. "$1"; fm_kestra_flow_files' _ "$d/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "an untracked YAML flow must stop discovery"
  assert_contains "$out" "untracked flow sources" "the refusal must name the untracked source"
  rm -f "$d/kestra/flows/untracked.yaml"

  printf '\n# local edit\n' >> "$d/kestra/flows/tracked.yaml"
  rc=0
  out=$(bash -c '. "$1"; fm_kestra_flow_files' _ "$d/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "a locally modified tracked flow must stop discovery"
  assert_contains "$out" "local changes" "the refusal must name the unreviewed edit"
  pass "flow discovery is fixed to canonical tracked sources and refuses local or untracked YAML"
}

test_deploy_flow_snapshot_is_immutable_after_capture() {
  local d out
  d="$TMP_ROOT/immutable-flow-snapshot"
  mkdir -p "$d/bin" "$d/kestra/flows"
  cp "$ROOT/bin/fm-kestra-lib.sh" "$d/bin/fm-kestra-lib.sh"
  fixture_flow "$d/kestra/flows" tracked 'id: reviewed
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: reviewed'
  git -C "$d" init -q
  git -C "$d" add bin/fm-kestra-lib.sh kestra/flows/tracked.yaml
  git -C "$d" -c user.name=Test -c user.email=test@example.invalid commit -qm initial

  out=$(TMPDIR="$d" bash -c '
    . "$1/bin/fm-kestra-lib.sh"
    fm_kestra_snapshot_flow_files
    [ "${#FM_KESTRA_SNAPSHOT_FILES[@]}" -eq 1 ] || exit 1
    printf "message: changed\n" > "$1/kestra/flows/tracked.yaml"
    cat "${FM_KESTRA_SNAPSHOT_FILES[0]}"
  ' _ "$d") || fail "the HEAD flow snapshot must remain readable after the worktree source changes"
  assert_contains "$out" "message: reviewed" "the snapshot must contain the reviewed HEAD bytes"
  assert_not_contains "$out" "message: changed" "the snapshot must not re-read the mutable worktree source"
  pass "deployment flow snapshots remain bound to immutable HEAD blobs"
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

test_deploy_requires_an_exact_true_read_only_label() {
  local d out rc
  d="$TMP_ROOT/inexact-readonly"
  fixture_flow "$d" mutable 'id: mutable
namespace: firstmate.m1

labels:
  system.readOnly: "untrue"

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: hello'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a read-only label containing but not equal to true must be refused"
  assert_contains "$out" 'missing label system.readOnly' "the refusal must name the exact label contract"
  pass "the read-only label value must parse to exactly true"
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

test_deploy_checks_each_task_map_independently() {
  local d out rc
  d="$TMP_ROOT/task-map-order"
  fixture_flow "$d" reordered 'id: reordered
namespace: firstmate.m1

labels:
  system.readOnly: true

tasks:
  - id: shell
    commands:
      - echo hi
    type: io.kestra.plugin.scripts.shell.Commands'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a nested list must not hide the task type that follows it"
  assert_contains "$out" "outside the core-plugin allow-list" \
    "the parser must retain ownership of the surrounding task map"

  d="$TMP_ROOT/task-map-inline-type"
  fixture_flow "$d" inline 'id: inline
namespace: firstmate.m1

labels:
  system.readOnly: true

tasks:
  - type: io.kestra.plugin.scripts.shell.Commands
    id: shell'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a task map beginning with type must not bypass validation"
  assert_contains "$out" "outside the core-plugin allow-list" \
    "an inline list-item type must be validated"
  assert_contains "$out" "task map is missing id" \
    "an unsupported field order must fail closed instead of being partially parsed"

  d="$TMP_ROOT/task-map-wide-indent"
  fixture_flow "$d" wide 'id: wide
namespace: firstmate.m1

labels:
  system.readOnly: true

tasks:
    - id: shell
      type: io.kestra.plugin.scripts.shell.Commands'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "wider valid YAML indentation must not hide a task map"
  assert_contains "$out" "outside the core-plugin allow-list" \
    "task-list ownership must not depend on exactly two spaces of indentation"
  pass "every task map is independently parsed or rejected without order-dependent gaps"
}

test_deploy_checks_every_supported_task_container() {
  local d out rc type
  d="$TMP_ROOT/task-containers"
  fixture_flow "$d" containers 'id: containers
namespace: firstmate.m1

labels:
  system.readOnly: true

tasks:
  - id: sequential
    type: io.kestra.plugin.core.flow.Sequential
    tasks:
      - id: nested_tasks
        type: io.kestra.plugin.external.NestedTasks
    errors:
      - id: nested_errors
        type: io.kestra.plugin.external.NestedErrors
    finally:
      - id: nested_finally
        type: io.kestra.plugin.external.NestedFinally
  - id: conditional
    type: io.kestra.plugin.core.flow.If
    condition: "{{ true }}"
    then:
      - id: then_task
        type: io.kestra.plugin.external.Then
    else:
      - id: else_task
        type: io.kestra.plugin.external.Else
  - id: switch
    type: io.kestra.plugin.core.flow.Switch
    value: synthetic
    cases:
      synthetic:
        - id: case_task
          type: io.kestra.plugin.external.Case
    defaults:
      - id: default_task
        type: io.kestra.plugin.external.Default
  - id: dag
    type: io.kestra.plugin.core.flow.Dag
    tasks:
      - task:
          id: dag_task
          type: io.kestra.plugin.external.Dag

errors:
  - id: flow_error
    type: io.kestra.plugin.external.FlowErrors

finally:
  - id: flow_finally
    type: io.kestra.plugin.external.FlowFinally

afterExecution:
  - id: after_execution
    type: io.kestra.plugin.external.AfterExecution

listeners:
  - tasks:
      - id: listener_task
        type: io.kestra.plugin.external.Listener'
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "a non-core task in any supported Kestra task container must be refused"
  for type in NestedTasks NestedErrors NestedFinally Then Else Case Default Dag \
    FlowErrors FlowFinally AfterExecution Listener
  do
    assert_contains "$out" "io.kestra.plugin.external.$type" \
      "the parser must validate tasks in the $type container shape"
  done
  pass "all Kestra 1.3.34 flow, flowable, switch, DAG, and listener task containers are validated"
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
  rc=0
  # The prefix stays INSIDE the command substitution: an assignment prefix on an
  # assignment would leak into the rest of the suite.
  out=$(SEAM_NAMESPACE=someone.else seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 2 "$rc" "a flow outside the allow-listed namespace must be refused"
  assert_contains "$out" "only someone.else is allow-listed" "the refusal must name the allow-listed namespace"
  [ ! -s "$d/curl.log" ] || fail "a namespace refusal must happen before any request"
  pass "the deployer refuses to update any namespace but the one allow-listed in local config"
}

test_deploy_never_enables_deletion() {
  local body_calls body_files d rc
  d=$(workdir deploy-run)
  rc=0
  seam "$d" "$DEPLOY" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "deploying the tracked flows must succeed against the fake server"
  assert_grep "flows/bulk?delete=false&namespace=$NS" "$d/curl.log" \
    "the namespace update must disable deletion"
  assert_grep "POST http://127.0.0.1:18080/api/v1/main/flows/validate" "$d/curl.log" \
    "flows must be validated server-side before the update"
  body_calls=$(sed -n 's/^ARGV .*--data-binary @\([^ ]*\).*/\1/p' "$d/curl.log" | wc -l | tr -d ' ')
  body_files=$(sed -n 's/^ARGV .*--data-binary @\([^ ]*\).*/\1/p' "$d/curl.log" | sort -u | wc -l | tr -d ' ')
  [ "$body_calls" -eq 2 ] && [ "$body_files" -eq 1 ] \
    || fail "server validation and deployment must send the same staged HEAD body"
  assert_no_grep "delete=true" "$d/curl.log" "deletion must never be enabled"
  # Kestra must never be handed Git reconciliation; the seam pushes instead.
  assert_no_grep "/git" "$d/curl.log" "the deployer must never ask Kestra to reconcile Git"
  pass "the deployer validates first, then updates the allow-listed namespace with deletion disabled"
}

test_deploy_requires_every_server_validation_result_to_pass() {
  local d out rc
  d=$(workdir deploy-mixed-validation)
  rc=0
  out=$(SEAM_VALIDATE_RESPONSE='[{"constraints":null},{"constraints":"invalid flow"}]' \
    seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 1 "$rc" "one valid response object must not mask a rejected flow"
  assert_contains "$out" "invalid flow" "the rejected validation response must remain visible"
  assert_no_grep "/flows/bulk?" "$d/curl.log" \
    "the deployer must not update the namespace after any validation rejection"
  pass "server validation succeeds only when every expected flow result passes"
}

test_http_failures_are_failures_and_keep_the_response_diagnostic() {
  local d out rc
  d=$(workdir deploy-http-failure)
  rc=0
  out=$(SEAM_FAIL_MATCH='/flows/bulk' SEAM_FAIL_BODY='bulk update rejected' \
    seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 1 "$rc" "an HTTP failure from the namespace update must fail deployment"
  assert_contains "$out" "bulk update rejected" "the server response body must remain diagnostic evidence"
  assert_not_contains "$out" "deployed:" "an HTTP-rejected update must never be reported as deployed"
  pass "HTTP failures propagate without discarding the server response body"
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

test_artifact_output_is_replaced_only_after_a_successful_download() {
  local d out rc uri target contents
  d=$(workdir artifact-failure)
  uri='kestra:///firstmate/m1/m1-shape/executions/EXECSUCCESS1/tasks/artifact/AAA/1.txt'
  target="$d/existing.txt"
  printf 'keep original\n' > "$target"
  rc=0
  out=$(SEAM_FAIL_MATCH='/file?path=' SEAM_FAIL_BODY='artifact unavailable' \
    seam "$d" "$STATUS" artifact EXECSUCCESS1 "$uri" --out "$target" 2>&1) || rc=$?
  expect_code 1 "$rc" "a failed artifact request must fail"
  assert_contains "$out" "artifact unavailable" "the failed download must retain its diagnostic"
  contents=$(cat "$target")
  [ "$contents" = "keep original" ] || fail "a failed artifact request replaced the existing output"
  pass "artifact downloads preserve an existing destination until the request succeeds"
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

test_log_transport_failure_cannot_be_masked_by_jq() {
  local d out rc
  d=$(workdir logs-http-failure)
  rc=0
  out=$(SEAM_FAIL_MATCH='/logs/EXECFAILURE1' SEAM_FAIL_BODY='logs unavailable' \
    seam "$d" "$STATUS" logs EXECFAILURE1 2>&1) || rc=$?
  expect_code 1 "$rc" "a failed log request must not become an empty successful report"
  assert_contains "$out" "logs unavailable" "the log failure must retain its response diagnostic"

  d=$(workdir outputs-http-failure)
  rc=0
  out=$(SEAM_FAIL_MATCH='/executions/EXECSUCCESS1' SEAM_FAIL_BODY='execution unavailable' \
    seam "$d" "$STATUS" outputs EXECSUCCESS1 2>&1) || rc=$?
  expect_code 1 "$rc" "a failed output request must not become an empty successful report"
  assert_contains "$out" "execution unavailable" "the output failure must retain its response diagnostic"
  pass "log and output transport failures propagate before JSON formatting"
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
test_malformed_and_multiline_input_values_are_refused
test_allowed_execution_returns_one_opaque_id
test_credential_never_reaches_argv_and_the_auth_file_is_private
test_tracked_flow_configures_exactly_three_attempts
test_status_adapter_reports_three_attempts_and_the_retry_transitions
test_status_adapter_reports_every_attempt_log_line
test_task_after_a_terminal_failure_is_reported_as_not_run
test_state_uses_the_recorded_revision_instead_of_the_current_flow
test_state_says_when_revision_accurate_suppression_is_unavailable
test_replay_lineage_is_readable
test_replay_is_denied_through_every_entrypoint
test_a_flow_with_no_reviewed_source_is_not_addressable
test_every_status_read_is_bound_to_the_allow_list_before_follow_up
test_every_mutating_verb_is_refused_by_the_run_adapter
test_every_mutating_operation_is_refused_by_the_status_adapter
test_the_http_gate_allows_only_exact_role_paths
test_the_http_gate_accepts_no_raw_curl_options
test_a_run_may_not_target_another_namespace
test_check_mode_accepts_the_tracked_flows_without_config_or_network
test_flow_discovery_uses_only_canonical_unchanged_git_sources
test_deploy_flow_snapshot_is_immutable_after_capture
test_deploy_refuses_a_flow_without_the_read_only_label
test_deploy_requires_an_exact_true_read_only_label
test_deploy_refuses_a_task_type_outside_the_core_plugin_allow_list
test_deploy_checks_each_task_map_independently
test_deploy_checks_every_supported_task_container
test_deploy_refuses_an_input_it_cannot_pre_check
test_deploy_refuses_a_validator_the_adapter_cannot_faithfully_pre_check
test_deploy_refuses_a_namespace_outside_the_allow_list
test_deploy_never_enables_deletion
test_deploy_requires_every_server_validation_result_to_pass
test_http_failures_are_failures_and_keep_the_response_diagnostic
test_a_non_loopback_endpoint_is_refused
test_only_a_declared_artifact_can_be_read
test_artifact_output_is_replaced_only_after_a_successful_download
test_declared_outputs_are_reported
test_log_transport_failure_cannot_be_masked_by_jq
test_every_tracked_flow_is_read_only_and_core_only
test_no_credential_or_endpoint_value_is_committed
test_the_pinned_version_and_checksum_are_stated_once
test_no_prototype_artifact_is_present
test_live_engine_behaviour
