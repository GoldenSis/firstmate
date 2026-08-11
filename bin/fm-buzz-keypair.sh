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
#   fm-buzz-keypair.sh --help                this text
#
# Exit status: 0 when ensure or --rotate leaves a recorded keypair, when --public
# prints an existing stored identity, or when --forget-key completes even if the
# named key was not recorded.
# Exit status 1 reports an operational or inconsistent-state failure, and 2
# reports invalid or contradictory arguments.
# Unlike bin/fm-buzz-publish.sh this script is NOT fire-and-forget: it is run
# deliberately, by a human, and a silent failure to create a key would be worse
# than a loud one.
#
# Rotation: Buzz documents no key-rotation procedure, so `--rotate` is this
# adapter's. It clears BOTH stores - the keychain entry and the 0600 fallback
# file - plus data/buzz-keypair.public, then mints a fresh keypair and prints the
# new public key. Before mutation it checks every used relay/channel pair
# recorded by bin/fm-buzz-targets.mjs, refusing when the
# outgoing publisher appears in the relay's current membership state because M1
# has no membership-transfer operation. The first valid membership snapshot pins
# its signer in data/buzz-relay-authorities.jsonl, and later checks require that
# same signer. It never prints the private key, old or new.
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
# The outgoing key is only accepted as 64 lowercase hex characters. data/
# buzz-keypair.public is a cache, not the authority: every rotation derives the
# public half from the still-stored private key and compares the recorded value
# when one exists.
# Compromised recovery that cannot authenticate a recorded identity's tracked
# memberships records every affected pair in
# data/buzz-compromised-unverifiable-pairs.jsonl before replacing the key.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REPLAY_DIR="${FM_BUZZ_REPLAY_DIR:-$STATE/buzz-replay}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

PUBLIC_FILE="$DATA/buzz-keypair.public"
HISTORY_FILE="$DATA/buzz-keypair.public-history"
TARGETS_FILE="$DATA/buzz-publisher-targets.jsonl"
AUTHORITIES_FILE="$DATA/buzz-relay-authorities.jsonl"
UNVERIFIABLE_FILE="$DATA/buzz-compromised-unverifiable-pairs.jsonl"
PUBLIC_ONLY=0
ROTATE=0
COMPROMISED=0
DISCARD_PENDING_CACHE=0
FORGET_KEY=""
FORGETTING=0
STRICT_RELAY_AUTHORITY=${FM_BUZZ_REQUIRE_PINNED_RELAY_AUTHORITY:-0}

while [ "$#" -gt 0 ]; do
  case $1 in
    --public) PUBLIC_ONLY=1 ;;
    --rotate) ROTATE=1 ;;
    --compromised) COMPROMISED=1 ;;
    --discard-pending-cache) DISCARD_PENDING_CACHE=1 ;;
    # Tracked as a flag rather than by its value being non-empty: an operator who
    # typed the flag and lost its argument must get an error, never a silent fall
    # through into the default "ensure a keypair exists" behaviour.
    --forget-key) FORGETTING=1; shift; FORGET_KEY=${1:-} ;;
    --help|-h) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'fm-buzz-keypair.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$ROTATE" -eq 1 ] && [ "$PUBLIC_ONLY" -eq 1 ]; then
  printf 'fm-buzz-keypair.sh: --rotate and --public are mutually exclusive\n' >&2
  exit 2
fi

if [ "$COMPROMISED" -eq 1 ] && [ "$ROTATE" -eq 0 ]; then
  printf 'fm-buzz-keypair.sh: --compromised describes a rotation; pass it with --rotate\n' >&2
  exit 2
fi

if [ "$DISCARD_PENDING_CACHE" -eq 1 ] && [ "$ROTATE" -eq 0 ]; then
  printf 'fm-buzz-keypair.sh: --discard-pending-cache describes a rotation; pass it with --rotate\n' >&2
  exit 2
fi

if [ "$FORGETTING" -eq 1 ] && { [ "$ROTATE" -eq 1 ] || [ "$PUBLIC_ONLY" -eq 1 ]; }; then
  printf 'fm-buzz-keypair.sh: --forget-key is its own operation; run it on its own\n' >&2
  exit 2
fi

if [ "$ROTATE" -eq 1 ]; then
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
release_keypair_lock() {
  if [ -n "$KEYPAIR_LOCK" ]; then
    fm_lock_release "$KEYPAIR_LOCK"
    KEYPAIR_LOCK=""
  fi
  if [ -n "$PUBLISH_LOCK" ]; then
    fm_lock_release "$PUBLISH_LOCK"
    PUBLISH_LOCK=""
  fi
}

if [ "$PUBLIC_ONLY" -eq 0 ]; then
  mkdir -p "$DATA" 2>/dev/null || {
    printf 'fm-buzz-keypair.sh: could not create %s\n' "$DATA" >&2
    exit 1
  }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap release_keypair_lock EXIT
  trap 'exit 1' HUP INT TERM
  if [ "$ROTATE" -eq 1 ]; then
    mkdir -p "$STATE" 2>/dev/null || {
      printf 'fm-buzz-keypair.sh: could not create %s\n' "$STATE" >&2
      exit 1
    }
    PUBLISH_LOCK=$(fm_buzz_replay_transaction_lock "$STATE") || {
      printf 'fm-buzz-keypair.sh: could not resolve the replay cache transaction lock\n' >&2
      exit 1
    }
    fm_lock_acquire_wait "$PUBLISH_LOCK"
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

refuse_rotation_for_current_membership() {  # <keychain|file> <public-key> <relay> <channel>
  local store=$1 public=$2 relay=$3 channel=$4 check check_key
  [ -n "$public" ] || return 0
  check_key="$public"$'\t'"$relay"$'\t'"$channel"
  printf '%s\n' "${checked_rotation_targets:-}" | grep -Fqx -- "$check_key" && return 0
  checked_rotation_targets="${checked_rotation_targets:+$checked_rotation_targets
}$check_key"
  check=$(publisher_is_current_channel_member \
    "$store" "$relay" "$channel" "$rotation_timeout" 2>&1)
  check_status=$?
  if [ "$check_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not verify current membership for relay %s, channel %s: %s; nothing was rotated\n' \
      "$relay" "$channel" "$check" >&2
    return 1
  fi
  [ "$check" = "member" ] || return 0
  printf 'fm-buzz-keypair.sh: outgoing publisher has current membership on relay %s, channel %s; nothing was rotated\n' \
    "$relay" "$channel" >&2
  printf '%s\n' 'Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity.' >&2
  printf '%s\n' 'Reference: https://github.com/block/buzz/blob/main/ARCHITECTURE.md' >&2
  printf '%s\n' 'Reference: https://github.com/block/buzz/blob/main/NOSTR.md' >&2
  return 1
}

check_rotation_targets_for_store() {  # <keychain|file> <public-key>
  local store=$1 public=$2 target_public target_relay target_channel
  while IFS=$'\t' read -r target_public target_relay target_channel; do
    [ -n "$target_public" ] || continue
    [ "$target_public" = "$public" ] || continue
    refuse_rotation_for_current_membership \
      "$store" "$public" "$target_relay" "$target_channel" || return 1
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

record_public() {
  local public=$1 tmp
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 1
  tmp=$(mktemp "$DATA/.buzz-keypair-public.XXXXXX") || return 1
  printf '%s\n' "$public" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_buzz_replace_file "$tmp" "$PUBLIC_FILE" || { rm -f -- "$tmp"; return 1; }
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

# --forget-key: withdraw one already-retired key from the recorded set. This is
# what --compromised cannot be, and the reason it is a separate operation: a
# rotation only ever holds the key it is retiring right now, so an exposure
# discovered later has to name the key it means. Nothing is minted or cleared
# here, and no key material is read - it is a rewrite of one public-key list.
if [ "$FORGETTING" -eq 1 ]; then
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
fi

add_recovery_reason() {  # <reason>
  if [ -n "$recovery_reason" ]; then
    recovery_reason="$recovery_reason; $1"
  else
    recovery_reason=$1
  fi
}

# Retire the old key before the lookup below, so rotation falls through into the
# minting path instead of finding the key it was asked to replace.
if [ "$ROTATE" -eq 1 ]; then
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
  rotation_targets=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" list "$TARGETS_FILE" 2>&1)
  rotation_targets_status=$?
  if [ "$rotation_targets_status" -ne 0 ]; then
    printf 'fm-buzz-keypair.sh: could not validate %s: %s; nothing was rotated\n' \
      "$TARGETS_FILE" "$rotation_targets" >&2
    exit 1
  fi
  checked_rotation_targets=""
  if [ -n "$keychain_public" ]; then
    check_rotation_targets_for_store keychain "$keychain_public" || exit 1
  fi
  if [ -n "$file_public" ]; then
    check_rotation_targets_for_store file "$file_public" || exit 1
  fi

  rotation_publics=()
  for candidate_public in "$recorded" "$keychain_public" "$file_public"; do
    [ -n "$candidate_public" ] || continue
    seen_public=0
    if [ "${#rotation_publics[@]}" -gt 0 ]; then
      for known_public in "${rotation_publics[@]}"; do
        [ "$known_public" = "$candidate_public" ] && seen_public=1
      done
    fi
    [ "$seen_public" -eq 1 ] || rotation_publics+=("$candidate_public")
  done
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

  unverifiable_pairs=""
  if [ "$COMPROMISED" -eq 1 ] && [ -n "$recovery_reason" ] && [ -n "$recorded" ] \
    && [ "$recorded" != "$keychain_public" ] && [ "$recorded" != "$file_public" ]; then
    unverifiable_pairs=$(node "$SCRIPT_DIR/fm-buzz-targets.mjs" record-unverifiable \
      "$TARGETS_FILE" "$UNVERIFIABLE_FILE" "$recorded" "$recovery_reason" 2>&1)
    unverifiable_status=$?
    if [ "$unverifiable_status" -ne 0 ]; then
      printf 'fm-buzz-keypair.sh: could not record unverifiable compromised memberships in %s: %s; nothing was rotated\n' \
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
    purge_public_set "$recorded" "$keychain_public" "$file_public" || {
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

  cleared=$(fm_buzz_key_forget "$FM_HOME") || {
    printf 'fm-buzz-keypair.sh: could not verify removal of the old key from every store; nothing was replaced\n' >&2
    exit 1
  }
  if [ -n "$cleared" ]; then
    printf 'rotated: cleared the previous key from %s\n' "$(printf '%s' "$cleared" | tr '\n' ' ' | sed 's/ $//')" >&2
  else
    printf 'fm-buzz-keypair.sh: no previous key was stored for this home; minting one\n' >&2
  fi
  rm -f -- "$PUBLIC_FILE" || {
    printf 'fm-buzz-keypair.sh: could not remove stale public key record %s; no replacement was minted\n' "$PUBLIC_FILE" >&2
    exit 1
  }
fi

fm_buzz_key_load "$FM_HOME" >/dev/null 2>&1
load_status=$?
if [ "$load_status" -eq 0 ]; then
  public=$(derive_public) || {
    printf 'fm-buzz-keypair.sh: a key is stored but its public half could not be derived\n' >&2
    exit 1
  }
  if [ "$PUBLIC_ONLY" -eq 1 ]; then
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

if [ "$PUBLIC_ONLY" -eq 1 ]; then
  printf 'fm-buzz-keypair.sh: no keypair exists yet; run without --public to create one\n' >&2
  exit 1
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
