// Videos (Recordings/ on the mac): screen + camera recordings with captions.
// The renderer composites and encodes (MediaRecorder); main streams the bytes
// to disk, transcribes for captions (word timings → cues), translates them,
// and stores the burned-in landscape / vertical masters next to the original.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { EventEmitter } = require('events');

/** Scribe words → caption cues of at most ~42 chars / 3.5 s, split at pauses. */
function wordsToCues(words) {
  const cues = [];
  let cur = null;
  for (const w of words || []) {
    if (!w || w.type === 'spacing' || typeof w.start !== 'number') continue;
    const text = String(w.text || '').trim();
    if (!text) continue;
    const gap = cur ? w.start - cur.end : 0;
    if (!cur || (cur.text + ' ' + text).length > 42 || w.end - cur.start > 3.5 || gap > 0.8) {
      if (cur) cues.push(cur);
      cur = { start: w.start, end: w.end, text };
    } else {
      cur.text += ` ${text}`;
      cur.end = w.end;
    }
  }
  if (cur) cues.push(cur);
  return cues.map((c) => ({ start: Math.round(c.start * 1000), end: Math.round(c.end * 1000), text: c.text.replace(/\s+([,.!?;:])/g, '$1') }));
}

class Recordings extends EventEmitter {
  constructor({ dataDir, meetings }) {
    super();
    this.dir = path.join(dataDir, 'Recordings');
    this.meetings = meetings;   // reuses its STT + LLM setup
    this.streams = new Map();
  }

  folder(id) {
    if (!/^[\w-]+$/.test(String(id))) throw new Error('bad id');
    return path.join(this.dir, id);
  }
  metaFile(id) { return path.join(this.folder(id), 'recording.json'); }

  list() {
    let ids = [];
    try { ids = fs.readdirSync(this.dir); } catch { return []; }
    return ids.map((id) => this.get(id)).filter(Boolean).sort((a, b) => b.createdAt - a.createdAt);
  }

  get(id) {
    try { return JSON.parse(fs.readFileSync(this.metaFile(id), 'utf8')); } catch { return null; }
  }

  save(r) {
    fs.mkdirSync(this.folder(r.id), { recursive: true });
    fs.writeFileSync(`${this.metaFile(r.id)}.tmp`, JSON.stringify(r, null, 2));
    fs.renameSync(`${this.metaFile(r.id)}.tmp`, this.metaFile(r.id));
    this.emit('updated', r);
    return r;
  }

  /** Begin a file that chunks are appended to: kind 'original' or an export name. */
  begin(id, kind) {
    const file = path.join(this.folder(id), `${kind}.webm`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    this.streams.set(`${id}:${kind}`, fs.createWriteStream(file));
    return file;
  }

  create(opts = {}) {
    const now = new Date();
    const id = `${now.toISOString().slice(0, 19).replace(/[-:T]/g, '')}-${crypto.randomBytes(3).toString('hex')}`;
    const r = {
      id, title: `Recording ${now.toLocaleDateString()} ${now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`,
      createdAt: now.getTime(), durationMs: 0, camera: !!opts.camera, width: opts.width || 0, height: opts.height || 0,
      captions: [], captionLanguage: null, translations: {}, exports: {}, status: 'recording', error: null,
    };
    this.save(r);
    this.begin(id, 'original');
    return r;
  }

  append(id, kind, bytes) {
    const s = this.streams.get(`${id}:${kind}`);
    if (s) s.write(Buffer.from(bytes));
  }

  async finish(id, kind, durationMs) {
    const key = `${id}:${kind}`;
    const s = this.streams.get(key);
    if (s) { await new Promise((r) => s.end(r)); this.streams.delete(key); }
    const r = this.get(id);
    if (!r) return null;
    if (kind === 'original') {
      r.durationMs = durationMs || r.durationMs;
      r.status = 'ready';
      this.save(r);
      if (this.meetings.canTranscribe()) this.caption(id);
    } else {
      r.exports = { ...(r.exports || {}), [kind]: { at: Date.now(), file: `${kind}.webm` } };
      this.save(r);
    }
    return r;
  }

  filePath(id, kind = 'original') { return path.join(this.folder(id), `${kind}.webm`); }

  async caption(id) {
    const r = this.get(id);
    if (!r) return null;
    r.status = 'captioning'; r.error = null; this.save(r);
    try {
      const words = await this.transcribeWords(this.filePath(id));
      const fresh = this.get(id);
      fresh.captions = wordsToCues(words);
      fresh.status = 'ready';
      this.save(fresh);
    } catch (err) {
      const fresh = this.get(id);
      fresh.status = 'ready'; fresh.error = `Captions: ${err.message}`;
      this.save(fresh);
    }
    return this.get(id);
  }

  async transcribeWords(file) {
    const base = this.meetings.cfg().sttBaseURL;
    const key = this.meetings.secrets.get('elevenlabs_api_key');
    if (!base && !key) throw new Error('add an ElevenLabs key or a local Whisper URL in Meetings → Setup');
    const form = new FormData();
    form.append('model_id', 'scribe_v1');
    form.append('file', new Blob([fs.readFileSync(file)], { type: 'video/webm' }), path.basename(file));
    const url = base ? base.replace(/\/$/, '') : 'https://api.elevenlabs.io/v1/speech-to-text';
    const res = await fetch(url, { method: 'POST', headers: key && !base ? { 'xi-api-key': key } : {}, body: form, signal: AbortSignal.timeout(600000) });
    if (!res.ok) throw new Error(`${res.status} ${(await res.text()).slice(0, 160)}`);
    const body = await res.json();
    if (Array.isArray(body.words) && body.words.length) return body.words;
    // No word timings: one cue spanning the clip.
    return body.text ? [{ text: body.text, start: 0, end: 3.5, type: 'word' }] : [];
  }

  setCaptions(id, cues, lang) {
    const r = this.get(id);
    if (!r) return null;
    const clean = (cues || []).map((c) => ({ start: Math.max(0, Math.round(c.start)), end: Math.max(0, Math.round(c.end)), text: String(c.text || '').slice(0, 200) }))
      .filter((c) => c.end > c.start && c.text.trim());
    if (lang) r.translations = { ...(r.translations || {}), [lang]: clean }; else r.captions = clean;
    return this.save(r);
  }

  /** Translate the caption track line by line (same notes backend as Meetings). */
  async translate(id, language) {
    const r = this.get(id);
    if (!r || !r.captions.length) throw new Error('Nothing to translate yet');
    const lines = r.captions.map((c, i) => `${i + 1}. ${c.text}`).join('\n');
    const prompt = `Translate each numbered caption line into ${language}. Keep the numbering and one line per caption; output only the translated lines.\n\n${lines}`;
    let out;
    const client = this.meetings.anthropic();
    if (client) {
      const res = await client.beta.messages.create({
        model: 'claude-opus-5-5', max_tokens: 16000,
        betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default',
        output_config: { effort: 'low' },
        messages: [{ role: 'user', content: prompt }],
      });
      if (res.stop_reason === 'refusal') throw new Error('the model declined to translate this');
      out = res.content.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
    } else {
      const local = this.meetings.local();
      if (!local.baseURL) throw new Error('Add an Anthropic key or an Ollama server in Meetings → Setup');
      const res = await fetch(`${local.baseURL.replace(/\/$/, '')}/api/chat`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(300000),
        body: JSON.stringify({ model: local.model, stream: false, messages: [{ role: 'user', content: prompt }] }),
      });
      if (!res.ok) throw new Error(`Ollama ${res.status}`);
      out = (await res.json()).message.content;
    }
    const byNum = new Map();
    for (const line of out.split('\n')) {
      const m = line.match(/^\s*(\d+)[.)]\s*(.*)$/);
      if (m) byNum.set(Number(m[1]), m[2].trim());
    }
    const cues = r.captions.map((c, i) => ({ ...c, text: byNum.get(i + 1) || c.text }));
    return this.setCaptions(id, cues, language);
  }

  rename(id, title) { const r = this.get(id); if (r && title) { r.title = String(title).slice(0, 120); this.save(r); } }

  remove(id) {
    fs.rmSync(this.folder(id), { recursive: true, force: true });
    this.emit('removed', id);
  }
}

module.exports = { Recordings, wordsToCues };
