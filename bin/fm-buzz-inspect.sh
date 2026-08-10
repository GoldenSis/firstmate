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
#   --anonymous   read as a stranger - probes whether the private channel is
#                 invisible to non-members. An event that recomputes to its own id,
#                 verifies under its author's signature, carries this channel's
#                 `h` tag AND was signed by this home's recorded publishing key is
#                 the conclusive answer, and it is a negative one: a non-member read
#                 the channel. Events the relay served but that fail any of those
#                 checks are reported INCONCLUSIVE instead, since a relay that
#                 alters, replays or fabricates frames says nothing about who may
#                 read this channel - and the channel id is not a secret, so a
#                 correctly signed event tagged for it can come from any stranger
#                 who can publish to the relay. Authorship is checked against this
#                 home's current AND retired publishing keys, so a rotation does
#                 not blind the probe to pre-rotation events the relay still holds.
#                 Combining it with --channel-label rules the conclusive answer out
#                 entirely: see that flag below.
#                 Zero events is only an answer the other way when the relay
#                 refuses the subscription on MEMBERSHIP grounds, i.e. with
#                 NIP-01's `restricted:`. Every other outcome is reported
#                 INCONCLUSIVE and prints the relay's own words: any other reason
#                 is not machine-tagged as a membership refusal and so cannot be
#                 read as one, and an unrefused empty read looks identical to a
#                 wiped relay, a channel id from another home, a publish that never
#                 landed, or a channel that is simply empty.
#
# --channel-label points the read at a channel derived from some other label than
# this home's, and the only publishing keys on disk here are this home's own. So
# --anonymous cannot reach the conclusive answer for such a channel: it reports
# INCONCLUSIVE with "cannot verify authorship for a channel not derived from this
# home; use --anonymous only on this home's own channel". Reading another home's
# recorded keys is not the answer - firstmate does not reach into another home's
# files - so probe a channel from the home that owns it.
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

if [ -n "$CHANNEL_LABEL" ]; then
  OWN_CHANNEL=false
else
  OWN_CHANNEL=true
  CHANNEL_LABEL=$(fm_buzz_key_account "$FM_HOME")
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
collect_author() {  # <line>
  local key=$1
  key=$(printf '%s' "$key" | tr -d '[:space:]' | tr 'A-F' 'a-f')
  [ "${#key}" -eq 64 ] || return 0
  case $key in *[!0-9a-f]*) return 0 ;; esac
  EXPECTED_AUTHORS+=("$key")
}
for author_file in "$DATA/buzz-keypair.public" "$DATA/buzz-keypair.public-history"; do
  [ -r "$author_file" ] || continue
  while IFS= read -r author_line || [ -n "$author_line" ]; do
    collect_author "$author_line"
  done < "$author_file"
done

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
  --argjson ownChannel "$OWN_CHANNEL" \
  --args \
  '{privateKey:$privateKey, relay:$relay, channelId:$channelId,
    expectedAuthors:$ARGS.positional, ownChannel:$ownChannel,
    limit:$limit, full:$full}' \
  ${EXPECTED_AUTHORS[@]+"${EXPECTED_AUTHORS[@]}"} \
  | node "$SCRIPT_DIR/fm-buzz-inspect.mjs"
