'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { wordsToCues } = require('../src/main/recordings');

test('words become cues, split on length, duration and pauses', () => {
  const words = [];
  let t = 0;
  for (const w of 'This is a fairly long sentence that should be split into more than one caption line'.split(' ')) {
    words.push({ text: w, start: t, end: t + 0.3, type: 'word' }, { text: ' ', start: t + 0.3, end: t + 0.35, type: 'spacing' });
    t += 0.35;
  }
  words.push({ text: 'After', start: t + 2, end: t + 2.3, type: 'word' }, { text: 'pause.', start: t + 2.3, end: t + 2.6, type: 'word' });
  const cues = wordsToCues(words);
  assert.ok(cues.length >= 3);
  assert.ok(cues.every((c) => c.text.length <= 42));
  assert.equal(cues[cues.length - 1].text, 'After pause.');
  assert.ok(cues.every((c, i) => i === 0 || c.start >= cues[i - 1].end));
});
