// Session folders (SessionFolder.swift): named groups on this machine, each
// collapsible and hideable. A session points at one by `folderID`; deleting a
// folder lets its sessions fall back to loose rather than removing them.
'use strict';

const crypto = require('crypto');

class Folders {
  constructor(store, sessions) {
    this.store = store;
    this.sessions = sessions;
  }

  list() { return this.store.config.sessionFolders || []; }

  create(name) {
    const folder = { id: crypto.randomUUID(), name: String(name || 'Folder').trim() || 'Folder', collapsed: false, hidden: false };
    this.store.mutate((c) => { c.sessionFolders = [...(c.sessionFolders || []), folder]; });
    return folder.id;
  }

  update(id, fields) {
    const allowed = {};
    for (const k of ['name', 'collapsed', 'hidden']) if (k in fields) allowed[k] = fields[k];
    if ('name' in allowed) allowed.name = String(allowed.name || '').trim() || 'Folder';
    this.store.mutate((c) => {
      const f = (c.sessionFolders || []).find((x) => x.id === id);
      if (f) Object.assign(f, allowed);
    });
  }

  remove(id) {
    for (const s of this.store.config.sessions) if (s.folderID === id) this.sessions.patch(s.id, { folderID: null });
    this.store.mutate((c) => { c.sessionFolders = (c.sessionFolders || []).filter((f) => f.id !== id); });
  }

  reorder(ids) {
    this.store.mutate((c) => {
      const byId = new Map((c.sessionFolders || []).map((f) => [f.id, f]));
      c.sessionFolders = [...ids.map((i) => byId.get(i)).filter(Boolean), ...(c.sessionFolders || []).filter((f) => !ids.includes(f.id))];
    });
  }

  /** "Unhide all": every hidden session and folder comes back. */
  unhideAll() {
    for (const s of this.store.config.sessions) if (s.hidden) this.sessions.patch(s.id, { hidden: false });
    this.store.mutate((c) => { for (const f of c.sessionFolders || []) f.hidden = false; });
  }

  /** A membership pointing at a folder that no longer exists is dropped (restoreSessions does the same). */
  prune() {
    const known = new Set(this.list().map((f) => f.id));
    for (const s of this.store.config.sessions) {
      if (s.folderID && !known.has(s.folderID)) this.sessions.patch(s.id, { folderID: null });
    }
  }
}

module.exports = { Folders };
