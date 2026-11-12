// The edge overlay (Overlay/ on the mac): a near-black strip one hair wide
// against the right edge of the screen with a capsule tick per session — tall
// red and pulsing when a session wants you, a shorter accent bar while it
// works, a stub when quiet. Hovering blooms it into a card of session pills;
// clicking one raises that session. Empty regions pass clicks through.
'use strict';

const { BrowserWindow, screen, ipcMain } = require('electron');
const path = require('path');

const STRIP_W = 14;     // hit area; the visible strip inside it is thinner
const PANEL_W = 340;

class EdgeOverlay {
  constructor({ getSessions, onPick, staleAfter }) {
    this.getSessions = getSessions;
    this.onPick = onPick;
    this.staleAfter = staleAfter;
    this.win = null;
    this.bloomed = false;
    this.enabled = false;

    ipcMain.on('overlay:bloom', (_e, on) => this.setBloom(!!on));
    ipcMain.on('overlay:interactive', (_e, on) => {
      if (this.win && !this.win.isDestroyed()) this.win.setIgnoreMouseEvents(!on, { forward: true });
    });
    ipcMain.on('overlay:pick', (_e, id) => { this.setBloom(false); this.onPick(id); });
    ipcMain.handle('overlay:state', () => ({ sessions: this.getSessions(), staleAfter: this.staleAfter() }));
  }

  setEnabled(on) {
    this.enabled = on;
    if (on) this.ensure(); else this.destroy();
  }

  bounds(bloomed) {
    const area = screen.getPrimaryDisplay().workArea;
    const w = bloomed ? PANEL_W + STRIP_W : STRIP_W;
    return { x: area.x + area.width - w, y: area.y, width: w, height: area.height };
  }

  ensure() {
    if (this.win && !this.win.isDestroyed()) return;
    this.win = new BrowserWindow({
      ...this.bounds(false),
      frame: false,
      transparent: true,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      skipTaskbar: true,
      focusable: false,
      alwaysOnTop: true,
      hasShadow: false,
      show: false,
      backgroundColor: '#00000000',
      webPreferences: {
        preload: path.join(__dirname, 'overlay-preload.js'),
        contextIsolation: true,
        sandbox: true,
      },
    });
    this.win.setAlwaysOnTop(true, 'screen-saver');
    this.win.setIgnoreMouseEvents(true, { forward: true });
    this.win.loadFile(path.join(__dirname, '..', 'renderer', 'overlay.html'));
    this.win.once('ready-to-show', () => { if (this.win) this.win.showInactive(); this.refresh(); });
    this.win.on('closed', () => { this.win = null; });
    this._onDisplay = () => this.place();
    screen.on('display-metrics-changed', this._onDisplay);
    screen.on('display-added', this._onDisplay);
    screen.on('display-removed', this._onDisplay);
  }

  place() {
    if (this.win && !this.win.isDestroyed()) this.win.setBounds(this.bounds(this.bloomed));
  }

  setBloom(on) {
    if (this.bloomed === on || !this.win || this.win.isDestroyed()) return;
    this.bloomed = on;
    this.place();
    this.win.webContents.send('overlay:bloomed', on);
  }

  refresh() {
    if (!this.win || this.win.isDestroyed()) return;
    this.win.webContents.send('overlay:sessions', this.getSessions(), this.staleAfter());
  }

  destroy() {
    if (this._onDisplay) {
      screen.removeListener('display-metrics-changed', this._onDisplay);
      screen.removeListener('display-added', this._onDisplay);
      screen.removeListener('display-removed', this._onDisplay);
      this._onDisplay = null;
    }
    if (this.win && !this.win.isDestroyed()) this.win.destroy();
    this.win = null;
    this.bloomed = false;
  }
}

module.exports = { EdgeOverlay };
