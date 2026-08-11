#!/usr/bin/env bash
# Buzz key custody, rotation, and retirement behavior tests.
set -u

# shellcheck source=tests/fm-buzz-test-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-buzz-test-lib.sh"

test_bip340_official_vectors() {
  local result
  result=$(node -e '
    import(process.argv[1]).then(({ schnorrSign, schnorrVerify, publicKeyFromPrivate }) => {
      // Signing vectors 0-3 and the negative verification vectors 5-14 from
      // https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv
      // (only the 32-byte-message vectors; BIP-340 variable-length messages are
      // not part of NIP-01 and this signer does not accept them).
      const sign = [
        ["0000000000000000000000000000000000000000000000000000000000000003","f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9","0000000000000000000000000000000000000000000000000000000000000000","0000000000000000000000000000000000000000000000000000000000000000","e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0"],
        ["b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef","dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","0000000000000000000000000000000000000000000000000000000000000001","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a"],
        ["c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9","dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8","c87aa53824b4d7ae2eb035a2b5bbbccc080e76cdc6d1692c4b0b62d798e6d906","7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c","5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1bab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7"],
        ["0b432b2677937381aef05bb02a66ecd012773062cf3fa2549e44f58ed2401710","25d1dff95105f5253c4022f628a996ad3a0d95fbf21d468a1b33f8c160d8f517","ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","7eb0509757e246f19449885651611cb965ecc1a187dd51b64fda1edc9637d5ec97582b9cb13db3933705b32ba982af5af25fd78881ebb32771fc5922efc66ea3"]
      ];
      const badVerify = [
        ["eefdea4cdb677750a420fee807eacf21eb9898ae79b9768766e4faa04a2d4a34","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a14602975563cc27944640ac607cd107ae10923d9ef7a73c643e166be5ebeafa34b1ac553e2"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","1fa62e331edbc21c394792d2ab1100a7b432b013df3f6ff4f99fcb33e0e1515f28890b3edb6e7189b630448b515ce4f8622a954cfe545735aaea5134fccdb2bd"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e177769961764b3aa9b2ffcb6ef947b6887a226e8d7c93e00c5ed0c1834ff0d0c2e6da6"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","0000000000000000000000000000000000000000000000000000000000000000123dda8328af9c23a94c1feecfd123ba4fb73476f0d594dcb65c6425bd186051"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","00000000000000000000000000000000000000000000000000000000000000017615fbaf5ae28864013c099742deadb4dba87f11ac6754f93780d5a1837cf197"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","4a298dacae57395a15d0795ddbfd1dcb564da82b0f269bc70a74f8220429ba1d69e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f69e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"],
        ["dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e177769fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"],
        ["fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc30","243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89","6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b"]
      ];
      for (const [sk, pk, aux, msg, expected] of sign) {
        if (publicKeyFromPrivate(sk) !== pk) { console.log("bad-pubkey"); return; }
        if (schnorrSign(msg, sk, aux) !== expected) { console.log("bad-signature"); return; }
        if (!schnorrVerify(msg, pk, expected)) { console.log("bad-verify"); return; }
      }
      for (const [pk, msg, sig] of badVerify) {
        if (schnorrVerify(msg, pk, sig)) { console.log("accepted-invalid-signature"); return; }
      }
      console.log("ok");
    });
  ' "$ROOT/bin/fm-buzz-crypto.mjs")
  [ "$result" = "ok" ] || fail "BIP-340 official vectors failed: $result"
  pass "signing matches the official BIP-340 32-byte-message vectors and rejects all 10 invalid ones"
}

# --- (a) keypair generation ------------------------------------------------

test_keypair_is_idempotent_and_never_prints_the_private_key() {
  local home first second stored keyfile
  home=$(make_home keypair)
  keyfile=$(key_file "$home" "$home/xdg")

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  case $first in
    [0-9a-f]*) : ;;
    *) fail "keypair did not print a hex public key: $first" ;;
  esac
  [ "${#first}" -eq 64 ] || fail "public key has the wrong length: ${#first}"

  second=$(run_keypair "$home" 2>/dev/null) || fail "second keypair run failed"
  [ "$first" = "$second" ] \
    || fail "keypair is not idempotent: got $first then $second"

  assert_grep "$first" "$home/data/buzz-keypair.public" \
    "the public key was not recorded in data/buzz-keypair.public"

  # The private key must appear in NO output stream of either run.
  stored=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$keyfile")
  [ -n "$stored" ] || fail "no private key was stored"
  [ "$stored" != "$first" ] || fail "the public and private keys are identical"

  local combined
  combined=$(run_keypair "$home" 2>&1)
  assert_not_contains "$combined" "$stored" \
    "the private key leaked into the keypair script's output"

  # And the fallback file must not be world-readable.
  local mode
  mode=$(file_mode "$keyfile")
  [ "$mode" = "600" ] || fail "the key file mode is $mode, expected 600"

  pass "keypair generation is idempotent and never prints the private key"
}

test_fallback_key_load_requires_private_regular_custody() {
  local home keyfile stored moved output code
  home=$(make_home fallback-key-custody)
  run_keypair "$home" >/dev/null 2>&1 || fail "fallback custody setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  stored=$(cat "$keyfile")

  chmod 0644 "$keyfile"
  output=$(run_keypair "$home" --public 2>&1)
  code=$?
  expect_code 1 "$code" "a group/world-readable fallback private key"
  assert_contains "$output" "publishing key file" \
    "a group/world-readable fallback key was not diagnosed"
  assert_contains "$output" "could not be read" \
    "a group/world-readable fallback key failure was ambiguous"
  [ "$(cat "$keyfile")" = "$stored" ] || fail "fallback custody refusal changed the key"

  chmod 0600 "$keyfile"
  moved="$keyfile.regular"
  mv "$keyfile" "$moved"
  ln -s "$moved" "$keyfile"
  output=$(run_keypair "$home" --public 2>&1)
  code=$?
  expect_code 1 "$code" "a symbolic-link fallback private key"
  assert_contains "$output" "publishing key file" \
    "a symbolic-link fallback key was not diagnosed"
  assert_contains "$output" "could not be read" \
    "a symbolic-link fallback key failure was ambiguous"
  [ "$(cat "$moved")" = "$stored" ] || fail "fallback symlink refusal changed the key"
  pass "fallback key loading requires a private regular file"
}

test_private_key_reads_are_descriptor_verified() {
  local home keyfile held replacement preload output code stage staged_private staged_public recorded
  home=$(make_home descriptor-key-read)
  recorded=$(run_keypair "$home" 2>/dev/null) || fail "descriptor key-read setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  held="$keyfile.held"
  replacement="$keyfile.replacement"
  preload="$home/swap-private-before-open.cjs"
  printf '%s\n' '{"private_key":"0000000000000000000000000000000000000000000000000000000000000003"}' \
    > "$replacement"
  chmod 0600 "$replacement"
  cat > "$preload" <<'EOF'
const fs = require("node:fs");
const { syncBuiltinESMExports } = require("node:module");
const originalOpenSync = fs.openSync;
let swapped = false;
fs.openSync = function guardedOpenSync(file, flags, ...args) {
  if (!swapped && String(file) === process.env.FM_TEST_PRIVATE_KEY_FILE) {
    swapped = true;
    fs.renameSync(process.env.FM_TEST_PRIVATE_KEY_FILE, process.env.FM_TEST_PRIVATE_KEY_HELD);
    fs.symlinkSync(process.env.FM_TEST_PRIVATE_KEY_REPLACEMENT, process.env.FM_TEST_PRIVATE_KEY_FILE);
  }
  return originalOpenSync.call(fs, file, flags, ...args);
};
syncBuiltinESMExports();
EOF
  output=$(NODE_OPTIONS="--require=$preload" \
    FM_TEST_PRIVATE_KEY_FILE="$keyfile" \
    FM_TEST_PRIVATE_KEY_HELD="$held" \
    FM_TEST_PRIVATE_KEY_REPLACEMENT="$replacement" \
    run_keypair "$home" --public 2>&1)
  code=$?
  expect_code 1 "$code" "fallback key swapped to a symlink during open"
  [ -L "$keyfile" ] || fail "the private-key open race fixture did not run"
  assert_contains "$output" "publishing key file" \
    "a fallback key swapped during open bypassed descriptor validation"
  [ "$(public_from_private "$(jq -r '.private_key' "$held")")" = "$recorded" ] \
    || fail "the rejected descriptor race changed the original private key"

  rm -f -- "$keyfile"
  mv "$held" "$keyfile"
  stage=$(rotation_stage_file "$home")
  staged_private=$(new_private_key) || fail "could not mint the staged-permission fixture"
  staged_public=$(public_from_private "$staged_private") || fail "could not derive the staged-permission fixture"
  write_rotation_stage "$home" committable "$staged_private" "$staged_public"
  chmod 0644 "$stage"
  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "a group/world-readable rotation stage"
  assert_contains "$output" "rotation stage $stage is invalid" \
    "a non-private rotation stage was accepted"
  assert_present "$stage" "rejecting a non-private rotation stage removed recovery material"
  chmod 0600 "$stage"
  [ "$(run_keypair "$home" --public 2>/dev/null)" = "$recorded" ] \
    || fail "rejecting a non-private rotation stage changed the current identity"
  pass "fallback and staged private keys are verified through one opened descriptor"
}

# --- one key per home, in the store that cannot enforce it ------------------

test_two_homes_sharing_one_xdg_get_separate_keys() {
  # XDG_DATA_HOME follows the USER, not FM_HOME, so the realistic arrangement is
  # one XDG dir shared by the main home and every secondmate. The keychain keys on
  # the FM_HOME account and so is safe by construction; the file fallback has to
  # derive per-home too or a secondmate silently publishes under the main home's
  # identity on every non-Darwin host. Giving each synthetic home its own
  # XDG_DATA_HOME - which the rest of this suite does - cannot see that at all,
  # so this test deliberately shares one.
  local xdg main second main_key second_key main_file second_file
  xdg="$TMP_ROOT/shared-xdg"
  mkdir -p "$xdg"
  main=$(make_home per-home-main)
  second=$(make_home per-home-second)

  main_key=$(FM_HOME="$main" FM_DATA_OVERRIDE="$main/data" XDG_DATA_HOME="$xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 "$KEYPAIR" 2>/dev/null) \
    || fail "keypair creation failed for the main home"
  second_key=$(FM_HOME="$second" FM_DATA_OVERRIDE="$second/data" XDG_DATA_HOME="$xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 "$KEYPAIR" 2>/dev/null) \
    || fail "keypair creation failed for the second home"

  [ "$main_key" != "$second_key" ] \
    || fail "two homes sharing one XDG_DATA_HOME got the SAME public key ($main_key); the second home would publish under the first home's identity"

  main_file=$(key_file "$main" "$xdg")
  second_file=$(key_file "$second" "$xdg")
  [ "$main_file" != "$second_file" ] \
    || fail "both homes resolved to one key file: $main_file"
  assert_present "$main_file" "the main home's key file is missing"
  assert_present "$second_file" "the second home's key file is missing"

  # And the first home's key must survive the second home's creation unchanged.
  local reread
  reread=$(FM_HOME="$main" FM_DATA_OVERRIDE="$main/data" XDG_DATA_HOME="$xdg" \
    FM_BUZZ_FORCE_FILE_STORE=1 "$KEYPAIR" --public 2>/dev/null)
  [ "$reread" = "$main_key" ] \
    || fail "the second home's keypair overwrote the first home's key"

  pass "two homes sharing one XDG_DATA_HOME get separate keys"
}

test_rotation_replaces_the_key_in_whichever_store_holds_it() {
  # A rotation that clears one store and leaves the other is a rotation that
  # silently does not rotate: the next load finds the surviving key and re-prints
  # the same public key. On every host with no reachable keychain - which is this
  # suite, CI, and all of Linux - the key is in the fallback file, under a
  # digest-derived name no operator can delete by hand. So the check that matters
  # is behavioural: the public key must actually change.
  local home first second third keyfile stored combined code
  home=$(make_home rotate)
  keyfile=$(key_file "$home" "$home/xdg")

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  second=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$first" != "$second" ] \
    || fail "rotation re-printed the same public key ($first); the old key was never cleared"
  assert_grep "$second" "$home/data/buzz-keypair.public" \
    "rotation did not re-record the new public key"

  # The rotated-in key must be the one the publisher would now load.
  third=$(run_keypair "$home" --public 2>/dev/null) || fail "--public failed after rotation"
  [ "$third" = "$second" ] || fail "the stored key does not match the rotated public key"

  # And rotation must stay as silent about key material as creation is.
  combined=$(run_keypair "$home" --rotate 2>&1)
  stored=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$keyfile")
  [ -n "$stored" ] || fail "rotation left no usable key behind"
  assert_not_contains "$combined" "$stored" "the private key leaked into --rotate's output"

  run_keypair "$home" --rotate --public >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--rotate --public asks for two contradictory things"
  pass "rotation replaces the key in whichever store holds it"
}

test_a_compromised_rotation_does_not_keep_the_retired_key() {
  # Retention rests on the retired key being one only this home ever held, and the
  # commonest reason to rotate breaks exactly that premise: a private half that may
  # have leaked is a key somebody else holds too, and the channel id is not a
  # secret, so that somebody can mint an event the probe would report as this
  # home's own leaked projection. --compromised is how a rotation says so: it
  # declines to record the outgoing key, and withdraws it if it is already there.
  local home first second third history code
  home=$(make_home rotate-compromised)
  history="$home/data/buzz-keypair.public-history"

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  second=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "compromised rotation failed"
  [ "$first" != "$second" ] \
    || fail "the compromised rotation re-printed the same public key; nothing was replaced"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$first" \
    "a compromised rotation kept the retired key in the recorded set"

  # Declining to retain has to mean the outgoing key is absent from the recorded
  # set afterwards, not merely that this run did not add it. A key an EARLIER
  # rotation retired is a different key and out of this flag's reach: see
  # test_forget_key_withdraws_an_already_retired_key for that one.
  printf '%s\n' "$second" >> "$history"
  third=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "second compromised rotation failed"
  [ "$third" != "$second" ] \
    || fail "the second compromised rotation did not replace the key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$second" \
    "a compromised rotation left an already-recorded copy of the retired key in place"

  # An ordinary rotation must still retain, or the flag would be describing the
  # default rather than an opt-out.
  assert_grep "$third" "$home/data/buzz-keypair.public" \
    "the compromised rotation did not record the new public key"
  run_keypair "$home" --rotate >/dev/null 2>&1 || fail "ordinary rotation failed"
  assert_grep "$third" "$history" \
    "an ordinary rotation stopped retaining the key it retired"

  run_keypair "$home" --compromised >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--compromised without --rotate describes nothing"
  pass "a compromised rotation does not keep the retired key"
}

test_rotation_refuses_or_quarantines_outgoing_pending_events() {
  local home other relay channel old old_private other_private old_file_one old_file_two other_file
  local keyfile private_before history_before output code rotated quarantine manifests
  home=$(make_home rotation-pending-cache)
  other=$(make_home rotation-pending-cache-other)
  relay="ws://127.0.0.1:1/pending-rotation"
  channel="11111111-1111-5111-8111-111111111111"
  old=$(run_keypair "$home" 2>/dev/null) || fail "pending-cache rotation keypair setup failed"
  run_keypair "$other" >/dev/null 2>&1 || fail "pending-cache other-author setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  old_private=$(jq -r '.private_key' "$keyfile")
  other_private=$(jq -r '.private_key' "$(key_file "$other" "$other/xdg")")
  old_file_one=$(seed_replay_event "$home" "$relay" "$old_private" 1700000100 "$channel" pending-one) \
    || fail "could not seed the first outgoing replay entry"
  old_file_two=$(seed_replay_event "$home" "$relay" "$old_private" 1700000101 "$channel" pending-two) \
    || fail "could not seed the second outgoing replay entry"
  other_file=$(seed_replay_event "$home" "$relay" "$other_private" 1700000102 "$channel" other-author) \
    || fail "could not seed the other-author replay entry"
  private_before=$(cat "$keyfile")
  history_before=$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with outgoing-authored pending replay entries"
  assert_contains "$output" "pending replay cache contains 2 outgoing-authored event(s)" \
    "rotation refusal did not report the exact pending-entry count"
  assert_contains "$output" "$old_file_one" "rotation refusal omitted the first blocking path"
  assert_contains "$output" "$old_file_two" "rotation refusal omitted the second blocking path"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "pending-cache refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "pending-cache refusal changed the stored private key"
  [ "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)" = "$history_before" ] \
    || fail "pending-cache refusal changed public-key history"
  assert_present "$old_file_one" "pending-cache refusal removed the first outgoing entry"
  assert_present "$old_file_two" "pending-cache refusal removed the second outgoing entry"
  assert_present "$other_file" "pending-cache refusal removed another publisher's entry"

  output=$(run_keypair "$home" --rotate --discard-pending-cache 2>&1)
  code=$?
  expect_code 0 "$code" "rotation with explicit pending-cache quarantine"
  assert_contains "$output" "quarantined 2 outgoing-authored pending replay event(s)" \
    "rotation override did not report the exact quarantined-entry count"
  rotated=$(printf '%s\n' "$output" | tail -1)
  [ "$rotated" != "$old" ] || fail "pending-cache override did not replace the publishing identity"
  assert_absent "$old_file_one" "pending-cache override left the first outgoing entry active"
  assert_absent "$old_file_two" "pending-cache override left the second outgoing entry active"
  assert_present "$other_file" "pending-cache override removed another publisher's entry"
  quarantine="$home/state/buzz-replay/_legacy-quarantine"
  manifests=$(find "$quarantine/manifests" -type f -name '*.json' -print)
  [ "$(printf '%s\n' "$manifests" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] \
    || fail "pending-cache override did not retain exactly two quarantine manifests"
  for manifest in $manifests; do
    jq -e --arg publisher "$old" \
      '.quarantine_reason == "pending-key-rotation" and .publisher_pubkey == $publisher' \
      "$manifest" >/dev/null \
      || fail "pending-cache quarantine manifest omitted its rotation provenance"
    assert_present "$quarantine/$(jq -r '.payload_reference' "$manifest")" \
      "pending-cache quarantine manifest referenced no retained payload"
  done
  pass "rotation refuses or explicitly quarantines outgoing pending replay entries"
}

test_rotation_refuses_an_existing_private_channel_before_mutation() {
  local home relay old channel resolved_home private_file private_before history_before output code readback
  home=$(make_home rotate-existing-private-channel)
  old=$(run_keypair "$home" 2>/dev/null) || fail "rotation membership fixture setup failed"
  private_file=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$private_file")
  history_before=$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"membership-must-survive"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  resolved_home=$(cd "$home" && pwd -P)
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$resolved_home") || fail "could not derive the rotation fixture channel"

  output=$(FM_BUZZ_KEYPAIR_RELAY="$relay" run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation of an identity owning an existing private channel"
  assert_contains "$output" "current membership on relay $relay, channel $channel" \
    "rotation refusal did not name the existing private-channel membership"
  assert_contains "$output" "Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity." \
    "rotation refusal omitted the required membership explanation"
  assert_contains "$output" "https://github.com/block/buzz/blob/main/ARCHITECTURE.md" \
    "rotation refusal omitted the Buzz architecture reference"
  assert_contains "$output" "https://github.com/block/buzz/blob/main/NOSTR.md" \
    "rotation refusal omitted the Nostr reference"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "rotation refusal changed the recorded public key"
  [ "$(cat "$private_file")" = "$private_before" ] \
    || fail "rotation refusal changed the stored private key"
  [ "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null || true)" = "$history_before" ] \
    || fail "rotation refusal changed public-key history"
  readback=$(run_inspect "$home" "$relay" 2>&1)
  stop_stub "$STUB_PID"
  assert_contains "$readback" "membership-must-survive" \
    "rotation membership preflight changed the existing channel state"
  pass "rotation refuses an existing private channel before key mutation"
}

test_rotation_reports_every_membership_blocker() {
  local home old keyfile private_before relay normalized_relay targets channel_a channel_b
  local target_a target_b output code relay_instruction_count
  home=$(make_home aggregate-membership-blockers)
  old=$(run_keypair "$home" 2>/dev/null) || fail "aggregate-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel_a="31313131-4242-5353-8464-757575757575"
  channel_b="32323232-4343-5454-8565-767676767676"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel_a" "$old" \
    || fail "could not seed the first blocking membership"
  publish_membership_fixture "$relay" "$channel_b" "$old" \
    || fail "could not seed the second blocking membership"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the aggregate-membership relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      for (let index = 4; index < process.argv.length - 1; index += 2) {
        recordPublisherTarget(process.argv[3], {
          relay: process.argv[index],
          channel_id: process.argv[index + 1],
          publisher_pubkey: process.argv[process.argv.length - 1],
        });
      }
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$normalized_relay" "$channel_a" "$normalized_relay" "$channel_b" "$old" \
    || fail "could not seed aggregate-membership targets"
  target_a=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_a" '$4 == channel { print $1 }')
  target_b=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_b" '$4 == channel { print $1 }')

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with multiple blocking memberships"
  assert_contains "$output" "target $target_a has current membership on relay $normalized_relay, channel $channel_a" \
    "rotation refusal omitted the first blocking relay/channel pair"
  assert_contains "$output" "target $target_b has current membership on relay $normalized_relay, channel $channel_b" \
    "rotation refusal omitted the second blocking relay/channel pair"
  assert_contains "$output" "--forget-target $target_a" \
    "rotation refusal omitted the first target-retirement command"
  assert_contains "$output" "--forget-target $target_b" \
    "rotation refusal omitted the second target-retirement command"
  relay_instruction_count=$(printf '%s\n' "$output" \
    | grep -Fc -- "--forget-relay-identity $normalized_relay")
  [ "$relay_instruction_count" = "1" ] \
    || fail "rotation refusal did not deduplicate the shared relay-retirement command"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "aggregate membership refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "aggregate membership refusal changed the stored private key"
  pass "rotation reports every membership blocker and complete retirement sequence"
}

test_rotation_query_errors_report_every_target_on_the_endpoint() {
  local home other old other_public relay targets channel_a channel_b target_a target_b output code
  home=$(make_home aggregate-membership-query-errors)
  other=$(make_home aggregate-membership-query-errors-other)
  old=$(run_keypair "$home" 2>/dev/null) || fail "query-error keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "query-error alternate key setup failed"
  relay="ws://127.0.0.1:1/aggregate-query-error"
  channel_a="33333333-4444-5555-8666-777777777777"
  channel_b="34343434-4545-5656-8767-787878787878"
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[5], publisher_pubkey: process.argv[6],
      });
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[7], publisher_pubkey: process.argv[8],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$relay" "$channel_a" "$old" "$channel_b" "$other_public" \
    || fail "could not seed query-error retirement targets"
  target_a=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_a" '$4 == channel { print $1 }')
  target_b=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_b" '$4 == channel { print $1 }')

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with an unverifiable target endpoint"
  assert_contains "$output" "could not verify current membership for target $target_a" \
    "rotation did not report the membership query error"
  assert_contains "$output" "--forget-target $target_a" \
    "query-error recovery omitted the queried target"
  assert_contains "$output" "--forget-target $target_b" \
    "query-error recovery omitted another durable target on the affected endpoint"
  assert_contains "$output" "--forget-relay-identity $relay" \
    "query-error recovery omitted the affected relay identity"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "query-error retirement reporting changed the publishing identity"
  pass "membership query errors report every target needed to retire the endpoint"
}

test_retirement_commands_quote_special_relay_endpoints() {
  local home publisher relay normalized quoted channel targets output code
  home=$(make_home quoted-retirement-endpoint)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "quoted retirement setup failed"
  relay='ws://127.0.0.1:1/retired?first=1&second=2'
  normalized=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the quoted retirement endpoint"
  printf -v quoted '%q' "$normalized"
  channel=$(channel_id_for_label quoted-retirement-endpoint)
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[5], publisher_pubkey: process.argv[6],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$relay" "$channel" "$publisher" \
    || fail "could not seed the quoted retirement target"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a special-character relay endpoint"
  assert_contains "$output" "--forget-relay-identity $quoted" \
    "relay retirement output did not shell-quote its endpoint"
  pass "relay retirement commands shell-quote complete endpoints"
}

test_publisher_target_overrides_are_recorded_and_guard_rotation() {
  local home relay label channel old keyfile private_before targets targets_before output code normalized_relay
  home=$(make_home tracked-rotation-target)
  old=$(run_keypair "$home" 2>/dev/null) || fail "tracked-target keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  label="non-default-private-channel"
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the tracked override channel"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"tracked-override"}' \
    | run_publish "$home" "$relay" --channel-label "$label" >/dev/null 2>&1
  targets="$home/data/buzz-publisher-targets.jsonl"
  assert_present "$targets" "publish did not create the publisher-target registry"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the tracked relay"
  jq -e \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    'select(.relay == $relay and .channel_id == $channel and .publisher_pubkey == $publisher)' \
    "$targets" >/dev/null \
    || fail "publish did not persist the normalized relay/channel/publisher tuple"
  targets_before=$(cat "$targets")

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with a tracked non-default private channel"
  assert_contains "$output" "channel $channel" \
    "rotation refusal did not name the tracked override channel"
  assert_contains "$output" "relay $normalized_relay" \
    "rotation refusal did not name the tracked override relay"
  assert_contains "$output" "Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity." \
    "tracked-target refusal omitted the M1 membership explanation"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "tracked-target refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "tracked-target refusal changed the private key"
  [ "$(cat "$targets")" = "$targets_before" ] \
    || fail "tracked-target refusal changed the target registry"
  pass "publisher target overrides are recorded and guard rotation"
}

test_publisher_target_updates_are_concurrent_and_fail_closed() {
  local home relay publisher first second targets output code channel_one channel_two
  home=$(make_home publisher-target-concurrency)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "publisher-target concurrency setup failed"
  targets="$home/data/buzz-publisher-targets.jsonl"
  relay="ws://127.0.0.1:3001/concurrent-targets"
  channel_one=$(channel_id_for_label target-one)
  channel_two=$(channel_id_for_label target-two)
  (FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS=750 node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        publisher_pubkey: process.argv[4], relay: process.argv[5], channel_id: process.argv[6],
      });
    });
  ' buzz-target-test "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$publisher" "$relay" "$channel_one") &
  first=$!
  (FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS=750 node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        publisher_pubkey: process.argv[4], relay: process.argv[5], channel_id: process.argv[6],
      });
    });
  ' buzz-target-test "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$publisher" "$relay" "$channel_two") &
  second=$!
  wait "$first" || fail "first concurrent target publish failed"
  wait "$second" || fail "second concurrent target publish failed"
  [ "$(jq -s --arg publisher "$publisher" '[.[] | select(.publisher_pubkey == $publisher)] | length' "$targets")" = "2" ] \
    || fail "concurrent publisher-target updates lost or duplicated a tuple"
  assert_absent "$targets.registry-lock" "publisher-target serialization left its lock behind"

  printf '%s\n' '{"relay":"ws://localhost:3000"}' > "$targets"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a malformed publisher-target registry"
  assert_contains "$output" "could not validate $targets" \
    "malformed publisher-target state did not fail closed"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$publisher" ] \
    || fail "malformed publisher-target state allowed key mutation"

  : > "$targets"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with an empty publisher-target registry"
  assert_contains "$output" "empty or truncated" \
    "an empty publisher-target registry was treated as first use"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$publisher" ] \
    || fail "empty publisher-target state allowed key mutation"
  pass "publisher target updates serialize and malformed state fails closed"
}

test_publisher_target_lock_ignores_only_identity_bound_dead_candidates() {
  local home publisher targets lock relay first second channel_one channel_two channel_three dead token live_token
  home=$(make_home publisher-target-stale-candidate)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "stale-candidate target setup failed"
  targets="$home/data/buzz-publisher-targets.jsonl"
  lock="$targets.registry-lock"
  relay="ws://127.0.0.1:3001/stale-candidate"
  channel_one=$(channel_id_for_label stale-candidate-one)
  channel_two=$(channel_id_for_label stale-candidate-two)
  dead=2147483647
  token=00000000000000000000000000000000
  mkdir "$lock"
  printf '%s\n' "{\"pid\":$dead,\"token\":\"$token\",\"choosing\":false,\"ticket\":1}" \
    > "$lock/$dead-$token.candidate"

  (FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS=300 node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        publisher_pubkey: process.argv[4], relay: process.argv[5], channel_id: process.argv[6],
      });
    });
  ' target-lock-test "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$publisher" "$relay" "$channel_one") &
  first=$!
  (FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS=300 node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        publisher_pubkey: process.argv[4], relay: process.argv[5], channel_id: process.argv[6],
      });
    });
  ' target-lock-test "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$publisher" "$relay" "$channel_two") &
  second=$!
  wait "$first" || fail "first stale-candidate target update failed"
  wait "$second" || fail "second stale-candidate target update failed"
  [ "$(jq -s 'length' "$targets")" = "2" ] \
    || fail "dead-candidate recovery lost a concurrent target update"
  assert_absent "$lock" "dead-candidate recovery left registry ownership behind"

  channel_three=$(channel_id_for_label stale-candidate-three)
  live_token=$(printf '%032d' 8)
  mkdir "$lock"
  printf '{"pid":%s,"pid_identity":"reused-pid-owner","token":"%s","choosing":false,"ticket":1}\n' \
    "$$" "$live_token" > "$lock/$$-$live_token.candidate"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        publisher_pubkey: process.argv[4], relay: process.argv[5], channel_id: process.argv[6],
      });
    });
  ' target-lock-test "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$publisher" "$relay" "$channel_three" \
    || fail "PID-reused candidate blocked a target registry update"
  [ "$(jq -s 'length' "$targets")" = "3" ] \
    || fail "PID-reused candidate recovery lost the target update"
  assert_absent "$lock" "PID-reused candidate recovery left registry ownership behind"
  pass "registry ownership verifies process-start identity before trusting live pids"
}

test_forget_target_attests_exact_retirement() {
  local home other relay label channel old other_public targets normalized_relay other_channel
  local target_hex output code replacement
  home=$(make_home forget-publisher-target)
  other=$(make_home forget-publisher-target-other)
  old=$(run_keypair "$home" 2>/dev/null) || fail "forget-target keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "forget-target unrelated publisher setup failed"
  label="retired-private-channel"
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the retired target channel"
  other_channel="12121212-3434-5656-8787-909090909090"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  printf '%s' '{"schema":"fm-bearings.v1","note":"target-retirement"}' \
    | run_publish "$home" "$relay" --channel-label "$label" >/dev/null 2>&1
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the retired target relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4],
        channel_id: process.argv[5],
        publisher_pubkey: process.argv[6],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$normalized_relay" "$other_channel" "$other_public" \
    || fail "could not seed the unrelated publisher target"
  target_hex=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel" '$4 == channel { print $1 }')
  [ "${#target_hex}" = 64 ] || fail "the tracked target has no canonical target hex"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation before target retirement"
  assert_contains "$output" "target $target_hex" \
    "rotation refusal did not expose the exact target identifier"
  assert_contains "$output" "docker compose -f docker-compose.buzz-loopback.yml down -v" \
    "rotation refusal omitted the disposable-relay retirement step"
  assert_contains "$output" "--forget-target $target_hex" \
    "rotation refusal omitted its exact target-retirement command"
  assert_contains "$output" "--forget-relay-identity $normalized_relay" \
    "rotation refusal omitted its exact relay-identity retirement command"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "pre-retirement refusal changed the publishing identity"

  stop_stub "$STUB_PID"
  output=$(run_keypair "$home" --forget-target "$target_hex" 2>&1)
  code=$?
  expect_code 0 "$code" "exact target retirement after relay reset"
  assert_contains "$output" "forgotten target: $target_hex" \
    "target retirement did not confirm the exact record"
  assert_not_contains "$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets")" "$target_hex" \
    "target retirement left the selected record behind"
  assert_grep "$other_public" "$targets" \
    "target retirement removed an unrelated publisher target"

  replacement=$(run_keypair "$home" --rotate 2>/dev/null) \
    || fail "rotation did not proceed after exact target retirement"
  [ "$replacement" != "$old" ] || fail "post-retirement rotation kept the old identity"
  pass "exact target retirement unblocks rotation without dropping unrelated targets"
}

test_forget_relay_identity_requires_exact_target_retirement() {
  local home other old other_public relay normalized_relay port targets authorities
  local channel_a channel_b other_channel other_relay target_a target_b output code
  local first_private first_signer second_private second_signer other_signer
  home=$(make_home forget-relay-identity)
  other=$(make_home forget-relay-identity-other)
  old=$(run_keypair "$home" 2>/dev/null) || fail "relay-identity keypair setup failed"
  other_public=$(run_keypair "$other" 2>/dev/null) || fail "relay-identity unrelated publisher setup failed"
  first_private=$(printf '%064d' 4)
  first_signer=$(public_from_private "$first_private") || fail "could not derive the first relay signer"
  second_private=$(printf '%064d' 5)
  second_signer=$(public_from_private "$second_private") || fail "could not derive the replacement relay signer"
  other_signer=$(public_from_private "$(printf '%064d' 6)") || fail "could not derive the unrelated relay signer"
  channel_a="13131313-2424-5353-8464-757575757575"
  channel_b="14141414-2525-5656-8787-989898989898"
  other_channel="15151515-2626-5757-8888-a9a9a9a9a9a9"
  other_relay="ws://127.0.0.1:65534/unrelated"
  read -r STUB_PID relay <<EOF
$(start_stub --membership-private-key "$first_private")
EOF
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the relay identity"
  other_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$other_relay") \
    || fail "could not normalize the unrelated relay identity"
  port=${relay##*:}
  publish_membership_fixture "$relay" "$channel_a" "$old" \
    || fail "could not seed the first retired channel"
  publish_membership_fixture "$relay" "$channel_b" "$old" \
    || fail "could not seed the second retired channel"
  targets="$home/data/buzz-publisher-targets.jsonl"
  authorities="$home/data/buzz-relay-authorities.jsonl"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      const file = process.argv[3];
      for (let index = 4; index < process.argv.length; index += 3) {
        recordPublisherTarget(file, {
          relay: process.argv[index],
          channel_id: process.argv[index + 1],
          publisher_pubkey: process.argv[index + 2],
        });
      }
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$normalized_relay" "$channel_a" "$old" \
    "$normalized_relay" "$channel_b" "$old" \
    "$other_relay" "$other_channel" "$other_public" \
    || fail "could not seed relay-retirement targets"
  {
    jq -cn --arg relay "$normalized_relay" --arg channel "$channel_a" --arg signer "$first_signer" \
      '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}'
    jq -cn --arg relay "$normalized_relay" --arg channel "$channel_b" --arg signer "$first_signer" \
      '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}'
    jq -cn --arg relay "$other_relay" --arg channel "$other_channel" --arg signer "$other_signer" \
      '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}'
  } > "$authorities"
  target_a=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_a" '$4 == channel { print $1 }')
  target_b=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" \
    | awk -F '\t' -v channel="$channel_b" '$4 == channel { print $1 }')

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation before relay retirement"
  assert_contains "$output" "docker compose -f docker-compose.buzz-loopback.yml down -v" \
    "rotation refusal named the wrong compose retirement command"
  assert_contains "$output" "--forget-target $target_a" \
    "rotation refusal omitted the blocking target selector"
  assert_contains "$output" "--forget-relay-identity $normalized_relay" \
    "rotation refusal omitted the blocking relay endpoint"

  run_keypair "$home" --forget-target "$target_a" >/dev/null 2>&1 \
    || fail "could not attest the first target retirement"
  [ "$(jq -s --arg relay "$normalized_relay" '[.[] | select(.relay == $relay)] | length' "$authorities")" = "2" ] \
    || fail "target retirement implicitly removed relay authority pins"
  output=$(run_keypair "$home" --forget-relay-identity "$normalized_relay" 2>&1)
  code=$?
  expect_code 1 "$code" "relay identity retirement with a remaining target"
  assert_contains "$output" "$target_b" \
    "relay identity retirement did not name the remaining target"
  [ "$(jq -s --arg relay "$normalized_relay" '[.[] | select(.relay == $relay)] | length' "$authorities")" = "2" ] \
    || fail "refused relay identity retirement changed authority pins"

  run_keypair "$home" --forget-target "$target_b" >/dev/null 2>&1 \
    || fail "could not attest the second target retirement"
  output=$(run_keypair "$home" --forget-relay-identity "$normalized_relay" 2>&1)
  code=$?
  expect_code 0 "$code" "relay identity retirement after every target"
  assert_contains "$output" "forgotten relay identity: $normalized_relay (2 authority record(s))" \
    "relay identity retirement did not report the exact endpoint and pin count"
  [ "$(jq -s --arg relay "$normalized_relay" '[.[] | select(.relay == $relay)] | length' "$authorities")" = "0" ] \
    || fail "relay identity retirement left an authority pin for the retired endpoint"
  jq -e --arg relay "$other_relay" --arg signer "$other_signer" \
    'select(.relay == $relay and .signer_pubkey == $signer)' "$authorities" >/dev/null \
    || fail "relay identity retirement removed an unrelated endpoint pin"
  assert_grep "$other_public" "$targets" \
    "relay identity retirement removed an unrelated publisher target"

  stop_stub "$STUB_PID"
  read -r STUB_PID relay <<EOF
$(start_stub --port "$port" --membership-private-key "$second_private")
EOF
  publish_membership_fixture "$relay" "$channel_a" "$old" \
    || fail "could not seed the recreated relay membership"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4],
        channel_id: process.argv[5],
        publisher_pubkey: process.argv[6],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$normalized_relay" "$channel_a" "$old" \
    || fail "could not record the recreated relay target"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation after recreated relay TOFU"
  assert_contains "$output" "current membership" \
    "the recreated relay did not reach the membership guard"
  jq -e --arg relay "$normalized_relay" --arg channel "$channel_a" --arg signer "$second_signer" \
    'select(.relay == $relay and .channel_id == $channel and .signer_pubkey == $signer)' \
    "$authorities" >/dev/null \
    || fail "the recreated relay did not pin its replacement signer"
  jq -e --arg relay "$other_relay" --arg signer "$other_signer" \
    'select(.relay == $relay and .signer_pubkey == $signer)' "$authorities" >/dev/null \
    || fail "re-pinning the recreated relay changed an unrelated endpoint pin"
  pass "relay identity retirement requires exact target retirement and permits TOFU re-pinning"
}

test_rotation_checks_authoritative_current_membership() {
  local home relay old channel keyfile private_before targets normalized_relay output code
  home=$(make_home current-membership-rotation)
  old=$(run_keypair "$home" 2>/dev/null) || fail "current-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="11111111-2222-5333-8444-555555555555"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel" "$old" \
    || fail "could not seed creator-independent current membership"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the membership relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation of a publisher added by another channel creator"
  assert_contains "$output" "relay $normalized_relay" \
    "current-membership refusal did not name the normalized relay"
  assert_contains "$output" "channel $channel" \
    "current-membership refusal did not name the channel"
  assert_contains "$output" "Rotating publisher identity for an existing private channel would strand membership; membership-transfer is not implemented in M1. To rotate, either publish membership transfer first (planned for M2) or destroy and recreate the channel with the new identity." \
    "current-membership refusal omitted the required M1 explanation"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "current-membership refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "current-membership refusal changed the stored private key"
  [ "$(jq -s 'length' "$home/data/buzz-relay-authorities.jsonl")" = "1" ] \
    || fail "the first authoritative membership query did not pin its signer"
  pass "rotation checks current membership independently of channel creation"
}

test_rotation_fails_closed_on_unverifiable_membership() {
  local mode expected home relay old channel keyfile private_before targets normalized_relay output code
  for mode in --malform-membership --ambiguous-membership --empty-membership; do
    case $mode in
      --malform-membership) expected="malformed current membership state" ;;
      --ambiguous-membership) expected="ambiguous current membership state" ;;
      --empty-membership) expected="malformed current membership state" ;;
    esac
    home=$(make_home "membership-${mode#--}")
    old=$(run_keypair "$home" 2>/dev/null) || fail "unverifiable-membership keypair setup failed"
    keyfile=$(key_file "$home" "$home/xdg")
    private_before=$(cat "$keyfile")
    channel="22222222-3333-5444-8555-666666666666"
    read -r STUB_PID relay <<EOF
$(start_stub "$mode")
EOF
    publish_membership_fixture "$relay" "$channel" "$old" \
      || fail "could not seed unverifiable current membership"
    normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
      || fail "could not normalize the unverifiable-membership relay"
    targets="$home/data/buzz-publisher-targets.jsonl"
    jq -cn \
      --arg relay "$normalized_relay" \
      --arg channel "$channel" \
      --arg publisher "$old" \
      '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"

    output=$(run_keypair "$home" --rotate 2>&1)
    code=$?
    stop_stub "$STUB_PID"
    expect_code 1 "$code" "rotation with $expected"
    assert_contains "$output" "$expected" "rotation did not diagnose $expected"
    assert_contains "$output" "relay $normalized_relay, channel $channel" \
      "unverifiable-membership refusal did not name its target pair"
    [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
      || fail "unverifiable-membership refusal changed the recorded public key"
    [ "$(cat "$keyfile")" = "$private_before" ] \
      || fail "unverifiable-membership refusal changed the stored private key"
  done

  home=$(make_home membership-missing)
  old=$(run_keypair "$home" 2>/dev/null) || fail "missing-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="33333333-4444-5555-8666-777777777777"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the missing-membership relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with no current membership snapshot"
  assert_contains "$output" "no current membership state" \
    "rotation treated a missing membership snapshot as authoritative absence"
  assert_contains "$output" "relay $normalized_relay, channel $channel" \
    "missing-membership refusal did not name its target pair"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "missing-membership refusal changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "missing-membership refusal changed the stored private key"
  pass "rotation fails closed on missing, empty, malformed, or ambiguous membership"
}

test_rotation_pins_and_verifies_relay_membership_authority() {
  local home relay old channel keyfile private_before targets authorities normalized_relay
  local expected_signer actual_private actual_signer output code strict_home strict_old
  home=$(make_home membership-authority-mismatch)
  old=$(run_keypair "$home" 2>/dev/null) || fail "membership-authority keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="44444444-5555-5666-8777-888888888888"
  actual_private=$(printf '%064d' 4)
  actual_signer=$(public_from_private "$actual_private") \
    || fail "could not derive the actual membership signer"
  expected_signer=$(public_from_private "$(printf '%064d' 5)") \
    || fail "could not derive the pinned membership signer"
  read -r STUB_PID relay <<EOF
$(start_stub --membership-private-key "$actual_private")
EOF
  publish_membership_fixture "$relay" "$channel" "$old" \
    || fail "could not seed membership-authority state"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the membership-authority relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  authorities="$home/data/buzz-relay-authorities.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg signer "$expected_signer" \
    '{relay:$relay,channel_id:$channel,signer_pubkey:$signer}' > "$authorities"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with a changed relay membership signer"
  assert_contains "$output" "relay $normalized_relay, channel $channel" \
    "relay-authority mismatch did not name its target pair"
  assert_contains "$output" "relay membership authority mismatch" \
    "relay-authority mismatch was not diagnosed"
  assert_contains "$output" "expected $expected_signer, received $actual_signer" \
    "relay-authority mismatch did not identify both signers"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "relay-authority mismatch changed the recorded public key"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "relay-authority mismatch changed the stored private key"

  strict_home=$(make_home membership-authority-strict)
  strict_old=$(run_keypair "$strict_home" 2>/dev/null) \
    || fail "strict membership-authority keypair setup failed"
  channel="55555555-6666-5777-8888-999999999999"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel" "$strict_old" \
    || fail "could not seed strict membership-authority state"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the strict membership-authority relay"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$strict_old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' \
    > "$strict_home/data/buzz-publisher-targets.jsonl"
  output=$(FM_BUZZ_REQUIRE_PINNED_RELAY_AUTHORITY=1 run_keypair "$strict_home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "strict rotation without a pinned relay authority"
  assert_contains "$output" "relay membership authority is not pinned in strict mode" \
    "strict membership-authority mode trusted its first signer"
  [ "$(cat "$strict_home/data/buzz-keypair.public")" = "$strict_old" ] \
    || fail "strict unpinned-authority refusal changed the recorded public key"
  assert_absent "$strict_home/data/buzz-relay-authorities.jsonl" \
    "strict membership-authority mode recorded a first-use signer"
  pass "rotation pins and verifies relay membership authority"
}

test_empty_relay_authority_registry_fails_closed() {
  local home old keyfile private_before channel relay normalized_relay targets authorities output code
  home=$(make_home empty-relay-authority)
  old=$(run_keypair "$home" 2>/dev/null) || fail "empty-authority keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  private_before=$(cat "$keyfile")
  channel="77777777-8888-5999-8aaa-bbbbbbbbbbbb"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_membership_fixture "$relay" "$channel" "$old" \
    || fail "could not seed empty-authority membership state"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the empty-authority relay"
  targets="$home/data/buzz-publisher-targets.jsonl"
  authorities="$home/data/buzz-relay-authorities.jsonl"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  : > "$authorities"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "rotation with an empty relay-authority registry"
  assert_contains "$output" "empty or truncated" \
    "an empty relay-authority registry was treated as TOFU first use"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "empty relay-authority state allowed public-key mutation"
  [ "$(cat "$keyfile")" = "$private_before" ] \
    || fail "empty relay-authority state allowed private-key mutation"
  pass "empty security registries are corrupt rather than first use"
}

test_rotation_stops_or_recovers_when_the_outgoing_private_key_is_unusable() {
  # data/buzz-keypair.public is a cache, not the authority. A half-written one
  # holds something that is not a key at all, and retaining that would leave a
  # history entry no reader can attribute while looking exactly like retention
  # that worked - the stored private half is what settles it. And when neither
  # source can name the outgoing key, the rotation must STOP: the very next step
  # forgets the private half, after which nothing can derive that key again.
  local home first second third history keyfile output code targets artifact unrelated
  local current_channel unrelated_channel current_relay unrelated_relay
  home=$(make_home rotate-unusable)
  history="$home/data/buzz-keypair.public-history"
  keyfile=$(key_file "$home" "$home/xdg")

  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  printf 'deadbeefdeadbeef\n' > "$home/data/buzz-keypair.public"
  second=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$first" != "$second" ] || fail "rotation did not replace the key"
  assert_grep "$first" "$history" \
    "a truncated recorded file cost the rotation the key it was retiring"
  assert_no_grep "deadbeefdeadbeef" "$history" \
    "a truncated recorded file was recorded as though it were a key"

  targets="$home/data/buzz-publisher-targets.jsonl"
  artifact="$home/data/buzz-compromised-unverifiable-pairs.jsonl"
  unrelated=$(public_from_private "$(printf '%064d' 9)") \
    || fail "could not derive the unrelated publisher fixture"
  current_channel="19191919-2020-5151-8282-939393939393"
  unrelated_channel="29292929-3030-5151-8282-949494949494"
  current_relay="ws://localhost:3000/current-compromised"
  unrelated_relay="ws://localhost:3000/unrelated-retired"
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4],
        channel_id: process.argv[5],
        publisher_pubkey: process.argv[6],
      });
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[7],
        channel_id: process.argv[8],
        publisher_pubkey: process.argv[9],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" \
    "$current_relay" "$current_channel" "$second" \
    "$unrelated_relay" "$unrelated_channel" "$unrelated" \
    || fail "could not seed scoped compromised-recovery targets"
  printf '%s\n' "$unrelated" >> "$history"
  printf '{"private_key": "unreadable"}\n' > "$keyfile"
  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "a rotation that cannot name its outgoing key"
  assert_contains "$output" "$keyfile" \
    "the rotation failed without naming the unreadable private key file"
  assert_grep "$first" "$history" \
    "a refused rotation still rewrote the recorded key set"
  assert_grep "$second" "$home/data/buzz-keypair.public" \
    "a refused rotation disturbed the recorded current public key"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "a compromised rotation with unreadable private material"
  assert_contains "$output" "$keyfile" \
    "the compromised recovery did not name the unreadable private key file"
  assert_contains "$output" "no outgoing public key will be retained" \
    "the compromised recovery did not diagnose its no-retention path"
  third=$(printf '%s\n' "$output" | tail -1)
  [ "$third" != "$second" ] || fail "compromised recovery did not replace the unreadable key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$second" \
    "compromised recovery retained the unreadable outgoing key"
  assert_grep "$first" "$history" \
    "compromised recovery disturbed an earlier uncompromised retired key"
  assert_grep "$unrelated" "$history" \
    "compromised recovery purged an unrelated historical publisher"
  jq -e --arg publisher "$unrelated" 'select(.publisher_pubkey == $publisher)' "$targets" >/dev/null \
    || fail "compromised recovery retired an unrelated publisher target"
  if jq -e --arg publisher "$second" 'select(.publisher_pubkey == $publisher)' "$targets" >/dev/null; then
    fail "compromised recovery left the implicated publisher target active"
  fi
  jq -e --arg publisher "$second" 'select(.publisher_pubkey == $publisher)' "$artifact" >/dev/null \
    || fail "compromised recovery did not record the implicated unverifiable target"
  if jq -e --arg publisher "$unrelated" 'select(.publisher_pubkey == $publisher)' "$artifact" >/dev/null; then
    fail "compromised recovery recorded an unrelated publisher as unverifiable"
  fi
  pass "rotation refuses or recovers explicitly when private material is unusable"
}

test_compromised_orphan_recovery_records_unverifiable_memberships() {
  local home old keyfile targets artifact relay normalized_relay channel output code replacement
  home=$(make_home compromised-unverifiable-membership)
  old=$(run_keypair "$home" 2>/dev/null) || fail "unverifiable-membership keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  targets="$home/data/buzz-publisher-targets.jsonl"
  artifact="$home/data/buzz-compromised-unverifiable-pairs.jsonl"
  relay="ws://localhost:3000/unverifiable"
  normalized_relay=$(node "$ROOT/bin/fm-buzz-targets.mjs" normalize-relay "$relay") \
    || fail "could not normalize the unverifiable-membership relay"
  channel="66666666-7777-5888-8999-aaaaaaaaaaaa"
  jq -cn \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    --arg publisher "$old" \
    '{relay:$relay,channel_id:$channel,publisher_pubkey:$publisher}' > "$targets"
  rm "$keyfile"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "plain rotation with an orphaned tracked identity"
  assert_contains "$output" "has no stored private key" \
    "plain rotation did not refuse the orphaned identity"
  assert_absent "$artifact" "plain rotation recorded a compromised-recovery artifact"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "plain orphan refusal changed the recorded identity"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised recovery with unverifiable tracked memberships"
  replacement=$(printf '%s\n' "$output" | tail -1)
  [ "$replacement" != "$old" ] || fail "compromised orphan recovery did not replace the identity"
  assert_contains "$output" "they may be stranded and are recorded in $artifact" \
    "compromised recovery omitted the unverifiable-membership warning"
  assert_contains "$output" "$normalized_relay" \
    "compromised recovery warning omitted the affected relay"
  assert_contains "$output" "$channel" \
    "compromised recovery warning omitted the affected channel"
  jq -e \
    --arg publisher "$old" \
    --arg relay "$normalized_relay" \
    --arg channel "$channel" \
    'select(
      .publisher_pubkey == $publisher and
      .relay == $relay and
      .channel_id == $channel and
      (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) and
      (.reason | contains("has no stored private key"))
    )' "$artifact" >/dev/null \
    || fail "compromised recovery artifact omitted canonical identity, pair, time, or reason"
  pass "compromised orphan recovery records every unverifiable tracked membership"
}

test_orphan_identity_evidence_requires_compromised_recovery() {
  local home relay old keyfile public_file targets cache_file cache_name targets_before cache_before
  local output code replacement artifact manifest history unrelated_history_key
  home=$(make_home orphan-identity-evidence)
  old=$(run_keypair "$home" 2>/dev/null) || fail "orphan-evidence keypair setup failed"
  keyfile=$(key_file "$home" "$home/xdg")
  public_file="$home/data/buzz-keypair.public"
  targets="$home/data/buzz-publisher-targets.jsonl"
  relay="ws://127.0.0.1:1/orphan-evidence"
  printf '%s' '{"schema":"fm-bearings.v1","note":"orphan-evidence"}' \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  cache_file=$(find "$home/state/buzz-replay" -type f -name '*.json' | head -1)
  assert_present "$cache_file" "orphan-evidence setup did not create a replay entry"
  cache_name=$(basename "$cache_file")
  targets_before=$(cat "$targets")
  cache_before=$(cat "$cache_file")
  rm "$keyfile" "$public_file"
  history="$home/data/buzz-keypair.public-history"
  unrelated_history_key=$(public_from_private "$(printf '%064d' 8)") \
    || fail "could not derive unrelated orphan-history fixture key"
  printf '%s\n%s\n' "$old" "$unrelated_history_key" > "$history"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with orphan identity evidence"
  assert_contains "$output" "orphan identity evidence exists" \
    "default ensure did not refuse orphan identity evidence"
  assert_contains "$output" "orphan publisher target records present" \
    "default ensure did not name orphan target evidence"
  assert_contains "$output" "$cache_name" \
    "default ensure did not name orphan replay evidence"
  [ "$(cat "$targets")" = "$targets_before" ] || fail "default ensure changed orphan target state"
  [ "$(cat "$cache_file")" = "$cache_before" ] || fail "default ensure changed orphan replay bytes"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "plain rotation with orphan identity evidence"
  assert_contains "$output" "orphan publisher target records are present" \
    "plain rotation did not refuse orphan target state"
  assert_contains "$output" "$cache_name" "plain rotation did not name orphan replay state"
  [ "$(cat "$targets")" = "$targets_before" ] || fail "plain rotation changed orphan target state"
  [ "$(cat "$cache_file")" = "$cache_before" ] || fail "plain rotation changed orphan replay bytes"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 1 "$code" "compromised orphan recovery without cache disposition"
  assert_contains "$output" "retry with --discard-pending-cache" \
    "compromised recovery bypassed the explicit pending-cache disposition"

  output=$(run_keypair "$home" --rotate --compromised --discard-pending-cache 2>&1)
  code=$?
  expect_code 0 "$code" "explicit compromised orphan recovery"
  replacement=$(printf '%s\n' "$output" | tail -1)
  [ "$replacement" != "$old" ] || fail "compromised orphan recovery reused the orphan identity"
  artifact="$home/data/buzz-compromised-unverifiable-pairs.jsonl"
  assert_present "$artifact" "compromised orphan recovery created no durable warning artifact"
  jq -e --arg publisher "$old" 'select(.publisher_pubkey == $publisher)' "$artifact" >/dev/null \
    || fail "compromised orphan recovery artifact omitted the orphan publisher"
  assert_absent "$targets" "compromised orphan recovery left its retired target active"
  assert_absent "$cache_file" "compromised orphan recovery left its replay entry active"
  manifest=$(grep -l 'pending-key-rotation' \
    "$home/state/buzz-replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "compromised orphan recovery did not quarantine pending replay evidence"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$old" \
    "compromised orphan recovery left the orphan publisher trusted in history"
  assert_contains "$(cat "$history" 2>/dev/null)" "$unrelated_history_key" \
    "compromised orphan recovery removed an unrelated historical key"
  assert_contains "$output" "they may be stranded and are recorded in $artifact" \
    "compromised orphan recovery omitted its stranded-pair warning"
  pass "orphan identity evidence requires explicit compromised recovery"
}

test_complete_cache_temporaries_protect_publisher_identity() {
  local rotate_home ensure_home relay channel old private cached temporary output code manifest
  rotate_home=$(make_home complete-temporary-rotation)
  old=$(run_keypair "$rotate_home" 2>/dev/null) || fail "temporary rotation setup failed"
  private=$(jq -r '.private_key' "$(key_file "$rotate_home" "$rotate_home/xdg")")
  relay="ws://127.0.0.1:1/complete-temporary-rotation"
  channel=$(default_channel_id "$rotate_home")
  cached=$(seed_replay_event "$rotate_home" "$relay" "$private" 1700000200 "$channel" complete-temporary) \
    || fail "could not seed the complete temporary rotation fixture"
  temporary="$cached.tmp"
  mv "$cached" "$temporary"

  output=$(run_keypair "$rotate_home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "plain rotation with a fresh complete cache temporary"
  assert_contains "$output" "$temporary" \
    "rotation ignored a complete cache temporary during its identity check"
  [ "$(cat "$rotate_home/data/buzz-keypair.public")" = "$old" ] \
    || fail "rotation changed the identity despite a complete cache temporary"
  assert_present "$temporary" "rotation removed a complete cache temporary without explicit disposition"

  output=$(run_keypair "$rotate_home" --rotate --discard-pending-cache 2>&1)
  code=$?
  expect_code 0 "$code" "explicit rotation disposition for a complete cache temporary"
  assert_absent "$temporary" "explicit rotation disposition left a complete cache temporary active"
  manifest=$(grep -l 'pending-key-rotation' \
    "$rotate_home/state/buzz-replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "explicit rotation disposition did not quarantine the complete temporary"

  ensure_home=$(make_home complete-temporary-ensure)
  old=$(run_keypair "$ensure_home" 2>/dev/null) || fail "temporary ensure setup failed"
  private=$(jq -r '.private_key' "$(key_file "$ensure_home" "$ensure_home/xdg")")
  relay="ws://127.0.0.1:1/complete-temporary-ensure"
  channel=$(default_channel_id "$ensure_home")
  cached=$(seed_replay_event "$ensure_home" "$relay" "$private" 1700000201 "$channel" complete-temporary) \
    || fail "could not seed the complete temporary ensure fixture"
  temporary="$cached.tmp"
  mv "$cached" "$temporary"
  rm -f -- "$(key_file "$ensure_home" "$ensure_home/xdg")" "$ensure_home/data/buzz-keypair.public"

  output=$(run_keypair "$ensure_home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with a fresh complete cache temporary"
  assert_contains "$output" "orphan identity evidence exists" \
    "default ensure ignored a complete cache temporary"
  assert_contains "$output" "$old" \
    "default ensure did not recover publisher identity from a complete temporary"
  assert_contains "$output" "$temporary" \
    "default ensure did not name the complete temporary identity evidence"
  assert_absent "$(key_file "$ensure_home" "$ensure_home/xdg")" \
    "default ensure minted over a complete cache temporary"
  pass "complete cache temporaries protect publisher identity before cleanup age"
}

test_rotation_compares_the_recorded_key_with_stored_private_material() {
  local home other first mismatched history output recovered code
  home=$(make_home rotate-mismatch)
  other=$(make_home rotate-mismatch-other)
  history="$home/data/buzz-keypair.public-history"
  first=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  mismatched=$(run_keypair "$other" 2>/dev/null) || fail "second keypair creation failed"
  printf '%s\n' "$mismatched" > "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "a rotation whose recorded and derived public keys disagree"
  assert_contains "$output" "does not match the stored private key" \
    "the mismatch refusal did not identify the conflicting sources"
  assert_grep "$mismatched" "$home/data/buzz-keypair.public" \
    "the refused mismatch rotation changed the recorded key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$first" \
    "the refused mismatch rotation retained a key before validation completed"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "a compromised rotation whose key records disagree"
  assert_contains "$output" "does not match the stored private key" \
    "the compromised mismatch recovery did not diagnose the mismatch"
  assert_contains "$output" "no outgoing public key will be retained" \
    "the compromised mismatch recovery did not use the no-retention path"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$first" ] || fail "compromised mismatch recovery kept the stored key"
  [ "$recovered" != "$mismatched" ] || fail "compromised mismatch recovery adopted the bad record"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$first" \
    "compromised mismatch recovery retained the derived outgoing key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$mismatched" \
    "compromised mismatch recovery retained the mismatched recorded key"
  pass "rotation compares recorded and derived public keys before retiring either"
}

test_rotation_detects_and_cleans_up_divergent_stores() {
  local tools home keyfile keychain_state keychain_private keychain_public file_public
  local file_before history_before output recovered code
  tools=$(make_fake_keychain_tools)
  home=$(make_home rotate-divergent-stores)
  keyfile=$(key_file "$home" "$home/xdg")
  keychain_state="$home/keychain-private"
  keychain_private=0000000000000000000000000000000000000000000000000000000000000003
  keychain_public=f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9
  file_public=$(run_keypair "$home" 2>/dev/null) || fail "fallback keypair setup failed"
  printf '%s\n' "$keychain_private" > "$keychain_state"
  printf '%s\n%s\n' "$file_public" "$keychain_public" \
    > "$home/data/buzz-keypair.public-history"
  file_before=$(cat "$keyfile")
  history_before=$(cat "$home/data/buzz-keypair.public-history")

  output=$(PATH="$tools:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_FAKE_SECURITY_STATE_FILE="$keychain_state" FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" \
    "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "ordinary rotation with divergent private-key stores"
  assert_contains "$output" "$keychain_public" \
    "the divergence refusal did not identify the keychain public key"
  assert_contains "$output" "$file_public" \
    "the divergence refusal did not identify the fallback public key"
  [ "$(cat "$keychain_state")" = "$keychain_private" ] \
    || fail "ordinary divergence refusal changed the keychain private key"
  [ "$(cat "$keyfile")" = "$file_before" ] \
    || fail "ordinary divergence refusal changed the fallback private key"
  [ "$(cat "$home/data/buzz-keypair.public-history")" = "$history_before" ] \
    || fail "ordinary divergence refusal changed public-key history"
  assert_grep "$file_public" "$home/data/buzz-keypair.public" \
    "ordinary divergence refusal changed the current public record"

  output=$(PATH="$tools:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_FAKE_SECURITY_STATE_FILE="$keychain_state" FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" \
    "$KEYPAIR" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised rotation with divergent private-key stores"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$keychain_public" ] || fail "compromised divergence recovery reused the keychain identity"
  [ "$recovered" != "$file_public" ] || fail "compromised divergence recovery reused the fallback identity"
  assert_absent "$keychain_state" "compromised divergence recovery left the keychain private key"
  [ "$(cat "$keyfile")" != "$file_before" ] \
    || fail "compromised divergence recovery left the fallback private key unchanged"
  assert_not_contains "$(cat "$keyfile" 2>/dev/null)" "$keychain_private" \
    "compromised divergence recovery copied the old keychain key into the fallback store"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$keychain_public" \
    "compromised divergence recovery retained the keychain identity"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$file_public" \
    "compromised divergence recovery retained the fallback identity"
  assert_grep "$recovered" "$home/data/buzz-keypair.public" \
    "compromised divergence recovery did not record the replacement identity"
  pass "rotation refuses divergent stores or purges both through compromised recovery"
}

test_orphaned_public_record_requires_compromised_recovery() {
  local home orphan history keyfile output recovered code
  home=$(make_home rotate-orphan)
  history="$home/data/buzz-keypair.public-history"
  keyfile=$(key_file "$home" "$home/xdg")
  orphan=$(run_keypair "$home" 2>/dev/null) || fail "keypair creation failed"
  rm -f "$keyfile"
  printf '%s\n' "$orphan" > "$history"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "ordinary rotation with an orphaned public record"
  assert_contains "$output" "has no stored private key" \
    "ordinary rotation did not diagnose the inconsistent recorded-key state"
  assert_grep "$orphan" "$home/data/buzz-keypair.public" \
    "ordinary rotation removed the orphaned record instead of refusing"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default key creation with an orphaned public record"
  assert_contains "$output" "recover with --rotate --compromised" \
    "default key creation did not preserve the explicit orphan recovery path"
  assert_grep "$orphan" "$home/data/buzz-keypair.public" \
    "default key creation overwrote the orphaned public record"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised rotation with an orphaned public record"
  assert_contains "$output" "no outgoing public key will be retained" \
    "compromised orphan recovery did not identify its no-retention path"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$orphan" ] || fail "compromised orphan recovery reused the orphaned key"
  assert_grep "$recovered" "$home/data/buzz-keypair.public" \
    "compromised orphan recovery did not record the replacement key"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$orphan" \
    "compromised orphan recovery retained the orphaned key"
  pass "orphaned public records require explicit compromised recovery"
}

test_forget_key_refuses_when_history_cannot_be_read() {
  local tools home retired history before output code
  tools=$(make_forget_read_failure_tools)
  home=$(make_home forget-key-read-error)
  history="$home/data/buzz-keypair.public-history"
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"
  run_keypair "$home" --rotate >/dev/null 2>&1 || fail "rotation fixture setup failed"
  before=$(cat "$history")

  output=$(PATH="$tools:$PATH" run_keypair "$home" --forget-key "$retired" 2>&1)
  code=$?
  expect_code 1 "$code" "--forget-key when public-key history cannot be read"
  assert_contains "$output" "could not read $history" \
    "--forget-key treated a history read error as an absent key"
  [ "$(cat "$history")" = "$before" ] || fail "failed --forget-key changed public-key history"
  pass "--forget-key refuses when public-key history cannot be read"
}

test_malformed_public_history_is_never_rewritten() {
  local home retired history before output code
  home=$(make_home malformed-public-history)
  run_keypair "$home" >/dev/null 2>&1 || fail "malformed history setup failed"
  retired=$(printf '%064d' 7)
  history="$home/data/buzz-keypair.public-history"
  printf '%s\n%s\n' "$retired" 'not-a-public-key' > "$history"
  before=$(cat "$history")

  output=$(run_keypair "$home" --forget-key "$retired" 2>&1)
  code=$?
  expect_code 1 "$code" "--forget-key with malformed public-key history"
  assert_contains "$output" "could not read $history" \
    "a malformed history record was silently dropped"
  [ "$(cat "$history")" = "$before" ] \
    || fail "failed malformed-history validation rewrote recoverable evidence"
  pass "malformed public-key history remains intact"
}

test_keychain_errors_refuse_rotation_without_minting_a_fallback_key() {
  local tools private public home lookup_home forced_home forced_public output code fallback
  tools=$(make_fake_keychain_tools)
  private=0000000000000000000000000000000000000000000000000000000000000003
  public=f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9

  home=$(make_home keychain-delete-error)
  printf '%s\n' "$public" > "$home/data/buzz-keypair.public"
  output=$(PATH="$tools:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    XDG_DATA_HOME="$home/xdg" FM_FAKE_SECURITY_FIND=found \
    FM_FAKE_SECURITY_PRIVATE="$private" FM_FAKE_SECURITY_DELETE=error \
    FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation when keychain deletion fails"
  assert_contains "$output" "could not verify removal of the old key" \
    "keychain deletion failure was mistaken for successful absence"
  fallback=$(key_file "$home" "$home/xdg")
  assert_absent "$fallback" "rotation minted a fallback key while the keychain entry remained"
  assert_grep "$public" "$home/data/buzz-keypair.public" \
    "failed keychain deletion disturbed the current public key record"

  lookup_home=$(make_home keychain-lookup-error)
  printf '%s\n' "$public" > "$lookup_home/data/buzz-keypair.public"
  output=$(PATH="$tools:$PATH" FM_HOME="$lookup_home" FM_DATA_OVERRIDE="$lookup_home/data" \
    XDG_DATA_HOME="$lookup_home/xdg" FM_FAKE_SECURITY_FIND=error \
    FM_FAKE_SECURITY_DELETE=not-found FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" \
    "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation when the keychain cannot be read"
  assert_contains "$output" "login keychain could not be read" \
    "keychain lookup failure was mistaken for an absent key"
  fallback=$(key_file "$lookup_home" "$lookup_home/xdg")
  assert_absent "$fallback" "lookup failure minted a fallback key that could shadow the keychain entry"

  forced_home=$(make_home force-file-keychain-error)
  forced_public=$(run_keypair "$forced_home" 2>/dev/null) || fail "forced-file keypair setup failed"
  output=$(PATH="$tools:$PATH" FM_HOME="$forced_home" FM_DATA_OVERRIDE="$forced_home/data" \
    XDG_DATA_HOME="$forced_home/xdg" FM_BUZZ_FORCE_FILE_STORE=1 \
    FM_FAKE_SECURITY_FIND=error FM_FAKE_SECURITY_DELETE=not-found \
    FM_BUZZ_RELAY="$ROTATION_GUARD_RELAY" "$KEYPAIR" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "forced-file rotation when preferred-store absence is unverifiable"
  assert_contains "$output" "login keychain could not be read" \
    "forced-file rotation skipped inspection of the preferred keychain store"
  assert_grep "$forced_public" "$forced_home/data/buzz-keypair.public" \
    "failed forced-file rotation disturbed the current public key record"
  pass "keychain lookup and deletion errors refuse rotation without fallback minting"
}

test_public_record_failures_are_fatal_and_retryable() {
  local tools create_home create_file create_output create_private retry_private created code
  local rotate_home rotate_file old rotate_output rotated_private retry_rotated replacement
  tools=$(make_public_record_failure_tools)

  create_home=$(make_home public-record-create-failure)
  create_file=$(key_file "$create_home" "$create_home/xdg")
  create_output=$(PATH="$tools:$PATH" FM_FAIL_BUZZ_PUBLIC_MV=1 run_keypair "$create_home" 2>&1)
  code=$?
  expect_code 1 "$code" "key creation when the public record cannot be persisted"
  assert_contains "$create_output" "private key remains stored for a safe retry" \
    "creation did not diagnose its retryable public-record failure"
  assert_absent "$create_home/data/buzz-keypair.public" \
    "creation reported a failed public record but left one behind"
  create_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$create_file")
  created=$(PATH="$tools:$PATH" run_keypair "$create_home" 2>/dev/null) \
    || fail "creation retry did not repair the public record"
  retry_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$create_file")
  [ "$create_private" = "$retry_private" ] || fail "creation retry replaced retained private material"
  assert_grep "$created" "$create_home/data/buzz-keypair.public" \
    "creation retry did not persist the retained key's public record"

  rotate_home=$(make_home public-record-rotate-failure)
  rotate_file=$(key_file "$rotate_home" "$rotate_home/xdg")
  old=$(run_keypair "$rotate_home" 2>/dev/null) || fail "rotation fixture setup failed"
  rotate_output=$(PATH="$tools:$PATH" FM_FAIL_BUZZ_PUBLIC_MV=1 \
    run_keypair "$rotate_home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation when the replacement public record cannot be persisted"
  assert_contains "$rotate_output" "private key remains stored for a safe retry" \
    "rotation did not diagnose its retryable public-record failure"
  [ "$(cat "$rotate_home/data/buzz-keypair.public")" = "$old" ] \
    || fail "failed rotation removed the last recoverable public identity record"
  rotated_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$rotate_file")
  replacement=$(PATH="$tools:$PATH" run_keypair "$rotate_home" 2>/dev/null) \
    || fail "rotation retry did not repair the public record"
  retry_rotated=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$rotate_file")
  [ "$rotated_private" = "$retry_rotated" ] || fail "rotation retry replaced retained private material"
  [ "$replacement" != "$old" ] || fail "rotation failure did not retain the replacement private key"
  assert_grep "$old" "$rotate_home/data/buzz-keypair.public-history" \
    "failed public-record persistence lost the ordinarily retired key"
  pass "public record failures are fatal while retained private material makes retry safe"
}

test_key_record_targets_reject_non_files() {
  local fallback_home fallback output code public_home public_target history_home old history_target

  fallback_home=$(make_home fallback-directory-target)
  fallback=$(key_file "$fallback_home" "$fallback_home/xdg")
  mkdir -p "$fallback"
  output=$(
    # shellcheck disable=SC2031
    export XDG_DATA_HOME="$fallback_home/xdg" FM_BUZZ_FORCE_FILE_STORE=1
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-buzz-key-lib.sh"
    fm_buzz_key_store "$fallback_home" \
      0000000000000000000000000000000000000000000000000000000000000003
  )
  code=$?
  expect_code 1 "$code" "fallback storage with a directory target"
  [ -z "$output" ] || fail "fallback storage reported success for a directory target"
  [ -z "$(find "$fallback" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the fallback writer moved its temporary file into a directory target"

  public_home=$(make_home public-directory-symlink-target)
  run_keypair "$public_home" >/dev/null 2>&1 || fail "public target fixture setup failed"
  rm -f "$public_home/data/buzz-keypair.public"
  public_target="$public_home/data/public-target"
  mkdir "$public_target"
  ln -s "$(basename "$public_target")" "$public_home/data/buzz-keypair.public"
  output=$(run_keypair "$public_home" 2>&1)
  code=$?
  expect_code 1 "$code" "key creation with a public-record directory symlink"
  assert_contains "$output" "could not record" \
    "a public-record directory symlink was treated as a successful write"
  [ -z "$(find "$public_target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the public-record writer moved its temporary file through a directory symlink"

  history_home=$(make_home history-directory-symlink-target)
  old=$(run_keypair "$history_home" 2>/dev/null) || fail "history target fixture setup failed"
  history_target="$history_home/data/history-target"
  mkdir "$history_target"
  ln -s "$(basename "$history_target")" "$history_home/data/buzz-keypair.public-history"
  output=$(run_keypair "$history_home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "rotation with a history directory symlink"
  assert_contains "$output" "history target" \
    "rotation did not diagnose the invalid public-key history target"
  [ "$(run_keypair "$history_home" --public 2>/dev/null)" = "$old" ] \
    || fail "rotation mutated the key before rejecting the history directory symlink"
  [ -z "$(find "$history_target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "the history writer moved its temporary file through a directory symlink"
  pass "public, history, and fallback records reject non-file targets"
}

test_key_record_replace_is_exact_destination() {
  local tools home target output code
  tools=$(make_public_record_failure_tools)
  home=$(make_home exact-key-record-replace)
  target="$home/data/buzz-keypair.public"

  output=$(PATH="$tools:$PATH" FM_RACE_BUZZ_REPLACE_TARGET="$target" \
    run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "public record replacement raced by a directory target"
  assert_contains "$output" "could not record" \
    "a directory race was treated as successful public-record persistence"
  [ -d "$target" ] || fail "the exact-destination race fixture was unexpectedly replaced"
  [ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "record replacement redirected its temporary file inside the raced directory"
  pass "key record replacement cannot be redirected by a directory race"
}

test_keypair_transactions_are_serialized_per_home() {
  local home ready output holder worker waited current lock
  home=$(make_home serialized-keypair)
  ready="$home/key-lock-ready"
  output="$home/keypair-output"
  lock=$(bash -c '. "$1"; fm_buzz_key_transaction_lock "$2"' \
    _ "$ROOT/bin/fm-buzz-key-lib.sh" "$home/data") \
    || fail "could not resolve the shared key transaction lock"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    : > "$3"
    sleep 1
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$ready" &
  holder=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "the keypair lock fixture did not acquire its lock"

  run_keypair "$home" > "$output" 2>&1 &
  worker=$!
  sleep 0.1
  kill -0 "$worker" 2>/dev/null \
    || fail "keypair creation did not wait for the active per-home transaction"
  assert_absent "$home/data/buzz-keypair.public" \
    "keypair creation mutated public state before acquiring the transaction lock"

  wait "$holder" || fail "the keypair lock fixture failed"
  wait "$worker" || fail "serialized keypair creation failed"
  current=$(run_keypair "$home" --public 2>/dev/null) || fail "serialized keypair was unreadable"
  [ "$(tail -1 "$output")" = "$current" ] \
    || fail "serialized keypair output disagrees with its recorded identity"
  ! grep -F '.buzz-keypair.lock' "$ROOT/bin/fm-buzz-keypair.sh" "$ROOT/bin/fm-buzz-publish.sh" >/dev/null \
    || fail "a key transaction caller duplicated the lock-path contract"
  pass "keypair ensure, rotation, and withdrawal share one home transaction lock"
}

test_public_read_cannot_restore_a_concurrently_retired_identity() {
  local home tools ready release output reader waited old rotated observed recorded
  home=$(make_home concurrent-public-read)
  tools=$(make_delayed_derive_tools)
  ready="$home/public-derive-ready"
  release="$home/public-derive-release"
  output="$home/public-output"
  old=$(run_keypair "$home" 2>/dev/null) || fail "concurrent public-read fixture setup failed"

  (PATH="$tools:$PATH" FM_DELAY_BUZZ_DERIVE_READY="$ready" \
    FM_DELAY_BUZZ_DERIVE_RELEASE="$release" run_keypair "$home" --public > "$output" 2>&1) &
  reader=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || {
    kill "$reader" 2>/dev/null
    fail "the public read did not pause after loading the outgoing key"
  }

  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || {
    : > "$release"
    wait "$reader" 2>/dev/null
    fail "rotation failed while the public read was paused"
  }
  : > "$release"
  wait "$reader" || fail "the concurrent public read failed"

  observed=$(tail -1 "$output")
  recorded=$(cat "$home/data/buzz-keypair.public")
  [ "$observed" = "$old" ] || fail "the paused public read did not observe the outgoing identity"
  [ "$recorded" = "$rotated" ] \
    || fail "a read-only --public call restored the concurrently retired identity"
  pass "--public cannot rewrite a public record after concurrent rotation"
}

test_public_read_cannot_commit_a_rotation_stage() {
  local home old staged_private staged_public stage output stored_public
  home=$(make_home public-read-stage)
  old=$(run_keypair "$home" 2>/dev/null) || fail "public-stage keypair setup failed"
  staged_private=$(new_private_key) || fail "could not mint a public-stage replacement"
  staged_public=$(public_from_private "$staged_private") || fail "could not derive the public-stage replacement"
  stage=$(rotation_stage_file "$home")
  write_rotation_stage "$home" committable "$staged_private" "$staged_public"

  output=$(run_keypair "$home" --public 2>/dev/null) \
    || fail "read-only --public failed with a committable stage present"
  [ "$output" = "$old" ] || fail "--public exposed or installed the staged identity"
  assert_present "$stage" "--public cleared a committable rotation stage"
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "--public rewrote the current public record from a rotation stage"
  stored_public=$(public_from_private "$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")") \
    || fail "could not derive the key retained after --public"
  [ "$stored_public" = "$old" ] || fail "--public stored staged private material"
  pass "--public remains read-only when a committable rotation stage exists"
}

test_public_key_history_is_normalized_consistently() {
  local home history first first_upper second second_upper third
  home=$(make_home normalized-history)
  history="$home/data/buzz-keypair.public-history"
  first=$(run_keypair "$home" 2>/dev/null) || fail "normalized history fixture setup failed"
  first_upper=$(printf '%s' "$first" | tr 'a-f' 'A-F')
  printf '  %s  \r\n%s\n' "$first_upper" "$first" > "$history"

  second=$(run_keypair "$home" --rotate 2>/dev/null) || fail "normalized history rotation failed"
  [ "$(cat "$history")" = "$first" ] \
    || fail "ordinary rotation did not normalize and deduplicate public-key history"

  second_upper=$(printf '%s' "$second" | tr 'a-f' 'A-F')
  printf '\t%s\r\n %s \n' "$first_upper" "$second_upper" > "$history"
  third=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "normalized compromised rotation failed"
  [ "$third" != "$second" ] || fail "compromised rotation did not replace the current key"
  [ "$(cat "$history")" = "$first" ] \
    || fail "compromised rotation did not normalize history while purging the outgoing key"

  printf '  %s  \r\n' "$first_upper" > "$history"
  run_keypair "$home" --forget-key "$first" >/dev/null 2>&1 \
    || fail "--forget-key did not match a normalized history entry"
  assert_absent "$history" "--forget-key left a case- or whitespace-variant history entry trusted"
  pass "public-key history uses one normalization for retention, purge, and withdrawal"
}

test_public_flag_fails_before_a_keypair_exists() {
  local home output code
  home=$(make_home public-first)
  output=$(run_keypair "$home" --public 2>&1)
  code=$?
  expect_code 1 "$code" "--public with no keypair"
  assert_contains "$output" "no keypair exists yet" "--public gave an unhelpful error"
  pass "--public refuses before a keypair exists"
}

# --- (b) relay down --------------------------------------------------------

test_rotation_stages_the_replacement_before_clearing_the_outgoing_key() {
  local home stage first staged_private staged_public output code recovered mode
  home=$(make_home rotate-staging)
  first=$(run_keypair "$home" 2>/dev/null) || fail "staging keypair setup failed"
  stage=$(rotation_stage_file "$home")

  # An ordinary rotation must leave nothing behind: the stage exists only between
  # the outgoing key being cleared and the replacement being recorded.
  output=$(run_keypair "$home" --rotate 2>&1)
  expect_code 0 "$?" "an ordinary rotation with the replacement staged first"
  assert_absent "$stage" "a completed rotation left its replacement staged"

  # The crash this staging exists for: the outgoing private key is gone and only
  # the public record survives. Without a stage that is the orphan state, which
  # needs --rotate --compromised; with one the next run simply finishes the job.
  staged_private=$(new_private_key) || fail "could not mint a staged replacement"
  staged_public=$(public_from_private "$staged_private") || fail "could not derive the staged key"
  write_rotation_stage "$home" committable "$staged_private" "$staged_public"
  mode=$(file_mode "$stage")
  [ "$mode" = "600" ] || fail "the rotation stage holds key material at mode $mode"
  rm -f -- "$(key_file "$home" "$home/xdg")"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 0 "$code" "an interrupted rotation must be completable, not orphan recovery"
  assert_contains "$output" "completed staged buzz publishing key replacement" \
    "the interrupted rotation was not recognised as completable"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" = "$staged_public" ] \
    || fail "the recovered identity is not the staged replacement"
  assert_grep "$staged_public" "$home/data/buzz-keypair.public" \
    "the completed staged replacement was not recorded"
  assert_absent "$stage" "completing the staged replacement left the stage behind"
  [ "$(run_keypair "$home" --public 2>/dev/null)" = "$staged_public" ] \
    || fail "the staged replacement was recorded without being stored"
  pass "rotation stages and verifies the replacement before clearing the outgoing key"
}

test_compromised_rotation_stage_preserves_withdrawal_intent() {
  local home old stage staged_private staged_public output code recovered
  home=$(make_home compromised-rotation-stage)
  old=$(run_keypair "$home" 2>/dev/null) || fail "compromised-stage keypair setup failed"
  stage=$(rotation_stage_file "$home")
  staged_private=$(new_private_key) || fail "could not mint the compromised staged replacement"
  staged_public=$(public_from_private "$staged_private") \
    || fail "could not derive the compromised staged replacement"
  write_rotation_stage "$home" prepared "$staged_private" "$staged_public" compromised

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "a plain retry of a staged compromised rotation"
  assert_contains "$output" "retry with --rotate --compromised" \
    "a staged compromised rotation lost its withdrawal intent"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$old" \
    "a plain retry re-trusted the compromised outgoing identity"
  assert_present "$stage" "a rejected plain retry discarded the staged replacement"

  recovered=$(run_keypair "$home" --rotate --compromised 2>/dev/null) \
    || fail "the compromised rotation could not resume with its original intent"
  [ "$recovered" = "$staged_public" ] || fail "the compromised retry replaced its staged identity"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$old" \
    "the resumed compromised rotation retained the withdrawn identity"
  pass "staged compromised rotation intent survives an interrupted history withdrawal"
}

test_orphan_gate_sees_legacy_replay_publisher_evidence() {
  local home relay foreign_private foreign_public seeded channel flat host_dir
  local output code recovered
  home=$(make_home orphan-legacy-replay)
  run_keypair "$home" >/dev/null 2>&1 || fail "legacy orphan keypair setup failed"
  relay="ws://127.0.0.1:1"
  channel=$(default_channel_id "$home")
  foreign_private=$(new_private_key) || fail "could not mint a legacy publisher"
  foreign_public=$(public_from_private "$foreign_private") || fail "could not derive the legacy publisher"
  seeded=$(seed_replay_event "$home" "$relay" "$foreign_private" 1700000000 "$channel" legacy-orphan) \
    || fail "could not seed a replay event"

  # Flat and host-keyed entries are the two pre-endpoint-digest layouts. Neither is
  # ever delivered, but both name the publisher that signed them, so both have to
  # reach the orphan gate.
  flat="$home/state/buzz-replay/$(basename "$seeded")"
  mv "$seeded" "$flat"
  host_dir="$home/state/buzz-replay/127.0.0.1%3A1"
  mkdir -p "$host_dir"
  cp "$flat" "$host_dir/"

  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"
  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "an ensure over legacy replay evidence from another publisher"
  assert_contains "$output" "orphan identity evidence exists" \
    "the orphan gate ignored legacy replay evidence"
  assert_contains "$output" "$foreign_public" \
    "the orphan gate did not name the legacy publisher"
  assert_contains "$output" "buzz-replay/$(basename "$flat")" \
    "the orphan gate did not name the flat legacy entry"
  assert_contains "$output" "$(basename "$host_dir")/$(basename "$flat")" \
    "the orphan gate did not name the host-keyed legacy entry"

  output=$(run_keypair "$home" --rotate --compromised 2>&1)
  code=$?
  expect_code 0 "$code" "compromised recovery over legacy orphan evidence"
  recovered=$(printf '%s\n' "$output" | tail -1)
  [ "$recovered" != "$foreign_public" ] || fail "compromised recovery adopted the legacy publisher"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$foreign_public" \
    "compromised recovery retained the legacy orphan identity"
  pass "orphan identity inspection covers flat and host-keyed legacy replay entries"
}

test_orphan_gate_preserves_publisher_evidence_after_legacy_quarantine() {
  local home relay private publisher channel seeded flat replay manifest output code
  home=$(make_home orphan-quarantined-legacy)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantined orphan setup failed"
  relay="ws://127.0.0.1:1/quarantined-orphan"
  private=$(new_private_key) || fail "could not mint a quarantined legacy publisher"
  publisher=$(public_from_private "$private") || fail "could not derive the quarantined legacy publisher"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" quarantined-orphan) \
    || fail "could not seed quarantined orphan evidence"
  replay="$home/state/buzz-replay"
  flat="$replay/$(basename "$seeded")"
  mv "$seeded" "$flat"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not quarantine the valid legacy publisher fixture"
  manifest=$(grep -l "$publisher" "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "legacy quarantine did not retain its validated publisher identity"
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with quarantined legacy identity evidence"
  assert_contains "$output" "orphan identity evidence exists" \
    "the orphan gate ignored quarantined legacy evidence"
  assert_contains "$output" "$publisher" \
    "the orphan gate lost the publisher recorded by legacy quarantine"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over quarantined legacy identity evidence"
  pass "legacy quarantine preserves publisher identity for orphan recovery"
}

test_orphan_gate_includes_quarantine_manifest_temporaries() {
  local home relay private publisher channel seeded replay flat manifest temporary output code
  home=$(make_home orphan-quarantine-manifest-temporary)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine manifest temporary setup failed"
  relay="ws://127.0.0.1:1/quarantine-manifest-temporary"
  private=$(new_private_key) || fail "could not mint a quarantine temporary publisher"
  publisher=$(public_from_private "$private") || fail "could not derive the quarantine temporary publisher"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" quarantine-temporary) \
    || fail "could not seed quarantine temporary evidence"
  replay="$home/state/buzz-replay"
  flat="$replay/$(basename "$seeded")"
  mv "$seeded" "$flat"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not create quarantine temporary evidence"
  manifest=$(grep -l "$publisher" "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "quarantine temporary fixture has no publisher manifest"
  temporary="$manifest.tmp"
  mv "$manifest" "$temporary"
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with quarantine manifest temporary evidence"
  assert_contains "$output" "orphan identity evidence exists" \
    "the orphan gate ignored a quarantine manifest temporary"
  assert_contains "$output" "$publisher" \
    "the orphan gate lost the temporary manifest publisher"
  assert_contains "$output" "$temporary" \
    "the orphan gate did not name the temporary manifest evidence"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over temporary quarantine evidence"
  pass "quarantine manifest temporaries preserve publisher identity"
}

test_orphan_gate_preserves_corrupt_partition_publisher_evidence() {
  local home relay private publisher channel seeded replay corrupt_name corrupt_path manifest payload output code
  home=$(make_home orphan-corrupt-partition-publisher)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "corrupt partition publisher setup failed"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  relay="ws://127.0.0.1:1/corrupt-partition-publisher"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000202 "$channel" corrupt-partition-publisher) \
    || fail "could not seed corrupt partition publisher evidence"
  replay="$home/state/buzz-replay"
  corrupt_name=$(printf '%064d' 7)
  corrupt_path="$replay/$corrupt_name"
  mv "$seeded" "$corrupt_path"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not quarantine the partition-shaped signed payload"
  manifest=$(find "$replay/_legacy-quarantine/manifests" -type f -name '*.json' -print \
    | while IFS= read -r candidate; do
        jq -e --arg publisher "$publisher" '.publisher_pubkey == $publisher and .corrupt_type == "regular-file"' \
          "$candidate" >/dev/null 2>&1 && { printf '%s\n' "$candidate"; break; }
      done)
  [ -n "$manifest" ] || fail "corrupt partition quarantine dropped validated publisher metadata"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  assert_present "$payload" "corrupt partition manifest does not reference retained publisher evidence"
  if ! jq '.publisher_pubkey = null' "$manifest" > "$manifest.tmp"; then
    fail "could not rewrite the corrupt-partition manifest fixture"
  fi
  if ! mv "$manifest.tmp" "$manifest"; then
    fail "could not simulate an older corrupt-partition manifest without publisher metadata"
  fi
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with corrupt-partition quarantine evidence"
  assert_contains "$output" "orphan identity evidence exists" \
    "the orphan gate ignored corrupt-partition quarantine evidence"
  assert_contains "$output" "$publisher" \
    "the orphan gate did not recover the publisher from the retained corrupt payload"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over corrupt-partition publisher evidence"
  pass "corrupt partition quarantine preserves validated publisher identity"
}

test_orphan_gate_includes_interrupted_corrupt_quarantine_transactions() {
  local home private publisher relay channel seeded replay corrupt_path manifest payload
  local transaction token origin output code
  home=$(make_home orphan-interrupted-corrupt-quarantine)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "interrupted corrupt quarantine setup failed"
  private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  relay="ws://127.0.0.1:1/interrupted-corrupt-quarantine"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000203 "$channel" interrupted-corrupt) \
    || fail "could not seed interrupted corrupt quarantine evidence"
  replay="$home/state/buzz-replay"
  corrupt_path="$replay/$(printf '%064d' 8)"
  mv "$seeded" "$corrupt_path"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not create the interrupted corrupt quarantine fixture"
  manifest=$(grep -l "$publisher" "$replay/_legacy-quarantine/manifests"/*.json 2>/dev/null | head -1)
  [ -n "$manifest" ] || fail "interrupted corrupt quarantine fixture has no publisher manifest"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  transaction=$(dirname "$payload")
  token=$(basename "$transaction")
  origin="$transaction/origin.json"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const [manifestFile, originFile, token] = process.argv.slice(1);
    const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
    fs.writeFileSync(originFile, `${JSON.stringify({ token, manifest }, null, 2)}\n`);
    fs.unlinkSync(manifestFile);
  ' "$manifest" "$origin" "$token" || fail "could not interrupt corrupt quarantine finalization"
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with interrupted corrupt quarantine evidence"
  assert_contains "$output" "$publisher" \
    "the orphan gate ignored the interrupted corrupt quarantine publisher"
  assert_contains "$output" "$origin" \
    "the orphan gate did not name the interrupted corrupt quarantine record"
  assert_present "$payload" "read-only orphan inspection removed interrupted corrupt evidence"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over interrupted corrupt quarantine evidence"
  pass "interrupted corrupt quarantine transactions remain visible to orphan recovery"
}

test_orphan_gate_validates_quarantine_payloads_without_filename_trust() {
  local home relay private publisher channel seeded flat replay manifest payload output code
  home=$(make_home orphan-quarantine-payload)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine payload setup failed"
  relay="ws://127.0.0.1:1/quarantine-payload"
  private=$(new_private_key) || fail "could not mint a quarantine payload publisher"
  publisher=$(public_from_private "$private") || fail "could not derive the quarantine payload publisher"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" quarantine-payload) \
    || fail "could not seed quarantine payload evidence"
  replay="$home/state/buzz-replay"
  flat="$replay/not-a-cache-filename.json"
  mv "$seeded" "$flat"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not quarantine the mismatched-filename payload"
  manifest=$(find "$replay/_legacy-quarantine/manifests" -type f -name '*.json' -print | head -1)
  [ -n "$manifest" ] || fail "mismatched-filename payload has no quarantine manifest"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    value.publisher_pubkey = null;
    value.original_path = "not-a-cache-filename.json";
    fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  ' "$manifest"
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with filename-independent quarantine evidence"
  assert_contains "$output" "$publisher" \
    "the orphan gate trusted a quarantine filename instead of the signed payload"
  assert_contains "$output" "$payload" \
    "the orphan gate did not name the signed quarantine payload"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over filename-independent quarantine evidence"
  pass "quarantine payload authorship does not depend on cache filenames"
}

test_orphan_gate_fails_closed_on_unreadable_quarantine_payloads() {
  local home relay private channel seeded flat replay manifest payload tools real_python output code
  home=$(make_home orphan-quarantine-read-error)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine read-error setup failed"
  relay="ws://127.0.0.1:1/quarantine-read-error"
  private=$(new_private_key) || fail "could not mint a quarantine read-error publisher"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" quarantine-read-error) \
    || fail "could not seed quarantine read-error evidence"
  replay="$home/state/buzz-replay"
  flat="$replay/not-a-cache-filename.json"
  mv "$seeded" "$flat"
  node -e '
    import(process.argv[1]).then(({ migrateReplayCache }) => {
      const result = migrateReplayCache(process.argv[2]);
      if (result.legacy.length || result.endpoint.length) process.exitCode = 1;
    });
  ' "$ROOT/bin/fm-buzz-publish.mjs" "$replay" \
    || fail "could not quarantine the read-error payload"
  manifest=$(find "$replay/_legacy-quarantine/manifests" -type f -name '*.json' -print | head -1)
  [ -n "$manifest" ] || fail "quarantine read-error payload has no manifest"
  payload="$replay/_legacy-quarantine/$(jq -r '.payload_reference' "$manifest")"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const value = JSON.parse(fs.readFileSync(file, "utf8"));
    value.publisher_pubkey = null;
    fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  ' "$manifest"
  tools="$home/tools"
  mkdir -p "$tools"
  real_python=$(command -v python3)
  cat > "$tools/python3" <<'EOF'
#!/usr/bin/env bash
case ${3:-} in
  *'"operation":"read_regular"'*'"name":"'"$FM_TEST_UNREADABLE_QUARANTINE_NAME"'"'*)
    parent=$("$FM_TEST_REAL_PYTHON" -c 'import os; os.fchdir(3); print(os.getcwd())')
    if [ "$parent/$FM_TEST_UNREADABLE_QUARANTINE_NAME" = "$FM_TEST_UNREADABLE_QUARANTINE_PAYLOAD" ]; then
      printf '%s\n' '{"ok":false,"code":"EACCES","message":"simulated quarantine payload read failure"}' >&2
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_PYTHON" "$@"
EOF
  chmod +x "$tools/python3"
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(PATH="$tools:$PATH" FM_TEST_REAL_PYTHON="$real_python" \
    FM_TEST_UNREADABLE_QUARANTINE_NAME="$(basename "$payload")" \
    FM_TEST_UNREADABLE_QUARANTINE_PAYLOAD="$payload" \
    run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with an unreadable quarantine payload"
  assert_contains "$output" "could not read legacy quarantine payload $payload" \
    "an unreadable quarantine payload was treated as absent identity evidence"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over uninspectable quarantine evidence"
  pass "uninspectable quarantine payloads keep orphan recovery fail closed"
}

test_orphan_gate_validates_quarantine_manifest_variants() {
  local home replay quarantine token payload manifest output code
  home=$(make_home orphan-malformed-quarantine-manifest)
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  token=$(printf '%064d' 81)
  payload="$quarantine/payloads/$token.json"
  manifest="$quarantine/manifests/$token.json"
  mkdir -p "$quarantine/payloads" "$quarantine/manifests"
  printf '{}\n' > "$payload"
  jq -cn --arg token "$token" '{
    original_path:"legacy.json",
    payload_reference:("payloads/" + $token + ".json"),
    publisher_pubkey:null
  }' > "$manifest"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with a malformed regular quarantine manifest"
  assert_contains "$output" "quarantine manifest" \
    "a malformed null-publisher manifest was silently treated as no evidence"
  assert_contains "$output" "malformed" \
    "the malformed quarantine manifest was not diagnosed"
  assert_absent "$home/data/buzz-keypair.public" \
    "a malformed quarantine manifest allowed a replacement identity"

  home=$(make_home orphan-valid-recovery-residue)
  replay="$home/state/buzz-replay"
  quarantine="$replay/_legacy-quarantine"
  mkdir -p "$quarantine/recovery-corrupt" "$quarantine/manifests"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("node:fs");
    const { createHash } = require("node:crypto");
    const quarantine = process.argv[1];
    const source = `${quarantine}/recovery-corrupt/fixture.invalid`;
    const originalPath = "manifests/interrupted.json.tmp";
    fs.writeFileSync(source, "invalid recovery bytes\n");
    const metadata = fs.statSync(source);
    const token = createHash("sha256").update(JSON.stringify({
      original_path: originalPath,
      device: metadata.dev,
      inode: metadata.ino,
    })).digest("hex");
    const payload = `${quarantine}/recovery-corrupt/${token}.invalid`;
    const manifest = `${quarantine}/manifests/${token}.json`;
    fs.renameSync(source, payload);
    fs.writeFileSync(manifest, JSON.stringify({
      original_path: originalPath,
      legacy_host: null,
      original_timestamps: {
        atime_ms: metadata.atimeMs,
        mtime_ms: metadata.mtimeMs,
        ctime_ms: metadata.ctimeMs,
        birthtime_ms: metadata.birthtimeMs,
      },
      quarantine_timestamp: new Date(0).toISOString(),
      payload_reference: "recovery-corrupt/" + token + ".invalid",
      source_device: metadata.dev,
      source_inode: metadata.ino,
      corrupt_type: "invalid-quarantine-recovery-residue",
      recovery_error: "fixture",
    }, null, 2) + "\n");
  ' "$quarantine" || fail "could not create the recovery-residue fixture"
  run_keypair "$home" >/dev/null 2>&1 \
    || fail "a valid recovery-residue manifest blocked first key creation"
  assert_present "$home/data/buzz-keypair.public" \
    "valid recovery residue was not distinguished from unresolved publisher evidence"
  pass "orphan inspection validates every null-publisher quarantine manifest variant"
}

test_orphan_gate_includes_recoverable_quarantine_staging() {
  local home relay private publisher channel seeded replay token transaction output code
  home=$(make_home orphan-quarantine-staging)
  run_keypair "$home" >/dev/null 2>&1 || fail "quarantine staging setup failed"
  relay="ws://127.0.0.1:1/quarantine-staging"
  private=$(new_private_key) || fail "could not mint a quarantine staging publisher"
  publisher=$(public_from_private "$private") || fail "could not derive the quarantine staging publisher"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$private" 1700000000 "$channel" quarantine-staging) \
    || fail "could not seed quarantine staging evidence"
  replay="$home/state/buzz-replay"
  transaction="$replay/_legacy-quarantine/staging/fixture"
  mkdir -p "$transaction" "$replay/_legacy-quarantine/payloads"
  mv "$seeded" "$transaction/source"
  # shellcheck disable=SC2016
  token=$(node -e '
    const fs = require("fs");
    const path = require("node:path");
    const { createHash } = require("node:crypto");
    const fixture = process.argv[1];
    const quarantine = process.argv[2];
    const source = path.join(fixture, "source");
    const originalPath = "legacy/staged.json";
    const metadata = fs.statSync(source);
    const token = createHash("sha256").update(JSON.stringify({
      original_path: originalPath,
      device: metadata.dev,
      inode: metadata.ino,
    })).digest("hex");
    const transaction = path.join(quarantine, "staging", token);
    fs.renameSync(fixture, transaction);
    fs.writeFileSync(path.join(transaction, "origin.json"), `${JSON.stringify({
      original_path: originalPath,
      transaction_token: token,
      payload_reference: `payloads/${token}.json`,
      source_device: metadata.dev,
      source_inode: metadata.ino,
      publisher_pubkey: null,
    }, null, 2)}\n`);
    process.stdout.write(token);
  ' "$transaction" "$replay/_legacy-quarantine")
  transaction="$replay/_legacy-quarantine/staging/$token"
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure with staged quarantine identity evidence"
  assert_contains "$output" "$publisher" \
    "the orphan gate ignored the publisher in a recoverable staging transaction"
  assert_contains "$output" "$transaction/source" \
    "the orphan gate did not name the staged signed payload"
  assert_present "$transaction/source" "read-only orphan inspection completed or removed staging"
  assert_absent "$(key_file "$home" "$home/xdg")" \
    "default ensure minted over staged quarantine identity evidence"
  pass "recoverable quarantine staging remains visible to orphan inspection"
}

test_orphan_identity_inspection_does_not_mutate_endpoint_replay() {
  local home relay channel seeded endpoint_file before output code
  home=$(make_home orphan-read-only-replay)
  run_keypair "$home" >/dev/null 2>&1 || fail "orphan read-only keypair setup failed"
  relay="ws://127.0.0.1:1"
  channel=$(default_channel_id "$home")
  seeded=$(seed_replay_event "$home" "$relay" "$(new_private_key)" 1700000000 \
    "$channel" orphan-read-only) || fail "could not seed orphan read-only evidence"
  endpoint_file="$(relay_cache_dir "$home" "$relay")/$(basename "$seeded")"
  mv "$seeded" "$endpoint_file"
  rmdir "$(dirname "$seeded")"
  before=$(shasum -a 256 "$endpoint_file")
  rm -f -- "$(key_file "$home" "$home/xdg")" "$home/data/buzz-keypair.public"

  output=$(run_keypair "$home" 2>&1)
  code=$?
  expect_code 1 "$code" "default ensure over endpoint-only orphan evidence"
  assert_contains "$output" "orphan identity evidence exists" \
    "default ensure did not refuse endpoint-only orphan evidence"
  assert_present "$endpoint_file" "default ensure migrated endpoint-only orphan evidence"
  [ "$(shasum -a 256 "$endpoint_file")" = "$before" ] \
    || fail "default ensure rewrote endpoint-only orphan evidence"

  output=$(run_keypair "$home" --rotate 2>&1)
  code=$?
  expect_code 1 "$code" "plain rotation over endpoint-only orphan evidence"
  assert_present "$endpoint_file" "plain rotation migrated endpoint-only orphan evidence"
  [ "$(shasum -a 256 "$endpoint_file")" = "$before" ] \
    || fail "plain rotation rewrote endpoint-only orphan evidence"
  assert_absent "$home/state/buzz-replay/_legacy-quarantine" \
    "orphan identity inspection created quarantine state"
  pass "orphan identity inspection inventories endpoint replay without mutation"
}

test_publish_signing_is_serialized_with_compromised_rotation() {
  local home tools ready release publish_output rotate_output old publisher rotation waited relay new
  home=$(make_home publish-rotation-serialization)
  tools=$(make_delayed_publish_tools)
  ready="$home/publish-engine-ready"
  release="$home/publish-engine-release"
  publish_output="$home/publish-engine.out"
  rotate_output="$home/rotation.out"
  old=$(run_keypair "$home" 2>/dev/null) || fail "publish-rotation keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub --reject "restricted: channel fixture stays uncreated")
EOF

  (printf '%s' '{"schema":"fm-bearings.v1","note":"signed-before-compromised-rotation"}' \
    | PATH="$tools:$PATH" FM_DELAY_BUZZ_PUBLISH_READY="$ready" \
      FM_DELAY_BUZZ_PUBLISH_RELEASE="$release" \
      FM_DELAY_BUZZ_REMOVE_TARGETS="$home/data/buzz-publisher-targets.jsonl" \
      run_publish "$home" "$relay") \
    > "$publish_output" 2>&1 &
  publisher=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || {
    kill "$publisher" 2>/dev/null
    stop_stub "$STUB_PID"
    fail "the publisher did not pause at the signing boundary"
  }

  run_keypair "$home" --rotate --compromised --discard-pending-cache > "$rotate_output" 2>&1 &
  rotation=$!
  sleep 0.1
  kill -0 "$rotation" 2>/dev/null || {
    : > "$release"
    wait "$publisher" "$rotation" 2>/dev/null
    stop_stub "$STUB_PID"
    fail "compromised rotation did not wait for in-flight signing"
  }
  [ "$(cat "$home/data/buzz-keypair.public")" = "$old" ] \
    || fail "compromised rotation withdrew the key before the delayed publisher signed"

  : > "$release"
  wait "$publisher" || fail "the serialized publisher violated fire-and-forget"
  wait "$rotation" || fail "compromised rotation failed after publishing released the key"
  stop_stub "$STUB_PID"
  new=$(tail -1 "$rotate_output")

  assert_contains "$(cat "$publish_output")" "signed event" \
    "the delayed projection was not signed under the protected transaction"
  assert_contains "$(cat "$publish_output")" "retained=1" \
    "the delayed projection was not durably cached before rotation"
  assert_contains "$(cat "$rotate_output")" "quarantined 1 outgoing-authored pending replay event" \
    "the explicit rotation override did not quarantine the delayed projection"
  [ "$new" != "$old" ] || fail "compromised rotation did not replace the publishing identity"
  assert_not_contains "$(cat "$home/data/buzz-keypair.public-history" 2>/dev/null)" "$old" \
    "compromised rotation retained the protected outgoing identity"
  pass "publishing signs before compromised rotation can withdraw its key"
}

test_target_and_relay_retirement_wait_for_inflight_delivery() {
  local home relay publisher channel target_hex publish_output forget_output publish_pid forget_pid waited
  local relay_home relay_endpoint relay_channel relay_authority relay_output relay_publish delivery_lock code
  home=$(make_home target-retirement-delivery)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "target-retirement keypair setup failed"
  channel=$(channel_id_for_label target-retirement-delivery)
  publish_output="$home/target-retirement-publish.out"
  forget_output="$home/target-retirement-forget.out"
  read -r STUB_PID relay <<EOF
$(start_stub --challenge --challenge-delay-ms 2000)
EOF
  (printf '%s' '{"schema":"fm-bearings.v1","note":"target-retirement-delivery"}' \
    | FM_BUZZ_LOCK_TIMEOUT_S=5 run_publish "$home" "$relay" --channel-label target-retirement-delivery) \
    > "$publish_output" 2>&1 &
  publish_pid=$!
  waited=0
  while ! grep -F 'signed event' "$publish_output" >/dev/null 2>&1 && [ "$waited" -lt 400 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  grep -F 'signed event' "$publish_output" >/dev/null 2>&1 || fail "target-retirement publish never reached delivery"
  target_hex=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids \
    "$home/data/buzz-publisher-targets.jsonl" | awk -F '\t' -v channel="$channel" '$4 == channel {print $1}')
  [ -n "$target_hex" ] || fail "target-retirement publish did not persist its target"
  run_keypair "$home" --forget-target "$target_hex" > "$forget_output" 2>&1 &
  forget_pid=$!
  sleep 0.1
  kill -0 "$forget_pid" 2>/dev/null || fail "target retirement did not wait for in-flight delivery"
  wait "$publish_pid" || fail "target-retirement publish violated fire-and-forget"
  wait "$forget_pid" || fail "target retirement failed after delivery completed"
  stop_stub "$STUB_PID"
  assert_not_contains "$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$home/data/buzz-publisher-targets.jsonl")" \
    "$target_hex" "target retirement did not remove the exact delivered target"

  relay_home=$(make_home relay-retirement-delivery)
  run_keypair "$relay_home" >/dev/null 2>&1 || fail "relay-retirement keypair setup failed"
  relay_channel=$(channel_id_for_label relay-retirement-delivery)
  relay_authority=$(printf '%064d' 8)
  relay_output="$relay_home/relay-retirement-publish.out"
  read -r STUB_PID relay_endpoint <<EOF
$(start_stub)
EOF
  node -e '
    import(process.argv[2]).then(({ verifyOrRecordRelayAuthority }) => {
      verifyOrRecordRelayAuthority(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[5], signer_pubkey: process.argv[6],
      }, { strict: false });
    });
  ' buzz-target-test "$ROOT/bin/fm-buzz-targets.mjs" "$relay_home/data/buzz-relay-authorities.jsonl" \
    "$relay_endpoint" "$relay_channel" "$relay_authority" \
    || fail "could not seed relay-retirement authority"
  delivery_lock=$(delivery_lock_path "$relay_home" "$relay_endpoint" "$relay_channel")
  (printf '%s' '{"schema":"fm-bearings.v1","note":"relay-retirement-delivery"}' \
    | FM_TEST_BUZZ_TARGET_UPDATE_DELAY_MS=1500 FM_BUZZ_LOCK_TIMEOUT_S=5 \
      run_publish "$relay_home" "$relay_endpoint" --channel-label relay-retirement-delivery) \
    > "$relay_output" 2>&1 &
  relay_publish=$!
  waited=0
  while [ ! -d "$delivery_lock" ] && [ "$waited" -lt 400 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -d "$delivery_lock" ] || fail "relay-retirement publish never acquired delivery ownership"
  relay_output=$(run_keypair "$relay_home" --forget-relay-identity "$relay_endpoint" 2>&1)
  code=$?
  wait "$relay_publish" || fail "relay-retirement publish violated fire-and-forget"
  stop_stub "$STUB_PID"
  expect_code 1 "$code" "relay identity retirement during in-flight target persistence"
  assert_contains "$relay_output" "publisher targets still exist" \
    "relay identity retirement did not recheck targets after delivery"
  assert_contains "$(cat "$relay_home/data/buzz-relay-authorities.jsonl")" "$relay_authority" \
    "relay identity retirement removed an authority while delivery was in flight"
  pass "target and relay identity retirement wait for in-flight delivery"
}

test_target_retirement_cannot_pass_a_pre_delivery_publisher() {
  local home publisher relay channel targets target_hex ready release publish_output forget_output
  local publish_pid forget_pid waited
  home=$(make_home pre-delivery-retirement)
  publisher=$(run_keypair "$home" 2>/dev/null) || fail "pre-delivery retirement setup failed"
  channel=$(channel_id_for_label pre-delivery-retirement)
  targets="$home/data/buzz-publisher-targets.jsonl"
  ready="$home/pre-delivery-ready"
  release="$home/pre-delivery-release"
  publish_output="$home/pre-delivery-publish.out"
  forget_output="$home/pre-delivery-forget.out"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  node -e '
    import(process.argv[2]).then(({ recordPublisherTarget }) => {
      recordPublisherTarget(process.argv[3], {
        relay: process.argv[4], channel_id: process.argv[5], publisher_pubkey: process.argv[6],
      });
    });
  ' target-fixture "$ROOT/bin/fm-buzz-targets.mjs" "$targets" "$relay" "$channel" "$publisher" \
    || fail "could not seed the pre-delivery retirement target"
  target_hex=$(node "$ROOT/bin/fm-buzz-targets.mjs" list-with-ids "$targets" | awk -F '\t' 'NR == 1 { print $1 }')

  (printf '%s' '{"schema":"fm-bearings.v1","note":"pre-delivery-retirement"}' \
    | FM_TEST_BUZZ_BEFORE_DELIVERY_LOCK_READY="$ready" \
      FM_TEST_BUZZ_BEFORE_DELIVERY_LOCK_RELEASE="$release" \
      FM_BUZZ_LOCK_TIMEOUT_S=5 run_publish "$home" "$relay" --channel-label pre-delivery-retirement) \
    > "$publish_output" 2>&1 &
  publish_pid=$!
  waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 400 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "publisher did not pause before acquiring delivery ownership"
  run_keypair "$home" --forget-target "$target_hex" > "$forget_output" 2>&1 &
  forget_pid=$!
  sleep 0.1
  kill -0 "$forget_pid" 2>/dev/null \
    || fail "target retirement passed a publisher before it registered delivery ownership"
  : > "$release"
  wait "$publish_pid" || fail "pre-delivery publisher violated fire-and-forget"
  wait "$forget_pid" || fail "target retirement failed after the publisher completed"
  stop_stub "$STUB_PID"
  assert_absent "$targets" "target retirement raced with the publisher and left its target active"
  pass "target retirement cannot pass a publisher entering delivery"
}

read -r ROTATION_GUARD_PID ROTATION_GUARD_RELAY <<EOF
$(start_stub)
EOF

test_bip340_official_vectors
test_keypair_is_idempotent_and_never_prints_the_private_key
test_fallback_key_load_requires_private_regular_custody
test_private_key_reads_are_descriptor_verified
test_two_homes_sharing_one_xdg_get_separate_keys
test_rotation_replaces_the_key_in_whichever_store_holds_it
test_a_compromised_rotation_does_not_keep_the_retired_key
test_rotation_refuses_or_quarantines_outgoing_pending_events
test_rotation_refuses_an_existing_private_channel_before_mutation
test_rotation_reports_every_membership_blocker
test_rotation_query_errors_report_every_target_on_the_endpoint
test_retirement_commands_quote_special_relay_endpoints
test_publisher_target_overrides_are_recorded_and_guard_rotation
test_publisher_target_updates_are_concurrent_and_fail_closed
test_publisher_target_lock_ignores_only_identity_bound_dead_candidates
test_forget_target_attests_exact_retirement
test_forget_relay_identity_requires_exact_target_retirement
test_rotation_checks_authoritative_current_membership
test_rotation_fails_closed_on_unverifiable_membership
test_rotation_pins_and_verifies_relay_membership_authority
test_empty_relay_authority_registry_fails_closed
test_rotation_stops_or_recovers_when_the_outgoing_private_key_is_unusable
test_compromised_orphan_recovery_records_unverifiable_memberships
test_orphan_identity_evidence_requires_compromised_recovery
test_complete_cache_temporaries_protect_publisher_identity
test_rotation_compares_the_recorded_key_with_stored_private_material
test_rotation_detects_and_cleans_up_divergent_stores
test_orphaned_public_record_requires_compromised_recovery
test_forget_key_refuses_when_history_cannot_be_read
test_malformed_public_history_is_never_rewritten
test_keychain_errors_refuse_rotation_without_minting_a_fallback_key
test_public_record_failures_are_fatal_and_retryable
test_key_record_targets_reject_non_files
test_key_record_replace_is_exact_destination
test_keypair_transactions_are_serialized_per_home
test_public_read_cannot_restore_a_concurrently_retired_identity
test_public_read_cannot_commit_a_rotation_stage
test_public_key_history_is_normalized_consistently
test_public_flag_fails_before_a_keypair_exists
test_rotation_stages_the_replacement_before_clearing_the_outgoing_key
test_compromised_rotation_stage_preserves_withdrawal_intent
test_orphan_gate_sees_legacy_replay_publisher_evidence
test_orphan_gate_preserves_publisher_evidence_after_legacy_quarantine
test_orphan_gate_includes_quarantine_manifest_temporaries
test_orphan_gate_preserves_corrupt_partition_publisher_evidence
test_orphan_gate_includes_interrupted_corrupt_quarantine_transactions
test_orphan_gate_validates_quarantine_payloads_without_filename_trust
test_orphan_gate_fails_closed_on_unreadable_quarantine_payloads
test_orphan_gate_validates_quarantine_manifest_variants
test_orphan_gate_includes_recoverable_quarantine_staging
test_orphan_identity_inspection_does_not_mutate_endpoint_replay
test_publish_signing_is_serialized_with_compromised_rotation
test_target_and_relay_retirement_wait_for_inflight_delivery
test_target_retirement_cannot_pass_a_pre_delivery_publisher
