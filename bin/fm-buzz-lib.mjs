#!/usr/bin/env node
// NIP-01 event construction and the loopback Buzz relay client.
//
// Layered on bin/fm-buzz-crypto.mjs (BIP-340 signing) and consumed by
// bin/fm-buzz-publish.sh via bin/fm-buzz-publish.mjs. This module owns the wire
// format and the relay conversation; it owns no policy. The fire-and-forget
// contract, the replay cache, and the snapshot plumbing live in the publisher.
//
// WHY THE EVENT ID MATTERS MORE THAN USUAL HERE
// A NIP-01 event id is SHA-256 over [0, pubkey, created_at, kind, tags, content],
// so `created_at` is part of the identity. Buzz's relay dedupes on that id
// (`INSERT ... ON CONFLICT DO NOTHING`), which makes resubmitting the
// byte-identical signed event perfectly idempotent - and makes re-signing the
// same logical message a DUPLICATE, because a new `created_at` yields a new id.
// Everything downstream of signEvent must therefore move signed bytes around, not
// rebuild events. The publisher's replay cache stores exact bytes for this reason.
//
// Scope note: this speaks only the subset of the protocol M1 needs - create a
// private channel idempotently, publish append-only channel messages, and (for
// human verification only) read events back. No canvas kind is implemented, by
// invariant: Buzz canvases are a single mutable TEXT column overwritten with no
// compare-and-set, so publishing state into one would silently clobber concurrent
// captain edits. Append-only messages only.

import { schnorrSign, sha256, bytesToHex, publicKeyFromPrivate } from "./fm-buzz-crypto.mjs";

// Buzz kind numbers, from crates/buzz-core/src/kind.rs at commit 7fb008f9.
export const KIND_STREAM_MESSAGE = 9; // NIP-29 channel chat message (append-only)
export const KIND_NIP29_CREATE_GROUP = 9007; // creates a channel; creator becomes owner
export const KIND_NIP42_AUTH = 22242; // NIP-42 challenge response

// NIP-01 canonical serialization. JSON.stringify already produces the required
// form: no insignificant whitespace, minimal escaping of ", \\ and the C0
// controls, and raw (unescaped) UTF-8 for everything else.
export function canonicalSerialization(event) {
  return JSON.stringify([
    0,
    event.pubkey,
    event.created_at,
    event.kind,
    event.tags,
    event.content,
  ]);
}

export function computeEventId(event) {
  return bytesToHex(sha256(Buffer.from(canonicalSerialization(event), "utf8")));
}

// Turn an unsigned event into a signed one. Returns a NEW object; the id and sig
// are derived from the exact fields present at call time, so a caller must not
// mutate the result afterwards (that would invalidate both).
export function signEvent(unsigned, privateKeyHex) {
  const event = {
    pubkey: publicKeyFromPrivate(privateKeyHex),
    created_at: unsigned.created_at,
    kind: unsigned.kind,
    tags: unsigned.tags ?? [],
    content: unsigned.content ?? "",
  };
  event.id = computeEventId(event);
  event.sig = schnorrSign(event.id, privateKeyHex);
  return event;
}

// Derive a stable channel UUID from a label, so the same home publishes to the
// same private channel on every invocation with nothing to persist and no
// registry to keep in sync. Shaped as a v5 (name-based, SHA-1-style) UUID:
// SHA-256 truncated to 128 bits with the version and variant bits set. It is not
// RFC-4122 v5 (that mandates SHA-1); it only needs to be stable, well-formed, and
// collision-free in practice, and it is deliberately derived rather than random
// so a lost keypair or wiped cache does not orphan the channel.
export function channelIdForLabel(label) {
  const digest = sha256(Buffer.from(`firstmate-buzz-channel:${label}`, "utf8"));
  const bytes = Uint8Array.from(digest.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50; // version 5
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytesToHex(bytes);
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

export function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

// Both entry points are fed one JSON envelope on stdin - that is how the private
// key, and the projection with it, stay off every command line - so both need
// this, and it lives here rather than being copied into each of them.
export function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

// Build the idempotent private-channel creation event. Re-sending it is safe:
// the relay answers `duplicate: channel already exists` when the row is present.
export function buildChannelCreateEvent(channelId, name, about, privateKeyHex) {
  const tags = [
    ["h", channelId],
    ["name", name],
    ["visibility", "private"],
    ["channel_type", "stream"],
  ];
  if (about) tags.push(["about", about]);
  return signEvent(
    { created_at: nowSeconds(), kind: KIND_NIP29_CREATE_GROUP, tags, content: "" },
    privateKeyHex,
  );
}

// Build one append-only bearings message. `content` is the projection verbatim -
// including its omitted[] disclosure - because a bounded projection whose
// truncation disclosure was stripped in transit is worse than no projection: an
// absence stops being unambiguous.
export function buildBearingsEvent(channelId, content, privateKeyHex, extraTags = []) {
  const tags = [["h", channelId], ...extraTags];
  return signEvent(
    { created_at: nowSeconds(), kind: KIND_STREAM_MESSAGE, tags, content },
    privateKeyHex,
  );
}

// --- relay response classification ------------------------------------------
//
// Buzz's CLI models delivery outcomes as retryable / permanent / unknown rather
// than guessing, and the adapter needs the same distinction to decide whether a
// cached event should be replayed or dropped. Getting this wrong in either
// direction is bad: treating a permanent rejection as retryable wedges the cache
// replaying an event that can never land, and treating a transient one as
// permanent silently loses a message.

export const DELIVERED = "delivered";
export const RETRYABLE = "retryable";
export const PERMANENT = "permanent";

export function classifyOkResponse(accepted, message = "") {
  if (accepted) return DELIVERED;
  const text = String(message);
  // The relay already has this id; ON CONFLICT DO NOTHING did its job. That is
  // the success case for a replayed event, not a failure.
  if (text.startsWith("duplicate:")) return DELIVERED;
  // Provisioning-shaped refusals can clear once the channel or membership
  // exists, so keep the event and replay it later.
  if (text.startsWith("auth-required:") || text.startsWith("restricted:")) return RETRYABLE;
  // Malformed, blocked, or policy-rejected events will never be accepted; a
  // replay would loop forever.
  if (text.startsWith("invalid:") || text.startsWith("blocked:") || text.startsWith("pow:")) {
    return PERMANENT;
  }
  // Relay-internal errors are worth one more try.
  if (text.startsWith("error:")) return RETRYABLE;
  return RETRYABLE;
}

// --- relay client -----------------------------------------------------------

function buildAuthEvent(relayUrl, challenge, privateKeyHex) {
  return signEvent(
    {
      created_at: nowSeconds(),
      kind: KIND_NIP42_AUTH,
      tags: [
        ["relay", relayUrl],
        ["challenge", challenge],
      ],
      content: "",
    },
    privateKeyHex,
  );
}

// Open one connection, run `handler` against it, and always close it. Every
// failure mode - refused connection, handshake error, timeout, mid-flight socket
// drop - surfaces as a rejected promise for the caller to log; nothing here
// decides what a failure means for the process exit code.
// `publishTimeoutMs` bounds ONE acknowledgement rather than the whole connection.
// Without it the only bound is `timeoutMs`, and a single publish that never gets
// an OK - a relay that answers with a NOTICE, say - eats the entire connection
// budget, so the channel-create that runs before the replay drain can starve the
// drain completely and no cached event is ever attempted. Per-publish it costs one
// slow event instead of every remaining one. A fifth of the connection budget
// leaves room for a useful drain after the worst single stall.
//
// `authChallengeTimeoutMs` bounds only the wait for a challenge that may never
// come, and it is the sole timer here that can expire in normal operation: a
// NIP-42 relay issues its AUTH frame with the handshake, so the wait ends on
// arrival, while an open relay never sends one and the deadline is what lets the
// run proceed. It cannot be unbounded, because "never challenged" and "challenged
// eventually" are indistinguishable until the deadline passes, and an open relay
// must not pay for that.
//
// Losing that race therefore costs a whole unauthenticated pass, not one event:
// the caller publishes, every event comes back `auth-required:`, and every one is
// classified retryable. `completeLateAuthentication` is the second and last
// window - it settles the challenge that arrived during that pass and lets the
// caller re-attempt what the unauthenticated window refused. Honest worst case:
// a relay whose AUTH lands after BOTH windows leaves the run unauthenticated and
// every event cached for the next run, which will race it again.
async function withRelay(relayUrl, privateKeyHex, timeoutMs, handler, options = {}) {
  if (typeof WebSocket !== "function") {
    throw new Error("this Node build has no global WebSocket");
  }
  const publishTimeoutMs = options.publishTimeoutMs ?? Math.max(1000, Math.floor(timeoutMs / 5));
  const authChallengeTimeoutMs = options.authChallengeTimeoutMs ?? Math.min(publishTimeoutMs, 500);
  const socket = new WebSocket(relayUrl);
  const pending = new Map(); // event id -> {resolve}
  let authChallenge = null;
  let challengeWaiter = null; // resolve fn armed while an authentication window waits
  let challengeWaitDone = false; // true once the up-front handshake attempt settled
  let authSent = false;
  let lateAuth = null; // promise for a challenge answered after the handshake window
  const subscriptions = new Map(); // sub id -> {events, resolve}

  const closed = new Promise((resolve) => {
    socket.addEventListener("close", () => resolve());
  });

  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`relay timeout after ${timeoutMs}ms`)), timeoutMs);
  });

  const opened = new Promise((resolve, reject) => {
    socket.addEventListener("open", () => resolve());
    socket.addEventListener("error", () => reject(new Error(`relay connection failed: ${relayUrl}`)));
  });

  socket.addEventListener("message", (frame) => {
    let message;
    try {
      message = JSON.parse(typeof frame.data === "string" ? frame.data : String(frame.data));
    } catch {
      return; // a frame we cannot parse is not actionable
    }
    if (!Array.isArray(message)) return;
    const [type] = message;
    if (type === "OK") {
      const [, id, accepted, note] = message;
      const waiter = pending.get(id);
      if (waiter) {
        pending.delete(id);
        waiter.resolve({ id, accepted: Boolean(accepted), message: note ?? "" });
      }
    } else if (type === "AUTH") {
      authChallenge = message[1];
      if (challengeWaiter) {
        const resolve = challengeWaiter;
        challengeWaiter = null;
        resolve(authChallenge);
      } else if (challengeWaitDone && !authSent) {
        // The up-front handshake gave up before this challenge landed, so nobody
        // will ever wait for it. Answer it here instead, and KEEP the promise:
        // sending the response is not the same as the relay having accepted it,
        // and a caller whose events were refused while this was outstanding needs
        // to know when - and whether - authentication actually completed before it
        // re-attempts them.
        lateAuth = respondToChallenge(authChallenge);
      }
      // Before that point the challenge is simply recorded: authenticateIfChallenged
      // picks it up and waits for the relay's answer to the response, which is the
      // only path that can report whether authentication actually succeeded.
    } else if (type === "EVENT") {
      const sub = subscriptions.get(message[1]);
      if (sub) sub.events.push(message[2]);
    } else if (type === "EOSE") {
      const sub = subscriptions.get(message[1]);
      if (sub) sub.resolve(sub.events);
    } else if (type === "CLOSED") {
      // CLOSED is subscription-scoped in NIP-01, and it is the relay's way of
      // refusing a REQ outright - a private channel answers a non-member with
      // `restricted: not a channel member` and then sends no EOSE at all. Resolve
      // the subscription with whatever arrived (usually nothing) so the reader
      // reports the refusal instead of hanging until the timeout.
      const sub = subscriptions.get(message[1]);
      if (sub) {
        sub.closedReason = String(message[2] ?? "");
        sub.resolve(sub.events);
      }
    }
    // A NOTICE is a free-text relay remark that is not scoped to any event or
    // subscription, so it never resolves a pending publish. A publish that gets
    // no OK is bounded by the socket-close race and the timeout instead.
  });

  // Send one frame and settle on the OK the relay keys to `id`. Every wait in
  // this client is one of these: an OK frame, a socket close, or a deadline.
  async function sendAndAwaitOk(frame, id, deadlineMs) {
    const response = new Promise((resolve) => pending.set(id, { resolve }));
    let deadline;
    // Expiring drops the waiter, so a late OK for this id is ignored rather
    // than resolving a promise nobody is holding any more.
    const expired = new Promise((_, reject) => {
      deadline = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`no acknowledgement within ${deadlineMs}ms`));
      }, deadlineMs);
    });
    try {
      socket.send(frame);
      return await Promise.race([response, expired, closed.then(() => {
        // The socket closed with no OK: genuinely unknown delivery. Report it as
        // retryable so the event stays cached; the relay's id dedupe makes a
        // redundant replay a no-op rather than a duplicate.
        throw new Error("relay closed before acknowledging the event");
      })]);
    } finally {
      clearTimeout(deadline);
      pending.delete(id);
    }
  }

  // Sign the NIP-42 response to `challenge`, send it, and settle on the OK the
  // relay keys to the auth event's id. Marks the handshake as answered before it
  // awaits anything, so one challenge is never responded to twice. Never rejects:
  // the outcome is always one of the four names below.
  async function respondToChallenge(challenge) {
    authSent = true;
    const authEvent = buildAuthEvent(relayUrl, challenge, privateKeyHex);
    try {
      const response = await sendAndAwaitOk(
        JSON.stringify(["AUTH", authEvent]),
        authEvent.id,
        publishTimeoutMs,
      );
      return response.accepted ? "authenticated" : "refused";
    } catch {
      // A relay that takes the AUTH and says nothing is not a reason to abandon
      // the run: publishing decides delivery, and an `auth-required:` answer
      // there is already classified as retryable.
      return "unacknowledged";
    }
  }

  // Resolve with the challenge the moment it arrives, or with null when the
  // deadline passes or the socket closes without one.
  function awaitChallenge() {
    if (authChallenge) {
      challengeWaitDone = true;
      return Promise.resolve(authChallenge);
    }
    return new Promise((resolve) => {
      const settle = (challenge) => {
        clearTimeout(challengeTimer);
        challengeWaiter = null;
        challengeWaitDone = true;
        resolve(challenge);
      };
      const challengeTimer = setTimeout(() => settle(null), authChallengeTimeoutMs);
      challengeWaiter = settle;
      closed.then(() => settle(authChallenge));
    });
  }

  // Both authentication windows are the same routine and share one body, because
  // two copies of a state machine over these mutable flags is exactly the kind of
  // thing that drifts apart on the next edit. It settles whatever is outstanding:
  // an answer already in flight is awaited rather than duplicated, a challenge in
  // hand is answered, and a challenge that never comes is not an error.
  //
  // The single answer is kept in `lateAuth` whichever window produced it, so the
  // second caller learns the handshake's real outcome - authenticated, refused, or
  // unacknowledged - rather than only that somebody else answered first. That is
  // the whole point of calling twice: the caller re-attempts refused events only
  // when authentication actually completed.
  // Returns one of:
  //   not-challenged  the relay never sent AUTH (an open relay; not an error)
  //   authenticated   the relay accepted the response
  //   refused         the relay rejected the response
  //   unacknowledged  no answer within the deadline; the run proceeds anyway
  async function settleAuthentication() {
    if (lateAuth) return lateAuth;
    const challenge = await awaitChallenge();
    if (!challenge) return "not-challenged";
    if (lateAuth) return lateAuth;
    lateAuth = respondToChallenge(challenge);
    return lateAuth;
  }

  const api = {
    // NIP-42: answer the challenge if the relay issued one, and do not return
    // until the relay has answered that response, so a publish is never sent into
    // an unfinished handshake. Every step is driven by a frame rather than a
    // fixed delay: the challenge wait ends when the AUTH frame lands, and the
    // response wait ends on the OK the relay keys to the auth event's id.
    authenticateIfChallenged: settleAuthentication,

    // The second and final authentication window, for a caller that published
    // during the unauthenticated gap and got `auth-required:` back. Three cases,
    // all of which end here rather than in another guess:
    //   the challenge landed mid-publish - the frame handler already answered it
    //     and this returns that answer's real outcome;
    //   the challenge has not landed yet - wait one more bounded window, since
    //     `auth-required:` proves the relay does intend to challenge;
    //   it never lands - "not-challenged", and the caller keeps its events cached.
    completeLateAuthentication: settleAuthentication,

    // Send one already-signed event and wait for its OK. `raw` is the exact
    // stored bytes when replaying, so the id - and therefore the relay's dedupe
    // decision - is unchanged.
    async publish(event, raw) {
      return sendAndAwaitOk(raw ?? JSON.stringify(["EVENT", event]), event.id, publishTimeoutMs);
    },

    // Read-only, human-facing: used by bin/fm-buzz-inspect.mjs to prove a
    // published event is legible. Firstmate never consumes this.
    // Returns {events, refusal}: refusal is the relay's CLOSED reason when the
    // subscription was rejected rather than served, so a caller can tell "no
    // events" apart from "you may not see this channel".
    async query(filter, subId = "fm-inspect") {
      const events = [];
      const entry = { events, resolve: null, closedReason: "" };
      const done = new Promise((resolve) => {
        entry.resolve = resolve;
      });
      subscriptions.set(subId, entry);
      socket.send(JSON.stringify(["REQ", subId, filter]));
      const result = await done;
      socket.send(JSON.stringify(["CLOSE", subId]));
      subscriptions.delete(subId);
      return { events: result, refusal: entry.closedReason };
    },
  };

  try {
    await Promise.race([opened, timeout]);
    return await Promise.race([handler(api), timeout]);
  } finally {
    clearTimeout(timer);
    try {
      socket.close();
    } catch {
      // Closing a socket that already failed is not itself an error.
    }
  }
}

export { withRelay };
