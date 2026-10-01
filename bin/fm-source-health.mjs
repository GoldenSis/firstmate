#!/usr/bin/env node
// Bootstrap capability diagnostics: explicit, public-read source-health receipts.
// Usage: node bin/fm-source-health.mjs [--help]
// Prints six JSONL records to stdout, also usable verbatim as scout receipts.
// Exit 0: all substantive-ok; 1: at least one failed; 2: invocation/setup error.
// This is opt-in, not a session-start network dependency. No installs or repairs.
// One tool invocation per fixed target, at most 20 seconds each, no retries.
// A tool may use multiple protocol requests (notably YouTube extraction).
// Browser is deliberately unavailable: the supported axi client owns a shared
// bridge.pid; no safe isolated browser adapter is implemented here.
//
// Record contract (exactly these ten fields):
// source: fixed public URL; access_tier: public-read;
// candidate_paths: tool names listed by TARGETS; active_path: attempted tool or
// null when unavailable; last_checked_at: UTC ISO-8601 completion time;
// result: substantive-ok | failed; evidence_shape: TARGETS' required shape;
// failure_class: null | unavailable | timeout | rate-limit |
// authentication-required | malformed-output | empty-output;
// external_content_trust: untrusted-data; repair_hint: null on success, otherwise
// static advice only. A successful record is written only after shape validation;
// failures still get receipts, with the required (not observed) evidence_shape.
// Shapes: webget title-and-body requires the target's standalone title line AND
// body marker in the stripped text (a title only in HTML head does not count);
// gh-axi toon-object requires typed top-level name/full_name/private/description;
// browser snapshot-title-and-body requires root title and joined body text;
// yt-dlp json-metadata requires id/title/duration/webpage_url/channel.
// No bodies are stored. Fetched bytes never supply commands, paths, or advice.
// HTTP status is captured from transport headers, never inferred from page prose.
// Node handles subprocess isolation and the JSON/TOON receipt protocol; no npm
// dependency is installed. The TOON predicate accepts the conservative mapping,
// scalar and empty-array subset returned by this fixed repository endpoint.

import { spawn, spawnSync } from 'node:child_process';
import { accessSync, constants, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const TARGETS = Object.freeze([
  { source: 'https://example.com', tool: 'webget', shape: 'title-and-body', title: 'Example Domain', body: 'This domain is for use in documentation examples' },
  { source: 'https://en.wikipedia.org/wiki/Prompt_injection', tool: 'webget', shape: 'title-and-body', title: 'Prompt injection', body: 'Prompt injection is' },
  { source: 'https://simonwillison.net/2022/Sep/12/prompt-injection/', tool: 'webget', shape: 'title-and-body', title: 'Prompt injection attacks against GPT-3', body: 'Ignore the above instructions' },
  { source: 'https://api.github.com/repos/octocat/Hello-World', tool: 'gh-axi api GET', shape: 'toon-object' },
  { source: 'https://example.com', tool: 'isolated browser snapshot', shape: 'snapshot-title-and-body' },
  { source: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', tool: 'yt-dlp', shape: 'json-metadata' },
]);

const HINTS = Object.freeze({
  unavailable: 'Required local tool or safe transport unavailable; review local capability separately. No installation attempted.',
  timeout: 'The single 20-second attempt expired; check connectivity before a later explicit check.',
  'rate-limit': 'HTTP 429; wait for the source limit to clear before a later explicit check.',
  'authentication-required': 'HTTP 401; keep this public-only check unauthenticated and review endpoint access separately.',
  'malformed-output': 'The response did not match the required evidence shape; review the tool output contract.',
  'empty-output': 'The tool returned no substantive body; review source availability.',
});
const BROWSER_HINT = 'Shared chrome-devtools-axi bridge refused. A reviewed headless scratch-profile adapter that never writes ~/.chrome-devtools-axi/bridge.pid is required.';
const TIMEOUT_MS = 20_000;
const MAX_BYTES = 2 * 1024 * 1024;

function scalar(value) {
  if (value.startsWith('"')) return JSON.parse(value);
  if (value === '[]') return [];
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (value === 'null') return null;
  if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(value)) return Number(value);
  if (!value || /[:{},\[\]"\\\t]/.test(value) || value.trim() !== value) throw Error('Unsupported TOON scalar');
  return value;
}

// Conservative TOON subset, not a permissive regex search for four key names.
// Reject malformed/duplicate/nested lookalike fields and unsupported structures.
function repositoryToon(text) {
  const root = Object.create(null);
  const stack = [root];
  let previousDepth = 0;
  let child = null;
  for (const line of text.trimEnd().split(/\r?\n/)) {
    const match = /^( *)([A-Za-z_][A-Za-z_0-9]*)(\[0\])?:(?: (.*))?$/.exec(line);
    if (!match || match[1].length % 2) throw Error('Malformed TOON mapping');
    const depth = match[1].length / 2;
    if (depth > previousDepth) {
      if (depth !== previousDepth + 1 || !child) throw Error('Malformed indentation');
      stack.push(child);
    } else stack.length = depth + 1;
    if (!stack[depth] || Object.hasOwn(stack[depth], match[2])) throw Error('Duplicate or misplaced field');
    child = null;
    let value;
    if (match[3]) {
      if (match[4]) throw Error('Nonempty zero-length array');
      value = [];
    } else if (match[4] === undefined || match[4] === '') {
      value = Object.create(null);
      child = value;
    } else value = scalar(match[4]);
    stack[depth][match[2]] = value;
    previousDepth = depth;
  }
  return root;
}

export function shapeMatches(target, text) {
  try {
    if (target.shape === 'title-and-body') {
      const lines = text.split(/\r?\n/).map(line => line.trim());
      return lines.includes(target.title) && lines.some(line => line !== target.title && line.includes(target.body));
    }
    if (target.shape === 'toon-object') {
      const value = repositoryToon(text);
      return value.name === 'Hello-World' && value.full_name === 'octocat/Hello-World'
        && value.private === false && typeof value.description === 'string' && value.description.trim().length > 0;
    }
    if (target.shape === 'json-metadata') {
      const value = JSON.parse(text);
      return value?.id === 'jNQXAC9IVRw' && typeof value.title === 'string' && value.title.trim().length > 0
        && typeof value.duration === 'number' && Number.isFinite(value.duration) && value.duration > 0
        && value.webpage_url === target.source && typeof value.channel === 'string' && value.channel.trim().length > 0;
    }
    // No browser output can pass without an implemented isolated transport.
    return false;
  } catch { return false; }
}

export function classify(target, observation) {
  let failure = null;
  if (observation.timedOut) failure = 'timeout';
  else if (observation.unavailable) failure = 'unavailable';
  else if (observation.httpStatus === 429) failure = 'rate-limit';
  else if (observation.httpStatus === 401) failure = 'authentication-required';
  else if (!observation.stdout?.trim()) failure = 'empty-output';
  else if (observation.exitCode !== 0 || observation.overflow
    || (observation.httpStatus >= 400) || !shapeMatches(target, observation.stdout)) failure = 'malformed-output';
  return {
    source: target.source,
    access_tier: 'public-read',
    candidate_paths: [target.tool],
    active_path: observation.unavailable ? null : target.tool,
    last_checked_at: new Date().toISOString(),
    result: failure ? 'failed' : 'substantive-ok',
    evidence_shape: target.shape,
    failure_class: failure,
    external_content_trust: 'untrusted-data',
    repair_hint: failure ? (target.shape === 'snapshot-title-and-body' ? BROWSER_HINT : HINTS[failure]) : null,
  };
}

function executable(name) {
  for (const directory of (process.env.PATH || '').split(delimiter)) {
    const path = resolve(directory, name);
    try { accessSync(path, constants.X_OK); return path; } catch { /* next PATH entry */ }
  }
  return null;
}

async function run(command, args, env) {
  return new Promise(resolveResult => {
    const child = spawn(command, args, { env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const result = { stdout: '', stderr: '', exitCode: null };
    const kill = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already exited */ } };
    const timer = setTimeout(() => { result.timedOut = true; kill(); }, TIMEOUT_MS);
    let bytes = 0;
    for (const stream of ['stdout', 'stderr']) {
      child[stream].setEncoding('utf8');
      child[stream].on('data', data => {
        bytes += Buffer.byteLength(data);
        if (bytes > MAX_BYTES) { result.overflow = true; kill(); }
        else result[stream] += data;
      });
    }
    child.on('error', () => { result.unavailable = true; });
    child.on('close', code => { clearTimeout(timer); kill(); result.exitCode = code; resolveResult(result); });
  });
}

// Local shim used ONLY inside gh-axi: retain the actual HTTP status before axi
// converts errors into prose, while passing the unmodified JSON body to axi.
// argv originates in the fixed gh-axi call, never in fetched content.
function ghTransport() {
  const response = spawnSync(process.env.FM_SOURCE_GH, [...process.argv.slice(3), '--include'], {
    encoding: 'utf8', maxBuffer: MAX_BYTES, timeout: TIMEOUT_MS,
  });
  let body = response.stdout || '';
  let status = null;
  while (/^HTTP\/\S+ \d{3}[^\r\n]*\r?\n/.test(body)) {
    const end = /\r?\n\r?\n/.exec(body);
    if (!end) break;
    status = Number(/^HTTP\/\S+ (\d{3})/.exec(body)[1]);
    body = body.slice(end.index + end[0].length);
  }
  writeFileSync(process.env.FM_SOURCE_STATUS, JSON.stringify(status));
  process.stdout.write(body);
  process.stderr.write(response.stderr || '');
  process.exitCode = response.status ?? 1;
}

async function probe(target) {
  if (target.shape === 'snapshot-title-and-body') return classify(target, { unavailable: true });
  const tool = executable(target.tool.split(' ')[0]);
  const transport = target.tool === 'webget' ? executable('curl') : target.shape === 'toon-object' ? executable('gh') : null;
  if (!tool || (target.tool !== 'yt-dlp' && !transport)) return classify(target, { unavailable: true });
  const scratch = mkdtempSync(join(tmpdir(), 'fm-source-health-'));
  try {
    const statusFile = join(scratch, 'status');
    const env = { ...process.env, PATH: `${scratch}${delimiter}${process.env.PATH}`, TMPDIR: scratch,
      GH_HOST: 'github.com', GH_PROMPT_DISABLED: '1', GH_NO_UPDATE_NOTIFIER: '1' };
    // gh-axi turns GH_REPO into --repo, which gh api does not accept.
    // The API endpoint already supplies the fixed repository identity.
    delete env.GH_REPO;
    let args;
    if (target.tool === 'webget') {
      // --disable MUST be first: ignore ambient curl cookies, retries and config.
      writeFileSync(join(scratch, 'curl'), '#!/bin/sh\nexec "$FM_SOURCE_CURL" --disable "$@" --retry 0 --max-time 20 --dump-header "$FM_SOURCE_STATUS"\n', { mode: 0o700 });
      env.FM_SOURCE_CURL = transport;
      args = [target.source, 'en'];
    } else if (target.shape === 'toon-object') {
      writeFileSync(join(scratch, 'gh'), '#!/bin/sh\nexec "$FM_SOURCE_NODE" "$FM_SOURCE_CHECKER" --gh-transport "$@"\n', { mode: 0o700 });
      env.FM_SOURCE_NODE = process.execPath;
      env.FM_SOURCE_CHECKER = fileURLToPath(import.meta.url);
      env.FM_SOURCE_GH = transport;
      // Explicit empty Authorization makes this public GET anonymous even when
      // the local gh installation has a signed-in account.
      args = ['api', 'GET', '/repos/octocat/Hello-World', '--header', 'Authorization:'];
    } else {
      args = ['--ignore-config', '--no-cache-dir', '--skip-download', '--no-playlist', '--dump-single-json',
        '--retries', '0', '--extractor-retries', '0', '--fragment-retries', '0', '--socket-timeout', '20',
        '--extractor-args', 'youtube:player_client=tv,web_safari,android', target.source];
    }
    env.FM_SOURCE_STATUS = statusFile;
    const observation = await run(tool, args, env);
    try {
      const statusText = readFileSync(statusFile, 'utf8');
      observation.httpStatus = target.tool === 'webget'
        ? Number([...statusText.matchAll(/^HTTP\/\S+ (\d{3})\b/gm)].at(-1)?.[1])
        : JSON.parse(statusText);
    } catch { /* Transport did not reach response headers. */ }
    if (target.tool === 'yt-dlp') {
      // Only yt-dlp's transport diagnostic, not stdout/page text or vague prose.
      const status = /\bHTTP Error (\d{3}):/.exec(observation.stderr);
      if (status) observation.httpStatus = Number(status[1]);
    }
    return classify(target, observation);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

async function main() {
  if (process.argv[2] === '--gh-transport' && process.env.FM_SOURCE_GH && process.env.FM_SOURCE_STATUS) return ghTransport();
  if (process.argv.length === 3 && process.argv[2] === '--help') {
    console.log('Usage: node bin/fm-source-health.mjs\nExplicit public-read diagnostics: six JSONL receipts, 20s per target, no retries.\nExit 0: all substantive-ok; 1: failures recorded; 2: setup/usage error.\nThe header owns the ten-field contract. Browser is unavailable; shared bridge refused.');
    return;
  }
  if (process.argv.length !== 2) throw Error('Usage: node bin/fm-source-health.mjs [--help]');
  for (const target of TARGETS) {
    const record = await probe(target);
    console.log(JSON.stringify(record));
    if (record.result === 'failed') process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(() => { console.error('source-health: local setup failed; receipts may be incomplete'); process.exitCode = 2; });
}
