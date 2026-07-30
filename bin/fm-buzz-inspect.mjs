#!/usr/bin/env node
// Read back published bearings events from the loopback relay, for a human.
//
// Driven by bin/fm-buzz-inspect.sh, which is the supported entry point: it owns
// resolving the reading identity so no private key reaches a command line. This
// file reads one JSON envelope on stdin: {privateKey, relay, channelId, limit,
// full}. An empty privateKey means "read with a throwaway identity".
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
  computeEventId,
  readStdin,
  withRelay,
  KIND_STREAM_MESSAGE,
} from "./fm-buzz-lib.mjs";
import { generateKeypair, schnorrVerify } from "./fm-buzz-crypto.mjs";

const envelope = JSON.parse(await readStdin());
const relay = envelope.relay ?? "ws://localhost:3000";
const limit = envelope.limit ?? 3;
const full = Boolean(envelope.full);
const channelId = envelope.channelId || channelIdForLabel(envelope.channelLabel ?? "");
// A blank key means read as a stranger, which is the useful shape for confirming
// that a private channel really is invisible to non-members.
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
  if (events.length === 0 && anonymous) {
    process.stdout.write(
      "\nNothing visible, which is the CORRECT answer here: the reading identity is\n" +
        "ephemeral and was never added to this private channel, so the relay withholds\n" +
        "the events. Re-run without --anonymous to read as the publisher.\n",
    );
  }
  for (const event of events.sort((a, b) => a.created_at - b.created_at)) {
    const when = new Date(event.created_at * 1000).toISOString();
    // Both halves, and neither on its own is worth anything here. The signature
    // proves the author committed to this ID; recomputing the id proves the ID is
    // the hash of the CONTENT printed below it. Checking only the signature would
    // let a relay serve a validly-signed id beside altered content, tags, or
    // timestamp and have this tool - the one place a human looks for that
    // assurance - print "verified" over text the author never wrote.
    const idMatches = computeEventId(event) === event.id;
    const signed = schnorrVerify(event.id, event.pubkey, event.sig);
    const verdict = !idMatches ? "INVALID (id does not match this content)"
      : signed ? "verified"
      : "INVALID";
    process.stdout.write(
      `\n--- ${event.id}\n    at        ${when}\n    author    ${event.pubkey}\n` +
        `    signature ${verdict}\n\n`,
    );
    process.stdout.write(full ? `${event.content}\n` : `${event.content.slice(0, 600)}\n`);
  }
} catch (error) {
  process.stderr.write(`fm-buzz-inspect: ${error.message}\n`);
  process.exit(1);
}
