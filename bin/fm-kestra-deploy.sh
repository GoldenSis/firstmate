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
#   - a task type outside the exact M1-safe allow-list in fm-kestra-lib.sh;
#   - a YAML shape, input schema, or validator regex this seam cannot represent
#     and pre-check exactly;
#   - any trigger, because executions may start only through fm-kestra-run.sh.
#
# Usage:
#   fm-kestra-deploy.sh --check    validate tracked flows only; no config, no network
#   fm-kestra-deploy.sh            validate, then validate server-side, then update
#                                  the allow-listed namespace with deletion disabled
#   fm-kestra-deploy.sh --help     this text
#
# Endpoint and credential come from gitignored captain-private config; see the
# shape in docs/kestra-seam.md. No captain-private data enters a flow payload, and
# every tracked flow is synthetic.
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
index=0
while [ "$index" -lt "${#FM_KESTRA_SNAPSHOT_FILES[@]}" ]; do
  file=${FM_KESTRA_SNAPSHOT_FILES[$index]}
  source=${FM_KESTRA_SNAPSHOT_SOURCES[$index]}
  index=$((index + 1))
  flow_count=$((flow_count + 1))
  fm_kestra_check_flow "$file" "$source" || problems=1
  ns=$(fm_kestra_scalar "$file" namespace)
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
    file=${FM_KESTRA_SNAPSHOT_FILES[$index]}
    source=${FM_KESTRA_SNAPSHOT_SOURCES[$index]}
    index=$((index + 1))
    printf 'ok: %s (%s/%s)\n' "$source" "$declared_ns" "$(fm_kestra_scalar "$file" id)"
  done
  exit 0
fi

# --- authorization ----------------------------------------------------------

fm_kestra_load_config
command -v jq >/dev/null 2>&1 || fm_kestra_die "jq is required for the Kestra seam" 1
[ "$declared_ns" = "$FM_KESTRA_NAMESPACE" ] || fm_kestra_die \
  "tracked flows declare namespace $declared_ns but only $FM_KESTRA_NAMESPACE is allow-listed"

# One multi-document body, exactly the set of tracked flows.
BODY=""
fm_kestra_tempfile flows BODY || fm_kestra_die "could not create a staging file" 1
first=1
for file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
  [ "$first" -eq 1 ] || printf -- '---\n' >> "$BODY"
  first=0
  cat -- "$file" >> "$BODY"
  printf '\n' >> "$BODY"
done

# Server-side validation first: a rejected flow must never reach the update call.
rc=0
validation=$(fm_kestra_request deploy POST /flows/validate "$BODY") || rc=$?
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
  "/flows/bulk?delete=false&namespace=$FM_KESTRA_NAMESPACE" \
  "$BODY") || rc=$?
if [ "$rc" -eq 2 ]; then
  exit 2
elif [ "$rc" -ne 0 ]; then
  [ -z "$update_response" ] || printf '%s\n' "$update_response" >&2
  fm_kestra_die "namespace update failed" 1
fi

for file in "${FM_KESTRA_SNAPSHOT_FILES[@]}"; do
  printf 'deployed: %s/%s\n' "$FM_KESTRA_NAMESPACE" "$(fm_kestra_scalar "$file" id)"
done
