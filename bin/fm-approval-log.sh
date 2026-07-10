#!/usr/bin/env bash
# fm-approval-log.sh - the durable, append-only record of every approval firstmate acts on.
#
# Closes agent-registry gap #4: firstmate approvals (PR merges, local-only merges, ask-user
# resolutions, discards) previously left no durable trail - and under yolo=on, no record at all.
# This is the append-only ledger of those decisions. It ONLY appends; it never rewrites or deletes.
#
# The log lives in data/ (durable, git-tracked, backed up with firstmate every 6h) - NOT state/,
# which is volatile per-task status. Format is one tab-separated line per approval:
#   <iso8601-utc> \t <actor> \t <action> \t <project> \t <ref> \t <detail>
#     actor  = captain | yolo      (who authorised it: the captain explicitly, or yolo self-approval)
#     action = local-merge | pr-merge | ask-user | discard | other
#     ref    = task id / PR URL / branch (whatever identifies the thing approved)
#
# Usage:
#   fm-approval-log.sh record --actor <captain|yolo> --action <action> [--project P] [--ref R] [--detail "..."]
#   fm-approval-log.sh show [N]      # tail the last N approvals (default 20), newest last
#   fm-approval-log.sh path          # print the log file path
#
# See AGENTS.md (yolo / task lifecycle): every self-approved merge MUST be recorded here.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
LOG="${FM_APPROVAL_LOG_OVERRIDE:-$FM_HOME/data/approvals.log}"

usage() { sed -n '2,30p' "$0"; exit "${1:-0}"; }

cmd=${1:-}; [ -n "$cmd" ] || usage 1
shift || true

case "$cmd" in
  path) echo "$LOG" ;;

  show)
    n=${1:-20}
    if [ -f "$LOG" ]; then tail -n "$n" "$LOG"; else echo "(no approvals logged yet: $LOG)"; fi
    ;;

  record)
    actor=""; action=""; project=""; ref=""; detail=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --actor)   actor=${2:-}; shift 2 ;;
        --action)  action=${2:-}; shift 2 ;;
        --project) project=${2:-}; shift 2 ;;
        --ref)     ref=${2:-}; shift 2 ;;
        --detail)  detail=${2:-}; shift 2 ;;
        *) echo "fm-approval-log: unknown arg '$1'" >&2; exit 2 ;;
      esac
    done
    [ -n "$actor" ]  || { echo "fm-approval-log: --actor required (captain|yolo)" >&2; exit 2; }
    [ -n "$action" ] || { echo "fm-approval-log: --action required" >&2; exit 2; }
    case "$actor" in captain|yolo) ;; *) echo "fm-approval-log: --actor must be captain|yolo" >&2; exit 2 ;; esac

    # Sanitise: strip tabs/newlines so one approval is always exactly one parseable line.
    clean() { printf '%s' "${1:-}" | tr '\t\n' '  '; }
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$LOG")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts" "$(clean "$actor")" "$(clean "$action")" "$(clean "$project")" "$(clean "$ref")" "$(clean "$detail")" \
      >> "$LOG"
    echo "logged: $actor $action ${ref:+$ref }-> $LOG"
    ;;

  -h|--help|help) usage 0 ;;
  *) echo "fm-approval-log: unknown command '$cmd'" >&2; usage 2 ;;
esac
