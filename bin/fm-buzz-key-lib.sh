#!/usr/bin/env bash
# fm-buzz-key-lib.sh - custody of the loopback Buzz publishing key.
#
# Sourced by bin/fm-buzz-keypair.sh (which creates the key) and
# bin/fm-buzz-publish.sh (which spends it). The single owner of WHERE the private
# key lives and how it is fetched, so the two callers cannot drift into different
# storage assumptions.
#
# CUSTODY MODEL
# Preferred store is the OS keychain, matching what Buzz's own desktop client
# does. On macOS that is `security add-generic-password` against the login
# keychain. When no keychain is reachable - headless Linux, CI, a locked keychain -
# the fallback is a 0600 file under ${XDG_DATA_HOME:-~/.local/share}/firstmate/.
# The fallback is written only after the keychain path has been tried and failed,
# and it is never consulted in preference to a keychain entry that exists.
#
# ONE KEY PER HOME
# The keychain account is the resolved FM_HOME path, so a secondmate home with its
# own FM_HOME gets its own key and its own channel rather than silently publishing
# under the main home's identity.
#
# fm_buzz_key_load PRINTS THE PRIVATE KEY ON STDOUT. That is how a shell function
# returns a value, and it is the reason this is a library and not a CLI: its
# output must be piped straight into the consumer and must never be echoed,
# logged, put in a command line (visible in the process table), or captured into a
# variable that later gets printed. bin/fm-buzz-keypair.sh deliberately exposes no
# flag that prints it. The publishing key is low-value by construction - it signs
# fleet-status projections on a loopback relay and grants no authority, since
# merge authority stays in bin/fm-pr-merge.sh per AGENTS.md section 7 - but low
# value is not no value, and leaking it into a log would be a real defect.

FM_BUZZ_KEYCHAIN_SERVICE=firstmate-buzz

# The account label identifying this home's key inside the keychain.
fm_buzz_key_account() {
  local home=${1:?home required}
  local resolved
  resolved=$(cd "$home" 2>/dev/null && pwd -P) || resolved=$home
  printf '%s\n' "$resolved"
}

# True when a macOS-style `security` keychain CLI is usable.
# FM_BUZZ_FORCE_FILE_STORE=1 forces the file fallback. That exists for the test
# suite, which must not write into the developer's real login keychain, and for
# headless runs where a keychain exists but is locked.
fm_buzz_keychain_available() {
  [ "${FM_BUZZ_FORCE_FILE_STORE:-0}" = "1" ] && return 1
  [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1
}

# The 0600 fallback file for hosts with no reachable keychain.
fm_buzz_key_fallback_file() {
  local base=${XDG_DATA_HOME:-$HOME/.local/share}
  printf '%s/firstmate/buzz-keypair.json\n' "$base"
}

# Print the stored private key, or return 1 when none is stored. Read the header
# before adding a caller: the output must go into a pipe.
fm_buzz_key_load() {
  local home=${1:?home required} account file
  account=$(fm_buzz_key_account "$home")
  if fm_buzz_keychain_available; then
    if security find-generic-password -s "$FM_BUZZ_KEYCHAIN_SERVICE" -a "$account" -w 2>/dev/null; then
      return 0
    fi
  fi
  file=$(fm_buzz_key_fallback_file)
  if [ -f "$file" ]; then
    # Single-key file; a missing/blank field means the file is unusable rather
    # than that no key exists, so fail closed instead of returning an empty key.
    local value
    value=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p' "$file" | head -1)
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  return 1
}

# Store a private key. Tries the keychain first and falls back to a 0600 file.
# Returns 1 if neither store could be written, so the caller can refuse to
# pretend a key was persisted.
fm_buzz_key_store() {
  local home=${1:?home required} private=${2:?private key required} account file dir
  account=$(fm_buzz_key_account "$home")
  if fm_buzz_keychain_available; then
    # -U updates an existing entry instead of failing, which keeps a re-run after
    # a partial failure idempotent. -w takes the secret without echoing it.
    if security add-generic-password -U \
      -s "$FM_BUZZ_KEYCHAIN_SERVICE" -a "$account" \
      -l "firstmate buzz publishing key" \
      -w "$private" 2>/dev/null; then
      printf 'keychain\n'
      return 0
    fi
  fi
  file=$(fm_buzz_key_fallback_file)
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  local tmp
  umask 077
  tmp=$(mktemp "$dir/.buzz-keypair.XXXXXX") || return 1
  printf '{\n  "private_key": "%s"\n}\n' "$private" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  printf 'file\n'
}
