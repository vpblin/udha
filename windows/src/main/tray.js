// The tray icon — the Windows stand-in for the mac menu-bar extra. Lists every
// session with its state (the ones that need you first), raises the window on
// one, and keeps Udha (and so its sessions) alive when the window is closed.
'use strict';

const { Tray, Menu, nativeImage } = require('electron');
const path = require('path');

const ASSETS = path.join(__dirname, '..', 'assets');

const RANK = { awaitingApproval: 0, awaitingReply: 1, thinking: 2, usingTool: 2, starting: 3, idle: 4, finished: 5 };

function label(s) {
  if (s.state !== 'running') return s.state === 'stopped' ? 'Stopped' : 'Exited';
  switch (s.phase) {
    case 'awaitingApproval': return 'Needs you';
    case 'awaitingReply': return 'Ready';
    case 'thinking': return 'Thinking';
    case 'usingTool': return s.phaseDetail || 'Working';
    case 'starting': return 'Starting';
    default: return 'Idle';
  }
}

class UdhaTray {
  constructor({ getSessions, onShow, onNew, onQuit }) {
    this.getSessions = getSessions;
    this.onShow = onShow;
    this.onNew = onNew;
    this.onQuit = onQuit;
    this.icons = {
      normal: nativeImage.createFromPath(path.join(ASSETS, 'tray.png')),
      alert: nativeImage.createFromPath(path.join(ASSETS, 'tray-alert.png')),
    };
    this.tray = new Tray(this.icons.normal);
    this.tray.setToolTip('Udha');
    this.tray.on('click', () => this.onShow());
    this.tray.on('double-click', () => this.onShow());
    this._timer = null;
    this.refresh();
  }

  /** Rebuild soon; snapshots change many times a second while Claude streams. */
  scheduleRefresh() {
    if (this._timer) return;
    this._timer = setTimeout(() => { this._timer = null; this.refresh(); }, 400);
  }

  refresh() {
    if (!this.tray || this.tray.isDestroyed()) return;
    const all = this.getSessions();
    const running = all.filter((s) => s.state === 'running');
    const needs = running.filter((s) => s.phase === 'awaitingApproval');
    const working = running.filter((s) => ['thinking', 'usingTool', 'starting'].includes(s.phase));

    this.tray.setImage(needs.length ? this.icons.alert : this.icons.normal);
    const tip = [`Udha — ${all.length} session${all.length === 1 ? '' : 's'}`];
    if (needs.length) tip.push(`${needs.length} need${needs.length === 1 ? 's' : ''} you`);
    if (working.length) tip.push(`${working.length} working`);
    this.tray.setToolTip(tip.join(' · '));

    const sorted = [...all].sort((a, b) => {
      const ra = a.state === 'running' ? (RANK[a.phase] ?? 6) : 9;
      const rb = b.state === 'running' ? (RANK[b.phase] ?? 6) : 9;
      return ra - rb;
    });
    const items = sorted.slice(0, 15).map((s) => ({
      label: `${s.phase === 'awaitingApproval' && s.state === 'running' ? '● ' : ''}${s.label}  —  ${label(s)}`.slice(0, 80),
      click: () => this.onShow(s.id),
    }));
    const menu = Menu.buildFromTemplate([
      { label: 'Show Udha', click: () => this.onShow(), type: 'normal' },
      { type: 'separator' },
      ...(items.length ? items : [{ label: 'No sessions yet', enabled: false }]),
      { type: 'separator' },
      { label: 'New session…', click: () => this.onNew() },
      ...(this.onLock ? [{ label: 'Lock input', click: () => this.onLock() }] : []),
      { type: 'separator' },
      { label: 'Quit Udha (stops sessions)', click: () => this.onQuit() },
    ]);
    this.tray.setContextMenu(menu);
  }

  destroy() {
    clearTimeout(this._timer);
    if (this.tray && !this.tray.isDestroyed()) this.tray.destroy();
  }
}

module.exports = { UdhaTray };
