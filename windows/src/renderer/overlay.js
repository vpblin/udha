'use strict';
/* global UdhaPresentation */

const el = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
let sessions = [];
let staleAfter = 1800;
let bloomed = false;
let hoverTimer = null;
let leaveTimer = null;

const dark = window.matchMedia('(prefers-color-scheme: dark)');
const applyTheme = () => { document.documentElement.dataset.dark = dark.matches ? '1' : '0'; };
dark.addEventListener('change', applyTheme);
applyTheme();

/** Needs-you first, then working, then the rest — the order the eye wants. */
function rank(st) { return st.wantsYou ? 0 : (st.kind === 'working' || st.kind === 'starting') ? 1 : st.kind === 'ready' ? 2 : 3; }

function visible() {
  return sessions.filter((s) => !s.hidden).map((s) => ({ s, st: UdhaPresentation.style(s, staleAfter) }));
}

function render() {
  const list = visible();
  document.body.style.display = list.length ? '' : 'none';
  el('ticks').innerHTML = list.map(({ st }) => {
    const cls = st.wantsYou ? 'needs' : (st.kind === 'working' || st.kind === 'starting') ? 'working' : st.kind === 'ready' ? 'ready' : st.kind === 'stale' ? 'stale' : 'quiet';
    return `<div class="tick ${cls}"></div>`;
  }).join('');
  const sorted = [...list].sort((a, b) => rank(a.st) - rank(b.st));
  const needs = list.filter((x) => x.st.wantsYou).length;
  el('panel').innerHTML = `<div class="ovhead">Udha <span class="n">${list.length} session${list.length === 1 ? '' : 's'}${needs ? ` · ${needs} need${needs === 1 ? 's' : ''} you` : ''}</span></div>` +
    sorted.map(({ s, st }) => `<div class="pill ${st.wantsYou ? 'wants' : ''}" data-id="${s.id}">
      <div class="top"><span class="ping ${st.filled ? '' : 'hollow'} ${st.pulses ? 'active' : ''}" style="--dot:${st.dot}"></span>
        <span class="name">${esc(s.label)}</span><span class="word" style="color:${st.ink}">${esc(st.label)}</span></div>
      ${st.detail ? `<div class="det">${esc(st.detail)}</div>` : ''}
    </div>`).join('');
}

// Hit testing: only the ticks (and the bloomed panel) take the mouse; the rest passes through.
let interactive = false;
function setInteractive(on) { if (on !== interactive) { interactive = on; window.overlay.interactive(on); } }

document.addEventListener('mousemove', (e) => {
  const overUI = e.target.closest('.ticks, .ovcard');
  setInteractive(!!overUI);
  if (overUI) {
    clearTimeout(leaveTimer);
    if (!bloomed && !hoverTimer) hoverTimer = setTimeout(() => { hoverTimer = null; window.overlay.bloom(true); }, 100);
  } else {
    clearTimeout(hoverTimer); hoverTimer = null;
    if (bloomed) { clearTimeout(leaveTimer); leaveTimer = setTimeout(() => window.overlay.bloom(false), 250); }
  }
});
document.addEventListener('mouseleave', () => {
  clearTimeout(hoverTimer); hoverTimer = null;
  setInteractive(false);
  if (bloomed) { clearTimeout(leaveTimer); leaveTimer = setTimeout(() => window.overlay.bloom(false), 250); }
});
el('panel').addEventListener('click', (e) => {
  const pill = e.target.closest('.pill');
  if (pill) window.overlay.pick(pill.dataset.id);
});

window.overlay.onBloomed((on) => {
  bloomed = on;
  el('ov').classList.toggle('bloomed', on);
  if (!on) setInteractive(false);
});
window.overlay.onSessions((list, stale) => { sessions = list; staleAfter = stale || 1800; render(); });
window.overlay.state().then((st) => { sessions = st.sessions; staleAfter = st.staleAfter; render(); });
setInterval(render, 60000);
