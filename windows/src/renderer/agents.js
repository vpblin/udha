'use strict';
/* Agents section (AgentsPane.swift): reusable prompts stored as .md files.
   Uses the globals app.js defines ($, esc, state, openSheet, closeSheets,
   askText, select, registerSection). */

const agentsUI = { selected: null, dirty: false, draft: null };

async function loadAgents() {
  state.agents = await window.udha.agents.list();
  return state.agents;
}

function agentGlyph(a) {
  const letter = (a.name || '?').trim()[0] || '?';
  return `<span class="agent-glyph">${esc(letter.toUpperCase())}</span>`;
}

function renderAgentsList() {
  const list = $('#agentsList');
  $('#agentsCount').textContent = state.agents.length ? String(state.agents.length) : '';
  if (!state.agents.length) {
    list.innerHTML = '<div class="board-empty">No agents yet.<br>Press <b>New</b> to write one.</div>';
    return;
  }
  list.innerHTML = state.agents.map((a) => `
    <div class="card-row agent-row ${a.slug === agentsUI.selected ? 'selected' : ''}" data-slug="${esc(a.slug)}">
      ${agentGlyph(a)}
      <div class="agent-row-text">
        <div class="card-top"><span class="card-name">${esc(a.name)}</span>${a.isBuiltIn ? '<span class="tag">Built in</span>' : ''}</div>
        <div class="card-detail">${esc(a.description || 'No description')}</div>
      </div>
    </div>`).join('');
}

$('#agentsList').addEventListener('click', (e) => {
  const row = e.target.closest('.agent-row');
  if (row) selectAgent(row.dataset.slug);
});

async function selectAgent(slug) {
  if (agentsUI.dirty && agentsUI.selected !== slug) await saveAgentDraft();
  agentsUI.selected = slug;
  agentsUI.dirty = false;
  renderAgentsList();
  renderAgentPane();
}

function renderAgentPane() {
  const pane = $('#agentsPane');
  const a = state.agents.find((x) => x.slug === agentsUI.selected);
  if (!a) {
    pane.innerHTML = `<div class="empty">
      <div class="title">Agents</div>
      <div class="text">A reusable prompt, kept as a plain <span class="mono">.md</span> file. Running one starts a fresh Claude session in a folder and pastes the prompt in once Claude is ready.</div>
      <div class="row" style="justify-content:center"><button class="btn primary" id="agentEmptyNew">New agent</button><button class="btn" id="agentOpenDir">Open agents folder</button></div>
    </div>`;
    $('#agentEmptyNew').onclick = newAgent;
    $('#agentOpenDir').onclick = () => window.udha.agents.openFolder();
    return;
  }
  agentsUI.draft = { ...a };
  pane.innerHTML = `
    <div class="pane-head">
      <div class="pane-title-wrap">
        <input class="agent-title-input" id="agName" value="${esc(a.name)}" spellcheck="false">
        <div class="pane-sub"><span class="mono">${esc(a.slug)}.md</span>${a.isBuiltIn ? '<span class="tag">Built in</span>' : ''}<span id="agSaved" class="saved-note"></span></div>
      </div>
      <div class="pane-actions">
        <button class="btn" id="agDelete">${a.isBuiltIn ? 'Restore default' : 'Delete'}</button>
        <button class="btn" id="agSave" disabled>Save</button>
        <button class="btn primary" id="agRun">
          <svg viewBox="0 0 16 16"><path d="M5 3.5v9l7-4.5z" fill="currentColor"/></svg>Run…
        </button>
      </div>
    </div>
    <div class="card agent-meta">
      <label>Description</label>
      <input class="input" id="agDesc" value="${esc(a.description)}" placeholder="One line shown in the list" spellcheck="false">
    </div>
    <div class="card agent-prompt-card">
      <div class="agent-prompt-head"><span>Prompt</span><span class="hint">Pasted into the session as your first message · Ctrl+S saves</span></div>
      <textarea id="agPrompt" spellcheck="false" placeholder="What should Claude do when this agent runs?">${esc(a.prompt)}</textarea>
    </div>`;
  const markDirty = () => {
    agentsUI.dirty = true;
    $('#agSave').disabled = false;
    $('#agSaved').textContent = 'Unsaved changes';
  };
  ['#agName', '#agDesc', '#agPrompt'].forEach((sel) => $(sel).addEventListener('input', markDirty));
  $('#agSave').onclick = saveAgentDraft;
  $('#agRun').onclick = async () => { if (agentsUI.dirty) await saveAgentDraft(); openRunSheet(a.slug); };
  $('#agDelete').onclick = () => confirmDeleteAgent(a);
  pane.onkeydown = (e) => { if (e.ctrlKey && e.key.toLowerCase() === 's') { e.preventDefault(); saveAgentDraft(); } };
}

async function saveAgentDraft() {
  const a = state.agents.find((x) => x.slug === agentsUI.selected);
  if (!a || !$('#agName')) return;
  const next = { ...a, name: $('#agName').value.trim() || a.name, description: $('#agDesc').value.trim(), prompt: $('#agPrompt').value };
  await window.udha.agents.save(next);
  agentsUI.dirty = false;
  await loadAgents();
  renderAgentsList();
  if ($('#agSave')) { $('#agSave').disabled = true; $('#agSaved').textContent = 'Saved'; }
}

async function newAgent() {
  const name = await askText('New agent', '', 'Create');
  if (!name) return;
  const slug = await window.udha.agents.create(name);
  await loadAgents();
  agentsUI.selected = slug;
  renderAgentsList();
  renderAgentPane();
  if ($('#agPrompt')) $('#agPrompt').focus();
}
$('#agentNewBtn').onclick = newAgent;

function confirmDeleteAgent(a) {
  openSheet('#settingsSheet', a.isBuiltIn
    ? `<h2>Restore “${esc(a.name)}”?</h2><p class="lede">Your edits to this built-in agent are replaced with the version that ships with Udha.</p>
       <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="agDelOK">Restore default</button></div>`
    : `<h2>Delete “${esc(a.name)}”?</h2><p class="lede">Its file <span class="mono">${esc(a.slug)}.md</span> is deleted. Sessions it already started are not affected.</p>
       <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="agDelOK">Delete</button></div>`);
  $('#agDelOK').onclick = async () => {
    closeSheets();
    await window.udha.agents.remove(a.slug);
    agentsUI.dirty = false;
    await loadAgents();
    if (!state.agents.some((x) => x.slug === a.slug)) agentsUI.selected = null;
    renderAgentsList();
    renderAgentPane();
  };
}

/** Pick where to run: a session's folder (inherits its command/mode/folder) or any folder. */
function openRunSheet(slug) {
  const a = state.agents.find((x) => x.slug === slug);
  if (!a) return;
  const sessions = ordered();
  let source = sessions.find((s) => s.id === state.selected) || null;
  openSheet('#newSheet', `
    <h2>Run ${esc(a.name)}</h2>
    <p class="lede">Starts a new Claude session and pastes the prompt in once it's ready.</p>
    <div class="field">
      <label>Next to a session</label>
      <select class="input" id="runSource">
        <option value="">— Pick a folder instead —</option>
        ${sessions.map((s) => `<option value="${s.id}" ${source && source.id === s.id ? 'selected' : ''}>${esc(s.label)} — ${esc(s.directory)}</option>`).join('')}
      </select>
      <span class="hint">Runs in that session's folder with its permission mode, and files under it.</span>
    </div>
    <div class="field ${source ? 'hidden' : ''}" id="runDirField">
      <label>Folder</label>
      <div class="row"><input class="input mono" id="runDir" spellcheck="false" placeholder="D:\\code\\project"><button class="btn" id="runBrowse">Browse…</button></div>
    </div>
    <div class="error hidden" id="runError"></div>
    <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn primary" id="runGo">Run agent</button></div>`);
  $('#runSource').onchange = (e) => {
    source = sessions.find((s) => s.id === e.target.value) || null;
    $('#runDirField').classList.toggle('hidden', !!source);
  };
  $('#runBrowse').onclick = async () => { const p = await window.udha.pickFolder($('#runDir').value); if (p) $('#runDir').value = p; };
  $('#runGo').onclick = async () => {
    try {
      await runAgent(slug, source ? { sourceSessionID: source.id } : { directory: $('#runDir').value.trim() });
      closeSheets();
    } catch (err) {
      $('#runError').textContent = String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
      $('#runError').classList.remove('hidden');
    }
  };
}

async function runAgent(slug, opts) {
  const id = await window.udha.agents.run(slug, opts);
  state.selected = null;
  select(id);
  return id;
}

registerSection('agents', {
  async show() {
    await loadAgents();
    if (!agentsUI.selected && state.agents.length) agentsUI.selected = state.agents[0].slug;
    renderAgentsList();
    renderAgentPane();
  },
});

loadAgents();
