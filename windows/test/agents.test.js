'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { AgentStore, parse, serialize } = require('../src/main/agents');

test('frontmatter round-trips', () => {
  const a = parse('code-review', '---\nname: Code Review\ndescription: Review the diff\nicon: eye\n---\nReview this.\n\nThoroughly.');
  assert.equal(a.name, 'Code Review');
  assert.equal(a.description, 'Review the diff');
  assert.equal(a.prompt, 'Review this.\n\nThoroughly.');
  assert.deepEqual(parse('code-review', serialize(a)), { ...a });
  assert.equal(parse('my-thing', 'Just a prompt').name, 'My Thing');
});

test('store seeds built-ins, restores them on delete, creates unique slugs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'udha-agents-'));
  const store = new AgentStore(dir);
  const list = store.list();
  const builtIn = list.find((a) => a.slug === 'security-audit');
  assert.ok(builtIn && builtIn.isBuiltIn);
  store.save({ ...builtIn, prompt: 'edited' });
  assert.equal(store.get('security-audit').prompt, 'edited');
  store.remove('security-audit');
  assert.notEqual(store.get('security-audit').prompt, 'edited');
  const s1 = store.create('Fix Tests');
  const s2 = store.create('Fix Tests');
  assert.equal(s1, 'fix-tests');
  assert.equal(s2, 'fix-tests-2');
  store.remove(s1);
  assert.equal(store.get(s1), null);
});
