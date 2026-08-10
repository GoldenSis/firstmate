#!/usr/bin/env node
// Read back published bearings events from the loopback relay, for a human.
//
// Driven by bin/fm-buzz-inspect.sh, which is the supported entry point: it owns
// resolving the reading identity so no private key reaches a command line. This
// file reads one JSON envelope on stdin: {privateKey, relay, channelId, limit,
// full, expectedAuthors, ownChannel}. An empty privateKey means "read with a
// throwaway identity"; expectedAuthors are this home's PUBLIC publishing keys,
// current and retired, which the wrapper reads from data/buzz-keypair.public and
// data/buzz-keypair.public-history without touching the keychain. ownChannel is
// false when the channel was derived from a label other than this home's, in
// which case no key on this disk can attribute what the relay serves.
//
// IT IS NOT A STATE READ PATH. Nothing in Firstmate invokes this, parses its
// output, or makes a decision from it. It exists to answer one human question -
// "is the published projection actually legible?" - on a host with no `websocat`
// and no Buzz desktop client. Buzz is a projection target, never a state source:
// Firstmate's authoritative view is rebuilt from local durable records on every
// session start, and a relay that was stale or unreachable must never be able to
// influence it. If a future change makes any Firstmate code path consume this
// output, that is not an increment - it re-opens the question of who owns
// canonical state.

import {
  channelIdForLabel,
  classifyRefusalReason,
  computeEventId,
  readStdin,
  withRelay,
  KIND_STREAM_MESSAGE,
  REFUSAL_MEMBERSHIP,
} from "./fm-buzz-lib.mjs";
import { generateKeypair, schnorrVerify } from "./fm-buzz-crypto.mjs";

const envelope = JSON.parse(await readStdin());
const relay = envelope.relay ?? "ws://localhost:3000";
const limit = envelope.limit ?? 3;
const full = Boolean(envelope.full);
const channelId = envelope.channelId || channelIdForLabel(envelope.channelLabel ?? "");
const expectedAuthors = new Set(
  (envelope.expectedAuthors ?? [])
    .map((key) => String(key).trim().toLowerCase())
    .filter((key) => key !== ""),
);
// Attribution is only meaningful for a channel derived from THIS home's label:
// the recorded keys are this home's, and reaching into another home's files to
// find its keys is not on the table. Default true, since an envelope that omits
// the field is the wrapper's own-channel shape.
const ownChannel = envelope.ownChannel !== false;
// A blank key means read as a stranger. That is the useful shape for probing
// whether a private channel is invisible to non-members. Events that verify as
// this channel's own content settle it negatively outright; an absence settles it
// positively only when the relay refused the subscription ON MEMBERSHIP GROUNDS -
// see the branches below.
const anonymous = !envelope.privateKey;
const privateKey = anonymous ? generateKeypair().privateKey : envelope.privateKey;

try {
  const { events, refusal } = await withRelay(
    relay,
    privateKey,
    envelope.timeoutMs ?? 15000,
    async (api) => {
      await api.authenticateIfChallenged();
      return api.query({ kinds: [KIND_STREAM_MESSAGE], "#h": [channelId], limit });
    },
  );

  process.stdout.write(
    `relay:    ${relay}\nchannel:  ${channelId}\nidentity: ${anonymous ? "ephemeral non-member" : "channel member"}\nevents:   ${events.length}\n`,
  );
  if (refusal) process.stdout.write(`refused:  ${refusal}\n`);

  // Both halves, and neither on its own is worth anything here. The signature
  // proves the author committed to this ID; recomputing the id proves the ID is
  // the hash of the CONTENT printed below it. Checking only the signature would
  // let a relay serve a validly-signed id beside altered content, tags, or
  // timestamp and have this tool - the one place a human looks for that
  // assurance - print "verified" over text the author never wrote. The `h` tag is
  // the third half: the `#h` filter went out on the wire, but a relay is free to
  // ignore it, so what came back is only this channel's content if the events
  // themselves say so under a signature.
  //
  // And a signature alone says only that SOMEBODY signed it. The channel id is not
  // a secret - it is a digest of the home path, printed in the header above and
  // sent to the relay in the `#h` filter - so anyone who can publish to this open
  // loopback relay can mint a keypair and sign an event carrying this channel's
  // `h` tag: id recomputes, signature verifies, tag matches, all three of the
  // checks above satisfied by content this home's publisher never wrote. Binding
  // the author to this home's recorded PUBLIC keys - current AND retired, since
  // rotation leaves the channel id and the relay's stored events alone - is what
  // separates "this channel leaked" from "someone put a lookalike event on the
  // relay".
  const attributable = ownChannel && expectedAuthors.size > 0;
  const assessed = events
    .sort((a, b) => a.created_at - b.created_at)
    .map((event) => {
      const idMatches = computeEventId(event) === event.id;
      const signed = schnorrVerify(event.id, event.pubkey, event.sig);
      const inChannel = (event.tags ?? []).some((tag) => tag[0] === "h" && tag[1] === channelId);
      const byPublisher = attributable && expectedAuthors.has((event.pubkey ?? "").toLowerCase());
      return {
        event,
        idMatches,
        signed,
        inChannel,
        byPublisher,
        authentic: idMatches && signed && inChannel && byPublisher,
      };
    });
  const authentic = assessed.filter((entry) => entry.authentic);

  // An anonymous read that RETURNS events is the one unambiguous answer this probe
  // can produce, and it is the negative one: a non-member read the private channel.
  // It has to be said out loud, because everything below prints `signature
  // verified` beside each event and a successful breach otherwise reads exactly
  // like a successful legibility check. But the accusation earns no more trust in
  // the relay than the reassurance does: the evidence for "a non-member read THIS
  // channel" is an event that recomputes to its own id, verifies under its
  // author's signature, carries this channel's `h` tag, AND was signed by one of
  // the publishing keys this home has held. A relay that serves altered, replayed
  // or fabricated frames would otherwise have this tool report a definite breach
  // of a channel that never leaked. Under --channel-label that last piece of
  // evidence cannot exist here at all, so the verdict is ruled out first: the
  // channel belongs to another home, whose keys this one does not read.
  if (anonymous && !ownChannel && events.length > 0) {
    process.stdout.write(
      `\nINCONCLUSIVE: the relay served ${events.length} event(s) to this non-member, but\n` +
        "cannot verify authorship for a channel not derived from this home; use\n" +
        "--anonymous only on this home's own channel.\n",
    );
  } else if (anonymous && authentic.length > 0) {
    process.stdout.write(
      "\nThe channel was readable by an identity that is not a member — this is a definite negative privacy result.\n",
    );
  } else if (anonymous && events.length > 0) {
    process.stdout.write(
      `\nINCONCLUSIVE: the relay served ${events.length} event(s) to this non-member, but\n` +
        "none of them are this home's own content: they are served by relay but not\n" +
        "verifiable / not tagged for this channel / not signed by any publishing key\n" +
        "this home has held. A relay that alters, replays or fabricates what it\n" +
        "serves proves nothing about who may read this channel, and neither does an\n" +
        "event any stranger could have signed against a channel id that is not a\n" +
        "secret.\n" +
        (expectedAuthors.size === 0
          ? "This home has no recorded publisher public key, so no served event can be\n" +
            "attributed to it at all - run bin/fm-buzz-keypair.sh to record one.\n"
          : "") +
        "See the per-event verdicts below.\n",
    );
  }
  // An empty anonymous read is not evidence of privacy on its own, and neither is
  // just any refusal. Only a membership-shaped refusal - NIP-01's `restricted:` -
  // machine-tags itself as being about the READER; every other reason is either
  // about the relay or the request (`auth-required:`, `rate-limited:`, `error:`,
  // `invalid:`) or untagged free text that this tool cannot read a policy out of.
  // So the reassurance is gated on that one shape, and every other outcome prints
  // the relay's own words and states only the limit - the reason is not tagged as
  // a membership refusal, so it cannot be taken for one - without asserting what
  // the relay's policy actually is. Printing a security conclusion over an
  // ambiguous absence is worse than printing nothing, and so is printing the
  // opposite conclusion: this is the one place a human looks for that answer.
  if (events.length === 0 && anonymous) {
    const ambiguous =
      "An empty read that nobody refused on membership grounds is equally what you\n" +
      "get from:\n" +
      "  - a relay that is down, restarted, or had its storage wiped\n" +
      "  - a channel id derived from a different home than the publisher's\n" +
      "  - a publish that never actually landed\n" +
      "  - a channel that is simply empty\n" +
      "  - privacy enforcement that withholds events silently, or refuses without\n" +
      "    machine-tagging its reason as a membership refusal\n" +
      "Re-run without --anonymous to read as the publisher and tell these apart.\n";
    if (classifyRefusalReason(refusal) === REFUSAL_MEMBERSHIP) {
      process.stdout.write(
        "\nNothing visible, and the relay said why: the reading identity is ephemeral\n" +
          "and was never added to this private channel, so the subscription was refused\n" +
          "rather than served. That refusal is the assurance - re-run without\n" +
          "--anonymous to read as the publisher.\n",
      );
    } else if (refusal) {
      process.stdout.write(
        "\nINCONCLUSIVE: the relay refused this subscription, but not on membership\n" +
          `grounds. It said: ${refusal}\n` +
          "That reason is not machine-tagged as a membership refusal, so it cannot be\n" +
          "read as one.\n" +
          ambiguous,
      );
    } else {
      process.stdout.write(
        "\nINCONCLUSIVE: the relay served this subscription without refusing it and\n" +
          "returned nothing, which on its own proves nothing about privacy.\n" +
          ambiguous,
      );
    }
  }
  for (const { event, idMatches, signed, inChannel, byPublisher } of assessed) {
    const when = new Date(event.created_at * 1000).toISOString();
    const verdict = !idMatches ? "INVALID (id does not match this content)"
      : signed ? "verified"
      : "INVALID";
    const channelVerdict = inChannel ? "this channel" : "NOT tagged for this channel";
    const authorVerdict = byPublisher
      ? "this home's publisher"
      : !ownChannel
        ? "unattributable (channel not derived from this home)"
        : expectedAuthors.size === 0
          ? "unknown (no publisher public key recorded for this home)"
          : "NOT this home's publisher";
    process.stdout.write(
      `\n--- ${event.id}\n    at        ${when}\n` +
        `    author    ${event.pubkey} (${authorVerdict})\n` +
        `    signature ${verdict}\n    channel   ${channelVerdict}\n\n`,
    );
    process.stdout.write(full ? `${event.content}\n` : `${event.content.slice(0, 600)}\n`);
  }
} catch (error) {
  process.stderr.write(`fm-buzz-inspect: ${error.message}\n`);
  process.exit(1);
}
