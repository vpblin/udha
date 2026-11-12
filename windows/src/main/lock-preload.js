'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('lock', {
  state: () => ipcRenderer.invoke('lock:state'),
  unlock: (pin) => ipcRenderer.invoke('lock:unlock', pin),
  onSessions: (fn) => ipcRenderer.on('lock:sessions', (_e, list) => fn(list)),
});
