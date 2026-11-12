'use strict';
/* global Terminal, FitAddon, UdhaPresentation */

const $ = (sel) => document.querySelector(sel);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const state = {
  folders: [],
  sessions: new Map(),   // id → snapshot (ordered by `order`)
  order: [],
  selected: null,
  tab: 'terminal',
  filter: '',
  staleAfter: 1800,
  settings: {},
  configPath: '',
  recentDirs: [],
  hostName: 'This PC',
  renaming: false,
};

// ---------- Sections (nav) ----------
// Sessions is built into this file; other sections register { show } hooks
// from their own scripts and own the board column + pane tagged data-for.

state.section = 'sessions';
state.agents = [];
const sections = {};
function registerSection(name, hooks) { sections[name] = hooks; }
function setSection(name) {
  if (state.section === name) return;
  const prev = sections[state.section];
  if (prev && prev.hide) prev.hide();
  state.section = name;
  document.querySelectorAll('.nav-row[data-section]').forEach((b) => b.classList.toggle('active', b.dataset.section === name));
  document.querySelectorAll('[data-for]').forEach((el) => el.classList.toggle('hidden', el.dataset.for !== name));
  if (name === 'sessions') { renderBoard(); renderPane(true); } else if (sections[name]) sections[name].show();
}
document.querySelectorAll('.nav-row[data-section]').forEach((b) => { b.onclick = () => setSection(b.dataset.section); });

// ---------- Theme ----------

const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
function applyTheme() {
  document.documentElement.dataset.dark = darkQuery.matches ? '1' : '0';
  document.documentElement.dataset.accent = (state.settings.appearance && state.settings.appearance.accent) || 'blue';
  applyTerminalAppearance();
}
darkQuery.addEventListener('change', applyTheme);

function cssVar(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

/** The selected terminal theme, resolved for the current light/dark mode and font size. */
function terminalLook() {
  const t = state.settings.terminal || {};
  return TerminalThemes.resolve(t.theme || 'udha', { dark: darkQuery.matches, fontSize: t.fontSize || 13 });
}

/** Push the theme into xterm and paint the card around it in the same colours. */
function applyTerminalAppearance() {
  const look = terminalLook();
  const rootStyle = document.documentElement.style;
  rootStyle.setProperty('--term-bg', look.colors.background);
  rootStyle.setProperty('--term-fg', look.colors.foreground);
  rootStyle.setProperty('--term-pad', look.padding != null ? `${look.padding}px` : '');
  document.documentElement.dataset.termTheme = look.id;
  if (!term) return;
  term.options.theme = look.colors;
  for (const [k, v] of Object.entries(look.options)) term.options[k] = v;
  fitTerminal();
}

// ---------- Terminal (one xterm, re-pointed at the selected session) ----------

let term = null;
let fit = null;
let termSession = null;
let resizeObs = null;

function ensureTerminal(host) {
  if (!term) {
    const look = terminalLook();
    term = new Terminal({
      ...look.options,
      scrollback: 10000,
      allowProposedApi: true,
      theme: look.colors,
    });
    fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.onData((d) => { if (termSession) window.udha.write(termSession, d); });
    term.attachCustomKeyEventHandler((e) => {
      // Ctrl+C copies when there is a selection; Ctrl+V pastes. Otherwise keys go to the session.
      if (e.type !== 'keydown') return true;
      if (e.ctrlKey && !e.shiftKey && e.key.toLowerCase() === 'c' && term.hasSelection()) {
        navigator.clipboard.writeText(term.getSelection()); term.clearSelection(); return false;
      }
      if (e.ctrlKey && e.key.toLowerCase() === 'v') {
        const id = termSession;
        navigator.clipboard.readText().then(async (t) => {
          if (!id) return;
          if (t) { term.paste(t); return; }
          // No text: a screenshot on the clipboard becomes a file path.
          const p = await window.udha.pasteImage(id);
          if (p && termSession === id) term.paste(quotePath(p) + ' ');
        });
        e.preventDefault();
        return false;
      }
      if (e.ctrlKey && (e.key.toLowerCase() === 'k' || e.key.toLowerCase() === 'n')) return false;
      return true;
    });
  }
  if (term.element && term.element.parentElement !== host) {
    host.appendChild(term.element);
  } else if (!term.element) {
    term.open(host);
  }
  if (resizeObs) resizeObs.disconnect();
  resizeObs = new ResizeObserver(() => fitTerminal());
  resizeObs.observe(host);
}

function fitTerminal() {
  if (!term || !fit || !term.element || !term.element.isConnected) return;
  try {
    fit.fit();
    if (termSession) window.udha.resize(termSession, term.cols, term.rows);
  } catch { /* hidden */ }
}

async function attachTerminal(id) {
  if (termSession === id) { fitTerminal(); return; }
  termSession = id;
  term.reset();
  const buf = await window.udha.buffer(id);
  if (termSession !== id) return;
  term.write(buf);
  fitTerminal();
  term.focus();
}

window.udha.onData((id, data) => {
  if (term && id === termSession) term.write(data);
});

// ---------- Board ----------

function ordered() {
  return state.order.map((id) => state.sessions.get(id)).filter(Boolean);
}

function pingHTML(st, size = 6) {
  return `<span class="ping ${st.filled ? '' : 'hollow'} ${st.pulses ? 'active' : ''}" style="--dot:${st.dot};width:${size}px;height:${size}px"></span>`;
}
function dotsHTML(st) { return st.live ? `<span class="dots" style="--dot:${st.dot}"><i></i><i></i><i></i></span>` : ''; }
function chipHTML(st) {
  return `<span class="chip" style="--tint:${st.tint};--ink:${st.ink}">${pingHTML(st)}<span>${esc(st.label)}</span>${dotsHTML(st)}</span>`;
}
/** A friendly name for a plain command: "Git Bash" rather than its full path. */
function commandName(cmd) {
  if (/\\git\\(usr\\)?bin\\bash(\.exe)?$/i.test(cmd || '') || /git-bash(\.exe)?$/i.test(cmd || '')) return 'Git Bash';
  return cmd;
}
function rightLabel(s) {
  if (s.model) return s.model;
  if (!s.tool) return commandName(s.command);
  if (s.tool === 'codex') return 'ChatGPT';
  if (s.tool === 'qwen') return 'Qwen';
  if (!s.tool) return s.command;
  return '';
}

function cardHTML(s) {
  const st = UdhaPresentation.style(s, state.staleAfter);
  const cls = ['card-row', s.id === state.selected ? 'selected' : '', st.wantsYou ? 'wants' : ''].join(' ');
  return `<div class="${cls}" data-id="${s.id}" draggable="true">
    <div class="card-top">
      <span class="card-name">${esc(s.label)}</span>
      ${s.agentName ? `<span class="agent-mark" title="Agent run: ${esc(s.agentName)}">✦</span>` : ''}
      <span class="card-spacer"></span>
      <span class="card-model">${esc(rightLabel(s))}</span>
    </div>
    <div class="card-state">${pingHTML(st)}<span class="card-state-label" style="color:${st.ink}">${esc(st.label)}</span>${dotsHTML(st)}</div>
    <div class="card-detail">${esc(st.detail || '')}</div>
  </div>`;
}

function folderHeaderHTML(folder, members) {
  const needs = members.some((s) => UdhaPresentation.style(s, state.staleAfter).wantsYou);
  const working = members.some((s) => s.state === 'running' && ['thinking', 'usingTool', 'starting'].includes(s.phase));
  const dot = needs ? 'var(--bad)' : working ? 'var(--accent)' : null;
  return `<div class="folder-head ${folder.collapsed ? 'collapsed' : ''}" data-folder="${folder.id}">
    <svg class="chev" viewBox="0 0 16 16" width="10" height="10"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>
    <svg viewBox="0 0 16 16" width="13" height="13" class="ficon"><path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.8l1.4 1.5h4.8A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>
    <span class="fname">${esc(folder.name)}</span>
    ${dot ? `<span class="ping ${needs ? 'active' : ''}" style="--dot:${dot}"></span>` : ''}
    <span class="fcount">${members.length}</span>
  </div>`;
}

function renderBoard() {
  const list = $('#list');
  const f = state.filter.toLowerCase();
  const match = (s) => !f || s.label.toLowerCase().includes(f) || s.directory.toLowerCase().includes(f);
  const all = ordered();
  $('#boardCount').textContent = all.length ? String(all.length) : '';
  $('#navCount').textContent = all.length ? String(all.length) : '';

  const known = new Set(state.folders.map((x) => x.id));
  const hiddenFolders = new Set(state.folders.filter((x) => x.hidden).map((x) => x.id));
  const shown = all.filter((s) => !s.hidden && !(s.folderID && hiddenFolders.has(s.folderID)) && match(s));
  const hiddenCount = all.filter((s) => s.hidden).length + hiddenFolders.size;

  let html = '';
  for (const folder of state.folders) {
    if (folder.hidden) continue;
    const members = shown.filter((s) => s.folderID === folder.id);
    if (f && !members.length) continue;
    html += `<div class="folder">${folderHeaderHTML(folder, members)}`;
    if (!folder.collapsed || f) {
      html += `<div class="folder-body">${members.map(cardHTML).join('') || '<div class="folder-empty">Drag sessions here</div>'}</div>`;
    }
    html += '</div>';
  }
  html += shown.filter((s) => !s.folderID || !known.has(s.folderID)).map(cardHTML).join('');
  if (!html) {
    html = `<div class="board-empty">${all.length ? (f ? 'No session matches.' : 'Every session is hidden.') : 'No sessions yet.<br>Press <b>New</b> to start one.'}</div>`;
  }
  if (hiddenCount && !f) {
    html += `<div class="board-hidden">${hiddenCount} hidden · <button class="link" id="unhideAll">Unhide all</button></div>`;
  }
  list.innerHTML = html;
  if ($('#unhideAll')) $('#unhideAll').onclick = () => window.udha.unhideAll();
}

$('#list').addEventListener('click', (e) => {
  const head = e.target.closest('.folder-head');
  if (head) {
    const folder = state.folders.find((x) => x.id === head.dataset.folder);
    if (folder) { folder.collapsed = !folder.collapsed; window.udha.updateFolder(folder.id, { collapsed: folder.collapsed }); renderBoard(); }
    return;
  }
  const row = e.target.closest('.card-row');
  if (row) select(row.dataset.id);
});
$('#list').addEventListener('dblclick', (e) => {
  const row = e.target.closest('.card-row');
  if (row) { select(row.dataset.id); beginRename(); }
});

// Right-click: the board's context menus.
$('#list').addEventListener('contextmenu', async (e) => {
  const head = e.target.closest('.folder-head');
  const row = e.target.closest('.card-row');
  if (head) {
    e.preventDefault();
    const folder = state.folders.find((x) => x.id === head.dataset.folder);
    if (!folder) return;
    const choice = await window.udha.contextMenu([
      { id: 'rename', label: 'Rename folder…' },
      { id: 'hide', label: 'Hide folder' },
      { type: 'separator' },
      { id: 'delete', label: 'Delete folder (keeps its sessions)' },
    ]);
    if (choice === 'rename') {
      const name = await askText('Rename folder', folder.name, 'Rename');
      if (name) window.udha.updateFolder(folder.id, { name });
    } else if (choice === 'hide') window.udha.updateFolder(folder.id, { hidden: true });
    else if (choice === 'delete') window.udha.removeFolder(folder.id);
    return;
  }
  if (row) {
    e.preventDefault();
    sessionMenu(state.sessions.get(row.dataset.id));
    return;
  }
  e.preventDefault();
  const choice = await window.udha.contextMenu([
    { id: 'new-session', label: 'New session…' },
    { id: 'new-folder', label: 'New folder…' },
  ]);
  if (choice === 'new-session') openNewSheet();
  if (choice === 'new-folder') {
    const name = await askText('New folder', '', 'Create');
    if (name) window.udha.createFolder(name);
  }
});

async function sessionMenu(s) {
  if (!s) return;
  const running = s.state === 'running';
  const items = [
    { id: 'rename', label: 'Rename' },
    { id: 'duplicate', label: 'Duplicate' },
    s.tool === 'claude' && state.logins && state.logins.length > 1 ? {
      label: 'Claude login',
      submenu: state.logins.map((l) => ({
        id: `login:${l.isDefault ? '' : l.configDir}`,
        label: `${l.name}${l.email ? ` — ${l.email}` : ''}${l.limited ? ' (at limit)' : ''}`,
        checked: loginOf(s) === l,
        enabled: l.signedIn,
      })),
    } : null,
    s.tool === 'claude' ? {
      label: 'Permissions',
      submenu: PERMS.map(([v, n]) => ({ id: `perm:${v}`, label: n, checked: (s.permission || 'default') === v })),
    } : null,
    { type: 'separator' },
    running ? { id: 'restart', label: 'Restart' } : { id: 'start', label: s.tool === 'claude' && s.claudeSessionID ? 'Resume' : 'Start' },
    running ? { id: 'stop', label: 'Stop' } : null,
    running && s.tool === 'claude' ? { id: 'notify', label: 'Notify when done', checked: !!s.notifyWhenDone } : null,
    { type: 'separator' },
    {
      label: 'Move to folder',
      submenu: [
        ...state.folders.map((f) => ({ id: `folder:${f.id}`, label: f.name, checked: s.folderID === f.id })),
        ...(state.folders.length ? [{ type: 'separator' }] : []),
        { id: 'folder:new', label: 'New folder…' },
        ...(s.folderID ? [{ id: 'folder:none', label: 'Remove from folder' }] : []),
      ],
    },
    { id: 'hide', label: 'Hide' },
    state.agents.length ? {
      label: 'Run agent here',
      submenu: state.agents.map((a) => ({ id: `agent:${a.slug}`, label: a.name })),
    } : null,
    { type: 'separator' },
    { id: 'open-folder', label: 'Open folder' },
    { id: 'open-terminal', label: 'Open in Terminal' },
    { type: 'separator' },
    { id: 'remove', label: 'Remove…' },
  ].filter(Boolean);
  const choice = await window.udha.contextMenu(items);
  if (!choice) return;
  if (choice === 'rename') { select(s.id); setTimeout(beginRename, 0); }
  else if (choice === 'duplicate') duplicateSession(s.id);
  else if (choice.startsWith('agent:')) runAgent(choice.slice(6), { sourceSessionID: s.id });
  else if (choice.startsWith('login:')) window.udha.usage.moveSession(s.id, choice.slice(6) || null);
  else if (choice.startsWith('perm:')) changePermission(s, choice.slice(5));
  else if (choice === 'restart') window.udha.restart(s.id);
  else if (choice === 'start') window.udha.start(s.id);
  else if (choice === 'stop') window.udha.stop(s.id);
  else if (choice === 'notify') window.udha.notifyWhenDone(s.id, !s.notifyWhenDone);
  else if (choice === 'hide') window.udha.setHidden(s.id, true);
  else if (choice === 'open-folder') window.udha.openFolder(s.directory);
  else if (choice === 'open-terminal') window.udha.openInTerminal(s.id);
  else if (choice === 'remove') confirmRemove(s);
  else if (choice === 'folder:none') window.udha.setFolder(s.id, null);
  else if (choice === 'folder:new') {
    const name = await askText('New folder', '', 'Create');
    if (name) window.udha.createFolder(name, s.id);
  } else if (choice.startsWith('folder:')) window.udha.setFolder(s.id, choice.slice(7));
}

// Drag to reorder, onto a folder to file it, or next to a loose card to unfile it.
let dragID = null;
$('#list').addEventListener('dragstart', (e) => {
  const row = e.target.closest('.card-row'); if (!row) return;
  dragID = row.dataset.id; row.classList.add('dragging');
  e.dataTransfer.effectAllowed = 'move';
});
$('#list').addEventListener('dragover', (e) => {
  if (!dragID) return;
  e.preventDefault();
  document.querySelectorAll('.drop-target').forEach((n) => n.classList.remove('drop-target'));
  const target = e.target.closest('.card-row, .folder-head, .folder-empty');
  if (target && target.dataset.id !== dragID) target.classList.add('drop-target');
});
$('#list').addEventListener('drop', (e) => {
  e.preventDefault();
  const s = state.sessions.get(dragID);
  const head = e.target.closest('.folder-head');
  const empty = e.target.closest('.folder-empty');
  const row = e.target.closest('.card-row');
  if (s && (head || empty)) {
    const folderID = head ? head.dataset.folder : empty.closest('.folder').querySelector('.folder-head').dataset.folder;
    s.folderID = folderID;
    window.udha.setFolder(s.id, folderID);
  } else if (s && row && row.dataset.id !== dragID) {
    const target = state.sessions.get(row.dataset.id);
    if (target && (target.folderID || null) !== (s.folderID || null)) {
      s.folderID = target.folderID || null;
      window.udha.setFolder(s.id, s.folderID);
    }
    const ids = state.order.filter((i) => i !== dragID);
    ids.splice(ids.indexOf(row.dataset.id), 0, dragID);
    state.order = ids;
    window.udha.reorder(ids);
  }
  dragID = null; renderBoard();
});
$('#list').addEventListener('dragend', () => { dragID = null; renderBoard(); });

window.udha.onFolders((list) => { state.folders = list; renderBoard(); });

async function duplicateSession(id) {
  const newID = await window.udha.duplicate(id);
  if (newID) { state.selected = null; select(newID); }
}

function changePermission(s, mode) {
  if ((s.permission || 'default') === mode) return;
  const apply = () => window.udha.setPermission(s.id, mode);
  if (mode === 'bypass') {
    openSheet('#settingsSheet', `
      <h2>Bypass permissions?</h2>
      <p class="lede">Claude will run every command and edit every file in <span class="mono">${esc(s.directory)}</span> without asking.${s.state === 'running' ? ' The session restarts and resumes its conversation.' : ''}</p>
      <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="permOK">Bypass permissions</button></div>`);
    $('#permOK').onclick = () => { apply(); closeSheets(); };
  } else {
    apply();
  }
}

/** A one-field sheet; resolves to the text, or null on cancel. */
function askText(title, value, action) {
  return new Promise((resolve) => {
    openSheet('#settingsSheet', `
      <h2>${esc(title)}</h2>
      <div class="field" style="margin-top:12px"><input class="input" id="askInput" value="${esc(value)}" spellcheck="false"></div>
      <div class="sheet-actions"><button class="btn" id="askCancel">Cancel</button><button class="btn primary" id="askOK">${esc(action)}</button></div>`);
    const input = $('#askInput');
    input.focus(); input.select();
    const done = (v) => { closeSheets(); resolve(v); };
    $('#askOK').onclick = () => done(input.value.trim() || null);
    $('#askCancel').onclick = () => done(null);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') done(input.value.trim() || null); });
  });
}

$('#filter').addEventListener('input', (e) => { state.filter = e.target.value; renderBoard(); });

// ---------- Detail pane ----------

let paneSkeletonFor = null;

function select(id) {
  if (state.section !== 'sessions') { state.selected = id; window.udha.select(id); setSection('sessions'); return; }
  if (state.selected === id) return;
  state.selected = id;
  state.renaming = false;
  window.udha.select(id);
  renderBoard();
  renderPane(true);
}

function renderPane(full = false) {
  const pane = $('#pane');
  const s = state.sessions.get(state.selected);
  if (!s) {
    paneSkeletonFor = null;
    termSession = null;
    pane.innerHTML = `<div class="empty">
      <div class="title">Nothing supervised yet</div>
      <div class="text">Start a session and Udha watches it — the state, the tool it's on, and the moment it needs you. Sessions are saved on this PC and come back when you reopen Udha.</div>
      <button class="btn primary" id="emptyNew">New session</button>
    </div>`;
    $('#emptyNew').onclick = openNewSheet;
    return;
  }
  const key = `${s.id}|${state.tab}`;
  if (full || paneSkeletonFor !== key) {
    paneSkeletonFor = key;
    pane.innerHTML = `
      <div class="pane-head">
        <div class="pane-title-wrap">
          <div id="titleSlot"></div>
          <div class="pane-sub" id="sub"></div>
        </div>
        <div class="pane-actions">
          <div class="segmented">
            <button data-tab="terminal" class="${state.tab === 'terminal' ? 'on' : ''}">Terminal</button>
            <button data-tab="details" class="${state.tab === 'details' ? 'on' : ''}">Details</button>
          </div>
          <span id="lifeBtns" class="pane-actions"></span>
        </div>
      </div>
      <div class="card running-on" id="runningOn"></div>
      <div id="waitingSlot"></div>
      ${state.tab === 'terminal'
        ? `<div class="card terminal-card"><div class="terminal-host" id="termHost"></div><div id="termOverlay"></div></div>`
        : `<div class="details-scroll"><div class="card facts" id="facts"></div></div>
           <div class="card sendbox"><div class="chips" id="chips"></div><div class="sendrow"><textarea id="draft" rows="1" placeholder="Message ${esc(s.label)}…  (Enter to send, Shift+Enter for a new line, drop or paste files)"></textarea><button class="btn primary" id="sendBtn">Send</button></div></div>`}
    `;
    pane.querySelectorAll('.segmented button').forEach((b) => {
      b.onclick = () => { state.tab = b.dataset.tab; renderPane(true); };
    });
    if (state.tab === 'terminal') {
      ensureTerminal($('#termHost'));
      termSession = null;
      attachTerminal(s.id);
    } else {
      termSession = null;
      const draft = $('#draft');
      draft.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendDraft(); }
      });
      draft.addEventListener('input', () => { draft.style.height = 'auto'; draft.style.height = Math.min(draft.scrollHeight, 160) + 'px'; });
      draft.addEventListener('paste', async (e) => {
        const hasImage = [...(e.clipboardData ? e.clipboardData.items : [])].some((i) => i.type.startsWith('image/'));
        if (!hasImage) return;
        e.preventDefault();
        const p = await window.udha.pasteImage(s.id);
        if (p) stageAttachments(s.id, [p]);
      });
      $('#sendBtn').onclick = sendDraft;
      renderChips();
    }
  }
  updatePane(s);
}

function updatePane(s) {
  const st = UdhaPresentation.style(s, state.staleAfter);
  const running = s.state === 'running';

  if (!state.renaming) {
    $('#titleSlot').innerHTML = `<div class="pane-title" id="title" title="Double-click to rename">${esc(s.label)}</div>`;
    $('#title').ondblclick = beginRename;
  }
  const subHTML = `${chipHTML(st)}${s.tool === 'claude'
    ? `<select class="mini-select ${s.permission === 'bypass' ? 'danger' : ''}" id="permSelect" title="Permission mode${running ? ' — changing it restarts the session and resumes the conversation' : ''}">
        ${PERMS.map(([v, n]) => `<option value="${v}" ${(s.permission || 'default') === v ? 'selected' : ''}>${n}</option>`).join('')}
      </select>` : ''}<span class="mono" title="${esc(s.directory)}">${esc(s.directory)}</span>`;
  // Only redraw when it changed: rebuilding the <select> would close it while it's open.
  const sub = $('#sub');
  if (sub.dataset.html !== subHTML) { sub.innerHTML = subHTML; sub.dataset.html = subHTML; }
  if ($('#permSelect')) {
    $('#permSelect').onchange = (e) => {
      const mode = e.target.value;
      e.target.value = s.permission || 'default';
      changePermission(s, mode);
    };
  }

  $('#lifeBtns').innerHTML = `
    ${running
      ? `<button class="btn" id="restartBtn" title="Restart (resumes the conversation)">Restart</button>
         <button class="btn" id="stopBtn">Stop</button>`
      : `<button class="btn primary" id="startBtn">${s.claudeSessionID && s.tool === 'claude' ? 'Resume' : 'Start'}</button>`}
    <button class="btn bare" id="dupBtn" title="Duplicate — a new session in the same folder">
      <svg viewBox="0 0 16 16"><rect x="5" y="5" width="8.5" height="8.5" rx="1.8" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M11 5V3.8A1.3 1.3 0 0 0 9.7 2.5H3.8A1.3 1.3 0 0 0 2.5 3.8v5.9A1.3 1.3 0 0 0 3.8 11H5" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>
    </button>
    <button class="btn bare" id="moreBtn" title="Remove session">
      <svg viewBox="0 0 16 16"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>
    </button>`;
  if (running) {
    $('#restartBtn').onclick = () => window.udha.restart(s.id);
    $('#stopBtn').onclick = () => window.udha.stop(s.id);
  } else {
    $('#startBtn').onclick = () => window.udha.start(s.id);
  }
  $('#moreBtn').onclick = () => confirmRemove(s);
  $('#dupBtn').onclick = () => duplicateSession(s.id);

  const tool = s.tool === 'claude' ? 'Claude' : s.tool === 'codex' ? 'ChatGPT' : s.tool === 'qwen' ? 'Qwen' : commandName(s.command);
  $('#runningOn').innerHTML = `
    <span class="eyebrow">Running on</span>
    <span class="live-dot" style="${running ? '' : 'background:var(--tertiary);box-shadow:none'}"></span>
    <span class="host">${esc(state.hostName)}</span>
    ${s.branch ? `<span class="branch-tag" title="${s.worktree ? 'Worktree on branch' : 'Branch'} ${esc(s.branch)}"><svg viewBox="0 0 16 16" width="11" height="11"><circle cx="4.5" cy="3.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="4.5" cy="12.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="11.5" cy="5.5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M4.5 5.1v5.8M11.5 7.1c0 2.4-2 3-7 3.6" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>${esc(s.branch)}${s.worktree ? ' <i>worktree</i>' : ''}</span>` : ''}
    <span style="color:var(--secondary)">· ${esc(tool)}${s.model ? ' · ' + esc(s.model) : ''}${s.tool === 'claude' && typeof loginOf === 'function' && state.logins && state.logins.length > 1 && loginOf(s) ? ' · ' + esc(loginOf(s).name) : ''}${s.contextPercent != null ? ' · ctx ' + s.contextPercent + '%' : ''}${s.costCents != null ? ' · $' + (s.costCents / 100).toFixed(2) : ''}</span>
    <span class="spacer"></span>
    ${running && s.tool === 'claude' ? `<button class="link bell ${s.notifyWhenDone ? 'on' : ''}" id="notifyBtn" title="Send a Windows notification when this turn finishes">
      <svg viewBox="0 0 16 16" width="12" height="12"><path d="M8 2.2a3.6 3.6 0 0 0-3.6 3.6v2.6L3 10.6h10l-1.4-2.2V5.8A3.6 3.6 0 0 0 8 2.2zM6.5 12.4a1.5 1.5 0 0 0 3 0" fill="${s.notifyWhenDone ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>
      ${s.notifyWhenDone ? 'Will notify when done' : 'Notify when done'}</button>` : ''}
    <button class="link" id="openFolder">Open folder</button>
    <button class="link" id="openTerm">Open in Terminal</button>`;
  $('#openFolder').onclick = () => window.udha.openFolder(s.directory);
  if ($('#notifyBtn')) $('#notifyBtn').onclick = () => window.udha.notifyWhenDone(s.id, !s.notifyWhenDone);
  $('#openTerm').onclick = () => window.udha.openInTerminal(s.id);

  const slot = $('#waitingSlot');
  if (st.wantsYou && running) {
    slot.innerHTML = `<div class="waiting">
      <div class="eyebrow"><span class="ping active" style="--dot:var(--bad)"></span>Waiting on you</div>
      <div class="text">${esc(st.detail || 'The session is asking for permission.')}</div>
      ${state.tab === 'details' ? `<div class="actions"><button class="btn primary sm" data-key="1">Allow</button><button class="btn sm" data-key="2">Allow for session</button><button class="btn danger sm" data-key="esc">Deny</button></div>` : ''}
    </div>`;
    slot.querySelectorAll('[data-key]').forEach((b) => {
      b.onclick = () => window.udha.write(s.id, b.dataset.key === 'esc' ? '\x1b' : b.dataset.key);
    });
  } else {
    slot.innerHTML = '';
  }

  if (state.tab === 'terminal') {
    const overlay = $('#termOverlay');
    if (!running) {
      overlay.innerHTML = `<div class="terminal-overlay">
        <div class="title">${s.state === 'stopped' ? 'Session saved' : 'Session ended'}</div>
        <div class="text">${s.tool === 'claude' && s.claudeSessionID
          ? 'Its Claude conversation is kept. Resume picks it up where it stopped.'
          : 'Start runs the command again in the same folder.'}</div>
        <button class="btn primary" id="overlayStart">${s.tool === 'claude' && s.claudeSessionID ? 'Resume' : 'Start'}</button>
      </div>`;
      $('#overlayStart').onclick = () => window.udha.start(s.id);
    } else {
      overlay.innerHTML = '';
    }
  } else {
    const facts = [
      ['State', `${st.label}${s.state === 'running' ? '' : ` (${s.state})`}`],
      ['Folder', s.directory, true],
      ['Branch', s.branch ? `${s.branch}${s.worktree ? ' (own worktree)' : ''}` : '—', true],
      ['Command', s.command, true],
      ['Assistant', s.tool ? tool : 'Shell command'],
      ['Model', s.model || '—'],
      ['Context used', s.contextPercent != null ? `${s.contextPercent}%` : '—'],
      ['Spend', s.costCents != null ? `$${(s.costCents / 100).toFixed(2)}` : '—'],
      ['Claude session', s.claudeSessionID || '—', true],
      ['Last line', s.lastQuestion || '—'],
      ['Started', s.startedAt ? new Date(s.startedAt).toLocaleString() : '—'],
    ];
    $('#facts').innerHTML = facts.map(([k, v, mono]) => `<div class="fact"><span class="k">${esc(k)}</span><span class="v ${mono ? 'mono' : ''}">${esc(v)}</span></div>`).join('');
    $('#sendBtn').disabled = !running;
  }
}

function sendDraft() {
  const draft = $('#draft');
  const id = state.selected;
  const files = attachments.get(id) || [];
  const text = [draft.value.trim(), files.map(quotePath).join(' ')].filter(Boolean).join(' ');
  if (!text || !id) return;
  window.udha.send(id, text);
  attachments.delete(id);
  renderChips();
  draft.value = '';
  draft.style.height = 'auto';
}

// ---------- Attachments ----------
// A pty can't be handed bytes, so a file is a path the assistant reads. Dropped
// on the terminal it is typed straight in; on Details it's staged as a chip and
// goes out with the next message.

const attachments = new Map();   // session id → [paths]

function quotePath(p) { return /[\s&()^%!;,']/.test(p) ? `"${p}"` : p; }

function stageAttachments(id, paths) {
  const list = attachments.get(id) || [];
  for (const p of paths) if (!list.includes(p)) list.push(p);
  attachments.set(id, list);
  renderChips();
}

function renderChips() {
  const box = $('#chips');
  if (!box) return;
  const list = attachments.get(state.selected) || [];
  box.innerHTML = list.map((p, i) => `<span class="att-chip" title="${esc(p)}">
    <svg viewBox="0 0 16 16" width="11" height="11"><path d="M10.5 4.5 5.8 9.2a1.5 1.5 0 0 0 2.1 2.1l5-5a2.8 2.8 0 0 0-4-4l-5 5a4 4 0 0 0 5.7 5.7l3.6-3.6" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>
    ${esc(p.split(/[\\/]/).pop())}<button data-i="${i}" title="Remove">×</button></span>`).join('');
  box.classList.toggle('hidden', !list.length);
  box.querySelectorAll('button').forEach((b) => {
    b.onclick = () => { list.splice(Number(b.dataset.i), 1); renderChips(); };
  });
}

async function pathsFromDrop(dt, id) {
  const out = [];
  for (const file of dt.files) {
    const p = window.udha.pathForFile(file);
    if (p) out.push(p);
    else out.push(await window.udha.saveAttachment(id, file.name, new Uint8Array(await file.arrayBuffer())));
  }
  return out.filter(Boolean);
}

// A file dropped anywhere else must not navigate the window to it.
document.addEventListener('dragover', (e) => { if (e.dataTransfer && e.dataTransfer.types.includes('Files')) e.preventDefault(); });
document.addEventListener('drop', (e) => { if (e.dataTransfer && e.dataTransfer.files.length) e.preventDefault(); });

const paneEl = $('#pane');
paneEl.addEventListener('dragover', (e) => {
  if (dragID || !state.selected || !e.dataTransfer.types.includes('Files')) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
  paneEl.classList.add('drop-on');
});
paneEl.addEventListener('dragleave', (e) => {
  if (!paneEl.contains(e.relatedTarget)) paneEl.classList.remove('drop-on');
});
paneEl.addEventListener('drop', async (e) => {
  paneEl.classList.remove('drop-on');
  if (dragID || !state.selected || !e.dataTransfer.files.length) return;
  e.preventDefault();
  const id = state.selected;
  const s = state.sessions.get(id);
  const paths = await pathsFromDrop(e.dataTransfer, id);
  if (!paths.length) return;
  if (state.tab === 'terminal' && s && s.state === 'running') {
    window.udha.write(id, paths.map(quotePath).join(' ') + ' ');
    if (term) term.focus();
  } else {
    stageAttachments(id, paths);
  }
});

function beginRename() {
  const s = state.sessions.get(state.selected);
  if (!s || !$('#titleSlot')) return;
  state.renaming = true;
  $('#titleSlot').innerHTML = `<input class="pane-title-input" id="renameInput" value="${esc(s.label)}" spellcheck="false">`;
  const input = $('#renameInput');
  input.focus(); input.select();
  const finish = (commit) => {
    if (!state.renaming) return;
    state.renaming = false;
    if (commit && input.value.trim() && input.value.trim() !== s.label) window.udha.rename(s.id, input.value.trim());
    renderPane();
  };
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') finish(true);
    if (e.key === 'Escape') finish(false);
  });
  input.addEventListener('blur', () => finish(true));
}

function confirmRemove(s) {
  openSheet('#settingsSheet', `
    <h2>Remove “${esc(s.label)}”?</h2>
    <p class="lede">${s.state === 'running' ? 'The session is stopped and ' : ''}it is taken off the board. Claude's own transcript stays on disk, so nothing in the conversation is deleted.</p>
    ${s.worktree ? `<div class="switch-row"><div class="t"><b>Also delete its worktree</b><span class="mono">${esc(s.directory)}</span><span>The branch <b>${esc(s.branch || '')}</b> is kept. Git refuses if there are uncommitted changes.</span></div><input type="checkbox" class="switch" id="rmWorktree"></div>` : ''}
    <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="confirmRemove">Remove</button></div>`);
  $('#confirmRemove').onclick = async () => {
    const deleteWorktree = !!($('#rmWorktree') && $('#rmWorktree').checked);
    closeSheets();
    const r = await window.udha.remove(s.id, { deleteWorktree });
    if (r && !r.ok) {
      openSheet('#settingsSheet', `
        <h2>Worktree kept</h2>
        <p class="lede">Git wouldn't remove <span class="mono">${esc(r.worktree)}</span>: ${esc(r.error)}</p>
        <div class="sheet-actions"><button class="btn" data-close>Keep it</button><button class="btn danger" id="forceWt">Delete anyway (discards changes)</button></div>`);
      $('#forceWt').onclick = async () => {
        const r2 = await window.udha.removeWorktree(r.worktree, true);
        closeSheets();
        if (r2 && !r2.ok) openSheet('#settingsSheet', `<h2>Couldn't delete the worktree</h2><p class="lede">${esc(r2.error)}</p><div class="sheet-actions"><button class="btn primary" data-close>OK</button></div>`);
      };
    }
  };
}

// ---------- Status bar ----------

function renderStatusBar() {
  const all = ordered();
  const running = all.filter((s) => s.state === 'running');
  const working = running.filter((s) => s.phase === 'thinking' || s.phase === 'usingTool' || s.phase === 'starting').length;
  const needs = running.filter((s) => s.phase === 'awaitingApproval').length;
  const parts = [`${all.length} session${all.length === 1 ? '' : 's'}`, `${running.length} running`];
  if (working) parts.push(`${working} working`);
  let html = parts.map(esc).join(' <span class="sep">·</span> ');
  if (needs) html += ` <span class="sep">·</span> <span class="needs">${needs} need${needs === 1 ? 's' : ''} you</span>`;
  $('#statusSummary').innerHTML = html;
  document.title = needs ? `(${needs}) Udha` : 'Udha';
  updateBadge(needs);
}

/** Taskbar overlay: a red count badge while anything needs you. */
let lastBadge = -1;
function updateBadge(count) {
  if (count === lastBadge) return;
  lastBadge = count;
  if (!count) { window.udha.badge(0, null); return; }
  const c = document.createElement('canvas');
  c.width = c.height = 32;
  const g = c.getContext('2d');
  g.fillStyle = '#CF2A20';
  g.beginPath(); g.arc(16, 16, 15, 0, Math.PI * 2); g.fill();
  g.fillStyle = '#fff';
  g.font = `bold ${count > 9 ? 16 : 20}px "Segoe UI", sans-serif`;
  g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillText(count > 9 ? '9+' : String(count), 16, 17);
  window.udha.badge(count, c.toDataURL('image/png'));
}

window.udha.onSelect((id) => { if (state.sessions.has(id)) { closeSheets(); select(id); } });
window.udha.onOpenNew(() => openNewSheet());

// Input lock: needs a PIN first.
async function setLockPinSheet(thenLock) {
  const pin = await askText(thenLock ? 'Choose an unlock PIN (4–12 digits)' : 'New unlock PIN (4–12 digits)', '', thenLock ? 'Save and lock' : 'Save');
  if (!pin) return;
  try {
    await window.udha.setLockPin(pin);
    state.settings.hasLockPin = true;
    if (thenLock) window.udha.lockInput();
  } catch (err) {
    openSheet('#settingsSheet', `<h2>PIN not saved</h2><p class="lede">${esc(String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''))}</p><div class="sheet-actions"><button class="btn primary" data-close>OK</button></div>`);
  }
}
$('#lockBtn').onclick = () => (state.settings.hasLockPin ? window.udha.lockInput() : setLockPinSheet(true));
window.udha.onLockNeedPin(() => setLockPinSheet(true));

$('#configLink').onclick = () => window.udha.revealConfig();

// ---------- Sheets ----------

function openSheet(sel, html) {
  closeSheets();
  const sheet = $(sel);
  sheet.innerHTML = html;
  sheet.classList.remove('hidden');
  $('#scrim').classList.remove('hidden');
  sheet.querySelectorAll('[data-close]').forEach((b) => { b.onclick = closeSheets; });
}
function closeSheets() {
  ['#newSheet', '#settingsSheet', '#palette', '#scrim'].forEach((s) => $(s).classList.add('hidden'));
}
$('#scrim').onclick = closeSheets;

const TOOLS = [
  { id: 'claude', name: 'Claude', sub: 'Claude Code', command: 'claude' },
  { id: 'codex', name: 'ChatGPT', sub: 'Codex CLI', command: 'codex' },
  { id: 'qwen', name: 'Qwen', sub: 'Qwen Code', command: 'qwen' },
  { id: 'gitbash', name: 'Git Bash', sub: 'bash --login', command: 'C:\\Program Files\\Git\\bin\\bash.exe', args: ['--login', '-i'] },
  { id: 'shell', name: 'Command', sub: 'Any program', command: 'powershell' },
];
const PERMS = [
  ['acceptEdits', 'Accept edits', 'Applies file edits, still asks before riskier actions'],
  ['default', 'Ask every time', 'Claude asks before each change'],
  ['plan', 'Plan first', 'Starts in plan mode'],
  ['bypass', 'Bypass permissions', 'Never asks — use with care'],
];

function openNewSheet() {
  let tool = 'claude';
  openSheet('#newSheet', `
    <h2>New session</h2>
    <p class="lede">Runs in its own terminal, saved on this PC. Close Udha and it comes back — Claude sessions resume their conversation.</p>
    <div class="field">
      <label>Folder</label>
      <div class="row"><input class="input mono" id="nsDir" placeholder="D:\\code\\project" spellcheck="false"><button class="btn" id="nsBrowse">Browse…</button></div>
      ${state.recentDirs.length ? `<div class="recent">${state.recentDirs.map((d) => `<button data-dir="${esc(d)}" title="${esc(d)}">${esc(d.split(/[\\/]/).filter(Boolean).pop() || d)}</button>`).join('')}</div>` : ''}
    </div>
    <div class="field hidden" id="nsGitField">
      <label>Work on</label>
      <div class="segmented" id="nsGitMode"><button data-v="here" class="on">Current checkout</button><button data-v="worktree">New branch (worktree)</button></div>
      <span class="hint" id="nsGitHint"></span>
      <div class="row hidden" id="nsWtRow" style="margin-top:4px">
        <input class="input mono" id="nsBranch" spellcheck="false" placeholder="udha/my-task">
        <span class="hint">from</span>
        <select class="input" id="nsBase" style="max-width:170px"></select>
      </div>
    </div>
    <div class="field">
      <label>Name</label>
      <input class="input" id="nsName" placeholder="Defaults to the folder name" spellcheck="false">
    </div>
    <div class="field">
      <label>Assistant</label>
      <div class="tools">${TOOLS.map((t) => `<button class="tool-opt ${t.id === tool ? 'on' : ''}" data-tool="${t.id}"><b>${t.name}</b><span>${t.sub}</span></button>`).join('')}</div>
    </div>
    <div class="field" id="nsPermField">
      <label>Permissions</label>
      <select class="input" id="nsPerm">${PERMS.map(([v, n, d]) => `<option value="${v}" title="${esc(d)}">${n} — ${esc(d)}</option>`).join('')}</select>
    </div>
    <div class="field hidden" id="nsCmdField">
      <label>Command</label>
      <input class="input mono" id="nsCmd" value="powershell" spellcheck="false">
      <span class="hint">Run in the folder, e.g. <span class="mono">powershell</span>, <span class="mono">npm run dev</span>, <span class="mono">python</span></span>
    </div>
    <div class="error hidden" id="nsError"></div>
    <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn primary" id="nsCreate">Start session</button></div>`);

  const dir = $('#nsDir');
  dir.focus();

  // Git: when the folder is a repo, offer a worktree on a new branch.
  let gitMode = 'here';
  let gitTimer = null;
  let gitSeq = 0;
  const checkGit = () => {
    clearTimeout(gitTimer);
    gitTimer = setTimeout(async () => {
      const seq = ++gitSeq;
      const info = dir.value.trim() ? await window.udha.gitInfo(dir.value.trim()) : null;
      if (seq !== gitSeq || !$('#nsGitField')) return;
      $('#nsGitField').classList.toggle('hidden', !info);
      if (!info) { gitMode = 'here'; return; }
      $('#nsGitHint').textContent = info.branch ? `Repository on ${info.branch}` : 'Repository (detached HEAD)';
      if (!$('#nsBranch').value) $('#nsBranch').value = info.suggestion;
      $('#nsBase').innerHTML = info.branches.map((b) => `<option ${b === info.branch ? 'selected' : ''}>${esc(b)}</option>`).join('');
    }, 250);
  };
  dir.addEventListener('input', checkGit);
  document.querySelectorAll('#nsGitMode button').forEach((b) => {
    b.onclick = () => {
      gitMode = b.dataset.v;
      document.querySelectorAll('#nsGitMode button').forEach((x) => x.classList.toggle('on', x === b));
      $('#nsWtRow').classList.toggle('hidden', gitMode !== 'worktree');
    };
  });

  $('#nsBrowse').onclick = async () => { const p = await window.udha.pickFolder(dir.value); if (p) { dir.value = p; checkGit(); } };
  document.querySelectorAll('#newSheet .recent button').forEach((b) => { b.onclick = () => { dir.value = b.dataset.dir; checkGit(); }; });
  document.querySelectorAll('#newSheet .tool-opt').forEach((b) => {
    b.onclick = () => {
      tool = b.dataset.tool;
      document.querySelectorAll('#newSheet .tool-opt').forEach((x) => x.classList.toggle('on', x === b));
      $('#nsPermField').classList.toggle('hidden', tool !== 'claude');
      $('#nsCmdField').classList.toggle('hidden', tool !== 'shell');
    };
  });
  const create = async () => {
    const t = TOOLS.find((x) => x.id === tool);
    let command = t.command;
    let args = t.args ? [...t.args] : [];
    if (tool === 'shell') {
      const parts = ($('#nsCmd').value.trim() || 'powershell').match(/"[^"]*"|\S+/g) || ['powershell'];
      command = parts[0].replace(/"/g, '');
      args = parts.slice(1).map((a) => a.replace(/^"|"$/g, ''));
    }
    const worktree = gitMode === 'worktree' && !$('#nsGitField').classList.contains('hidden')
      ? { branch: $('#nsBranch').value.trim(), base: $('#nsBase').value || null }
      : null;
    if (worktree && !worktree.branch) { $('#nsError').textContent = 'Name the new branch'; $('#nsError').classList.remove('hidden'); return; }
    $('#nsCreate').disabled = true;
    try {
      const id = await window.udha.create({ directory: dir.value.trim(), label: $('#nsName').value.trim(), command, args, permission: $('#nsPerm').value, worktree });
      closeSheets();
      const d = dir.value.trim();
      state.recentDirs = [d, ...state.recentDirs.filter((x) => x !== d)].slice(0, 8);
      state.selected = null;
      select(id);
    } catch (err) {
      const e = $('#nsError');
      e.textContent = String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
      e.classList.remove('hidden');
      $('#nsCreate').disabled = false;
    }
  };
  $('#nsCreate').onclick = create;
  $('#newSheet').addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target.tagName === 'INPUT') create(); });
}
$('#newBtn').onclick = openNewSheet;

function openSettings() {
  const a = state.settings.appearance || {};
  const n = { needsYou: true, done: true, ...(state.settings.notifications || {}) };
  openSheet('#settingsSheet', `
    <h2>Settings</h2>
    <p class="lede">Saved with your sessions in <span class="mono" style="font-size:11px">${esc(state.configPath)}</span></p>
    <div class="field"><label>Appearance</label>
      <div class="segmented" id="setMode">${['system', 'light', 'dark'].map((m) => `<button data-v="${m}" class="${(a.mode || 'system') === m ? 'on' : ''}">${m === 'system' ? 'Match Windows' : m[0].toUpperCase() + m.slice(1)}</button>`).join('')}</div>
    </div>
    <div class="field"><label>Accent</label>
      <div class="segmented" id="setAccent">${['blue', 'purple', 'green', 'graphite'].map((m) => `<button data-v="${m}" class="${(a.accent || 'blue') === m ? 'on' : ''}">${m[0].toUpperCase() + m.slice(1)}</button>`).join('')}</div>
    </div>
    <div class="field"><label>Terminal theme</label>
      <div class="term-themes" id="setTermTheme">${Object.entries(TerminalThemes.THEMES).map(([id, t]) => {
        const c = TerminalThemes.resolve(id, { dark: darkQuery.matches }).colors;
        const cur = ((state.settings.terminal || {}).theme || 'udha') === id;
        return `<button class="term-theme ${cur ? 'on' : ''}" data-v="${id}" title="${esc(t.note)}">
          <span class="tt-preview" style="background:${c.background};color:${c.foreground};font-family:${esc(t.font)}">
            <span style="color:${c.green}">you@devbox</span> <span style="color:${c.magenta}">MINGW64</span> <span style="color:${c.yellow}">~/code</span><br>$ <span style="color:${c.cyan}">git</span> status<span class="tt-cursor" style="background:${c.cursor}"></span>
          </span>
          <span class="tt-name">${esc(t.name)}</span>
        </button>`;
      }).join('')}</div>
      <span class="hint" id="setTermNote">${esc((TerminalThemes.THEMES[(state.settings.terminal || {}).theme || 'udha'] || {}).note || '')}</span>
    </div>
    <div class="field" id="setTermSizeField"><label>Terminal font size</label>
      <div class="segmented" id="setTermSize">${[11, 12, 13, 14, 16].map((n) => `<button data-v="${n}" class="${((state.settings.terminal || {}).fontSize || 13) === n ? 'on' : ''}">${n}</button>`).join('')}</div>
    </div>
    <div class="switch-row"><div class="t"><b>Restore sessions on launch</b><span>Start every saved session when Udha opens, resuming Claude conversations.</span></div><input type="checkbox" class="switch" id="setRestore" ${state.settings.restoreOnLaunch ? 'checked' : ''}></div>
    <div class="switch-row"><div class="t"><b>Edge overlay</b><span>A hairline strip of session ticks on the right edge of the screen; hover it to see every session, click one to jump to it.</span></div><input type="checkbox" class="switch" id="setOverlay" ${state.settings.overlay !== false ? 'checked' : ''}></div>
    <div class="switch-row"><div class="t"><b>Keep running in the tray</b><span>Closing the window leaves Udha and your sessions running. Quit from the tray icon.</span></div><input type="checkbox" class="switch" id="setTray" ${state.settings.closeToTray ? 'checked' : ''}></div>
    ${state.settings.openAtLogin === null ? '' : `<div class="switch-row"><div class="t"><b>Start with Windows</b><span>Opens in the tray when you sign in, bringing your saved sessions back.</span></div><input type="checkbox" class="switch" id="setLogin" ${state.settings.openAtLogin ? 'checked' : ''}></div>`}
    <div class="switch-row"><div class="t"><b>Notify when a session needs you</b><span>A Windows notification for approvals, while Udha is in the background.</span></div><input type="checkbox" class="switch" id="setNotifyNeeds" ${n.needsYou ? 'checked' : ''}></div>
    <div class="switch-row"><div class="t"><b>Notify when a turn finishes</b><span>While Udha is in the background. "Notify when done" on a session always notifies.</span></div><input type="checkbox" class="switch" id="setNotifyDone" ${n.done ? 'checked' : ''}></div>
    <div class="switch-row"><div class="t"><b>Input lock PIN</b><span>${state.settings.hasLockPin ? 'Set. Lock input from the sidebar or the tray.' : 'Not set yet.'}</span></div><button class="btn sm" id="setPin">${state.settings.hasLockPin ? 'Change PIN' : 'Set PIN'}</button></div>
    <div class="sheet-actions"><button class="btn" id="setReveal">Show saved file</button><button class="btn primary" data-close>Done</button></div>`);
  const seg = (sel, fn) => document.querySelectorAll(`${sel} button`).forEach((b) => {
    b.onclick = () => { document.querySelectorAll(`${sel} button`).forEach((x) => x.classList.toggle('on', x === b)); fn(b.dataset.v); };
  });
  seg('#setMode', (v) => { state.settings.appearance = { ...state.settings.appearance, mode: v }; window.udha.setSettings({ appearance: { mode: v } }); });
  seg('#setAccent', (v) => { state.settings.appearance = { ...state.settings.appearance, accent: v }; window.udha.setSettings({ appearance: { accent: v } }); applyTheme(); renderAll(); });
  const setTerminal = (patch) => {
    state.settings.terminal = { ...(state.settings.terminal || {}), ...patch };
    window.udha.setSettings({ terminal: patch });
    applyTerminalAppearance();
    const t = TerminalThemes.THEMES[state.settings.terminal.theme || 'udha'];
    $('#setTermNote').textContent = t ? t.note : '';
    // Git Bash has mintty's own fixed size; the size picker applies to the others.
    $('#setTermSizeField').classList.toggle('hidden', !!(t && t.fixedSize));
  };
  document.querySelectorAll('#setTermTheme .term-theme').forEach((b) => {
    b.onclick = () => {
      document.querySelectorAll('#setTermTheme .term-theme').forEach((x) => x.classList.toggle('on', x === b));
      setTerminal({ theme: b.dataset.v });
    };
  });
  seg('#setTermSize', (v) => setTerminal({ fontSize: Number(v) }));
  $('#setTermSizeField').classList.toggle('hidden', !!(TerminalThemes.THEMES[(state.settings.terminal || {}).theme || 'udha'] || {}).fixedSize);
  $('#setRestore').onchange = (e) => { state.settings.restoreOnLaunch = e.target.checked; window.udha.setSettings({ restoreOnLaunch: e.target.checked }); };
  const setN = (k) => (e) => { state.settings.notifications = { ...n, [k]: e.target.checked }; Object.assign(n, { [k]: e.target.checked }); window.udha.setSettings({ notifications: { [k]: e.target.checked } }); };
  $('#setNotifyNeeds').onchange = setN('needsYou');
  $('#setPin').onclick = () => setLockPinSheet(false);
  $('#setOverlay').onchange =(e) => { state.settings.overlay = e.target.checked; window.udha.setSettings({ overlay: e.target.checked }); };
  $('#setTray').onchange =(e) => { state.settings.closeToTray = e.target.checked; window.udha.setSettings({ closeToTray: e.target.checked }); };
  if ($('#setLogin')) $('#setLogin').onchange = (e) => { state.settings.openAtLogin = e.target.checked; window.udha.setSettings({ openAtLogin: e.target.checked }); };
  $('#setNotifyDone').onchange = setN('done');
  $('#setReveal').onclick = () => window.udha.revealConfig();
}
$('#settingsBtn').onclick = openSettings;

// ---------- Palette (Ctrl+K) ----------

let palIndex = 0;
function openPalette() {
  closeSheets();
  $('#palette').classList.remove('hidden');
  $('#scrim').classList.remove('hidden');
  const input = $('#paletteInput');
  input.value = '';
  palIndex = 0;
  renderPalette();
  input.focus();
}
function paletteRows() {
  const q = $('#paletteInput').value.toLowerCase();
  return ordered().filter((s) => !q || s.label.toLowerCase().includes(q) || s.directory.toLowerCase().includes(q));
}
function renderPalette() {
  const rows = paletteRows();
  palIndex = Math.max(0, Math.min(palIndex, rows.length - 1));
  $('#paletteList').innerHTML = rows.length ? rows.map((s, i) => {
    const st = UdhaPresentation.style(s, state.staleAfter);
    return `<div class="pal-row ${i === palIndex ? 'on' : ''}" data-id="${s.id}">${pingHTML(st)}<span class="n">${esc(s.label)}</span><span class="d">${esc(s.directory)}</span>${chipHTML(st)}</div>`;
  }).join('') : '<div class="board-empty">No session matches.</div>';
  document.querySelectorAll('.pal-row').forEach((r) => { r.onclick = () => { closeSheets(); select(r.dataset.id); }; });
}
$('#paletteInput').addEventListener('input', () => { palIndex = 0; renderPalette(); });
$('#paletteInput').addEventListener('keydown', (e) => {
  const rows = paletteRows();
  if (e.key === 'ArrowDown') { palIndex++; renderPalette(); e.preventDefault(); }
  if (e.key === 'ArrowUp') { palIndex--; renderPalette(); e.preventDefault(); }
  if (e.key === 'Enter' && rows[palIndex]) { closeSheets(); select(rows[palIndex].id); }
});
$('#paletteBtn').onclick = openPalette;

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeSheets();
  if (e.ctrlKey && !e.shiftKey && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); }
  if (e.ctrlKey && !e.shiftKey && e.key.toLowerCase() === 'n') { e.preventDefault(); openNewSheet(); }
});

// ---------- Live updates ----------

function renderAll() { renderBoard(); renderPane(); renderStatusBar(); }

window.udha.onChanged((snap) => {
  const known = state.sessions.has(snap.id);
  state.sessions.set(snap.id, snap);
  if (!known && !state.order.includes(snap.id)) state.order.push(snap.id);
  renderBoard();
  renderStatusBar();
  if (snap.id === state.selected) renderPane();
});

window.udha.onRemoved((id) => {
  state.sessions.delete(id);
  state.order = state.order.filter((x) => x !== id);
  if (state.selected === id) {
    state.selected = null;
    const next = ordered()[0];
    if (next) select(next.id); else renderPane(true);
  }
  renderBoard();
  renderStatusBar();
});

// Ready → Stale is time-based; re-read once a minute.
setInterval(() => { renderBoard(); if (state.selected && !state.renaming) renderPane(); }, 60000);

(async function boot() {
  const s = await window.udha.state();
  state.staleAfter = s.staleAfterSeconds;
  state.settings = { appearance: s.appearance, restoreOnLaunch: s.restoreOnLaunch, terminal: s.terminal, notifications: s.notifications, closeToTray: s.closeToTray, openAtLogin: s.openAtLogin, accountFailover: s.accountFailover, overlay: s.overlay, hasLockPin: s.hasLockPin };
  state.configPath = s.configPath;
  state.recentDirs = s.recentDirs;
  state.hostName = s.hostName;
  $('#hostName').textContent = s.hostName;
  state.folders = s.folders || [];
  for (const snap of s.sessions) { state.sessions.set(snap.id, snap); state.order.push(snap.id); }
  applyTheme();
  const initial = s.sessions.find((x) => x.id === s.selectedSessionID) || s.sessions[0];
  renderBoard();
  renderStatusBar();
  if (initial) select(initial.id); else renderPane(true);
})();
