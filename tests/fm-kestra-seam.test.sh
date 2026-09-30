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
#   does. Nothing here proves Kestra retries a failing task three times, and
#   nothing here proves Kestra returns a flow's submitted source unchanged at a
#   recorded revision; the fake models both.
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
#      opt-in live section at the end of this file checks it against a real server
#      when FM_KESTRA_LIVE=1 is set. It is skipped by default.
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

# The seam resolves flows from Git HEAD, so the fixtures below are derived from
# HEAD too: the fake server's "deployed" sources are the HEAD blobs and the
# revision record names their blob ids.
HEAD_COMMIT=$(git -C "$ROOT" rev-parse HEAD) || fail "tests need a Git HEAD"
SHAPE_BLOB=$(git -C "$ROOT" rev-parse "HEAD:kestra/flows/m1_shape.yaml") \
  || fail "m1_shape.yaml must be tracked at HEAD"
FAILURE_BLOB=$(git -C "$ROOT" rev-parse "HEAD:kestra/flows/m1_controlled_failure.yaml") \
  || fail "m1_controlled_failure.yaml must be tracked at HEAD"

# --- recorded response shapes ----------------------------------------------
#
# These mirror the execution JSON Kestra OSS returns: a state history, a
# taskRunList with per-task attempt arrays and per-task outputs. The failure shape
# is the one that matters most - three attempts, the retry transitions, and NO
# taskRun for the task after the failure.

EXEC_SUCCESS_JSON='{
  "id": "EXECSUCCESS1",
  "namespace": "firstmate.m1",
  "flowId": "m1_shape",
  "flowRevision": 1,
  "state": {"current": "SUCCESS", "histories": [
    {"state": "CREATED"}, {"state": "RUNNING"}, {"state": "SUCCESS"}]},
  "taskRunList": [
    {"taskId": "begin", "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]}, "attempts": [{"state": {"current": "SUCCESS"}}]},
    {"taskId": "sequential", "state": {"current": "SUCCESS", "histories": []}, "attempts": []},
    {"taskId": "seq_first", "state": {"current": "SUCCESS", "histories": []}, "attempts": [{"state": {"current": "SUCCESS"}}]},
    {"taskId": "seq_second", "state": {"current": "SUCCESS", "histories": []}, "attempts": [{"state": {"current": "SUCCESS"}}], "outputs": {"value": "sequential second"}},
    {"taskId": "parallel", "state": {"current": "SUCCESS", "histories": []}, "attempts": []},
    {"taskId": "par_left", "state": {"current": "SUCCESS", "histories": []}, "attempts": [{"state": {"current": "SUCCESS"}}]},
    {"taskId": "par_right", "state": {"current": "SUCCESS", "histories": []}, "attempts": [{"state": {"current": "SUCCESS"}}]},
    {"taskId": "choose_route", "state": {"current": "SUCCESS", "histories": []}, "attempts": []},
    {"taskId": "safe_branch", "state": {"current": "SUCCESS", "histories": []}, "attempts": [{"state": {"current": "SUCCESS"}}], "outputs": {"value": "safe branch selected"}},
    {"taskId": "artifact", "state": {"current": "SUCCESS", "histories": []}, "attempts": [{"state": {"current": "SUCCESS"}}], "outputs": {"uri": "kestra:///firstmate/m1/m1-shape/executions/EXECSUCCESS1/tasks/artifact/AAA/1.txt"}},
    {"taskId": "finish", "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]}, "attempts": [{"state": {"current": "SUCCESS"}}], "outputs": {"value": "finished static shape"}}
  ]
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
  ]
}'

EXEC_REPLAY_JSON='{
  "id": "EXECREPLAY1",
  "namespace": "firstmate.m1",
  "flowId": "m1_shape",
  "flowRevision": 1,
  "originalId": "EXECSUCCESS1",
  "state": {"current": "SUCCESS", "histories": [{"state": "CREATED"}, {"state": "SUCCESS"}]},
  "taskRunList": []
}'

EXEC_FOREIGN_NAMESPACE_JSON='{
  "id": "EXECFOREIGNNS",
  "namespace": "someone.else",
  "flowId": "m1_shape",
  "flowRevision": 1,
  "state": {"current": "SUCCESS", "histories": []},
  "taskRunList": [{"taskId": "artifact", "state": {"current": "SUCCESS"}, "outputs": {"uri": "kestra:///foreign.txt"}}]
}'

EXEC_UNTRACKED_FLOW_JSON='{
  "id": "EXECUNTRACKED",
  "namespace": "firstmate.m1",
  "flowId": "not_reviewed",
  "flowRevision": 1,
  "state": {"current": "SUCCESS", "histories": []},
  "taskRunList": [{"taskId": "artifact", "state": {"current": "SUCCESS"}, "outputs": {"uri": "kestra:///untracked.txt"}}]
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
  ]
}'

EXEC_MISSING_REVISION_JSON='{
  "id": "EXECNOREVISION",
  "namespace": "firstmate.m1",
  "flowId": "m1_controlled_failure",
  "state": {"current": "FAILED", "histories": []},
  "taskRunList": []
}'

EXEC_RUNNING_JSON='{
  "id": "EXECRUNNING1",
  "namespace": "firstmate.m1",
  "flowId": "m1_controlled_failure",
  "flowRevision": 2,
  "state": {"current": "RUNNING", "histories": [{"state": "CREATED"}, {"state": "RUNNING"}]},
  "taskRunList": [
    {"taskId": "before_failure", "state": {"current": "SUCCESS", "histories": []}, "attempts": []}
  ]
}'

EXEC_UNREADABLE_REVISION_JSON='{
  "id": "EXECGONEREV",
  "namespace": "firstmate.m1",
  "flowId": "m1_controlled_failure",
  "flowRevision": 9,
  "state": {"current": "FAILED", "histories": []},
  "taskRunList": []
}'

# A historical revision of the controlled-failure flow, from before after_failure
# existed. It must pass the static grammar because the status adapter parses it.
HISTORICAL_FAILURE_SOURCE='id: m1_controlled_failure
namespace: firstmate.m1

labels:
  system.readOnly: "true"

tasks:
  - id: before_failure
    type: io.kestra.plugin.core.log.Log
    message: "controlled failure begins"
  - id: always_fails
    type: io.kestra.plugin.core.execution.Fail
    errorMessage: "synthetic controlled failure"
    retry:
      type: constant
      interval: PT0.5S
      maxAttempts: 3
      maxDuration: PT10S
      warningOnRetry: true'

VALIDATION_OK_JSON='[
  {"constraints": null},
  {"constraints": null}
]'

BULK_OK_JSON='[
  {"id": "m1_controlled_failure", "namespace": "firstmate.m1", "revision": 2},
  {"id": "m1_shape", "namespace": "firstmate.m1", "revision": 1}
]'

LOGS_FAILURE_JSON='[
  {"taskId": "before_failure", "attemptNumber": 0, "level": "INFO", "message": "controlled failure begins"},
  {"taskId": "always_fails", "attemptNumber": 0, "level": "ERROR", "message": "synthetic controlled failure"},
  {"taskId": "always_fails", "attemptNumber": 1, "level": "ERROR", "message": "synthetic controlled failure"},
  {"taskId": "always_fails", "attemptNumber": 2, "level": "ERROR", "message": "synthetic controlled failure"}
]'

# --- the fake Kestra HTTP surface -------------------------------------------
#
# One fakebin curl. It appends `<METHOD> <URL>` to FAKE_CURL_LOG, records how the
# credential reached it, and answers from the recorded shapes above. Flow sources
# at a revision are served from FAKE_FLOW_DIR/<flow>@<revision>.yaml; a missing
# file answers like an HTTP 404 under --fail-with-body (exit 22 with a body). Any
# request the seam is not supposed to make still gets LOGGED, so a test can prove
# the seam never attempted it.

make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
method=GET url="" cfg="" formstrings="" output="" body=""
uploads=()
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--request) method=$2; shift 2 ;;
    --config) cfg=$2; shift 2 ;;
    --form-string) formstrings="$formstrings $2"; shift 2 ;;
    --form) uploads+=("$2"); shift 2 ;;
    --data-binary) body=${2#@}; shift 2 ;;
    -o|--output) output=$2; shift 2 ;;
    --max-time|--noproxy|-H|-F|-w|-m) shift 2 ;;
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
if [ "$method" = POST ] && [[ "$path" == /flows/* ]]; then
  destination="$FAKE_FLOW_DIR/uploads/${path#/flows/}"
  destination=${destination%%\?*}
  mkdir -p "$destination"
  [ -z "$body" ] || cp "$body" "$destination/body"
  index=0
  for upload in "${uploads[@]}"; do
    file=${upload#flows=@}
    file=${file%%;filename=*}
    file=${file#\"}
    file=${file%\"}
    cp "$file" "$destination/$index.yaml" || exit 1
    index=$((index + 1))
  done
fi
emit() {
  if [ -n "$output" ]; then
    printf '%s' "$1" > "$output"
  else
    printf '%s' "$1"
  fi
}
emit_artifact() {
  if [ "${FAKE_ARTIFACT_BINARY:-0}" = 1 ]; then
    if [ -n "$output" ]; then
      printf 'binary\000artifact\n\n' > "$output"
    else
      printf 'binary\000artifact\n\n'
    fi
  else
    emit 'kind=synthetic
shape=m1
'
  fi
}
if [ -n "${FAKE_CURL_FAIL_MATCH:-}" ]; then
  case "$path" in
    *"$FAKE_CURL_FAIL_MATCH"*)
      emit "${FAKE_CURL_FAIL_BODY:-synthetic HTTP failure}"
      exit "${FAKE_CURL_FAIL_CODE:-22}"
      ;;
  esac
fi
case "$method $path" in
  'POST /flows/validate') emit "$FAKE_VALIDATE_RESPONSE" ;;
  'POST /flows/bulk'*|'POST /flows/firstmate.m1?delete=false') emit "$FAKE_BULK_RESPONSE" ;;
  'POST /executions/firstmate.m1/m1_shape?revision='*)
    rev=${path##*revision=}
    emit "{\"id\":\"EXECSUCCESS1\",\"flowRevision\":${FAKE_EXEC_REVISION_OVERRIDE:-$rev}}" ;;
  'POST /executions/firstmate.m1/m1_controlled_failure?revision='*)
    rev=${path##*revision=}
    emit "{\"id\":\"EXECFAILURE1\",\"flowRevision\":${FAKE_EXEC_REVISION_OVERRIDE:-$rev}}" ;;
  'GET /executions/EXECSUCCESS1/file'*) emit_artifact ;;
  'GET /executions/EXECSUCCESS1') emit "$FAKE_EXEC_SUCCESS" ;;
  'GET /executions/EXECFAILURE1') emit "$FAKE_EXEC_FAILURE" ;;
  'GET /executions/EXECREPLAY1') emit "$FAKE_EXEC_REPLAY" ;;
  'GET /executions/EXECFOREIGNNS') emit "$FAKE_EXEC_FOREIGN_NAMESPACE" ;;
  'GET /executions/EXECUNTRACKED') emit "$FAKE_EXEC_UNTRACKED_FLOW" ;;
  'GET /executions/EXECHISTORICAL1') emit "$FAKE_EXEC_HISTORICAL" ;;
  'GET /executions/EXECNOREVISION') emit "$FAKE_EXEC_MISSING_REVISION" ;;
  'GET /executions/EXECRUNNING1') emit "$FAKE_EXEC_RUNNING" ;;
  'GET /executions/EXECGONEREV') emit "$FAKE_EXEC_UNREADABLE_REVISION" ;;
  'GET /flows/firstmate.m1/'*'?revision='*'&source=true')
    flow=${path#/flows/firstmate.m1/}
    flow=${flow%%\?*}
    rev=${path#*revision=}
    rev=${rev%%&*}
    file="$FAKE_FLOW_DIR/$flow@$rev.yaml"
    if [ -f "$file" ]; then
      emit "$(jq -n --arg id "$flow" --arg ns firstmate.m1 --argjson rev "$rev" --rawfile src "$file" \
        '{id: $id, namespace: $ns, revision: $rev, source: $src}')"
    else
      emit '{"message":"Not Found"}'
      exit 22
    fi
    ;;
  'GET /logs/EXECFAILURE1') emit "$FAKE_LOGS_FAILURE" ;;
  *) emit '{}' ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# seam <workdir> <command...>: run a seam script with the fake HTTP surface, a
# loopback endpoint, and the workdir's private operating home. FM_KESTRA_CONFIG
# points at a path that does not exist, so these runs exercise the environment path
# and never depend on an operator's local config.
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
    FM_HOME="$workdir/home" \
    FAKE_CURL_LOG="$workdir/curl.log" \
    FAKE_FLOW_DIR="$workdir/fake-flows" \
    FAKE_EXEC_SUCCESS="$EXEC_SUCCESS_JSON" \
    FAKE_EXEC_FAILURE="$EXEC_FAILURE_JSON" \
    FAKE_EXEC_REPLAY="$EXEC_REPLAY_JSON" \
    FAKE_EXEC_FOREIGN_NAMESPACE="$EXEC_FOREIGN_NAMESPACE_JSON" \
    FAKE_EXEC_UNTRACKED_FLOW="$EXEC_UNTRACKED_FLOW_JSON" \
    FAKE_EXEC_HISTORICAL="$EXEC_HISTORICAL_JSON" \
    FAKE_EXEC_MISSING_REVISION="$EXEC_MISSING_REVISION_JSON" \
    FAKE_EXEC_RUNNING="$EXEC_RUNNING_JSON" \
    FAKE_EXEC_UNREADABLE_REVISION="$EXEC_UNREADABLE_REVISION_JSON" \
    FAKE_LOGS_FAILURE="$LOGS_FAILURE_JSON" \
    FAKE_VALIDATE_RESPONSE="${SEAM_VALIDATE_RESPONSE:-$VALIDATION_OK_JSON}" \
    FAKE_BULK_RESPONSE="${SEAM_BULK_RESPONSE:-$BULK_OK_JSON}" \
    FAKE_EXEC_REVISION_OVERRIDE="${SEAM_EXEC_REVISION_OVERRIDE:-}" \
    FAKE_CURL_FAIL_MATCH="${SEAM_FAIL_MATCH:-}" \
    FAKE_CURL_FAIL_BODY="${SEAM_FAIL_BODY:-}" \
    FAKE_CURL_FAIL_CODE="${SEAM_FAIL_CODE:-22}" \
    FAKE_ARTIFACT_BINARY="${SEAM_ARTIFACT_BINARY:-0}" \
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
SEAM_BULK_RESPONSE=""
SEAM_EXEC_REVISION_OVERRIDE=""
SEAM_FAIL_MATCH=""
SEAM_FAIL_BODY=""
SEAM_FAIL_CODE=""
SEAM_ARTIFACT_BINARY=""
SEAM_PROXY=""

# workdir <name>: a fresh workdir whose fake server already "holds" the HEAD flows
# at revision 1 (m1_shape) and 2 (m1_controlled_failure) plus the historical
# revision 1 of the failure flow, and whose operating home already records those
# revisions against the HEAD blobs, as a completed deploy would have left it.
workdir() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/data/kestra" "$d/fake-flows"
  : > "$d/curl.log"
  git -C "$ROOT" show "HEAD:kestra/flows/m1_shape.yaml" > "$d/fake-flows/m1_shape@1.yaml"
  git -C "$ROOT" show "HEAD:kestra/flows/m1_controlled_failure.yaml" \
    > "$d/fake-flows/m1_controlled_failure@2.yaml"
  printf '%s\n' "$HISTORICAL_FAILURE_SOURCE" > "$d/fake-flows/m1_controlled_failure@1.yaml"
  printf 'm1_controlled_failure\t%s\t2\t%s\t%s\nm1_shape\t%s\t1\t%s\t%s\n' \
    "$NS" "$FAILURE_BLOB" "$HEAD_COMMIT" "$NS" "$SHAPE_BLOB" "$HEAD_COMMIT" \
    > "$d/home/data/kestra/revisions"
  printf '%s\n' "$d"
}

run_shape() {
  seam "$1" "$RUN" --flow m1_shape --input units=3 --input route=safe --input label=synthetic-alpha
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
    # The whole point: nothing was launched, not even the revision read-back.
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

test_input_validation_matches_the_supported_kestra_semantics() {
  local d file out rc
  d="$TMP_ROOT/input-semantics"
  mkdir -p "$d"
  file="$d/flow.yaml"
  printf '%s\n' 'id: semantics
namespace: firstmate.m1
labels:
  system.readOnly: true
inputs:
  - id: count
    type: INT
  - id: code
    type: STRING
    validator: ^(code|[0-9]+)$
  - id: route
    type: SELECT
    required: false
    values:
      - safe mode
      - fast
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "synthetic"' > "$file"

  rc=0
  out=$(bash -c '. "$1"; fm_kestra_check_flow "$2"; fm_kestra_validate_inputs "$2"' \
    _ "$ROOT/bin/fm-kestra-lib.sh" "$file" 2>&1) || rc=$?
  expect_code 2 "$rc" "an omitted required field must default to required"
  assert_contains "$out" "missing required input: count" \
    "the adapter must apply Kestra's required-by-default input semantics"

  rc=0
  out=$(bash -c '. "$1"; fm_kestra_check_flow "$2"; fm_kestra_validate_inputs "$2" count=2147483648 code=123' \
    _ "$ROOT/bin/fm-kestra-lib.sh" "$file" 2>&1) || rc=$?
  expect_code 2 "$rc" "an INT beyond Java Integer range must be refused"
  assert_contains "$out" "signed 32-bit INT range" "the refusal must name Kestra's INT range"

  rc=0
  out=$(bash -c '. "$1"; fm_kestra_check_flow "$2"; fm_kestra_validate_inputs "$2" count=1 code=x1' \
    _ "$ROOT/bin/fm-kestra-lib.sh" "$file" 2>&1) || rc=$?
  expect_code 2 "$rc" "a STRING validator must match the entire value"
  assert_contains "$out" 'must match ^(code|[0-9]+)$' "substring matches must not satisfy the validator"

  out=$(bash -c '. "$1"; fm_kestra_check_flow "$2"; fm_kestra_validate_inputs "$2" count=1 code=123 "route=safe mode"' \
    _ "$ROOT/bin/fm-kestra-lib.sh" "$file") \
    || fail "an exact block-list SELECT value containing a space must validate"
  assert_contains "$out" "route=safe mode" "SELECT values must preserve internal whitespace exactly"

  printf '%s\n' 'id: bounds
namespace: firstmate.m1
labels:
  system.readOnly: true
inputs:
  - id: count
    type: INT
    min: -2147483649
  - id: window
    type: INT
    min: 5
    max: 1
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "synthetic"' > "$file"
  rc=0
  out=$(bash -c '. "$1"; fm_kestra_check_flow "$2"' \
    _ "$ROOT/bin/fm-kestra-lib.sh" "$file" 2>&1) || rc=$?
  expect_code 1 "$rc" "an INT schema bound beyond Java Integer range must be refused"
  assert_contains "$out" "min/max outside the signed 32-bit range" \
    "schema bounds must fit the same type as submitted INT values"
  assert_contains "$out" "min greater than max" "an empty INT range must be refused at deploy time"
  pass "required defaults, INT range, full regex matches, and exact SELECT values mirror the supported semantics"
}

# ===========================================================================
# 2. An allowed execution returns an opaque execution ID, bound to the
#    recorded revision
# ===========================================================================

test_allowed_execution_returns_one_opaque_id_bound_to_the_recorded_revision() {
  local d out rc posts
  d=$(workdir allow-run)
  rc=0
  out=$(run_shape "$d" 2>&1) || rc=$?
  expect_code 0 "$rc" "an allow-listed flow with valid inputs must run: $out"
  [ "$out" = "EXECSUCCESS1" ] || fail "the run adapter must print only the execution id, got: $out"

  posts=$(grep -c "^POST " "$d/curl.log" || true)
  [ "$posts" -eq 1 ] || fail "exactly one execution must be created, saw $posts POSTs"
  assert_grep "POST http://127.0.0.1:18080/api/v1/main/executions/firstmate.m1/m1_shape?revision=1" \
    "$d/curl.log" "the execution must be created in the allow-listed namespace at the recorded revision"
  assert_grep "GET http://127.0.0.1:18080/api/v1/main/flows/firstmate.m1/m1_shape?revision=1&source=true" \
    "$d/curl.log" "the recorded revision must be read back before the execution is created"
  assert_grep "FORM units=3 route=safe label=synthetic-alpha" "$d/curl.log" \
    "validated inputs must be sent as literal form strings"
  pass "an allowed flow with valid inputs creates exactly one execution at its recorded revision and returns its opaque id"
}

test_run_refuses_without_a_verified_revision_record() {
  local d out rc
  d=$(workdir no-record)
  rm -f "$d/home/data/kestra/revisions"
  rc=0
  out=$(run_shape "$d" 2>&1) || rc=$?
  expect_code 2 "$rc" "a flow with no recorded deployed revision must not run"
  assert_contains "$out" "no recorded deployed revision" "the refusal must say deployment has not recorded the flow"
  [ ! -s "$d/curl.log" ] || fail "an unrecorded flow must be refused before any request"

  d=$(workdir stale-record)
  printf 'm1_shape\t%s\t1\t%s\t%s\n' "$NS" "0000000000000000000000000000000000000000" "$HEAD_COMMIT" \
    > "$d/home/data/kestra/revisions"
  rc=0
  out=$(run_shape "$d" 2>&1) || rc=$?
  expect_code 2 "$rc" "a record whose blob is not the current HEAD blob must not run"
  assert_contains "$out" "changed since its deployed revision" \
    "the refusal must say the reviewed flow changed since deployment"
  [ ! -s "$d/curl.log" ] || fail "a stale record must be refused before any request"

  d=$(workdir malformed-record)
  printf 'm1_shape\t%s\tlatest\t%s\t%s\n' "$NS" "$SHAPE_BLOB" "$HEAD_COMMIT" > "$d/home/data/kestra/revisions"
  rc=0
  out=$(run_shape "$d" 2>&1) || rc=$?
  expect_code 2 "$rc" "a malformed revision record must not run"
  assert_contains "$out" "malformed" "the refusal must name the malformed record"
  [ ! -s "$d/curl.log" ] || fail "a malformed record must be refused before any request"
  pass "a run is refused, before any request, when the deployed-revision record is absent, stale, or malformed"
}

test_run_refuses_when_the_server_revision_is_not_the_reviewed_source() {
  local d out rc
  d=$(workdir server-drift)
  printf '%s\n' 'id: m1_shape
namespace: firstmate.m1
labels:
  system.readOnly: "true"
tasks:
  - id: edited_on_server
    type: io.kestra.plugin.core.log.Log
    message: "not what Git reviewed"' > "$d/fake-flows/m1_shape@1.yaml"
  rc=0
  out=$(run_shape "$d" 2>&1) || rc=$?
  expect_code 2 "$rc" "a recorded revision whose server source differs from HEAD must not run"
  assert_contains "$out" "does not carry the reviewed source" \
    "the refusal must say the server revision is not the reviewed source"
  assert_no_grep "^POST " "$d/curl.log" "no execution may be created after a source mismatch"

  d=$(workdir server-gone)
  rm -f "$d/fake-flows/m1_shape@1.yaml"
  rc=0
  out=$(run_shape "$d" 2>&1) || rc=$?
  expect_code 1 "$rc" "a recorded revision the server cannot return must not run"
  assert_contains "$out" "could not read revision 1" "the failure must name the unreadable revision"
  assert_no_grep "^POST " "$d/curl.log" "no execution may be created when the revision cannot be read"
  pass "a run is refused when Kestra does not hold the reviewed source at the recorded revision"
}

test_run_reports_an_execution_created_at_the_wrong_revision_as_a_failure() {
  local d out rc
  d=$(workdir wrong-revision)
  rc=0
  out=$(SEAM_EXEC_REVISION_OVERRIDE=7 run_shape "$d" 2>&1) || rc=$?
  expect_code 1 "$rc" "an execution reporting another revision must be a failure, not a success"
  assert_contains "$out" "EXECSUCCESS1 reports flow revision 7, not the bound revision 1" \
    "the failure must name the execution and both revisions"
  pass "an execution whose recorded revision is not the bound one is reported as unverified evidence"
}

test_credential_never_reaches_argv_and_the_auth_file_is_private() {
  local d
  d=$(workdir credential)
  SEAM_PROXY=http://127.0.0.1:65535 run_shape "$d" >/dev/null 2>&1 \
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

test_credential_config_and_request_cleanup_are_private_per_process() {
  local child_record config d out rc stray
  d=$(workdir credential-files)
  config="$d/kestra.env"
  printf '%s\n' 'FM_KESTRA_BASE_URL=http://127.0.0.1:18080
FM_KESTRA_TENANT=main
FM_KESTRA_NAMESPACE=firstmate.m1
FM_KESTRA_USER=synthetic-operator
FM_KESTRA_PASSWORD=Synthetic-M1-Only' > "$config"
  chmod 0644 "$config"
  rc=0
  # shellcheck disable=SC2016 # The child shell owns its positional parameters.
  out=$(env -i PATH="$BASE_PATH" FM_KESTRA_CONFIG="$config" \
    bash -c '. "$1"; fm_kestra_load_config' _ "$ROOT/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "a group/world-readable credential config must be refused"
  assert_contains "$out" "must have mode 0600" "the config refusal must name the required mode"

  chmod 0600 "$config"
  ln -s "$config" "$d/kestra-link.env"
  rc=0
  # shellcheck disable=SC2016 # The child shell owns its positional parameters.
  out=$(env -i PATH="$BASE_PATH" FM_KESTRA_CONFIG="$d/kestra-link.env" \
    bash -c '. "$1"; fm_kestra_load_config' _ "$ROOT/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "a symlinked credential config must be refused"
  assert_contains "$out" "regular, non-symlink" "the config refusal must name the file-type boundary"

  child_record="$d/child-path"
  TMPDIR="$d" bash -c '
    . "$1"
    fm_kestra_tempfile parent parent_file
    (
      fm_kestra_tempfile auth child_file
      printf "%s\n" "$child_file" > "$2"
      sh -c "kill -TERM \"\$PPID\""
    ) || :
    [ -f "$parent_file" ] || exit 1
  ' _ "$ROOT/bin/fm-kestra-lib.sh" "$child_record" \
    || fail "an interrupted subshell must clean only its own request files"
  stray=$(find "$d" -maxdepth 1 -name '.fm-kestra-*' -print)
  [ -z "$stray" ] || fail "interrupted request credentials survived cleanup: $stray"
  pass "credential config and interrupted request files stay private and are cleaned per process"
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
  expect_code 0 "$rc" "reading a failed execution must succeed: $out"
  assert_contains "$out" "state: FAILED" "the terminal state must be reported"
  assert_contains "$out" "revision: 2" "the execution's recorded revision must be reported"
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
    assert_contains "$out" "task=always_fails attempt=$n level=ERROR synthetic controlled failure" \
      "the error log for attempt $n must reach the report with its attempt number"
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
  assert_not_contains "$out" "not-run: unavailable" \
    "a readable historical revision must yield real suppression evidence"
  assert_grep '/flows/firstmate.m1/m1_controlled_failure?revision=1&source=true' "$d/curl.log" \
    "suppression evidence must resolve the execution's recorded flowRevision"
  pass "not-run evidence comes from the exact flow revision that executed"
}

test_state_says_when_suppression_evidence_is_unavailable_and_still_reports_state() {
  local d out rc
  d=$(workdir missing-revision)
  rc=0
  out=$(seam "$d" "$STATUS" state EXECNOREVISION 2>&1) || rc=$?
  expect_code 0 "$rc" "state evidence without flowRevision must remain readable"
  assert_contains "$out" "not-run: unavailable: execution has no valid flowRevision" \
    "the adapter must explicitly omit suppression evidence it cannot make revision-accurate"

  d=$(workdir running-execution)
  rc=0
  out=$(seam "$d" "$STATUS" state EXECRUNNING1 2>&1) || rc=$?
  expect_code 0 "$rc" "a running execution's state must be readable"
  assert_contains "$out" "state: RUNNING" "the live state must be reported"
  assert_contains "$out" "not-run: unavailable: execution is not terminal (RUNNING)" \
    "tasks that have not started yet must not be called suppressed"
  assert_not_contains "$out" "not-run: always_fails" \
    "a non-terminal execution must produce no not-run lines"
  assert_no_grep "/flows/firstmate.m1/" "$d/curl.log" \
    "no revision read-back is needed when the evidence is unavailable on its face"

  d=$(workdir unreadable-revision)
  rc=0
  out=$(seam "$d" "$STATUS" state EXECGONEREV 2>&1) || rc=$?
  expect_code 0 "$rc" "an HTTP failure reading the revision must keep the state readable"
  assert_contains "$out" "state: FAILED" "the state must still be printed"
  assert_contains "$out" "not-run: unavailable: flow revision 9 could not be read from Kestra" \
    "an HTTP-level failure on the revision read must be reported as unavailable evidence"

  d=$(workdir revision-transport-failure)
  rc=0
  out=$(SEAM_FAIL_MATCH='?revision=2&source=true' SEAM_FAIL_CODE=7 SEAM_FAIL_BODY='connection refused' \
    seam "$d" "$STATUS" state EXECFAILURE1 2>&1) || rc=$?
  expect_code 1 "$rc" "a transport failure reading the revision must be an error, not unavailable evidence"
  assert_contains "$out" "connection refused" "the transport failure must keep its diagnostic"
  pass "missing, non-terminal, and unreadable revision evidence produces an explicit unavailable marker; transport failures stay errors"
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
    --state --set-state --secret --namespace --force --revision --latest
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
    fm_kestra_snapshot_flow_files
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
        "POST /flows/bulk?delete=false&namespace=firstmate.m1" \
        "POST /flows/firstmate.m1?delete=true" \
        "POST /flows/firstmate.m1?delete=false&extra=1" \
        "POST /flows/someone.else?delete=false" \
        "POST /flows/bulk?delete=true&namespace=firstmate.m1" \
        "POST /flows/bulk?delete=false&namespace=firstmate.m1&extra=1" \
        "POST /flows/bulk?delete=false&namespace=someone.else" \
        "POST /executions/firstmate.m1/m1_shape/eval" \
        "POST /executions/firstmate.m1/m1_shape" \
        "POST /executions/firstmate.m1/m1_shape?revision=" \
        "POST /executions/firstmate.m1/m1_shape?revision=latest" \
        "POST /executions/firstmate.m1/m1_shape?revision=0" \
        "POST /executions/firstmate.m1/m1_shape?revision=1&wait=true" \
        "POST /executions/firstmate.m1/m1_shape?wait=true&revision=1" \
        "POST /executions/firstmate.m1/not_reviewed?revision=1" \
        "GET /executions/webhook/firstmate.m1/m1_shape/key" \
        "GET /executions/EXECSUCCESS1/unknown" \
        "GET /logs/EXECFAILURE1/extra" \
        "GET /flows/firstmate.m1/m1_shape?source=true" \
        "GET /flows/firstmate.m1/m1_shape/revisions"
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
    fm_kestra_path_allowed deploy POST "/flows/firstmate.m1?delete=false" \
      || printf "DENIED deploy namespace\n"
    fm_kestra_path_allowed run POST "/executions/firstmate.m1/m1_shape?revision=1" \
      || printf "DENIED run execute at revision\n"
    fm_kestra_path_allowed read GET "/executions/EXECSUCCESS1" || printf "DENIED read execution\n"
    fm_kestra_path_allowed read GET "/logs/EXECFAILURE1" || printf "DENIED read logs\n"
    fm_kestra_path_allowed read GET "/executions/EXECSUCCESS1/file?path=kestra%3A%2F%2Fartifact" \
      || printf "DENIED read artifact\n"
    fm_kestra_path_allowed read GET "/flows/firstmate.m1/m1_shape?revision=1&source=true" \
      || printf "DENIED read flow revision\n"
  ' _ "$ROOT" 2>&1) || rc=$?
  [ -z "$out" ] || fail "HTTP gate role matrix is wrong:"$'\n'"$out"
  pass "the HTTP gate admits only the exact deploy, revision-bound run, execution, log, artifact, and revision paths"
}

test_the_http_gate_accepts_no_raw_curl_options_or_caller_bodies() {
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
        [ "$role" != run ] || fm_kestra_snapshot_flow_files
        case "$4" in
          request) set -- -X DELETE ;;
          url) set -- --url http://example.invalid/ ;;
          proxy) set -- --proxy http://127.0.0.1:65535 ;;
          config) set -- -K "$body" ;;
        esac
        case "$role" in
          deploy) fm_kestra_request deploy POST /flows/validate "$body" "$@" ;;
          run) fm_kestra_request run POST "/executions/firstmate.m1/m1_shape?revision=1" safe=value "$@" ;;
          read) fm_kestra_request read GET /executions/EXECSUCCESS1 "$@" ;;
        esac
      ' _ "$ROOT" "$role" "$body" "$attack" 2>&1) || rc=$?
      expect_code 2 "$rc" "$role must refuse raw curl option injection through $attack"
      assert_contains "$out" "refused:" "$role must identify the structured request refusal"
      [ ! -s "$d/curl.log" ] \
        || fail "$role launched curl after a raw option injection attempt through $attack"
    done
  done
  pass "deploy, run, and read construct requests only from role-specific structured values, and deploy takes no caller body"
}

test_a_run_may_not_target_another_namespace() {
  local out
  out=$(FM_KESTRA_NAMESPACE=firstmate.m1 bash -c '
    . "$1/bin/fm-kestra-lib.sh"
    fm_kestra_path_allowed run POST "/executions/other.namespace/m1_shape?revision=1" \
      && printf "ALLOWED other namespace\n"
    exit 0
  ' _ "$ROOT" 2>&1)
  [ -z "$out" ] || fail "the run role must not reach a namespace outside the allow-list"
  pass "the run role can only launch executions inside the one allow-listed namespace"
}

test_forbidden_api_words_are_matched_as_segments() {
  local out
  out=$(bash -c '
    . "$1/bin/fm-kestra-lib.sh"
    for path in \
      /executions/firstmate.m1/state-audit \
      /executions/firstmate.m1/restart-check \
      /executions/firstmate.m1/replay-analysis
    do
      fm_kestra_path_has_forbidden_segment "$path" && printf "FALSE POSITIVE %s\n" "$path"
    done
    for path in \
      /executions/EXECSUCCESS1/state \
      /executions/EXECSUCCESS1/replay \
      /namespaces/firstmate.m1
    do
      fm_kestra_path_has_forbidden_segment "$path" || printf "MISSED %s\n" "$path"
    done
  ' _ "$ROOT")
  [ -z "$out" ] || fail "forbidden API path-segment matching is wrong:"$'\n'"$out"
  pass "the HTTP deny-list matches exact path segments without rejecting safe identifiers"
}

# ===========================================================================
# 7. Deployment authority and the revision record
# ===========================================================================

test_check_mode_accepts_the_tracked_flows_without_config_or_network() {
  local d out rc
  d=$(workdir deploy-check)
  rc=0
  out=$(env -i PATH="$BASE_PATH" HOME="$d" "$DEPLOY" --check 2>&1) || rc=$?
  expect_code 0 "$rc" "the tracked flows must pass static validation: $out"
  assert_contains "$out" "$NS/m1_shape" "the shape flow must validate"
  assert_contains "$out" "$NS/m1_controlled_failure" "the controlled-failure flow must validate"
  pass "deploy --check validates the tracked flows with no config, no credential, and no network"
}

# fixture_flow <dir> <name> <body>: write a throwaway flow source.
fixture_flow() {
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/$2.yaml"
}

# check_fixture <dir>: run deploy --check against a throwaway Git repo holding the
# fixture flow, because the seam only reads flows from a committed HEAD.
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

# refused_fixture <name> <needle> <body>: the fixture must be refused with <needle>.
refused_fixture() {
  local name=$1 needle=$2 body=$3 d out rc=0
  d="$TMP_ROOT/fixture-$name"
  fixture_flow "$d" "$name" "$body"
  out=$(check_fixture "$d") || rc=$?
  expect_code 2 "$rc" "$name must be refused instead of approximately parsed"
  assert_contains "$out" "$needle" "$name must name the boundary it crosses"
}

MINIMAL_HEAD='labels:
  system.readOnly: "true"
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "synthetic"'

test_flow_discovery_uses_only_canonical_unchanged_git_sources() {
  local d out rc
  d="$TMP_ROOT/tracked-flow-root"
  mkdir -p "$d/bin" "$d/kestra/flows" "$d/ignored"
  cp "$ROOT/bin/fm-kestra-lib.sh" "$d/bin/fm-kestra-lib.sh"
  fixture_flow "$d/kestra/flows" tracked "id: tracked
namespace: firstmate.m1
$MINIMAL_HEAD"
  git -C "$d" init -q
  git -C "$d" add bin/fm-kestra-lib.sh kestra/flows/tracked.yaml
  git -C "$d" -c user.name=Test -c user.email=test@example.invalid commit -qm initial

  out=$(FM_KESTRA_FLOWS_DIR="$d/ignored" bash -c '. "$1"; fm_kestra_flows_dir' \
    _ "$ROOT/bin/fm-kestra-lib.sh")
  [ "$out" = "$FLOWS" ] || fail "FM_KESTRA_FLOWS_DIR changed the production flow root: $out"

  fixture_flow "$d/kestra/flows" untracked 'id: untracked'
  rc=0
  out=$(bash -c '. "$1"; fm_kestra_snapshot_flow_files' _ "$d/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "an untracked YAML flow must stop discovery"
  assert_contains "$out" "untracked flow sources" "the refusal must name the untracked source"
  rm -f "$d/kestra/flows/untracked.yaml"

  printf '\n# local edit\n' >> "$d/kestra/flows/tracked.yaml"
  rc=0
  out=$(bash -c '. "$1"; fm_kestra_snapshot_flow_files' _ "$d/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
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
    message: "reviewed"'
  git -C "$d" init -q
  git -C "$d" add bin/fm-kestra-lib.sh kestra/flows/tracked.yaml
  git -C "$d" -c user.name=Test -c user.email=test@example.invalid commit -qm initial

  out=$(TMPDIR="$d" bash -c '
    . "$1/bin/fm-kestra-lib.sh"
    fm_kestra_snapshot_flow_files
    [ "${#FM_KESTRA_SNAPSHOT_FILES[@]}" -eq 1 ] || exit 1
    printf "message: changed\n" > "$1/kestra/flows/tracked.yaml"
    resolved=""
    blob=""
    fm_kestra_resolve_flow reviewed resolved blob
    [ "$resolved" = "${FM_KESTRA_SNAPSHOT_FILES[0]}" ] || exit 1
    [ "$blob" = "$(git -C "$1" rev-parse HEAD:kestra/flows/tracked.yaml)" ] || exit 1
    cat "$resolved"
  ' _ "$d") || fail "the HEAD flow snapshot must remain readable after the worktree source changes"
  assert_contains "$out" 'message: "reviewed"' "the snapshot must contain the reviewed HEAD bytes"
  assert_not_contains "$out" "message: changed" "the snapshot must not re-read the mutable worktree source"
  pass "flow resolution and validation remain bound to one immutable HEAD snapshot with its blob identity"
}

test_deploy_refuses_a_flow_without_the_read_only_label() {
  refused_fixture mutable 'missing label system.readOnly' 'id: mutable
namespace: firstmate.m1

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "hello"'
  refused_fixture inexact 'labels must contain only system.readOnly' 'id: inexact
namespace: firstmate.m1

labels:
  system.readOnly: "untrue"

tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "hello"'
  pass "the deployer refuses a flow that the Kestra UI editor could still change"
}

test_deploy_refuses_pebble_templating_everywhere() {
  refused_fixture pebble-message 'Pebble templating is not permitted' "id: pebble_message
namespace: firstmate.m1
labels:
  system.readOnly: \"true\"
inputs:
  - id: label
    type: STRING
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: \"hello {{ inputs.label }}\""
  refused_fixture pebble-secret 'Pebble templating is not permitted' "id: pebble_secret
namespace: firstmate.m1
labels:
  system.readOnly: \"true\"
tasks:
  - id: only
    type: io.kestra.plugin.core.debug.Return
    format: \"{{ secret(KEY) }}\""
  refused_fixture pebble-condition 'Pebble templating is not permitted' "id: pebble_condition
namespace: firstmate.m1
labels:
  system.readOnly: \"true\"
tasks:
  - id: branch
    type: io.kestra.plugin.core.flow.If
    condition: \"{{ true }}\"
    then:
      - id: yes_task
        type: io.kestra.plugin.core.log.Log
        message: \"yes\"
    else:
      - id: no_task
        type: io.kestra.plugin.core.log.Log
        message: \"no\""
  refused_fixture pebble-content 'Pebble templating is not permitted' "id: pebble_content
namespace: firstmate.m1
labels:
  system.readOnly: \"true\"
tasks:
  - id: file
    type: io.kestra.plugin.core.storage.Write
    extension: .txt
    content: |
      {% for x in outputs %}{{ x }}{% endfor %}"
  refused_fixture pebble-comment-tag 'Pebble templating is not permitted' "id: pebble_tag
namespace: firstmate.m1
labels:
  system.readOnly: \"true\"
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: \"{# hidden #}\""
  pass "no Pebble expression, tag, or comment is accepted in any task field or content block"
}

test_deploy_refuses_task_types_outside_the_m1_safe_allow_list() {
  refused_fixture plugged 'outside the core-plugin allow-list' 'id: plugged
namespace: firstmate.m1
labels:
  system.readOnly: "true"
tasks:
  - id: shell
    type: io.kestra.plugin.scripts.shell.Commands
    commands:
      - echo hi'
  local type
  for type in io.kestra.plugin.core.http.Request io.kestra.plugin.core.execution.PurgeExecutions \
    io.kestra.plugin.core.flow.Switch io.kestra.plugin.core.flow.Dag io.kestra.plugin.core.flow.Subflow
  do
    refused_fixture "task-${type##*.}" "outside the core-plugin allow-list for M1-safe tasks: $type" "id: side_effect
namespace: firstmate.m1
labels:
  system.readOnly: \"true\"
tasks:
  - id: unsafe
    type: $type"
  done
  pass "the deployer refuses shell, script, side-effecting, and unsupported flowable task types by exact allow-list"
}

test_deploy_refuses_task_maps_in_any_order_or_indentation_it_cannot_own() {
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
  assert_contains "$out" "unsupported task key: commands" \
    "an unknown task key must be refused by name"

  refused_fixture inline-type 'task list item must begin with id' 'id: inline
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - type: io.kestra.plugin.scripts.shell.Commands
    id: shell'

  refused_fixture wide-indent 'not indented two spaces under a supported' 'id: wide
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
    - id: shell
      type: io.kestra.plugin.scripts.shell.Commands'
  pass "every task map is parsed by one grammar; unknown keys, misordered items, and unexpected indentation fail closed"
}

test_deploy_refuses_every_container_outside_tasks_then_and_else() {
  refused_fixture task-errors 'unsupported task key: errors' 'id: task_errors
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: sequential
    type: io.kestra.plugin.core.flow.Sequential
    tasks:
      - id: inner
        type: io.kestra.plugin.core.log.Log
        message: "inner"
    errors:
      - id: handler
        type: io.kestra.plugin.core.log.Log
        message: "handler"'
  local key
  for key in errors finally afterExecution listeners outputs variables taskDefaults; do
    refused_fixture "top-$key" "unsupported top-level key: $key" "id: top_$key
namespace: firstmate.m1
$MINIMAL_HEAD
$key:
  - id: extra
    type: io.kestra.plugin.core.log.Log
    message: \"extra\""
  done
  refused_fixture empty-then 'container branch.then declares no tasks' 'id: empty_then
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: branch
    type: io.kestra.plugin.core.flow.If
    condition: "true"
    then:
    else:
      - id: no_task
        type: io.kestra.plugin.core.log.Log
        message: "no"'
  pass "only tasks, then, and else containers exist; every other Kestra container is refused by name"
}

test_deploy_accepts_only_the_exact_supported_yaml_shape() {
  refused_fixture inline-tasks 'flow-style mappings and sequences' 'id: inline_tasks
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks: [{id: only, type: io.kestra.plugin.core.log.Log, message: synthetic}]'
  refused_fixture inline-inputs 'flow-style mappings and sequences' "id: inline_inputs
namespace: firstmate.m1
inputs: [{id: value, type: STRING}]
$MINIMAL_HEAD"
  refused_fixture anchor 'anchors, aliases, and merge keys' 'id: anchor
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: only
    type: &task_type io.kestra.plugin.core.log.Log
    message: "synthetic"'
  refused_fixture quoted-id 'top-level id must be an unquoted' "id: \"quoted\"
namespace: firstmate.m1
$MINIMAL_HEAD"
  refused_fixture block-message 'must be a double-quoted literal' 'id: block
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: |
      synthetic'
  refused_fixture plain-message 'must be a double-quoted literal' 'id: plain
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: synthetic'
  refused_fixture single-quoted 'single-quoted scalars are not supported' "id: single
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: 'synthetic'"
  refused_fixture inline-comment 'inline comments are not supported' 'id: commented
namespace: firstmate.m1
labels:
  system.readOnly: true
inputs:
  - id: count
    type: INT
    required: false # optional
tasks:
  - id: only
    type: io.kestra.plugin.core.log.Log
    message: "synthetic"'
  refused_fixture unknown-top 'unsupported top-level key: description' "id: unknown
namespace: firstmate.m1
description: unsupported
$MINIMAL_HEAD"
  refused_fixture tabbed 'tabs are not supported' "id: tabbed
namespace: firstmate.m1
labels:
  system.readOnly: true
tasks:
	- id: only
	  type: io.kestra.plugin.core.log.Log
	  message: \"synthetic\""
  pass "deployment refuses every YAML form outside the exact supported M1 static-flow shape"
}

test_deploy_refuses_triggers() {
  refused_fixture trigger 'triggers are refused because executions must start through the run adapter' "id: trigger
namespace: firstmate.m1
triggers:
  - id: schedule
    type: io.kestra.plugin.core.trigger.Schedule
    cron: \"0 * * * *\"
$MINIMAL_HEAD"
  pass "deployment refuses autonomous triggers by name"
}

test_deploy_refuses_an_input_schema_it_cannot_pre_check() {
  refused_fixture exotic-input 'unsupported input type: JSON' "id: exotic
namespace: firstmate.m1
inputs:
  - id: payload
    type: JSON
    required: true
$MINIMAL_HEAD"
  refused_fixture input-defaults 'unsupported input key: defaults' "id: defaulted
namespace: firstmate.m1
inputs:
  - id: count
    type: INT
    defaults: 3
$MINIMAL_HEAD"
  refused_fixture mismatched-keys 'declares min/max but is not INT' "id: mismatched
namespace: firstmate.m1
inputs:
  - id: name
    type: STRING
    min: 1
$MINIMAL_HEAD"
  refused_fixture boolean-select 'SELECT values must be plain word scalars' "id: boolean_select
namespace: firstmate.m1
inputs:
  - id: flag
    type: SELECT
    values:
      - yes
      - no
$MINIMAL_HEAD"
  pass "the deployer refuses any input schema the run adapter could not validate exactly"
}

test_deploy_accepts_only_the_ere_java_common_validator_subset() {
  local pattern
  for pattern in '^\d+$' '^(?i)abc$' '^[^a-z]+$' '^\Qlit\E$' 'abc' '^a**$' '^(|a)$' '^a{x}$' '^[a-z]{2$'; do
    refused_fixture "validator-$(printf '%s' "$pattern" | tr -c 'A-Za-z0-9' _)" \
      'outside the ERE/Java-common regex subset' "id: validator
namespace: firstmate.m1
inputs:
  - id: code
    type: STRING
    validator: $pattern
$MINIMAL_HEAD"
  done
  local d out rc
  d="$TMP_ROOT/validator-accepted"
  fixture_flow "$d" accepted "id: accepted
namespace: firstmate.m1
inputs:
  - id: code
    type: STRING
    validator: ^(code|[a-z0-9_-]{2,8})(-v[0-9]+)?$
$MINIMAL_HEAD"
  rc=0
  out=$(check_fixture "$d") || rc=$?
  expect_code 0 "$rc" "a validator inside the common subset must be accepted: $out"
  pass "validators are accepted only from the explicit grammar both POSIX ERE and Java read identically"
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

test_deploy_never_enables_deletion_and_records_verified_revisions() {
  local file d out rc record
  d=$(workdir deploy-run)
  rm -f "$d/home/data/kestra/revisions"
  rc=0
  out=$(seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 0 "$rc" "deploying the tracked flows must succeed against the fake server: $out"
  assert_grep "flows/$NS?delete=false" "$d/curl.log" \
    "the namespace update must disable deletion"
  assert_grep "POST http://127.0.0.1:18080/api/v1/main/flows/validate" "$d/curl.log" \
    "flows must be validated server-side before the update"
  for file in 0 1; do
    cmp -s "$d/fake-flows/uploads/validate/$file.yaml" "$d/fake-flows/uploads/$NS/$file.yaml" \
      || fail "server validation and deployment must send the same separate HEAD files"
  done
  assert_absent "$d/fake-flows/uploads/$NS/body" "deployment must not concatenate flow sources"
  assert_absent "$d/fake-flows/uploads/$NS/2.yaml" "deployment must upload exactly the tracked files"
  assert_no_grep "delete=true" "$d/curl.log" "deletion must never be enabled"
  # Kestra must never be handed Git reconciliation; the seam pushes instead.
  assert_no_grep "/git" "$d/curl.log" "the deployer must never ask Kestra to reconcile Git"
  assert_grep "GET http://127.0.0.1:18080/api/v1/main/flows/firstmate.m1/m1_shape?revision=1&source=true" \
    "$d/curl.log" "each deployed flow must be read back at the reported revision"
  assert_grep "GET http://127.0.0.1:18080/api/v1/main/flows/firstmate.m1/m1_controlled_failure?revision=2&source=true" \
    "$d/curl.log" "each deployed flow must be read back at the reported revision"
  assert_contains "$out" "deployed: $NS/m1_shape revision 1" "the deploy must report the recorded revision"
  record=$(cat "$d/home/data/kestra/revisions")
  assert_contains "$record" "m1_shape	$NS	1	$SHAPE_BLOB	$HEAD_COMMIT" \
    "the record must bind the shape flow's revision to its HEAD blob"
  assert_contains "$record" "m1_controlled_failure	$NS	2	$FAILURE_BLOB	$HEAD_COMMIT" \
    "the record must bind the failure flow's revision to its HEAD blob"
  pass "the deployer validates first, updates with deletion disabled, verifies each revision's source, and records it"
}

test_deploy_records_nothing_when_a_revision_cannot_be_verified() {
  local d out rc
  d=$(workdir deploy-unverified)
  rm -f "$d/home/data/kestra/revisions"
  rc=0
  out=$(SEAM_BULK_RESPONSE='[{"id":"m1_shape","namespace":"firstmate.m1"},{"id":"m1_controlled_failure","namespace":"firstmate.m1","revision":2}]' \
    seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 1 "$rc" "an update response without a revision must fail deployment"
  assert_contains "$out" "reported no revision for flow $NS/m1_shape" \
    "the failure must name the flow whose revision is unknown"
  assert_absent "$d/home/data/kestra/revisions" "no record may be written when a revision is unknown"

  d=$(workdir deploy-drift)
  rm -f "$d/home/data/kestra/revisions"
  printf 'id: m1_shape\nnamespace: firstmate.m1\nlabels:\n  system.readOnly: "true"\ntasks:\n  - id: other\n    type: io.kestra.plugin.core.log.Log\n    message: "other"\n' \
    > "$d/fake-flows/m1_shape@1.yaml"
  rc=0
  out=$(seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 2 "$rc" "a read-back that is not the reviewed source must fail deployment"
  assert_contains "$out" "does not carry the reviewed source" \
    "the refusal must say the server revision is not what Git reviewed"
  assert_absent "$d/home/data/kestra/revisions" "no record may be written after a source mismatch"
  assert_not_contains "$out" "deployed:" "an unverified deployment must never be reported as deployed"
  pass "the revision record is written only after every deployed revision is verified against HEAD"
}

test_deploy_requires_every_server_validation_result_to_pass() {
  local d out rc
  d=$(workdir deploy-mixed-validation)
  rc=0
  out=$(SEAM_VALIDATE_RESPONSE='[{"constraints":null},{"constraints":"invalid flow"}]' \
    seam "$d" "$DEPLOY" 2>&1) || rc=$?
  expect_code 1 "$rc" "one valid response object must not mask a rejected flow"
  assert_contains "$out" "invalid flow" "the rejected validation response must remain visible"
  assert_no_grep "/flows/$NS?delete=false" "$d/curl.log" \
    "the deployer must not update the namespace after any validation rejection"
  pass "server validation succeeds only when every expected flow result passes"
}

test_http_failures_are_failures_and_keep_the_response_diagnostic() {
  local d out rc
  d=$(workdir deploy-http-failure)
  rc=0
  out=$(SEAM_FAIL_MATCH="/flows/$NS?delete=false" SEAM_FAIL_BODY='bulk update rejected' \
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
  out=$(SEAM_BASE_URL=https://kestra.example.com run_shape "$d" 2>&1) || rc=$?
  expect_code 2 "$rc" "a non-loopback endpoint must be refused"
  assert_contains "$out" "must be loopback" "the refusal must name the loopback rule"
  [ ! -s "$d/curl.log" ] || fail "a non-loopback endpoint must be refused before any request"

  rc=0
  out=$(SEAM_BASE_URL='http://user:pass@127.0.0.1:18080' run_shape "$d" 2>&1) || rc=$?
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
  expect_code 0 "$rc" "an artifact a task declared must be readable"
  assert_contains "$out" "kind=synthetic" "the declared artifact's bytes must be returned"

  rc=0
  out=$(seam "$d" "$STATUS" artifact EXECSUCCESS1 'kestra:///somewhere/else/secret.txt' 2>&1) || rc=$?
  expect_code 2 "$rc" "an undeclared artifact URI must be refused"
  assert_contains "$out" "not declared as an output" "the refusal must say the URI was never declared"
  assert_no_grep "somewhere/else" "$d/curl.log" "an undeclared artifact must never be fetched"
  pass "only artifacts a task declared as outputs are readable; anything else is refused"
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

test_artifact_streaming_preserves_binary_bytes_and_trailing_newlines() {
  local d expected rc target uri
  d=$(workdir artifact-binary)
  uri='kestra:///firstmate/m1/m1-shape/executions/EXECSUCCESS1/tasks/artifact/AAA/1.txt'
  expected="$d/expected.bin"
  target="$d/actual.bin"
  printf 'binary\000artifact\n\n' > "$expected"
  rc=0
  SEAM_ARTIFACT_BINARY=1 seam "$d" "$STATUS" artifact EXECSUCCESS1 "$uri" --out "$target" \
    >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a binary artifact download must succeed"
  cmp -s "$expected" "$target" \
    || fail "artifact staging changed NUL bytes or trailing newlines"

  target="$d/stdout.bin"
  rc=0
  SEAM_ARTIFACT_BINARY=1 seam "$d" "$STATUS" artifact EXECSUCCESS1 "$uri" \
    > "$target" 2>/dev/null || rc=$?
  expect_code 0 "$rc" "a binary artifact written to stdout must succeed"
  cmp -s "$expected" "$target" \
    || fail "artifact stdout changed NUL bytes or trailing newlines"
  pass "artifact reads stream through files without command-substitution corruption"
}

test_task_outputs_and_branch_evidence_are_reported() {
  local d out rc
  d=$(workdir outputs)
  rc=0
  out=$(seam "$d" "$STATUS" outputs EXECSUCCESS1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading task outputs must succeed"
  assert_contains "$out" "output: finish.value=finished static shape" \
    "a Return task's declared value must be reported"
  assert_contains "$out" "output: artifact.uri=kestra:///firstmate/m1/m1-shape/executions/EXECSUCCESS1/tasks/artifact/AAA/1.txt" \
    "a Write task's declared artifact URI must be reported"

  rc=0
  out=$(seam "$d" "$STATUS" state EXECSUCCESS1 2>&1) || rc=$?
  expect_code 0 "$rc" "reading the successful execution must succeed"
  assert_contains "$out" "not-run: fast_branch" \
    "the branch arm that never ran must be reported as not-run from the executed revision"
  assert_not_contains "$out" "not-run: safe_branch" "the branch arm that ran must not be called suppressed"
  pass "the status adapter reports task outputs and the untaken branch arm as evidence"
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

test_every_tracked_flow_is_static_read_only_and_m1_safe() {
  local file records
  for file in "$FLOWS"/*.yaml; do
    assert_grep 'system.readOnly: "true"' "$file" "$file must carry the read-only label"
    assert_grep "namespace: $NS" "$file" "$file must declare the allow-listed namespace"
    assert_no_grep '{{' "$file" "$file must carry no Pebble expression"
    assert_no_grep '{%' "$file" "$file must carry no Pebble tag"
    records=$(bash -c '. "$1/bin/fm-kestra-lib.sh"; fm_kestra_parse_flow "$2"' _ "$ROOT" "$file" 2>&1) \
      || fail "$file does not pass the M1 static-flow grammar: $records"
  done
  assert_grep 'type: io.kestra.plugin.core.flow.Sequential' "$FLOWS/m1_shape.yaml" "the shape flow must exercise a sequential group"
  assert_grep 'type: io.kestra.plugin.core.flow.Parallel' "$FLOWS/m1_shape.yaml" "the shape flow must exercise a parallel group"
  assert_grep 'type: io.kestra.plugin.core.flow.If' "$FLOWS/m1_shape.yaml" "the shape flow must exercise a branch"
  assert_grep 'type: io.kestra.plugin.core.storage.Write' "$FLOWS/m1_shape.yaml" "the shape flow must write an artifact"
  pass "every tracked flow is static, read-only-labelled, M1-safe, in the allow-listed namespace, and exercises the required shapes"
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
  [ "$(grep -c 'de846ac42e2b35a2e55301d01335de6ea30eab77fd69570f238e06ea28149a4b' "$ROOT/bin/fm-kestra-lib.sh")" -eq 1 ] \
    || fail "the checksum literal must appear exactly once in the library, in its owning function"
  pass "the Kestra version and asset checksum are pinned in code once, with no floating tag"
}

test_kestra_contracts_have_one_documentation_owner() {
  assert_grep "never inherited or propagated to a secondmate home" "$ROOT/docs/configuration.md" \
    "configuration docs must keep Kestra credentials home-local"
  assert_grep "data/kestra/revisions" "$ROOT/docs/configuration.md" \
    "configuration docs must place the deployed-revision record"
  assert_grep "replay lineage" "$ROOT/docs/scripts.md" \
    "the script inventory must list every status evidence mode"
  assert_no_grep "de846ac42e2b35a2e55301d01335de6ea30eab77fd69570f238e06ea28149a4b" \
    "$ROOT/docs/kestra-seam.md" "the rationale page must not duplicate the pinned checksum"
  assert_no_grep "1.3.34" "$ROOT/docs/kestra-seam.md" \
    "the rationale page must not duplicate the pinned version literal"
  assert_no_grep "GET /executions/" "$ROOT/docs/kestra-seam.md" \
    "the rationale page must not duplicate the request matrix"
  assert_grep "Static flows only" "$ROOT/docs/kestra-seam.md" \
    "the rationale page must record the static-flow narrowing"
  pass "Kestra mechanics stay with script and configuration owners while rationale stays in the seam guide"
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
# pinned Kestra OSS server on loopback with the tracked flows deployed through
# bin/fm-kestra-deploy.sh (so the revision record exists), and it runs only when
# FM_KESTRA_LIVE=1 is set explicitly.

test_live_engine_behaviour() {
  if [ "${FM_KESTRA_LIVE:-0}" != "1" ]; then
    pass "SKIP live engine check (set FM_KESTRA_LIVE=1 with a real loopback pinned Kestra and deployed flows to run it)"
    return 0
  fi
  local id out
  id=$("$RUN" --flow m1_controlled_failure) || fail "live: could not launch the controlled-failure flow"
  # The flow retries with a 0.5s interval; poll rather than sleeping a fixed guess.
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
  pass "live: Kestra made three attempts, showed the retry transitions, suppressed the following task, and returned the reviewed source at the bound revision"
}

test_deploy_preserves_literal_document_separators() {
  local d out rc=0
  d=$(workdir literal-separators)
  fixture_flow "$d" literal 'id: m1_shape
namespace: firstmate.m1
labels:
  system.readOnly: "true"
tasks:
  - id: artifact
    type: io.kestra.plugin.core.storage.Write
    extension: .txt
    content: |
      literal---text
      ---
      id: injected
      namespace: firstmate.m1
      tasks:
        - id: forbidden
          type: io.kestra.plugin.scripts.shell.Commands
          commands:
            - echo unsafe'
  check_fixture "$d" >/dev/null || fail "document separators inside literal content must remain supported"
  cp "$d/literal.yaml" "$d/fake-flows/m1_shape@1.yaml"
  out=$(SEAM_VALIDATE_RESPONSE='[{"constraints":null}]' seam "$d" "$d/repo/bin/fm-kestra-deploy.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "literal separators must deploy as one flow: $out"
  cmp -s "$d/literal.yaml" "$d/fake-flows/uploads/validate/0.yaml" \
    || fail "validation must receive the original flow as a separate uploaded file"
  cmp -s "$d/literal.yaml" "$d/fake-flows/uploads/firstmate.m1/0.yaml" \
    || fail "deployment must receive the same separate file, including literal separators"
  assert_absent "$d/fake-flows/uploads/firstmate.m1/1.yaml" "literal YAML must not become another uploaded flow"
  assert_no_grep '/flows/bulk' "$d/curl.log" "deployment must not use the delimiter-splitting endpoint"
  pass "literal document separators remain artifact content in validation and deployment"
}

test_request_urls_cannot_escape_the_role_path() {
  local d suffix out rc
  d=$(workdir unsafe-base-url)
  for suffix in '/api/v1/main/flows/bulk?delete=true&namespace=firstmate.m1#' \
    '/?delete=true' '/#fragment' '/%2e%2e' '/..' '/.' '/prefix/../other' '/{one,two}' '/bad path' '/bad\path'; do
    rc=0
    out=$(SEAM_BASE_URL="http://127.0.0.1:18080$suffix" seam "$d" "$DEPLOY" 2>&1) || rc=$?
    expect_code 2 "$rc" "unsafe base URL $suffix must be refused: $out"
    [ ! -s "$d/curl.log" ] || fail "unsafe base URLs must be refused before curl"
  done
  for suffix in 'http://127.0.0.1:18080' 'https://localhost:443/prefix' 'http://[::1]:18080'; do
    seam "$d" bash -c ". \"\$1\"; fm_kestra_assert_loopback \"\$2\"" _ "$ROOT/bin/fm-kestra-lib.sh" "$suffix" \
      || fail "a valid loopback base must remain supported: $suffix"
  done
  rc=0
  out=$(seam "$d" bash -c "
    . \"\$1\"
    fm_kestra_load_config
    FM_KESTRA_BASE_URL='http://127.0.0.1:18080/api/v1/main/flows/bulk?delete=true#'
    fm_kestra_request read GET /executions/EXECSUCCESS1
  " _ "$ROOT/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "the transport must revalidate the configured URL before sending: $out"
  [ ! -s "$d/curl.log" ] || fail "a changed unsafe base URL must never reach curl"
  rc=0
  out=$(seam "$d" bash -c "
    . \"\$1\"
    fm_kestra_load_config
    FM_KESTRA_NAMESPACE=..
    fm_kestra_request read GET '/flows/../m1_shape?revision=1&source=true'
  " _ "$ROOT/bin/fm-kestra-lib.sh" 2>&1) || rc=$?
  expect_code 2 "$rc" "dot segments in the assembled request path must be refused: $out"
  [ ! -s "$d/curl.log" ] || fail "a request whose assembled path changes meaning must never reach curl"
  pass "base URLs and assembled request paths cannot override the allowed HTTP operation"
}

test_revision_verification_preserves_literal_whitespace() {
  local d out rc mutation
  for mutation in trailing-space blank-indent; do
    d=$(workdir "literal-whitespace-$mutation")
    awk -v mutation="$mutation" '
      /kind=synthetic/ {
        if (mutation == "trailing-space") { print $0 " "; next }
        print; print "       "; next
      }
      { print }
    ' "$d/fake-flows/m1_shape@1.yaml" > "$d/changed.yaml"
    mv "$d/changed.yaml" "$d/fake-flows/m1_shape@1.yaml"
    rc=0
    out=$(run_shape "$d" 2>&1) || rc=$?
    expect_code 2 "$rc" "artifact whitespace drift must refuse execution: $out"
    assert_contains "$out" 'does not carry the reviewed source' "whitespace drift must be a source mismatch"
    assert_no_grep 'POST ' "$d/curl.log" "whitespace drift must not create an execution"
    rm -f "$d/home/data/kestra/revisions"
    rc=0
    out=$(seam "$d" "$DEPLOY" 2>&1) || rc=$?
    expect_code 2 "$rc" "artifact whitespace drift must refuse deployment verification: $out"
    assert_absent "$d/home/data/kestra/revisions" "whitespace drift must not record a verified revision"
  done
  d=$(workdir source-padding)
  { printf '\n'; cat "$d/fake-flows/m1_shape@1.yaml"; printf '\n'; } > "$d/padded.yaml"
  mv "$d/padded.yaml" "$d/fake-flows/m1_shape@1.yaml"
  run_shape "$d" >/dev/null || fail "empty transport padding outside content must remain harmless"
  pass "revision verification preserves literal whitespace while allowing empty transport padding"
}

test_string_validators_use_character_semantics() {
  local d example pattern value expected out rc
  d=$(workdir unicode-validator)
  for example in accent-one accent-two emoji-one emoji-two mixed ascii-range unicode-range nel ls ps empty; do
    case "$example" in
      accent-one) pattern='^.$'; value='é'; expected=0 ;;
      accent-two) pattern='^..$'; value='é'; expected=2 ;;
      emoji-one) pattern='^.$'; value='😀'; expected=0 ;;
      emoji-two) pattern='^..$'; value='😀'; expected=2 ;;
      mixed) pattern='^a.b$'; value='aéb'; expected=0 ;;
      ascii-range) pattern='^[A-Z][a-z]+$'; value='Abc'; expected=0 ;;
      unicode-range) pattern='^[A-Z][a-z]+$'; value='Abé'; expected=2 ;;
      nel) pattern='^.*$'; value=$(printf '\302\205'); expected=2 ;;
      ls) pattern='^.*$'; value=$(printf '\342\200\250'); expected=2 ;;
      ps) pattern='^.*$'; value=$(printf '\342\200\251'); expected=2 ;;
      empty) pattern='^.*$'; value=''; expected=0 ;;
    esac
    fixture_flow "$d" unicode "id: unicode
namespace: firstmate.m1
inputs:
  - id: text
    type: STRING
    validator: $pattern
$MINIMAL_HEAD"
    rc=0
    out=$(bash -c '. "$1"; fm_kestra_check_flow "$2" && fm_kestra_validate_inputs "$2" "$3"' \
      _ "$ROOT/bin/fm-kestra-lib.sh" "$d/unicode.yaml" "text=$value" 2>&1) || rc=$?
    expect_code "$expected" "$rc" "STRING validator $example must follow character semantics: $out"
  done
  pass "STRING validators count Unicode characters and exclude Java line terminators"
}

test_deploy_preserves_literal_document_separators
test_request_urls_cannot_escape_the_role_path
test_revision_verification_preserves_literal_whitespace
test_string_validators_use_character_semantics
test_typed_input_rejection_happens_before_any_request
test_undeclared_input_is_refused
test_missing_required_input_is_refused
test_malformed_and_multiline_input_values_are_refused
test_input_validation_matches_the_supported_kestra_semantics
test_allowed_execution_returns_one_opaque_id_bound_to_the_recorded_revision
test_run_refuses_without_a_verified_revision_record
test_run_refuses_when_the_server_revision_is_not_the_reviewed_source
test_run_reports_an_execution_created_at_the_wrong_revision_as_a_failure
test_credential_never_reaches_argv_and_the_auth_file_is_private
test_credential_config_and_request_cleanup_are_private_per_process
test_tracked_flow_configures_exactly_three_attempts
test_status_adapter_reports_three_attempts_and_the_retry_transitions
test_status_adapter_reports_every_attempt_log_line
test_task_after_a_terminal_failure_is_reported_as_not_run
test_state_uses_the_recorded_revision_instead_of_the_current_flow
test_state_says_when_suppression_evidence_is_unavailable_and_still_reports_state
test_replay_lineage_is_readable
test_replay_is_denied_through_every_entrypoint
test_a_flow_with_no_reviewed_source_is_not_addressable
test_every_status_read_is_bound_to_the_allow_list_before_follow_up
test_every_mutating_verb_is_refused_by_the_run_adapter
test_every_mutating_operation_is_refused_by_the_status_adapter
test_the_http_gate_allows_only_exact_role_paths
test_the_http_gate_accepts_no_raw_curl_options_or_caller_bodies
test_a_run_may_not_target_another_namespace
test_forbidden_api_words_are_matched_as_segments
test_check_mode_accepts_the_tracked_flows_without_config_or_network
test_flow_discovery_uses_only_canonical_unchanged_git_sources
test_deploy_flow_snapshot_is_immutable_after_capture
test_deploy_refuses_a_flow_without_the_read_only_label
test_deploy_refuses_pebble_templating_everywhere
test_deploy_refuses_task_types_outside_the_m1_safe_allow_list
test_deploy_refuses_task_maps_in_any_order_or_indentation_it_cannot_own
test_deploy_refuses_every_container_outside_tasks_then_and_else
test_deploy_accepts_only_the_exact_supported_yaml_shape
test_deploy_refuses_triggers
test_deploy_refuses_an_input_schema_it_cannot_pre_check
test_deploy_accepts_only_the_ere_java_common_validator_subset
test_deploy_refuses_a_namespace_outside_the_allow_list
test_deploy_never_enables_deletion_and_records_verified_revisions
test_deploy_records_nothing_when_a_revision_cannot_be_verified
test_deploy_requires_every_server_validation_result_to_pass
test_http_failures_are_failures_and_keep_the_response_diagnostic
test_a_non_loopback_endpoint_is_refused
test_only_a_declared_artifact_can_be_read
test_artifact_output_is_replaced_only_after_a_successful_download
test_artifact_streaming_preserves_binary_bytes_and_trailing_newlines
test_task_outputs_and_branch_evidence_are_reported
test_log_transport_failure_cannot_be_masked_by_jq
test_every_tracked_flow_is_static_read_only_and_m1_safe
test_no_credential_or_endpoint_value_is_committed
test_the_pinned_version_and_checksum_are_stated_once
test_kestra_contracts_have_one_documentation_owner
test_no_prototype_artifact_is_present
test_live_engine_behaviour
