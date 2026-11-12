// Slack inbox (Slack/ + InboxPane on the mac): DMs and @-mentions from each
// connected workspace, filed per thread as they arrive, each stamped with when
// Udha saw it or that it was sent from Udha. Forward-only: connecting starts
// the record now; history is never backfilled. One user token per workspace
// (encrypted with the other secrets).
'use strict';

const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');

const API = process.env.UDHA_SLACK_API || 'https://slack.com/api';
const POLL_MS = 60000;
const IMS_PER_POLL = 20;   // conversations.history is Tier 3; spread DMs over polls

class SlackInbox extends EventEmitter {
  constructor({ dataDir, store, secrets }) {
    super();
    this.file = path.join(dataDir, 'slack-inbox.json');
    this.store = store;
    this.secrets = secrets;
    this.data = this.load();
    this.users = new Map();
    this.timer = null;
    this.polling = false;
  }

  load() {
    try { return { threads: {}, cursors: {}, ...JSON.parse(fs.readFileSync(this.file, 'utf8')) }; } catch { return { threads: {}, cursors: {} }; }
  }
  save() {
    fs.writeFileSync(`${this.file}.tmp`, JSON.stringify(this.data));
    fs.renameSync(`${this.file}.tmp`, this.file);
  }

  workspaces() { return this.store.config.slackWorkspaces || []; }

  async call(token, method, params = {}, post = false) {
    const url = new URL(`${API}/${method}`);
    const opts = { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(20000) };
    if (post) {
      opts.method = 'POST';
      opts.headers['content-type'] = 'application/json; charset=utf-8';
      opts.body = JSON.stringify(params);
    } else {
      for (const [k, v] of Object.entries(params)) if (v != null) url.searchParams.set(k, String(v));
    }
    const res = await fetch(url, opts);
    if (res.status === 429) throw new Error('rate limited');
    const body = await res.json();
    if (!body.ok) throw new Error(body.error || 'slack error');
    return body;
  }

  /** Connect a workspace with a user token (xoxp-…). */
  async add(token) {
    token = String(token || '').trim();
    if (!/^xox[pc]-/.test(token)) throw new Error('Paste a Slack user token (starts with xoxp-)');
    const who = await this.call(token, 'auth.test');
    const ws = { teamID: who.team_id, team: who.team, userID: who.user_id, user: who.user, addedAt: Date.now() };
    this.secrets.set(`slack_token:${ws.teamID}`, token);
    this.store.mutate((c) => { c.slackWorkspaces = [...(c.slackWorkspaces || []).filter((w) => w.teamID !== ws.teamID), ws]; });
    // Forward-only: everything before now is history.
    this.data.cursors[ws.teamID] = { since: Date.now() / 1000, ims: {}, imRing: 0 };
    this.save();
    this.start();
    this.poll();
    return ws;
  }

  remove(teamID) {
    this.secrets.set(`slack_token:${teamID}`, null);
    this.store.mutate((c) => { c.slackWorkspaces = (c.slackWorkspaces || []).filter((w) => w.teamID !== teamID); });
    for (const k of Object.keys(this.data.threads)) if (k.startsWith(`${teamID}:`)) delete this.data.threads[k];
    delete this.data.cursors[teamID];
    this.save();
    this.emit('changed');
  }

  start() {
    if (this.timer || !this.workspaces().length) return;
    this.timer = setInterval(() => this.poll(), POLL_MS);
    setTimeout(() => this.poll(), 3000);
  }
  stop() { clearInterval(this.timer); this.timer = null; }

  async userName(token, teamID, id) {
    if (!id) return 'Someone';
    const key = `${teamID}:${id}`;
    if (this.users.has(key)) return this.users.get(key);
    try {
      const u = (await this.call(token, 'users.info', { user: id })).user;
      const name = (u.profile && (u.profile.display_name || u.profile.real_name)) || u.real_name || u.name || id;
      this.users.set(key, name);
      return name;
    } catch { return id; }
  }

  /** Readable text: <@U1> → @name, <#C1|general> → #general, links tidied. */
  async render(token, teamID, text) {
    let out = String(text || '');
    const ids = [...new Set([...out.matchAll(/<@([A-Z0-9]+)(?:\|[^>]*)?>/g)].map((m) => m[1]))];
    for (const id of ids) out = out.split(new RegExp(`<@${id}(?:\\|[^>]*)?>`)).join(`@${await this.userName(token, teamID, id)}`);
    return out.replace(/<#[A-Z0-9]+\|([^>]+)>/g, '#$1').replace(/<(https?:[^|>]+)\|([^>]+)>/g, '$2 ($1)').replace(/<(https?:[^>]+)>/g, '$1')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  }

  async fileMessage(ws, token, { kind, channel, channelName, threadTS, msg }) {
    const key = `${ws.teamID}:${channel}:${threadTS}`;
    const t = this.data.threads[key] || { key, teamID: ws.teamID, team: ws.team, kind, channel, channelName, threadTS, messages: [], unread: 0, updatedAt: 0 };
    if (t.messages.some((m) => m.ts === msg.ts)) return false;
    t.messages.push({
      ts: msg.ts, user: msg.user, userName: await this.userName(token, ws.teamID, msg.user),
      text: await this.render(token, ws.teamID, msg.text), receivedAt: Date.now(), mine: msg.user === ws.userID,
    });
    t.messages.sort((a, b) => Number(a.ts) - Number(b.ts));
    if (msg.user !== ws.userID) t.unread += 1;
    t.updatedAt = Date.now();
    this.data.threads[key] = t;
    return t;
  }

  async poll() {
    if (this.polling) return;
    this.polling = true;
    const fresh = [];
    try {
      for (const ws of this.workspaces()) {
        const token = this.secrets.get(`slack_token:${ws.teamID}`);
        if (!token) continue;
        const cur = this.data.cursors[ws.teamID] || (this.data.cursors[ws.teamID] = { since: Date.now() / 1000, ims: {}, imRing: 0 });
        try {
          // Mentions: search is one call across every channel.
          const found = await this.call(token, 'search.messages', { query: `<@${ws.userID}>`, sort: 'timestamp', sort_dir: 'desc', count: 20 });
          for (const m of (found.messages && found.messages.matches) || []) {
            if (Number(m.ts) <= cur.since || m.user === ws.userID) continue;
            const threadTS = (m.permalink && (m.permalink.match(/thread_ts=([\d.]+)/) || [])[1]) || m.ts;
            const t = await this.fileMessage(ws, token, { kind: 'mention', channel: m.channel.id, channelName: m.channel.name ? `#${m.channel.name}` : 'a channel', threadTS, msg: m });
            if (t) fresh.push(t);
          }
          // DMs: a slice of IM/MPIM conversations per poll.
          const convs = (await this.call(token, 'users.conversations', { types: 'im,mpim', limit: 200, exclude_archived: true })).channels || [];
          const slice = [];
          for (let i = 0; i < Math.min(IMS_PER_POLL, convs.length); i++) slice.push(convs[(cur.imRing + i) % convs.length]);
          cur.imRing = convs.length ? (cur.imRing + IMS_PER_POLL) % convs.length : 0;
          for (const c of slice) {
            const oldest = cur.ims[c.id] || cur.since;
            const hist = await this.call(token, 'conversations.history', { channel: c.id, oldest, limit: 15 });
            const msgs = (hist.messages || []).filter((m) => !m.subtype || m.subtype === 'thread_broadcast').reverse();
            for (const m of msgs) {
              const name = c.is_im ? await this.userName(token, ws.teamID, c.user) : (c.name || 'Group DM');
              const t = await this.fileMessage(ws, token, { kind: 'dm', channel: c.id, channelName: name, threadTS: m.thread_ts || c.id, msg: m });
              if (t && m.user !== ws.userID) fresh.push(t);
              cur.ims[c.id] = Math.max(Number(cur.ims[c.id] || 0), Number(m.ts));
            }
          }
          ws.error = null;
        } catch (err) {
          ws.error = err.message;
        }
      }
      this.save();
    } finally {
      this.polling = false;
    }
    if (fresh.length) this.emit('new', [...new Map(fresh.map((t) => [t.key, t])).values()]);
    this.emit('changed');
  }

  threads() {
    return Object.values(this.data.threads).sort((a, b) => b.updatedAt - a.updatedAt);
  }

  markRead(key) {
    const t = this.data.threads[key];
    if (t && t.unread) { t.unread = 0; this.save(); this.emit('changed'); }
  }

  async reply(key, text) {
    const t = this.data.threads[key];
    if (!t) throw new Error('Thread not found');
    const ws = this.workspaces().find((w) => w.teamID === t.teamID);
    const token = this.secrets.get(`slack_token:${t.teamID}`);
    if (!ws || !token) throw new Error('Workspace not connected');
    // Mentions (and threaded DMs) answer in their thread; a plain DM answers in the DM.
    const params = { channel: t.channel, text: String(text) };
    if (/^\d+\.\d+$/.test(t.threadTS)) params.thread_ts = t.threadTS;
    const res = await this.call(token, 'chat.postMessage', params, true);
    t.messages.push({ ts: res.ts, user: ws.userID, userName: ws.user, text: String(text), receivedAt: Date.now(), mine: true, sentFromUdha: true });
    t.updatedAt = Date.now();
    t.unread = 0;
    this.save();
    this.emit('changed');
    return t;
  }
}

module.exports = { SlackInbox };
