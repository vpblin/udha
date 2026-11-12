'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('overlay', {
  state: () => ipcRenderer.invoke('overlay:state'),
  bloom: (on) => ipcRenderer.send('overlay:bloom', on),
  interactive: (on) => ipcRenderer.send('overlay:interactive', on),
  pick: (id) => ipcRenderer.send('overlay:pick', id),
  onSessions: (fn) => ipcRenderer.on('overlay:sessions', (_e, list, staleAfter) => fn(list, staleAfter)),
  onBloomed: (fn) => ipcRenderer.on('overlay:bloomed', (_e, on) => fn(on)),
});
