#!/usr/bin/env node
// BIP-340 Schnorr signatures over secp256k1, in pure BigInt with no dependency.
//
// WHY THIS EXISTS
// Nostr (NIP-01) identifies every event by a SHA-256 over its canonical
// serialization and authenticates it with a BIP-340 Schnorr signature. Publishing
// one signed bearings event therefore needs secp256k1. This host has no
// secp256k1 binding (no `coincurve`, no `secp256k1` Python module, no Rust
// toolchain to build buzz-cli), and firstmate has no package.json and no
// node_modules - it ships shell plus a few dependency-free .mjs policy modules.
// Adding an npm dependency tree to a repo that deliberately has none, for a
// proof of concept, is the worse trade. So the curve arithmetic lives here,
// self-contained, and tests/fm-buzz-keypair.test.sh proves it correct against the
// official BIP-340 test vectors rather than asserting it by inspection - every
// 32-byte-message vector, signing and verification, including all ten negative
// cases. The variable-length-message vectors (15-18) are deliberately excluded
// and are NOT covered: this signer accepts a 32-byte message only, because that
// is all NIP-01 ever produces, so it throws on those inputs and schnorrVerify
// returns false for them. That is the fail-closed answer, not a passing one.
//
// KNOWN LIMITATION - NOT CONSTANT TIME
// JavaScript BigInt operations are not constant time, so this signer leaks timing
// information about the private key in principle. That is acceptable for exactly
// the key this PoC uses and no other: a loopback-only fleet-reporting key that
// signs nothing of value, holds no funds, grants no authority (merge authority
// stays in bin/fm-pr-merge.sh per AGENTS.md section 7). Do not reuse this module
// for a key that guards anything, and do not promote it to a networked or shared
// relay without replacing it with an audited binding. bin/fm-buzz-keypair.sh
// --help owns the rotation, retention, membership, and recovery procedure.
//
// The exported surface is deliberately small: schnorrSign, schnorrVerify,
// publicKeyFromPrivate, and the hex helpers the event layer needs.
// bin/fm-buzz-lib.mjs owns NIP-01 event construction on top of this.

import { createHash, randomBytes } from "node:crypto";

// secp256k1 domain parameters (SEC 2, v2.0).
const P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const Gx = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n;
const Gy = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n;

// --- field helpers ----------------------------------------------------------

function mod(a, m = P) {
  const r = a % m;
  return r >= 0n ? r : r + m;
}

// Modular exponentiation. Used for inversion and for the square root below.
function powMod(base, exp, m) {
  let result = 1n;
  let b = mod(base, m);
  let e = exp;
  while (e > 0n) {
    if (e & 1n) result = (result * b) % m;
    b = (b * b) % m;
    e >>= 1n;
  }
  return result;
}

// Fermat inversion: valid because P is prime, and a is never 0 at our call sites.
function invMod(a, m = P) {
  return powMod(a, m - 2n, m);
}

// --- curve arithmetic in Jacobian coordinates -------------------------------
//
// A Jacobian point (X, Y, Z) represents the affine point (X/Z^2, Y/Z^3); Z === 0n
// is the point at infinity. Jacobian form keeps scalar multiplication free of
// modular inversions - only the final conversion to affine needs one.

const INFINITY = { x: 0n, y: 0n, z: 0n };

function isInfinity(point) {
  return point.z === 0n;
}

// dbl-2009-l, specialised for the a = 0 short Weierstrass curve secp256k1 uses.
function jacobianDouble(point) {
  const { x, y, z } = point;
  if (y === 0n || z === 0n) return INFINITY;
  const a = mod(x * x);
  const b = mod(y * y);
  const c = mod(b * b);
  const d = mod(2n * (mod(mod(x + b) * mod(x + b)) - a - c));
  const e = mod(3n * a);
  const f = mod(e * e);
  const nx = mod(f - 2n * d);
  const ny = mod(e * mod(d - nx) - 8n * c);
  const nz = mod(2n * y * z);
  return { x: nx, y: ny, z: nz };
}

// add-2007-bl.
function jacobianAdd(p1, p2) {
  if (isInfinity(p1)) return p2;
  if (isInfinity(p2)) return p1;
  const z1z1 = mod(p1.z * p1.z);
  const z2z2 = mod(p2.z * p2.z);
  const u1 = mod(p1.x * z2z2);
  const u2 = mod(p2.x * z1z1);
  const s1 = mod(p1.y * z2z2 * p2.z);
  const s2 = mod(p2.y * z1z1 * p1.z);
  const h = mod(u2 - u1);
  const r = mod(2n * (s2 - s1));
  if (h === 0n) {
    // Same x: either a doubling, or two points that sum to infinity.
    return r === 0n ? jacobianDouble(p1) : INFINITY;
  }
  const i = mod(mod(2n * h) * mod(2n * h));
  const j = mod(h * i);
  const v = mod(u1 * i);
  const x3 = mod(mod(r * r) - j - 2n * v);
  const y3 = mod(r * mod(v - x3) - 2n * s1 * j);
  const z3 = mod(mod(mod(mod(p1.z + p2.z) * mod(p1.z + p2.z)) - z1z1 - z2z2) * h);
  return { x: x3, y: y3, z: z3 };
}

// Left-to-right double-and-add. See the constant-time caveat in the header.
function jacobianMultiply(point, scalar) {
  let k = mod(scalar, N);
  if (k === 0n || isInfinity(point)) return INFINITY;
  let result = INFINITY;
  let addend = point;
  while (k > 0n) {
    if (k & 1n) result = jacobianAdd(result, addend);
    addend = jacobianDouble(addend);
    k >>= 1n;
  }
  return result;
}

function toAffine(point) {
  if (isInfinity(point)) return null;
  const zInv = invMod(point.z);
  const zInv2 = mod(zInv * zInv);
  return { x: mod(point.x * zInv2), y: mod(point.y * zInv2 * zInv) };
}

function generatorMultiply(scalar) {
  return toAffine(jacobianMultiply({ x: Gx, y: Gy, z: 1n }, scalar));
}

// BIP-340 lift_x: recover the even-y affine point for an x-only public key.
// Returns null when x is out of range or not on the curve, so callers reject
// rather than compute with a bogus point.
function liftX(x) {
  if (x <= 0n || x >= P) return null;
  const c = mod(x * x * x + 7n);
  // P % 4 === 3, so the candidate square root is c^((P+1)/4).
  const y = powMod(c, (P + 1n) / 4n, P);
  if (mod(y * y) !== c) return null;
  return { x, y: (y & 1n) === 0n ? y : P - y };
}

// --- byte / hex helpers -----------------------------------------------------

export function bytesToHex(bytes) {
  return Buffer.from(bytes).toString("hex");
}

export function hexToBytes(hex) {
  if (typeof hex !== "string" || !/^[0-9a-fA-F]*$/.test(hex) || hex.length % 2 !== 0) {
    throw new Error("invalid hex string");
  }
  return Uint8Array.from(Buffer.from(hex, "hex"));
}

function bytesToBigInt(bytes) {
  return BigInt("0x" + (bytesToHex(bytes) || "0"));
}

function bigIntTo32Bytes(value) {
  const hex = value.toString(16).padStart(64, "0");
  if (hex.length > 64) throw new Error("value does not fit in 32 bytes");
  return hexToBytes(hex);
}

export function sha256(...chunks) {
  const hash = createHash("sha256");
  for (const chunk of chunks) hash.update(Buffer.from(chunk));
  return Uint8Array.from(hash.digest());
}

// BIP-340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || msg).
function taggedHash(tag, ...msg) {
  const tagHash = sha256(Buffer.from(tag, "utf8"));
  return sha256(tagHash, tagHash, ...msg);
}

function xorBytes(a, b) {
  const out = new Uint8Array(a.length);
  for (let i = 0; i < a.length; i += 1) out[i] = a[i] ^ b[i];
  return out;
}

// --- public API -------------------------------------------------------------

// Validate a 32-byte private key and return it as a scalar in [1, N-1].
function privateScalar(privateKeyHex) {
  const bytes = hexToBytes(privateKeyHex);
  if (bytes.length !== 32) throw new Error("private key must be 32 bytes");
  const d = bytesToBigInt(bytes);
  if (d <= 0n || d >= N) throw new Error("private key out of range");
  return d;
}

// The x-only (32-byte, BIP-340) public key for a private key, as lowercase hex.
export function publicKeyFromPrivate(privateKeyHex) {
  const point = generatorMultiply(privateScalar(privateKeyHex));
  return bytesToHex(bigIntTo32Bytes(point.x));
}

// Generate a fresh keypair. The private key comes from the OS CSPRNG, and a
// scalar outside [1, N-1] is rejected and redrawn rather than clamped.
export function generateKeypair() {
  for (;;) {
    const candidate = Uint8Array.from(randomBytes(32));
    const d = bytesToBigInt(candidate);
    if (d > 0n && d < N) {
      const privateKey = bytesToHex(candidate);
      return { privateKey, publicKey: publicKeyFromPrivate(privateKey) };
    }
  }
}

// Sign a 32-byte message per BIP-340. `auxRand` is exposed only so the test
// suite can replay the official vectors; production callers omit it and get
// fresh CSPRNG auxiliary randomness.
export function schnorrSign(messageHex, privateKeyHex, auxRandHex) {
  const message = hexToBytes(messageHex);
  if (message.length !== 32) throw new Error("message must be 32 bytes");
  const dPrime = privateScalar(privateKeyHex);
  const pointP = generatorMultiply(dPrime);
  // BIP-340 signs with the private key whose public point has even y.
  const d = (pointP.y & 1n) === 0n ? dPrime : N - dPrime;
  const px = bigIntTo32Bytes(pointP.x);

  const auxRand = auxRandHex === undefined
    ? Uint8Array.from(randomBytes(32))
    : hexToBytes(auxRandHex);
  if (auxRand.length !== 32) throw new Error("aux rand must be 32 bytes");

  const t = xorBytes(bigIntTo32Bytes(d), taggedHash("BIP0340/aux", auxRand));
  const rand = taggedHash("BIP0340/nonce", t, px, message);
  const kPrime = mod(bytesToBigInt(rand), N);
  if (kPrime === 0n) throw new Error("nonce derivation failed");

  const pointR = generatorMultiply(kPrime);
  const k = (pointR.y & 1n) === 0n ? kPrime : N - kPrime;
  const rx = bigIntTo32Bytes(pointR.x);
  const e = mod(bytesToBigInt(taggedHash("BIP0340/challenge", rx, px, message)), N);
  const s = mod(k + e * d, N);

  const signature = bytesToHex(rx) + bytesToHex(bigIntTo32Bytes(s));
  // Verify before returning: a signature this module cannot itself verify is a
  // bug, and emitting it would put a permanently-rejected event in the replay
  // cache where it would be retried forever.
  if (!schnorrVerify(messageHex, bytesToHex(px), signature)) {
    throw new Error("self-verification of fresh signature failed");
  }
  return signature;
}

// Verify a BIP-340 signature. Returns a boolean and never throws on
// well-formed-but-invalid input, so callers can treat it as a predicate.
export function schnorrVerify(messageHex, publicKeyHex, signatureHex) {
  let message;
  let publicKey;
  let signature;
  try {
    message = hexToBytes(messageHex);
    publicKey = hexToBytes(publicKeyHex);
    signature = hexToBytes(signatureHex);
  } catch {
    return false;
  }
  if (message.length !== 32 || publicKey.length !== 32 || signature.length !== 64) {
    return false;
  }
  const pointP = liftX(bytesToBigInt(publicKey));
  if (pointP === null) return false;
  const r = bytesToBigInt(signature.subarray(0, 32));
  const s = bytesToBigInt(signature.subarray(32, 64));
  if (r >= P || s >= N) return false;
  const e = mod(
    bytesToBigInt(taggedHash("BIP0340/challenge", signature.subarray(0, 32), publicKey, message)),
    N,
  );
  // R = s*G - e*P
  const sG = jacobianMultiply({ x: Gx, y: Gy, z: 1n }, s);
  const eP = jacobianMultiply({ x: pointP.x, y: pointP.y, z: 1n }, mod(N - e, N));
  const pointR = toAffine(jacobianAdd(sG, eP));
  if (pointR === null) return false;
  return (pointR.y & 1n) === 0n && pointR.x === r;
}
