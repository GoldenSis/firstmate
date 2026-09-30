#!/usr/bin/env bash
# fm-kestra-status.sh - the read-only half of firstmate's Kestra seam.
#
# It returns five kinds of evidence and nothing else: execution state, task logs,
# the outputs tasks declared, replay lineage, and artifacts a task actually
# declared as an output. Before any evidence is printed or any follow-up request
# is made, the execution must resolve to the configured namespace and a tracked,
# unchanged flow. Every request goes through the `read` role of fm-kestra-lib.sh's
# HTTP gate, which allows only the exact execution, log, artifact, and flow-revision
# GET shapes used here. Performing a replay is not offered by any subcommand and is
# refused by the gate.
#
# A state this prints is evidence that a task ran. It is never approval, never
# authorization, and never a business decision; nothing downstream may treat a
# SUCCESS as permission to merge, route, or unlock anything.
#
# Usage:
#   fm-kestra-status.sh state    <execution-id>   state, history, per-task attempts,
#                                                 and the tasks that never ran
#   fm-kestra-status.sh logs     <execution-id>   per-task, per-attempt log lines
#   fm-kestra-status.sh outputs  <execution-id>   every output a task declared,
#                                                 as <task>.<key>=<value>
#   fm-kestra-status.sh lineage  <execution-id>   this execution and its original
#   fm-kestra-status.sh artifact <execution-id> <uri> [--out <file>]
#                                                 one artifact a task declared as
#                                                 an output
#   fm-kestra-status.sh --help
#
# `state` reports `not-run:` for every task the execution's recorded flow revision
# declares that the execution never produced. That is only evidence once the
# execution is terminal and its task list is well-formed, and only when the exact
# revision can be read back and parsed; otherwise the line says
# `not-run: unavailable: <reason>` and the rest of the state is still printed. An
# HTTP failure reading the revision (for example a 404) is an unavailable reason;
# a transport failure is an error.
#
# `artifact` refuses any URI no task of the execution declared as an output, so
# this adapter cannot be used to walk Kestra's internal storage.
#
# Exit status: 0 on success, 2 on a refusal or usage error, 1 on a transport or
# server failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-kestra-lib.sh
. "$SCRIPT_DIR/fm-kestra-lib.sh"

case "${1:-}" in
  --help|-h) sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
esac

SUBCOMMAND=${1:-}
case "$SUBCOMMAND" in
  state|logs|outputs|lineage|artifact) : ;;
  '') fm_kestra_die "usage: fm-kestra-status.sh <state|logs|outputs|lineage|artifact> <execution-id>" ;;
  *) fm_kestra_die "refused: the status adapter is read-only and has no '$SUBCOMMAND' operation" ;;
esac
shift

EXECUTION=${1:-}
case "$EXECUTION" in
  ''|*[!a-zA-Z0-9_-]*) fm_kestra_die "execution id is not [A-Za-z0-9_-]+: ${EXECUTION:-<empty>}" ;;
esac
shift

URI=""
OUT=""
case "$SUBCOMMAND" in
  state|logs|outputs|lineage)
    [ "$#" -eq 0 ] || fm_kestra_die "$SUBCOMMAND takes only an execution id"
    ;;
  artifact)
    URI=${1:-}
    [ -n "$URI" ] || fm_kestra_die "artifact needs the URI a task declared"
    shift
    if [ "${1:-}" = "--out" ]; then
      [ "$#" -ge 2 ] || fm_kestra_die "--out needs a path"
      OUT=$2
      shift 2
    fi
    [ "$#" -eq 0 ] \
      || fm_kestra_die "artifact takes an execution id, a URI, and an optional --out"
    ;;
esac

command -v jq >/dev/null 2>&1 || fm_kestra_die "jq is required for the Kestra seam" 1
fm_kestra_load_config

# kestra_get <path>: one gated GET, with refusals kept distinguishable from
# transport failures.
kestra_get() {
  local rc=0 body
  body=$(fm_kestra_request read GET "$1") || rc=$?
  if [ "$rc" -eq 2 ]; then
    exit 2
  elif [ "$rc" -ne 0 ]; then
    [ -z "$body" ] || printf '%s\n' "$body" >&2
    fm_kestra_die "read request failed: $1" 1
  fi
  printf '%s' "$body"
}

kestra_get_file() {
  local path=$1 destination=$2 rc=0
  fm_kestra_request_to_file "$path" "$destination" || rc=$?
  if [ "$rc" -eq 2 ]; then
    exit 2
  elif [ "$rc" -ne 0 ]; then
    [ ! -s "$destination" ] || cat -- "$destination" >&2
    fm_kestra_die "read request failed: $path" 1
  fi
}

EXEC_JSON=$(kestra_get "/executions/$EXECUTION")
EXEC_ID=$(printf '%s' "$EXEC_JSON" | jq -er '.id | select(type == "string")') \
  || fm_kestra_die "execution response has no valid id" 1
NS=$(printf '%s' "$EXEC_JSON" | jq -er '.namespace | select(type == "string")') \
  || fm_kestra_die "execution response has no valid namespace" 1
FLOW=$(printf '%s' "$EXEC_JSON" | jq -er '.flowId | select(type == "string")') \
  || fm_kestra_die "execution response has no valid flowId" 1
[ "$EXEC_ID" = "$EXECUTION" ] \
  || fm_kestra_die "execution response id does not match the requested execution" 1
[ "$NS" = "$FM_KESTRA_NAMESPACE" ] \
  || fm_kestra_die "refused: execution $EXECUTION belongs to namespace $NS, not allow-listed namespace $FM_KESTRA_NAMESPACE"
FLOW_FILE=""
fm_kestra_resolve_flow "$FLOW" FLOW_FILE
FLOW_NS=$(fm_kestra_flow_namespace "$FLOW_FILE")
[ "$FLOW_NS" = "$FM_KESTRA_NAMESPACE" ] \
  || fm_kestra_die "refused: tracked flow $FLOW does not belong to allow-listed namespace $FM_KESTRA_NAMESPACE"

# not_run_source <revision> <out-var>: stage the flow source at that revision, or
# set NOT_RUN_UNAVAILABLE. Curl's exit 22 is an HTTP-level failure with the body
# retained, which is an unavailable reason; anything else non-zero is transport.
not_run_source() {
  local revision=$1 out_var=$2 rc=0 body returned source staged
  body=$(fm_kestra_request read GET "/flows/$NS/$FLOW?revision=$revision&source=true") || rc=$?
  if [ "$rc" -eq 2 ]; then
    exit 2
  elif [ "$rc" -eq 22 ]; then
    NOT_RUN_UNAVAILABLE="flow revision $revision could not be read from Kestra"
    return 0
  elif [ "$rc" -ne 0 ]; then
    [ -z "$body" ] || printf '%s\n' "$body" >&2
    fm_kestra_die "read request failed: /flows/$NS/$FLOW?revision=$revision&source=true" 1
  fi
  returned=$(printf '%s' "$body" | jq -r '
    .revision | select(type == "number" and . >= 1 and floor == .) | tostring
  ' 2>/dev/null) || returned=""
  source=$(printf '%s' "$body" | jq -er '.source | select(type == "string")' 2>/dev/null) || source=""
  if [ "$returned" != "$revision" ] || [ -z "$source" ]; then
    NOT_RUN_UNAVAILABLE="flow revision $revision could not be resolved"
    return 0
  fi
  fm_kestra_tempfile revision staged || fm_kestra_die "could not stage flow revision $revision" 1
  printf '%s\n' "$source" > "$staged"
  if ! fm_kestra_check_flow "$staged" >/dev/null 2>&1 \
    || [ "$(fm_kestra_flow_id "$staged")" != "$FLOW" ] \
    || [ "$(fm_kestra_flow_namespace "$staged")" != "$NS" ]; then
    NOT_RUN_UNAVAILABLE="flow revision $revision could not be parsed safely"
    return 0
  fi
  printf -v "$out_var" '%s' "$staged"
}

case "$SUBCOMMAND" in
  state)
    NOT_RUN_SOURCE=""
    NOT_RUN_UNAVAILABLE=""
    STATE=$(printf '%s' "$EXEC_JSON" | jq -r '.state.current // "unknown"')
    REVISION=$(printf '%s' "$EXEC_JSON" | jq -r '
      .flowRevision |
      select(type == "number" and . >= 1 and floor == .) |
      tostring
    ')
    case "$STATE" in
      SUCCESS|WARNING|FAILED|KILLED|CANCELLED) : ;;
      *) NOT_RUN_UNAVAILABLE="execution is not terminal ($STATE)" ;;
    esac
    if [ -z "$NOT_RUN_UNAVAILABLE" ] \
      && ! printf '%s' "$EXEC_JSON" | jq -e '
        (.taskRunList | type == "array") and all(.taskRunList[]; type == "object" and (.taskId | type == "string"))
      ' >/dev/null 2>&1; then
      NOT_RUN_UNAVAILABLE="execution has no well-formed task list"
    fi
    if [ -z "$NOT_RUN_UNAVAILABLE" ] && [ -z "$REVISION" ]; then
      NOT_RUN_UNAVAILABLE="execution has no valid flowRevision"
    fi
    if [ -z "$NOT_RUN_UNAVAILABLE" ]; then
      not_run_source "$REVISION" NOT_RUN_SOURCE
    fi

    printf 'execution: %s\n' "$EXEC_ID"
    printf 'flow: %s/%s\n' "$NS" "$FLOW"
    printf 'revision: %s\n' "${REVISION:-unknown}"
    printf 'state: %s\n' "$STATE"
    # The full transition history is what makes a retry sequence observable rather
    # than a bare terminal state, so it is printed verbatim and in order.
    printf 'history: %s\n' \
      "$(printf '%s' "$EXEC_JSON" | jq -r '[.state.histories[]?.state] | join(" -> ")')"
    printf '%s' "$EXEC_JSON" | jq -r '
      .taskRunList[]? | select(type == "object") |
      "task: \(.taskId) state=\(.state.current) attempts=\(.attempts | length // 0) " +
      "history=\([.state.histories[]?.state] | join(","))"
    '
    if [ -n "$NOT_RUN_UNAVAILABLE" ]; then
      printf 'not-run: unavailable: %s\n' "$NOT_RUN_UNAVAILABLE"
    else
      while IFS= read -r declared; do
        [ -n "$declared" ] || continue
        if ! printf '%s' "$EXEC_JSON" \
          | jq -e --arg task "$declared" 'any(.taskRunList[]; .taskId == $task)' >/dev/null; then
          printf 'not-run: %s\n' "$declared"
        fi
      done <<< "$(fm_kestra_task_ids "$NOT_RUN_SOURCE")"
    fi
    ;;

  logs)
    LOGS_JSON=$(kestra_get "/logs/$EXECUTION")
    printf '%s' "$LOGS_JSON" | jq -r '
      .[]? | "log: task=\(.taskId // "-") attempt=\(.attemptNumber // 0) " +
      "level=\(.level // "-") \(.message // "")"
    '
    ;;

  outputs)
    # Outputs are what tasks declared on their own task runs: a Return task's
    # value, a Write task's uri. Static flows declare no flow-level outputs.
    printf '%s' "$EXEC_JSON" | jq -r '
      .taskRunList[]? | select(type == "object") |
      .taskId as $task | (.outputs // {}) | to_entries[]? |
      "output: \($task).\(.key)=\(.value | tostring)"
    '
    ;;

  lineage)
    printf 'execution: %s\n' "$EXEC_ID"
    printf 'original: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.originalId // "none"')"
    ;;

  artifact)
    # Approved means declared. An artifact URI no task of this execution published
    # as one of its outputs is refused, so this stays an evidence reader rather
    # than a storage browser.
    printf '%s' "$EXEC_JSON" | jq -e --arg uri "$URI" '
      any(.taskRunList[]? | select(type == "object") | (.outputs // {}) | to_entries[]?;
        (.value | tostring) == $uri)
    ' >/dev/null \
      || fm_kestra_die "refused: $URI is not declared as an output of execution $EXECUTION"
    ENCODED=$(printf '%s' "$URI" | jq -sRr @uri)
    if [ -n "$OUT" ]; then
      OUT_DIR=$(dirname -- "$OUT")
      fm_kestra_tempfile artifact ARTIFACT_TMP "$OUT_DIR" \
        || fm_kestra_die "could not create an artifact staging file beside $OUT" 1
      kestra_get_file "/executions/$EXECUTION/file?path=$ENCODED" "$ARTIFACT_TMP"
      mv -- "$ARTIFACT_TMP" "$OUT" || fm_kestra_die "could not replace artifact output: $OUT" 1
      printf 'artifact: %s\n' "$OUT"
    else
      fm_kestra_tempfile artifact ARTIFACT_TMP \
        || fm_kestra_die "could not create an artifact staging file" 1
      kestra_get_file "/executions/$EXECUTION/file?path=$ENCODED" "$ARTIFACT_TMP"
      cat -- "$ARTIFACT_TMP"
    fi
    ;;
esac
