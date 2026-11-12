// Agents (Agent.swift / AgentStore.swift): a reusable prompt stored as a plain
// .md file with name / description / icon frontmatter. Running one spawns a
// fresh session in a folder and pastes the prompt in. Built-ins ship in
// src/agents and are restored if deleted; your own are never touched.
'use strict';

const fs = require('fs');
const path = require('path');

const BUILT_IN_DIR = path.join(__dirname, '..', 'agents');

function titleCase(slug) {
  return slug.split(/[-_\s]+/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(' ');
}

function slugify(name) {
  return String(name || 'agent').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48) || 'agent';
}

function parse(slug, contents, isBuiltIn = false) {
  let name = titleCase(slug);
  let description = '';
  let icon = 'sparkles';
  let body = contents.replace(/\r\n/g, '\n');
  const lines = body.split('\n');
  if ((lines[0] || '').trim() === '---') {
    let i = 1;
    const meta = {};
    for (; i < lines.length; i++) {
      if (lines[i].trim() === '---') { i++; break; }
      const c = lines[i].indexOf(':');
      if (c > 0) meta[lines[i].slice(0, c).trim().toLowerCase()] = lines[i].slice(c + 1).trim();
    }
    if (meta.name) name = meta.name;
    if (meta.description != null) description = meta.description;
    if (meta.icon) icon = meta.icon;
    body = lines.slice(i).join('\n');
  }
  return { slug, name, description, icon, prompt: body.trim(), isBuiltIn };
}

function serialize(a) {
  const clean = (s) => String(s || '').replace(/[\r\n]+/g, ' ').trim();
  return `---\nname: ${clean(a.name)}\ndescription: ${clean(a.description)}\nicon: ${clean(a.icon) || 'sparkles'}\n---\n${String(a.prompt || '').trim()}\n`;
}

class AgentStore {
  constructor(dir) {
    this.dir = dir;
  }

  builtInSlugs() {
    try { return fs.readdirSync(BUILT_IN_DIR).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3)); } catch { return []; }
  }

  /** Seed built-ins that are missing (first launch, or deleted). */
  seed() {
    fs.mkdirSync(this.dir, { recursive: true });
    for (const slug of this.builtInSlugs()) {
      const target = path.join(this.dir, `${slug}.md`);
      if (!fs.existsSync(target)) fs.copyFileSync(path.join(BUILT_IN_DIR, `${slug}.md`), target);
    }
  }

  list() {
    this.seed();
    const builtIns = new Set(this.builtInSlugs());
    return fs.readdirSync(this.dir)
      .filter((f) => f.endsWith('.md'))
      .map((f) => {
        const slug = f.slice(0, -3);
        try { return parse(slug, fs.readFileSync(path.join(this.dir, f), 'utf8'), builtIns.has(slug)); } catch { return null; }
      })
      .filter(Boolean)
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  get(slug) { return this.list().find((a) => a.slug === slug) || null; }

  create(name) {
    let slug = slugify(name);
    for (let n = 2; fs.existsSync(path.join(this.dir, `${slug}.md`)); n++) slug = `${slugify(name)}-${n}`;
    const agent = { slug, name: String(name || '').trim() || titleCase(slug), description: '', icon: 'sparkles', prompt: '' };
    this.save(agent);
    return slug;
  }

  save(agent) {
    if (!/^[a-z0-9-]+$/.test(agent.slug)) throw new Error('bad agent id');
    fs.mkdirSync(this.dir, { recursive: true });
    const file = path.join(this.dir, `${agent.slug}.md`);
    fs.writeFileSync(`${file}.tmp`, serialize(agent));
    fs.renameSync(`${file}.tmp`, file);
  }

  /** Deleting a built-in restores the shipped version (that's "Restore default"). */
  remove(slug) {
    if (!/^[a-z0-9-]+$/.test(slug)) return;
    fs.rmSync(path.join(this.dir, `${slug}.md`), { force: true });
    this.seed();
  }

  openFolder() { return this.dir; }
}

module.exports = { AgentStore, parse, serialize, slugify };
