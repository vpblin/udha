'use strict';
/* Terminal themes. "Udha" follows the app's light/dark palette; the rest are
   fixed schemes. "Git Bash" reproduces mintty's built-in defaults as Git for
   Windows ships them (no ~/.minttyrc): the palette from
   Git/usr/share/mintty/themes/mintty, #BFBFBF on black, Lucida Console 9 pt,
   a blinking line cursor, bold drawn as bright colour (BoldAsColour=yes,
   BoldAsFont=no), selection shown as inverse. */

(function (root) {
  const MINTTY = {
    background: '#000000', foreground: '#BFBFBF', cursor: '#BFBFBF', cursorAccent: '#000000',
    selectionBackground: '#BFBFBF', selectionForeground: '#000000', selectionInactiveBackground: '#808080',
    black: '#000000', red: '#BF0000', green: '#00BF00', yellow: '#BFBF00', blue: '#0000BF', magenta: '#BF00BF', cyan: '#00BFBF', white: '#BFBFBF',
    brightBlack: '#404040', brightRed: '#FF4040', brightGreen: '#40FF40', brightYellow: '#FFFF40', brightBlue: '#6060FF', brightMagenta: '#FF40FF', brightCyan: '#40FFFF', brightWhite: '#FFFFFF',
  };

  const UDHA_DARK = {
    background: '#1E1E20', foreground: '#E7E7EA', cursor: '#E7E7EA', cursorAccent: '#1E1E20',
    selectionBackground: 'rgba(77,162,255,0.35)',
    black: '#1E1E20', red: '#FF6961', green: '#45D669', yellow: '#FFB340', blue: '#4DA2FF', magenta: '#C08CF5', cyan: '#5AC8FA', white: '#E7E7EA',
    brightBlack: '#6E6E73', brightRed: '#FF9A94', brightGreen: '#6FE089', brightYellow: '#FFC46B', brightBlue: '#8EC2FF', brightMagenta: '#D9B8FA', brightCyan: '#8AD9FB', brightWhite: '#FFFFFF',
  };
  const UDHA_LIGHT = {
    background: '#FFFFFF', foreground: '#2B2B2E', cursor: '#2B2B2E', cursorAccent: '#FFFFFF',
    selectionBackground: 'rgba(0,105,217,0.22)',
    black: '#1D1D1F', red: '#CF2A20', green: '#1C8B3A', yellow: '#9A5B00', blue: '#0069D9', magenta: '#7B3FBF', cyan: '#0B7C99', white: '#C7C7CC',
    brightBlack: '#64646A', brightRed: '#E0453B', brightGreen: '#28A84A', brightYellow: '#B86E00', brightBlue: '#2E86F0', brightMagenta: '#9459D6', brightCyan: '#1597B8', brightWhite: '#8E8E93',
  };

  const UDHA_FONT = '"Cascadia Mono", "Cascadia Code", Consolas, monospace';

  const THEMES = {
    udha: {
      name: 'Udha', note: 'Follows the app’s light or dark look',
      colors: (dark) => (dark ? UDHA_DARK : UDHA_LIGHT),
      font: UDHA_FONT, lineHeight: 1.15, cursorStyle: 'block', cursorBlink: true, boldBright: true,
    },
    gitbash: {
      name: 'Git Bash', note: 'Identical to Git for Windows’ mintty: Lucida Console 9 pt, #BFBFBF on black',
      colors: () => MINTTY,
      font: '"Lucida Console", monospace', fontSize: 12 /* 9 pt */, fixedSize: true,
      lineHeight: 1.0, letterSpacing: 0, cursorStyle: 'bar', cursorWidth: 1, cursorBlink: true,
      boldBright: true, boldWeight: 'normal', padding: 1,
    },
    campbell: {
      name: 'Windows Terminal', note: 'Campbell, the Windows Terminal default',
      colors: () => ({
        background: '#0C0C0C', foreground: '#CCCCCC', cursor: '#FFFFFF', cursorAccent: '#0C0C0C', selectionBackground: 'rgba(255,255,255,0.25)',
        black: '#0C0C0C', red: '#C50F1F', green: '#13A10E', yellow: '#C19C00', blue: '#0037DA', magenta: '#881798', cyan: '#3A96DD', white: '#CCCCCC',
        brightBlack: '#767676', brightRed: '#E74856', brightGreen: '#16C60C', brightYellow: '#F9F1A5', brightBlue: '#3B78FF', brightMagenta: '#B4009E', brightCyan: '#61D6D6', brightWhite: '#F2F2F2',
      }),
      font: '"Cascadia Mono", Consolas, monospace', lineHeight: 1.2, cursorStyle: 'bar', cursorBlink: true, boldBright: false,
    },
    onehalfdark: {
      name: 'One Half Dark', note: 'Soft dark scheme',
      colors: () => ({
        background: '#282C34', foreground: '#DCDFE4', cursor: '#A3B3CC', cursorAccent: '#282C34', selectionBackground: 'rgba(255,255,255,0.18)',
        black: '#282C34', red: '#E06C75', green: '#98C379', yellow: '#E5C07B', blue: '#61AFEF', magenta: '#C678DD', cyan: '#56B6C2', white: '#DCDFE4',
        brightBlack: '#5A6374', brightRed: '#E06C75', brightGreen: '#98C379', brightYellow: '#E5C07B', brightBlue: '#61AFEF', brightMagenta: '#C678DD', brightCyan: '#56B6C2', brightWhite: '#DCDFE4',
      }),
      font: UDHA_FONT, lineHeight: 1.2, cursorStyle: 'block', cursorBlink: true, boldBright: false,
    },
    dracula: {
      name: 'Dracula', note: 'Purple-tinted dark scheme',
      colors: () => ({
        background: '#282A36', foreground: '#F8F8F2', cursor: '#F8F8F2', cursorAccent: '#282A36', selectionBackground: 'rgba(68,71,90,0.9)',
        black: '#21222C', red: '#FF5555', green: '#50FA7B', yellow: '#F1FA8C', blue: '#BD93F9', magenta: '#FF79C6', cyan: '#8BE9FD', white: '#F8F8F2',
        brightBlack: '#6272A4', brightRed: '#FF6E6E', brightGreen: '#69FF94', brightYellow: '#FFFFA5', brightBlue: '#D6ACFF', brightMagenta: '#FF92DF', brightCyan: '#A4FFFF', brightWhite: '#FFFFFF',
      }),
      font: UDHA_FONT, lineHeight: 1.2, cursorStyle: 'block', cursorBlink: true, boldBright: false,
    },
    solarizeddark: {
      name: 'Solarized Dark', note: 'Low-contrast dark',
      colors: () => ({
        background: '#002B36', foreground: '#839496', cursor: '#93A1A1', cursorAccent: '#002B36', selectionBackground: 'rgba(147,161,161,0.25)',
        black: '#073642', red: '#DC322F', green: '#859900', yellow: '#B58900', blue: '#268BD2', magenta: '#D33682', cyan: '#2AA198', white: '#EEE8D5',
        brightBlack: '#002B36', brightRed: '#CB4B16', brightGreen: '#586E75', brightYellow: '#657B83', brightBlue: '#839496', brightMagenta: '#6C71C4', brightCyan: '#93A1A1', brightWhite: '#FDF6E3',
      }),
      font: UDHA_FONT, lineHeight: 1.2, cursorStyle: 'block', cursorBlink: true, boldBright: false,
    },
    solarizedlight: {
      name: 'Solarized Light', note: 'Low-contrast light',
      colors: () => ({
        background: '#FDF6E3', foreground: '#657B83', cursor: '#586E75', cursorAccent: '#FDF6E3', selectionBackground: 'rgba(88,110,117,0.2)',
        black: '#073642', red: '#DC322F', green: '#859900', yellow: '#B58900', blue: '#268BD2', magenta: '#D33682', cyan: '#2AA198', white: '#EEE8D5',
        brightBlack: '#002B36', brightRed: '#CB4B16', brightGreen: '#586E75', brightYellow: '#657B83', brightBlue: '#839496', brightMagenta: '#6C71C4', brightCyan: '#93A1A1', brightWhite: '#FDF6E3',
      }),
      font: UDHA_FONT, lineHeight: 1.2, cursorStyle: 'block', cursorBlink: true, boldBright: false,
    },
  };

  /** Everything xterm needs for a theme id, plus the card colours around it. */
  function resolve(id, { dark, fontSize }) {
    const t = THEMES[id] || THEMES.udha;
    const colors = t.colors(dark);
    return {
      id: THEMES[id] ? id : 'udha',
      colors,
      options: {
        fontFamily: t.font,
        fontSize: t.fixedSize ? t.fontSize : (fontSize || 13),
        lineHeight: t.lineHeight || 1.15,
        letterSpacing: t.letterSpacing || 0,
        cursorStyle: t.cursorStyle || 'block',
        cursorWidth: t.cursorWidth || 1,
        cursorBlink: t.cursorBlink !== false,
        drawBoldTextInBrightColors: !!t.boldBright,
        fontWeightBold: t.boldWeight || 'bold',
        minimumContrastRatio: 1,
      },
      padding: t.padding,
      fixedSize: !!t.fixedSize,
    };
  }

  const api = { THEMES, resolve };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.TerminalThemes = api;
})(typeof window !== 'undefined' ? window : globalThis);
