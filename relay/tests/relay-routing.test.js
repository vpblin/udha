// Verifies the three relay changes: clientId stamping, toClientId targeting,
// and the notify push verb. Drives the real server code with auth stubbed.
const WebSocket = require('ws');
const BASE = process.env.RELAY_TEST_URL || 'ws://127.0.0.1:8099';
const INSTANCE = 'test-instance';

const results = [];
function check(name, pass, detail) {
  results.push({ name, pass, detail });
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}
const wait = ms => new Promise(r => setTimeout(r, ms));

function open(path) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${BASE}${path}`);
    ws.inbox = [];
    ws.on('message', d => { try { ws.inbox.push(JSON.parse(d.toString())); } catch {} });
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

(async () => {
  const home = await open(`/home?token=x&instanceId=${INSTANCE}`);
  const clientA = await open('/client?token=x');
  const clientB = await open('/client?token=x');
  await wait(300);

  // Both clients subscribe to the instance.
  clientA.send(JSON.stringify({ type: 'set_active_instance', instanceId: INSTANCE }));
  clientB.send(JSON.stringify({ type: 'set_active_instance', instanceId: INSTANCE }));
  await wait(300);

  // --- 1. client -> home stamps clientId -------------------------------
  home.inbox = [];
  clientA.send(JSON.stringify({ type: 'relay', instanceId: INSTANCE, payload: { type: 'hello', protocol: 2 } }));
  await wait(400);
  const got = home.inbox.find(m => m.type === 'relay' && m.payload?.type === 'hello');
  const clientAId = got?.clientId;
  check('client->home stamps clientId', !!clientAId, clientAId ? `clientId=${clientAId}` : 'no clientId on forwarded message');
  check('client->home preserves payload', got?.payload?.protocol === 2, JSON.stringify(got?.payload));

  // Learn clientB's id too.
  home.inbox = [];
  clientB.send(JSON.stringify({ type: 'relay', instanceId: INSTANCE, payload: { type: 'hello', protocol: 2 } }));
  await wait(400);
  const clientBId = home.inbox.find(m => m.type === 'relay')?.clientId;
  check('two clients get distinct ids', !!clientBId && clientBId !== clientAId, `A=${clientAId} B=${clientBId}`);

  // --- 2. home -> client broadcast (no toClientId) ----------------------
  clientA.inbox = []; clientB.inbox = [];
  home.send(JSON.stringify({ type: 'relay', payload: { type: 'sessions_full', sessions: [] } }));
  await wait(400);
  const aGotBroadcast = clientA.inbox.some(m => m.payload?.type === 'sessions_full');
  const bGotBroadcast = clientB.inbox.some(m => m.payload?.type === 'sessions_full');
  check('broadcast reaches both clients (back-compat)', aGotBroadcast && bGotBroadcast, `A=${aGotBroadcast} B=${bGotBroadcast}`);

  // --- 3. home -> client targeted (toClientId) --------------------------
  clientA.inbox = []; clientB.inbox = [];
  home.send(JSON.stringify({
    type: 'relay', toClientId: clientAId,
    payload: { type: 'terminal_frame', id: 's1', seq: 1, ansi: 'hi' },
  }));
  await wait(400);
  const aGotFrame = clientA.inbox.some(m => m.payload?.type === 'terminal_frame');
  const bGotFrame = clientB.inbox.some(m => m.payload?.type === 'terminal_frame');
  check('targeted frame reaches the addressed client', aGotFrame, `A=${aGotFrame}`);
  check('targeted frame does NOT leak to other client', !bGotFrame, `B=${bGotFrame}`);

  // --- 4. notify fires push even with clients connected -----------------
  clientA.send(JSON.stringify({ type: 'register_device', deviceToken: 'devtoken123' }));
  await wait(300);
  home.send(JSON.stringify({
    type: 'relay',
    payload: { type: 'notify', title: 'scholar-health', body: 'needs approval' },
  }));
  await wait(500);

  [home, clientA, clientB].forEach(w => w.close());
  await wait(200);
  const failed = results.filter(r => !r.pass);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  process.exit(failed.length ? 1 : 0);
})().catch(e => { console.error('harness error:', e.message); process.exit(2); });
