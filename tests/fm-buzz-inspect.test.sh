#!/usr/bin/env bash
# Buzz inspection, privacy-verdict, Compose, and structural behavior tests.
set -u

# shellcheck source=tests/fm-buzz-test-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-buzz-test-lib.sh"

test_the_inspector_rejects_a_tampered_event() {
  # The inspector's whole job is answering "is the published projection legible AND
  # authentic?", and it is the only place a human looks for that answer. A relay
  # that serves a validly-signed id beside altered content passes a signature check
  # unchanged - the signature covers the id, not the bytes printed under it - so
  # only recomputing the id from what was served can catch it. This stub does
  # exactly that: it stores a real event and hands back other content with the id
  # and signature intact.
  local home relay clean tampered
  home=$(make_home tampered-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "authentic" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  clean=$(run_inspect "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$clean" "signature verified" \
    "an untouched event must read back as verified, or this test proves nothing"
  assert_contains "$clean" "authentic" "the projection did not read back"

  # Same home, same key, same channel - only the relay's honesty differs.
  read -r STUB_PID relay <<EOF
$(start_stub --tamper-on-read)
EOF
  test_projection "authentic" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  tampered=$(run_inspect "$home" "$relay" 2>&1)
  kill "$STUB_PID" 2>/dev/null
  STUB_PID=""

  assert_contains "$tampered" "TAMPERED" \
    "the stub did not serve altered content, so the check under test was never reached"
  assert_not_contains "$tampered" "signature verified" \
    "altered content was reported as verified: the id is not being recomputed"
  assert_contains "$tampered" "INVALID" \
    "altered content was not reported as invalid"
  pass "the inspector refuses to call altered content verified"
}

test_an_anonymous_read_only_claims_privacy_when_the_relay_refuses() {
  # --anonymous is the only place this tool makes a SECURITY claim, and an empty
  # read is the weakest possible evidence for one: a wiped relay, a channel id
  # derived from another home, a publish that never landed, and a genuinely empty
  # channel are all indistinguishable from enforced privacy. Only the relay
  # refusing the subscription ON MEMBERSHIP GROUNDS separates them, so the
  # assurance is gated on that one refusal shape and everything else - including a
  # refusal for some other reason - must read INCONCLUSIVE.
  local home relay served refused unrelated untagged
  home=$(make_home anonymous-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Nothing published: an ordinary relay that serves the subscription and has
  # nothing to hand back. This is the ambiguous case.
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  served=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$served" "events:   0" "the empty read did not happen"
  assert_not_contains "$served" "refused:" \
    "the stub refused the subscription, so the ambiguous case was never reached"
  assert_contains "$served" "INCONCLUSIVE" \
    "an unrefused empty read must be reported as inconclusive"
  assert_not_contains "$served" "CORRECT" \
    "an unrefused empty read was reported as proof of privacy"
  assert_not_contains "$served" "That refusal is the assurance" \
    "the reassurance was printed without any refusal behind it"

  # A relay that enforces membership: same empty result, but it says why.
  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "restricted: not a channel member")
EOF
  refused=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$refused" "refused:  restricted: not a channel member" \
    "the relay's refusal reason did not reach the reader"
  assert_contains "$refused" "That refusal is the assurance" \
    "a refused subscription must still report the privacy assurance"
  assert_not_contains "$refused" "INCONCLUSIVE" \
    "a refused subscription is conclusive and must not be hedged"

  # A relay that refuses this read for a reason NIP-01 does not tag as being about
  # the reader. It carries no privacy conclusion, but the hedge must not swing the
  # other way either: the tool knows the reason is untagged, not that the relay
  # would have refused any other channel too.
  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "auth-required: we only serve authenticated readers")
EOF
  unrelated=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$unrelated" "auth-required: we only serve authenticated readers" \
    "a non-membership refusal must be reported in the relay's own words"
  assert_contains "$unrelated" "INCONCLUSIVE" \
    "a refusal that is not about membership must stay inconclusive"
  assert_not_contains "$unrelated" "That refusal is the assurance" \
    "a non-membership refusal was reported as proof of privacy"
  assert_not_contains "$unrelated" "never added to this private channel" \
    "a non-membership refusal was described as a membership refusal"
  assert_not_contains "$unrelated" "any reader asking for any channel" \
    "the hedge asserted a relay policy the refusal reason does not establish"

  # The same branch catches an UNTAGGED membership refusal, which is the case that
  # makes the strong hedge wrong: this really is the refusal the probe was looking
  # for, and the tool must say only that it cannot tell.
  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "not a member of this group")
EOF
  untagged=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$untagged" "not a member of this group" \
    "an untagged refusal must be reported in the relay's own words"
  assert_contains "$untagged" "INCONCLUSIVE" \
    "an untagged refusal cannot be read as a membership refusal"
  assert_contains "$untagged" "not machine-tagged as a membership refusal" \
    "the hedge must state the limit it actually knows"
  assert_not_contains "$untagged" "any reader asking for any channel" \
    "an untagged membership refusal was described as channel-independent"
  assert_not_contains "$untagged" "That refusal is the assurance" \
    "an untagged refusal was reported as proof of privacy"
  pass "an anonymous empty read claims privacy only on a membership refusal"
}

test_an_anonymous_read_that_returns_events_reports_the_breach() {
  # The one conclusive answer --anonymous can give, and it is the negative one: a
  # relay that serves the events to a stranger has no privacy to report. It has to
  # be stated, because every event below it prints `signature verified` and a
  # successful breach otherwise looks exactly like a successful legibility check.
  # This is not a hypothetical shape either - it is what the bundled stack does,
  # since it ships with membership enforcement off.
  local home relay breached
  home=$(make_home anonymous-readable)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "readable-by-a-stranger" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  breached=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$breached" "identity: ephemeral non-member" \
    "the read was not performed as a non-member, so nothing here is under test"
  assert_contains "$breached" "readable-by-a-stranger" \
    "the stranger did not actually receive the projection"
  assert_contains "$breached" \
    "The channel was readable by an identity that is not a member — this is a definite negative privacy result." \
    "a non-member read the private channel and the tool said nothing about it"
  assert_not_contains "$breached" "INCONCLUSIVE" \
    "a non-member reading the channel is conclusive, not inconclusive"
  pass "an anonymous read that returns events reports the breach"
}

test_multiline_current_key_record_cannot_expand_authorship() {
  local home other relay current appended inspected
  home=$(make_home multiline-current-key)
  other=$(make_home multiline-current-key-other)
  current=$(run_keypair "$home" 2>/dev/null) || fail "multiline current-key setup failed"
  appended=$(run_keypair "$other" 2>/dev/null) || fail "multiline current-key second identity setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "authorship-needs-singular-record" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  printf '%s\n%s\n' "$current" "$appended" > "$home/data/buzz-keypair.public"

  inspected=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$inspected" "authorship-needs-singular-record" \
    "the multiline current-key fixture did not return its event"
  assert_contains "$inspected" "unknown (no publisher public key recorded for this home)" \
    "a multiline current-key record still established authorship"
  assert_contains "$inspected" "INCONCLUSIVE" \
    "malformed current-key attribution produced a definite privacy verdict"
  assert_not_contains "$inspected" \
    "The channel was readable by an identity that is not a member" \
    "an appended current key expanded trust for the anonymous verdict"
  pass "current-key attribution requires exactly one normalized record"
}

test_an_anonymous_read_of_unverifiable_events_claims_no_breach() {
  # The accusation is only as good as the frames it rests on. A relay that serves
  # altered content is the same relay the verdict would be quoting, so events that
  # do not recompute to their own id - or that are not tagged for this channel -
  # cannot establish that a non-member read THIS channel. Same anti-overclaim rule
  # as the reassurance and the hedge, applied to the accusation.
  local home relay tampered
  home=$(make_home anonymous-tampered)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --tamper-on-read)
EOF
  test_projection "readable-by-a-stranger" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  tampered=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$tampered" "TAMPERED" \
    "the stub did not serve altered content, so the check under test was never reached"
  assert_contains "$tampered" "INVALID" \
    "altered content was not reported as invalid"
  assert_not_contains "$tampered" \
    "The channel was readable by an identity that is not a member" \
    "a definite breach was declared over content the tool itself reports as forged"
  assert_contains "$tampered" "INCONCLUSIVE" \
    "unverifiable served events must be reported as inconclusive"
  assert_contains "$tampered" "served by relay but not" \
    "the served-but-unverifiable events were not reported separately"
  pass "an anonymous read of unverifiable events claims no breach"
}

test_malformed_relay_events_are_assessed_independently() {
  local home relay malformed code
  home=$(make_home malformed-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  read -r STUB_PID relay <<EOF
$(start_stub --malform-on-read)
EOF
  test_projection "malformed-on-read" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  malformed=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  code=$?
  stop_stub "$STUB_PID"

  expect_code 0 "$code" "inspection of malformed relay events"
  assert_contains "$malformed" "events:   4" \
    "the stub did not serve every independently malformed event"
  assert_contains "$malformed" "malformed id" "a malformed id was not classified as invalid"
  assert_contains "$malformed" "malformed tags" "malformed tags were not classified as invalid"
  assert_contains "$malformed" "malformed created_at" \
    "a malformed timestamp was not classified as invalid"
  assert_contains "$malformed" "malformed content" \
    "malformed content was not classified as invalid"
  assert_contains "$malformed" "INCONCLUSIVE" \
    "malformed served events did not leave the privacy result inconclusive"
  assert_not_contains "$malformed" \
    "The channel was readable by an identity that is not a member" \
    "malformed events produced a definite privacy verdict"
  pass "malformed relay events are invalidated independently without aborting inspection"
}

test_wrong_kind_event_cannot_produce_a_privacy_breach_verdict() {
  local home relay inspected
  home=$(make_home wrong-kind-read)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  read -r STUB_PID relay <<EOF
$(start_stub --wrong-kind-on-read)
EOF
  test_projection "wrong-kind" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  inspected=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$inspected" "events:   1" \
    "stub did not serve the signed wrong-kind channel event"
  assert_contains "$inspected" "unexpected event kind" \
    "wrong-kind event was not classified as invalid"
  assert_contains "$inspected" "this home's publisher" \
    "wrong-kind fixture did not pass publisher attribution"
  assert_contains "$inspected" "INCONCLUSIVE" \
    "wrong-kind event did not leave the privacy result inconclusive"
  assert_not_contains "$inspected" \
    "The channel was readable by an identity that is not a member" \
    "wrong-kind event produced a definite negative privacy verdict"
  pass "wrong-kind events cannot produce a privacy-breach verdict"
}

test_an_anonymous_read_of_a_foreign_authors_event_claims_no_breach() {
  # id, signature and `h` tag are all satisfiable by a stranger: the channel id is
  # a digest of the home path, printed by this very tool and sent to the relay in
  # the filter, so anyone who can publish to the open loopback relay can mint a
  # keypair and sign a perfectly valid event tagged for this channel. Nothing about
  # that event says this home's projection leaked, so it must not trigger the
  # verdict. The publisher's PUBLIC key is the evidence that separates the two, and
  # bin/fm-buzz-keypair.sh records it exactly where an anonymous read can find it.
  local home other relay label foreign
  home=$(make_home anonymous-foreign)
  other=$(make_home anonymous-foreign-stranger)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  run_keypair "$other" >/dev/null 2>&1 || fail "stranger keypair setup failed"

  # The label the inspected home derives its channel from, resolved the same way
  # bin/fm-buzz-key-lib.sh resolves it.
  label=$(cd "$home" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  # A different home, a different key, aimed at this home's channel.
  test_projection "planted-by-a-stranger" \
    | run_publish "$other" "$relay" --channel-label "$label" >/dev/null 2>&1
  foreign=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$foreign" "events:   1" \
    "the planted event was not served, so the check under test was never reached"
  assert_contains "$foreign" "signature verified" \
    "the planted event must verify, or it fails an earlier gate and proves nothing"
  assert_contains "$foreign" "channel   this channel" \
    "the planted event must carry this channel's h tag, or an earlier gate catches it"
  assert_contains "$foreign" "NOT this home's publisher" \
    "the foreign author was not reported"
  assert_not_contains "$foreign" \
    "The channel was readable by an identity that is not a member" \
    "a definite breach was declared over an event this home's publisher never wrote"
  assert_contains "$foreign" "INCONCLUSIVE" \
    "an event from a foreign author must be reported as inconclusive"
  pass "an anonymous read of a foreign author's event claims no breach"
}

test_a_rotated_home_still_recognises_its_own_leaked_events() {
  # Rotation mints a new key but changes neither the channel id (a digest of the
  # home path) nor the relay's stored events, so this home's pre-rotation
  # projections keep sitting on the relay signed by the retired key. Attributing
  # only the current key would make the probe answer INCONCLUSIVE over exactly the
  # leak it exists to catch - a false negative created by the home's own key
  # hygiene. The retired PUBLIC key is retained precisely so that cannot happen.
  local home relay retired retired_private retired_upper rotated leaked malformed channel label
  home=$(make_home rotated-breach)
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"
  retired_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' \
    "$(key_file "$home" "$home/xdg")")
  label=$(cd "$home" && pwd -P)
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the rotated fixture channel"
  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  [ "$rotated" != "$retired" ] || fail "rotation did not replace the key, so nothing here is under test"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_signed_fixture "$retired_private" "$relay" "$channel" "published-before-rotation" \
    || fail "could not seed the pre-rotation signed event"
  retired_private=""
  retired_upper=$(printf '%s' "$retired" | tr 'a-f' 'A-F')
  printf '  %s  \r\n' "$retired_upper" > "$home/data/buzz-keypair.public-history"
  leaked=$(run_inspect "$home" "$relay" --anonymous 2>&1)

  assert_contains "$(tr 'A-F' 'a-f' < "$home/data/buzz-keypair.public-history")" "$retired" \
    "rotation dropped the retired public key instead of retaining it"
  assert_contains "$leaked" "published-before-rotation" \
    "the pre-rotation event was not served, so the check under test was never reached"
  assert_contains "$leaked" "this home's publisher" \
    "an event signed by a retired key of this home was not attributed to it"
  assert_contains "$leaked" \
    "The channel was readable by an identity that is not a member — this is a definite negative privacy result." \
    "rotation blinded the probe to this home's own leaked content"
  assert_not_contains "$leaked" "INCONCLUSIVE" \
    "a leak of this home's own pre-rotation content is conclusive, not inconclusive"

  printf '%s\n' 'not-a-public-key' >> "$home/data/buzz-keypair.public-history"
  malformed=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  assert_contains "$malformed" "NOT this home's publisher" \
    "the inspector partially trusted a malformed public-key history"
  assert_contains "$malformed" "INCONCLUSIVE" \
    "malformed public-key history expanded publisher attribution"
  printf '%s\n' "$retired" > "$home/data/buzz-keypair.public-history"
  stop_stub "$STUB_PID"

  # The recorded file is the cheap source of the outgoing key, not the only one:
  # once it is gone the stored private half is the last thing that can name what
  # this home was publishing under, and rotation clears that. So a second rotation
  # with no recorded file must still retain the key it is retiring.
  rm -f "$home/data/buzz-keypair.public"
  run_keypair "$home" --rotate >/dev/null 2>&1 || fail "second rotation failed"
  assert_grep "$rotated" "$home/data/buzz-keypair.public-history" \
    "a rotation with no recorded public key lost the key it retired"
  assert_grep "$retired" "$home/data/buzz-keypair.public-history" \
    "a later rotation dropped an earlier retired key"
  pass "a rotated home still recognises its own leaked events"
}

test_forget_key_withdraws_an_already_retired_key() {
  # The case --compromised cannot reach. Every rotation mints a fresh random key,
  # so the key a rotation is retiring is never one an earlier rotation recorded:
  # an exposure that comes to light AFTER the rotation that retired the key has to
  # name the key it means. Once withdrawn, an event signed by that key is no
  # longer evidence of anything - anyone holding the leaked private half could
  # have minted it against a channel id that is not a secret - so the probe must
  # fall back to INCONCLUSIVE rather than report this home's own leak.
  local home relay retired retired_private rotated history withdrawn after code label channel
  home=$(make_home forget-key)
  history="$home/data/buzz-keypair.public-history"
  retired=$(run_keypair "$home" 2>/dev/null) || fail "keypair setup failed"
  retired_private=$(sed -n 's/.*"private_key"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' \
    "$(key_file "$home" "$home/xdg")")
  label=$(cd "$home" && pwd -P)
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$label") || fail "could not derive the withdrawal fixture channel"
  rotated=$(run_keypair "$home" --rotate 2>/dev/null) || fail "rotation failed"
  assert_grep "$retired" "$history" \
    "the ordinary rotation did not retain the key the withdrawal is about"

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  publish_signed_fixture "$retired_private" "$relay" "$channel" "signed-by-the-leaked-key" \
    || fail "could not seed the withdrawn-key event"
  retired_private=""

  withdrawn=$(run_keypair "$home" --forget-key "$retired" 2>&1)
  code=$?
  expect_code 0 "$code" "--forget-key on a recorded key"
  assert_contains "$withdrawn" "no longer recorded" \
    "--forget-key withdrew the key without saying so"
  assert_not_contains "$(cat "$history" 2>/dev/null)" "$retired" \
    "--forget-key left the named key in the recorded set"
  assert_grep "$rotated" "$home/data/buzz-keypair.public" \
    "--forget-key disturbed this home's current key"

  after=$(run_inspect "$home" "$relay" --anonymous 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$after" "signed-by-the-leaked-key" \
    "the event was not served, so the check under test was never reached"
  assert_contains "$after" "NOT this home's publisher" \
    "an event signed by a withdrawn key was still attributed to this home"
  assert_not_contains "$after" \
    "The channel was readable by an identity that is not a member" \
    "a withdrawn key still carried the verdict it was withdrawn to stop carrying"
  assert_contains "$after" "INCONCLUSIVE" \
    "an event signed by a withdrawn key must be reported as inconclusive"

  # Naming a key that is not recorded changes nothing and says so, so a repeat run
  # is safe; naming this home's CURRENT key says that rotation is what retires it.
  run_keypair "$home" --forget-key "$retired" >/dev/null 2>&1
  code=$?
  expect_code 0 "$code" "--forget-key on a key that is not recorded"
  assert_contains "$(run_keypair "$home" --forget-key "$rotated" 2>&1)" \
    "CURRENT publishing key" \
    "--forget-key on this home's current key implied the key had been withdrawn"
  run_keypair "$home" --forget-key "not-a-key" >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--forget-key with a value that is not a public key"
  # A lost argument must be an error, not a silent fall through into minting.
  run_keypair "$home" --forget-key >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "--forget-key with no key named"
  pass "--forget-key withdraws an already-retired key"
}

test_an_anonymous_read_of_a_foreign_channel_claims_no_verdict() {
  # --channel-label points the read at a channel derived from some other home's
  # label, and the only publishing keys on this disk are this home's own. No served
  # event can be attributed either way, so the conclusive answer is unreachable and
  # must not be printed - and the fix is to say so, not to go reading another
  # home's files.
  local home other relay label foreign
  home=$(make_home foreign-channel-reader)
  other=$(make_home foreign-channel-owner)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  run_keypair "$other" >/dev/null 2>&1 || fail "other home keypair setup failed"

  label=$(cd "$other" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "another-homes-projection" \
    | run_publish "$other" "$relay" >/dev/null 2>&1
  foreign=$(run_inspect "$home" "$relay" --anonymous --channel-label "$label" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$foreign" "events:   1" \
    "the other home's event was not served, so the check under test was never reached"
  assert_contains "$foreign" "signature verified" \
    "the served event must verify, or it fails an earlier gate and proves nothing"
  assert_not_contains "$foreign" \
    "The channel was readable by an identity that is not a member" \
    "a definite verdict was declared for a channel this home cannot attribute"
  assert_contains "$foreign" "INCONCLUSIVE" \
    "a channel not derived from this home must be reported as inconclusive"
  assert_contains "$foreign" \
    "cannot verify authorship for a channel not derived from this home" \
    "the reason the verdict is unreachable was not stated"
  assert_contains "$foreign" "unattributable (channel not derived from this home)" \
    "the served event was reported as if this home could judge its author"
  pass "an anonymous read of a foreign channel claims no verdict"
}

test_a_membership_refusal_for_an_empty_foreign_channel_is_inconclusive() {
  local home other relay label foreign
  home=$(make_home foreign-empty-reader)
  other=$(make_home foreign-empty-owner)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"
  label=$(cd "$other" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub --refuse-req "restricted: not a channel member")
EOF
  foreign=$(run_inspect "$home" "$relay" --anonymous --channel-label "$label" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$foreign" "events:   0" "the empty foreign read did not occur"
  assert_contains "$foreign" "INCONCLUSIVE" \
    "a foreign channel received a positive privacy verdict"
  assert_contains "$foreign" "not derived from this home" \
    "the inspector did not explain why a foreign-channel refusal is inconclusive"
  assert_not_contains "$foreign" "That refusal is the assurance" \
    "a membership refusal reassured the reader about a foreign channel"
  pass "membership refusals for empty foreign channels remain inconclusive"
}

test_an_anonymous_read_of_this_homes_own_label_still_reaches_a_verdict() {
  # What rules the conclusive answer out is the channel belonging to another home,
  # not --channel-label being typed. Spelling this home's own resolved path out is
  # a natural way to check which channel id a label derives to, and it inspects
  # precisely this home's channel with precisely this home's keys on disk - so
  # deciding attributability from the flag's presence would throw the verdict away
  # over a real leak of this home's own content.
  local home relay label explicit
  home=$(make_home own-label-explicit)
  run_keypair "$home" >/dev/null 2>&1 || fail "keypair setup failed"

  # Resolved the same way bin/fm-buzz-key-lib.sh resolves this home's own label.
  label=$(cd "$home" && pwd -P)

  read -r STUB_PID relay <<EOF
$(start_stub)
EOF
  test_projection "own-label-spelled-out" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  explicit=$(run_inspect "$home" "$relay" --anonymous --channel-label "$label" 2>&1)
  stop_stub "$STUB_PID"

  assert_contains "$explicit" "own-label-spelled-out" \
    "the event was not served, so the check under test was never reached"
  assert_contains "$explicit" "this home's publisher" \
    "this home's own event was not attributed to it when its label was passed explicitly"
  assert_contains "$explicit" \
    "The channel was readable by an identity that is not a member — this is a definite negative privacy result." \
    "spelling out this home's own label suppressed the verdict over a real leak"
  assert_not_contains "$explicit" "INCONCLUSIVE" \
    "a leak of this home's own content is conclusive, not inconclusive"
  assert_not_contains "$explicit" "channel not derived from this home" \
    "this home's own label was treated as another home's"
  pass "an anonymous read of this home's own label still reaches a verdict"
}

test_compose_relay_signer_survives_restart_but_not_volume_teardown() {
  local project port home relay old_private channel first second third
  if [ "${FM_BUZZ_DOCKER_INTEGRATION:-0}" != "1" ]; then
    pass "compose relay signer lifecycle is available with FM_BUZZ_DOCKER_INTEGRATION=1"
    return
  fi
  command -v docker >/dev/null 2>&1 \
    || fail "FM_BUZZ_DOCKER_INTEGRATION=1 but docker is unavailable"
  docker compose version >/dev/null 2>&1 \
    || fail "FM_BUZZ_DOCKER_INTEGRATION=1 but docker compose is unavailable"
  docker info >/dev/null 2>&1 \
    || fail "FM_BUZZ_DOCKER_INTEGRATION=1 but the docker daemon is unavailable"
  project="buzz-loopback-test-$$"
  BUZZ_DOCKER_PROJECT=$project
  # shellcheck disable=SC2016
  port=$(node -e '
    const server = require("node:net").createServer();
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => process.stdout.write(`${port}\n`));
    });
  ') || fail "could not reserve a loopback port for the compose integration"
  home=$(make_home compose-relay-signer)
  run_keypair "$home" >/dev/null 2>&1 || fail "compose signer keypair setup failed"
  old_private=$(jq -r '.private_key' "$(key_file "$home" "$home/xdg")")
  channel=$(node -e '
    import(process.argv[1]).then(({ channelIdForLabel }) => {
      process.stdout.write(channelIdForLabel(process.argv[2]));
    });
  ' "$ROOT/bin/fm-buzz-lib.mjs" "$(cd "$home" && pwd -P)") \
    || fail "could not derive the compose integration channel"
  relay="ws://localhost:$port"

  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" up -d --wait --wait-timeout 240 \
    || fail "could not start the disposable Buzz integration stack"
  test_projection "signer-before-restart" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  first=$(query_membership_signer "$old_private" "$relay" "$channel") \
    || fail "could not read the initial compose membership signer"

  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" restart relay >/dev/null \
    || fail "could not restart the disposable Buzz relay"
  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" up -d --wait --wait-timeout 240 >/dev/null \
    || fail "the restarted disposable Buzz relay did not become ready"
  second=$(query_membership_signer "$old_private" "$relay" "$channel") \
    || fail "could not read the restarted compose membership signer"
  [ "$second" = "$first" ] || fail "relay restart changed the TOFU membership signer"

  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" down -v >/dev/null \
    || fail "could not destroy the disposable Buzz volumes"
  BUZZ_LOOPBACK_PORT=$port docker compose -p "$project" \
    -f "$ROOT/docker-compose.buzz-loopback.yml" up -d --wait --wait-timeout 240 >/dev/null \
    || fail "could not recreate the disposable Buzz integration stack"
  test_projection "signer-after-volume-teardown" \
    | run_publish "$home" "$relay" >/dev/null 2>&1
  third=$(query_membership_signer "$old_private" "$relay" "$channel") \
    || fail "could not read the recreated compose membership signer"
  [ "$third" != "$first" ] || fail "down -v retained the disposable relay signing key"
  docker compose -p "$project" -f "$ROOT/docker-compose.buzz-loopback.yml" \
    down -v >/dev/null 2>&1 || true
  BUZZ_DOCKER_PROJECT=""
  pass "compose relay signer survives restart and changes after down -v"
}

test_quarantine_lifecycle_has_one_pinned_cache_owner() {
  assert_absent "$ROOT/bin/fm-buzz-quarantine.mjs" \
    "the quarantine callback middleman still splits lifecycle ownership"
  assert_grep "function quarantineLegacyEntries" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the pinned cache owner does not own legacy quarantine orchestration"
  assert_grep "function recoverStagedLegacyEntries" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the pinned cache owner does not own quarantine recovery"
  assert_grep "staging/<token>/{source,origin.json}" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine owner does not document its staging and payload layout"
  assert_grep "Every manifests/<token>.json variant requires" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine owner does not document manifest identity"
  assert_grep "Startup completes manifest temporaries before accounting for invalid recovery" \
    "$ROOT/bin/fm-buzz-publish.mjs" \
    "the quarantine owner does not document recovery order"
  assert_grep "<replay-root>/<endpoint-digest>/<channel-id>/<created_at>-<event-id>.json" \
    "$ROOT/bin/fm-buzz-publish.mjs" \
    "the active-cache owner does not document its partition and entry layout"
  assert_grep "query authoritative membership state for safe key" "$ROOT/bin/fm-buzz-lib.mjs" \
    "the relay-client scope omits rotation membership queries"
  assert_grep 'FM_BUZZ_DOCKER_INTEGRATION=1` enables the opt-in Compose' "$ROOT/docs/buzz-loopback-adapter.md" \
    "the adapter guide does not distinguish the opt-in Docker lane"
  # shellcheck disable=SC2016
  assert_grep 'The header of `bin/fm-buzz-publish.sh` owns input, option, default, and termination mechanics' \
    "$ROOT/docs/buzz-loopback-adapter.md" \
    "the adapter guide does not point runtime mechanics to their owner"
  assert_no_grep "runLegacyQuarantineLifecycle" "$ROOT/bin/fm-buzz-publish.mjs" \
    "the publisher still delegates through the callback facade"
  pass "quarantine lifecycle and pinned mutations have one owner"
}

test_no_firstmate_path_depends_on_buzz() {
  # Invariant: Buzz is additive. If any other Firstmate script, skill, workflow or
  # AGENTS.md instruction ever calls the adapter, a stopped relay could reach a
  # supervision path - which is precisely what must not happen.
  local callers
  callers=$(grep -rl 'fm-buzz' "$ROOT/bin" "$ROOT/tests" "$ROOT/.agents" \
    "$ROOT/.github" "$ROOT/AGENTS.md" 2>/dev/null \
    | grep -v '/fm-buzz-' || true)
  [ -z "$callers" ] \
    || fail "Buzz must stay off every Firstmate path, but it is referenced by:"$'\n'"$callers"
  pass "no Firstmate path depends on the Buzz adapter"
}

read -r ROTATION_GUARD_PID ROTATION_GUARD_RELAY <<EOF
$(start_stub)
EOF

test_the_inspector_rejects_a_tampered_event
test_an_anonymous_read_only_claims_privacy_when_the_relay_refuses
test_an_anonymous_read_that_returns_events_reports_the_breach
test_multiline_current_key_record_cannot_expand_authorship
test_an_anonymous_read_of_unverifiable_events_claims_no_breach
test_malformed_relay_events_are_assessed_independently
test_wrong_kind_event_cannot_produce_a_privacy_breach_verdict
test_an_anonymous_read_of_a_foreign_authors_event_claims_no_breach
test_a_rotated_home_still_recognises_its_own_leaked_events
test_forget_key_withdraws_an_already_retired_key
test_an_anonymous_read_of_a_foreign_channel_claims_no_verdict
test_a_membership_refusal_for_an_empty_foreign_channel_is_inconclusive
test_an_anonymous_read_of_this_homes_own_label_still_reaches_a_verdict
test_compose_relay_signer_survives_restart_but_not_volume_teardown
test_quarantine_lifecycle_has_one_pinned_cache_owner
test_no_firstmate_path_depends_on_buzz
