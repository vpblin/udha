'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { Notifier } = require('../src/main/notify');

function setup({ focused }) {
  const cfg = { id: 'a', label: 'proj', notifyWhenDone: false };
  const store = { config: { sessions: [cfg] }, session: () => cfg, mutate: (fn) => fn(store.config) };
  const win = { isDestroyed: () => false, isFocused: () => focused, isMinimized: () => false, flashFrame() { this.flashed = true; } };
  const n = new Notifier({ store, getWindow: () => win, onClick() {} });
  const toasts = [];
  n.toast = (id, title, body) => toasts.push({ id, title, body });
  const snap = (phase, extra = {}) => ({ id: 'a', label: 'proj', state: 'running', phase, phaseDetail: null, ...extra });
  return { n, cfg, win, toasts, snap };
}

test('approval in the background toasts and flashes the taskbar', () => {
  const { n, win, toasts, snap } = setup({ focused: false });
  n.observe(snap('thinking'));
  n.observe(snap('awaitingApproval', { phaseDetail: 'Do you want to proceed?' }));
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].title, 'proj needs you');
  assert.ok(win.flashed);
  n.observe(snap('awaitingApproval', { phaseDetail: 'Do you want to proceed?' }));
  assert.equal(toasts.length, 1, 'same prompt does not toast twice');
});

test('finished turn: silent when focused, unless "notify when done" was asked (one-shot)', () => {
  const { n, cfg, toasts, snap } = setup({ focused: true });
  n.observe(snap('thinking'));
  n.observe(snap('awaitingReply'));
  assert.equal(toasts.length, 0);
  cfg.notifyWhenDone = true;
  n.observe(snap('usingTool'));
  n.observe(snap('awaitingReply', { lastQuestion: 'All done.' }));
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].body, 'All done.');
  assert.equal(cfg.notifyWhenDone, false);
});

test('finished turn in the background toasts', () => {
  const { n, toasts, snap } = setup({ focused: false });
  n.observe(snap('thinking'));
  n.observe(snap('awaitingReply'));
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].title, 'proj is ready');
});
