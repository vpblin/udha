#!/usr/bin/env node
//
// tests/run.js — the whole suite, `npm test`.
//
//   1. attention.test.js  — the relay's handlers and APNs payload serialization,
//      driven in a vm sandbox with ws/fs/http/http2 stubbed. No server, no network.
//   2. relay-routing.test.js and relay-coldstart.test.js — the real server.js,
//      spawned on a spare port with AUTH_MODE=insecure-dev, driven over real
//      WebSockets.
//
// The second group used to require regex-patching a copy of server.js to stub
// validateToken. AUTH_MODE=insecure-dev replaces that: the source under test is
// byte-for-byte the source you deploy.

const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

function waitForHealth(port, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const req = require("node:http").get(
        { host: "127.0.0.1", port, path: "/health", timeout: 1000 },
        (res) => {
          res.resume();
          if (res.statusCode === 200) resolve();
          else retry(new Error(`health returned ${res.statusCode}`));
        }
      );
      req.on("error", retry);
      req.on("timeout", () => req.destroy(new Error("health timeout")));
    };
    const retry = (err) => {
      if (Date.now() > deadline) reject(err);
      else setTimeout(attempt, 200);
    };
    attempt();
  });
}

function runNode(file, env) {
  const result = spawnSync(process.execPath, [file], {
    cwd: ROOT,
    stdio: "inherit",
    env: { ...process.env, ...env }
  });
  return result.status === 0;
}

(async () => {
  let failures = 0;

  console.log("\n--- attention.test.js (sandboxed handlers) ---");
  if (!runNode(path.join(__dirname, "attention.test.js"), {})) failures++;

  const port = await freePort();
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "udha-relay-test-"));

  console.log(`\n--- starting server.js on 127.0.0.1:${port} (AUTH_MODE=insecure-dev) ---`);
  const server = spawn(process.execPath, [path.join(ROOT, "server.js")], {
    cwd: ROOT,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      AUTH_MODE: "insecure-dev",
      PORT: String(port),
      BIND_ADDRESS: "127.0.0.1",
      DATA_DIR: dataDir,
      // No APNS_* vars: push stays disabled, which is what these tests want.
      APNS_KEY_ID: "",
      APNS_TEAM_ID: "",
      APNS_BUNDLE_ID: "",
      APNS_KEY_PATH: "",
      APNS_KEY: ""
    }
  });

  const serverLog = [];
  server.stdout.on("data", (d) => serverLog.push(d.toString()));
  server.stderr.on("data", (d) => serverLog.push(d.toString()));

  const stop = () => {
    if (!server.killed) server.kill("SIGTERM");
    try { fs.rmSync(dataDir, { recursive: true, force: true }); } catch {}
  };
  process.on("exit", stop);

  try {
    await waitForHealth(port);
  } catch (e) {
    console.error(`server never became healthy: ${e.message}`);
    console.error(serverLog.join(""));
    stop();
    process.exit(1);
  }

  const env = { RELAY_TEST_URL: `ws://127.0.0.1:${port}` };

  console.log("\n--- relay-routing.test.js (clientId stamping, toClientId, notify) ---");
  if (!runNode(path.join(__dirname, "relay-routing.test.js"), env)) failures++;

  console.log("\n--- relay-coldstart.test.js (pairing a host a client has never seen) ---");
  if (!runNode(path.join(__dirname, "relay-coldstart.test.js"), env)) failures++;

  stop();
  await new Promise((r) => setTimeout(r, 300));

  console.log(failures ? `\n${failures} test file(s) FAILED\n` : "\nAll relay tests passed\n");
  process.exit(failures ? 1 : 0);
})().catch((e) => {
  console.error(e);
  process.exit(2);
});
