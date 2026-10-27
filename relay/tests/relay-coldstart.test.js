// Regression for the cold-start pairing bug: a client that connects AFTER an
// unpaired host must still be told the host exists, or it can never pair.
const WebSocket = require('ws');
const BASE = process.env.RELAY_TEST_URL || 'ws://127.0.0.1:8099';
const INSTANCE = 'macbookpro-test';
let fails = 0, n = 0;
const check = (name, ok, d='') => { n++; console.log(`${ok?'PASS':'FAIL'}  ${name}${d?'  — '+d:''}`); if(!ok) fails++; };
const wait = ms => new Promise(r => setTimeout(r, ms));
function open(path) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(BASE + path);
    ws.inbox = [];
    ws.on('message', d => { try { ws.inbox.push(JSON.parse(d.toString())); } catch {} });
    ws.on('open', () => res(ws)); ws.on('error', rej);
  });
}
(async () => {
  // Host first, client second — the exact ordering that broke.
  const home = await open(`/home?token=x&instanceId=${INSTANCE}`);
  await wait(400);
  const client = await open('/client?token=x');
  await wait(600);

  const paired = client.inbox.find(m => m.type === 'paired_instances');
  check('client receives paired_instances', !!paired);
  const found = (paired?.instances || []).find(i => i.instanceId === INSTANCE);
  check('unpaired-but-online host is advertised', !!found,
        JSON.stringify(paired?.instances || []));
  check('host is marked online', found?.isOnline === true);
  check('host is marked not yet paired', found?.paired === false);

  // And the client can now actually pair with it.
  client.send(JSON.stringify({ type: 'pair_request', instanceId: INSTANCE, pairingToken: 'x' }));
  await wait(400);
  const validate = home.inbox.find(m => m.type === 'validate_pairing');
  check('host receives validate_pairing', !!validate);
  if (validate) {
    home.send(JSON.stringify({ type: 'pairing_valid', requestId: validate.requestId, valid: true,
                               metadata: { instanceId: INSTANCE, name: 'MacBook', kind: 'udha-desktop' } }));
    await wait(500);
    check('client gets pair_success', client.inbox.some(m => m.type === 'pair_success'));
  }

  // A second client connecting later must see it as paired now.
  const client2 = await open('/client?token=x');
  await wait(500);
  const p2 = client2.inbox.find(m => m.type === 'paired_instances');
  const f2 = (p2?.instances || []).find(i => i.instanceId === INSTANCE);
  check('later client sees it as paired', f2?.paired === true && f2?.isOnline === true,
        JSON.stringify(f2 || {}));
  check('no duplicate entries', (p2?.instances || []).filter(i => i.instanceId === INSTANCE).length === 1);

  [home, client, client2].forEach(w => w.close());
  await wait(200);
  console.log(`\n${n - fails}/${n} passed`);
  process.exit(fails ? 1 : 0);
})().catch(e => { console.error('harness error:', e.message); process.exit(2); });
