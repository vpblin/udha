'use strict';
/* Meetings section (MeetingsPane.swift). Two streams — your microphone and
   the system's loopback audio — each recorded on its own and cut into chunks
   on silence, so "You" and "Them" come apart without diarization. Silent
   chunks are never sent. Uses app.js globals ($, esc, state, openSheet,
   closeSheets, askText, registerSection). */

const meetingsUI = { list: [], selected: null, rec: null, asks: new Map(), setup: null, editingNotes: false };

const SPEECH_LEVEL = 0.012;   // RMS that counts as someone talking
const MIN_CHUNK_MS = 10000;   // cut at the first pause after this…
const MAX_CHUNK_MS = 30000;   // …or here regardless
const PAUSE_MS = 600;

/** Records one stream in standalone chunks cut at pauses. */
class StreamChunker {
  constructor(stream, who, t0, onChunk) {
    this.stream = stream; this.who = who; this.t0 = t0; this.onChunk = onChunk;
    this.ctx = new AudioContext();
    this.ctx.resume();
    const src = this.ctx.createMediaStreamSource(stream);
    this.analyser = this.ctx.createAnalyser();
    this.analyser.fftSize = 2048;
    src.connect(this.analyser);
    this.buf = new Float32Array(this.analyser.fftSize);
    this.level = 0;
    this.mime = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus' : 'audio/webm';
  }

  start() {
    this.begin();
    this.timer = setInterval(() => this.tick(), 100);
  }

  begin() {
    this.parts = [];
    this.peak = 0;
    this.quietSince = null;
    this.chunkStart = Date.now();
    this.rec = new MediaRecorder(this.stream, { mimeType: this.mime });
    this.rec.ondataavailable = (e) => { if (e.data && e.data.size) this.parts.push(e.data); };
    this.rec.start();
  }

  tick() {
    this.analyser.getFloatTimeDomainData(this.buf);
    let sum = 0;
    for (const v of this.buf) sum += v * v;
    this.level = Math.sqrt(sum / this.buf.length);
    this.peak = Math.max(this.peak, this.level);
    const now = Date.now();
    if (this.level < SPEECH_LEVEL) { if (!this.quietSince) this.quietSince = now; } else this.quietSince = null;
    const age = now - this.chunkStart;
    if ((age >= MIN_CHUNK_MS && this.quietSince && now - this.quietSince >= PAUSE_MS) || age >= MAX_CHUNK_MS) this.cut(true);
  }

  cut(restart) {
    const rec = this.rec; const parts = this.parts; const peak = this.peak; const offset = this.chunkStart - this.t0;
    rec.onstop = async () => {
      if (peak < SPEECH_LEVEL || !parts.length) return;   // silence: nothing to transcribe
      const blob = new Blob(parts, { type: this.mime });
      this.onChunk(this.who, offset, new Uint8Array(await blob.arrayBuffer()), this.mime);
    };
    if (rec.state !== 'inactive') rec.stop();
    if (restart) this.begin();
  }

  stop() {
    clearInterval(this.timer);
    this.cut(false);
    this.stream.getTracks().forEach((t) => t.stop());
    this.ctx.close();
  }
}

// ---------- Recording ----------

async function startRecording() {
  if (meetingsUI.rec) return;
  let mic = null; let sys = null;
  try {
    mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
  } catch (err) {
    return showMeetingError(`Couldn't open the microphone: ${err.message}`);
  }
  try {
    const display = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: true });
    display.getVideoTracks().forEach((t) => t.stop());   // only the loopback audio is wanted
    if (display.getAudioTracks().length) sys = new MediaStream(display.getAudioTracks());
  } catch { /* system audio unavailable: record the mic alone */ }

  const m = await window.udha.meetings.start();
  const t0 = Date.now();
  const send = (who, offset, bytes, mime) => window.udha.meetings.chunk(m.id, who, offset, bytes, mime);
  const chunkers = [new StreamChunker(mic, 'you', t0, send)];
  if (sys) chunkers.push(new StreamChunker(sys, 'them', t0, send));
  chunkers.forEach((c) => c.start());
  meetingsUI.rec = { id: m.id, t0, chunkers, hasSystem: !!sys };
  meetingsUI.levelsTimer = setInterval(updateLevels, 120);
  meetingsUI.selected = m.id;
  document.querySelector('.nav-row[data-section="meetings"]').classList.add('recording');
  await refreshMeetings();
  if (state.section !== 'meetings') setSection('meetings');
}

async function stopRecording() {
  const rec = meetingsUI.rec;
  if (!rec) return;
  meetingsUI.rec = null;
  clearInterval(meetingsUI.levelsTimer);
  rec.chunkers.forEach((c) => c.stop());
  document.querySelector('.nav-row[data-section="meetings"]').classList.remove('recording');
  // Let the last chunks land before the final notes pass.
  setTimeout(() => window.udha.meetings.stop(rec.id), 1500);
  renderMeetingPane();
}

function updateLevels() {
  const rec = meetingsUI.rec;
  if (!rec) return;
  rec.chunkers.forEach((c) => {
    const bar = document.querySelector(`.lvl[data-who="${c.who}"] .lvl-fill`);
    if (bar) bar.style.width = `${Math.min(100, (c.level / 0.15) * 100)}%`;
  });
  const t = document.querySelector('#recClock');
  if (t) t.textContent = fmtClock(Date.now() - rec.t0);
}

function fmtClock(ms) {
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  return `${h ? `${h}:` : ''}${String(Math.floor((s % 3600) / 60)).padStart(h ? 2 : 1, '0')}:${String(s % 60).padStart(2, '0')}`;
}

// ---------- List ----------

async function refreshMeetings() {
  meetingsUI.list = await window.udha.meetings.list();
  if (!meetingsUI.selected && meetingsUI.list.length) meetingsUI.selected = meetingsUI.list[0].id;
  renderMeetingsList();
  renderMeetingPane();
}

function renderMeetingsList() {
  $('#meetingsCount').textContent = meetingsUI.list.length ? String(meetingsUI.list.length) : '';
  $('#meetingsList').innerHTML = meetingsUI.list.map((m) => {
    const live = meetingsUI.rec && meetingsUI.rec.id === m.id;
    const dur = m.endedAt ? fmtClock(m.endedAt - m.startedAt) : '';
    return `<div class="card-row ${m.id === meetingsUI.selected ? 'selected' : ''}" data-meeting="${m.id}">
      <div class="card-top"><span class="card-name">${esc(m.title)}</span><span class="card-spacer"></span><span class="card-model">${new Date(m.startedAt).toLocaleDateString()}</span></div>
      <div class="card-state">${live
        ? '<span class="ping active" style="--dot:var(--bad)"></span><span class="card-state-label" style="color:var(--bad-ink)">Recording</span>'
        : `<span class="ping" style="--dot:var(--tertiary)"></span><span class="card-state-label" style="color:var(--secondary)">${dur || 'Ended'}</span>`}</div>
      <div class="card-detail">${m.segmentCount} line${m.segmentCount === 1 ? '' : 's'} transcribed</div>
    </div>`;
  }).join('') || '<div class="board-empty">No meetings yet.<br>Press <b>Record</b> when a call starts.</div>';
}

$('#meetingsList').addEventListener('click', (e) => {
  const row = e.target.closest('[data-meeting]');
  if (row) { meetingsUI.selected = row.dataset.meeting; meetingsUI.editingNotes = false; renderMeetingsList(); renderMeetingPane(); }
});
$('#recordBtn').onclick = () => (meetingsUI.rec ? stopRecording() : startRecording());

// ---------- Pane ----------

function showMeetingError(text) {
  openSheet('#settingsSheet', `<h2>Can't record</h2><p class="lede">${esc(text)}</p><div class="sheet-actions"><button class="btn primary" data-close>OK</button></div>`);
}

function setupCardHTML(s) {
  return `<div class="card mcard setup-card">
    <div class="mcard-head">Setup <span class="hint">Recording works without any of this; transcripts and notes need a service.</span></div>
    <div class="field"><label>Transcription — ElevenLabs API key ${s.elevenlabs_api_key ? '<span class="tag">saved</span>' : ''}</label>
      <div class="row"><input class="input mono" type="password" id="suEleven" placeholder="${s.elevenlabs_api_key ? '••••••••  (saved — type to replace)' : 'xi-…'}"><button class="btn" id="suElevenSave">Save</button></div></div>
    <div class="field"><label>…or a local Whisper server (Scribe-shaped answer)</label>
      <div class="row"><input class="input mono" id="suStt" value="${esc(s.sttBaseURL)}" placeholder="http://localhost:8000/v1/speech-to-text"><button class="btn" id="suSttSave">Save</button></div></div>
    <div class="field"><label>Notes & Ask — Anthropic API key ${s.anthropic_api_key ? '<span class="tag">saved</span>' : ''}</label>
      <div class="row"><input class="input mono" type="password" id="suAnth" placeholder="${s.anthropic_api_key ? '••••••••  (saved — type to replace)' : 'sk-ant-…'}"><button class="btn" id="suAnthSave">Save</button></div>
      <span class="hint">Uses Claude Opus 5.5. Keys are encrypted for your Windows account.</span></div>
    <div class="field"><label>…or a local Ollama server</label>
      <div class="row"><input class="input mono" id="suOllama" value="${esc(s.localModel.baseURL)}" placeholder="http://localhost:11434"><input class="input mono" id="suOllamaModel" value="${esc(s.localModel.model)}" style="max-width:160px"><button class="btn" id="suOllamaSave">Save</button></div></div>
  </div>`;
}

function bindSetup() {
  const done = async (p) => { meetingsUI.setup = await p; renderMeetingPane(); };
  const secret = (btn, input, account) => { if ($(btn)) $(btn).onclick = () => { const v = $(input).value.trim(); if (v) done(window.udha.meetings.setSecret(account, v)); }; };
  secret('#suElevenSave', '#suEleven', 'elevenlabs_api_key');
  secret('#suAnthSave', '#suAnth', 'anthropic_api_key');
  if ($('#suSttSave')) $('#suSttSave').onclick = () => done(window.udha.meetings.setConfig({ sttBaseURL: $('#suStt').value }));
  if ($('#suOllamaSave')) $('#suOllamaSave').onclick = () => done(window.udha.meetings.setConfig({ localModel: { baseURL: $('#suOllama').value.trim(), model: $('#suOllamaModel').value.trim() || 'llama3.1' } }));
}

async function renderMeetingPane() {
  const pane = $('#meetingsPane');
  if (!meetingsUI.setup) meetingsUI.setup = await window.udha.meetings.setup();
  const s = meetingsUI.setup;
  const m = meetingsUI.selected ? await window.udha.meetings.get(meetingsUI.selected) : null;
  if (!m) {
    pane.innerHTML = `<div class="machines-scroll"><div class="empty" style="flex:none;padding:40px 0">
      <div class="title">Meetings</div>
      <div class="text">Records your microphone and the call's audio as two streams, transcribes them as "You" and "Them", and keeps live notes and action items. Press Record when a call starts.</div>
      <button class="btn primary" id="emptyRecord">Record</button></div>
      ${!s.canTranscribe || !s.canSummarize ? setupCardHTML(s) : ''}</div>`;
    $('#emptyRecord').onclick = startRecording;
    bindSetup();
    return;
  }
  const live = meetingsUI.rec && meetingsUI.rec.id === m.id;
  const scrollT = $('#transcript') && $('#transcript').scrollTop;
  const atBottom = $('#transcript') ? $('#transcript').scrollHeight - $('#transcript').scrollTop - $('#transcript').clientHeight < 40 : true;
  const asks = meetingsUI.asks.get(m.id) || [];
  pane.innerHTML = `
    <div class="pane-head">
      <div class="pane-title-wrap">
        <div class="pane-title" id="mTitle" title="Double-click to rename">${esc(m.title)}</div>
        <div class="pane-sub">${live
          ? `<span class="chip" style="--tint:var(--bad-tint);--ink:var(--bad-ink)"><span class="ping active" style="--dot:var(--bad)"></span>Recording <span id="recClock">${fmtClock(Date.now() - meetingsUI.rec.t0)}</span></span>
             <span class="lvl" data-who="you"><span>You</span><span class="lvl-bar"><span class="lvl-fill"></span></span></span>
             ${meetingsUI.rec.hasSystem ? '<span class="lvl" data-who="them"><span>Them</span><span class="lvl-bar"><span class="lvl-fill"></span></span></span>' : '<span class="hint">System audio unavailable — mic only</span>'}`
          : `<span>${new Date(m.startedAt).toLocaleString()}${m.endedAt ? ` · ${fmtClock(m.endedAt - m.startedAt)}` : ''}</span>`}</div>
      </div>
      <div class="pane-actions">
        ${live ? '<button class="btn danger" id="mStop">Stop</button>' : ''}
        <button class="btn" id="mFolder">Open folder</button>
        ${live ? '' : '<button class="btn bare" id="mDelete" title="Delete meeting"><svg viewBox="0 0 16 16"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg></button>'}
      </div>
    </div>
    ${m.error ? `<div class="waiting" style="padding:10px 14px"><div class="text" style="margin:0">${esc(m.error)}</div></div>` : ''}
    ${!s.canTranscribe || !s.canSummarize ? `<details class="setup-details" ${!s.canTranscribe ? 'open' : ''}><summary>Setup ${!s.canTranscribe ? '— transcription is off' : '— notes are off'}</summary>${setupCardHTML(s)}</details>` : ''}
    <div class="meeting-grid">
      <div class="card transcript-card">
        <div class="mcard-head" style="padding:12px 14px 0">Transcript <span class="hint">${m.segments.length} lines</span></div>
        <div class="transcript" id="transcript">${m.segments.map((g) => `<div class="seg"><span class="who ${g.who}">${g.who === 'you' ? 'You' : 'Them'}</span><span class="t mono">${fmtClock(g.at)}</span><span class="tx">${esc(g.text)}</span></div>`).join('') || `<div class="hint" style="padding:8px 0">${live ? (s.canTranscribe ? 'Listening… lines appear after each pause.' : 'Recording. Add a transcription service in Setup to get text.') : 'Nothing was transcribed.'}</div>`}</div>
      </div>
      <div class="meeting-side">
        <div class="card mcard">
          <div class="mcard-head">Notes <span class="hint">${m.notesAt ? `updated ${new Date(m.notesAt).toLocaleTimeString()}` : s.canSummarize ? 'appear as the call goes' : 'need a notes service'}</span><span class="card-spacer"></span>
            ${s.canSummarize ? '<button class="link" id="mRefresh">Refresh</button>' : ''}<button class="link" id="mEditNotes">${meetingsUI.editingNotes ? 'Done' : 'Edit'}</button></div>
          ${m.summary ? `<p class="summary">${esc(m.summary)}</p>` : ''}
          ${meetingsUI.editingNotes
            ? `<textarea class="notes-edit" id="mNotesEdit">${esc((m.notes || []).join('\n'))}</textarea>`
            : `<ul class="notes">${(m.notes || []).map((n) => `<li>${esc(n)}</li>`).join('') || '<li class="hint">—</li>'}</ul>`}
        </div>
        <div class="card mcard">
          <div class="mcard-head">Action items <span class="hint">${(m.actionItems || []).length}</span></div>
          ${(m.actionItems || []).map((a, i) => `<label class="action"><input type="checkbox" data-ai="${i}" ${a.done ? 'checked' : ''}><span class="${a.done ? 'done' : ''}">${esc(a.text)}${a.owner ? ` <span class="tag">${esc(a.owner)}</span>` : ''}</span></label>`).join('') || '<div class="hint">None yet.</div>'}
        </div>
        <div class="card mcard">
          <div class="mcard-head">Ask about this call</div>
          <div class="asks">${asks.map((a) => `<div class="ask-q">${esc(a.q)}</div><div class="ask-a">${a.a == null ? '<span class="hint">Thinking…</span>' : esc(a.a)}</div>`).join('')}</div>
          <div class="row"><input class="input" id="mAsk" placeholder="${s.canSummarize ? 'What did they say about the deadline?' : 'Needs a notes service (Setup)'}" ${s.canSummarize ? '' : 'disabled'}><button class="btn" id="mAskBtn" ${s.canSummarize ? '' : 'disabled'}>Ask</button></div>
        </div>
      </div>
    </div>`;
  bindSetup();
  const tr = $('#transcript');
  if (tr) tr.scrollTop = atBottom ? tr.scrollHeight : scrollT;
  if ($('#mStop')) $('#mStop').onclick = stopRecording;
  $('#mFolder').onclick = () => window.udha.meetings.openFolder(m.id);
  if ($('#mDelete')) $('#mDelete').onclick = () => {
    openSheet('#settingsSheet', `<h2>Delete “${esc(m.title)}”?</h2><p class="lede">Its audio, transcript and notes are deleted from this PC.</p>
      <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="mDelOK">Delete</button></div>`);
    $('#mDelOK').onclick = async () => { closeSheets(); await window.udha.meetings.remove(m.id); meetingsUI.selected = null; refreshMeetings(); };
  };
  $('#mTitle').ondblclick = async () => { const t = await askText('Rename meeting', m.title, 'Rename'); if (t) window.udha.meetings.rename(m.id, t); };
  if ($('#mRefresh')) $('#mRefresh').onclick = () => window.udha.meetings.refreshNotes(m.id);
  $('#mEditNotes').onclick = async () => {
    if (meetingsUI.editingNotes && $('#mNotesEdit')) await window.udha.meetings.updateNotes(m.id, $('#mNotesEdit').value);
    meetingsUI.editingNotes = !meetingsUI.editingNotes;
    renderMeetingPane();
  };
  pane.querySelectorAll('[data-ai]').forEach((c) => { c.onchange = () => window.udha.meetings.actionDone(m.id, Number(c.dataset.ai), c.checked); });
  const ask = async () => {
    const q = $('#mAsk').value.trim();
    if (!q) return;
    const entry = { q, a: null };
    meetingsUI.asks.set(m.id, [...asks, entry]);
    renderMeetingPane();
    try { entry.a = await window.udha.meetings.ask(m.id, q); } catch (err) { entry.a = String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''); }
    if (meetingsUI.selected === m.id) renderMeetingPane();
  };
  $('#mAskBtn').onclick = ask;
  $('#mAsk').addEventListener('keydown', (e) => { if (e.key === 'Enter') ask(); });
}

window.udha.meetings.onUpdated((m) => {
  if (state.section !== 'meetings') return;
  const known = meetingsUI.list.find((x) => x.id === m.id);
  if (known) { known.segmentCount = m.segments.length; known.title = m.title; known.endedAt = m.endedAt; renderMeetingsList(); } else refreshMeetings();
  // Don't yank the notes editor or a half-typed question out from under the user.
  if (m.id === meetingsUI.selected && !meetingsUI.editingNotes && document.activeElement !== $('#mAsk')) renderMeetingPane();
});
window.udha.meetings.onRemoved(() => { if (state.section === 'meetings') refreshMeetings(); });

registerSection('meetings', {
  async show() {
    meetingsUI.setup = await window.udha.meetings.setup();
    await refreshMeetings();
  },
});
