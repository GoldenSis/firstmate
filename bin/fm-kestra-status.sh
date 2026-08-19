#!/usr/bin/env bash
# fm-kestra-status.sh - the read-only half of firstmate's Kestra seam.
#
# It returns four kinds of evidence and nothing else: execution state, task logs,
# declared flow outputs, and artifacts a flow actually declared as an output. Every
# request it makes goes through the `read` role of fm-kestra-lib.sh's HTTP gate,
# which allows only GET on the execution and log surfaces, so replay, restart,
# resume, kill, state override, flow mutation, and secret access are unreachable
# from here even by mistake.
#
# Replay LINEAGE is readable through `lineage`, because knowing an execution was
# derived from another one is evidence. Performing a replay is not offered by any
# subcommand and is refused by the gate.
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
# `state` reports `not-run:` for every task the tracked flow declares that the
# execution never produced. That is how the seam makes suppression after a terminal
# failure observable rather than inferred from an absence.
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
    fm_kestra_die "read request failed: $1" 1
  fi
  printf '%s' "$body"
}

case "$SUBCOMMAND" in
  state)
    [ "$#" -eq 0 ] || fm_kestra_die "state takes only an execution id"
    EXEC_JSON=$(kestra_get "/executions/$EXECUTION")
    printf 'execution: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.id // "unknown"')"
    NS=$(printf '%s' "$EXEC_JSON" | jq -r '.namespace // "unknown"')
    FLOW=$(printf '%s' "$EXEC_JSON" | jq -r '.flowId // "unknown"')
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
    # Tasks the reviewed flow declares but this execution never produced. After a
    # terminal failure, the following task appearing here is the suppression
    # evidence.
    if FLOW_FILE=$(fm_kestra_resolve_flow "$FLOW" 2>/dev/null); then
      RAN=$(printf '%s' "$EXEC_JSON" | jq -r '.taskRunList[]?.taskId')
      while IFS= read -r declared; do
        [ -n "$declared" ] || continue
        case "$(printf '\n%s\n' "$RAN")" in
          *"$(printf '\n%s\n' "$declared")"*) : ;;
          *) printf 'not-run: %s\n' "$declared" ;;
        esac
      done <<< "$(fm_kestra_task_ids "$FLOW_FILE")"
    fi
    ;;

  logs)
    [ "$#" -eq 0 ] || fm_kestra_die "logs takes only an execution id"
    kestra_get "/logs/$EXECUTION" | jq -r '
      .[]? | "log: task=\(.taskId // "-") attempt=\(.attemptNumber // 0) " +
      "level=\(.level // "-") \(.message // "")"
    '
    ;;

  outputs)
    [ "$#" -eq 0 ] || fm_kestra_die "outputs takes only an execution id"
    kestra_get "/executions/$EXECUTION" | jq -r '
      (.outputs // {}) | to_entries[]? | "output: \(.key)=\(.value)"
    '
    ;;

  lineage)
    [ "$#" -eq 0 ] || fm_kestra_die "lineage takes only an execution id"
    EXEC_JSON=$(kestra_get "/executions/$EXECUTION")
    printf 'execution: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.id // "unknown"')"
    printf 'original: %s\n' "$(printf '%s' "$EXEC_JSON" | jq -r '.originalId // "none"')"
    ;;

  artifact)
    URI=${1:-}
    [ -n "$URI" ] || fm_kestra_die "artifact needs the URI the execution declared"
    shift
    OUT=""
    if [ "${1:-}" = "--out" ]; then
      [ "$#" -ge 2 ] || fm_kestra_die "--out needs a path"
      OUT=$2
      shift 2
    fi
    [ "$#" -eq 0 ] || fm_kestra_die "artifact takes an execution id, a URI, and an optional --out"

    # Approved means declared. An artifact URI the execution did not publish as one
    # of its own outputs is refused, so this stays an evidence reader rather than a
    # storage browser.
    EXEC_JSON=$(kestra_get "/executions/$EXECUTION")
    DECLARED=$(printf '%s' "$EXEC_JSON" | jq -r '(.outputs // {}) | to_entries[]? | .value | tostring')
    case "$(printf '\n%s\n' "$DECLARED")" in
      *"$(printf '\n%s\n' "$URI")"*) : ;;
      *) fm_kestra_die "refused: $URI is not declared as an output of execution $EXECUTION" ;;
    esac
    ENCODED=$(printf '%s' "$URI" | jq -sRr @uri)
    if [ -n "$OUT" ]; then
      kestra_get "/executions/$EXECUTION/file?path=$ENCODED" > "$OUT"
      printf 'artifact: %s\n' "$OUT"
    else
      kestra_get "/executions/$EXECUTION/file?path=$ENCODED"
    fi
    ;;
esac
