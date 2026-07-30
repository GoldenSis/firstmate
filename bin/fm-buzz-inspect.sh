#!/usr/bin/env bash
# fm-buzz-inspect.sh - read published bearings events back off the loopback relay.
#
# A human diagnostic, and only that. Firstmate never runs this and never consumes
# its output: Buzz is a projection target, never a state source. The engine's
# header (bin/fm-buzz-inspect.mjs) states the full reasoning.
#
# It answers two different questions depending on the identity it reads with:
#   default       read as the publisher (a channel member) - proves the projection
#                 is legible, and verifies each event's signature
#   --anonymous   read as a stranger - proves the private channel really is
#                 invisible to non-members, which should return zero events
#
# Unlike bin/fm-buzz-publish.sh this is NOT fire-and-forget: it is a diagnostic run
# by hand, and a failure to reach the relay should be visible in its exit status.
#
# Usage:
#   fm-buzz-inspect.sh [--limit N] [--full] [--anonymous]
#                      [--relay <url>] [--channel-label <s>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
LIMIT=3
FULL=false
ANONYMOUS=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --relay) shift; RELAY=${1:-$RELAY} ;;
    --channel-label) shift; CHANNEL_LABEL=${1:-} ;;
    --limit) shift; LIMIT=${1:-$LIMIT} ;;
    --full) FULL=true ;;
    --anonymous) ANONYMOUS=1 ;;
    --help|-h) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'fm-buzz-inspect.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

command -v node >/dev/null 2>&1 || { printf 'fm-buzz-inspect.sh: node is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'fm-buzz-inspect.sh: jq is required\n' >&2; exit 1; }

[ -n "$CHANNEL_LABEL" ] || CHANNEL_LABEL=$(fm_buzz_key_account "$FM_HOME")

CHANNEL=$(fm_buzz_channel_id "$SCRIPT_DIR" "$CHANNEL_LABEL") || {
  printf 'fm-buzz-inspect.sh: could not derive the channel id\n' >&2
  exit 1
}

KEY=""
if [ "$ANONYMOUS" -eq 0 ]; then
  KEY=$(fm_buzz_key_load "$FM_HOME") || {
    printf 'fm-buzz-inspect.sh: no publishing keypair for this home; use --anonymous or run bin/fm-buzz-keypair.sh\n' >&2
    exit 1
  }
fi

# The key travels down file descriptors only - never a command line, never the
# environment. --rawfile rather than --arg for the same reason as in
# bin/fm-buzz-publish.sh: jq's own argv is world-readable in the process table.
jq -n \
  --rawfile privateKey <(printf '%s' "$KEY") \
  --arg relay "$RELAY" \
  --arg channelId "$CHANNEL" \
  --argjson limit "$LIMIT" \
  --argjson full "$FULL" \
  '{privateKey:$privateKey, relay:$relay, channelId:$channelId, limit:$limit, full:$full}' \
  | node "$SCRIPT_DIR/fm-buzz-inspect.mjs"
