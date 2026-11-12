// Pane rules for assistants without a hook feed — a port of the mac app's
// OutputClassifier: `classifyCodexPane` for Codex, and the generic regex
// classifier (prompts, errors, "esc to …" footers) for Qwen and plain
// commands. Input is the visible screen as plain text lines.
'use strict';

const NEEDS_INPUT = [
  /do\s*you\s*want\s*to\s*proceed/i,
  /[❯›>]\s*\d+\s*\.\s*\S/,
  /this\s*command\s*requires\s*approval/i,
  /waiting\s*for\s*your\s*approval/i,
  /\[y\/n\]/i,
  /\(y\/n\)/i,
  /press\s*enter\s*to\s*continue/i,
  /allow\s+(once|always)/i,
];
const WORKING = [/esc\s*to\s*(interrupt|cancel)/i, /⎿\s*Running/];
const ERRORS = [
  /^\s*Error:\s/, /^\s*API\s*Error:\s/,
  /\b(429|500|502|503|504)\s+(Too Many Requests|Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)/i,
  /connection\s*refused/i, /^\s*Traceback\b/, /^\s*FATAL:/i,
];
const IDLE_FOOTER = /accept\s*edits\s*(on|off)|shift\s*\+?\s*tab\s*to\s*cycle|\?\s*for\s*shortcuts/i;
const DIALOG_FOOTER = /esc\s*to\s*cancel/i;
const ACTIVITY = [/(Reading|Writing|Editing|Searching|Running|Fetching)\s*\S.{0,80}/i];

/** { state: 'needsInput'|'working'|'idle'|'error'|null, activity?, prompt?, question? } */
function classifyCodexPane(rawLines) {
  const lines = rawLines.map((l) => l.trim()).filter(Boolean);
  const tail = lines.slice(-12);
  const text = tail.join('\n');

  // 1. A dialog: a numbered choice with a confirm footer (approval, update banner, trust prompt).
  const footer = /esc to cancel|press enter to confirm|press enter to continue/i.test(text);
  const numbered = /^[›❯]\s*\d+[.)]\s*/m.test(text);
  if (footer && numbered) {
    let start = tail.findIndex((l) => /would you like|update available|do you trust|\?$/i.test(l));
    if (start < 0) start = Math.max(0, tail.length - 6);
    return { state: 'needsInput', prompt: tail.slice(start).join(' ').slice(0, 200) };
  }

  // 2. The prompt anchors everything else.
  let prompt = -1;
  for (let i = lines.length - 1; i >= 0; i--) if (lines[i].startsWith('›')) { prompt = i; break; }
  if (prompt < 0 || lines.length - prompt > 5) return { state: null };
  const above = lines.slice(0, prompt);
  const status = above.slice(-3);

  // 3. In flight.
  if (status.some((l) => /^[•●] .+\(.*esc to interrupt\)$/.test(l))) {
    const tool = above.slice(-6).reverse().find((l) => /^[•●] (Running|Ran|Reading|Read|Editing|Edited|Searching|Searched|Exploring|Explored|Listing|Listed)\b/.test(l));
    const activity = tool ? tool.slice(1).trim() : null;
    return { state: 'working', activity: activity && activity.length > 90 ? activity.slice(0, 88) + '…' : activity };
  }
  // A partially repainted busy footer is not evidence that the turn ended.
  if (status.some((l) => /esc to interrupt/i.test(l))) return { state: null };

  // 4. A queued question ("? 1 question" + "shift + ↵ to answer").
  const queued = above.slice(-6);
  const count = [...queued].reverse().find((l) => /^\?\s*\d+ questions?$/.test(l));
  if (count && queued.some((l) => /to answer/i.test(l))) {
    const q = `${count.replace(/^\?\s*/, '')} queued for you · shift + ↵ in the terminal to answer`;
    return { state: 'needsInput', prompt: q, question: q };
  }

  // 5. Finished — carry the question if the last thing it said was one.
  const said = [...above].reverse().find((l) => l.startsWith('•') && !l.startsWith('• Worked for') && !l.startsWith('• Queued'));
  if (said) {
    const line = said.slice(1).trim();
    if (line.endsWith('?')) return { state: 'idle', question: line };
  }
  return { state: 'idle' };
}

/** The generic classifier (Qwen, shells, anything else), on the last ~15 lines. */
function classifyGeneric(rawLines) {
  const lines = [...rawLines];
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  const recent = lines.slice(-15);
  const text = recent.join('\n');

  const idleBoxWithoutDialog = IDLE_FOOTER.test(text) && !DIALOG_FOOTER.test(text);
  if (!idleBoxWithoutDialog) {
    for (const re of NEEDS_INPUT) {
      if (re.test(text)) {
        const q = [...recent].reverse().find((l) => /\?\s*$|\(y\/n\)|\[y\/n\]|approval|proceed/i.test(l));
        return { state: 'needsInput', prompt: (q || recent[recent.length - 1] || '').trim().slice(0, 200) };
      }
    }
  }
  for (const re of WORKING) {
    if (re.test(text)) {
      let activity = null;
      for (const ex of ACTIVITY) {
        const m = text.match(ex);
        if (m) { activity = m[0].trim().slice(0, 90); break; }
      }
      return { state: 'working', activity };
    }
  }
  const last = recent.slice(-4);
  if (last.some((l) => ERRORS.some((re) => re.test(l)))) {
    return { state: 'error', activity: last.find((l) => ERRORS.some((re) => re.test(l))).trim().slice(0, 160) };
  }
  return { state: 'idle' };
}

/**
 * Stability filter: a state only lands after it is seen twice in a row, so a
 * single repaint frame cannot flip a card. Returns the result to apply, or null.
 */
function stable(tracker, result) {
  const key = `${result.state}|${result.prompt || ''}`;
  if (tracker.pending === key) {
    tracker.count += 1;
  } else {
    tracker.pending = key;
    tracker.count = 1;
  }
  return tracker.count >= 2 ? result : null;
}

module.exports = { classifyCodexPane, classifyGeneric, stable };
