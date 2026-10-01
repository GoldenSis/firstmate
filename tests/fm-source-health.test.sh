#!/usr/bin/env bash
# Four offline classifier regressions; saved tool output only, no network/tools.
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

node --input-type=module - "$ROOT" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const { classify, TARGETS } = await import(pathToFileURL(`${root}/bin/fm-source-health.mjs`));
const fixtures = JSON.parse(readFileSync(`${root}/tests/fixtures/source-health/classifier.json`, 'utf8'));
const fields = ['source', 'access_tier', 'candidate_paths', 'active_path', 'last_checked_at',
  'result', 'evidence_shape', 'failure_class', 'external_content_trust', 'repair_hint'].sort();
for (const [name, cases] of Object.entries(fixtures)) {
  for (const fixture of cases) {
    const receipt = classify(TARGETS[fixture.target], fixture);
    assert.equal(receipt.failure_class, fixture.expected, `${name}: ${fixture.stdout}`);
    assert.equal(receipt.result, fixture.expected ? 'failed' : 'substantive-ok');
    assert.equal(receipt.external_content_trust, 'untrusted-data');
    assert.deepEqual(Object.keys(receipt).sort(), fields);
    assert.equal(receipt.repair_hint === null, fixture.expected === null);
  }
  console.log(`ok - ${name}`);
}
JS
