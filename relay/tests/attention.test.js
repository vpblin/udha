// Exercises the real relay handlers and APNs serialization with network/auth stubbed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const pushes = [];
class Socket extends EventEmitter {
  static OPEN = 1;
  constructor() { super(); this.readyState = 1; this.messages = []; }
  send(value) { this.messages.push(JSON.parse(value)); }
  close() { this.readyState = 3; this.emit('close'); }
}
Socket.Server = class extends EventEmitter { constructor() { super(); this.clients = new Set(); } };
const sandbox = {
  require(name) {
    if (name === 'ws') return Socket;
    if (name === 'fs') return { existsSync: () => false, writeFileSync() {}, mkdirSync() {} };
    if (name === 'http') return { createServer: () => ({ on() {}, listen() {} }) };
    if (name === 'http2') return { connect: () => ({ on() {}, close() {}, request(headers) {
      let body;
      const request = new EventEmitter();
      request.write = data => { body = JSON.parse(data); };
      request.end = () => { pushes.push({ headers, body }); request.emit('response', { ':status': 200 }); request.emit('end'); };
      return request;
    } }) };
    if (name === 'jsonwebtoken') return {};
    if (name === 'jwks-rsa') return () => ({});
    return require(name);
  },
  __dirname: path.resolve(__dirname, '..'),
  console: { log() {}, error() {} },
  // insecure-dev keeps the config gate quiet: this test never exercises auth.
  process: { env: { AUTH_MODE: 'insecure-dev' }, on() {}, uptime: () => 0, exit() {} },
  Buffer, URL,
  setInterval() {}, clearInterval() {}, setTimeout, clearTimeout,
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../server.js'), 'utf8') + `
  apnsKey = 'test'; generateApnsToken = () => 'test';
  globalThis.api = { handleHomeConnection, handleClientConnection, clientSubscriptions, sendPushToUser };
`, sandbox);
const { api } = sandbox;
const send = (ws, value) => ws.emit('message', Buffer.from(JSON.stringify(value)));
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  const home = new Socket(), phone = new Socket();
  api.handleHomeConnection(home, 'user', 'test@example.com', '127.0.0.1', 'mac');
  api.handleClientConnection(phone, 'user', 'test@example.com', '127.0.0.1');
  api.clientSubscriptions.get(phone._clientId).add('mac');
  send(phone, { type: 'register_device', deviceToken: 'phone-token' });
  const notify = eventId => send(home, { type: 'relay', payload: {
    type: 'notify', sessionId: 'session-1', eventId, title: 'Decision needed', body: 'Keep an archive?'
  } });
  notify('event-1'); await tick();
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].body.sessionId, 'session-1');
  assert.equal(pushes[0].body.eventId, 'event-1');
  assert.equal(pushes[0].body.instanceId, 'mac');
  assert.equal(pushes[0].body.aps['thread-id'], 'session-1');
  assert.equal(pushes[0].headers['apns-collapse-id'], 'event-1');
  assert.ok(Number(pushes[0].headers['apns-expiration']) <= Date.now() / 1000 + 301);
  send(phone, { type: 'attention_presence', sessionId: 'session-1', instanceId: 'mac' });
  notify('event-2'); await tick();
  assert.equal(pushes.length, 1, 'viewing this session suppresses push');
  send(phone, { type: 'attention_presence', sessionId: 'different', instanceId: 'mac' });
  notify('event-3'); await tick();
  assert.equal(pushes.length, 2, 'viewing another session does not suppress');
  send(phone, { type: 'attention_presence', sessionId: 'session-1', instanceId: 'mac' });
  phone._attentionPresence.at -= 46000;
  notify('event-4'); await tick();
  assert.equal(pushes.length, 3, 'stale presence cannot suppress');
  send(phone, { type: 'attention_presence', sessionId: 'session-1', instanceId: 'mac' });
  send(phone, { type: 'attention_presence' });
  notify('event-5'); await tick();
  assert.equal(pushes.length, 4, 'backgrounding clears presence');
  send(phone, { type: 'attention_presence', sessionId: 'session-1', instanceId: 'not-paired' });
  assert.equal(phone._attentionPresence, null, 'presence must name a subscribed host');
  await api.sendPushToUser('user', 'Legacy output', 'An older host without metadata');
  assert.equal(pushes.length, 5, 'legacy pushes still work without presence metadata');
  assert.equal(pushes[4].body.sessionId, undefined);
  console.log('PASS relay attention: payload routing, expiry, collapse IDs, foreground/background presence');
})().catch(error => { console.error(error); process.exitCode = 1; });
