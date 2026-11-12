#!/usr/bin/env node
// Run by Claude Code itself (hooks + statusLine in the generated settings
// file), the Windows twin of the mac app's two `sh` sidecar scripts.
//   node hook.js event       → append the hook payload to <dir>/<id>.jsonl
//   node hook.js statusline  → overwrite <dir>/<id>.status.json, print a line
// The session is identified by UDHA_SESSION_ID, which Udha puts in the pty's
// environment. Never fails loudly: a broken hook must not break Claude.
'use strict';

const fs = require('fs');
const path = require('path');

const mode = process.argv[2] || 'event';
const id = process.env.UDHA_SESSION_ID;
const dir = process.env.UDHA_STATUS_DIR;

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { input += c; });
process.stdin.on('end', () => {
  try {
    if (!id || !dir || !/^[0-9a-f-]{36}$/i.test(id)) return finish('');
    fs.mkdirSync(dir, { recursive: true });
    if (mode === 'statusline') {
      const tmp = path.join(dir, `${id}.status.json.tmp`);
      fs.writeFileSync(tmp, input);
      fs.renameSync(tmp, path.join(dir, `${id}.status.json`));
      let line = '';
      try {
        const obj = JSON.parse(input);
        const parts = [];
        if (obj.model && obj.model.display_name) parts.push(obj.model.display_name);
        if (obj.context_window && typeof obj.context_window.used_percentage === 'number') {
          parts.push(`ctx ${Math.round(obj.context_window.used_percentage)}%`);
        }
        if (obj.cost && typeof obj.cost.total_cost_usd === 'number') parts.push(`$${obj.cost.total_cost_usd.toFixed(2)}`);
        line = parts.join(' · ');
      } catch { /* print nothing */ }
      return finish(line);
    }
    let payload;
    try { payload = JSON.parse(input); } catch { payload = { raw: input }; }
    fs.appendFileSync(path.join(dir, `${id}.jsonl`), JSON.stringify({ t: Date.now(), payload }) + '\n');
  } catch { /* swallow */ }
  finish('');
});

function finish(text) {
  if (text) process.stdout.write(text);
  process.exit(0);
}
