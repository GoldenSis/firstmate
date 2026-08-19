#!/usr/bin/env bash
# fm-kestra-run.sh - the run adapter for firstmate's Kestra seam. Not a Kestra client.
#
# It does exactly one thing: launch one execution of one allow-listed flow with
# typed, locally pre-checked inputs, and print the opaque execution ID.
#
# The allow-list is the tracked kestra/flows/ directory itself. A flow identity with
# no reviewed source in Git is not addressable here, so the set of runnable flows
# only changes through Git review and bin/fm-kestra-deploy.sh.
#
# Denied, structurally rather than by omission:
#   - replay, restart, resume, kill, and state override;
#   - flow creation, update, and deletion;
#   - secret access and namespace administration;
#   - arbitrary task selection.
# Two independent things enforce that. This script accepts only `--flow` and
# `--input` and refuses every other argument, and fm-kestra-lib.sh's HTTP gate
# refuses any method or path outside the `run` role, so a bug here still cannot
# reach a mutating endpoint. tests/fm-kestra-seam.test.sh asserts both.
#
# A returned execution ID is a handle for reading evidence with
# bin/fm-kestra-status.sh. It is not an approval, and a later SUCCESS state is
# evidence that a task ran, never authorization for anything.
#
# Usage:
#   fm-kestra-run.sh --flow <flow-id> [--input <name>=<value>]...
#   fm-kestra-run.sh --help
#
# Every input is validated against the tracked flow's declared schema BEFORE any
# request is made, so a rejected input never creates an execution. Values are sent
# with curl's --form-string, which never interprets a leading `@` or `<` as a file
# reference.
#
# M1 is synthetic-data only: no captain-private, financial, or personal data goes
# through a flow, because retention, redaction, and artifact-size controls are not
# designed yet.
#
# Exit status: 0 and the execution ID on stdout; 2 on a refusal or usage error;
# 1 on a transport or server failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-kestra-lib.sh
. "$SCRIPT_DIR/fm-kestra-lib.sh"

FLOW=""
INPUTS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --flow)
      [ "$#" -ge 2 ] || fm_kestra_die "--flow needs a flow id"
      [ -z "$FLOW" ] || fm_kestra_die "--flow may be given once"
      FLOW=$2
      shift 2
      ;;
    --input)
      [ "$#" -ge 2 ] || fm_kestra_die "--input needs name=value"
      INPUTS+=("$2")
      shift 2
      ;;
    --help|-h)
      sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'
      exit 0
      ;;
    *)
      # Everything else is refused by name, including every mutating verb. This is
      # the denial the seam promises; do not turn it into a pass-through.
      fm_kestra_die "refused: the run adapter accepts only --flow and --input, got: $1"
      ;;
  esac
done

[ -n "$FLOW" ] || fm_kestra_die "--flow is required"

FLOW_FILE=$(fm_kestra_resolve_flow "$FLOW")
fm_kestra_check_flow "$FLOW_FILE" || fm_kestra_die "flow source failed validation: $FLOW_FILE"

fm_kestra_load_config

FLOW_NS=$(fm_kestra_scalar "$FLOW_FILE" namespace)
[ "$FLOW_NS" = "$FM_KESTRA_NAMESPACE" ] || fm_kestra_die \
  "flow $FLOW declares namespace $FLOW_NS but only $FM_KESTRA_NAMESPACE is allow-listed"

# Typed validation happens here, before the first byte goes out.
ACCEPTED=$(fm_kestra_validate_inputs "$FLOW_FILE" ${INPUTS+"${INPUTS[@]}"})

FORM=()
while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  FORM+=(--form-string "$pair")
done <<< "$ACCEPTED"

command -v jq >/dev/null 2>&1 || fm_kestra_die "jq is required for the Kestra seam" 1

RC=0
RESPONSE=$(fm_kestra_request run POST "/executions/$FM_KESTRA_NAMESPACE/$FLOW" \
  ${FORM+"${FORM[@]}"}) || RC=$?
# A refusal from the HTTP gate already printed its own diagnostic and exits 2;
# anything else is a transport or server failure.
if [ "$RC" -eq 2 ]; then
  exit 2
elif [ "$RC" -ne 0 ]; then
  fm_kestra_die "execution request failed" 1
fi

EXECUTION_ID=$(printf '%s' "$RESPONSE" | jq -r '.id // empty' 2>/dev/null || true)
[ -n "$EXECUTION_ID" ] || fm_kestra_die "no execution id in the response" 1

printf '%s\n' "$EXECUTION_ID"
