// Udha relay — a small WebSocket relay that lets a phone or a desktop reach a
// machine that supervises AI coding sessions, without either side needing an
// inbound port.
//
//   host (Mac app / udha-agent)  ──wss──▶  relay  ◀──wss──  client (iPad / desktop)
//
// Every value below comes from the environment. Nothing here knows about any
// particular deployment: set the vars (see .env.example) or the server refuses
// to start and names what is missing.

const WebSocket = require("ws");
const http = require("http");
const http2 = require("http2");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const jwt = require("jsonwebtoken");
const jwksClient = require("jwks-rsa");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

function log(message) {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${message}`);
}

const VERSION = "2.0.0";

const fatalConfigErrors = [];

function requiredEnv(name, hint) {
  const value = (process.env[name] || "").trim();
  if (!value) {
    fatalConfigErrors.push(`${name} is not set${hint ? ` — ${hint}` : ""}`);
    return "";
  }
  return value;
}

function intEnv(name, fallback) {
  const raw = (process.env[name] || "").trim();
  if (!raw) return fallback;
  const value = parseInt(raw, 10);
  if (!Number.isFinite(value) || value <= 0) {
    fatalConfigErrors.push(`${name}="${raw}" is not a positive integer`);
    return fallback;
  }
  return value;
}

function boolEnv(name, fallback = false) {
  const raw = (process.env[name] || "").trim().toLowerCase();
  if (!raw) return fallback;
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

const PORT = intEnv("PORT", 8080);
const BIND_ADDRESS = (process.env.BIND_ADDRESS || "0.0.0.0").trim();
const PING_INTERVAL = intEnv("PING_INTERVAL_MS", 30000);
const PAIRING_TIMEOUT_MS = intEnv("PAIRING_TIMEOUT_MS", 30000);
const PRESENCE_TTL_MS = intEnv("ATTENTION_PRESENCE_TTL_MS", 45000);
const MAX_ATTEMPTS = intEnv("RATE_LIMIT_MAX_ATTEMPTS", 10);
const RATE_WINDOW_MS = intEnv("RATE_LIMIT_WINDOW_MS", 60000);

// Where paired-instance state is persisted. Mount this as a volume so pairings
// survive a container restart.
const DATA_DIR = (process.env.DATA_DIR || path.join(__dirname, "data")).trim();

// The URL clients should dial, used only for the banner printed at startup.
const PUBLIC_URL = (process.env.PUBLIC_URL || "").trim();

// --- Auth -------------------------------------------------------------------
//
// AUTH_MODE=auth0  (default) verifies every token against the tenant's JWKS.
// AUTH_MODE=insecure-dev accepts any token and derives the user id from it —
// for local testing and the integration tests only. NEVER expose that to a
// network you do not control: it grants anyone full access to every host.

const AUTH_MODE = (process.env.AUTH_MODE || "auth0").trim().toLowerCase();
if (AUTH_MODE !== "auth0" && AUTH_MODE !== "insecure-dev") {
  fatalConfigErrors.push(`AUTH_MODE="${AUTH_MODE}" is not one of: auth0, insecure-dev`);
}
const INSECURE_AUTH = AUTH_MODE === "insecure-dev";

const AUTH0_DOMAIN = INSECURE_AUTH
  ? (process.env.AUTH0_DOMAIN || "").trim()
  : requiredEnv("AUTH0_DOMAIN", "your Auth0 tenant, e.g. your-tenant.us.auth0.com");
const AUTH0_AUDIENCE = INSECURE_AUTH
  ? (process.env.AUTH0_AUDIENCE || "").trim()
  : requiredEnv("AUTH0_AUDIENCE", "the identifier of the Auth0 API you created for this relay");
// Auth0 issues `https://<domain>/` by default; override for a custom domain.
const AUTH0_ISSUER = (process.env.AUTH0_ISSUER || (AUTH0_DOMAIN ? `https://${AUTH0_DOMAIN}/` : "")).trim();
const AUTH0_JWKS_URI = (process.env.AUTH0_JWKS_URI ||
  (AUTH0_DOMAIN ? `https://${AUTH0_DOMAIN}/.well-known/jwks.json` : "")).trim();
// Auth0 only puts `email` in an access token through a custom namespaced claim
// added by an Action. Name it here if you added one; the relay only uses it for
// log lines, so leaving it unset costs nothing.
const AUTH0_EMAIL_CLAIM = (process.env.AUTH0_EMAIL_CLAIM || "").trim();

// JWKS client for Auth0 public key retrieval
const jwks = AUTH0_JWKS_URI
  ? jwksClient({
      jwksUri: AUTH0_JWKS_URI,
      cache: true,
      cacheMaxAge: 3600000, // 1 hour
      rateLimit: true,
      jwksRequestsPerMinute: intEnv("JWKS_REQUESTS_PER_MINUTE", 10)
    })
  : null;

// --- APNs (optional) --------------------------------------------------------
//
// Only the iOS app needs this: it is how a backgrounded phone hears that a
// session wants a human. Leave the vars unset and the relay runs with push
// disabled — every other feature works.

const APNS_KEY_ID = (process.env.APNS_KEY_ID || "").trim();
const APNS_TEAM_ID = (process.env.APNS_TEAM_ID || "").trim();
const APNS_BUNDLE_ID = (process.env.APNS_BUNDLE_ID || "").trim();
const APNS_KEY_PATH = (process.env.APNS_KEY_PATH || "").trim();
const APNS_KEY_INLINE = process.env.APNS_KEY || "";
const APNS_PRODUCTION = boolEnv("APNS_PRODUCTION", false);
const APNS_EXPIRATION_SECONDS = intEnv("APNS_EXPIRATION_SECONDS", 300);

// Load the APNs signing key, if push is configured at all.
let apnsKey = null;
const apnsWanted = !!(APNS_KEY_ID || APNS_TEAM_ID || APNS_BUNDLE_ID || APNS_KEY_PATH || APNS_KEY_INLINE);
let apnsPending = null; // logged after the config check, so failures read in order
if (apnsWanted) {
  const missing = [
    ["APNS_KEY_ID", APNS_KEY_ID],
    ["APNS_TEAM_ID", APNS_TEAM_ID],
    ["APNS_BUNDLE_ID", APNS_BUNDLE_ID]
  ].filter(([, v]) => !v).map(([k]) => k);
  if (!APNS_KEY_PATH && !APNS_KEY_INLINE) missing.push("APNS_KEY_PATH or APNS_KEY");
  if (missing.length) {
    apnsPending = `WARNING: push half-configured — missing ${missing.join(", ")}; push notifications disabled`;
  } else if (APNS_KEY_INLINE) {
    apnsKey = APNS_KEY_INLINE.replace(/\\n/g, "\n");
    apnsPending = "APNs key loaded from APNS_KEY";
  } else {
    try {
      if (fs.existsSync(APNS_KEY_PATH)) {
        apnsKey = fs.readFileSync(APNS_KEY_PATH, "utf8");
        apnsPending = `APNs key loaded from ${APNS_KEY_PATH}`;
      } else {
        apnsPending = `WARNING: APNs key not found at ${APNS_KEY_PATH} - push notifications disabled`;
      }
    } catch (e) {
      apnsPending = `WARNING: Failed to load APNs key: ${e.message}`;
    }
  }
} else {
  apnsPending = "Push notifications disabled (no APNS_* vars set)";
}

// Refuse to start on a broken configuration, naming every missing value at once
// rather than one per restart.
if (fatalConfigErrors.length) {
  console.error("");
  console.error("Udha relay cannot start — fix the configuration:");
  for (const problem of fatalConfigErrors) console.error(`  • ${problem}`);
  console.error("");
  console.error("Copy .env.example to .env and fill it in, or pass the variables");
  console.error("through your process manager / docker compose environment.");
  console.error("");
  process.exit(1);
}

log(apnsPending);
if (INSECURE_AUTH) {
  log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
  log("!! AUTH_MODE=insecure-dev — every token is accepted without check. !!");
  log("!! Use this on localhost only. Never expose this process publicly. !!");
  log("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
}

// Connection pools (multi-instance support)
// homeServers: userId -> Map<instanceId, { ws, metadata }>
const homeServers = new Map();
// clientConnections: userId -> Set<WebSocket>
const clientConnections = new Map();
// clientSubscriptions: clientId -> Set<instanceId>
const clientSubscriptions = new Map();
// pairedInstances: userId -> Map<instanceId, { metadata, pairedAt }>
const pairedInstances = new Map();

// Pending pairing requests: requestId -> { clientWs, instanceId, pairingToken, userId }
const pendingPairings = new Map();

// Device tokens: userId -> Set<deviceToken>
const deviceTokens = new Map();

// Persistence file for paired instances. Lives under DATA_DIR so a container
// can mount it as a volume and keep pairings across restarts.
const PAIRED_INSTANCES_FILE = path.join(DATA_DIR, "paired-instances.json");

// Load paired instances from file
function loadPairedInstances() {
  try {
    if (!fs.existsSync(DATA_DIR)) {
      fs.mkdirSync(DATA_DIR, { recursive: true });
      log(`Created data directory ${DATA_DIR}`);
    }
    if (fs.existsSync(PAIRED_INSTANCES_FILE)) {
      const data = JSON.parse(fs.readFileSync(PAIRED_INSTANCES_FILE, "utf8"));
      for (const [userId, instances] of Object.entries(data)) {
        pairedInstances.set(userId, new Map(Object.entries(instances)));
      }
      log(`Loaded paired instances for ${pairedInstances.size} users`);
    }
  } catch (e) {
    log(`Failed to load paired instances: ${e.message}`);
  }
}

// Save paired instances to file
function savePairedInstances() {
  try {
    const data = {};
    for (const [userId, instances] of pairedInstances) {
      data[userId] = Object.fromEntries(instances);
    }
    fs.writeFileSync(PAIRED_INSTANCES_FILE, JSON.stringify(data, null, 2));
  } catch (e) {
    log(`Failed to save paired instances: ${e.message}`);
  }
}

// Generate unique client ID
function generateClientId() {
  return crypto.randomBytes(8).toString("hex");
}

// Rate limiting: IP -> { attempts: number, lastAttempt: timestamp }
const rateLimits = new Map();

function securityLog(event, ip, details = "") {
  log(`[SECURITY] ${event} from ${ip}${details ? ` - ${details}` : ""}`);
}

// Get signing key from Auth0 JWKS
function getSigningKey(header, callback) {
  if (!jwks) {
    callback(new Error("JWKS is not configured (AUTH0_DOMAIN / AUTH0_JWKS_URI)"), null);
    return;
  }
  jwks.getSigningKey(header.kid, (err, key) => {
    if (err) {
      callback(err, null);
      return;
    }
    const signingKey = key.getPublicKey();
    callback(null, signingKey);
  });
}

// Validate Auth0 JWT token - returns { valid: boolean, userId?: string, email?: string, error?: string }
async function validateToken(token) {
  if (!token) {
    return { valid: false, error: "No token provided" };
  }

  // Local testing without a tenant: the token is taken at face value and used
  // as the account id, so two connections sharing a token share a fleet.
  if (INSECURE_AUTH) {
    return { valid: true, userId: `insecure:${token}`, email: undefined };
  }

  return new Promise((resolve) => {
    jwt.verify(
      token,
      getSigningKey,
      {
        audience: AUTH0_AUDIENCE,
        issuer: AUTH0_ISSUER,
        algorithms: ["RS256"]
      },
      (err, decoded) => {
        if (err) {
          resolve({ valid: false, error: err.message });
          return;
        }

        // Extract user ID from 'sub' claim
        const userId = decoded.sub;
        const email = decoded.email ||
          (AUTH0_EMAIL_CLAIM ? decoded[AUTH0_EMAIL_CLAIM] : undefined);

        if (!userId) {
          resolve({ valid: false, error: "No user ID in token" });
          return;
        }

        resolve({ valid: true, userId, email });
      }
    );
  });
}

// Rate limiting check
function checkRateLimit(ip) {
  const now = Date.now();
  const record = rateLimits.get(ip);

  if (!record) {
    rateLimits.set(ip, { attempts: 1, lastAttempt: now });
    return true;
  }

  // Reset if outside window
  if (now - record.lastAttempt > RATE_WINDOW_MS) {
    record.attempts = 1;
    record.lastAttempt = now;
    return true;
  }

  record.attempts++;
  record.lastAttempt = now;

  return record.attempts <= MAX_ATTEMPTS;
}

// Generate APNs JWT token
function generateApnsToken() {
  if (!apnsKey) return null;

  const token = jwt.sign({}, apnsKey, {
    algorithm: "ES256",
    keyid: APNS_KEY_ID,
    issuer: APNS_TEAM_ID,
    expiresIn: "1h"
  });

  return token;
}

// Send push notification via APNs
async function sendPushNotification(deviceToken, title, body, metadata = {}) {
  if (!apnsKey) {
    log("Push notification skipped - APNs key not configured");
    return false;
  }

  const apnsHost = APNS_PRODUCTION
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";

  const jwtToken = generateApnsToken();
  if (!jwtToken) {
    log("Failed to generate APNs JWT token");
    return false;
  }

  const payload = JSON.stringify({
    ...(metadata.sessionId ? { sessionId: metadata.sessionId } : {}),
    ...(metadata.eventId ? { eventId: metadata.eventId } : {}),
    ...(metadata.instanceId ? { instanceId: metadata.instanceId } : {}),
    aps: {
      alert: {
        title: title,
        body: body.length > 100 ? body.substring(0, 100) + "..." : body
      },
      sound: "default",
      "thread-id": metadata.sessionId || "udha"
    }
  });

  return new Promise((resolve) => {
    const client = http2.connect(`https://${apnsHost}`);

    client.on("error", (err) => {
      log(`APNs connection error: ${err.message}`);
      resolve(false);
    });

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      "authorization": `bearer ${jwtToken}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + APNS_EXPIRATION_SECONDS),
      ...(metadata.eventId ? { "apns-collapse-id": metadata.eventId.slice(0, 64) } : {}),
      "content-type": "application/json",
      "content-length": Buffer.byteLength(payload)
    });

    req.on("response", (headers) => {
      const status = headers[":status"];
      if (status === 200) {
        log(`Push notification sent to ${deviceToken.substring(0, 8)}...`);
        resolve(true);
      } else {
        log(`APNs error: status ${status}`);
        resolve(false);
      }
    });

    req.on("error", (err) => {
      log(`APNs request error: ${err.message}`);
      resolve(false);
    });

    req.on("end", () => {
      client.close();
    });

    req.write(payload);
    req.end();
  });
}

// Send push to all registered devices for a user
async function sendPushToUser(userId, title, body, metadata = {}) {
  const tokens = deviceTokens.get(userId);
  if (!tokens || tokens.size === 0) {
    log(`No device tokens registered for user ${userId.substring(0, 16)}...`);
    return;
  }

  log(`Sending push to ${tokens.size} device(s) for user ${userId.substring(0, 16)}...`);

  for (const deviceToken of tokens) {
    // Presence is per registered device, expires quickly, and is cleared on background.
    const viewing = !!metadata.sessionId && !!metadata.instanceId && [...(clientConnections.get(userId) || [])].some(client =>
      client._attentionPresence && client.readyState === WebSocket.OPEN && client._deviceToken === deviceToken &&
      client._attentionPresence?.sessionId === metadata.sessionId &&
      client._attentionPresence?.instanceId === metadata.instanceId &&
      Date.now() - client._attentionPresence.at < PRESENCE_TTL_MS);
    if (!viewing) await sendPushNotification(deviceToken, title, body, metadata);
  }
}

// Notify clients about home server status (with instanceId)
// broadcastToAll: if true, send to ALL clients (for status updates), otherwise only subscribed clients
function notifyClients(userId, type, instanceId = null, metadata = null, broadcastToAll = false) {
  const clients = clientConnections.get(userId);
  if (clients) {
    const message = JSON.stringify({
      type,
      instanceId,
      metadata
    });
    clients.forEach(client => {
      if (client.readyState === WebSocket.OPEN) {
        // For status updates (instance_online/offline), broadcast to all clients
        // For relay messages, only send to subscribed clients
        if (broadcastToAll || !instanceId) {
          client.send(message);
        } else {
          const subs = clientSubscriptions.get(client._clientId);
          if (subs && subs.has(instanceId)) {
            client.send(message);
          }
        }
      }
    });
  }
}

// Get list of paired instances with online status for a user
function getPairedInstancesList(userId) {
  const userPaired = pairedInstances.get(userId) || new Map();
  const userHomes = homeServers.get(userId) || new Map();

  const list = Array.from(userPaired.entries()).map(([instanceId, info]) => {
    const homeInfo = userHomes.get(instanceId);
    return {
      instanceId,
      name: info.metadata?.name || instanceId,
      folderName: info.metadata?.folderName,
      workingDirectory: info.metadata?.workingDirectory,
      machineName: info.metadata?.machineName,
      isOnline: !!(homeInfo && homeInfo.ws && homeInfo.ws.readyState === WebSocket.OPEN),
      paired: true,
      pairedAt: info.pairedAt,
      lastSeen: info.lastSeen || info.pairedAt
    };
  });

  // Also advertise hosts that are online right now but have never completed a
  // pairing handshake with this account.
  //
  // Without this, a fresh account can never pair at all. A client learns an
  // instanceId from exactly two places: this list, or the `instance_online`
  // broadcast — and that broadcast only fires at the moment the host connects,
  // so a client that opens later misses it permanently. Pairing needs an
  // instanceId, but the only source of one was a list that required already
  // being paired. Same-user routing is already enforced above, so surfacing an
  // unpaired-but-connected host of this user grants no new access.
  for (const [instanceId, homeInfo] of userHomes) {
    if (userPaired.has(instanceId)) continue;
    if (!homeInfo || !homeInfo.ws || homeInfo.ws.readyState !== WebSocket.OPEN) continue;
    list.push({
      instanceId,
      name: homeInfo.metadata?.name || instanceId,
      folderName: homeInfo.metadata?.folderName,
      workingDirectory: homeInfo.metadata?.workingDirectory,
      machineName: homeInfo.metadata?.machineName,
      isOnline: true,
      paired: false,
      pairedAt: null,
      lastSeen: Date.now()
    });
  }

  return list;
}

// Check if any clients are actively connected
function hasActiveClients(userId) {
  const clients = clientConnections.get(userId);
  if (!clients) return false;

  for (const client of clients) {
    if (client.readyState === WebSocket.OPEN) {
      return true;
    }
  }
  return false;
}

// Create HTTP server for WebSocket upgrade handling.
//
// GET /health is the liveness probe the Dockerfile and any load balancer use.
// It answers before Auth0 is reachable on purpose: a relay that cannot verify
// tokens is still up, and you want to see the difference.
const server = http.createServer((req, res) => {
  const urlPath = (req.url || "/").split("?")[0];

  if (urlPath === "/health" || urlPath === "/healthz") {
    const body = JSON.stringify({
      status: "ok",
      version: VERSION,
      uptimeSeconds: Math.round(process.uptime()),
      authMode: AUTH_MODE,
      push: apnsKey ? "enabled" : "disabled",
      hosts: [...homeServers.values()].reduce((n, m) => n + m.size, 0),
      clients: [...clientConnections.values()].reduce((n, s) => n + s.size, 0)
    });
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
      "Cache-Control": "no-store"
    });
    res.end(body);
    return;
  }

  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(`Udha relay v${VERSION}\n`);
});

// Create WebSocket server
const wss = new WebSocket.Server({ noServer: true });

// Handle HTTP upgrade to WebSocket
server.on("upgrade", async (request, socket, head) => {
  const ip = request.socket.remoteAddress;

  // Rate limit check
  if (!checkRateLimit(ip)) {
    securityLog("RATE_LIMITED", ip);
    socket.write("HTTP/1.1 429 Too Many Requests\r\n\r\n");
    socket.destroy();
    return;
  }

  // Parse URL
  let url;
  try {
    url = new URL(request.url, `http://${request.headers.host}`);
  } catch (e) {
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.destroy();
    return;
  }

  const urlPath = url.pathname;
  const token = url.searchParams.get("token");
  const instanceId = url.searchParams.get("instanceId") || "default";

  // Validate path
  if (urlPath !== "/home" && urlPath !== "/client") {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }

  // Validate JWT token
  const authResult = await validateToken(token);
  if (!authResult.valid) {
    securityLog("INVALID_TOKEN", ip, `path=${urlPath}, error=${authResult.error}`);
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }

  const { userId, email } = authResult;
  log(`Auth successful for user: ${email || userId.substring(0, 16)}...`);

  // Accept the WebSocket connection
  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit("connection", ws, request, { path: urlPath, userId, email, instanceId });
  });
});

// Handle WebSocket connections
wss.on("connection", (ws, request, { path, userId, email, instanceId }) => {
  const ip = request.socket.remoteAddress;

  if (path === "/home") {
    handleHomeConnection(ws, userId, email, ip, instanceId);
  } else if (path === "/client") {
    handleClientConnection(ws, userId, email, ip);
  }
});

function handleHomeConnection(ws, userId, email, ip, instanceId) {
  log(`Home server connected: ${ip} (user: ${email || userId.substring(0, 16)}..., instance: ${instanceId})`);

  // Initialize user's home servers map if needed
  if (!homeServers.has(userId)) {
    homeServers.set(userId, new Map());
  }
  const userHomes = homeServers.get(userId);

  // Close existing home connection for this instance
  const existing = userHomes.get(instanceId);
  if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
    log(`Replacing existing home connection for instance ${instanceId}`);
    existing.ws.close(4002, "Replaced by new connection");
  }

  // Store with metadata
  userHomes.set(instanceId, {
    ws,
    metadata: null, // Will be updated when home_info is received
    connectedAt: Date.now()
  });

  ws._userId = userId;
  ws._userEmail = email;
  ws._instanceId = instanceId;
  ws._relayType = "home";
  ws._isAlive = true;

  // Notify connected clients that this instance is online
  // Broadcast to ALL clients so they can update their project list
  notifyClients(userId, "instance_online", instanceId, null, true);

  // Handle messages from home server
  ws.on("message", (data) => {
    try {
      const message = JSON.parse(data.toString());

      if (message.type === "ping") {
        ws.send(JSON.stringify({ type: "pong" }));
        return;
      }

      // Handle pairing validation response from home server
      if (message.type === "pairing_valid") {
        const pending = pendingPairings.get(message.requestId);
        if (pending) {
          pendingPairings.delete(message.requestId);

          if (message.valid) {
            // Add to paired instances
            if (!pairedInstances.has(userId)) {
              pairedInstances.set(userId, new Map());
            }
            pairedInstances.get(userId).set(instanceId, {
              metadata: message.metadata,
              pairedAt: Date.now(),
              lastSeen: Date.now()
            });
            savePairedInstances();

            // Subscribe the client to this instance
            const subs = clientSubscriptions.get(pending.clientId);
            if (subs) {
              subs.add(instanceId);
            }

            // Update home server metadata
            const homeInfo = userHomes.get(instanceId);
            if (homeInfo) {
              homeInfo.metadata = message.metadata;
            }

            log(`Pairing successful for instance ${instanceId}`);
            pending.clientWs.send(JSON.stringify({
              type: "pair_success",
              instanceId,
              metadata: message.metadata
            }));
          } else {
            log(`Pairing failed for instance ${instanceId}`);
            pending.clientWs.send(JSON.stringify({
              type: "pair_failed",
              instanceId,
              error: "Invalid or expired pairing token"
            }));
          }
        }
        return;
      }

      if (message.type === "relay") {
        // Add instanceId to the relay message
        const relayMessage = {
          ...message,
          instanceId: instanceId
        };

        // Optional per-client targeting. Terminal frames and PTY output belong
        // to the one device that asked for them — broadcasting one client's
        // terminal bytes to every paired device is both wasteful and wrong.
        // Absent `toClientId` this behaves exactly as before: fan out to all
        // subscribers, which is what session state and voice signaling want.
        const targetClientId = message.toClientId || null;

        // Forward to clients subscribed to this instance
        const clients = clientConnections.get(userId);
        let sentToClient = false;

        if (clients) {
          const relayData = JSON.stringify(relayMessage);
          clients.forEach(client => {
            if (client.readyState !== WebSocket.OPEN) return;
            if (targetClientId && client._clientId !== targetClientId) return;
            // Check if client is subscribed to this instance
            const subs = clientSubscriptions.get(client._clientId);
            if (subs && subs.has(instanceId)) {
              client.send(relayData);
              sentToClient = true;
            }
          });
        }

        // Explicit push request from a host: "this session needs a human".
        // Unlike the output fallback below this fires whether or not a client
        // is connected — reaching a backgrounded phone is the entire point.
        if (message.payload && message.payload.type === "notify") {
          const homeInfo = userHomes.get(instanceId);
          const instanceName = homeInfo?.metadata?.name || instanceId;
          sendPushToUser(
            userId,
            message.payload.title || `[${instanceName}]`,
            message.payload.body || "",
            { sessionId: typeof message.payload.sessionId === "string" ? message.payload.sessionId : undefined,
              eventId: typeof message.payload.eventId === "string" ? message.payload.eventId : undefined,
              instanceId }
          );
        } else if (!sentToClient && message.payload) {
          // If no active clients, send push notification
          const payload = message.payload;
          if (payload.type === "output" && payload.data) {
            const homeInfo = userHomes.get(instanceId);
            const instanceName = homeInfo?.metadata?.name || instanceId;
            const text = payload.data;
            sendPushToUser(userId, `[${instanceName}]`, text);
          }
        }
      }
    } catch (e) {
      log(`Error parsing home message: ${e.message}`);
    }
  });

  ws.on("pong", () => {
    ws._isAlive = true;
  });

  ws.on("close", () => {
    log(`Home server disconnected: ${ip} (instance: ${instanceId})`);
    const userHomes = homeServers.get(userId);
    if (userHomes) {
      const homeInfo = userHomes.get(instanceId);
      if (homeInfo && homeInfo.ws === ws) {
        userHomes.delete(instanceId);
        if (userHomes.size === 0) {
          homeServers.delete(userId);
        }
      }
    }

    // Update lastSeen in paired instances
    const userPaired = pairedInstances.get(userId);
    if (userPaired && userPaired.has(instanceId)) {
      userPaired.get(instanceId).lastSeen = Date.now();
      savePairedInstances();
    }

    // Broadcast to ALL clients so they can update their project list
    notifyClients(userId, "instance_offline", instanceId, null, true);
  });

  ws.on("error", (err) => {
    log(`Home server error: ${err.message}`);
  });
}

function handleClientConnection(ws, userId, email, ip) {
  const clientId = generateClientId();
  log(`Client connected: ${ip} (user: ${email || userId.substring(0, 16)}..., clientId: ${clientId})`);

  // Add to client pool
  if (!clientConnections.has(userId)) {
    clientConnections.set(userId, new Set());
  }
  clientConnections.get(userId).add(ws);

  // Initialize subscriptions for this client (empty - client must set active instance)
  // This prevents messages from ALL instances flooding the client
  const subs = new Set();
  clientSubscriptions.set(clientId, subs);

  ws._userId = userId;
  ws._userEmail = email;
  ws._clientId = clientId;
  ws._relayType = "client";
  ws._isAlive = true;

  // Send list of paired instances with online status
  const instancesList = getPairedInstancesList(userId);
  ws.send(JSON.stringify({
    type: "paired_instances",
    instances: instancesList
  }));
  log(`Sent ${instancesList.length} paired instances to client ${clientId}`);

  // For backward compatibility: also send home_connected/disconnected if any instance is online
  const userHomes = homeServers.get(userId);
  const hasOnlineInstance = userHomes && userHomes.size > 0 &&
    Array.from(userHomes.values()).some(h => h.ws && h.ws.readyState === WebSocket.OPEN);

  if (hasOnlineInstance) {
    ws.send(JSON.stringify({ type: "home_connected" }));
  } else {
    ws.send(JSON.stringify({ type: "home_disconnected" }));
  }

  // Handle messages from client
  ws.on("message", (data) => {
    try {
      const message = JSON.parse(data.toString());

      if (message.type === "ping") {
        ws.send(JSON.stringify({ type: "pong" }));
        return;
      }

      // Handle device token registration
      if (message.type === "register_device" && message.deviceToken) {
        if (!deviceTokens.has(userId)) {
          deviceTokens.set(userId, new Set());
        }
        deviceTokens.get(userId).add(message.deviceToken);
        ws._deviceToken = message.deviceToken;
        log(`Device token registered for user ${email || userId.substring(0, 16)}...: ${message.deviceToken.substring(0, 8)}...`);
        ws.send(JSON.stringify({ type: "device_registered" }));
        return;
      }

      if (message.type === "attention_presence") {
        const allowed = clientSubscriptions.get(clientId)?.has(message.instanceId);
        ws._attentionPresence = allowed && typeof message.sessionId === "string"
          ? { sessionId: message.sessionId, instanceId: message.instanceId, at: Date.now() } : null;
        return;
      }

      // Handle subscribe_instances - a client that wants several machines at once.
      //
      // `set_active_instance` below clears the set, and that one line is what
      // pinned a phone to a single machine: its Sessions list could only ever
      // hold one host's work, so reaching the other one meant switching and
      // losing sight of the first. The fan-out has always routed per instance
      // (`subs.has(instanceId)`), so carrying more than one subscription costs
      // nothing here.
      //
      // A separate verb rather than a change to `set_active_instance`, so an
      // older client keeps its exclusive behaviour byte for byte.
      if (message.type === "subscribe_instances") {
        const ids = Array.isArray(message.instanceIds)
          ? message.instanceIds.filter(id => typeof id === "string" && id.length > 0)
          : [];
        const subs = clientSubscriptions.get(clientId);
        if (subs) {
          subs.clear();
          ids.forEach(id => subs.add(id));
          log(`Client ${clientId} subscribed to ${ids.length} instance(s): ${ids.join(", ") || "none"}`);
        }
        ws.send(JSON.stringify({ type: "instances_subscribed", instanceIds: ids }));
        return;
      }

      // Handle set_active_instance - client tells us which instance to subscribe to
      if (message.type === "set_active_instance") {
        const { instanceId } = message;
        const subs = clientSubscriptions.get(clientId);
        if (subs) {
          subs.clear();  // Clear all subscriptions
          if (instanceId) {
            subs.add(instanceId);  // Subscribe only to active instance
            log(`Client ${clientId} subscribed to instance ${instanceId}`);
          }
        }
        ws.send(JSON.stringify({ type: "active_instance_set", instanceId }));
        return;
      }

      // Handle pairing request
      if (message.type === "pair_request") {
        const { instanceId, pairingToken } = message;
        log(`Pairing request for instance ${instanceId}`);

        // Find the home server for this instance
        const userHomes = homeServers.get(userId);
        const homeInfo = userHomes?.get(instanceId);

        if (!homeInfo || !homeInfo.ws || homeInfo.ws.readyState !== WebSocket.OPEN) {
          ws.send(JSON.stringify({
            type: "pair_failed",
            instanceId,
            error: "Instance is not online"
          }));
          return;
        }

        // Generate request ID and store pending pairing
        const requestId = crypto.randomBytes(8).toString("hex");
        pendingPairings.set(requestId, {
          clientWs: ws,
          clientId,
          instanceId,
          pairingToken,
          userId,
          timestamp: Date.now()
        });

        // Ask home server to validate the pairing token
        homeInfo.ws.send(JSON.stringify({
          type: "validate_pairing",
          requestId,
          pairingToken
        }));

        // Clean up pending pairing after 30 seconds
        setTimeout(() => {
          if (pendingPairings.has(requestId)) {
            pendingPairings.delete(requestId);
            ws.send(JSON.stringify({
              type: "pair_failed",
              instanceId,
              error: "Pairing request timed out"
            }));
          }
        }, PAIRING_TIMEOUT_MS);

        return;
      }

      // Handle unpair request
      if (message.type === "unpair_request") {
        const { instanceId } = message;
        log(`Unpair request for instance ${instanceId}`);

        const userPaired = pairedInstances.get(userId);
        if (userPaired) {
          userPaired.delete(instanceId);
          if (userPaired.size === 0) {
            pairedInstances.delete(userId);
          }
          savePairedInstances();
        }

        // Remove from this client's subscriptions
        const subs = clientSubscriptions.get(clientId);
        if (subs) {
          subs.delete(instanceId);
        }

        ws.send(JSON.stringify({
          type: "unpair_success",
          instanceId
        }));
        return;
      }

      if (message.type === "relay") {
        // Get target instanceId from message (required for multi-instance)
        const targetInstanceId = message.instanceId;

        if (!targetInstanceId) {
          // Backward compatibility: if no instanceId, try to find any online home
          const userHomes = homeServers.get(userId);
          if (userHomes && userHomes.size > 0) {
            // Find first online instance
            for (const [instId, homeInfo] of userHomes) {
              if (homeInfo.ws && homeInfo.ws.readyState === WebSocket.OPEN) {
                homeInfo.ws.send(JSON.stringify({ ...message, clientId }));
                return;
              }
            }
          }
          ws.send(JSON.stringify({
            type: "error",
            data: "No home server connected"
          }));
          return;
        }

        // Forward to specific instance
        const userHomes = homeServers.get(userId);
        const homeInfo = userHomes?.get(targetInstanceId);

        if (homeInfo && homeInfo.ws && homeInfo.ws.readyState === WebSocket.OPEN) {
          // Stamp the sender so the host can address a reply to this device
          // alone (see `toClientId` on the home->client path). Hosts that don't
          // care simply ignore the extra field.
          homeInfo.ws.send(JSON.stringify({ ...message, clientId }));
        } else {
          ws.send(JSON.stringify({
            type: "error",
            instanceId: targetInstanceId,
            data: "Instance not connected"
          }));
        }
      }
    } catch (e) {
      log(`Error parsing client message: ${e.message}`);
    }
  });

  ws.on("pong", () => {
    ws._isAlive = true;
  });

  ws.on("close", () => {
    log(`Client disconnected: ${ip} (clientId: ${clientId})`);
    const clients = clientConnections.get(userId);
    if (clients) {
      clients.delete(ws);
      if (clients.size === 0) {
        clientConnections.delete(userId);
      }
    }
    // Clean up subscriptions
    clientSubscriptions.delete(clientId);
  });

  ws.on("error", (err) => {
    log(`Client error: ${err.message}`);
  });
}

// Keepalive ping interval
const pingInterval = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws._isAlive === false) {
      log(`Connection not responding, terminating (${ws._relayType})`);
      return ws.terminate();
    }
    ws._isAlive = false;
    ws.ping();
  });
}, PING_INTERVAL);

// Cleanup rate limit records periodically
setInterval(() => {
  const now = Date.now();
  for (const [ip, record] of rateLimits) {
    if (now - record.lastAttempt > RATE_WINDOW_MS * 2) {
      rateLimits.delete(ip);
    }
  }
}, RATE_WINDOW_MS);

// Graceful shutdown
function shutdown(signal) {
  log(`Received ${signal}, shutting down...`);

  clearInterval(pingInterval);

  wss.clients.forEach((ws) => {
    ws.close(1001, "Server shutting down");
  });

  server.close(() => {
    log("Server closed. Goodbye!");
    process.exit(0);
  });
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

// Start server
server.listen(PORT, BIND_ADDRESS, () => {
  const base = PUBLIC_URL || `ws://localhost:${PORT}`;

  log("");
  log(`Udha relay v${VERSION}`);
  log(`Listening on ${BIND_ADDRESS}:${PORT}`);
  log(`Auth mode: ${AUTH_MODE}`);
  if (!INSECURE_AUTH) {
    log(`Auth0 domain: ${AUTH0_DOMAIN}`);
    log(`Auth0 audience: ${AUTH0_AUDIENCE}`);
    log(`Auth0 issuer: ${AUTH0_ISSUER}`);
  }
  log(`APNs enabled: ${apnsKey ? "yes" : "no"}`);
  log(`Data directory: ${DATA_DIR}`);
  log("");

  // Load persisted paired instances
  loadPairedInstances();

  log("Endpoints:");
  log(`  Health:  GET ${base.replace(/^ws/, "http")}/health`);
  log(`  Host:    ${base}/home?token=<JWT>&instanceId=<ID>`);
  log(`  Client:  ${base}/client?token=<JWT>`);
  log("");
});
