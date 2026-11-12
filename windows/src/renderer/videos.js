'use strict';
/* Videos section (VideosPane.swift): screen recording with an optional camera
   bubble, captions from the transcript, caption editing, translation, and
   landscape / vertical masters with the captions burned in. Uses app.js
   globals ($, esc, state, openSheet, closeSheets, askText, setSection,
   registerSection). */

const videosUI = { list: [], selected: null, rec: null, track: '', exporting: null };

function fmtTime(ms, tenths = false) {
  const s = Math.max(0, ms) / 1000;
  const m = Math.floor(s / 60);
  const sec = s - m * 60;
  return `${m}:${tenths ? sec.toFixed(1).padStart(4, '0') : String(Math.floor(sec)).padStart(2, '0')}`;
}
function parseTime(text) {
  const m = String(text).trim().match(/^(?:(\d+):)?(\d+(?:\.\d+)?)$/);
  return m ? Math.round(((Number(m[1] || 0) * 60) + Number(m[2])) * 1000) : null;
}

// ---------- Recording ----------

function openRecordSheet() {
  openSheet('#newSheet', `
    <h2>New recording</h2>
    <p class="lede">Records your screen. Udha minimizes after the countdown; press <kbd>Ctrl Alt S</kbd> or open Udha to stop.</p>
    <div class="switch-row"><div class="t"><b>Microphone</b><span>Your voice — captions come from this.</span></div><input type="checkbox" class="switch" id="vMic" checked></div>
    <div class="switch-row"><div class="t"><b>System audio</b><span>What the computer plays.</span></div><input type="checkbox" class="switch" id="vSys"></div>
    <div class="switch-row"><div class="t"><b>Camera bubble</b><span>Your camera in a circle in the corner.</span></div><input type="checkbox" class="switch" id="vCam"></div>
    <div class="error hidden" id="vErr"></div>
    <div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="vGo"><span class="rec-dot"></span>Start recording</button></div>`);
  $('#vGo').onclick = async () => {
    try {
      await startVideo({ mic: $('#vMic').checked, sys: $('#vSys').checked, cam: $('#vCam').checked });
    } catch (err) {
      $('#vErr').textContent = String(err.message || err);
      $('#vErr').classList.remove('hidden');
    }
  };
}

async function startVideo({ mic, sys, cam }) {
  const display = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: 30 }, audio: true });
  const screenTrack = display.getVideoTracks()[0];
  const camStream = cam ? await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 640 } }).catch(() => null) : null;
  const micStream = mic ? await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }).catch(() => null) : null;
  closeSheets();

  // Audio: mic and/or system loopback, mixed to one track.
  // A suspended context stalls the whole recording (the muxer waits for audio),
  // so resume it, and add no audio track at all when nothing feeds it.
  const actx = new AudioContext();
  await actx.resume();
  const dest = actx.createMediaStreamDestination();
  let audioSources = 0;
  if (micStream) { actx.createMediaStreamSource(micStream).connect(dest); audioSources++; }
  if (sys && display.getAudioTracks().length) { actx.createMediaStreamSource(new MediaStream(display.getAudioTracks())).connect(dest); audioSources++; } else display.getAudioTracks().forEach((t) => t.stop());

  // Video: the screen, plus the camera bubble composited on a canvas.
  const set = screenTrack.getSettings();
  const scale = Math.min(1, 1920 / (set.width || 1920));
  const W = Math.round((set.width || 1920) * scale / 2) * 2;
  const H = Math.round((set.height || 1080) * scale / 2) * 2;
  let videoTrack = screenTrack;
  let drawTimer = null;
  if (camStream) {
    const canvas = document.createElement('canvas');
    canvas.width = W; canvas.height = H;
    const g = canvas.getContext('2d');
    const sv = Object.assign(document.createElement('video'), { srcObject: new MediaStream([screenTrack]), muted: true });
    const cv = Object.assign(document.createElement('video'), { srcObject: camStream, muted: true });
    await Promise.all([sv.play(), cv.play()]);
    const d = Math.round(H * 0.22);
    drawTimer = setInterval(() => {
      g.drawImage(sv, 0, 0, W, H);
      const x = W - d - 32; const y = H - d - 32;
      g.save(); g.beginPath(); g.arc(x + d / 2, y + d / 2, d / 2, 0, Math.PI * 2); g.clip();
      const s = Math.min(cv.videoWidth, cv.videoHeight) || 1;
      g.drawImage(cv, (cv.videoWidth - s) / 2, (cv.videoHeight - s) / 2, s, s, x, y, d, d);
      g.restore();
      g.lineWidth = 4; g.strokeStyle = 'rgba(255,255,255,0.9)'; g.beginPath(); g.arc(x + d / 2, y + d / 2, d / 2, 0, Math.PI * 2); g.stroke();
    }, 1000 / 30);
    videoTrack = canvas.captureStream(30).getVideoTracks()[0];
  }

  // Countdown, then minimize and record.
  await countdown(3);
  const r = await window.udha.videos.create({ camera: !!camStream, width: W, height: H });
  const tracks = [videoTrack, ...(audioSources ? dest.stream.getAudioTracks() : [])];
  const mime = audioSources
    ? (MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus') ? 'video/webm;codecs=vp9,opus' : 'video/webm')
    : (MediaRecorder.isTypeSupported('video/webm;codecs=vp9') ? 'video/webm;codecs=vp9' : 'video/webm');
  const rec = new MediaRecorder(new MediaStream(tracks), { mimeType: mime, videoBitsPerSecond: 6_000_000 });
  rec.ondataavailable = async (e) => { if (e.data && e.data.size) window.udha.videos.append(r.id, 'original', new Uint8Array(await e.data.arrayBuffer())); };
  const t0 = Date.now();
  videosUI.rec = {
    id: r.id, rec, t0,
    stop: () => new Promise((resolve) => {
      rec.onstop = async () => {
        clearInterval(drawTimer);
        [display, camStream, micStream].forEach((s) => s && s.getTracks().forEach((t) => t.stop()));
        actx.close();
        setTimeout(async () => { await window.udha.videos.finish(r.id, 'original', Date.now() - t0); resolve(); }, 300);
      };
      rec.stop();
    }),
  };
  screenTrack.addEventListener('ended', stopVideo);   // the share was ended from Windows
  rec.start(1000);
  window.udha.videos.recordingState(true);
  document.querySelector('.nav-row[data-section="videos"]').classList.add('recording');
  videosUI.selected = r.id;
  refreshVideos();
}

function countdown(n) {
  return new Promise((resolve) => {
    const el = document.createElement('div');
    el.className = 'countdown';
    document.body.appendChild(el);
    const step = (k) => {
      // Give the compositor a beat to drop the overlay, or frame one shows the "1".
      if (k === 0) { el.remove(); setTimeout(resolve, 250); return; }
      el.textContent = String(k);
      setTimeout(() => step(k - 1), 900);
    };
    step(n);
  });
}

async function stopVideo() {
  const rec = videosUI.rec;
  if (!rec) return;
  videosUI.rec = null;
  window.udha.videos.recordingState(false);
  document.querySelector('.nav-row[data-section="videos"]').classList.remove('recording');
  await rec.stop();
  videosUI.selected = rec.id;
  if (state.section !== 'videos') setSection('videos'); else refreshVideos();
}

// ---------- List + pane ----------

async function refreshVideos() {
  videosUI.list = await window.udha.videos.list();
  if (!videosUI.selected && videosUI.list.length) videosUI.selected = videosUI.list[0].id;
  renderVideosList();
  renderVideoPane();
}

function renderVideosList() {
  $('#videosCount').textContent = videosUI.list.length ? String(videosUI.list.length) : '';
  $('#videoRecBtn').innerHTML = videosUI.rec ? '<span class="rec-dot"></span>Stop' : '<span class="rec-dot"></span>Record';
  $('#videosList').innerHTML = videosUI.list.map((v) => {
    const live = videosUI.rec && videosUI.rec.id === v.id;
    return `<div class="card-row ${v.id === videosUI.selected ? 'selected' : ''}" data-video="${v.id}">
      <div class="card-top"><span class="card-name">${esc(v.title)}</span><span class="card-spacer"></span><span class="card-model">${live ? '' : fmtTime(v.durationMs)}</span></div>
      <div class="card-state">${live ? '<span class="ping active" style="--dot:var(--bad)"></span><span class="card-state-label" style="color:var(--bad-ink)">Recording</span>'
        : v.status === 'captioning' ? '<span class="ping active" style="--dot:var(--accent)"></span><span class="card-state-label" style="color:var(--accent-ink)">Captioning</span>'
        : `<span class="ping" style="--dot:var(--tertiary)"></span><span class="card-state-label" style="color:var(--secondary)">${v.captions.length} captions</span>`}</div>
      <div class="card-detail">${new Date(v.createdAt).toLocaleString()}${v.camera ? ' · camera' : ''}</div>
    </div>`;
  }).join('') || '<div class="board-empty">No recordings yet.<br>Press <b>Record</b>.</div>';
}

$('#videosList').addEventListener('click', (e) => {
  const row = e.target.closest('[data-video]');
  if (row) { videosUI.selected = row.dataset.video; videosUI.track = ''; renderVideosList(); renderVideoPane(); }
});
$('#videoRecBtn').onclick = () => (videosUI.rec ? stopVideo() : openRecordSheet());

function cuesOf(v) { return videosUI.track ? (v.translations || {})[videosUI.track] || [] : v.captions; }

async function renderVideoPane() {
  const pane = $('#videosPane');
  const v = videosUI.selected ? await window.udha.videos.get(videosUI.selected) : null;
  if (!v) {
    pane.innerHTML = `<div class="empty"><div class="title">Videos</div><div class="text">Record your screen, with your camera in a bubble if you like. Udha captions it from your voice, lets you fix the captions, and exports landscape and vertical versions with the captions burned in.</div><button class="btn danger" id="vEmptyRec"><span class="rec-dot"></span>Record</button></div>`;
    $('#vEmptyRec').onclick = openRecordSheet;
    return;
  }
  if (videosUI.rec && videosUI.rec.id === v.id) {
    pane.innerHTML = `<div class="empty"><div class="title">Recording…</div><div class="text">Udha is recording your screen. Stop here, or press <kbd>Ctrl Alt S</kbd> anywhere.</div><button class="btn danger" id="vStopBig">Stop recording</button></div>`;
    $('#vStopBig').onclick = stopVideo;
    return;
  }
  const url = await window.udha.videos.fileURL(v.id, 'original');
  const tracks = ['', ...Object.keys(v.translations || {})];
  const cues = cuesOf(v);
  const ex = videosUI.exporting && videosUI.exporting.id === v.id ? videosUI.exporting : null;
  pane.innerHTML = `
    <div class="pane-head">
      <div class="pane-title-wrap">
        <div class="pane-title" id="vTitle" title="Double-click to rename">${esc(v.title)}</div>
        <div class="pane-sub"><span>${new Date(v.createdAt).toLocaleString()} · ${fmtTime(v.durationMs)}${v.width ? ` · ${v.width}×${v.height}` : ''}</span></div>
      </div>
      <div class="pane-actions">
        <button class="btn" id="vFolder">Open folder</button>
        <button class="btn bare" id="vDelete" title="Delete recording"><svg viewBox="0 0 16 16"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg></button>
      </div>
    </div>
    ${v.error ? `<div class="waiting" style="padding:10px 14px"><div class="text" style="margin:0">${esc(v.error)}</div></div>` : ''}
    <div class="video-grid">
      <div class="card player-card">
        <div class="player"><video id="vPlayer" src="${esc(url)}" controls preload="metadata"></video><div class="cap-overlay" id="vCap"></div></div>
      </div>
      <div class="meeting-side">
        <div class="card mcard cues-card">
          <div class="mcard-head">Captions
            <select class="mini-select" id="vTrack">${tracks.map((t) => `<option value="${esc(t)}" ${t === videosUI.track ? 'selected' : ''}>${t ? esc(t) : 'Original'}</option>`).join('')}</select>
            <span class="card-spacer"></span>
            <button class="link" id="vRecaption">${v.status === 'captioning' ? 'Captioning…' : v.captions.length ? 'Re-caption' : 'Caption it'}</button>
            <button class="link" id="vTranslate">Translate…</button>
          </div>
          <div class="cues" id="vCues">${cues.map((c, i) => `<div class="cue" data-i="${i}">
              <input class="cue-t mono" data-f="start" value="${fmtTime(c.start, true)}"><input class="cue-t mono" data-f="end" value="${fmtTime(c.end, true)}">
              <input class="cue-x" data-f="text" value="${esc(c.text)}"><button class="cue-del" title="Delete caption">×</button></div>`).join('')
            || `<div class="hint">${v.status === 'captioning' ? 'Transcribing…' : 'No captions yet. They come from the recording\'s audio (needs the transcription setup in Meetings).'}</div>`}</div>
        </div>
        <div class="card mcard">
          <div class="mcard-head">Export <span class="hint">captions burned in${videosUI.track ? ` · ${esc(videosUI.track)}` : ''}</span></div>
          ${ex ? `<div class="umeter"><div class="umeter-top"><span>Exporting ${ex.kind}</span><span>${Math.round(ex.progress * 100)}%</span></div><div class="meter"><div class="meter-fill" style="width:${ex.progress * 100}%"></div></div></div>` : ''}
          <div class="row">
            <button class="btn" id="vExpL" ${ex ? 'disabled' : ''}>Landscape 16:9</button>
            <button class="btn" id="vExpV" ${ex ? 'disabled' : ''}>Vertical 9:16</button>
          </div>
          ${Object.entries(v.exports || {}).map(([k, e]) => `<div class="kv"><span>${esc(k)}</span><button class="link" data-show="${esc(k)}">Show file</button> <span class="hint">${new Date(e.at).toLocaleTimeString()}</span></div>`).join('')}
          <div class="hint" style="margin-top:6px">Exports play the recording through once, so they take as long as the video.</div>
        </div>
      </div>
    </div>`;

  const player = $('#vPlayer');
  // MediaRecorder WebM has no duration until the end is seen; make it seekable.
  player.addEventListener('loadedmetadata', () => {
    if (player.duration === Infinity) {
      player.currentTime = 1e101;
      player.addEventListener('timeupdate', function fix() { player.removeEventListener('timeupdate', fix); player.currentTime = 0; });
    }
  });
  const capEl = $('#vCap');
  const showCap = () => {
    const t = player.currentTime * 1000;
    const c = cues.find((x) => t >= x.start && t <= x.end);
    capEl.textContent = c ? c.text : '';
    capEl.style.display = c ? '' : 'none';
    document.querySelectorAll('.cue').forEach((row) => row.classList.toggle('on', c && cues[Number(row.dataset.i)] === c));
  };
  player.addEventListener('timeupdate', showCap);
  showCap();

  $('#vTitle').ondblclick = async () => { const t = await askText('Rename recording', v.title, 'Rename'); if (t) window.udha.videos.rename(v.id, t); };
  $('#vFolder').onclick = () => window.udha.videos.openFolder(v.id);
  $('#vDelete').onclick = () => {
    openSheet('#settingsSheet', `<h2>Delete “${esc(v.title)}”?</h2><p class="lede">The recording, its captions and exports are deleted from this PC.</p><div class="sheet-actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="vDelOK">Delete</button></div>`);
    $('#vDelOK').onclick = async () => { closeSheets(); await window.udha.videos.remove(v.id); videosUI.selected = null; refreshVideos(); };
  };
  $('#vTrack').onchange = (e) => { videosUI.track = e.target.value; renderVideoPane(); };
  $('#vRecaption').onclick = () => window.udha.videos.caption(v.id);
  $('#vTranslate').onclick = async () => {
    const lang = await askText('Translate captions into…', 'Albanian', 'Translate');
    if (!lang) return;
    try { await window.udha.videos.translate(v.id, lang); videosUI.track = lang; renderVideoPane(); } catch (err) {
      openSheet('#settingsSheet', `<h2>Couldn't translate</h2><p class="lede">${esc(String(err.message || err).replace(/^Error invoking remote method '[^']+': (Error: )?/, ''))}</p><div class="sheet-actions"><button class="btn primary" data-close>OK</button></div>`);
    }
  };
  // Cue editing: click to seek, edit in place (saved on change).
  const saveCues = () => window.udha.videos.setCaptions(v.id, cues, videosUI.track || null);
  $('#vCues').addEventListener('click', (e) => {
    const row = e.target.closest('.cue');
    if (!row) return;
    const i = Number(row.dataset.i);
    if (e.target.classList.contains('cue-del')) { cues.splice(i, 1); saveCues(); return; }
    if (e.target.tagName !== 'INPUT') player.currentTime = cues[i].start / 1000 + 0.01;
  });
  $('#vCues').addEventListener('focusin', (e) => { const row = e.target.closest('.cue'); if (row) player.currentTime = cues[Number(row.dataset.i)].start / 1000 + 0.01; });
  $('#vCues').addEventListener('change', (e) => {
    const row = e.target.closest('.cue');
    if (!row) return;
    const c = cues[Number(row.dataset.i)];
    const f = e.target.dataset.f;
    if (f === 'text') c.text = e.target.value;
    else { const t = parseTime(e.target.value); if (t != null) c[f] = t; }
    saveCues();
  });
  $('#vExpL').onclick = () => exportVideo(v, 'landscape', url, cues);
  $('#vExpV').onclick = () => exportVideo(v, 'vertical', url, cues);
  pane.querySelectorAll('[data-show]').forEach((b) => { b.onclick = () => window.udha.videos.showFile(v.id, b.dataset.show); });
}

// ---------- Export (captions burned in) ----------

function wrapLines(g, text, maxW) {
  const words = text.split(/\s+/);
  const lines = [];
  let line = '';
  for (const w of words) {
    const next = line ? `${line} ${w}` : w;
    if (g.measureText(next).width > maxW && line) { lines.push(line); line = w; } else line = next;
  }
  if (line) lines.push(line);
  return lines.slice(0, 3);
}

function drawCaption(g, text, W, H, vertical) {
  if (!text) return;
  const size = Math.round((vertical ? W : H) * (vertical ? 0.058 : 0.045));
  g.font = `600 ${size}px "Segoe UI", sans-serif`;
  g.textAlign = 'center'; g.textBaseline = 'middle';
  const lines = wrapLines(g, text, W * (vertical ? 0.84 : 0.7));
  const lh = size * 1.3;
  const baseY = vertical ? H * 0.74 : H - size * 1.6 - (lines.length - 1) * lh;
  lines.forEach((l, i) => {
    const y = baseY + i * lh;
    const w = g.measureText(l).width + size * 0.9;
    g.fillStyle = 'rgba(10,10,12,0.72)';
    const x0 = W / 2 - w / 2; const r = size * 0.28;
    g.beginPath(); g.roundRect(x0, y - lh / 2, w, lh, r); g.fill();
    g.fillStyle = '#fff';
    g.fillText(l, W / 2, y + size * 0.04);
  });
}

async function exportVideo(v, kind, url, cues) {
  if (videosUI.exporting) return;
  const vertical = kind === 'vertical';
  const W = vertical ? 1080 : 1920; const H = vertical ? 1920 : 1080;
  const name = videosUI.track ? `${kind}-${videosUI.track.toLowerCase().replace(/[^\w]+/g, '-')}` : kind;
  videosUI.exporting = { id: v.id, kind: name, progress: 0 };
  renderVideoPane();
  const src = Object.assign(document.createElement('video'), { src: url, muted: false, preload: 'auto' });
  src.volume = 0.0001;  // the element must play audio to capture it; keep it inaudible
  await new Promise((r) => src.addEventListener('loadeddata', r, { once: true }));
  const canvas = document.createElement('canvas');
  canvas.width = W; canvas.height = H;
  const g = canvas.getContext('2d');
  const srcStream = src.captureStream();
  await src.play(); src.pause(); src.currentTime = 0;   // tracks appear once the element has played
  const audio = srcStream.getAudioTracks();
  const out = new MediaStream([...canvas.captureStream(30).getVideoTracks(), ...audio]);
  const mime = audio.length
    ? (MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus') ? 'video/webm;codecs=vp9,opus' : 'video/webm')
    : (MediaRecorder.isTypeSupported('video/webm;codecs=vp9') ? 'video/webm;codecs=vp9' : 'video/webm');
  await window.udha.videos.begin(v.id, name);
  const rec = new MediaRecorder(out, { mimeType: mime, videoBitsPerSecond: 8_000_000 });
  rec.ondataavailable = async (e) => { if (e.data && e.data.size) window.udha.videos.append(v.id, name, new Uint8Array(await e.data.arrayBuffer())); };
  const durMs = v.durationMs || 1;
  const draw = () => {
    const vw = src.videoWidth || 16; const vh = src.videoHeight || 9;
    g.fillStyle = '#000'; g.fillRect(0, 0, W, H);
    if (vertical) {
      // Blurred, darkened cover fill behind the fitted frame.
      const cover = Math.max(W / vw, H / vh);
      g.filter = 'blur(28px) brightness(0.45)';
      g.drawImage(src, (W - vw * cover) / 2, (H - vh * cover) / 2, vw * cover, vh * cover);
      g.filter = 'none';
    }
    const fit = Math.min(W / vw, H / vh);
    const dw = vw * fit; const dh = vh * fit;
    g.drawImage(src, (W - dw) / 2, vertical ? H * 0.32 - dh / 2 : (H - dh) / 2, dw, dh);
    const t = src.currentTime * 1000;
    const c = cues.find((x) => t >= x.start && t <= x.end);
    drawCaption(g, c ? c.text : '', W, H, vertical);
    videosUI.exporting.progress = Math.min(1, t / durMs);
    const bar = document.querySelector('.player-card + .meeting-side .meter-fill');
    if (bar) bar.style.width = `${videosUI.exporting.progress * 100}%`;
  };
  const timer = setInterval(draw, 1000 / 30);
  rec.start(1000);
  await src.play();
  await new Promise((r) => src.addEventListener('ended', r, { once: true }));
  clearInterval(timer);
  await new Promise((r) => { rec.onstop = r; rec.stop(); });
  await new Promise((r) => setTimeout(r, 300));
  await window.udha.videos.finish(v.id, name);
  videosUI.exporting = null;
  renderVideoPane();
}

window.udha.videos.onUpdated((v) => {
  if (state.section !== 'videos') return;
  const known = videosUI.list.findIndex((x) => x.id === v.id);
  if (known >= 0) videosUI.list[known] = v; else videosUI.list.unshift(v);
  renderVideosList();
  // Don't rebuild the player (and lose its position) for caption edits typed here.
  const editing = document.activeElement && document.activeElement.closest && document.activeElement.closest('#vCues');
  if (v.id === videosUI.selected && !editing && !videosUI.exporting) renderVideoPane();
});
window.udha.videos.onRemoved(() => { if (state.section === 'videos') refreshVideos(); });
window.udha.videos.onStopRequest(() => stopVideo());

registerSection('videos', { show: refreshVideos });
