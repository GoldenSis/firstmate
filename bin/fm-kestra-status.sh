#!/usr/bin/env bash
# fm-kestra-status.sh - the read-only half of firstmate's Kestra seam.
#
# It returns five kinds of evidence and nothing else: execution state, task logs,
# declared flow outputs, replay lineage, and artifacts a flow actually declared as
# an output. Before any evidence is printed or any follow-up request is made, the
# execution must resolve to the configured namespace and a tracked, unchanged flow.
# Every request goes through the `read` role of fm-kestra-lib.sh's HTTP gate, which
# allows only the exact execution, log, artifact, and recorded-flow-revision GET
# shapes used here. Performing a replay is not offered by any subcommand and is
# refused by the gate.
#
# A state this prints is evidence that a task ran. It is never approval, never
# authorization, and never a business decision; nothing downstream may treat a
# SUCCESS as permission to merge, route, or unlock anything.
#
# Usage:
#   fm-kestra-status.sh state    <execution-id>   state, history, per-task attempts,
#                                                 and the tasks that never ran
#   fm-kestra-status.sh logs     <execution-id>   per-task log lines
#   fm-kestra-status.sh outputs  <execution-id>   the flow's declared outputs
#   fm-kestra-status.sh lineage  <execution-id>   this execution and its original
#   fm-kestra-status.sh artifact <execution-id> <uri> [--out <file>]
#                                                 one artifact the execution
#                                                 declared as an output
#   fm-kestra-status.sh --help
#
# `state` reports `not-run:` for every task the execution's recorded flow revision
# declares that the execution never produced. If that exact revision cannot be
# resolved, the output says the suppression evidence is unavailable.
#
# `artifact` refuses any URI the execution did not declare in its own outputs, so
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
    [ -n "$URI" ] || fm_kestra_die "artifact needs the URI the execution declared"
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

# fm_kestra_read <path>: one gated GET, with refusals kept distinguishable from
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
FLOW_FILE=$(fm_kestra_resolve_flow "$FLOW")
FLOW_NS=$(fm_kestra_scalar "$FLOW_FILE" namespace)
[ "$FLOW_NS" = "$FM_KESTRA_NAMESPACE" ] \
  || fm_kestra_die "refused: tracked flow $FLOW does not belong to allow-listed namespace $FM_KESTRA_NAMESPACE"

case "$SUBCOMMAND" in
  state)
    NOT_RUN_SOURCE=""
    NOT_RUN_UNAVAILABLE=""
    REVISION=$(printf '%s' "$EXEC_JSON" | jq -r '
      .flowRevision |
      select(type == "number" and . >= 1 and floor == .) |
      tostring
    ')
    if [ -z "$REVISION" ]; then
      NOT_RUN_UNAVAILABLE="execution has no valid flowRevision"
    else
      REVISION_JSON=$(kestra_get "/flows/$NS/$FLOW?revision=$REVISION&source=true")
      RETURNED_REVISION=$(printf '%s' "$REVISION_JSON" | jq -r '
        .revision |
        select(type == "number" and . >= 1 and floor == .) |
        tostring
      ')
      REVISION_SOURCE=$(printf '%s' "$REVISION_JSON" | jq -er '.source | select(type == "string")' 2>/dev/null) \
        || REVISION_SOURCE=""
      if [ "$RETURNED_REVISION" != "$REVISION" ] || [ -z "$REVISION_SOURCE" ]; then
        NOT_RUN_UNAVAILABLE="flow revision $REVISION could not be resolved"
      else
        fm_kestra_tempfile revision NOT_RUN_SOURCE \
          || fm_kestra_die "could not stage flow revision $REVISION" 1
        printf '%s\n' "$REVISION_SOURCE" > "$NOT_RUN_SOURCE"
        if ! fm_kestra_check_flow "$NOT_RUN_SOURCE" >/dev/null 2>&1 \
          || [ "$(fm_kestra_scalar "$NOT_RUN_SOURCE" id)" != "$FLOW" ] \
          || [ "$(fm_kestra_scalar "$NOT_RUN_SOURCE" namespace)" != "$NS" ]; then
          NOT_RUN_UNAVAILABLE="flow revision $REVISION could not be parsed safely"
        fi
      fi
    fi

    printf 'execution: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.id // "unknown"')"
    printf 'flow: %s/%s\n' "$NS" "$FLOW"
    printf 'state: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.state.current // "unknown"')"
    # The full transition history is what makes a retry sequence observable rather
    # than a bare terminal state, so it is printed verbatim and in order.
    printf 'history: %s\n' \
      "$(printf '%s' "$EXEC_JSON" | jq -r '[.state.histories[]?.state] | join(" -> ")')"
    printf '%s' "$EXEC_JSON" | jq -r '
      .taskRunList[]? |
      "task: \(.taskId) state=\(.state.current) attempts=\(.attempts | length // 0) " +
      "history=\([.state.histories[]?.state] | join(","))"
    '
    if [ -n "$NOT_RUN_UNAVAILABLE" ]; then
      printf 'not-run: unavailable: %s\n' "$NOT_RUN_UNAVAILABLE"
    else
      while IFS= read -r declared; do
        [ -n "$declared" ] || continue
        if ! printf '%s' "$EXEC_JSON" \
          | jq -e --arg task "$declared" 'any(.taskRunList[]?; .taskId == $task)' >/dev/null; then
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
    printf '%s' "$EXEC_JSON" | jq -r '
      (.outputs // {}) | to_entries[]? | "output: \(.key)=\(.value)"
    '
    ;;

  lineage)
    printf 'execution: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.id // "unknown"')"
    printf 'original: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.originalId // "none"')"
    ;;

  artifact)
    # Approved means declared. An artifact URI the execution did not publish as one
    # of its own outputs is refused, so this stays an evidence reader rather than a
    # storage browser.
    printf '%s' "$EXEC_JSON" | jq -e --arg uri "$URI" \
      'any((.outputs // {}) | to_entries[]?; (.value | tostring) == $uri)' >/dev/null \
      || fm_kestra_die "refused: $URI is not declared as an output of execution $EXECUTION"
    ENCODED=$(printf '%s' "$URI" | jq -sRr @uri)
    if [ -n "$OUT" ]; then
      OUT_DIR=$(dirname -- "$OUT")
      fm_kestra_tempfile artifact ARTIFACT_TMP "$OUT_DIR" \
        || fm_kestra_die "could not create an artifact staging file beside $OUT" 1
      kestra_get "/executions/$EXECUTION/file?path=$ENCODED" > "$ARTIFACT_TMP"
      mv -- "$ARTIFACT_TMP" "$OUT" || fm_kestra_die "could not replace artifact output: $OUT" 1
      printf 'artifact: %s\n' "$OUT"
    else
      kestra_get "/executions/$EXECUTION/file?path=$ENCODED"
    fi
    ;;
esac
