#!/usr/bin/env node
// End-to-end check of udha-agent against the relay's mock server: pair, hello,
// create a session, watch it come up, attach a terminal frame, close it.
//
//   RELAY=ws://localhost:8090 node e2e-mock.js
//
// Needs the mock relay and the agent already running against it (see run-e2e.sh).
const path = require("path");
const WebSocket = require("ws"); // resolved through NODE_PATH, set by run-e2e.sh
const RELAY = process.env.RELAY || "ws://localhost:8090";
const DIR = process.env.E2E_DIR || process.env.HOME;
const TIMEOUT_MS = parseInt(process.env.E2E_TIMEOUT || "90000", 10);

let instanceId = null, sessionId = null, step = "connect";
const seen = new Set();
const ws = new WebSocket(`${RELAY}/client?token=fake`);
const send = (m) => ws.send(JSON.stringify(m));
const relay = (payload) => send({ type: "relay", instanceId, payload });
const pass = (msg) => console.log(`PASS  ${msg}`);
const fail = (msg) => { console.log(`FAIL  ${msg}`); cleanup(1); };
function cleanup(code) {
  if (sessionId && code !== 0) relay({ type: "close_session", id: sessionId });
  setTimeout(() => { ws.close(); process.exit(code); }, 300);
}
const timer = setTimeout(() => fail(`timed out at step "${step}"`), TIMEOUT_MS);

ws.on("open", () => { step = "discover"; });
ws.on("message", (raw) => {
  const msg = JSON.parse(raw.toString());
  const inner = msg.type === "relay" ? msg.payload : msg;
  const t = inner.type;
  if (t === "instance_online" && !instanceId) {
    instanceId = msg.instanceId; pass(`agent online as ${instanceId}`);
    step = "pair"; send({ type: "pair_request", instanceId, pairingToken: "e2e" });
    return;
  }
  if (t === "pair_success") {
    pass("pairing accepted by agent");
    send({ type: "set_active_instance", instanceId });
    step = "hello";
    relay({ type: "hello", protocol: 2, capabilities: ["delta", "actions", "terminal", "diff", "push", "resize", "rename"] });
    return;
  }
  if (t === "hello_ack") {
    if (inner.instanceKind !== "udha-desktop") return fail(`unexpected instanceKind ${inner.instanceKind}`);
    if ((inner.capabilities || []).includes("videos")) return fail("agent must not advertise videos");
    pass(`hello_ack protocol=${inner.protocol} caps=${inner.capabilities.sort().join(",")}`);
    return;
  }
  if (t === "sessions_full" && step === "hello") {
    pass(`sessions_full with ${inner.sessions.length} sessions`);
    step = "create";
    relay({ type: "create_session", directory: DIR, label: "e2e-agent", permission: "default" });
    return;
  }
  if (t === "session_create_failed") return fail(`create_session failed: ${inner.error}`);
  if (t === "session_created") {
    sessionId = inner.id; pass(`session created ${inner.label} (${sessionId}) in ${inner.directory}`);
    step = "status"; return;
  }
  if ((t === "sessions_full" || t === "sessions_delta") && step === "status" && sessionId) {
    const rows = inner.sessions || inner.changed || [];
    const row = rows.find((r) => r.id === sessionId);
    if (!row) return;
    const key = `${row.state}/${row.phase}`;
    if (!seen.has(key)) { seen.add(key); console.log(`      state=${row.state} phase=${row.phase} status=${JSON.stringify(row.statusLine || row.status || "")}`); }
    // A real Claude session opens on the workspace-trust prompt, which reads as
    // needsInput and (correctly) holds phase at "starting" because the prompt
    // covers the footer the pane reader anchors on. Either signal proves the
    // classifier is running over the live pane.
    if (row.state !== "starting") {
      pass(`session classified live → ${key}`);
      step = "attach"; relay({ type: "attach_terminal", id: sessionId, cols: 100, rows: 30 });
    }
    return;
  }
  if (t === "terminal_frame" && step === "attach") {
    const text = (inner.lines || inner.text || []).toString();
    pass(`terminal_frame received (${text.length} chars)${/Claude|claude|❯|>/.test(text) ? ", Claude chrome visible" : ""}`);
    step = "close"; relay({ type: "detach_terminal" }); relay({ type: "close_session", id: sessionId });
    return;
  }
  if (t === "session_closed" && step === "close") {
    pass("session closed"); clearTimeout(timer); sessionId = null; cleanup(0);
  }
  if (t === "action_result" && inner.ok === false) console.log(`      action_result ${inner.action}: ${inner.error}`);
});
ws.on("error", (e) => fail(`ws error ${e.message}`));
