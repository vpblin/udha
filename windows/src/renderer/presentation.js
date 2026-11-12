// How a session reads: the words (SessionStatusPresentation.swift) and the
// colour family (UdhaSessionStyle.swift) — red when it is on you, accent while
// it works, green when it has finished, amber once that has gone stale.
'use strict';

(function (root) {
  function presentation(s, staleAfterSeconds) {
    if (s.state === 'stopped') {
      return { label: 'Stopped', detail: s.claudeSessionID ? 'Saved — start to resume the conversation' : 'Saved', kind: 'quiet', pulses: false, live: false };
    }
    if (s.state === 'exited') {
      const code = s.exitCode == null ? null : (s.exitCode === 0 ? 'clean exit' : `code ${s.exitCode}`);
      return { label: 'Exited', detail: s.phaseDetail || code, kind: 'quiet', pulses: false, live: false };
    }
    switch (s.phase) {
      case 'starting':
        return { label: 'Starting', detail: s.phaseDetail, kind: 'starting', pulses: true, live: false };
      case 'thinking':
        return { label: 'Thinking', detail: s.phaseDetail, kind: 'working', pulses: true, live: true };
      case 'usingTool':
        return { label: s.phaseDetail || 'Working', detail: null, kind: 'working', pulses: false, live: true };
      case 'awaitingApproval':
        return { label: 'Needs approval', detail: s.phaseDetail, kind: 'needsYou', pulses: true, live: false };
      case 'awaitingReply': {
        const stale = (Date.now() - s.phaseEnteredAt) / 1000 > (staleAfterSeconds || 1800);
        return { label: stale ? 'Stale' : 'Ready', detail: s.lastQuestion || s.phaseDetail, kind: stale ? 'stale' : 'ready', pulses: false, live: false };
      }
      case 'finished':
        return { label: 'Done', detail: s.phaseDetail, kind: 'ready', pulses: false, live: false };
      case 'idle':
      default:
        return { label: 'Idle', detail: s.phaseDetail, kind: 'quiet', pulses: false, live: false };
    }
  }

  /** CSS custom-property names for each family: dot, text ink, chip tint. */
  const FAMILY = {
    needsYou: { dot: 'var(--bad)', ink: 'var(--bad-ink)', tint: 'var(--bad-tint)', filled: true },
    working:  { dot: 'var(--accent)', ink: 'var(--accent-ink)', tint: 'var(--accent-tint)', filled: true },
    starting: { dot: 'var(--accent)', ink: 'var(--accent-ink)', tint: 'var(--accent-tint)', filled: true },
    ready:    { dot: 'var(--good)', ink: 'var(--good-ink)', tint: 'var(--good-tint)', filled: true },
    stale:    { dot: 'var(--warn)', ink: 'var(--warn-ink)', tint: 'var(--warn-tint)', filled: true },
    quiet:    { dot: 'var(--tertiary)', ink: 'var(--secondary)', tint: 'var(--fill)', filled: false },
  };

  function style(s, staleAfterSeconds) {
    const p = presentation(s, staleAfterSeconds);
    return { ...p, ...FAMILY[p.kind], wantsYou: p.kind === 'needsYou' };
  }

  const api = { presentation, style };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.UdhaPresentation = api;
})(typeof window !== 'undefined' ? window : globalThis);
