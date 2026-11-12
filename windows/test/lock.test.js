'use strict';
const test = require('node:test');
const assert = require('node:assert');
const Module = require('module');

// lock.js requires electron at load; give it an inert stand-in for the pure helpers.
const realLoad = Module._load;
Module._load = function (req, ...rest) { return req === 'electron' ? { ipcMain: { handle() {} } } : realLoad.call(this, req, ...rest); };
const { hashPin, checkPin } = require('../src/main/lock');
Module._load = realLoad;

test('PIN is stored salted and checks in constant time', () => {
  const rec = hashPin('2468');
  assert.notEqual(rec.hash, '2468');
  assert.ok(checkPin('2468', rec));
  assert.ok(!checkPin('2469', rec));
  assert.ok(!checkPin('2468', null));
  assert.notEqual(hashPin('2468').hash, rec.hash, 'salt differs each time');
});
