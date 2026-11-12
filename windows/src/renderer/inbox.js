'use strict';
/* Inbox section (InboxPane.swift): Slack DMs and mentions, filed per thread,
   stamped "received 9:41" or "sent from Udha", answerable from here. Uses
   app.js globals ($, esc, state, openSheet, closeSheets, registerSection). */

const inboxUI = { threads: [], workspaces: [], selected: null };

function stampOf(m) {
  const t = new Date(m.receivedAt).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return m.sentFromUdha ? `sent from Udha ${t}` : `received ${t}`;
}

async function loadInbox() {
  const r = await window.udha.inbox.list();
  inboxUI.threads = r.threads;
  inboxUI.workspaces = r.workspaces;
  const unread = r.threads.reduce((n, t) => n + (t.unread || 0), 0);
  const nav = document.querySelector('.nav-row[data-section="inbox"] .nav-count');
  if (nav) nav.textContent = unread ? String(unread) : '';
}

function renderInboxList() {
  $('#inboxCount').textContent = inboxUI.threads.length ? String(inboxUI.threads.length) : '';
  $('#inboxList').innerHTML = inboxUI.threads.map((t) => {
    const last = t.messages[t.messages.length - 1];
    return `<div class="card-row ${t.key === inboxUI.selected ? 'selected' : ''}" data-thread="${esc(t.key)}">
      <div class="card-top"><span class="card-name">${t.unread ? '<span class="unread-dot"></span>' : ''}${esc(t.kind === 'dm' ? t.channelName : `${last.userName} in ${t.channelName}`)}</span><span class="card-spacer"></span><span class="card-model">${esc(t.team)}</span></div>
      <div class="card-detail" style="${t.unread ? 'color:var(--label);font-weight:600' : ''}">${esc(last.text)}</div>
      <div class="card-detail" style="font-size:10.5px;color:var(--tertiary)">${t.kind === 'dm' ? 'DM' : 'Mention'} · ${esc(stampOf(last))}</div>
    </div>`;
  }).join('') || `<div class="board-empty">${inboxUI.workspaces.length ? 'Nothing yet. New DMs and mentions land here as they arrive.' : 'Connect a Slack workspace to start.'}</div>`;
}

$('#inboxList').addEventListener('click', (e) => {
  const row = e.target.closest('[data-thread]');
  if (!row) return;
  inboxUI.selected = row.dataset.thread;
  window.udha.inbox.read(inboxUI.selected);
  renderInboxList();
  renderInboxPane();
});

function slackSetupHTML() {
  return `<div class="card mcard setup-card">
    <div class="mcard-head">Connect a Slack workspace</div>
    <ol class="steps">
      <li>Create a Slack app at <span class="mono">api.slack.com/apps</span> (from scratch, in your workspace).</li>
      <li>Under <b>OAuth &amp; Permissions → User Token Scopes</b> add: <span class="mono">im:history mpim:history im:read mpim:read search:read users:read chat:write</span>.</li>
      <li>Install it to the workspace and copy the <b>User OAuth Token</b> (<span class="mono">xoxp-…</span>).</li>
    </ol>
    <div class="row"><input class="input mono" type="password" id="slackToken" placeholder="xoxp-…"><button class="btn primary" id="slackAdd">Connect</button></div>
    <div class="error hidden" id="slackErr" style="margin-top:8px"></div>
    <span class="hint">The token is encrypted for your Windows account. Udha only reads DMs and mentions from now on — it never backfills history.</span>
  </div>
  ${inboxUI.workspaces.map((w) => `<div class="kv"><span>${esc(w.team)} · @${esc(w.user)}${w.error ? ` · <span class="bad-ink">${esc(w.error)}</span>` : ''}</span><button class="link" data-rm="${esc(w.teamID)}">Disconnect</button></div>`).join('')}`;
}

function renderInboxPane() {
  const pane = $('#inboxPane');
  const t = inboxUI.threads.find((x) => x.key === inboxUI.selected);
  if (!t) {
    pane.innerHTML = `<div class="pane-head"><div class="pane-title-wrap"><div class="pane-title">Inbox</div><div class="pane-sub"><span>Slack DMs and mentions, as they arrive</span></div></div>
      <div class="pane-actions"><button class="btn" id="inboxPoll">Check now</button></div></div>
      <div class="machines-scroll">${slackSetupHTML()}</div>`;
    bindInboxSetup();
    return;
  }
  pane.innerHTML = `
    <div class="pane-head">
      <div class="pane-title-wrap">
        <div class="pane-title">${esc(t.kind === 'dm' ? t.channelName : t.channelName)}</div>
        <div class="pane-sub"><span>${t.kind === 'dm' ? 'Direct message' : 'Mention thread'} · ${esc(t.team)}</span></div>
      </div>
      <div class="pane-actions"><button class="btn" id="inboxBack">Workspaces</button></div>
    </div>
    <div class="card thread-card"><div class="thread" id="thread">${t.messages.map((m) => `
      <div class="msg ${m.mine ? 'mine' : ''}">
        <div class="msg-head"><b>${esc(m.userName)}</b><span class="hint">${esc(stampOf(m))}</span></div>
        <div class="msg-text">${esc(m.text)}</div>
      </div>`).join('')}</div></div>
    <div class="card sendbox"><div class="sendrow"><textarea id="inboxDraft" rows="1" placeholder="Reply ${t.kind === 'dm' ? `to ${esc(t.channelName)}` : 'in thread'}…  (Enter to send)"></textarea><button class="btn primary" id="inboxSend">Send</button></div>
      <div class="error hidden" id="inboxErr"></div></div>`;
  const th = $('#thread'); th.scrollTop = th.scrollHeight;
  $('#inboxBack').onclick = () => { inboxUI.selected = null; renderInboxList(); renderInboxPane(); };
  const send = async () => {
    const text = $('#inboxDraft').value.trim();
    if (!text) return;
    $('#inboxSend').disabled = true;
    try {
      await window.udha.inbox.reply(t.key, text);
      $('#inboxDraft').value = '';
    } catch (err) {
      $('#inboxErr').textContent = String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
      $('#inboxErr').classList.remove('hidden');
    }
    if ($('#inboxSend')) $('#inboxSend').disabled = false;
  };
  $('#inboxSend').onclick = send;
  $('#inboxDraft').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
}

function bindInboxSetup() {
  if ($('#inboxPoll')) $('#inboxPoll').onclick = () => window.udha.inbox.poll();
  $('#slackAdd').onclick = async () => {
    try {
      await window.udha.inbox.add($('#slackToken').value);
      await loadInbox(); renderInboxList(); renderInboxPane();
    } catch (err) {
      $('#slackErr').textContent = String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
      $('#slackErr').classList.remove('hidden');
    }
  };
  document.querySelectorAll('[data-rm]').forEach((b) => { b.onclick = async () => { await window.udha.inbox.remove(b.dataset.rm); await loadInbox(); renderInboxList(); renderInboxPane(); }; });
}

window.udha.inbox.onChanged(async () => {
  await loadInbox();
  if (state.section !== 'inbox') return;
  renderInboxList();
  const typing = document.activeElement && (document.activeElement.id === 'inboxDraft' || document.activeElement.id === 'slackToken');
  if (!typing) renderInboxPane();
});

registerSection('inbox', {
  async show() { await loadInbox(); renderInboxList(); renderInboxPane(); },
});
loadInbox();
