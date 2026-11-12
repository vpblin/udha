// Windows toasts + taskbar attention, the Windows side of the mac app's
// attention inbox: a session that needs you, and a turn that finished —
// always when you asked ("Notify when done"), otherwise only while Udha is in
// the background, so a toast never tells you what you're already looking at.
'use strict';

const { Notification } = require('electron');

const WORKING = new Set(['starting', 'thinking', 'usingTool']);

class Notifier {
  /**
   * @param {{ store: import('./config').ConfigStore, getWindow: () => Electron.BrowserWindow|null,
   *           onClick: (id: string) => void }} opts
   */
  constructor({ store, getWindow, onClick }) {
    this.store = store;
    this.getWindow = getWindow;
    this.onClick = onClick;
    this.last = new Map();   // id → { phase, detail }
    this.live = new Set();   // keep references so toasts aren't GC'd before they're clicked
  }

  settings() {
    return { enabled: true, needsYou: true, done: true, ...(this.store.config.notifications || {}) };
  }

  /** Feed every snapshot change through here. */
  observe(snap) {
    const prev = this.last.get(snap.id);
    this.last.set(snap.id, { phase: snap.phase, detail: snap.phaseDetail, state: snap.state });
    if (!prev || snap.state !== 'running') return;
    const s = this.settings();
    const win = this.getWindow();
    const background = !win || win.isDestroyed() || !win.isFocused() || win.isMinimized();

    if (snap.phase === 'awaitingApproval' && (prev.phase !== 'awaitingApproval' || prev.detail !== snap.phaseDetail)) {
      if (s.enabled && s.needsYou && background) {
        this.toast(snap.id, `${snap.label} needs you`, snap.phaseDetail || 'Waiting for approval');
      }
      if (background && win && !win.isDestroyed()) win.flashFrame(true);
      return;
    }

    if (snap.phase === 'awaitingReply' && WORKING.has(prev.phase)) {
      const cfg = this.store.session(snap.id);
      const asked = cfg && cfg.notifyWhenDone;
      if (asked) {
        this.store.mutate(() => { cfg.notifyWhenDone = false; });
        if (this.onCleared) setImmediate(() => this.onCleared(snap.id));
      }
      if (s.enabled && (asked || (s.done && background))) {
        this.toast(snap.id, `${snap.label} is ready`, snap.lastQuestion || 'Turn finished');
      }
    }
  }

  forget(id) { this.last.delete(id); }

  toast(id, title, body) {
    if (!Notification || !Notification.isSupported()) return;
    const n = new Notification({ title, body: String(body || '').slice(0, 240), silent: false });
    this.live.add(n);
    const drop = () => this.live.delete(n);
    n.on('click', () => { drop(); this.onClick(id || undefined); });
    n.on('close', drop);
    n.show();
  }
}

module.exports = { Notifier };
