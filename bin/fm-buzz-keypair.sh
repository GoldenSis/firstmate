#!/usr/bin/env bash
# fm-buzz-keypair.sh - create this home's loopback Buzz publishing keypair, once.
#
# Idempotent: the first run mints a keypair and stores the private half in the OS
# keychain; every later run finds it and just prints the public key. There is no
# flag that prints the private key, by design - see bin/fm-buzz-key-lib.sh, which
# owns custody and explains the reasoning.
#
# The public key is recorded in <FM_HOME>/data/buzz-keypair.public so the value is
# readable without touching the keychain. Retired public keys are kept alongside
# it in <FM_HOME>/data/buzz-keypair.public-history, one per line. Both paths are
# gitignored: no keypair material, public or private, is ever committed.
#
# Usage:
#   fm-buzz-keypair.sh                       ensure a keypair exists; print the public key
#   fm-buzz-keypair.sh --public              print the public key; fail if none exists yet
#   fm-buzz-keypair.sh --rotate              retire this home's key and mint a new one
#   fm-buzz-keypair.sh --rotate --compromised  as above, but do not keep the retired key
#   fm-buzz-keypair.sh --forget-key <hex>    withdraw one already-retired public key
#   fm-buzz-keypair.sh --help                this text
#
# Exit status: 0 when a keypair exists (created or already present), 1 on a real
# failure (no key material could be stored, or --public with no keypair). Unlike
# bin/fm-buzz-publish.sh this script is NOT fire-and-forget: it is run
# deliberately, by a human, and a silent failure to create a key would be worse
# than a loud one.
#
# Rotation: Buzz documents no key-rotation procedure, so `--rotate` is this
# adapter's. It clears BOTH stores - the keychain entry and the 0600 fallback
# file - plus data/buzz-keypair.public, then mints a fresh keypair and prints the
# new public key. It never prints the private key, old or new.
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
# --compromised governs ONLY the key that rotation is retiring in that same run.
# It cannot reach a key an earlier ordinary rotation already recorded, because
# every rotation mints a fresh random key and so retires a different one. When an
# exposure comes to light after the rotation that retired the key, name the key:
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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

PUBLIC_FILE="$DATA/buzz-keypair.public"
HISTORY_FILE="$DATA/buzz-keypair.public-history"
PUBLIC_ONLY=0
ROTATE=0
COMPROMISED=0
FORGET_KEY=""
FORGETTING=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --public) PUBLIC_ONLY=1 ;;
    --rotate) ROTATE=1 ;;
    --compromised) COMPROMISED=1 ;;
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

if [ "$FORGETTING" -eq 1 ] && { [ "$ROTATE" -eq 1 ] || [ "$PUBLIC_ONLY" -eq 1 ]; }; then
  printf 'fm-buzz-keypair.sh: --forget-key is its own operation; run it on its own\n' >&2
  exit 2
fi

# A public key is 64 lowercase hex characters and nothing else. Anything else is
# not a key, however plausible it looks: a half-written or truncated recorded file
# is exactly the case this rejects.
is_public_key() {  # <candidate>
  local key=$1
  [ "${#key}" -eq 64 ] || return 1
  case $key in *[!0-9a-f]*) return 1 ;; esac
}

# Read a recorded public key the way both the recorded file and an operator's
# argument may spell it, and echo nothing at all when it is not a key.
normalize_public_key() {  # <candidate>
  local key
  key=$(printf '%s' "$1" | tr -d '[:space:]' | tr 'A-F' 'a-f')
  is_public_key "$key" || return 1
  printf '%s\n' "$key"
}

# Derive the public key from the stored private key without the private key ever
# reaching a command line or this script's own output: it goes straight down a
# pipe into node's stdin.
derive_public() {
  fm_buzz_key_load "$FM_HOME" | node -e '
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

record_public() {
  local public=$1 tmp
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 1
  tmp=$(mktemp "$DATA/.buzz-keypair-public.XXXXXX") || return 1
  printf '%s\n' "$public" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$PUBLIC_FILE" || { rm -f -- "$tmp"; return 1; }
}

# Replace the history file's contents. Whole-file rewrite through a temp file and
# one `mv`, for the same reason record_public does it: a rotation interrupted
# midway must leave either the old history or the new one, never a half-written
# one. Nothing left to record means no file, rather than a file holding a blank
# line.
write_history() {  # <whole file contents, possibly empty>
  local content=$1 tmp
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 1
  if [ -z "$content" ]; then
    rm -f -- "$HISTORY_FILE" || return 1
    return 0
  fi
  tmp=$(mktemp "$DATA/.buzz-keypair-public-history.XXXXXX") || return 1
  printf '%s\n' "$content" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$HISTORY_FILE" || { rm -f -- "$tmp"; return 1; }
}

# Carry the outgoing public key into the history file before the rotation drops
# it. Duplicates and blank lines are collapsed, so re-running a rotation cannot
# grow the file without bound.
retain_public() {  # <retired public key>
  local retired=$1 merged
  [ -n "$retired" ] || return 0
  if [ -f "$HISTORY_FILE" ]; then
    merged=$(cat -- "$HISTORY_FILE") || return 1
    merged="$merged
$retired"
  else
    merged=$retired
  fi
  merged=$(printf '%s\n' "$merged" | awk 'NF && !seen[$0]++') || return 1
  write_history "$merged"
}

# The mirror of retain_public, for a key that is not evidence of anything because
# its private half may have leaked: whoever holds it can sign an event the probe
# would otherwise report as this home's own leaked projection. Such a key must
# leave the recorded set rather than join it. Called for the key a --compromised
# rotation is retiring, and by --forget-key for one named by hand.
purge_public() {  # <public key to withdraw>
  local retired=$1 merged
  [ -n "$retired" ] || return 0
  [ -f "$HISTORY_FILE" ] || return 0
  merged=$(awk -v drop="$retired" 'NF && $0 != drop && !seen[$0]++' "$HISTORY_FILE") || return 1
  write_history "$merged"
}

# --forget-key: withdraw one already-retired key from the recorded set. This is
# what --compromised cannot be, and the reason it is a separate operation: a
# rotation only ever holds the key it is retiring right now, so an exposure
# discovered later has to name the key it means. Nothing is minted or cleared
# here, and no key material is read - it is a rewrite of one public-key list.
if [ "$FORGETTING" -eq 1 ]; then
  forget=$(normalize_public_key "$FORGET_KEY") || {
    printf 'fm-buzz-keypair.sh: --forget-key wants a 64-character hex public key\n' >&2
    exit 2
  }

  if [ -f "$HISTORY_FILE" ] && grep -qx -- "$forget" "$HISTORY_FILE" 2>/dev/null; then
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
  current=$(normalize_public_key "$(sed -n 1p "$PUBLIC_FILE" 2>/dev/null)" 2>/dev/null) || current=""
  if [ -n "$current" ] && [ "$current" = "$forget" ]; then
    printf 'fm-buzz-keypair.sh: %s is still this home'"'"'s CURRENT publishing key; retire it with --rotate --compromised\n' "$forget" >&2
  fi
  exit 0
fi

command -v node >/dev/null 2>&1 || {
  printf 'fm-buzz-keypair.sh: node is required to derive the public key\n' >&2
  exit 1
}

# Retire the old key before the lookup below, so rotation falls through into the
# minting path instead of finding the key it was asked to replace.
if [ "$ROTATE" -eq 1 ]; then
  recorded=$(normalize_public_key "$(sed -n 1p "$PUBLIC_FILE" 2>/dev/null)" 2>/dev/null) || recorded=""
  derived=""
  retiring=""
  recovery_reason=""
  fm_buzz_key_load "$FM_HOME" >/dev/null 2>&1
  load_status=$?
  key_file=""
  if [ "$load_status" -eq 3 ]; then
    key_file=$(fm_buzz_key_fallback_file "$FM_HOME") || key_file=""
  fi

  case $load_status in
    0)
      derived=$(normalize_public_key "$(derive_public 2>/dev/null)" 2>/dev/null) || derived=""
      if [ -z "$derived" ]; then
        recovery_reason="the stored private key could not be used to derive its public key"
      elif [ -n "$recorded" ] && [ "$recorded" != "$derived" ]; then
        recovery_reason="the recorded public key in $PUBLIC_FILE does not match the stored private key"
      else
        retiring=$derived
      fi
      ;;
    1) ;;
    2) recovery_reason="the publishing key in the login keychain could not be read" ;;
    3)
      recovery_reason="publishing key file $key_file could not be read"
      ;;
    *) recovery_reason="the stored publishing key could not be read" ;;
  esac

  if [ -n "$recovery_reason" ]; then
    if [ "$COMPROMISED" -eq 0 ]; then
      printf 'fm-buzz-keypair.sh: %s; nothing was rotated\n' "$recovery_reason" >&2
      exit 1
    fi
    printf 'rotating compromised key: %s; no outgoing public key will be retained\n' "$recovery_reason" >&2
  fi

  # Settle the recorded-key set while the private half is still stored, and stop
  # if it cannot be settled: after fm_buzz_key_forget there is no second chance to
  # learn what this home was publishing under, so a failure here would silently
  # and permanently cost the probe its attribution. A rotation that stops now is
  # simply retryable - nothing has changed yet.
  if [ "$COMPROMISED" -eq 1 ]; then
    purge_public "$recorded" || {
      printf 'fm-buzz-keypair.sh: could not drop the compromised public key from %s; nothing was rotated\n' "$HISTORY_FILE" >&2
      exit 1
    }
    if [ -n "$derived" ] && [ "$derived" != "$recorded" ]; then
      purge_public "$derived" || {
        printf 'fm-buzz-keypair.sh: could not drop the compromised public key from %s; nothing was rotated\n' "$HISTORY_FILE" >&2
        exit 1
      }
    fi
    if [ -n "$retiring" ]; then
      printf 'rotating: the retired public key is treated as compromised and is not kept in %s\n' "$HISTORY_FILE" >&2
    fi
  elif [ -n "$retiring" ]; then
    retain_public "$retiring" || {
      printf 'fm-buzz-keypair.sh: could not retain the retired public key in %s; nothing was rotated\n' "$HISTORY_FILE" >&2
      exit 1
    }
  elif [ "$load_status" -eq 1 ]; then
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
  rm -f -- "$PUBLIC_FILE"
fi

fm_buzz_key_load "$FM_HOME" >/dev/null 2>&1
load_status=$?
if [ "$load_status" -eq 0 ]; then
  public=$(derive_public) || {
    printf 'fm-buzz-keypair.sh: a key is stored but its public half could not be derived\n' >&2
    exit 1
  }
  # Re-record on every run: cheap, and it self-heals a deleted or truncated file.
  record_public "$public" || printf 'fm-buzz-keypair.sh: could not record %s\n' "$PUBLIC_FILE" >&2
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

record_public "$public" || printf 'fm-buzz-keypair.sh: could not record %s\n' "$PUBLIC_FILE" >&2
printf 'created: buzz publishing keypair (private key stored in %s)\n' "$store" >&2
printf '%s\n' "$public"
