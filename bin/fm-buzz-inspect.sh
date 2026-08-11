#!/usr/bin/env bash
# fm-buzz-inspect.sh - read published bearings events back off the loopback relay.
#
# A human diagnostic, and only that. Firstmate never runs this and never consumes
# its output: Buzz is a projection target, never a state source. The engine's
# header (bin/fm-buzz-inspect.mjs) states the full reasoning.
#
# This wrapper selects the reading identity, resolves the channel, and supplies
# this home's recorded authors. This header owns the user-facing verdict contract;
# bin/fm-buzz-inspect.mjs owns its assessment mechanics and rationale.
# --channel-label may select another channel, but this wrapper never reads another
# home's author records to attribute it.
#
# Unlike bin/fm-buzz-publish.sh this is NOT fire-and-forget: it is a diagnostic run
# by hand, and a failure to reach the relay should be visible in its exit status.
#
# With no flags, the diagnostic reads up to three events from this home's channel
# with this home's publishing identity and prints at most 600 content bytes
# per event. Content longer than that ends with an explicit truncation marker
# (`... (truncated at 600 bytes; run with --full to see the complete projection)`);
# --full prints complete event content with no marker, and --limit changes the
# relay query limit.
#
# --anonymous reads with a throwaway non-member identity without loading the
# publishing private key. It reports a definite negative privacy result only for
# a returned event whose shape, recomputed id, signature, exact channel tag, and
# author all verify, with the author matching this home's current or retained
# historical publishing keys. It reports positive assurance only for an empty
# read that the relay rejects with a membership-tagged `restricted:` reason on
# this home's own channel. Empty reads without that refusal, other refusal
# reasons, unverifiable events, and channels derived from another home are
# inconclusive.
#
# Usage:
#   fm-buzz-inspect.sh [--limit N] [--full] [--anonymous]
#                      [--relay <url>] [--channel-label <s>]
#   fm-buzz-inspect.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
LIMIT=3
FULL=false
ANONYMOUS=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --relay|--channel-label|--limit)
      option=$1
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        printf 'fm-buzz-inspect.sh: %s requires a value\n' "$option" >&2
        exit 2
      fi
      case $2 in
        --*)
          printf 'fm-buzz-inspect.sh: %s requires a value\n' "$option" >&2
          exit 2
          ;;
      esac
      shift
      case $option in
        --relay) RELAY=$1 ;;
        --channel-label) CHANNEL_LABEL=$1 ;;
        --limit) LIMIT=$1 ;;
      esac
      ;;
    --full) FULL=true ;;
    --anonymous) ANONYMOUS=1 ;;
    --help|-h) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'fm-buzz-inspect.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

command -v node >/dev/null 2>&1 || { printf 'fm-buzz-inspect.sh: node is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'fm-buzz-inspect.sh: jq is required\n' >&2; exit 1; }

OWN_LABEL=$(fm_buzz_key_account "$FM_HOME")
[ -n "$CHANNEL_LABEL" ] || CHANNEL_LABEL=$OWN_LABEL

# Whether the recorded keys can attribute what the relay serves is a property of
# the RESOLVED label, not of whether --channel-label was typed. Deciding it from
# the flag's presence throws the conclusive answer away for an operator who
# spelled their own home path out - a natural thing to do when checking which
# channel id a label derives to - and that is a false negative over a real leak of
# this home's own content.
if [ "$CHANNEL_LABEL" = "$OWN_LABEL" ]; then
  OWN_CHANNEL=true
else
  OWN_CHANNEL=false
fi

CHANNEL=$(fm_buzz_channel_id "$SCRIPT_DIR" "$CHANNEL_LABEL") || {
  printf 'fm-buzz-inspect.sh: could not derive the channel id\n' >&2
  exit 1
}

# The PUBLIC halves of this home's publishing keys, so the engine can tell an event
# this home actually wrote from one any stranger could have signed against the
# same (non-secret) channel id. bin/fm-buzz-keypair.sh records them here precisely
# so they are readable without touching the keychain, which matters under
# --anonymous: no private key is loaded on that path.
#
# Retired keys count too. Rotation mints a new key but leaves the channel id and
# the relay's stored events untouched, so this home's own pre-rotation projections
# are still on the relay signed by the old key; attributing only the current key
# would make the probe report this home's own leaked content as somebody else's.
# A retired key is still evidence, because only this home ever held it.
#
# An absent file is not an error - the engine then declines to attribute any event
# rather than guessing. These are read for THIS home only: a channel derived from
# another label is handled by declining a verdict, never by reading another home's
# files.
EXPECTED_AUTHORS=()
current_file="$DATA/buzz-keypair.public"
if current_key=$(fm_buzz_current_public_record_read "$current_file" 2>/dev/null); then
  EXPECTED_AUTHORS+=("$current_key")
fi

history_file="$DATA/buzz-keypair.public-history"
if history=$(fm_buzz_public_history_read "$history_file" 2>/dev/null); then
  while IFS= read -r author_line || [ -n "$author_line" ]; do
    [ -n "$author_line" ] && EXPECTED_AUTHORS+=("$author_line")
  done <<EOF
$history
EOF
fi

KEY=""
if [ "$ANONYMOUS" -eq 0 ]; then
  KEY=$(fm_buzz_key_load "$FM_HOME")
  load_status=$?
  if [ "$load_status" -ne 0 ]; then
    if [ "$load_status" -eq 1 ]; then
      printf 'fm-buzz-inspect.sh: no publishing keypair for this home; use --anonymous or run bin/fm-buzz-keypair.sh\n' >&2
    else
      printf 'fm-buzz-inspect.sh: the stored publishing key could not be read\n' >&2
    fi
    exit 1
  fi
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
  --argjson ownChannel "$OWN_CHANNEL" \
  --args \
  '{privateKey:$privateKey, relay:$relay, channelId:$channelId,
    expectedAuthors:$ARGS.positional, ownChannel:$ownChannel,
    limit:$limit, full:$full}' \
  ${EXPECTED_AUTHORS[@]+"${EXPECTED_AUTHORS[@]}"} \
  | node "$SCRIPT_DIR/fm-buzz-inspect.mjs"
