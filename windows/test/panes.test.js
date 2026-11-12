'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { classifyCodexPane, classifyGeneric, stable } = require('../src/main/panes');

const L = (s) => s.split('\n');

test('codex: approval dialog', () => {
  const r = classifyCodexPane(L(`• I'll run the tests.
Would you like to run the following command?
  npm test
› 1. Yes, proceed
  2. No, and tell Codex what to do differently
Press enter to confirm or esc to cancel`));
  assert.equal(r.state, 'needsInput');
  assert.match(r.prompt, /Would you like to run/);
});

test('codex: working with a tool line', () => {
  const r = classifyCodexPane(L(`• Running npm test
• Working (12s • esc to interrupt)
› `));
  assert.equal(r.state, 'working');
  assert.equal(r.activity, 'Running npm test');
});

test('codex: finished on a question', () => {
  const r = classifyCodexPane(L(`• Worked for 1m 02s
• Fixed the bug. Want me to open a PR?
› Ask Codex to do anything`));
  assert.equal(r.state, 'idle');
  assert.equal(r.question, 'Fixed the bug. Want me to open a PR?');
});

test('codex: queued question', () => {
  const r = classifyCodexPane(L(`? 1 question
shift + ↵ to answer
› `));
  assert.equal(r.state, 'needsInput');
});

test('generic: y/n prompt, working footer, error, idle shell', () => {
  assert.equal(classifyGeneric(L('Overwrite file? [y/N]')).state, 'needsInput');
  assert.equal(classifyGeneric(L('Generating...\n(esc to cancel, 4s)')).state, 'working');
  assert.equal(classifyGeneric(L('Traceback (most recent call last):\n  File "x"\nPS C:\\>')).state, 'error');
  assert.equal(classifyGeneric(L('PS C:\\code> \n\n\n')).state, 'idle');
});

test('stability: a state lands only on the second sighting', () => {
  const t = { pending: null, count: 0 };
  assert.equal(stable(t, { state: 'working' }), null);
  assert.equal(stable(t, { state: 'working' }).state, 'working');
  assert.equal(stable(t, { state: 'idle' }), null);
});
