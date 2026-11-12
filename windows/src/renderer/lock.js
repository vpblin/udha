'use strict';
/* global UdhaPresentation */
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const primary = new URLSearchParams(location.search).get('primary') === '1';
let staleAfter = 1800;

function tick() { $('clock').textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
tick(); setInterval(tick, 1000);

function renderSessions(list) {
  $('sessions').innerHTML = list.filter((s) => !s.hidden).slice(0, 8).map((s) => {
    const st = UdhaPresentation.style(s, staleAfter);
    return `<div class="srow"><span class="ping ${st.pulses ? 'active' : ''}" style="--dot:${st.dot}"></span><span class="n">${esc(s.label)}</span><span style="color:${st.dot};font-weight:600;font-size:11.5px">${esc(st.label)}</span></div>`;
  }).join('');
}

if (!primary) {
  // Secondary displays are just a shield.
  ['pinRow', 'msg'].forEach((id) => { $(id).style.display = 'none'; });
}

window.lock.state().then((s) => { staleAfter = s.staleAfter || 1800; renderSessions(s.sessions); });
window.lock.onSessions(renderSessions);

let waitUntil = 0;
$('pin').addEventListener('keydown', async (e) => {
  if (e.key !== 'Enter') return;
  if (Date.now() < waitUntil) return;
  const r = await window.lock.unlock($('pin').value);
  if (r.ok) return;
  $('pin').value = '';
  $('pinRow').classList.remove('shake'); void $('pinRow').offsetWidth; $('pinRow').classList.add('shake');
  if (r.wait) { waitUntil = Date.now() + r.wait * 1000; $('msg').textContent = `Wrong PIN — try again in ${r.wait}s`; } else $('msg').textContent = 'Wrong PIN';
});
// Keep the field focused whatever gets clicked.
document.addEventListener('mousedown', (e) => { if (primary) { e.preventDefault(); $('pin').focus(); } });
setInterval(() => { if (primary && document.activeElement !== $('pin')) $('pin').focus(); }, 500);
