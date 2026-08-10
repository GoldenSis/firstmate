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
#   fm-buzz-keypair.sh             ensure a keypair exists; print the public key
#   fm-buzz-keypair.sh --public    print the public key; fail if none exists yet
#   fm-buzz-keypair.sh --rotate    retire this home's key and mint a new one
#   fm-buzz-keypair.sh --help      this text
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

while [ "$#" -gt 0 ]; do
  case $1 in
    --public) PUBLIC_ONLY=1 ;;
    --rotate) ROTATE=1 ;;
    --help|-h) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'fm-buzz-keypair.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$ROTATE" -eq 1 ] && [ "$PUBLIC_ONLY" -eq 1 ]; then
  printf 'fm-buzz-keypair.sh: --rotate and --public are mutually exclusive\n' >&2
  exit 2
fi

command -v node >/dev/null 2>&1 || {
  printf 'fm-buzz-keypair.sh: node is required to derive the public key\n' >&2
  exit 1
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

# Carry the outgoing public key into the history file before the rotation drops
# it. Whole-file rewrite through a temp file and one `mv`, for the same reason
# record_public does it: a rotation interrupted midway must leave either the old
# history or the new one, never a half-written one. Duplicates and blank lines are
# collapsed, so re-running a rotation cannot grow the file without bound.
retain_public() {  # <retired public key>
  local retired=$1 merged tmp
  [ -n "$retired" ] || return 0
  if [ -f "$HISTORY_FILE" ]; then
    merged=$(cat -- "$HISTORY_FILE") || return 1
    merged="$merged
$retired"
  else
    merged=$retired
  fi
  merged=$(printf '%s\n' "$merged" | awk 'NF && !seen[$0]++') || return 1
  [ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null || return 1
  tmp=$(mktemp "$DATA/.buzz-keypair-public-history.XXXXXX") || return 1
  printf '%s\n' "$merged" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$HISTORY_FILE" || { rm -f -- "$tmp"; return 1; }
}

# Retire the old key before the lookup below, so rotation falls through into the
# minting path instead of finding the key it was asked to replace.
if [ "$ROTATE" -eq 1 ]; then
  # Read the outgoing public key while the private half is still stored: the
  # recorded file is the cheap source, but it can be missing or truncated, and the
  # stored key is the authority for what this home was publishing under. Once
  # fm_buzz_key_forget runs there is nothing left to derive it from.
  retiring=$(sed -n 1p "$PUBLIC_FILE" 2>/dev/null | tr -d '[:space:]')
  [ -n "$retiring" ] || retiring=$(derive_public 2>/dev/null | tr -d '[:space:]')
  cleared=$(fm_buzz_key_forget "$FM_HOME") || {
    printf 'fm-buzz-keypair.sh: the old key is still readable after rotation; nothing was replaced\n' >&2
    exit 1
  }
  if [ -n "$cleared" ]; then
    printf 'rotated: cleared the previous key from %s\n' "$(printf '%s' "$cleared" | tr '\n' ' ' | sed 's/ $//')" >&2
  else
    printf 'fm-buzz-keypair.sh: no previous key was stored for this home; minting one\n' >&2
  fi
  retain_public "$retiring" \
    || printf 'fm-buzz-keypair.sh: could not retain the retired public key in %s\n' "$HISTORY_FILE" >&2
  rm -f -- "$PUBLIC_FILE"
fi

if fm_buzz_key_load "$FM_HOME" >/dev/null 2>&1; then
  public=$(derive_public) || {
    printf 'fm-buzz-keypair.sh: a key is stored but its public half could not be derived\n' >&2
    exit 1
  }
  # Re-record on every run: cheap, and it self-heals a deleted or truncated file.
  record_public "$public" || printf 'fm-buzz-keypair.sh: could not record %s\n' "$PUBLIC_FILE" >&2
  printf '%s\n' "$public"
  exit 0
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
