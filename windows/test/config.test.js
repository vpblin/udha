'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { withPermission, newSessionConfig } = require('../src/main/config');
const status = require('../src/main/status');

test('withPermission swaps the mode and keeps other flags', () => {
  assert.deepEqual(withPermission(['--permission-mode', 'acceptEdits', '--model', 'opus'], 'plan'),
    ['--permission-mode', 'plan', '--model', 'opus']);
  assert.deepEqual(withPermission(['--dangerously-skip-permissions'], 'default'), []);
  assert.deepEqual(withPermission([], 'bypass'), ['--dangerously-skip-permissions']);
});

test('snapshot reads the permission mode from args', () => {
  const cfg = newSessionConfig({ label: 'a', directory: 'C:\\', permission: 'plan' });
  assert.equal(status.newSnapshot(cfg).permission, 'plan');
  cfg.args = ['--dangerously-skip-permissions'];
  assert.equal(status.newSnapshot(cfg).permission, 'bypass');
});
