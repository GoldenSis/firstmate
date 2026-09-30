#!/usr/bin/env bash
# fm-kestra-deploy.sh - the authorized deploy-after-merge step for the Kestra seam.
#
# This is the ONLY path from firstmate's tracked, unchanged kestra/flows/ into a
# Kestra namespace. A staged, modified, or untracked flow stops deployment. Kestra
# is deliberately never given permission to pull and reconcile Git itself: upstream
# documents that Git-driven synchronization can DELETE objects depending on the
# source-of-truth setting, so this script pushes instead, always with `delete=false`.
#
# What it refuses, before any request leaves the machine:
#   - a flow whose namespace is not the one allow-listed namespace in local config;
#   - a flow missing the `system.readOnly: "true"` label (without it, the Kestra UI
#     editor can change a deployed flow and Git review becomes advisory);
#   - anything outside the M1 static-flow grammar fm-kestra-lib.sh owns: a task
#     type outside the M1-safe allow-list, any Pebble templating, an input schema or
#     validator regex the run adapter could not pre-check exactly, any trigger.
#
# What it records. After the namespace update, every flow is read back from Kestra
# at the revision the update reported, and that revision's source must be the
# reviewed HEAD bytes. Only then is the revision written to the deployed-revision
# record (data/kestra/revisions in the operating home; fm-kestra-lib.sh owns its
# format), which is what fm-kestra-run.sh binds each execution to. A read-back
# that does not match leaves the record untouched and fails, so a run can never be
# bound to a revision that was not verified.
#
# Usage:
#   fm-kestra-deploy.sh --check    validate tracked flows only; no config, no network
#   fm-kestra-deploy.sh            validate, validate server-side, update the
#                                  allow-listed namespace with deletion disabled,
#                                  verify each deployed revision, record it
#   fm-kestra-deploy.sh --help     this text
#
# Endpoint and credential come from gitignored captain-private config; see
# docs/configuration.md and docs/examples/kestra-env. No captain-private data
# enters a flow payload, and every tracked flow is synthetic.
#
# Exit status: 0 on success, 2 on a refusal or usage error, 1 on a transport or
# server failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-kestra-lib.sh
. "$SCRIPT_DIR/fm-kestra-lib.sh"

MODE=deploy
case "${1:-}" in
  '') : ;;
  --check) MODE=check ;;
  --help|-h) sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d'; exit 0 ;;
  *) fm_kestra_die "unknown argument: $1" ;;
esac
[ "$#" -le 1 ] || fm_kestra_die "unexpected extra arguments"

fm_kestra_snapshot_flow_files
[ "${#FM_KESTRA_SNAPSHOT_FILES[@]}" -gt 0 ] \
  || fm_kestra_die "no tracked flows under $(fm_kestra_flows_dir)"

# --- static validation ------------------------------------------------------

problems=0
declared_ns=""
flow_count=0
FLOW_IDS=()
index=0
while [ "$index" -lt "${#FM_KESTRA_SNAPSHOT_FILES[@]}" ]; do
  file=${FM_KESTRA_SNAPSHOT_FILES[$index]}
  source=${FM_KESTRA_SNAPSHOT_SOURCES[$index]}
  index=$((index + 1))
  flow_count=$((flow_count + 1))
  if ! fm_kestra_check_flow "$file" "$source"; then
    problems=1
    FLOW_IDS+=("")
    continue
  fi
  FLOW_IDS+=("$(fm_kestra_flow_id "$file")")
  ns=$(fm_kestra_flow_namespace "$file")
  if [ -z "$declared_ns" ]; then
    declared_ns=$ns
  elif [ "$ns" != "$declared_ns" ]; then
    printf '%s: flows must share one namespace; expected %s, found %s\n' \
      "$source" "$declared_ns" "$ns" >&2
    problems=1
  fi
done
[ "$problems" -eq 0 ] || fm_kestra_die "tracked flows failed validation"

if [ "$MODE" = check ]; then
  index=0
  while [ "$index" -lt "${#FM_KESTRA_SNAPSHOT_FILES[@]}" ]; do
    printf 'ok: %s (%s/%s)\n' "${FM_KESTRA_SNAPSHOT_SOURCES[$index]}" "$declared_ns" "${FLOW_IDS[$index]}"
    index=$((index + 1))
  done
  exit 0
fi

# --- authorization ----------------------------------------------------------

fm_kestra_load_config
command -v jq >/dev/null 2>&1 || fm_kestra_die "jq is required for the Kestra seam" 1
[ "$declared_ns" = "$FM_KESTRA_NAMESPACE" ] || fm_kestra_die \
  "tracked flows declare namespace $declared_ns but only $FM_KESTRA_NAMESPACE is allow-listed"

# The body is the HEAD snapshot, staged once inside the gate so validation and the
# update send the same bytes; this script hands the gate no body of its own.
fm_kestra_stage_deploy_body

# Server-side validation first: a rejected flow must never reach the update call.
rc=0
validation=$(fm_kestra_request deploy POST /flows/validate) || rc=$?
if [ "$rc" -eq 2 ]; then
  exit 2
elif [ "$rc" -ne 0 ]; then
  [ -z "$validation" ] || printf '%s\n' "$validation" >&2
  fm_kestra_die "flow validation request failed" 1
fi
if ! printf '%s' "$validation" | jq -e --argjson expected "$flow_count" '
  type == "array" and
  length == $expected and
  all(.[]; type == "object" and has("constraints") and .constraints == null)
' >/dev/null 2>&1; then
  [ -z "$validation" ] || printf '%s\n' "$validation" >&2
  fm_kestra_die "server rejected a tracked flow or returned an incomplete validation result" 1
fi

# `delete=false` is not a default worth trusting to a caller: deletion stays off.
rc=0
update_response=$(fm_kestra_request deploy POST \
  "/flows/bulk?delete=false&namespace=$FM_KESTRA_NAMESPACE") || rc=$?
if [ "$rc" -eq 2 ]; then
  exit 2
elif [ "$rc" -ne 0 ]; then
  [ -z "$update_response" ] || printf '%s\n' "$update_response" >&2
  fm_kestra_die "namespace update failed" 1
fi

# --- revision verification and record ---------------------------------------
#
# The update response names the revision each flow now has. Each one is read back
# and must carry the reviewed bytes before anything is recorded, so the record
# never describes a revision that was not verified.
RECORD_LINES=()
index=0
while [ "$index" -lt "${#FM_KESTRA_SNAPSHOT_FILES[@]}" ]; do
  file=${FM_KESTRA_SNAPSHOT_FILES[$index]}
  flow_id=${FLOW_IDS[$index]}
  blob=${FM_KESTRA_SNAPSHOT_BLOBS[$index]}
  index=$((index + 1))
  revision=$(printf '%s' "$update_response" | jq -r --arg id "$flow_id" --arg ns "$FM_KESTRA_NAMESPACE" '
    select(type == "array") | .[] |
    select(type == "object" and .id == $id and .namespace == $ns) |
    .revision | select(type == "number" and . >= 1 and floor == .) | tostring
  ' 2>/dev/null | head -n 1) || revision=""
  if [ -z "$revision" ]; then
    [ -z "$update_response" ] || printf '%s\n' "$update_response" >&2
    fm_kestra_die "namespace update reported no revision for flow $FM_KESTRA_NAMESPACE/$flow_id; nothing recorded" 1
  fi
  fm_kestra_verify_revision_source "$flow_id" "$FM_KESTRA_NAMESPACE" "$revision" "$file"
  RECORD_LINES+=("$(printf '%s\t%s\t%s\t%s\t%s' \
    "$flow_id" "$FM_KESTRA_NAMESPACE" "$revision" "$blob" "$FM_KESTRA_SNAPSHOT_HEAD")")
done

fm_kestra_write_revision_record "${RECORD_LINES[@]}"

for line in "${RECORD_LINES[@]}"; do
  IFS=$'\t' read -r flow_id _ revision _ _ <<< "$line"
  printf 'deployed: %s/%s revision %s\n' "$FM_KESTRA_NAMESPACE" "$flow_id" "$revision"
done
