#!/usr/bin/env bash
# fm-buzz-keypair.sh - create this home's loopback Buzz publishing keypair, once.
#
# Idempotent: the first run mints a keypair and stores the private half in the OS
# keychain; every later run finds it and just prints the public key. There is no
# flag that prints the private key, by design - see bin/fm-buzz-key-lib.sh, which
# owns custody and explains the reasoning.
#
# The public key is recorded in <FM_HOME>/data/buzz-keypair.public so the value is
# readable without touching the keychain. That path is gitignored: no keypair
# material, public or private, is ever committed.
#
# Usage:
#   fm-buzz-keypair.sh             ensure a keypair exists; print the public key
#   fm-buzz-keypair.sh --public    print the public key; fail if none exists yet
#   fm-buzz-keypair.sh --help      this text
#
# Exit status: 0 when a keypair exists (created or already present), 1 on a real
# failure (no key material could be stored, or --public with no keypair). Unlike
# bin/fm-buzz-publish.sh this script is NOT fire-and-forget: it is run
# deliberately, by a human, and a silent failure to create a key would be worse
# than a loud one.
#
# Rotation: Buzz documents no key-rotation procedure. Rotating this key therefore
# means deleting the keychain entry (`security delete-generic-password -s
# firstmate-buzz -a "<FM_HOME>"`) plus data/buzz-keypair.public and re-running
# this script. Historical events stay signed by the retired key, which is
# acceptable precisely because this key grants no authority.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-buzz-key-lib.sh
. "$SCRIPT_DIR/fm-buzz-key-lib.sh"

PUBLIC_FILE="$DATA/buzz-keypair.public"
PUBLIC_ONLY=0

while [ "$#" -gt 0 ]; do
  case $1 in
    --public) PUBLIC_ONLY=1 ;;
    --help|-h) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'fm-buzz-keypair.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

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
