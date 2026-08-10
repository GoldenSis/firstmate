#!/usr/bin/env node
// A minimal Nostr relay, for tests only.
//
// WHY A STUB AND NOT THE REAL RELAY
// The real Buzz relay is four containers (relay + Postgres + Redis + MinIO) and a
// ~1GB image pull. CI runs `tests/*.test.sh` on a plain Linux runner with no
// Docker daemon, so a test that needed the real stack would simply skip there -
// and a test that skips in CI is not a regression test. This stub speaks the
// small slice of NIP-01 the adapter uses, including the part that actually
// matters: dedupe by event id, which is what makes replay idempotent.
//
// It deliberately VERIFIES every event's id and Schnorr signature before
// accepting it, using bin/fm-buzz-crypto.mjs's independent verify path. That
// turns "the relay accepted it" into a real assertion about our signing rather
// than a stub politely agreeing with whatever it is sent.
//
// Node has no built-in WebSocket *server* (the global WebSocket is client-only),
// so the RFC 6455 handshake and framing are implemented here. Only what a test
// needs: single-frame text messages, no extensions, no fragmentation, no
// compression.
//
// Usage: node tests/fm-buzz-stub-relay.mjs [--port N] [--reject <message>]
//                                          [--drop-after-event] [--challenge]
//                                          [--challenge-delay-ms N]
//                                          [--duplicate-refused] [--silent-ok]
//                                          [--truthy-ok]
//                                          [--tamper-on-read] [--malform-on-read]
//                                          [--wrong-kind-on-read]
//                                          [--refuse-req <msg>]
// Prints "listening <port>" on stdout once ready, so a caller can use port 0 and
// learn the ephemeral port.

import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { computeEventId, KIND_NIP42_AUTH } from "../bin/fm-buzz-lib.mjs";
import { schnorrVerify } from "../bin/fm-buzz-crypto.mjs";

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const argv = process.argv.slice(2);
let port = 0;
let reject = null;
let dropAfterEvent = false;
// --challenge models a NIP-42 relay properly, which means ENFORCING it: the
// challenge goes out on upgrade, an unauthenticated EVENT is refused with
// `auth-required:`, and the AUTH response is answered with an OK keyed to the auth
// event's id. A stub that challenged and then accepted everything anyway would let
// a broken handshake pass every test.
let challenge = false;
// How long after the upgrade the challenge is sent. The default is "immediately",
// which is what a real relay does; a delay is how a test proves the client waits
// for the frame instead of guessing when it will arrive.
let challengeDelayMs = 0;
// A relay may answer a known id either way: NIP-01 suggests OK true for an event
// it already has, but Buzz refuses an existing row outright - the publisher's own
// channel-provisioning check exists because `duplicate: channel already exists`
// arrives with accepted=false. Only the refusing shape reaches the `duplicate:`
// branch of classifyOkResponse; accepted=true is DELIVERED before that branch is
// ever consulted. Both are worth modelling, so this is a flag rather than a
// hardcoded choice.
let duplicateRefused = false;
// A relay that takes events and answers nothing at all. NIP-01 lets a relay reply
// to a bad frame with a NOTICE, which is not scoped to any event and so resolves
// no publish; this is that case, and it is the one that starves a drain if a
// publish has no deadline of its own.
let silentOk = false;
let truthyOk = false;
// A relay that stores a properly signed event and then serves it back with the
// content altered, leaving the id and signature untouched. This is the exact shape
// a signature-only check cannot see: the signature over that id is still valid, so
// the only thing that can catch it is recomputing the id from what was served.
let tamperOnRead = false;
let malformOnRead = false;
let wrongKindOnRead = false;
// A relay that enforces channel membership on reads: it answers a REQ with a
// subscription-scoped CLOSED and no EOSE, which is how a real private channel
// tells a non-member it may not see the events. Without this the stub serves every
// stored event to every reader, so an empty anonymous read here means "nothing
// stored" and never "you are not a member" - the exact ambiguity the inspector
// must not report as an assurance.
let refuseReq = null;
for (let i = 0; i < argv.length; i += 1) {
  if (argv[i] === "--port") port = Number(argv[++i]);
  else if (argv[i] === "--reject") reject = argv[++i];
  else if (argv[i] === "--drop-after-event") dropAfterEvent = true;
  else if (argv[i] === "--challenge") challenge = true;
  else if (argv[i] === "--challenge-delay-ms") challengeDelayMs = Number(argv[++i]);
  else if (argv[i] === "--duplicate-refused") duplicateRefused = true;
  else if (argv[i] === "--silent-ok") silentOk = true;
  else if (argv[i] === "--truthy-ok") truthyOk = true;
  else if (argv[i] === "--tamper-on-read") tamperOnRead = true;
  else if (argv[i] === "--malform-on-read") malformOnRead = true;
  else if (argv[i] === "--wrong-kind-on-read") wrongKindOnRead = true;
  else if (argv[i] === "--refuse-req") refuseReq = argv[++i];
}

// The event store: id -> event. A Map gives us exactly the relay's
// `ON CONFLICT DO NOTHING` semantics - a second insert of a known id is a no-op.
const store = new Map();

function encodeFrame(text) {
  const payload = Buffer.from(text, "utf8");
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x81, length]);
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  return Buffer.concat([header, payload]);
}

// Pull complete frames out of `buffer`, returning the decoded text messages and
// the unconsumed remainder.
function decodeFrames(buffer) {
  const messages = [];
  let offset = 0;
  for (;;) {
    if (buffer.length - offset < 2) break;
    const first = buffer[offset];
    const second = buffer[offset + 1];
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let cursor = offset + 2;
    if (length === 126) {
      if (buffer.length - cursor < 2) break;
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    } else if (length === 127) {
      if (buffer.length - cursor < 8) break;
      length = Number(buffer.readBigUInt64BE(cursor));
      cursor += 8;
    }
    let mask = null;
    if (masked) {
      if (buffer.length - cursor < 4) break;
      mask = buffer.subarray(cursor, cursor + 4);
      cursor += 4;
    }
    if (buffer.length - cursor < length) break;
    const payload = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    cursor += length;
    offset = cursor;
    if (opcode === 0x8) {
      messages.push({ close: true });
    } else if (opcode === 0x1) {
      messages.push({ text: payload.toString("utf8") });
    }
    // Other opcodes (ping/pong/continuation) are not produced by our client.
  }
  return { messages, rest: buffer.subarray(offset) };
}

function matches(event, filter, ignoreKinds = false) {
  if (!ignoreKinds && filter.kinds && !filter.kinds.includes(event.kind)) return false;
  for (const [key, values] of Object.entries(filter)) {
    if (!key.startsWith("#")) continue;
    const tagName = key.slice(1);
    const present = event.tags.some((tag) => tag[0] === tagName && values.includes(tag[1]));
    if (!present) return false;
  }
  return true;
}

const server = createServer((_req, res) => {
  res.writeHead(404);
  res.end();
});

server.on("upgrade", (req, socket) => {
  const key = req.headers["sec-websocket-key"];
  const accept = createHash("sha1").update(key + WS_GUID).digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );

  const send = (message) => {
    if (!socket.destroyed) socket.write(encodeFrame(JSON.stringify(message)));
  };

  const challengeString = "0".repeat(64);
  let challengeIssued = false;
  let authenticated = false;
  if (challenge) {
    const issue = () => {
      challengeIssued = true;
      send(["AUTH", challengeString]);
    };
    if (challengeDelayMs > 0) setTimeout(issue, challengeDelayMs).unref();
    else issue();
  }

  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    const { messages, rest } = decodeFrames(buffer);
    buffer = rest;
    for (const message of messages) {
      if (message.close) {
        socket.end();
        return;
      }
      let parsed;
      try {
        parsed = JSON.parse(message.text);
      } catch {
        continue;
      }
      const [type] = parsed;
      if (type === "AUTH") {
        // NIP-42: the response is a kind-22242 event carrying the challenge, and
        // the relay answers it with an OK keyed to that event's id. Verifying it
        // here is what turns "authenticated" into a real assertion, and answering
        // it is the frame the client waits on instead of sleeping.
        const event = parsed[1] ?? {};
        const carries = (event.tags ?? []).some(
          (tag) => tag[0] === "challenge" && tag[1] === challengeString,
        );
        const valid =
          challengeIssued &&
          event.kind === KIND_NIP42_AUTH &&
          carries &&
          computeEventId(event) === event.id &&
          schnorrVerify(event.id, event.pubkey, event.sig);
        if (valid) authenticated = true;
        send(["OK", event.id, valid, valid ? "" : "error: bad auth response"]);
        continue;
      }
      if (type === "EVENT") {
        const event = parsed[1];
        if (challenge && !authenticated) {
          send(["OK", event.id, false, "auth-required: we only accept events from authenticated users"]);
          continue;
        }
        if (dropAfterEvent) {
          // Simulate a kill mid-publish: the relay received the event but the
          // connection dies before the OK is written. The client must treat this
          // as unknown-delivery and keep the event cached.
          store.set(event.id, event);
          socket.destroy();
          return;
        }
        if (silentOk) {
          store.set(event.id, event);
          continue; // received, stored, never acknowledged
        }
        if (reject) {
          send(["OK", event.id, truthyOk ? "false" : false, reject]);
          continue;
        }
        if (computeEventId(event) !== event.id) {
          send(["OK", event.id, false, "invalid: event id does not match its content"]);
          continue;
        }
        if (!schnorrVerify(event.id, event.pubkey, event.sig)) {
          send(["OK", event.id, false, "invalid: bad signature"]);
          continue;
        }
        if (store.has(event.id)) {
          if (duplicateRefused) {
            send(["OK", event.id, truthyOk ? "false" : false, "duplicate: event already stored"]);
          } else send(["OK", event.id, true, "duplicate:"]);
          continue;
        }
        store.set(event.id, event);
        send(["OK", event.id, truthyOk ? "false" : true, ""]);
      } else if (type === "REQ") {
        const [, subId, filter = {}] = parsed;
        if (refuseReq) {
          // CLOSED and deliberately no EOSE, matching a relay that rejects the
          // subscription outright rather than serving an empty result set.
          send(["CLOSED", subId, refuseReq]);
          continue;
        }
        const found = [...store.values()]
          .filter((event) =>
            wrongKindOnRead
              ? Array.isArray(filter.kinds) &&
                !filter.kinds.includes(event.kind) &&
                matches(event, filter, true)
              : matches(event, filter),
          )
          .sort((a, b) => a.created_at - b.created_at);
        for (const event of found) {
          if (malformOnRead) {
            send(["EVENT", subId, { ...event, id: { malformed: true } }]);
            send(["EVENT", subId, { ...event, tags: { malformed: true } }]);
            send(["EVENT", subId, { ...event, created_at: "not-a-timestamp" }]);
            send(["EVENT", subId, { ...event, content: { malformed: true } }]);
          } else {
            send(["EVENT", subId, tamperOnRead ? { ...event, content: "TAMPERED" } : event]);
          }
        }
        send(["EOSE", subId]);
      } else if (type === "CLOSE") {
        // Nothing to tear down: subscriptions here are one-shot.
      }
    }
  });

  socket.on("error", () => socket.destroy());
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`listening ${server.address().port}\n`);
});
