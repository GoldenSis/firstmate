#!/usr/bin/env bash
# fm-buzz-keypair.sh - manage this home's loopback Buzz publishing keypair.
#
# Idempotent ensure: the first run mints and stores a keypair, and later runs
# derive the stored identity and refresh its public record. Store selection and
# private-key custody are owned by bin/fm-buzz-key-lib.sh. There is no flag that
# prints the private key, by design.
#
# The public key is recorded in <FM_HOME>/data/buzz-keypair.public so the value is
# readable without touching the keychain. Retired public keys are kept alongside
# it in <FM_HOME>/data/buzz-keypair.public-history, one per line. Both paths are
# gitignored: no keypair material, public or private, is ever committed.
#
# Usage:
#   fm-buzz-keypair.sh                       ensure a keypair exists; print the public key
#   fm-buzz-keypair.sh --public              print the stored identity without changing records
#   fm-buzz-keypair.sh --rotate              retire this home's key and mint a new one
#   fm-buzz-keypair.sh --rotate --compromised  as above, but do not keep the retired key
#   fm-buzz-keypair.sh --rotate --discard-pending-cache  quarantine outgoing pending events first
#   fm-buzz-keypair.sh --forget-key <hex>    withdraw one already-retired public key
#   fm-buzz-keypair.sh --forget-target <hex> attest one retired relay/channel target
#   fm-buzz-keypair.sh --forget-relay-identity <endpoint>  attest one retired relay identity
#   fm-buzz-keypair.sh --help                this text
#
# Exit status: 0 when ensure or --rotate leaves a recorded keypair, when --public
# prints an existing stored identity, or when --forget-key completes even if the
# named key was not recorded, when --forget-target removes its exact record, or
# when --forget-relay-identity retires every authority pin for its exact endpoint.
# Exit status 1 reports an operational or inconsistent-state failure, and 2
# reports invalid or contradictory arguments.
# Unlike bin/fm-buzz-publish.sh this script is NOT fire-and-forget: it is run
# deliberately, by a human, and a silent failure to create a key would be worse
# than a loud one.
#
# Rotation: Buzz documents no key-rotation procedure, so `--rotate` is this
# adapter's. It clears BOTH private stores - the keychain entry and the 0600
# fallback file - while preserving data/buzz-keypair.public as recovery evidence
# until the fresh private key is stored and that public record is atomically
# replaced. Before mutation it refuses identities whose tracked private-channel
# memberships would be stranded because M1 has no membership-transfer operation.
# bin/fm-buzz-lib.mjs owns authoritative membership queries, and
# bin/fm-buzz-targets.mjs owns tracked targets and relay-authority trust records.
# This command never prints the private key, old or new.
# Rotation also refuses while any active replay partition contains a valid event
# authored by an identity being retired, because replay authenticates only as the
# current publisher. --discard-pending-cache explicitly moves those exact entries
# into the durable replay quarantine before rotation instead of deleting them.
#
# The retired PUBLIC key is appended to data/buzz-keypair.public-history first, so
# events this home signed before the rotation stay attributable to it.
#
# It is a flag rather than instructions to run by hand because the two stores are
# not interchangeable: which one holds the key depends on the host, and the
# fallback file's name carries a digest of the home path, so hand-deleting "the
# keychain entry" on a machine whose key lives in the file clears nothing and the
# next run re-prints the SAME public key. A rotation that silently does not rotate
# is worse than no rotation procedure at all.
#
# Historical events stay signed by the retired key, which grants no authority and
# so needs no revocation. It is still evidence, though: it is a key only this home
# ever held, and bin/fm-buzz-inspect.sh --anonymous decides whether a served event
# is this home's own content by its author. So rotation retains the retired PUBLIC
# key in data/buzz-keypair.public-history rather than dropping it - a relay that
# still holds pre-rotation events would otherwise serve this home's own projections
# to a stranger and have the probe report it as somebody else's content.
#
# Retention assumes the retired key was never exposed. If retiring due to suspected
# compromise, use --compromised so the key is not retained for verdict-matching:
# a key whose private half somebody else may hold is no longer evidence that a
# served event is this home's own content, and keeping it would let that somebody
# mint an event the probe reports as this home's leaked projection.
#
# --compromised governs every identity being retired or recovered in that same
# run. It purges the current recorded key, divergent keychain and fallback-file
# identities, and an orphan record whose private material is unavailable, then
# mints one fresh key without retaining any purged identity. It cannot reach a key
# an earlier ordinary rotation already recorded. When an exposure comes to light
# after the rotation that retired the key, name the key:
#   fm-buzz-keypair.sh --forget-key <public key hex>
# withdraws exactly that key from data/buzz-keypair.public-history, leaving every
# other recorded key and this home's current key alone. It is its own operation,
# not a rotation: nothing is minted, cleared, or re-recorded.
#
# The recorded-key set is settled BEFORE the private half is cleared, and rotation
# stops if it cannot be settled. Doing it the other way round makes any write
# failure permanent: the private key is gone, so nothing can derive the retired
# public key a second time, and the probe silently loses the very attribution this
# retention exists to preserve. Stopping first leaves the rotation retryable.
#
# The replacement is likewise minted and verified BEFORE the outgoing key is
# cleared, and staged where bin/fm-buzz-key-lib.sh keeps it until it is stored and
# recorded. The two stores cannot simply be written over: the replacement may land
# in a different store than the outgoing key, so both have to be cleared first, and
# a failure inside that window would otherwise leave a public record with no
# private half - orphan recovery, out of a routine rotation. With the stage, the
# next ordinary run finishes the replacement instead.
#
# The outgoing key is only accepted as 64 lowercase hex characters. data/
# buzz-keypair.public is a cache, not the authority: every rotation derives the
# public half from the still-stored private key and compares the recorded value
# when one exists.
# Compromised recovery that cannot authenticate a recorded identity's tracked
# memberships records every affected pair in
# data/buzz-compromised-unverifiable-pairs.jsonl before replacing the key.
# When a channel or relay is truly retired, run
# `docker compose -f docker-compose.buzz-loopback.yml down -v`, run
# `fm-buzz-keypair.sh --forget-target <hex>` for every tracked target, run
# `fm-buzz-keypair.sh --forget-relay-identity <endpoint>` for every relay whose
# signer will change, and then run `fm-buzz-keypair.sh --rotate`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-buzz-key-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

REPLAY_DIR=$(fm_buzz_replay_cache_dir "$STATE") || {
  printf 'fm-buzz-keypair.sh: could not resolve the replay cache path\n' >&2
  exit 1
}

PUBLIC_FILE="$DATA/buzz-keypair.public"
HISTORY_FILE="$DATA/buzz-keypair.public-history"
TARGETS_FILE="$DATA/buzz-publisher-targets.jsonl"
AUTHORITIES_FILE="$DATA/buzz-relay-authorities.jsonl"
UNVERIFIABLE_FILE="$DATA/buzz-compromised-unverifiable-pairs.jsonl"
ROTATION_STAGE_FILE=$(fm_buzz_key_stage_file "$DATA")
OPERATION=ensure
COMPROMISED=0
DISCARD_PENDING_CACHE=0
FORGET_KEY=""
FORGET_TARGET=""
FORGET_RELAY_IDENTITY=""
STRICT_RELAY_AUTHORITY=${FM_BUZZ_REQUIRE_PINNED_RELAY_AUTHORITY:-0}

select_operation() {
  local requested=$1
  if [ "$OPERATION" = ensure ] || [ "$OPERATION" = "$requested" ]; then
    OPERATION=$requested
    return 0
  fi
  case "$OPERATION:$requested" in
    rotate:public|public:rotate)
      printf 'fm-buzz-keypair.sh: --rotate and --public are mutually exclusive\n' >&2
      ;;
    forget-key:*|*:forget-key)
      printf 'fm-buzz-keypair.sh: --forget-key is its own operation; run it on its own\n' >&2
      ;;
    forget-target:*|*:forget-target)
      printf 'fm-buzz-keypair.sh: --forget-target is its own operation; run it on its own\n' >&2
      ;;
    forget-relay-identity:*|*:forget-relay-identity)
      printf 'fm-buzz-keypair.sh: --forget-relay-identity is its own operation; run it on its own\n' >&2
      ;;
    *)
      printf 'fm-buzz-keypair.sh: operations %s and %s are mutually exclusive\n' \
        "$OPERATION" "$requested" >&2
      ;;
  esac
  exit 2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --public) select_operation public ;;
    --rotate) select_operation rotate ;;
    --compromised) COMPROMISED=1 ;;
    --discard-pending-cache) DISCARD_PENDING_CACHE=1 ;;
    # Tracked as a flag rather than by its value being non-empty: an operator who
    # typed the flag and lost its argument must get an error, never a silent fall
    # through into the default "ensure a keypair exists" behaviour.
    --forget-key) select_operation forget-key; shift; FORGET_KEY=${1:-} ;;
    --forget-target) select_operation forget-target; shift; FORGET_TARGET=${1:-} ;;
    --forget-relay-identity) select_operation forget-relay-identity; shift; FORGET_RELAY_IDENTITY=${1:-} ;;
    --help|-h) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'fm-buzz-keypair.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$COMPROMISED" -eq 1 ] && [ "$OPERATION" != rotate ]; then
  printf 'fm-buzz-keypair.sh: --compromised describes a rotation; pass it with --rotate\n' >&2
  exit 2
fi

if [ "$DISCARD_PENDING_CACHE" -eq 1 ] && [ "$OPERATION" != rotate ]; then
  printf 'fm-buzz-keypair.sh: --discard-pending-cache describes a rotation; pass it with --rotate\n' >&2
  exit 2
fi

if [ "$OPERATION" = rotate ]; then
  case $STRICT_RELAY_AUTHORITY in
    0|1) ;;
    *)
      printf 'fm-buzz-keypair.sh: FM_BUZZ_REQUIRE_PINNED_RELAY_AUTHORITY must be 0 or 1\n' >&2
      exit 1
      ;;
  esac
fi

KEYPAIR_LOCK=""
PUBLISH_LOCK=""
DELIVERY_LOCKS=()
DELIVERY_INTENT_LOCKS=()
release_keypair_lock() {
  if [ -n "$KEYPAIR_LOCK" ]; then
    fm_lock_release "$KEYPAIR_LOCK"
    KEYPAIR_LOCK=""
  fi
  if [ "${#DELIVERY_LOCKS[@]}" -gt 0 ]; then
    local index
    for ((index=${#DELIVERY_LOCKS[@]}-1; index>=0; index--)); do
      fm_lock_release "${DELIVERY_LOCKS[$index]}"
    done
    DELIVERY_LOCKS=()
  fi
  if [ "${#DELIVERY_INTENT_LOCKS[@]}" -gt 0 ]; then
    local intent_index
    for ((intent_index=${#DELIVERY_INTENT_LOCKS[@]}-1; intent_index>=0; intent_index--)); do
      fm_lock_release "${DELIVERY_INTENT_LOCKS[$intent_index]}"
    done
    DELIVERY_INTENT_LOCKS=()
  fi
  if [ -n "$PUBLISH_LOCK" ]; then
    fm_lock_release "$PUBLISH_LOCK"
    PUBLISH_LOCK=""
  fi
}

if [ "$OPERATION" != public ]; then
  mkdir -p "$DATA" 2>/dev/null || {
    printf 'fm-buzz-keypair.sh: could not create %s\n' "$DATA" >&2
    exit 1
    }
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap release_keypair_lock EXIT
  trap 'exit 1' HUP INT TERM
  # Ordering is fm-buzz-key-lib.sh's contract: whole tree, then each queue, then
  # the key. Both the ensure and the rotate paths read - and migrate - the whole
  # replay tree, so both take the first lock. Rotation and explicit target or relay
  # retirement wait for every delivery before changing identity state. Holding the
  # first for the whole run stops a queue appearing behind the enumeration below.
  mkdir -p "$STATE" 2>/dev/null || {
    printf 'fm-buzz-keypair.sh: could not create %s\n' "$STATE" >&2
    exit 1
  }
  PUBLISH_LOCK=$(fm_buzz_replay_transaction_lock "$STATE") || {
    printf 'fm-buzz-keypair.sh: could not resolve the replay cache transaction lock\n' >&2
    exit 1
  }
  fm_lock_acquire_wait "$PUBLISH_LOCK"
  if [ "$OPERATION" = rotate ] || [ "$OPERATION" = forget-target ] \
    || [ "$OPERATION" = forget-relay-identity ]; then
    for delivery_intent in "$STATE"/.buzz-replay-intent-*.lock; do
      if [ ! -e "$delivery_intent" ] && [ ! -L "$delivery_intent" ]; then
        continue
      fi
      fm_lock_acquire_wait "$delivery_intent"
      DELIVERY_INTENT_LOCKS+=("$delivery_intent")
    done
    for delivery_lock in "$STATE"/.buzz-replay-delivery-*.lock; do
      if [ ! -e "$delivery_lock" ] && [ ! -L "$delivery_lock" ]; then
        continue
      fi
      fm_lock_acquire_wait "$delivery_lock"
      DELIVERY_LOCKS+=("$delivery_lock")
    done
  fi
  KEYPAIR_LOCK=$(fm_buzz_key_transaction_lock "$DATA") || {
    printf 'fm-buzz-keypair.sh: could not resolve the key transaction lock\n' >&2
    exit 1
  }
  fm_lock_acquire_wait "$KEYPAIR_LOCK"
fi

command -v node >/dev/null 2>&1 || {
  printf 'fm-buzz-keypair.sh: node is required for key management\n' >&2
  exit 1
}

read_history() {
  local raw line normalized
  if [ ! -e "$HISTORY_FILE" ] && [ ! -L "$HISTORY_FILE" ]; then
    return 0
  fi
  [ -f "$HISTORY_FILE" ] || return 1
  raw=$(cat -- "$HISTORY_FILE") || return 1
  printf '%s\n' "$raw" |
    while IFS= read -r line || [ -n "$line" ]; do
      normalized=$(fm_buzz_normalize_public_key "$line") || continue
      printf '%s\n' "$normalized"
    done |
    awk '!seen[$0]++'
}

# Derive the public key from the stored private key without the private key ever
# reaching a command line or this script's own output: it goes straight down a
# pipe into node's stdin.
derive_public_from_store() {  # <keychain|file|selected>
  local store=$1
  case $store in
    keychain) fm_buzz_key_load_keychain "$FM_HOME" ;;
    file) fm_buzz_key_load_file "$FM_HOME" ;;
    selected) fm_buzz_key_load "$FM_HOME" ;;
    *) return 1 ;;
  esac | node -e '
    let input = "";
    process.stdin.on("data", (c) => { input += c; });
    process.stdin.on("end", async () => {
      const { publicKeyFromPrivate } = await import(process.argv[1]);
      const key = input.trim();
      if (!key) process.exit(1);
      process.stdout.write(publicKeyFromPrivate(key) + "\n");
    });
  ' "$SCRIPT_DIR/fm-buzz-crypto.mjs"
}

derive_public() {
  derive_public_from_store selected
}

publisher_is_current_channel_member() {  # <keychain|file> <relay> <channel> <timeout-ms>
  local store=$1 relay=$2 channel=$3 timeout_ms=$4
  case $store in
    keychain) fm_buzz_key_load_keychain "$FM_HOME" ;;
    file) fm_buzz_key_load_file "$FM_HOME" ;;
    *) return 1 ;;
  esac | node -e '
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", async () => {
      try {
        const { queryCurrentChannelMembership } = await import(process.argv[1]);
        const { verifyOrRecordRelayAuthority } = await import(process.argv[2]);
        const privateKey = input.trim();
        if (!privateKey) throw new Error("stored publishing key is empty");
        const membership = await queryCurrentChannelMembership(
          process.argv[3],
          privateKey,
          process.argv[4],
          Number(process.argv[5]),
        );
        verifyOrRecordRelayAuthority(process.argv[6], {
          relay: process.argv[3],
          channel_id: process.argv[4],
          signer_pubkey: membership.signerPubkey,
        }, { strict: process.argv[7] === "1" });
        process.stdout.write(membership.member ? "member\n" : "absent\n");
      } catch (error) {
        process.stderr.write(String(error.message) + "\n");
        process.exitCode = 1;
      }
    });
  ' "$SCRIPT_DIR/fm-buzz-lib.mjs" "$SCRIPT_DIR/fm-buzz-targets.mjs" \
    "$relay" "$channel" "$timeout_ms" "$AUTHORITIES_FILE" "$STRICT_RELAY_AUTHORITY"
}

check_rotation_target_membership() {  # <keychain|file> <public-key> <target-hex> <relay> <channel>
  local store=$1 public=$2 target_hex=$3 relay=$4 channel=$5 check check_key
  [ -n "$public" ] || return 0
  check_key="$public"$'\t'"$relay"$'\t'"$channel"
  printf '%s\n' "${checked_rotation_targets:-}" | grep -Fqx -- "$check_key" && return 0
  checked_rotation_targets="${checked_rotation_targets:+$checked_rotation_targets
}$check_key"
  check=$(publisher_is_current_channel_member \
    "$store" "$relay" "$channel" "$rotation_timeout" 2>&1)
  check_status=$?
  if [ "$check_status" -ne 0 ]; then
    rotation_membership_errors="${rotation_membership_errors:+$rotation_membership_errors
}fm-buzz-keypair.sh: could not verify current membership for target $target_hex, relay $relay, channel $channel: $check; nothing was rotated"
    rotation_membership_error_targets="${rotation_membership_error_targets:+$rotation_membership_error_targets
}$target_hex"$'\t'"$relay"$'\t'"$channel"
    return 0
  fi
  [ "$check" = "member" ] || return 0
  rotation_membership_blockers="${rotation_membership_blockers:+$rotation_membership_blockers
}$target_hex"$'\t'"$relay"$'\t'"$channel"
}

report_rotation_membership_results() {
  local target_hex relay channel target_public target_relay target_channel affected_results affected_relays retirement_targets
  [ -n "$rotation_membership_errors" ] && printf '%s\n' "$rotation_membership_errors" >&2
  if [ -z "$rotation_membership_blockers" ] && [ -z "$rotation_membership_error_targets" ]; then return 0; fi
  while IFS=$'\t' read -r target_hex relay channel; do
    [ -n "$target_hex" ] || continue
    printf 'fm-buzz-keypair.sh: outgoing publisher target %s has current membership on relay %s, channel %s; nothing was rotated\n' \
      "$target_hex" "$relay" "$channel" >&2
  done <<EOF
$rotation_membership_blockers
EOF
  affected_results="${rotation_membership_blockers}${rotation_membership_blockers:+
}${rotation_membership_error_targets}"
  affected_relays=$(printf '%s\n' "$affected_results" | cut -f2 | awk 'NF && !seen[$0]++')
  retirement_targets=""
  while IFS=$'\t' read -r target_hex target_public target_relay target_channel; do
    [ -n "$target_hex" ] || continue
    printf '%s\n' "$affected_relays" | grep -Fqx -- "$target_relay" || continue
    retirement_targets="${retirement_targets:+$retirement_targets
}$target_hex"
  done <<EOF
$rotation_targets
EOF
  printf '%s\n' 'Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity.' >&2
  printf '%s\n' 'If these relays or channels are truly retired, run this full recovery sequence:' >&2
  printf '%s\n' '  docker compose -f docker-compose.buzz-loopback.yml down -v' >&2
  while IFS= read -r target_hex; do
    [ -n "$target_hex" ] && printf '  fm-buzz-keypair.sh --forget-target %s\n' "$target_hex" >&2
  done <<EOF
$(printf '%s\n' "$retirement_targets" | awk 'NF && !seen[$0]++')
EOF
  while IFS= read -r relay; do
    [ -n "$relay" ] && printf '  fm-buzz-keypair.sh --forget-relay-identity %q\n' "$relay" >&2
  done <<EOF
$affected_relays
EOF
  printf '%s\n' '  fm-buzz-keypair.sh --rotate' >&2
  printf '%s\n' 'Reference: https://github.com/block/buzz/blob/main/ARCHITECTURE.md' >&2
  printf '%s\n' 'Reference: https://github.com/block/buzz/blob/main/NOSTR.md' >&2
  return 1
}

check_rotation_targets_for_store() {  # <keychain|file> <public-key>
  local store=$1 public=$2 target_hex target_public target_relay target_channel
  while IFS=$'\t' read -r target_hex target_public target_relay target_channel; do
    [ -n "$target_public" ] || continue
    [ "$target_public" = "$public" ] || continue
    check_rotation_target_membership \
      "$store" "$public" "$target_hex" "$target_relay" "$target_channel"
  done <<EOF
$rotation_targets
EOF
}

protect_rotation_replay_cache() {  # <discard:0|1> <public-key>...
  local discard=$1
  shift
  # shellcheck disable=SC2016
  node -e '
    const [modulePath, replayDir, discard, ...publishers] = process.argv.slice(1);
    import(modulePath).then(({ protectOutgoingPublisherCache }) => {
      const outcome = protectOutgoingPublisherCache(replayDir, publishers, { discard: discard === "1" });
      if (outcome.count === 0) return;
      const action = discard === "1"
        ? `quarantined ${outcome.count} outgoing-authored pending replay event(s):`
        : `pending replay cache contains ${outcome.count} outgoing-authored event(s):`;
      process.stdout.write(`${action}\n${outcome.paths.map((file) => `  ${file}`).join("\n")}\n`);
      if (discard !== "1") process.exitCode = 3;
    }).catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
  ' "$SCRIPT_DIR/fm-buzz-publish.mjs" "$REPLAY_DIR" "$discard" "$@"
}

inspect_replay_identity_evidence() {
  # shellcheck disable=SC2016
  node -e '
    const [modulePath, replayDir] = process.argv.slice(1);
    import(modulePath).then(({ inspectActiveReplayPublisherCache }) => {
      for (const entry of inspectActiveReplayPublisherCache(replayDir)) {
        process.stdout.write(`${entry.publisherPubkey}\t${entry.path}\n`);
      }
    }).catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    });
  ' "$SCRIPT_DIR/fm-buzz-publish.mjs" "$REPLAY_DIR"
}

record_public() {
  local public=$1 tmp
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 1
  tmp=$(mktemp "$DATA/.buzz-keypair-public.XXXXXX") || return 1
  printf '%s\n' "$public" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_buzz_replace_file "$tmp" "$PUBLIC_FILE" || { rm -f -- "$tmp"; return 1; }
}

# Read the stage back through the custody owner and re-derive its public half, so
# a stage whose two halves disagree is rejected rather than committed. Returns 1
# when there is no stage and 2 when the one that exists cannot be trusted.
load_rotation_stage() {
  local parsed status derived_stage
  parsed=$(fm_buzz_key_stage_read "$DATA")
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  ROTATION_STAGE_PHASE=$(printf '%s\n' "$parsed" | sed -n 1p)
  ROTATION_STAGE_PRIVATE=$(printf '%s\n' "$parsed" | sed -n 2p)
  ROTATION_STAGE_PUBLIC=$(printf '%s\n' "$parsed" | sed -n 3p)
  parsed=
  # shellcheck disable=SC2016
  derived_stage=$(printf '%s' "$ROTATION_STAGE_PRIVATE" | node -e '
    let input = "";
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", async () => {
      const { publicKeyFromPrivate } = await import(process.argv[1]);
      process.stdout.write(`${publicKeyFromPrivate(input.trim())}\n`);
    });
  ' "$SCRIPT_DIR/fm-buzz-crypto.mjs" 2>/dev/null) || return 2
  [ "$derived_stage" = "$ROTATION_STAGE_PUBLIC" ] || return 2
}

generate_rotation_stage() {
  local generated private public
  # shellcheck disable=SC2016
  generated=$(node -e '
    import(process.argv[1]).then(({ generateKeypair }) => {
      const kp = generateKeypair();
      process.stdout.write(`${kp.privateKey}\n${kp.publicKey}\n`);
    });
  ' "$SCRIPT_DIR/fm-buzz-crypto.mjs") || return 1
  private=$(printf '%s\n' "$generated" | sed -n 1p)
  public=$(printf '%s\n' "$generated" | sed -n 2p)
  generated=
  case $private in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#private}" -eq 64 ] || return 1
  case $public in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#public}" -eq 64 ] || return 1
  fm_buzz_key_stage_write "$DATA" prepared "$private" "$public" || return 1
  private=
  public=
  load_rotation_stage
}

finish_committable_rotation_stage() {
  local status current store
  fm_buzz_key_load "$FM_HOME" >/dev/null 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    current=$(derive_public) || return 1
    [ "$current" = "$ROTATION_STAGE_PUBLIC" ] || return 3
    store=existing
  elif [ "$status" -eq 1 ]; then
    store=$(fm_buzz_key_store "$FM_HOME" "$ROTATION_STAGE_PRIVATE") || return 1
    current=$(derive_public) || return 1
    [ "$current" = "$ROTATION_STAGE_PUBLIC" ] || return 1
  else
    return 1
  fi
  record_public "$ROTATION_STAGE_PUBLIC" || return 1
  fm_buzz_key_stage_clear "$DATA" || return 1
  ROTATION_STAGE_PRIVATE=""
  ROTATION_STAGE_PHASE=""
  ROTATION_STAGE_STORE=$store
}

# Replace the history file's contents. Whole-file rewrite through a temp file and
# one `mv`, for the same reason record_public does it: a rotation interrupted
# midway must leave either the old history or the new one, never a half-written
# one. Nothing left to record means no file, rather than a file holding a blank
# line.
write_history() {  # <whole file contents, possibly empty>
  local content=$1 tmp
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 1
  fm_buzz_file_target_replaceable "$HISTORY_FILE" || return 1
  if [ -z "$content" ]; then
    rm -f -- "$HISTORY_FILE" || return 1
    return 0
  fi
  tmp=$(mktemp "$DATA/.buzz-keypair-public-history.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_buzz_replace_file "$tmp" "$HISTORY_FILE" || { rm -f -- "$tmp"; return 1; }
}

# Carry the outgoing public key into the history file before the rotation drops
# it. Duplicates and blank lines are collapsed, so re-running a rotation cannot
# grow the file without bound.
retain_public() {  # <retired public key>
  local retired=$1 merged
  [ -n "$retired" ] || return 0
  retired=$(fm_buzz_normalize_public_key "$retired") || return 1
  merged=$(read_history) || return 1
  merged="${merged:+$merged
}$retired"
  merged=$(printf '%s\n' "$merged" | awk 'NF && !seen[$0]++') || return 1
  write_history "$merged"
}

# The mirror of retain_public, for a key that is not evidence of anything because
# its private half may have leaked: whoever holds it can sign an event the probe
# would otherwise report as this home's own leaked projection. Such a key must
# leave the recorded set rather than join it. Called for the key a --compromised
# rotation is retiring, and by --forget-key for one named by hand.
purge_public_set() {  # <public keys to withdraw...>
  local public normalized drops="" merged
  for public in "$@"; do
    [ -n "$public" ] || continue
    normalized=$(fm_buzz_normalize_public_key "$public") || return 1
    case ",$drops," in
      *,"$normalized",*) ;;
      *) drops="${drops:+$drops,}$normalized" ;;
    esac
  done
  [ -n "$drops" ] || return 0
  merged=$(read_history) || return 1
  merged=$(printf '%s\n' "$merged" | awk -v drops="$drops" '
    BEGIN {
      count = split(drops, keys, ",")
      for (i = 1; i <= count; i++) drop[keys[i]] = 1
    }
    NF && !drop[$0] && !seen[$0]++
  ') || return 1
  write_history "$merged"
}

purge_public() {  # <public key to withdraw>
  purge_public_set "$1"
}

run_forget_relay_identity_operation() {
  if [ -z "$FORGET_RELAY_IDENTITY" ]; then
    printf 'fm-buzz-keypair.sh: --forget-relay-identity wants a relay endpoint\n' >&2
    exit 2
  fi
  forgotten_relay=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" forget-relay-identity \
    "$TARGETS_FILE" "$AUTHORITIES_FILE" "$FORGET_RELAY_IDENTITY" 2>&1)
  forgotten_relay_status=$?
  if [ "$forgotten_relay_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not forget relay identity: %s; nothing was changed\n' \
      "$forgotten_relay" >&2
    exit 1
  fi
  IFS=$'\t' read -r forgotten_relay_endpoint forgotten_relay_count <<EOF
$forgotten_relay
EOF
  printf 'forgotten relay identity: %s (%s authority record(s))\n' \
    "$forgotten_relay_endpoint" "$forgotten_relay_count" >&2
  exit 0
}

run_forget_target_operation() {
  case $FORGET_TARGET in
    ""|*[!0-9a-f]*)
      printf 'fm-buzz-keypair.sh: --forget-target wants a canonical 64-character lowercase target hex\n' >&2
      exit 2
      ;;
  esac
  if [ "${#FORGET_TARGET}" -ne 64 ]; then
    printf 'fm-buzz-keypair.sh: --forget-target wants a canonical 64-character lowercase target hex\n' >&2
    exit 2
  fi
  forgotten_target=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" forget-target \
    "$TARGETS_FILE" "$FORGET_TARGET" 2>&1)
  forgotten_target_status=$?
  if [ "$forgotten_target_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not forget publisher target %s: %s; nothing was changed\n' \
      "$FORGET_TARGET" "$forgotten_target" >&2
    exit 1
  fi
  IFS=$'\t' read -r forgotten_hex forgotten_public forgotten_relay forgotten_channel <<EOF
$forgotten_target
EOF
  printf 'forgotten target: %s publisher %s relay %s channel %s\n' \
    "$forgotten_hex" "$forgotten_public" "$forgotten_relay" "$forgotten_channel" >&2
  exit 0
}

# --forget-key: withdraw one already-retired key from the recorded set. This is
# what --compromised cannot be, and the reason it is a separate operation: a
# rotation only ever holds the key it is retiring right now, so an exposure
# discovered later has to name the key it means. Nothing is minted or cleared
# here, and no key material is read - it is a rewrite of one public-key list.
run_forget_key_operation() {
  forget=$(fm_buzz_normalize_public_key "$FORGET_KEY") || {
    printf 'fm-buzz-keypair.sh: --forget-key wants a 64-character hex public key\n' >&2
    exit 2
  }

  history=$(read_history) || {
    printf 'fm-buzz-keypair.sh: could not read %s; nothing was changed\n' "$HISTORY_FILE" >&2
    exit 1
  }
  printf '%s\n' "$history" | grep -qx -- "$forget" >/dev/null 2>&1
  history_match=$?
  if [ "$history_match" -gt 1 ]; then
    printf 'fm-buzz-keypair.sh: could not read %s; nothing was changed\n' "$HISTORY_FILE" >&2
    exit 1
  fi
  if [ "$history_match" -eq 0 ]; then
    purge_public "$forget" || {
      printf 'fm-buzz-keypair.sh: could not withdraw the key from %s; nothing was changed\n' "$HISTORY_FILE" >&2
      exit 1
    }
    printf 'forgotten: %s is no longer recorded as a key of this home\n' "$forget" >&2
  else
    printf 'fm-buzz-keypair.sh: %s is not in %s; nothing to withdraw\n' "$forget" "$HISTORY_FILE" >&2
  fi

  # The current key is not in that list, so withdrawing it there says nothing
  # about it. Rotation is what retires a current key, and only --compromised
  # keeps it out of the recorded set.
  current=$(fm_buzz_normalize_public_key "$(sed -n 1p "$PUBLIC_FILE" 2>/dev/null)" 2>/dev/null) || current=""
  if [ -n "$current" ] && [ "$current" = "$forget" ]; then
    printf 'fm-buzz-keypair.sh: %s is still this home'"'"'s CURRENT publishing key; retire it with --rotate --compromised\n' "$forget" >&2
  fi
  exit 0
}

case $OPERATION in
  forget-relay-identity) run_forget_relay_identity_operation ;;
  forget-target) run_forget_target_operation ;;
  forget-key) run_forget_key_operation ;;
esac

add_recovery_reason() {  # <reason>
  if [ -n "$recovery_reason" ]; then
    recovery_reason="$recovery_reason; $1"
  else
    recovery_reason=$1
  fi
}

ROTATION_STAGE_PHASE=""
ROTATION_STAGE_PRIVATE=""
ROTATION_STAGE_PUBLIC=""
if [ -e "$ROTATION_STAGE_FILE" ] || [ -L "$ROTATION_STAGE_FILE" ]; then
  load_rotation_stage || {
    printf 'fm-buzz-keypair.sh: rotation stage %s is invalid; nothing was changed\n' \
      "$ROTATION_STAGE_FILE" >&2
    exit 1
  }
fi
if [ "$ROTATION_STAGE_PHASE" = committable ] && [ "$OPERATION" != public ]; then
  finish_committable_rotation_stage
  stage_finish_status=$?
  if [ "$stage_finish_status" -eq 0 ]; then
    printf 'recovered: completed staged buzz publishing key replacement (private key stored in %s)\n' \
      "$ROTATION_STAGE_STORE" >&2
    printf '%s\n' "$ROTATION_STAGE_PUBLIC"
    exit 0
  fi
  if [ "$stage_finish_status" -ne 3 ] || [ "$OPERATION" != rotate ]; then
    printf 'fm-buzz-keypair.sh: could not complete staged replacement %s; retry with --rotate\n' \
      "$ROTATION_STAGE_FILE" >&2
    exit 1
  fi
fi

run_rotate_operation() {
  fm_buzz_file_target_replaceable "$PUBLIC_FILE" || {
    printf 'fm-buzz-keypair.sh: public key record target %s is not a regular file; nothing was rotated\n' "$PUBLIC_FILE" >&2
    exit 1
  }
  fm_buzz_file_target_replaceable "$HISTORY_FILE" || {
    printf 'fm-buzz-keypair.sh: public key history target %s is not a regular file; nothing was rotated\n' "$HISTORY_FILE" >&2
    exit 1
  }
  recorded=$(fm_buzz_normalize_public_key "$(sed -n 1p "$PUBLIC_FILE" 2>/dev/null)" 2>/dev/null) || recorded=""
  keychain_public=""
  file_public=""
  derived=""
  retiring=""
  recovery_reason=""
  fm_buzz_key_load_keychain "$FM_HOME" >/dev/null 2>&1
  keychain_status=$?
  fm_buzz_key_load_file "$FM_HOME" >/dev/null 2>&1
  file_status=$?
  key_file=$(fm_buzz_key_fallback_file "$FM_HOME") || key_file="the fallback key file"

  case $keychain_status in
    0)
      keychain_public=$(fm_buzz_normalize_public_key "$(derive_public_from_store keychain 2>/dev/null)" 2>/dev/null) || keychain_public=""
      [ -n "$keychain_public" ] || add_recovery_reason "the private key in the login keychain could not be used to derive its public key"
      ;;
    1) ;;
    2) add_recovery_reason "the publishing key in the login keychain could not be read" ;;
    *) add_recovery_reason "the publishing key in the login keychain could not be inspected" ;;
  esac

  case $file_status in
    0)
      file_public=$(fm_buzz_normalize_public_key "$(derive_public_from_store file 2>/dev/null)" 2>/dev/null) || file_public=""
      [ -n "$file_public" ] || add_recovery_reason "publishing key file $key_file could not be used to derive its public key"
      ;;
    1) ;;
    3) add_recovery_reason "publishing key file $key_file could not be read" ;;
    *) add_recovery_reason "publishing key file $key_file could not be inspected" ;;
  esac

  if [ -n "$keychain_public" ] && [ -n "$file_public" ] && [ "$keychain_public" != "$file_public" ]; then
    add_recovery_reason "stored keys diverge: keychain public key $keychain_public, fallback public key $file_public"
  elif [ -n "$keychain_public" ]; then
    derived=$keychain_public
  elif [ -n "$file_public" ]; then
    derived=$file_public
  fi

  if [ -n "$derived" ] && [ -n "$recorded" ] && [ "$recorded" != "$derived" ]; then
    add_recovery_reason "the recorded public key in $PUBLIC_FILE does not match the stored private key"
  elif [ -n "$derived" ] && [ -z "$recovery_reason" ]; then
    retiring=$derived
  elif [ "$keychain_status" -eq 1 ] && [ "$file_status" -eq 1 ] \
    && { [ -e "$PUBLIC_FILE" ] || [ -L "$PUBLIC_FILE" ]; }; then
    add_recovery_reason "the recorded public key in $PUBLIC_FILE has no stored private key"
  fi

  rotation_targets=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" list-with-ids "$TARGETS_FILE" 2>&1)
  rotation_targets_status=$?
  if [ "$rotation_targets_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not validate %s: %s; nothing was rotated\n' \
      "$TARGETS_FILE" "$rotation_targets" >&2
    exit 1
  fi
  rotation_replay_evidence=$(inspect_replay_identity_evidence 2>&1)
  rotation_replay_status=$?
  if [ "$rotation_replay_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not inspect replay identity evidence: %s; nothing was rotated\n' \
      "$rotation_replay_evidence" >&2
    exit 1
  fi
  orphan_identity_mode=0
  if [ -z "$keychain_public" ] && [ -z "$file_public" ] && [ -z "$recorded" ]; then
    if [ -n "$rotation_targets" ]; then
      orphan_identity_mode=1
      orphan_target_ids=$(printf '%s\n' "$rotation_targets" | cut -f1 | paste -sd, -)
      add_recovery_reason "orphan publisher target records are present: $orphan_target_ids"
    fi
    if [ -n "$rotation_replay_evidence" ]; then
      orphan_identity_mode=1
      orphan_replay_paths=$(printf '%s\n' "$rotation_replay_evidence" | cut -f2- | paste -sd, -)
      add_recovery_reason "orphan replay entries are present: $orphan_replay_paths"
    fi
  fi

  if [ -n "$recovery_reason" ]; then
    if [ "$COMPROMISED" -eq 0 ]; then
      printf 'fm-buzz-keypair.sh: %s; nothing was rotated\n' "$recovery_reason" >&2
      exit 1
    fi
    printf 'rotating compromised key: %s; no outgoing public key will be retained\n' "$recovery_reason" >&2
  fi

  rotation_relay=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" normalize-relay \
    "${FM_BUZZ_RELAY:-ws://localhost:3000}" 2>&1)
  rotation_relay_status=$?
  if [ "$rotation_relay_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: configured relay is invalid: %s; nothing was rotated\n' \
      "$rotation_relay" >&2
    exit 1
  fi
  rotation_timeout=${FM_BUZZ_TIMEOUT_MS:-15000}
  checked_rotation_targets=""
  rotation_membership_errors=""
  rotation_membership_error_targets=""
  rotation_membership_blockers=""
  if [ -n "$keychain_public" ]; then
    check_rotation_targets_for_store keychain "$keychain_public"
  fi
  if [ -n "$file_public" ]; then
    check_rotation_targets_for_store file "$file_public"
  fi
  report_rotation_membership_results || exit 1

  rotation_publics=()
  rotation_candidate_publics=$(printf '%s\n%s\n%s\n' "$recorded" "$keychain_public" "$file_public")
  if [ "$orphan_identity_mode" -eq 1 ]; then
    rotation_candidate_publics="${rotation_candidate_publics}
$(printf '%s\n' "$rotation_targets" | cut -f2)
$(printf '%s\n' "$rotation_replay_evidence" | cut -f1)"
  fi
  while IFS= read -r candidate_public; do
    [ -n "$candidate_public" ] || continue
    seen_public=0
    if [ "${#rotation_publics[@]}" -gt 0 ]; then
      for known_public in "${rotation_publics[@]}"; do
        [ "$known_public" = "$candidate_public" ] && seen_public=1
      done
    fi
    [ "$seen_public" -eq 1 ] || rotation_publics+=("$candidate_public")
  done <<EOF
$rotation_candidate_publics
EOF
  if [ "${#rotation_publics[@]}" -gt 0 ]; then
    cache_preflight=$(protect_rotation_replay_cache \
      "$DISCARD_PENDING_CACHE" "${rotation_publics[@]}" 2>&1)
    cache_preflight_status=$?
    if [ "$cache_preflight_status" -eq 3 ]; then
      printf 'fm-buzz-keypair.sh: %s\nnothing was rotated; drain the queue or retry with --discard-pending-cache\n' \
        "$cache_preflight" >&2
      exit 1
    fi
    if [ "$cache_preflight_status" -ne 0 ]; then
      printf 'fm-buzz-keypair.sh: could not verify outgoing replay cache state: %s; nothing was rotated\n' \
        "$cache_preflight" >&2
      exit 1
    fi
    [ -n "$cache_preflight" ] && printf '%s\n' "$cache_preflight" >&2
  fi

  if [ -z "$ROTATION_STAGE_PHASE" ]; then
    generate_rotation_stage || {
      printf 'fm-buzz-keypair.sh: replacement key generation or staging failed; the outgoing private key remains stored\n' >&2
      exit 1
    }
  fi
  for candidate_public in "${rotation_publics[@]}"; do
    if [ "$candidate_public" = "$ROTATION_STAGE_PUBLIC" ]; then
      # Discard the offending stage, but only while the outgoing key is still
      # stored: keeping it would make every retry re-read the same collision and
      # wedge the rotation, and dropping a committable one would throw away the
      # only copy of a key the home already depends on.
      if [ "$ROTATION_STAGE_PHASE" = prepared ]; then
        fm_buzz_key_stage_clear "$DATA" || true
      fi
      printf 'fm-buzz-keypair.sh: staged replacement matches an outgoing identity; nothing was rotated\n' >&2
      exit 1
    fi
  done

  unverifiable_pairs=""
  unverifiable_publics=()
  if [ "$COMPROMISED" -eq 1 ] && [ -n "$recovery_reason" ]; then
    while IFS=$'\t' read -r _target_hex target_public _target_relay _target_channel; do
      [ -n "$target_public" ] || continue
      implicated_public=0
      for known_public in "${rotation_publics[@]}"; do
        [ "$known_public" = "$target_public" ] && implicated_public=1
      done
      [ "$implicated_public" -eq 1 ] || continue
      [ "$target_public" = "$keychain_public" ] && continue
      [ "$target_public" = "$file_public" ] && continue
      seen_public=0
      if [ "${#unverifiable_publics[@]}" -gt 0 ]; then
        for known_public in "${unverifiable_publics[@]}"; do
          [ "$known_public" = "$target_public" ] && seen_public=1
        done
      fi
      [ "$seen_public" -eq 1 ] || unverifiable_publics+=("$target_public")
    done <<EOF
$rotation_targets
EOF
  fi
  if [ "${#unverifiable_publics[@]}" -gt 0 ]; then
    unverifiable_pairs=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" retire-unverifiable \
      "$TARGETS_FILE" "$UNVERIFIABLE_FILE" "$recovery_reason" \
      "${unverifiable_publics[@]}" 2>&1)
    unverifiable_status=$?
    if [ "$unverifiable_status" -ne 0 ]; then
      printf 'fm-buzz-keypair.sh: could not retire unverifiable compromised memberships into %s: %s; nothing was rotated\n' \
        "$UNVERIFIABLE_FILE" "$unverifiable_pairs" >&2
      exit 1
    fi
  fi

  # Settle the recorded-key set while the private half is still stored, and stop
  # if it cannot be settled: after fm_buzz_key_forget there is no second chance to
  # learn what this home was publishing under, so a failure here would silently
  # and permanently cost the probe its attribution. A rotation that stops now is
  # simply retryable - nothing has changed yet.
  if [ "$COMPROMISED" -eq 1 ]; then
    purge_public_set "${rotation_publics[@]}" || {
      printf 'fm-buzz-keypair.sh: could not drop the compromised public keys from %s; nothing was rotated\n' "$HISTORY_FILE" >&2
      exit 1
    }
    if [ -n "$retiring" ]; then
      printf 'rotating: the retired public key is treated as compromised and is not kept in %s\n' "$HISTORY_FILE" >&2
    fi
  elif [ -n "$retiring" ]; then
    retain_public "$retiring" || {
      printf 'fm-buzz-keypair.sh: could not retain the retired public key in %s; nothing was rotated\n' "$HISTORY_FILE" >&2
      exit 1
    }
  elif [ "$keychain_status" -eq 1 ] && [ "$file_status" -eq 1 ]; then
    printf 'fm-buzz-keypair.sh: no key is stored for this home; there is nothing to retire\n' >&2
  fi

  fm_buzz_key_stage_write "$DATA" committable "$ROTATION_STAGE_PRIVATE" "$ROTATION_STAGE_PUBLIC" || {
    printf 'fm-buzz-keypair.sh: could not commit the staged replacement transaction; the outgoing private key remains stored\n' >&2
    exit 1
  }
  ROTATION_STAGE_PHASE=committable

  cleared=$(fm_buzz_key_forget "$FM_HOME") || {
    printf 'fm-buzz-keypair.sh: could not verify removal of the old key from every store; nothing was replaced\n' >&2
    exit 1
  }
  if [ -n "$cleared" ]; then
    printf 'rotated: cleared the previous key from %s\n' "$(printf '%s' "$cleared" | tr '\n' ' ' | sed 's/ $//')" >&2
  else
    printf 'fm-buzz-keypair.sh: no previous key was stored for this home; minting one\n' >&2
  fi

  store=$(fm_buzz_key_store "$FM_HOME" "$ROTATION_STAGE_PRIVATE") || {
    printf 'fm-buzz-keypair.sh: could not install the staged replacement key; retry to recover from %s\n' \
      "$ROTATION_STAGE_FILE" >&2
    exit 1
  }
  installed_public=$(derive_public) || {
    printf 'fm-buzz-keypair.sh: staged replacement was stored but its public half could not be derived; retry is safe\n' >&2
    exit 1
  }
  if [ "$installed_public" != "$ROTATION_STAGE_PUBLIC" ]; then
    printf 'fm-buzz-keypair.sh: stored replacement does not match the staged identity; retry is required\n' >&2
    exit 1
  fi
  record_public "$ROTATION_STAGE_PUBLIC" || {
    printf 'fm-buzz-keypair.sh: could not record %s; the private key remains stored for a safe retry in the staged replacement\n' \
      "$PUBLIC_FILE" >&2
    exit 1
  }
  fm_buzz_key_stage_clear "$DATA" || {
    printf 'fm-buzz-keypair.sh: replacement was installed but %s could not be cleared; retry is required\n' \
      "$ROTATION_STAGE_FILE" >&2
    exit 1
  }
  printf 'created: buzz publishing keypair (private key stored in %s)\n' "$store" >&2
  if [ -n "${unverifiable_pairs:-}" ]; then
    printf 'WARNING: compromised recovery could not authenticate these memberships for the retired identity; they may be stranded and are recorded in %s:\n%s\n' \
      "$UNVERIFIABLE_FILE" "$unverifiable_pairs" >&2
  fi
  printf '%s\n' "$ROTATION_STAGE_PUBLIC"
  exit 0
}

run_ensure_or_public_operation() {
fm_buzz_key_load "$FM_HOME" >/dev/null 2>&1
load_status=$?
if [ "$load_status" -eq 0 ]; then
  public=$(derive_public) || {
    printf 'fm-buzz-keypair.sh: a key is stored but its public half could not be derived\n' >&2
    exit 1
  }
  if [ "$OPERATION" = public ]; then
    printf '%s\n' "$public"
    exit 0
  fi
  # Re-record on every ensure: cheap, and it self-heals a deleted or truncated file.
  record_public "$public" || {
    printf 'fm-buzz-keypair.sh: could not record %s; the private key remains stored for a safe retry\n' "$PUBLIC_FILE" >&2
    exit 1
  }
  printf '%s\n' "$public"
  exit 0
fi

if [ "$load_status" -eq 2 ]; then
  printf 'fm-buzz-keypair.sh: the publishing key in the login keychain could not be read\n' >&2
  exit 1
fi

if [ "$load_status" -eq 3 ]; then
  key_file=$(fm_buzz_key_fallback_file "$FM_HOME") || key_file="the fallback key file"
  printf 'fm-buzz-keypair.sh: publishing key file %s could not be read\n' "$key_file" >&2
  exit 1
fi

if [ -e "$PUBLIC_FILE" ] || [ -L "$PUBLIC_FILE" ]; then
  printf 'fm-buzz-keypair.sh: the recorded public key in %s has no stored private key; recover with --rotate --compromised\n' "$PUBLIC_FILE" >&2
  exit 1
fi

if [ "$OPERATION" = public ]; then
  printf 'fm-buzz-keypair.sh: no keypair exists yet; run without --public to create one\n' >&2
  exit 1
fi

if [ "$OPERATION" = ensure ]; then
  ensure_targets=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" list-with-ids "$TARGETS_FILE" 2>&1)
  ensure_targets_status=$?
  if [ "$ensure_targets_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not validate %s: %s; no replacement identity was minted\n' \
      "$TARGETS_FILE" "$ensure_targets" >&2
    exit 1
  fi
  ensure_replay_evidence=$(inspect_replay_identity_evidence 2>&1)
  ensure_replay_status=$?
  if [ "$ensure_replay_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not inspect replay identity evidence: %s; no replacement identity was minted\n' \
      "$ensure_replay_evidence" >&2
    exit 1
  fi
  if [ -n "$ensure_targets" ] || [ -n "$ensure_replay_evidence" ]; then
    printf 'fm-buzz-keypair.sh: orphan identity evidence exists without readable current key material; recover with --rotate --compromised\n' >&2
    if [ -n "$ensure_targets" ]; then
      printf 'orphan publisher target records present:\n%s\n' "$ensure_targets" >&2
    fi
    if [ -n "$ensure_replay_evidence" ]; then
      printf 'orphan replay entries present:\n%s\n' "$ensure_replay_evidence" >&2
    fi
    exit 1
  fi
fi

# Mint a fresh keypair. Node emits two lines - private then public - and only the
# public line is ever shown or written to a file.
generated=$(node -e '
  import(process.argv[1]).then(({ generateKeypair }) => {
    const kp = generateKeypair();
    process.stdout.write(kp.privateKey + "\n" + kp.publicKey + "\n");
  });
' "$SCRIPT_DIR/fm-buzz-crypto.mjs") || {
  printf 'fm-buzz-keypair.sh: key generation failed\n' >&2
  exit 1
}

private=$(printf '%s\n' "$generated" | sed -n 1p)
public=$(printf '%s\n' "$generated" | sed -n 2p)
generated=

case $private in
  [0-9a-f]*) : ;;
  *) printf 'fm-buzz-keypair.sh: generated key is malformed\n' >&2; exit 1 ;;
esac
[ "${#private}" -eq 64 ] || { printf 'fm-buzz-keypair.sh: generated key has the wrong length\n' >&2; exit 1; }

store=$(fm_buzz_key_store "$FM_HOME" "$private") || {
  private=
  printf 'fm-buzz-keypair.sh: could not store the private key in the keychain or the fallback file\n' >&2
  exit 1
}
private=

record_public "$public" || {
  printf 'fm-buzz-keypair.sh: could not record %s; the private key remains stored for a safe retry\n' "$PUBLIC_FILE" >&2
  exit 1
}
printf 'created: buzz publishing keypair (private key stored in %s)\n' "$store" >&2
if [ -n "${unverifiable_pairs:-}" ]; then
  printf 'WARNING: compromised recovery could not authenticate these memberships for the retired identity; they may be stranded and are recorded in %s:\n%s\n' \
    "$UNVERIFIABLE_FILE" "$unverifiable_pairs" >&2
fi
printf '%s\n' "$public"
}

case $OPERATION in
  rotate) run_rotate_operation ;;
  ensure|public) run_ensure_or_public_operation ;;
  *)
    printf 'fm-buzz-keypair.sh: internal error: unhandled operation %s\n' "$OPERATION" >&2
    exit 1
    ;;
esac
