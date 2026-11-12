// Input lock (the mac's CGEventTap + Touch ID): keyboard and mouse go to a
// full-screen shield on every display while the screen stays awake and the
// sessions keep running underneath. Released with a PIN (stored as a salted
// scrypt hash). Windows reserves Ctrl+Alt+Del and Win+L for itself, so those
// still work — this guards against stray input, not against an attacker.
'use strict';

const { BrowserWindow, screen, powerSaveBlocker, ipcMain, globalShortcut } = require('electron');
const path = require('path');
const crypto = require('crypto');

const SWALLOW = ['Alt+F4', 'Alt+Tab', 'Alt+Shift+Tab', 'Super+D', 'Super+Tab', 'CommandOrControl+W', 'CommandOrControl+Q', 'F11', 'Escape'];

function hashPin(pin, salt = crypto.randomBytes(16).toString('hex')) {
  return { salt, hash: crypto.scryptSync(String(pin), salt, 32).toString('hex') };
}
function checkPin(pin, rec) {
  if (!rec || !rec.salt || !rec.hash) return false;
  const h = crypto.scryptSync(String(pin), rec.salt, 32);
  const want = Buffer.from(rec.hash, 'hex');
  return h.length === want.length && crypto.timingSafeEqual(h, want);
}

class InputLock {
  constructor({ store, getSessions, onChange }) {
    this.store = store;
    this.getSessions = getSessions;
    this.onChange = onChange;
    this.wins = [];
    this.blocker = null;
    this.failures = 0;
    ipcMain.handle('lock:unlock', (_e, pin) => this.tryUnlock(pin));
    ipcMain.handle('lock:state', () => ({ sessions: this.getSessions(), staleAfter: this.store.config.staleAfterSeconds }));
  }

  hasPin() { return !!(this.store.config.lockPin && this.store.config.lockPin.hash); }
  setPin(pin) {
    if (!/^\d{4,12}$/.test(String(pin))) throw new Error('Use 4 to 12 digits');
    this.store.mutate((c) => { c.lockPin = hashPin(pin); });
  }
  get locked() { return this.wins.length > 0; }

  lock() {
    if (this.locked) return;
    if (!this.hasPin()) throw new Error('Set an unlock PIN in Settings first');
    this.failures = 0;
    for (const d of screen.getAllDisplays()) {
      const w = new BrowserWindow({
        ...d.bounds, frame: false, fullscreen: true, kiosk: true, alwaysOnTop: true, skipTaskbar: true,
        resizable: false, movable: false, minimizable: false, closable: false, backgroundColor: '#0b0b0d',
        webPreferences: { preload: path.join(__dirname, 'lock-preload.js'), contextIsolation: true, sandbox: true },
      });
      w.setAlwaysOnTop(true, 'screen-saver');
      w.loadFile(path.join(__dirname, '..', 'renderer', 'lock.html'), { query: { primary: d.id === screen.getPrimaryDisplay().id ? '1' : '0' } });
      w.on('close', (e) => { if (this.locked) e.preventDefault(); });
      // Something stole focus (a toast, an app that launched): take it back.
      w.on('blur', () => setTimeout(() => { if (this.locked && !BrowserWindow.getFocusedWindow()) this.focusPrimary(); }, 150));
      this.wins.push(w);
    }
    for (const accel of SWALLOW) { try { globalShortcut.register(accel, () => {}); } catch { /* reserved by Windows */ } }
    this.blocker = powerSaveBlocker.start('prevent-display-sleep');
    this.focusTimer = setInterval(() => this.focusPrimary(), 1500);
    this.focusPrimary();
    this.onChange(true);
  }

  focusPrimary() {
    const w = this.wins.find((x) => !x.isDestroyed());
    if (w && !w.isFocused()) { w.show(); w.focus(); w.moveTop(); }
  }

  tryUnlock(pin) {
    if (!this.locked) return { ok: true };
    if (checkPin(pin, this.store.config.lockPin)) { this.unlock(); return { ok: true }; }
    this.failures += 1;
    return { ok: false, wait: this.failures >= 5 ? Math.min(60, 5 * (this.failures - 4)) : 0 };
  }

  unlock() {
    const wins = this.wins;
    this.wins = [];
    clearInterval(this.focusTimer);
    for (const accel of SWALLOW) { try { globalShortcut.unregister(accel); } catch { /* ignore */ } }
    if (this.blocker != null && powerSaveBlocker.isStarted(this.blocker)) powerSaveBlocker.stop(this.blocker);
    this.blocker = null;
    for (const w of wins) if (!w.isDestroyed()) { w.setClosable(true); w.destroy(); }
    this.onChange(false);
  }

  refresh() {
    for (const w of this.wins) if (!w.isDestroyed()) w.webContents.send('lock:sessions', this.getSessions());
  }
}

module.exports = { InputLock, hashPin, checkPin };
