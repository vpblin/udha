'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const { THEMES, resolve } = require('../src/renderer/terminal-themes');

test('Git Bash theme is mintty’s default palette, font and cursor', () => {
  const g = resolve('gitbash', { dark: false, fontSize: 16 });
  assert.equal(g.colors.background, '#000000');
  assert.equal(g.colors.foreground, '#BFBFBF');
  assert.equal(g.options.fontFamily.split(',')[0], '"Lucida Console"');
  assert.equal(g.options.fontSize, 12, '9 pt regardless of the size setting');
  assert.equal(g.options.cursorStyle, 'bar');
  assert.equal(g.options.drawBoldTextInBrightColors, true);
  assert.equal(g.options.fontWeightBold, 'normal');

  // Same 16 colours as Git for Windows' own theme file, when it's installed.
  const file = 'C:\\Program Files\\Git\\usr\\share\\mintty\\themes\\mintty';
  if (fs.existsSync(file)) {
    const map = { Black: 'black', Red: 'red', Green: 'green', Yellow: 'yellow', Blue: 'blue', Magenta: 'magenta', Cyan: 'cyan', White: 'white' };
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^(Bold)?(\w+)\s*=\s*(#[0-9A-F]{6})/i);
      if (!m || !map[m[2]]) continue;
      const key = m[1] ? `bright${map[m[2]][0].toUpperCase()}${map[m[2]].slice(1)}` : map[m[2]];
      assert.equal(g.colors[key].toUpperCase(), m[3].toUpperCase(), key);
    }
  }
});

test('every theme resolves; unknown falls back to Udha; Udha follows dark mode', () => {
  for (const id of Object.keys(THEMES)) assert.ok(resolve(id, { dark: true }).colors.background);
  assert.equal(resolve('nope', { dark: true }).id, 'udha');
  assert.notEqual(resolve('udha', { dark: true }).colors.background, resolve('udha', { dark: false }).colors.background);
  assert.equal(resolve('dracula', { dark: false, fontSize: 16 }).options.fontSize, 16);
});
