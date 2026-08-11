#!/usr/bin/env bash
# fm-buzz-key-lib.sh - shared shell helpers for the loopback Buzz adapter.
#
# Sourced by bin/fm-buzz-keypair.sh (which creates the key), bin/fm-buzz-publish.sh
# (which spends it) and bin/fm-buzz-inspect.sh (which reads with it). Its main job
# is custody: the single owner of WHERE the private key lives and how it is
# fetched, so the callers cannot drift into different storage assumptions. It also
# owns the small helpers more than one of those entry points needs, for the same
# anti-drift reason.
#
# CUSTODY MODEL
# Preferred store is the OS keychain, matching what Buzz's own desktop client
# does. On macOS that is `security add-generic-password` against the login
# keychain. Normal loading fails closed when that keychain is present but
# inaccessible, and does not consult the file fallback in that state.
# FM_BUZZ_FORCE_FILE_STORE=1 explicitly selects the fallback for normal loads and
# stores. A normal write tries the keychain first and uses the 0600 file under
# ${XDG_DATA_HOME:-~/.local/share}/firstmate/ only when keychain storage is
# unavailable. Rotation inspects and clears both stores independently.
#
# ONE KEY PER HOME
# Both stores key on the resolved FM_HOME path - the keychain through its account
# attribute, the fallback file through a digest of that same account baked into
# the filename - so a secondmate home with its own FM_HOME gets its own key and
# its own channel rather than silently publishing under the main home's identity.
# The two stores must agree on this or the invariant would hold only on macOS.
#
# ROTATION CLEARS BOTH STORES
# fm_buzz_key_forget is the one supported way to retire a key, and it clears the
# keychain entry AND the fallback file, then verifies nothing loads any more.
# Which store holds the key depends on the host, so anything that clears only one
# of them is a rotation that may silently not rotate.
#
# THE KEY NEVER REACHES AN ARGV
# A command line is world-readable through the process table, so no helper here
# may pass the private key as an argument to anything. Storing it goes through
# `security -i`, which reads its command line off stdin - `add-generic-password -w
# <secret>` typed into a pipe leaves the secret out of the `security` process's
# own argv, and it still reports the underlying error status, so the fallback to
# the file store keeps working. (`-w` with the value omitted is not usable here:
# it prompts, which hangs under automation.) Reading goes through
# fm_buzz_key_load, whose output must be piped straight into the consumer -
# never echoed, logged, put in a command line, or captured into a variable that
# later gets printed. bin/fm-buzz-keypair.sh deliberately exposes no flag that
# prints it. The publishing key is low-value by construction - it signs
# fleet-status projections on a loopback relay and grants no authority, since
# merge authority stays in bin/fm-pr-merge.sh per AGENTS.md section 7 - but low
# value is not no value, and leaking it into a log would be a real defect.

FM_BUZZ_KEYCHAIN_SERVICE=firstmate-buzz

# LOCK ORDERING
# Four locks guard this adapter, and every holder takes them in this order and
# releases them in the reverse one. Anything else can deadlock publishing against
# rotation, both of which need more than one of them.
#
#   1. fm_buzz_replay_transaction_lock  - the whole replay tree. Migration and
#      quarantine walk paths no single channel owns, so they need it; publishing
#      holds it only for that walk and drops it before the network.
#   2. fm_buzz_replay_delivery_intent   - one invocation entering a queue. It is
#      registered under the whole-tree barrier and retained until delivery ends,
#      so retirement sees publishers waiting behind an already-busy queue without
#      forcing those waiters to convoy unrelated channels on the whole-tree lock.
#   3. fm_buzz_replay_delivery_lock     - one endpoint-and-channel queue. Held
#      across signing, caching, and delivery, which is the slow part. Scoping it
#      per queue is the point: a channel whose relay is unreachable must not spend
#      another channel's bounded acquisition deadline.
#   4. fm_buzz_key_transaction_lock     - this home's key material. Rotation and
#      the publisher's key capture are mutually exclusive, so a compromised
#      rotation cannot withdraw an identity a delayed publish is about to sign as.
#
# Rotation holds 1 while it waits for every existing 2 and 3, so no invocation can
# appear behind its inventory. Publishing takes 1 and 2, releases 1 before waiting
# for 3, then takes 4 only through signing and durable caching. Dropping a
# lower-numbered lock early is safe; re-taking one while holding a higher one is
# not.
fm_buzz_key_transaction_lock() {  # <data directory>
  local data=${1:?data directory required}
  printf '%s/.buzz-keypair.lock\n' "$data"
}

fm_buzz_replay_transaction_lock() {  # <state directory>
  local state=${1:?state directory required}
  printf '%s/.buzz-replay-publish.lock\n' "$state"
}

fm_buzz_replay_delivery_intent() {  # <state directory> <normalized relay> <channel id> <pid>
  local state=${1:?state directory required} relay=${2:?normalized relay required}
  local channel=${3:?channel id required} owner=${4:?owner pid required} digest
  digest=$(printf '%s\n%s' "$relay" "$channel" | fm_buzz_key_sha256) || return 1
  [ -n "$digest" ] || return 1
  case $owner in ''|*[!0-9]*) return 1 ;; esac
  printf '%s/.buzz-replay-intent-%s-%s.lock\n' "$state" "$digest" "$owner"
}

# The digest covers the complete normalized endpoint AND the channel id, matching
# how the cache itself is partitioned, so two channels on one relay - and one
# channel on two relays - never share a delivery lock.
fm_buzz_replay_delivery_lock() {  # <state directory> <normalized relay> <channel id>
  local state=${1:?state directory required} relay=${2:?normalized relay required}
  local channel=${3:?channel id required} digest
  digest=$(printf '%s\n%s' "$relay" "$channel" | fm_buzz_key_sha256) || return 1
  [ -n "$digest" ] || return 1
  printf '%s/.buzz-replay-delivery-%s.lock\n' "$state" "$digest"
}

# Print the one authoritative replay-cache path shared by publishing and key
# rotation. An environment override would let the two operations inspect
# different queues and retire an identity whose events still need it.
fm_buzz_replay_cache_dir() {  # <state directory>
  local state=${1:?state directory required}
  printf '%s/buzz-replay\n' "$state"
}

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
fm_buzz_keychain_present() {
  [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1
}

fm_buzz_keychain_available() {
  [ "${FM_BUZZ_FORCE_FILE_STORE:-0}" = "1" ] && return 1
  fm_buzz_keychain_present
}

# SHA-256 of stdin, hex. Same shape as bin/fm-prototype.sh and bin/fm-fusion-gate.sh.
fm_buzz_key_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# Run a helper and keep its two streams apart: stdout becomes the captured value
# and stderr becomes the captured diagnostic. `$(helper 2>&1)` is the shape this
# replaces, and it is wrong for anything whose stdout is data - a single unrelated
# line on stderr, an interpreter warning from a globally set NODE_OPTIONS being the
# realistic one, would otherwise become part of a public key, a target record, a
# relay name or a lock digest on the SUCCESS path, where no caller inspects it.
# Both results are assigned in the caller's shell, so this is invoked as a plain
# command rather than inside a command substitution. A failing helper that says
# nothing on stderr still gets a message: its stdout stands in, which is what the
# merged form used to report.
FM_BUZZ_CAPTURED_OUTPUT=""
FM_BUZZ_CAPTURED_DIAGNOSTIC=""
fm_buzz_capture() {  # <command> [argument...]
  local status stderr_file
  FM_BUZZ_CAPTURED_OUTPUT=""
  FM_BUZZ_CAPTURED_DIAGNOSTIC=""
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-buzz-stderr.XXXXXX") || {
    FM_BUZZ_CAPTURED_DIAGNOSTIC="could not create a temporary file for helper diagnostics"
    return 1
  }
  FM_BUZZ_CAPTURED_OUTPUT=$("$@" 2>"$stderr_file")
  status=$?
  FM_BUZZ_CAPTURED_DIAGNOSTIC=$(cat -- "$stderr_file" 2>/dev/null)
  rm -f -- "$stderr_file"
  if [ "$status" -ne 0 ] && [ -z "$FM_BUZZ_CAPTURED_DIAGNOSTIC" ]; then
    FM_BUZZ_CAPTURED_DIAGNOSTIC=$FM_BUZZ_CAPTURED_OUTPUT
  fi
  return "$status"
}

fm_buzz_normalize_public_key() {
  local key
  key=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr 'A-F' 'a-f')
  [ "${#key}" -eq 64 ] || return 1
  case $key in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$key"
}

fm_buzz_current_public_record_read() {  # <file>
  local file=${1:?public record required} record
  [ -f "$file" ] || return 1
  record=$(sed -n 1p "$file") || return 1
  [ "${#record}" -eq 64 ] || return 1
  case $record in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$record" | cmp -s - "$file" || return 1
  printf '%s\n' "$record"
}

fm_buzz_public_history_read() {  # <file>
  local file=${1:?public history required} raw line normalized history=""
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  [ -f "$file" ] || return 1
  raw=$(cat -- "$file") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    normalized=$(fm_buzz_normalize_public_key "$line") || return 1
    case $'\n'"$history"$'\n' in
      *$'\n'"$normalized"$'\n'*) ;;
      *) history="${history:+$history
}$normalized" ;;
    esac
  done <<EOF
$raw
EOF
  [ -z "$history" ] || printf '%s\n' "$history"
}

# The 0600 fallback file for hosts with no reachable keychain.
#
# The filename carries a digest of the home account, not a fixed name: two homes
# frequently share one XDG_DATA_HOME (it follows the user, not FM_HOME), and a
# fixed name would hand a secondmate the main home's key on every non-Darwin host
# and on every FM_BUZZ_FORCE_FILE_STORE=1 run - breaking ONE KEY PER HOME exactly
# where the keychain is not there to enforce it. A digest rather than the path
# itself because a home path can be longer than a filename may be.
fm_buzz_key_fallback_file() {
  local home=${1:?home required} base account digest
  base=${XDG_DATA_HOME:-$HOME/.local/share}
  account=$(fm_buzz_key_account "$home")
  digest=$(printf '%s' "$account" | fm_buzz_key_sha256) || return 1
  [ -n "$digest" ] || return 1
  printf '%s/firstmate/buzz-keypair-%s.json\n' "$base" "${digest:0:16}"
}

# Emit a `security -i` command word: double-quoted, with the two characters that
# parser treats as special (\ and ") escaped. Keeps a home path containing a space
# from splitting into two arguments.
fm_buzz_security_word() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}

# Print the keychain private key. Return 1 when the keychain or entry is absent,
# and 2 when the keychain exists but cannot be read.
fm_buzz_key_load_keychain() {
  local home=${1:?home required} account rc
  fm_buzz_keychain_present || return 1
  account=$(fm_buzz_key_account "$home")
  if security find-generic-password -s "$FM_BUZZ_KEYCHAIN_SERVICE" -a "$account" -w 2>/dev/null; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 44 ] && return 1
  return 2
}

fm_buzz_private_record_read() {  # <fallback|stage> <file>
  local kind=${1:?record kind required} file=${2:?file required}
  # shellcheck disable=SC2016
  node -e '
    const { closeSync, constants, fstatSync, openSync, readFileSync } = require("node:fs");
    const [kind, file] = process.argv.slice(1);
    if (typeof constants.O_NOFOLLOW !== "number") process.exit(43);
    let descriptor;
    try {
      descriptor = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
    } catch (error) {
      process.exit(error?.code === "ENOENT" ? 42 : 43);
    }
    try {
      const metadata = fstatSync(descriptor);
      if (!metadata.isFile() || (metadata.mode & 0o777) !== 0o600) process.exit(43);
      const value = JSON.parse(readFileSync(descriptor, "utf8"));
      if (kind === "fallback") {
        if (!/^[0-9a-fA-F]{64}$/.test(value?.private_key ?? "")) process.exit(43);
        process.stdout.write(`${value.private_key}\n`);
      } else if (kind === "stage") {
        if (!value || !["prepared", "committable"].includes(value.phase)) process.exit(43);
        if (!/^[0-9a-f]{64}$/.test(value.private_key ?? "")) process.exit(43);
        if (!/^[0-9a-f]{64}$/.test(value.public_key ?? "")) process.exit(43);
        const rotationIntent = value.rotation_intent ??
          (value.phase === "committable" ? "ordinary" : null);
        if (!["ordinary", "compromised"].includes(rotationIntent)) process.exit(43);
        process.stdout.write(`${value.phase}\n${value.private_key}\n${value.public_key}\n${rotationIntent}\n`);
      } else {
        process.exit(43);
      }
    } catch {
      process.exit(43);
    } finally {
      closeSync(descriptor);
    }
  ' "$kind" "$file"
}

# Print the fallback private key. Return 1 when the file is absent, and 3 when it
# exists but cannot be read as a key.
fm_buzz_key_load_file() {
  local home=${1:?home required} file rc
  file=$(fm_buzz_key_fallback_file "$home") || return 1
  fm_buzz_private_record_read fallback "$file"
  rc=$?
  case $rc in
    0) return 0 ;;
    42) return 1 ;;
    *) return 3 ;;
  esac
}

# Print the preferred stored private key. Return 1 when none is stored, 2 when
# the keychain cannot be read, and 3 when the fallback file exists but cannot be
# read as a key. Read the header before adding a caller: the output must go into a
# pipe.
fm_buzz_key_load() {
  local home=${1:?home required} rc
  if fm_buzz_keychain_available; then
    fm_buzz_key_load_keychain "$home"
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  fi
  fm_buzz_key_load_file "$home"
}

fm_buzz_file_target_replaceable() {
  local target=${1:?target required}
  if { [ -e "$target" ] || [ -L "$target" ]; } && [ ! -f "$target" ]; then
    return 1
  fi
}

fm_buzz_replace_file() {
  local source=${1:?source required} target=${2:?target required}
  fm_buzz_file_target_replaceable "$target" || return 1
  node -e '
    const { renameSync } = require("node:fs");
    renameSync(process.argv[1], process.argv[2]);
  ' "$source" "$target" >/dev/null 2>&1
}

# Store a private key. Tries the keychain first and falls back to a 0600 file.
# Returns 1 if neither store could be written, so the caller can refuse to
# pretend a key was persisted.
fm_buzz_key_store() {
  local home=${1:?home required} private=${2:?private key required} account file dir
  account=$(fm_buzz_key_account "$home")
  if fm_buzz_keychain_available; then
    # -U updates an existing entry instead of failing, which keeps a re-run after
    # a partial failure idempotent. The whole command line goes down `security -i`
    # on stdin so the secret never lands in an argv; see the header.
    if printf 'add-generic-password -U -s %s -a %s -l %s -w %s\n' \
      "$(fm_buzz_security_word "$FM_BUZZ_KEYCHAIN_SERVICE")" \
      "$(fm_buzz_security_word "$account")" \
      "$(fm_buzz_security_word 'firstmate buzz publishing key')" \
      "$(fm_buzz_security_word "$private")" \
      | security -i >/dev/null 2>&1; then
      printf 'keychain\n'
      return 0
    fi
  fi
  file=$(fm_buzz_key_fallback_file "$home") || return 1
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 0700 "$dir" 2>/dev/null || true
  fm_buzz_file_target_replaceable "$file" || return 1
  # mktemp creates at 0600 regardless of umask, and the mode is tightened again
  # before a single byte of key material is written, so the key is never in a file
  # a second process could open. Doing it this way rather than with `umask 077`
  # keeps this sourced function from mutating the caller's umask for the rest of
  # the process, which would silently tighten unrelated files created later.
  local tmp
  tmp=$(mktemp "$dir/.buzz-keypair.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '{\n  "private_key": "%s"\n}\n' "$private" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_buzz_replace_file "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
  printf 'file\n'
}

# THE ROTATION STAGE IS THE THIRD PLACE A PRIVATE KEY CAN LIVE
# fm_buzz_key_forget has to clear every store before the replacement is stored,
# because the replacement may land in a different store than the outgoing key and
# a forget afterwards would take the new key with it. That leaves a window with no
# key at all, and a keychain that refuses the write inside it strands the home with
# a public record and nothing to derive it from - orphan recovery, from a routine
# rotation. So the replacement is written here first, verified, and only then is
# the outgoing key cleared: a failure at any later point leaves a stage file the
# next run finishes, rather than a home with no key.
#
# It lives beside the record it replaces, in the gitignored per-home data/, at the
# same 0600 as the fallback store and by the same mktemp-then-tighten route, and
# it is removed the moment the replacement is stored and recorded. Custody lives
# here rather than in bin/fm-buzz-keypair.sh so this file stays the single answer
# to where a private key can be found.
# The record also preserves its prepared-or-committable phase and its ordinary-or-
# compromised rotation intent, so an interrupted retry cannot silently weaken a
# compromised recovery. bin/fm-buzz-keypair.sh --help owns the operator decision
# procedure for resuming it.
fm_buzz_key_stage_file() {  # <data directory>
  local data=${1:?data directory required}
  printf '%s/.buzz-keypair.rotation-stage\n' "$data"
}

fm_buzz_key_stage_write() {  # <data directory> <prepared|committable> <private> <public> <ordinary|compromised>
  local data=${1:?data directory required} phase=${2:?phase required}
  local private=${3:?private key required} public=${4:?public key required}
  local intent=${5:?rotation intent required} file tmp
  case $phase in prepared|committable) ;; *) return 1 ;; esac
  case $intent in ordinary|compromised) ;; *) return 1 ;; esac
  file=$(fm_buzz_key_stage_file "$data") || return 1
  mkdir -p "$data" 2>/dev/null || return 1
  fm_buzz_file_target_replaceable "$file" || return 1
  tmp=$(mktemp "$data/.buzz-keypair-rotation-stage.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '{"phase":"%s","private_key":"%s","public_key":"%s","rotation_intent":"%s"}\n' \
    "$phase" "$private" "$public" "$intent" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_buzz_replace_file "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

# Print `phase`, `private_key`, `public_key`, and `rotation_intent` on four lines. Return 1 when no
# stage exists, and 2 when one exists but is not a readable, well-formed stage.
# Same output discipline as fm_buzz_key_load: the second line is a private key.
fm_buzz_key_stage_read() {  # <data directory>
  local data=${1:?data directory required} file rc
  file=$(fm_buzz_key_stage_file "$data") || return 2
  fm_buzz_private_record_read stage "$file"
  rc=$?
  case $rc in
    0) return 0 ;;
    42) return 1 ;;
    *) return 2 ;;
  esac
}

fm_buzz_key_stage_clear() {  # <data directory>
  local data=${1:?data directory required} file
  file=$(fm_buzz_key_stage_file "$data") || return 1
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  rm -f -- "$file"
}

# Remove this home's private key from EVERY store, printing one line per store
# actually cleared. Returns 0 only after every store is verified absent; deletion,
# lookup, derivation, or absence-verification failures return nonzero.
#
# Rotation is the only caller, and it is why this cannot be keychain-only: on a
# non-Darwin host, or under FM_BUZZ_FORCE_FILE_STORE=1, the key lives in the
# fallback file, whose name carries a digest of the home account and so cannot be
# found by hand. A rotation procedure that clears the store the key is NOT in
# leaves fm_buzz_key_load finding the old key and re-printing the same public key -
# a rotation that silently does not rotate, which is worse than none at all.
fm_buzz_key_forget() {
  local home=${1:?home required} account file attempts rc cleared_keychain
  account=$(fm_buzz_key_account "$home")
  if fm_buzz_keychain_present; then
    # Loop, bounded: `-U` keeps this to one entry, but a keychain that somehow
    # holds several would otherwise hand the next load a key we thought was gone.
    attempts=0
    cleared_keychain=0
    while [ "$attempts" -lt 10 ]; do
      security delete-generic-password -s "$FM_BUZZ_KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1
      rc=$?
      if [ "$rc" -eq 0 ]; then
        attempts=$((attempts + 1))
        cleared_keychain=1
        continue
      fi
      [ "$rc" -eq 44 ] || return 1
      break
    done
    security find-generic-password -s "$FM_BUZZ_KEYCHAIN_SERVICE" -a "$account" -w >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 44 ] || return 1
    [ "$cleared_keychain" -eq 1 ] && printf 'keychain\n'
  fi
  file=$(fm_buzz_key_fallback_file "$home") || return 1
  if [ -e "$file" ] || [ -L "$file" ]; then
    rm -f -- "$file" || return 1
    printf 'file\n'
  fi
  if fm_buzz_keychain_present; then
    security find-generic-password -s "$FM_BUZZ_KEYCHAIN_SERVICE" -a "$account" -w >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 44 ] || return 1
  fi
  [ ! -e "$file" ] && [ ! -L "$file" ]
}

# --- shared helpers ----------------------------------------------------------

# Print the channel id a label derives to. Both entry points must agree on this
# or the publisher and the inspector would look at different channels, so the
# derivation has exactly one caller-visible spelling and it lives here.
fm_buzz_channel_id() {  # <script dir> <label>
  local script_dir=${1:?script dir required} label=${2-}
  node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$script_dir/fm-buzz-lib.mjs" "$label"
}
