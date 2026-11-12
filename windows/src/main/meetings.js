// Meetings (Meetings/ on the mac): microphone and system audio arrive as two
// independent streams of chunks cut on silence ("You" and "Them" — no
// diarization needed), each chunk is transcribed, and the transcript turns
// into live notes and action items; "Ask" answers from the transcript.
//
// Transcription: ElevenLabs Scribe, or any endpoint with Scribe's
// {text, words[]} answer (a local Whisper server) at meetings.sttBaseURL.
// Notes / Ask: the Anthropic API (official SDK) or a local Ollama server.
// Recording and transcript storage work with neither notes backend.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { EventEmitter } = require('events');

const MODEL = 'claude-opus-5-5';

class Meetings extends EventEmitter {
  constructor({ dataDir, store, secrets }) {
    super();
    this.dir = path.join(dataDir, 'Meetings');
    this.store = store;
    this.secrets = secrets;
    this.cache = new Map();
    this.notesBusy = new Set();
    this._anthropic = null;
  }

  cfg() { return { sttBaseURL: '', ...(this.store.config.meetings || {}) }; }
  local() { return { baseURL: '', model: 'llama3.1', ...(this.store.config.localModel || {}) }; }

  // MARK: - Storage

  fileOf(id) { return path.join(this.dir, id, 'meeting.json'); }

  list() {
    let ids = [];
    try { ids = fs.readdirSync(this.dir); } catch { return []; }
    return ids.map((id) => this.get(id)).filter(Boolean)
      .map(({ segments, ...m }) => ({ ...m, segmentCount: segments.length }))
      .sort((a, b) => b.startedAt - a.startedAt);
  }

  get(id) {
    if (!/^[\w-]+$/.test(String(id))) return null;
    if (this.cache.has(id)) return this.cache.get(id);
    try {
      const m = JSON.parse(fs.readFileSync(this.fileOf(id), 'utf8'));
      this.cache.set(id, m);
      return m;
    } catch { return null; }
  }

  save(m) {
    this.cache.set(m.id, m);
    fs.mkdirSync(path.dirname(this.fileOf(m.id)), { recursive: true });
    fs.writeFileSync(`${this.fileOf(m.id)}.tmp`, JSON.stringify(m, null, 2));
    fs.renameSync(`${this.fileOf(m.id)}.tmp`, this.fileOf(m.id));
    this.emit('updated', m);
  }

  start(title) {
    const now = new Date();
    const stamp = now.toISOString().slice(0, 16).replace(/[-:T]/g, '');
    const id = `${stamp}-${crypto.randomBytes(3).toString('hex')}`;
    const m = {
      id, title: title || `Meeting ${now.toLocaleDateString()} ${now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`,
      startedAt: now.getTime(), endedAt: null, recording: true,
      segments: [], summary: '', notes: [], actionItems: [], notesAt: null, error: null,
    };
    this.save(m);
    return m;
  }

  stop(id) {
    const m = this.get(id);
    if (!m) return null;
    m.recording = false;
    m.endedAt = Date.now();
    this.save(m);
    this.refreshNotes(id, { force: true });
    return m;
  }

  rename(id, title) { const m = this.get(id); if (m && title) { m.title = String(title).slice(0, 120); this.save(m); } }

  remove(id) {
    if (!/^[\w-]+$/.test(String(id))) return;
    this.cache.delete(id);
    fs.rmSync(path.join(this.dir, id), { recursive: true, force: true });
    this.emit('removed', id);
  }

  setActionDone(id, index, done) {
    const m = this.get(id);
    if (m && m.actionItems[index]) { m.actionItems[index].done = !!done; this.save(m); }
  }

  updateNotes(id, text) {
    const m = this.get(id);
    if (!m) return;
    m.notes = String(text).split('\n').map((s) => s.replace(/^[-•*]\s*/, '').trim()).filter(Boolean);
    m.notesEdited = true;
    this.save(m);
  }

  // MARK: - Audio → transcript

  /** A chunk from the renderer: save it, transcribe it, append the segment. */
  async addChunk(id, who, offsetMs, bytes, mime) {
    const m = this.get(id);
    if (!m) return;
    const ext = /ogg/.test(mime) ? 'ogg' : 'webm';
    const audioDir = path.join(this.dir, id, 'audio');
    fs.mkdirSync(audioDir, { recursive: true });
    const file = path.join(audioDir, `${who === 'you' ? 'mic' : 'system'}-${String(offsetMs).padStart(9, '0')}.${ext}`);
    fs.writeFileSync(file, Buffer.from(bytes));
    try {
      const text = await this.transcribe(file, mime);
      if (text && text.trim()) {
        m.segments.push({ who, at: offsetMs, text: text.trim() });
        m.segments.sort((a, b) => a.at - b.at);
        m.error = null;
        this.save(m);
        this.refreshNotes(id);
      }
    } catch (err) {
      m.error = `Transcription: ${err.message}`;
      this.save(m);
    }
  }

  canTranscribe() { return !!(this.cfg().sttBaseURL || this.secrets.get('elevenlabs_api_key')); }
  canSummarize() { return !!(this.secrets.get('anthropic_api_key') || this.local().baseURL); }

  async transcribe(file, mime) {
    const base = this.cfg().sttBaseURL;
    const key = this.secrets.get('elevenlabs_api_key');
    if (!base && !key) throw new Error('add an ElevenLabs key or a local Whisper URL in Meetings → Setup');
    const form = new FormData();
    form.append('model_id', 'scribe_v1');
    form.append('file', new Blob([fs.readFileSync(file)], { type: mime || 'audio/webm' }), path.basename(file));
    const url = base ? base.replace(/\/$/, '') : 'https://api.elevenlabs.io/v1/speech-to-text';
    const res = await fetch(url, { method: 'POST', headers: key && !base ? { 'xi-api-key': key } : {}, body: form, signal: AbortSignal.timeout(120000) });
    if (!res.ok) throw new Error(`${res.status} ${(await res.text()).slice(0, 160)}`);
    const body = await res.json();
    return typeof body.text === 'string' ? body.text : '';
  }

  transcriptText(m) {
    const fmt = (ms) => { const s = Math.floor(ms / 1000); return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`; };
    return m.segments.map((s) => `[${fmt(s.at)}] ${s.who === 'you' ? 'You' : 'Them'}: ${s.text}`).join('\n');
  }

  // MARK: - Notes / Ask

  anthropic() {
    const key = this.secrets.get('anthropic_api_key');
    if (!key) return null;
    if (!this._anthropic || this._anthropicKey !== key) {
      const Anthropic = require('@anthropic-ai/sdk').default;
      this._anthropic = new Anthropic({ apiKey: key });
      this._anthropicKey = key;
    }
    return this._anthropic;
  }

  /** Re-summarize when enough new transcript arrived (or forced at stop). */
  async refreshNotes(id, { force = false } = {}) {
    const m = this.get(id);
    if (!m || !m.segments.length || this.notesBusy.has(id) || !this.canSummarize()) return;
    // Live notes at most once a minute, and only when the transcript grew.
    if (!force && m.notesAt && Date.now() - m.notesAt < 60000) return;
    if (!force && m.notesSegCount === m.segments.length) return;
    const segCount = m.segments.length;
    this.notesBusy.add(id);
    try {
      const out = await this.summarize(this.transcriptText(m));
      const fresh = this.get(id);
      if (out) {
        fresh.summary = out.summary || '';
        if (!fresh.notesEdited) fresh.notes = out.notes || [];
        const done = new Map((fresh.actionItems || []).map((a) => [a.text, a.done]));
        fresh.actionItems = (out.actionItems || []).map((a) => ({ ...a, done: done.get(a.text) || false }));
        fresh.notesAt = Date.now();
        fresh.notesSegCount = segCount;
        fresh.error = null;
        this.save(fresh);
      }
    } catch (err) {
      const fresh = this.get(id);
      fresh.error = `Notes: ${err.message}`;
      this.save(fresh);
    } finally {
      this.notesBusy.delete(id);
    }
  }

  async summarize(transcript) {
    const instructions = 'You take notes for a meeting from its transcript. "You" is the person recording; "Them" is everyone else on the call. Write a two-sentence summary, the key points as short notes, and action items (each with an owner when the transcript makes it clear). Use only what the transcript says.';
    const client = this.anthropic();
    if (client) {
      const { z } = require('zod');
      const { betaZodOutputFormat } = require('@anthropic-ai/sdk/helpers/beta/zod');
      const Schema = z.object({
        summary: z.string(),
        notes: z.array(z.string()),
        actionItems: z.array(z.object({ text: z.string(), owner: z.string().nullable() })),
      });
      const res = await client.beta.messages.parse({
        model: MODEL,
        max_tokens: 16000,
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        output_config: { effort: 'medium', format: betaZodOutputFormat(Schema) },
        system: instructions,
        messages: [{ role: 'user', content: `<transcript>\n${transcript}\n</transcript>` }],
      });
      if (res.stop_reason === 'refusal') throw new Error('the model declined to summarize this transcript');
      return res.parsed_output;
    }
    const local = this.local();
    if (!local.baseURL) return null;
    const res = await fetch(`${local.baseURL.replace(/\/$/, '')}/api/chat`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      signal: AbortSignal.timeout(180000),
      body: JSON.stringify({
        model: local.model, stream: false, format: 'json',
        messages: [
          { role: 'system', content: `${instructions} Answer as JSON: {"summary": string, "notes": string[], "actionItems": [{"text": string, "owner": string|null}]}` },
          { role: 'user', content: transcript },
        ],
      }),
    });
    if (!res.ok) throw new Error(`Ollama ${res.status}`);
    const body = await res.json();
    return JSON.parse(body.message.content);
  }

  async ask(id, question) {
    const m = this.get(id);
    if (!m) throw new Error('No such meeting');
    const transcript = this.transcriptText(m) || '(nothing transcribed yet)';
    const system = 'Answer questions about a meeting using only its transcript. "You" is the person asking; "Them" is everyone else. If the transcript does not say, say so. Be brief.';
    const client = this.anthropic();
    if (client) {
      const res = await client.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        betas: ['server-side-fallback-2026-07-01'],
        fallbacks: 'default',
        output_config: { effort: 'low' },
        system,
        messages: [{ role: 'user', content: `<transcript>\n${transcript}\n</transcript>\n\n${question}` }],
      });
      if (res.stop_reason === 'refusal') return 'The model declined to answer that.';
      return res.content.filter((b) => b.type === 'text').map((b) => b.text).join('\n').trim();
    }
    const local = this.local();
    if (!local.baseURL) throw new Error('Add an Anthropic key or an Ollama server in Meetings → Setup');
    const res = await fetch(`${local.baseURL.replace(/\/$/, '')}/api/chat`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(180000),
      body: JSON.stringify({ model: local.model, stream: false, messages: [{ role: 'system', content: system }, { role: 'user', content: `${transcript}\n\nQuestion: ${question}` }] }),
    });
    if (!res.ok) throw new Error(`Ollama ${res.status}`);
    return (await res.json()).message.content.trim();
  }
}

module.exports = { Meetings, MODEL };
