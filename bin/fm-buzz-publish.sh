#!/usr/bin/env bash
# fm-buzz-publish.sh - publish one bearings projection to the loopback Buzz relay.
#
# ============================ FIRE-AND-FORGET ==============================
# THIS SCRIPT ALWAYS EXITS 0. A NON-ZERO EXIT FROM THIS SCRIPT IS A BUG.
#
# Every failure path - relay down, connection refused, timeout, NIP-42 auth
# failure, event rejected, signing error, missing keypair, missing node, missing
# jq, unreadable replay cache, malformed snapshot, anything at all - must be
# caught, logged to stderr, and followed by exit 0. Nothing here may ever
# propagate a non-zero status into a caller.
#
# Why the contract is this absolute: Buzz is an additive reporting surface and
# nothing in Firstmate's operation may depend on it. If this script could fail, a
# stopped relay would be able to break a merge, a teardown, a wake drain, or a
# turn end - and Buzz would have become load-bearing for supervision, which is
# exactly the outcome the study that authorized this work ruled out. Publishing
# is downstream of everything and blocks nothing.
#
# Consequences that follow from the contract, for anyone editing this file:
#   - Do not add `set -e`. It is absent on purpose.
#   - Do not add a `|| exit 1`, an `exit $?`, or a bare `exit` on any path.
#   - A failure the operator needs to see is a stderr line, never an exit code.
#   - The engine (bin/fm-buzz-publish.mjs) MAY exit non-zero; converting that into
#     a logged success is this wrapper's whole job.
# tests/fm-buzz-publish.test.sh asserts exit 0 with the relay stopped, and also
# greps this file to assert `set -e` has not crept back in.
# ===========================================================================
#
# The published event is one append-only NIP-29 channel message whose content is
# the `fm-bearings-snapshot.sh --json` projection VERBATIM, including its
# omitted[] disclosure array. The disclosure is what makes a bounded projection
# honest - it states what was dropped and how to reveal it - so it is passed
# through untouched rather than summarised or stripped.
#
# Read-only in both directions that matter: this script only ever reads Firstmate
# state (via the snapshot's own read-only command) and only ever writes to Buzz.
# It never reads state back from Buzz. Buzz is a projection target, never a state
# source; bin/fm-buzz-inspect.mjs is a human diagnostic and is not consumed here.
#
# Usage:
#   fm-buzz-publish.sh                 read the projection JSON on stdin
#   fm-buzz-publish.sh --refresh       invoke bin/fm-bearings-snapshot.sh --json
#   fm-buzz-publish.sh --relay <url>   override the relay (default ws://localhost:3000)
#   fm-buzz-publish.sh --channel-label <s>
#                                      override the channel-derivation label
#   fm-buzz-publish.sh --timeout <ms>  relay timeout (default 15000)
#   fm-buzz-publish.sh --help          this text
#
# Relay host note: the default is ws://localhost:3000, not ws://127.0.0.1:3000.
# Buzz resolves its tenant from the HTTP Host header and the bundled deployment
# community is registered as `localhost:3000`, so a bare-IP Host is answered with
# `relay: no community is configured for this host`. Both spellings are loopback;
# only one is accepted. See docs/buzz-loopback-adapter.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

RELAY=${FM_BUZZ_RELAY:-ws://localhost:3000}
CHANNEL_LABEL=""
TIMEOUT_MS=${FM_BUZZ_TIMEOUT_MS:-15000}
MAX_CACHE=${FM_BUZZ_MAX_CACHE:-100}
REFRESH=0
REPLAY_DIR="$STATE/buzz-replay"

log() {
  printf 'fm-buzz-publish: %s\n' "$1" >&2
}

# Everything substantive runs inside this function so the tail of the script can
# hold the single unconditional `exit 0` that the contract above demands.
publish() {
  command -v node >/dev/null 2>&1 || { log "node is unavailable; skipping publish"; return 1; }
  command -v jq >/dev/null 2>&1 || { log "jq is unavailable; skipping publish"; return 1; }

  local content
  if [ "$REFRESH" -eq 1 ]; then
    content=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" --json 2>/dev/null) || {
      log "bearings snapshot failed; skipping publish"
      return 1
    }
  else
    content=$(cat) || { log "could not read the projection from stdin"; return 1; }
  fi
  [ -n "$content" ] || { log "the projection is empty; skipping publish"; return 1; }

  local key
  key=$(fm_buzz_key_load "$FM_HOME") || {
    log "no publishing keypair for this home; run bin/fm-buzz-keypair.sh first"
    return 1
  }
  [ -n "$key" ] || { log "the stored publishing key is empty"; return 1; }

  local label=$CHANNEL_LABEL
  if [ -z "$label" ]; then
    label=$(fm_buzz_key_account "$FM_HOME")
  fi

  local channel
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$SCRIPT_DIR/fm-buzz-lib.mjs" "$label") || {
    log "could not derive the channel id"
    return 1
  }

  mkdir -p "$REPLAY_DIR" 2>/dev/null || { log "could not create $REPLAY_DIR"; return 1; }
  chmod 0700 "$REPLAY_DIR" 2>/dev/null || true

  # The envelope goes down a pipe: the private key never reaches a command line
  # (visible in the process table) or the environment.
  jq -n \
    --arg privateKey "$key" \
    --arg content "$content" \
    --arg relay "$RELAY" \
    --arg channelId "$channel" \
    --arg replayDir "$REPLAY_DIR" \
    --argjson timeoutMs "$TIMEOUT_MS" \
    --argjson maxCache "$MAX_CACHE" \
    '{privateKey:$privateKey, content:$content, relay:$relay, channelId:$channelId,
      replayDir:$replayDir, timeoutMs:$timeoutMs, maxCache:$maxCache}' \
    | node "$SCRIPT_DIR/fm-buzz-publish.mjs"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --refresh) REFRESH=1 ;;
    --relay) shift; RELAY=${1:-$RELAY} ;;
    --channel-label) shift; CHANNEL_LABEL=${1:-} ;;
    --timeout) shift; TIMEOUT_MS=${1:-$TIMEOUT_MS} ;;
    --help|-h)
      # Print the header comment block and stop at the first line of code, so
      # help never drifts out of sync with a hardcoded line range.
      awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    *) log "ignoring unknown argument: $1" ;;
  esac
  shift
done

if ! publish; then
  # The single conversion point: a real failure becomes a logged non-event.
  log "publish did not complete; Firstmate is unaffected"
fi

# The contract. Do not make this conditional.
exit 0
