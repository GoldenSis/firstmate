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
async function withRelay(relayUrl, privateKeyHex, timeoutMs, handler) {
  if (typeof WebSocket !== "function") {
    throw new Error("this Node build has no global WebSocket");
  }
  const socket = new WebSocket(relayUrl);
  const pending = new Map(); // event id -> {resolve}
  let authChallenge = null;
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

  const api = {
    // NIP-42: answer the challenge if the relay issued one. Harmless when it did
    // not - an open relay simply never sends AUTH.
    async authenticateIfChallenged() {
      // Give a challenge that arrived with the handshake a moment to land.
      await new Promise((resolve) => setTimeout(resolve, 50));
      if (!authChallenge) return false;
      socket.send(JSON.stringify(["AUTH", buildAuthEvent(relayUrl, authChallenge, privateKeyHex)]));
      await new Promise((resolve) => setTimeout(resolve, 100));
      return true;
    },

    // Send one already-signed event and wait for its OK. `raw` is the exact
    // stored bytes when replaying, so the id - and therefore the relay's dedupe
    // decision - is unchanged.
    async publish(event, raw) {
      const response = new Promise((resolve) => pending.set(event.id, { resolve }));
      socket.send(raw ?? JSON.stringify(["EVENT", event]));
      return Promise.race([response, closed.then(() => {
        // The socket closed with no OK: genuinely unknown delivery. Report it as
        // retryable so the event stays cached; the relay's id dedupe makes a
        // redundant replay a no-op rather than a duplicate.
        throw new Error("relay closed before acknowledging the event");
      })]);
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
