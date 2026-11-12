'use strict';

const { app, BrowserWindow, ipcMain, dialog, shell, nativeTheme, nativeImage, clipboard } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const { ConfigStore, newSessionConfig } = require('./config');
const { SessionManager } = require('./sessions');
const { Notifier } = require('./notify');
const { UdhaTray } = require('./tray');
const { Folders } = require('./folders');
const { Menu } = require('electron');
const git = require('./git');
const { AgentStore } = require('./agents');
const { MachineStats } = require('./machines');
const usageMod = require('./usage');
const { EdgeOverlay } = require('./overlay');
const { Secrets } = require('./secrets');
const { InputLock } = require('./lock');
const { Meetings } = require('./meetings');
const { Recordings } = require('./recordings');
const { SlackInbox } = require('./slack');
const { desktopCapturer, session: electronSession } = require('electron');

// UDHA_DATA_DIR points a test run at a scratch folder instead of %APPDATA%\Udha.
const DATA_DIR = process.env.UDHA_DATA_DIR || path.join(app.getPath('appData'), 'Udha');
// A scratch run gets its own Electron profile, so its single-instance lock
// doesn't collide with (and hand off to) the installed Udha.
if (process.env.UDHA_DATA_DIR) app.setPath('userData', path.join(DATA_DIR, 'electron-profile'));
const store = new ConfigStore(DATA_DIR);
let sessions;
let notifier;
let overlay;
let inputLock;
let folders;
let tray;
let win;
let quitting = false;
let toldAboutTray = false;
// Started by Windows at sign-in: come up in the tray, not in your face.
const startHidden = process.argv.includes('--hidden');

app.setAppUserModelId('ai.udha.windows');

/** Bring the window forward and select a session (toast click, tray, overlay). */
function showSession(id) {
  if (!win || win.isDestroyed()) createWindow();
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
  if (id) {
    store.mutate((c) => { c.selectedSessionID = id; });
    send('select-session', id);
  }
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showSession());
  app.whenReady().then(boot);
}

function boot() {
  store.load();
  nativeTheme.themeSource = store.config.appearance.mode || 'system';

  // hook.js has to live on the real filesystem for Claude to run it, even
  // when the app itself is packaged into an asar.
  const hookScript = path.join(DATA_DIR, 'hook.js');
  fs.copyFileSync(path.join(__dirname, 'hook.js'), hookScript);

  sessions = new SessionManager(store, {
    statusDir: path.join(DATA_DIR, 'status'),
    hookScript,
    settingsFile: path.join(DATA_DIR, 'claude-settings.json'),
  });
  folders = new Folders(store, sessions);
  folders.prune();
  notifier = new Notifier({ store, getWindow: () => win, onClick: showSession });
  notifier.onCleared = (id) => sessions.emitChanged(id);
  tray = new UdhaTray({
    getSessions: () => sessions.list(),
    onShow: showSession,
    onNew: () => { showSession(); send('open-new-session'); },
    onQuit: () => { quitting = true; app.quit(); },
  });
  overlay = new EdgeOverlay({
    getSessions: () => sessions.list(),
    onPick: showSession,
    staleAfter: () => store.config.staleAfterSeconds,
  });
  let overlayTimer = null;
  let refreshOverlay = () => {
    if (overlayTimer) return;
    overlayTimer = setTimeout(() => { overlayTimer = null; overlay.refresh(); }, 250);
  };
  inputLock = new InputLock({
    store,
    getSessions: () => sessions.list(),
    onChange: (locked) => {
      send('lock:changed', locked);
      tray.scheduleRefresh();
      if (locked && process.env.UDHA_SCREENSHOT) {
        // Dev aid: never leave a test run's screen locked — capture it, then release.
        setTimeout(() => {
          const w = inputLock.wins[0];
          if (w && !w.isDestroyed()) w.webContents.capturePage().then((img) => fs.writeFileSync(process.env.UDHA_SCREENSHOT.replace(/\.png$/, '-lock.png'), img.toPNG()));
        }, 2000);
        setTimeout(() => inputLock.unlock(), 3500);
      }
    },
  });
  tray.onLock = () => { try { inputLock.lock(); } catch (err) { showSession(); send('lock:need-pin'); } };
  const origRefresh = refreshOverlay;
  refreshOverlay = () => { origRefresh(); if (inputLock.locked) inputLock.refresh(); };
  sessions.on('changed', (snap) => { send('session:changed', snap); notifier.observe(snap); tray.scheduleRefresh(); refreshOverlay(); });
  sessions.on('removed', (id) => { send('session:removed', id); notifier.forget(id); tray.scheduleRefresh(); refreshOverlay(); });
  sessions.on('reordered', () => { tray.scheduleRefresh(); refreshOverlay(); });
  sessions.on('data', (id, data) => send('session:data', id, data));

  registerIpc();
  createWindow({ show: !startHidden });
  sessions.init();
  tray.refresh();
  overlay.setEnabled(store.config.overlay !== false && (!process.env.UDHA_SCREENSHOT || !!process.env.UDHA_TEST_OVERLAY));
  if (process.env.UDHA_TEST_OVERLAY && process.env.UDHA_SCREENSHOT) {
    // Dev aid: capture the strip, then the bloomed panel.
    const shot = (suffix) => overlay.win && overlay.win.webContents.capturePage()
      .then((img) => fs.writeFileSync(process.env.UDHA_SCREENSHOT.replace(/\.png$/, `-${suffix}.png`), img.toPNG()));
    setTimeout(() => shot('strip'), 4000);
    setTimeout(() => overlay.setBloom(true), 4500);
    setTimeout(() => shot('bloom'), 5500);
  }
}

function send(channel, ...args) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, ...args);
}

function overlayColors() {
  const dark = nativeTheme.shouldUseDarkColors;
  return { color: dark ? '#2a2a2d' : '#f6f6f8', symbolColor: dark ? '#f5f5f7' : '#1d1d1f', height: 52 };
}

function createWindow({ show = true } = {}) {
  const saved = store.config.window || {};
  win = new BrowserWindow({
    icon: path.join(__dirname, '..', 'assets', 'icon.png'),
    width: saved.width || 1320,
    height: saved.height || 840,
    x: saved.x, y: saved.y,
    minWidth: 900,
    minHeight: 560,
    title: 'Udha',
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1b1b1d' : '#f2f2f4',
    titleBarStyle: 'hidden',
    titleBarOverlay: overlayColors(),
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      // Recording and export draw on timers; they must keep pace while minimized.
      backgroundThrottling: false,
      // Audio contexts (meters, mixing) must run without a click first.
      autoplayPolicy: 'no-user-gesture-required',
    },
  });
  if (saved.maximized && show) win.maximize();
  if (show) win.once('ready-to-show', () => win.show());
  // Closing the window hides it to the tray; the sessions keep running.
  win.on('close', (e) => {
    if (quitting || store.config.closeToTray === false) return;
    e.preventDefault();
    win.hide();
    if (!toldAboutTray && notifier) {
      toldAboutTray = true;
      notifier.toast(null, 'Udha is still running', 'Your sessions keep going. Open Udha from the tray, or quit it there.');
    }
  });
  if (process.env.UDHA_SCREENSHOT) {
    win.webContents.on('console-message', (e) => {
      const level = e.level ?? e.params?.level;
      if (level === 'error' || level === 'warning' || level >= 2) console.log(`[renderer] ${e.message ?? e.params?.message}`);
    });
    // Dev aid: optionally drive the page (UDHA_DEV_JS), capture the window after it settles, then quit.
    if (process.env.UDHA_DEV_JS) {
      setTimeout(() => {
        win.webContents.executeJavaScript(process.env.UDHA_DEV_JS)
          .then((r) => { if (r !== undefined) console.log(`[dev-js] ${typeof r === 'string' ? r : JSON.stringify(r)}`); })
          .catch((err) => console.log(`[dev-js] error: ${err.message}`));
      }, Number(process.env.UDHA_DEV_JS_DELAY || 2500));
    }
    setTimeout(async () => {
      const img = await win.webContents.capturePage();
      fs.writeFileSync(process.env.UDHA_SCREENSHOT, img.toPNG());
      console.log(`[udha] screenshot saved: ${process.env.UDHA_SCREENSHOT}`);
      app.quit();
    }, Number(process.env.UDHA_SCREENSHOT_DELAY || 6000));
  }
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
  // Belt and braces: the app page never navigates away (e.g. to a dropped file).
  win.webContents.on('will-navigate', (e) => e.preventDefault());

  const saveBounds = () => {
    if (!win || win.isDestroyed()) return;
    store.mutate((c) => { c.window = { ...win.getNormalBounds(), maximized: win.isMaximized() }; });
  };
  win.on('resize', saveBounds);
  win.on('move', saveBounds);
  win.on('closed', () => { win = null; });
  win.on('focus', () => win.flashFrame(false));
  nativeTheme.on('updated', () => { if (win && !win.isDestroyed()) win.setTitleBarOverlay(overlayColors()); });
}

function registerIpc() {
  ipcMain.handle('state', () => ({
    sessions: sessions.list(),
    folders: folders.list(),
    selectedSessionID: store.config.selectedSessionID,
    staleAfterSeconds: store.config.staleAfterSeconds,
    restoreOnLaunch: store.config.restoreOnLaunch,
    appearance: store.config.appearance,
    terminal: store.config.terminal,
    notifications: notifier.settings(),
    closeToTray: store.config.closeToTray !== false,
    accountFailover: store.config.accountFailover !== false,
    overlay: store.config.overlay !== false,
    hasLockPin: !!(store.config.lockPin && store.config.lockPin.hash),
    openAtLogin: app.isPackaged ? app.getLoginItemSettings({ args: ['--hidden'] }).openAtLogin : null,
    configPath: store.file,
    recentDirs: [...new Set(store.config.sessions.map((s) => s.directory))].slice(0, 8),
    hostName: require('os').hostname(),
  }));

  ipcMain.handle('git:info', async (_e, dir) => {
    const info = await git.repoInfo(dir);
    return info ? { ...info, suggestion: git.suggestBranch(path.basename(info.root)) } : null;
  });

  // Usage: Claude logins, their 5-hour / weekly readings, and failover.
  const usage = new usageMod.UsageStore(store, DATA_DIR);
  const allLoginDirs = () => usage.logins().map((l) => l.configDir);
  const usageChanged = () => send('usage:update', usage.logins());
  sessions.on('rate-limits', (dir, rl) => {
    usage.record(dir || usageMod.DEFAULT_DIR, usageMod.parseStatusLimits(rl));
    usageChanged();
  });
  sessions.on('limit', (id, dir) => {
    const from = dir || usageMod.DEFAULT_DIR;
    usage.markLimited(from);
    usageChanged();
    const cfg = store.session(id);
    const label = cfg ? cfg.label : 'A session';
    const fromName = (usage.find(from) || {}).name || 'this login';
    const next = store.config.accountFailover !== false ? usage.choose(from) : null;
    if (next) {
      sessions.moveToLogin(id, next.isDefault ? null : next.configDir, allLoginDirs(), { continueAfter: true });
      notifier.toast(id, `${label} moved to ${next.name}`, `${fromName} hit its usage limit; the conversation carries on under ${next.name}.`);
    } else {
      notifier.toast(id, `${label} hit its usage limit`, `${fromName} is out of usage${usage.logins().length > 1 ? ' and no other login has room' : ''}.`);
    }
  });
  ipcMain.handle('usage:list', () => usage.logins());
  ipcMain.handle('usage:probe', async () => {
    await Promise.all(usage.logins().map((l) => usage.probe(l)));
    return usage.logins();
  });
  ipcMain.handle('usage:add', (_e, name) => {
    const login = usage.add(name);
    // Sign in by running Claude once under the new config dir.
    const cfg = newSessionConfig({ label: uniqueLabel(`Sign in · ${login.name}`), directory: require('os').homedir(), command: 'claude', env: { CLAUDE_CONFIG_DIR: login.configDir } });
    const id = sessions.create(cfg);
    store.mutate((c) => { c.selectedSessionID = id; });
    usageChanged();
    return { login, sessionID: id };
  });
  ipcMain.handle('usage:remove', (_e, loginID) => { usage.remove(loginID); usageChanged(); });
  ipcMain.handle('usage:set-failover', (_e, on) => { store.mutate((c) => { c.accountFailover = !!on; }); });
  ipcMain.handle('session:move-login', (_e, id, configDir) => {
    const ok = sessions.moveToLogin(id, configDir || null, allLoginDirs());
    usageChanged();
    return ok;
  });

  // Meetings: keys in DPAPI-encrypted secrets, audio and transcripts on disk.
  const secrets = new Secrets(DATA_DIR);
  const meetings = new Meetings({ dataDir: DATA_DIR, store, secrets });
  meetings.on('updated', (m) => send('meetings:updated', m));
  meetings.on('removed', (id) => send('meetings:removed', id));
  // System audio: getDisplayMedia in the renderer gets the screen's loopback
  // audio here (the video track is dropped there straight away).
  electronSession.defaultSession.setDisplayMediaRequestHandler((_req, callback) => {
    desktopCapturer.getSources({ types: ['screen'] })
      .then((sources) => callback({ video: sources[0], audio: 'loopback' }))
      .catch(() => callback({}));
  });
  // Slack inbox.
  const slack = new SlackInbox({ dataDir: DATA_DIR, store, secrets });
  slack.on('changed', () => send('inbox:changed'));
  slack.on('new', (threads) => {
    for (const t of threads.slice(0, 3)) {
      const last = t.messages[t.messages.length - 1];
      notifier.toast(null, `${last.userName} · ${t.kind === 'dm' ? 'DM' : t.channelName}`, last.text);
    }
  });
  slack.start();
  app.on('before-quit', () => slack.stop());
  ipcMain.handle('inbox:list', () => ({ threads: slack.threads(), workspaces: slack.workspaces() }));
  ipcMain.handle('inbox:add', (_e, token) => slack.add(token));
  ipcMain.handle('inbox:remove', (_e, teamID) => slack.remove(teamID));
  ipcMain.handle('inbox:read', (_e, key) => slack.markRead(key));
  ipcMain.handle('inbox:reply', (_e, key, text) => slack.reply(key, String(text || '').slice(0, 4000)));
  ipcMain.handle('inbox:poll', () => slack.poll());

  // Videos.
  const recordings = new Recordings({ dataDir: DATA_DIR, meetings });
  recordings.on('updated', (r) => send('videos:updated', r));
  recordings.on('removed', (id) => send('videos:removed', id));
  ipcMain.handle('videos:list', () => recordings.list());
  ipcMain.handle('videos:get', (_e, id) => recordings.get(id));
  ipcMain.handle('videos:create', (_e, opts) => recordings.create(opts));
  ipcMain.handle('videos:begin', (_e, id, kind) => { recordings.begin(id, String(kind).replace(/[^\w-]/g, '')); return true; });
  ipcMain.on('videos:append', (_e, id, kind, bytes) => recordings.append(id, kind, bytes));
  ipcMain.handle('videos:finish', (_e, id, kind, durationMs) => recordings.finish(id, kind, durationMs));
  ipcMain.handle('videos:file-url', (_e, id, kind) => require('url').pathToFileURL(recordings.filePath(id, String(kind || 'original').replace(/[^\w-]/g, ''))).href);
  ipcMain.handle('videos:caption', (_e, id) => recordings.caption(id));
  ipcMain.handle('videos:set-captions', (_e, id, cues, lang) => recordings.setCaptions(id, cues, lang || null));
  ipcMain.handle('videos:translate', (_e, id, language) => recordings.translate(id, String(language).slice(0, 40)));
  ipcMain.handle('videos:rename', (_e, id, title) => recordings.rename(id, title));
  ipcMain.handle('videos:remove', (_e, id) => recordings.remove(id));
  // While recording: Udha gets out of the way, Ctrl+Alt+S stops from anywhere.
  ipcMain.on('videos:recording', (_e, on) => {
    const { globalShortcut } = require('electron');
    if (on) {
      try { globalShortcut.register('CommandOrControl+Alt+S', () => { send('videos:stop-request'); showSession(); }); } catch { /* taken */ }
      if (win && !win.isDestroyed()) win.minimize();
      notifier.toast(null, 'Recording your screen', 'Press Ctrl+Alt+S, or open Udha, to stop.');
    } else {
      try { globalShortcut.unregister('CommandOrControl+Alt+S'); } catch { /* ignore */ }
    }
  });
  ipcMain.handle('videos:open-folder', (_e, id) => shell.openPath(recordings.folder(id)));
  ipcMain.handle('videos:show-file', (_e, id, kind) => shell.showItemInFolder(recordings.filePath(id, String(kind).replace(/[^\w-]/g, ''))));

  const setupStatus = () => ({
    ...secrets.status(),
    sttBaseURL: meetings.cfg().sttBaseURL,
    localModel: meetings.local(),
    canTranscribe: meetings.canTranscribe(),
    canSummarize: meetings.canSummarize(),
  });
  ipcMain.handle('meetings:list', () => meetings.list());
  ipcMain.handle('meetings:get', (_e, id) => meetings.get(id));
  ipcMain.handle('meetings:start', (_e, title) => meetings.start(title));
  ipcMain.handle('meetings:stop', (_e, id) => meetings.stop(id));
  ipcMain.handle('meetings:chunk', (_e, id, who, offsetMs, bytes, mime) => meetings.addChunk(id, who === 'you' ? 'you' : 'them', Number(offsetMs) || 0, bytes, String(mime || '')));
  ipcMain.handle('meetings:rename', (_e, id, title) => meetings.rename(id, title));
  ipcMain.handle('meetings:remove', (_e, id) => meetings.remove(id));
  ipcMain.handle('meetings:action-done', (_e, id, i, done) => meetings.setActionDone(id, i, done));
  ipcMain.handle('meetings:update-notes', (_e, id, text) => meetings.updateNotes(id, text));
  ipcMain.handle('meetings:refresh-notes', (_e, id) => meetings.refreshNotes(id, { force: true }));
  ipcMain.handle('meetings:ask', (_e, id, q) => meetings.ask(id, String(q || '').slice(0, 2000)));
  ipcMain.handle('meetings:open-folder', (_e, id) => shell.openPath(path.join(DATA_DIR, 'Meetings', String(id).replace(/[^\w-]/g, ''))));
  ipcMain.handle('meetings:setup', () => setupStatus());
  ipcMain.handle('meetings:set-secret', (_e, account, value) => { secrets.set(account, value); return setupStatus(); });
  ipcMain.handle('meetings:set-config', (_e, patch) => {
    store.mutate((c) => {
      if (typeof patch.sttBaseURL === 'string') c.meetings = { ...(c.meetings || {}), sttBaseURL: patch.sttBaseURL.trim() };
      if (patch.localModel) c.localModel = { ...(c.localModel || {}), ...patch.localModel };
    });
    return setupStatus();
  });

  // Machines: polls only while the section is open (or the window is visible).
  const machineStats = new MachineStats({ onUpdate: (m) => send('machines:update', m) });
  ipcMain.handle('machines:start', () => { machineStats.start(); return machineStats.last; });
  ipcMain.handle('machines:stop', () => machineStats.stop());
  app.on('before-quit', () => machineStats.stop());

  // Agents.
  const agents = new AgentStore(path.join(DATA_DIR, 'Agents'));
  ipcMain.handle('agents:list', () => agents.list());
  ipcMain.handle('agents:create', (_e, name) => agents.create(name));
  ipcMain.handle('agents:save', (_e, agent) => { agents.save(agent); return agents.get(agent.slug); });
  ipcMain.handle('agents:remove', (_e, slug) => agents.remove(slug));
  ipcMain.handle('agents:open-folder', () => shell.openPath(agents.openFolder()));
  // Run: a fresh session in the source session's folder (with its command,
  // mode, env and folder — nested under it), or in a picked folder; then the prompt.
  ipcMain.handle('agents:run', (_e, slug, opts = {}) => {
    const agent = agents.get(slug);
    if (!agent) throw new Error('That agent no longer exists');
    const src = opts.sourceSessionID ? store.session(opts.sourceSessionID) : null;
    const directory = opts.directory || (src && src.directory);
    if (!directory || !fs.existsSync(directory)) throw new Error('Pick a folder that exists');
    const cfg = newSessionConfig({
      label: uniqueLabel(`${agent.name} · ${path.basename(directory)}`),
      directory,
      command: src ? src.command : 'claude',
      args: src ? [...(src.args || [])] : undefined,
      env: src ? { ...(src.env || {}) } : {},
    });
    cfg.agentName = agent.name;
    if (src) {
      cfg.parentSessionID = src.parentSessionID || src.id;
      cfg.folderID = src.folderID || null;
    }
    const id = sessions.create(cfg);
    sessions.sendPromptWhenReady(id, agent.prompt);
    store.mutate((c) => { c.selectedSessionID = id; });
    return id;
  });

  ipcMain.handle('git:remove-worktree', async (_e, dir, force) => {
    try { await git.removeWorktree(dir, !!force); return { ok: true }; } catch (err) { return { ok: false, error: err.message }; }
  });

  ipcMain.handle('session:create', async (_e, opts) => {
    let directory = String(opts.directory || '').trim();
    if (!directory || !fs.existsSync(directory)) throw new Error('Pick a folder that exists');
    let branch = null;
    if (opts.worktree && opts.worktree.branch) {
      branch = String(opts.worktree.branch).trim();
      directory = await git.createWorktree(directory, branch, opts.worktree.base || null);
    }
    const fallback = branch ? `${path.basename(path.dirname(directory)).replace(/-wt$/, '')} · ${branch.split('/').pop()}` : path.basename(directory);
    const label = uniqueLabel(String(opts.label || '').trim() || fallback || 'Session');
    const command = String(opts.command || 'claude').trim();
    const cfg = newSessionConfig({
      label, directory, command,
      args: opts.args && opts.args.length ? opts.args : undefined,
      permission: opts.permission,
    });
    if (branch) { cfg.branch = branch; cfg.worktree = true; }
    const id = sessions.create(cfg);
    store.mutate((c) => { c.selectedSessionID = id; });
    return id;
  });
  // Duplicate: a fresh session (its own new conversation) in the same folder,
  // with the same command, mode, env and folder.
  ipcMain.handle('session:duplicate', (_e, id) => {
    const src = store.session(id);
    if (!src) return null;
    const cfg = newSessionConfig({
      label: uniqueLabel(src.label.replace(/ \d+$/, '')),
      directory: src.directory,
      command: src.command,
      args: [...(src.args || [])],
      env: { ...(src.env || {}) },
    });
    cfg.folderID = src.folderID || null;
    const newID = sessions.create(cfg);
    store.mutate((c) => { c.selectedSessionID = newID; });
    return newID;
  });
  // Attachments (AttachmentStaging): a pty can't be handed bytes, so a file
  // becomes a path the assistant reads. Pasted images are written to disk first.
  const attachDir = (id) => {
    const dir = path.join(DATA_DIR, 'attachments', String(id).replace(/[^0-9a-f-]/gi, ''));
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  };
  const stamp = () => new Date().toISOString().replace(/[:.]/g, '-').replace('T', '_').slice(0, 19);
  ipcMain.handle('attachment:paste-image', (_e, id) => {
    const img = clipboard.readImage();
    if (img.isEmpty()) return null;
    const file = path.join(attachDir(id), `pasted-${stamp()}.png`);
    fs.writeFileSync(file, img.toPNG());
    return file;
  });
  ipcMain.handle('attachment:save', (_e, id, name, bytes) => {
    const safe = String(name || 'file').replace(/[<>:"/\\|?*\x00-\x1f]/g, '_').slice(0, 80) || 'file';
    const file = path.join(attachDir(id), `${stamp()}-${safe}`);
    fs.writeFileSync(file, Buffer.from(bytes));
    return file;
  });
  ipcMain.handle('session:set-permission', (_e, id, mode) => sessions.setPermission(id, mode));
  ipcMain.handle('session:start', (_e, id) => sessions.start(id));
  ipcMain.handle('session:stop', (_e, id) => sessions.stop(id));
  ipcMain.handle('session:restart', (_e, id) => sessions.restart(id));
  ipcMain.handle('session:remove', async (_e, id, opts = {}) => {
    const cfg = store.session(id);
    const worktreeDir = cfg && cfg.worktree ? cfg.directory : null;
    sessions.remove(id);
    if (!worktreeDir || !opts.deleteWorktree) return { ok: true };
    // Windows keeps files open until the process is gone; give it a moment.
    await new Promise((r) => setTimeout(r, 1200));
    try {
      await git.removeWorktree(worktreeDir, !!opts.force);
      return { ok: true };
    } catch (err) {
      return { ok: false, error: err.message, worktree: worktreeDir };
    }
  });
  ipcMain.handle('session:rename', (_e, id, label) => sessions.rename(id, label));
  ipcMain.handle('session:reorder', (_e, ids) => sessions.reorder(ids));
  ipcMain.handle('session:send', (_e, id, text) => sessions.send(id, text));
  ipcMain.handle('session:buffer', (_e, id) => sessions.buffer(id));
  ipcMain.on('session:write', (_e, id, data) => sessions.write(id, data));
  ipcMain.on('session:resize', (_e, id, cols, rows) => sessions.resize(id, cols, rows));
  ipcMain.on('select', (_e, id) => store.mutate((c) => { c.selectedSessionID = id; }));

  ipcMain.handle('pick-folder', async (_e, start) => {
    const r = await dialog.showOpenDialog(win, { properties: ['openDirectory'], defaultPath: start || undefined });
    return r.canceled ? null : r.filePaths[0];
  });
  ipcMain.handle('open-folder', (_e, dir) => shell.openPath(dir));
  ipcMain.handle('open-in-terminal', (_e, id) => {
    const cfg = store.session(id);
    if (!cfg) return false;
    // A plain shell in the session's folder — not a second Claude on the same conversation.
    const p = spawn('wt.exe', ['-d', cfg.directory], { detached: true, stdio: 'ignore' });
    p.on('error', () => spawn('cmd.exe', ['/c', 'start', 'cmd.exe', '/k', `cd /d "${cfg.directory}"`], { detached: true, stdio: 'ignore' }));
    p.unref();
    return true;
  });
  ipcMain.handle('reveal-config', () => shell.showItemInFolder(store.file));
  // Folders and hiding.
  const foldersChanged = () => send('folders', folders.list());
  ipcMain.handle('folder:create', (_e, name, sessionID) => {
    const id = folders.create(name);
    if (sessionID) sessions.patch(sessionID, { folderID: id });
    foldersChanged();
    return id;
  });
  ipcMain.handle('folder:update', (_e, id, fields) => { folders.update(id, fields); foldersChanged(); });
  ipcMain.handle('folder:remove', (_e, id) => { folders.remove(id); foldersChanged(); });
  ipcMain.handle('folder:reorder', (_e, ids) => { folders.reorder(ids); foldersChanged(); });
  ipcMain.handle('session:set-folder', (_e, id, folderID) => sessions.patch(id, { folderID: folderID || null }));
  ipcMain.handle('session:set-hidden', (_e, id, hidden) => sessions.patch(id, { hidden: !!hidden }));
  ipcMain.handle('unhide-all', () => { folders.unhideAll(); foldersChanged(); });

  // A native context menu. The renderer describes items; the chosen item's id comes back.
  ipcMain.handle('context-menu', (_e, items) => new Promise((resolve) => {
    let chosen = null;
    const build = (list) => list.map((it) => {
      if (it.type === 'separator') return { type: 'separator' };
      return {
        label: it.label,
        enabled: it.enabled !== false,
        type: it.checked != null ? 'checkbox' : 'normal',
        checked: !!it.checked,
        submenu: it.submenu ? build(it.submenu) : undefined,
        click: it.submenu ? undefined : () => { chosen = it.id; },
      };
    });
    Menu.buildFromTemplate(build(items)).popup({ window: win, callback: () => setTimeout(() => resolve(chosen), 0) });
  }));

  ipcMain.handle('lock:lock', () => { inputLock.lock(); return true; });
  ipcMain.handle('lock:set-pin', (_e, pin) => { inputLock.setPin(pin); return true; });

  ipcMain.handle('session:notify-when-done', (_e, id, on) => {
    const cfg = store.session(id);
    if (!cfg) return false;
    store.mutate(() => { cfg.notifyWhenDone = !!on; });
    sessions.emitChanged(id);
    return !!on;
  });
  // The renderer draws the count badge (it has a canvas); main pins it to the taskbar button.
  ipcMain.on('badge', (_e, count, dataURL) => {
    if (!win || win.isDestroyed()) return;
    if (count > 0 && dataURL) {
      win.setOverlayIcon(nativeImage.createFromDataURL(dataURL), `${count} session${count === 1 ? '' : 's'} need you`);
    } else {
      win.setOverlayIcon(null, '');
    }
  });
  ipcMain.handle('settings:set', (_e, patch) => {
    store.mutate((c) => {
      if (patch.appearance) c.appearance = { ...c.appearance, ...patch.appearance };
      if (typeof patch.restoreOnLaunch === 'boolean') c.restoreOnLaunch = patch.restoreOnLaunch;
      if (typeof patch.staleAfterSeconds === 'number') c.staleAfterSeconds = patch.staleAfterSeconds;
      if (patch.terminal) c.terminal = { ...c.terminal, ...patch.terminal };
      if (patch.notifications) c.notifications = { ...(c.notifications || {}), ...patch.notifications };
      if (typeof patch.closeToTray === 'boolean') c.closeToTray = patch.closeToTray;
      if (typeof patch.overlay === 'boolean') c.overlay = patch.overlay;
    });
    if (patch.appearance && patch.appearance.mode) nativeTheme.themeSource = patch.appearance.mode;
    if (typeof patch.overlay === 'boolean') overlay.setEnabled(patch.overlay);
    if (typeof patch.openAtLogin === 'boolean' && app.isPackaged) {
      app.setLoginItemSettings({ openAtLogin: patch.openAtLogin, args: ['--hidden'] });
    }
    return true;
  });
}

/** "udha", "udha 2", … — the mac app's uniqueLabel. */
function uniqueLabel(base) {
  const taken = new Set(store.config.sessions.map((s) => s.label.toLowerCase()));
  if (!taken.has(base.toLowerCase())) return base;
  for (let n = 2; ; n++) if (!taken.has(`${base} ${n}`.toLowerCase())) return `${base} ${n}`;
}

app.on('before-quit', (e) => {
  // Quitting must not be a way around the lock (Alt+F4 is swallowed; this covers the rest).
  if (inputLock && inputLock.locked && !process.env.UDHA_SCREENSHOT) { e.preventDefault(); return; }
  quitting = true;
  if (sessions) sessions.shutdown();
  if (tray) tray.destroy();
  if (overlay) overlay.destroy();
});
app.on('window-all-closed', () => { if (store.config.closeToTray === false) app.quit(); });
