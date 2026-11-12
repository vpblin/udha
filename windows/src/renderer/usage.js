'use strict';
/* Usage section (UsagePane.swift + ClaudeLoginsSettings.swift): each Claude
   login's 5-hour and weekly windows, which sessions run on it, and failover.
   Uses app.js globals ($, esc, state, ordered, openSheet, closeSheets,
   askText, select, registerSection). */

const usageUI = { selected: 'default', probing: false, lastProbe: 0 };
state.logins = [];

function loginOf(s) {
  const dir = (s.loginDir || '').toLowerCase();
  return state.logins.find((l) => (dir ? l.configDir.toLowerCase() === dir : l.isDefault)) || null;
}

function fmtReset(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  const sameDay = d.toDateString() === new Date().toDateString();
  return `resets ${sameDay ? d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) : d.toLocaleString([], { weekday: 'short', hour: 'numeric', minute: '2-digit' })}`;
}

/** A labelled meter: accent below 75%, warn + "Busy" to 90%, bad + "Limit" above. */
function usageMeter(title, w) {
  if (!w) return `<div class="umeter"><div class="umeter-top"><span>${esc(title)}</span><span class="hint">no reading</span></div><div class="meter"></div></div>`;
  const cls = w.pct >= 90 ? 'bad' : w.pct >= 75 ? 'warn' : '';
  const word = w.pct >= 100 ? ' · <b class="bad-ink">At limit</b>' : w.pct >= 90 ? ' · <b class="bad-ink">Nearly out</b>' : '';
  return `<div class="umeter"><div class="umeter-top"><span>${esc(title)}</span><span><b>${w.pct}%</b>${word} <span class="hint">${esc(fmtReset(w.resetsAt))}</span></span></div>
    <div class="meter"><div class="meter-fill ${cls}" style="width:${Math.min(100, w.pct)}%"></div></div></div>`;
}

function renderLoginsList() {
  $('#usageCount').textContent = String(state.logins.length);
  $('#usageList').innerHTML = state.logins.map((l) => {
    const u = l.usage;
    const pct = u ? Math.max(u.fiveHour ? u.fiveHour.pct : 0, u.sevenDay ? u.sevenDay.pct : 0) : null;
    const st = l.limited ? { dot: 'var(--bad)', ink: 'var(--bad-ink)', word: 'At limit' }
      : !l.signedIn ? { dot: 'var(--tertiary)', ink: 'var(--secondary)', word: 'Not signed in' }
      : { dot: 'var(--good)', ink: 'var(--good-ink)', word: 'Available' };
    return `<div class="card-row ${l.id === usageUI.selected ? 'selected' : ''}" data-login="${esc(l.id)}">
      <div class="card-top"><span class="card-name">${esc(l.name)}</span><span class="card-spacer"></span><span class="card-model">${esc(l.email || '')}</span></div>
      <div class="card-state"><span class="ping" style="--dot:${st.dot}"></span><span class="card-state-label" style="color:${st.ink}">${st.word}</span></div>
      <div class="card-detail">${u ? `5h ${u.fiveHour ? u.fiveHour.pct + '%' : '—'} · week ${u.sevenDay ? u.sevenDay.pct + '%' : '—'}` : 'No reading yet'}</div>
      ${pct != null ? `<div class="meter thin"><div class="meter-fill ${pct >= 90 ? 'bad' : pct >= 75 ? 'warn' : ''}" style="width:${Math.min(100, pct)}%"></div></div>` : ''}
    </div>`;
  }).join('');
}

$('#usageList').addEventListener('click', (e) => {
  const row = e.target.closest('[data-login]');
  if (row) { usageUI.selected = row.dataset.login; renderLoginsList(); renderUsagePane(); }
});

function renderUsagePane() {
  const l = state.logins.find((x) => x.id === usageUI.selected) || state.logins[0];
  const pane = $('#usagePane');
  if (!l) { pane.innerHTML = ''; return; }
  const on = ordered().filter((s) => s.tool === 'claude' && loginOf(s) === l);
  const u = l.usage;
  pane.innerHTML = `
    <div class="pane-head">
      <div class="pane-title-wrap">
        <div class="pane-title">${esc(l.name)}</div>
        <div class="pane-sub"><span>${esc(l.email || 'No account signed in yet')}</span><span class="mono" title="CLAUDE_CONFIG_DIR">${esc(l.configDir)}</span></div>
      </div>
      <div class="pane-actions">
        <button class="btn" id="uRefresh" ${usageUI.probing ? 'disabled' : ''}>${usageUI.probing ? 'Reading…' : 'Refresh'}</button>
        ${l.isDefault ? '' : '<button class="btn" id="uRemove">Remove login</button>'}
        <button class="btn primary" id="uAdd">Add login…</button>
      </div>
    </div>
    <div class="machines-scroll">
      <div class="card mcard">
        <div class="mcard-head">Usage ${u ? `<span class="hint">from ${u.source === 'api' ? 'the usage endpoint' : 'a running session'} · ${new Date(u.observedAt).toLocaleTimeString()}</span>` : ''}</div>
        ${usageMeter('5-hour window', u && u.fiveHour)}
        ${usageMeter('Weekly', u && u.sevenDay)}
        ${u && u.scoped ? usageMeter(`Weekly · ${u.scoped.label || 'model cap'}`, u.scoped) : ''}
        ${!l.signedIn ? '<div class="hint" style="margin-top:8px">Not signed in. Start a Claude session on this login and run /login.</div>' : ''}
      </div>
      <div class="card mcard">
        <div class="mcard-head">Sessions on this login <span class="hint">${on.length}</span></div>
        ${on.map((s) => `<div class="kv clickable" data-sid="${s.id}"><span>${esc(s.label)}</span><b>${esc(UdhaPresentation.presentation(s, state.staleAfter).label)}</b></div>`).join('') || '<div class="hint">None. Move a session here from its right-click menu (Claude login).</div>'}
      </div>
      <div class="card mcard">
        <div class="switch-row"><div class="t"><b>Move sessions when a login runs out</b><span>When Claude says a login hit its usage limit, the session restarts on the login with the most room and carries on with its conversation.${state.logins.length < 2 ? ' Add a second login to use this.' : ''}</span></div>
          <input type="checkbox" class="switch" id="uFailover" ${state.settings.accountFailover !== false ? 'checked' : ''}></div>
      </div>
    </div>`;
  $('#uRefresh').onclick = probeUsage;
  $('#uAdd').onclick = addLogin;
  if ($('#uRemove')) $('#uRemove').onclick = () => removeLogin(l);
  $('#uFailover').onchange = (e) => { state.settings.accountFailover = e.target.checked; window.udha.usage.setFailover(e.target.checked); };
  pane.querySelectorAll('[data-sid]').forEach((r) => { r.onclick = () => select(r.dataset.sid); });
}

async function probeUsage() {
  usageUI.probing = true;
  renderUsagePane();
  state.logins = await window.udha.usage.probe();
  usageUI.probing = false;
  usageUI.lastProbe = Date.now();
  renderLoginsList();
  renderUsagePane();
}

async function addLogin() {
  const name = await askText('Add a Claude login', '', 'Add and sign in');
  if (!name) return;
  const { sessionID } = await window.udha.usage.add(name);
  state.logins = await window.udha.usage.list();
  state.selected = null;
  select(sessionID);   // the sign-in session: finish Claude's onboarding there
}

function removeLogin(l) {
  openSheet('#settingsSheet', `<h2>Remove ${esc(l.name)}?</h2>
    <p class="lede">Udha stops offering this login. Its folder <span class="mono">${esc(l.configDir)}</span> and sign-in stay on disk.</p>
    <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="uRmOK">Remove</button></div>`);
  $('#uRmOK').onclick = async () => {
    await window.udha.usage.remove(l.id);
    closeSheets();
    state.logins = await window.udha.usage.list();
    usageUI.selected = 'default';
    renderLoginsList();
    renderUsagePane();
  };
}

window.udha.usage.onUpdate((logins) => {
  state.logins = logins;
  if (state.section === 'usage') { renderLoginsList(); renderUsagePane(); }
});

registerSection('usage', {
  async show() {
    state.logins = await window.udha.usage.list();
    renderLoginsList();
    renderUsagePane();
    if (Date.now() - usageUI.lastProbe > 60000) probeUsage();
  },
});

window.udha.usage.list().then((l) => { state.logins = l; });
