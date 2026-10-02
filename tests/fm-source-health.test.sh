#!/usr/bin/env bash
# Four offline classifier regressions; saved tool output only, no network.
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

node --input-type=module - "$ROOT" <<'JS'
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const { classify, probe, transportStatuses, TARGETS } = await import(pathToFileURL(`${root}/bin/fm-source-health.mjs`));
const fixtures = JSON.parse(readFileSync(`${root}/tests/fixtures/source-health/classifier.json`, 'utf8'));
const fields = ['source', 'access_tier', 'candidate_paths', 'active_path', 'last_checked_at',
  'result', 'evidence_shape', 'failure_class', 'external_content_trust', 'repair_hint'].sort();

async function githubFixture(fixture) {
  const sandbox = mkdtempSync(join(tmpdir(), 'fm-source-health-test-'));
  const ambient = { ...process.env };
  const forbidden = ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN',
    'GH_REPO', 'GH_HOST', 'GH_DEBUG', 'NODE_OPTIONS', 'HTTPS_PROXY', 'CURL_HOME'];
  const body = JSON.stringify({ name: 'Hello-World', full_name: 'octocat/Hello-World', private: false, description: 'Example' });
  try {
    writeFileSync(join(sandbox, 'fixture.json'), JSON.stringify({ ...fixture, body }));
    writeFileSync(join(sandbox, 'hosts.yml'), 'github.com:\n  oauth_token: fixture-only\n');
    const prelude = `#!${process.execPath}
const assert = require('node:assert/strict');
const { readFileSync, writeFileSync, appendFileSync, realpathSync } = require('node:fs');
const { join } = require('node:path');
const fixture = JSON.parse(readFileSync(join(__dirname, 'fixture.json'), 'utf8'));
assert(${JSON.stringify(forbidden)}.every(key => !Object.hasOwn(process.env, key)), 'ambient environment inherited');
assert(process.env.HOME !== __dirname, 'ambient home inherited');
assert.equal(process.env.GH_CONFIG_DIR, process.env.HOME);
assert.equal(process.env.XDG_CONFIG_HOME, process.env.HOME);
assert.equal(process.env.GIT_DIR, process.env.HOME);
assert.equal(process.cwd(), realpathSync(process.env.HOME));
assert.equal(process.env.GIT_CONFIG_NOSYSTEM, '1');
assert.equal(process.env.GIT_CONFIG_GLOBAL, '/dev/null');
`;
    writeFileSync(join(sandbox, 'gh-axi'), `${prelude}
assert.deepEqual(process.argv.slice(2), ['api', 'GET', '/repos/octocat/Hello-World', '--header', 'Authorization:']);
appendFileSync(join(__dirname, 'axi.calls'), 'call\\n');
const response = require('node:child_process').spawnSync('gh',
  ['api', process.argv[4], '--method', process.argv[3], ...process.argv.slice(5)], { encoding: 'utf8' });
assert.equal(response.status, fixture.exitCode);
if (response.status !== 0) process.exit(response.status);
assert.equal(response.stdout, fixture.body);
process.stdout.write(fixture.stdout);
`, { mode: 0o700 });
    writeFileSync(join(sandbox, 'curl'), `${prelude}
const args = process.argv.slice(2);
assert.equal(args[0], '--disable');
assert.equal(args.at(-1), 'https://api.github.com/repos/octocat/Hello-World');
assert.equal(args[args.indexOf('--retry') + 1], '0');
assert.equal(args[args.indexOf('--max-time') + 1], '20');
assert.equal(args[args.indexOf('--proto') + 1], '=https');
const headers = args.flatMap((arg, index) => arg === '--header' ? [args[index + 1]] : []);
assert.deepEqual(headers.filter(header => /^Authorization:/i.test(header)), ['Authorization:']);
assert(!args.some(arg => /^(--(user|netrc.*|cookie.*|config|cert.*|key|proxy.*)|-[ubcKUE])$/.test(arg)));
appendFileSync(join(__dirname, 'curl.calls'), 'call\\n');
writeFileSync(args[args.indexOf('--dump-header') + 1], fixture.headers || 'HTTP/2 200\\r\\n\\r\\n');
if (fixture.exitCode === 0) process.stdout.write(fixture.body);
process.exitCode = fixture.exitCode;
`, { mode: 0o700 });
    writeFileSync(join(sandbox, 'gh'), '#!/bin/sh\nexit 99\n', { mode: 0o700 });
    for (const key of forbidden) process.env[key] = 'fixture-only';
    Object.assign(process.env, { PATH: sandbox, HOME: sandbox, GH_CONFIG_DIR: sandbox, XDG_CONFIG_HOME: sandbox });
    const receipt = await probe(TARGETS[fixture.target]);
    assert.equal(readFileSync(join(sandbox, 'axi.calls'), 'utf8'), 'call\n');
    assert.equal(readFileSync(join(sandbox, 'curl.calls'), 'utf8'), 'call\n');
    assert.equal(receipt.access_tier, 'public-read');
    assert.equal(receipt.active_path, 'gh-axi api GET');
    return receipt;
  } finally {
    for (const key of Object.keys(process.env)) if (!Object.hasOwn(ambient, key)) delete process.env[key];
    Object.assign(process.env, ambient);
    rmSync(sandbox, { recursive: true, force: true });
  }
}

for (const [name, cases] of Object.entries(fixtures)) {
  for (const fixture of cases) {
    const target = TARGETS[fixture.target];
    const receipt = fixture.githubTransport ? await githubFixture(fixture) : classify(target, {
      ...fixture, httpStatuses: transportStatuses(target, fixture.headers, fixture.stderr),
    });
    assert.equal(receipt.failure_class, fixture.expected, `${name}: ${fixture.stdout}`);
    assert.equal(receipt.result, fixture.expected ? 'failed' : 'substantive-ok');
    assert.equal(receipt.external_content_trust, 'untrusted-data');
    assert.deepEqual(Object.keys(receipt).sort(), fields);
    assert.equal(receipt.repair_hint === null, fixture.expected === null);
  }
  console.log(`ok - ${name}`);
}
JS
