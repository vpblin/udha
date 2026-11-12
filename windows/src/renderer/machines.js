'use strict';
/* Machines section (MachinesPane.swift): this PC's live stats. Every tile is a
   single series named by its title (no legend); 2px accent line over a faint
   area; hover reads out the value and time. Status colour only at thresholds,
   always with a word. Uses app.js globals ($, esc, state, registerSection). */

const machinesUI = { data: null, hover: {} };

function fmtBytes(n, digits = 1) {
  if (n == null || !Number.isFinite(n)) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i === 0 ? 0 : digits)} ${u[i]}`;
}
const fmtRate = (n) => (n == null ? '—' : `${fmtBytes(n)}/s`);
const fmtPct = (n) => (n == null ? '—' : `${Math.round(n)}%`);
function fmtUptime(s) {
  const d = Math.floor(s / 86400); const h = Math.floor((s % 86400) / 3600); const m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

/** Busy / High as a word + status colour; nothing below the threshold. */
function loadChip(pct) {
  if (pct == null) return '';
  if (pct >= 90) return '<span class="chip" style="--tint:var(--bad-tint);--ink:var(--bad-ink)"><span class="ping" style="--dot:var(--bad)"></span>High</span>';
  if (pct >= 75) return '<span class="chip" style="--tint:var(--warn-tint);--ink:var(--warn-ink)"><span class="ping" style="--dot:var(--warn)"></span>Busy</span>';
  return '';
}

/** An SVG sparkline; `max` fixes the scale (100 for percentages) or null = auto. */
function sparkline(key, series, { max = null, fmt = fmtPct } = {}) {
  const W = 300; const H = 46;
  if (!series || series.length < 2) return `<div class="spark empty">Collecting…</div>`;
  const top = max ?? Math.max(1, ...series.map((p) => p.v)) * 1.15;
  const x = (i) => (i / (series.length - 1)) * W;
  const y = (v) => H - 2 - (Math.min(v, top) / top) * (H - 4);
  const pts = series.map((p, i) => `${x(i).toFixed(1)},${y(p.v).toFixed(1)}`).join(' ');
  const hi = machinesUI.hover[key];
  const hp = hi != null && series[hi] ? series[hi] : null;
  return `<div class="spark" data-key="${key}" data-n="${series.length}">
    <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-label="${esc(key)} over the last ${Math.round((series[series.length - 1].t - series[0].t) / 1000)} seconds">
      <polygon points="0,${H} ${pts} ${W},${H}" fill="var(--accent-tint)"/>
      <polyline points="${pts}" fill="none" stroke="var(--accent)" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round"/>
      ${hp ? `<line x1="${x(hi)}" x2="${x(hi)}" y1="0" y2="${H}" stroke="var(--tertiary)" stroke-width="1" vector-effect="non-scaling-stroke" stroke-dasharray="2 2"/>` : ''}
    </svg>
    ${hp ? `<div class="spark-tip" style="left:${(hi / (series.length - 1)) * 100}%"><b>${esc(fmt(hp.v))}</b> · ${new Date(hp.t).toLocaleTimeString()}</div>` : ''}
  </div>`;
}

function tile(title, value, sub, chart, chip = '') {
  return `<div class="card stat-tile">
    <div class="stat-head"><span class="stat-title">${esc(title)}</span>${chip}</div>
    <div class="stat-value">${value}</div>
    <div class="stat-sub">${sub}</div>
    ${chart}
  </div>`;
}

function renderMachinesList() {
  const m = machinesUI.data;
  $('#machinesList').innerHTML = `<div class="card-row selected">
    <div class="card-top"><span class="card-name">${esc(m ? m.host : state.hostName)}</span><span class="card-spacer"></span><span class="card-model">This PC</span></div>
    <div class="card-state"><span class="ping active" style="--dot:var(--good)"></span><span class="card-state-label" style="color:var(--good-ink)">Online</span></div>
    <div class="card-detail">${m ? `CPU ${fmtPct(m.cpu)} · Mem ${fmtPct((100 * m.memUsed) / m.memTotal)} · ${ordered().filter((s) => s.state === 'running').length} sessions running` : 'Reading…'}</div>
  </div>`;
}

function renderMachinesPane() {
  const pane = $('#machinesPane');
  const m = machinesUI.data;
  if (!m) { pane.innerHTML = '<div class="empty"><div class="text">Reading this PC…</div></div>'; return; }
  const memPct = (100 * m.memUsed) / m.memTotal;
  const gpu = (m.gpus || [])[0];
  const running = ordered().filter((s) => s.state === 'running');

  pane.innerHTML = `
    <div class="pane-head">
      <div class="pane-title-wrap">
        <div class="pane-title">${esc(m.host)}</div>
        <div class="pane-sub"><span class="chip" style="--tint:var(--good-tint);--ink:var(--good-ink)"><span class="ping active" style="--dot:var(--good)"></span>Online</span>
          <span>${esc(m.os)} · ${esc(m.arch)} · up ${fmtUptime(m.uptime)}</span></div>
      </div>
    </div>
    <div class="machines-scroll">
      <div class="stat-grid">
        ${tile('CPU', fmtPct(m.cpu), `${m.cores} cores · ${esc(m.cpuModel.replace(/\s+/g, ' ').trim())}`, sparkline('cpu', m.history.cpu, { max: 100 }), loadChip(m.cpu))}
        ${tile('Memory', fmtPct(memPct), `${fmtBytes(m.memUsed)} of ${fmtBytes(m.memTotal)}`, sparkline('mem', m.history.mem, { max: 100 }), loadChip(memPct))}
        ${tile('Download', fmtRate(m.rxRate), 'All network adapters', sparkline('rx', m.history.rx, { fmt: fmtRate }))}
        ${tile('Upload', fmtRate(m.txRate), 'All network adapters', sparkline('tx', m.history.tx, { fmt: fmtRate }))}
        ${gpu ? tile('GPU', fmtPct(gpu.util), `${esc(gpu.name)} · ${fmtBytes(gpu.memUsed)} / ${fmtBytes(gpu.memTotal)}${Number.isFinite(gpu.temp) ? ` · ${gpu.temp}°C` : ''}`, sparkline('gpu', m.history.gpu, { max: 100 }), loadChip(gpu.util)) : ''}
      </div>

      <div class="machines-row">
        <div class="card mcard">
          <div class="mcard-head">CPU cores</div>
          <div class="cores">${m.perCore.map((v, i) => `<div class="core" title="Core ${i}: ${fmtPct(v)}"><div class="core-fill" style="height:${Math.max(2, v)}%"></div></div>`).join('')}</div>
        </div>
        <div class="card mcard">
          <div class="mcard-head">Disks</div>
          ${(m.disks || []).map((d) => {
            const used = d.total - d.free; const pct = (100 * used) / d.total;
            return `<div class="meter-row"><span class="meter-label">${esc(d.name)}</span>
              <div class="meter"><div class="meter-fill ${pct >= 90 ? 'bad' : pct >= 75 ? 'warn' : ''}" style="width:${pct}%"></div></div>
              <span class="meter-value">${fmtBytes(d.free)} free of ${fmtBytes(d.total)}${pct >= 90 ? ' · <b class="bad-ink">Almost full</b>' : ''}</span></div>`;
          }).join('') || '<div class="hint">Reading…</div>'}
        </div>
      </div>

      <div class="machines-row">
        <div class="card mcard grow">
          <div class="mcard-head">Top processes <span class="hint">by CPU</span></div>
          <table class="ptable"><thead><tr><th>Process</th><th>PID</th><th class="num">CPU</th><th class="num">Memory</th></tr></thead>
          <tbody>${(m.processes || []).map((p) => `<tr><td>${esc(p.name)}</td><td class="mono">${p.pid}</td><td class="num">${p.cpu.toFixed(1)}%</td><td class="num">${fmtBytes(p.mem)}</td></tr>`).join('') || '<tr><td colspan="4" class="hint">Reading…</td></tr>'}</tbody></table>
        </div>
        <div class="mcol">
          <div class="card mcard">
            <div class="mcard-head">Udha</div>
            <div class="kv"><span>Sessions</span><b>${ordered().length}</b></div>
            <div class="kv"><span>Running</span><b>${running.length}</b></div>
            <div class="kv"><span>Docker containers</span><b>${m.docker == null ? 'Docker not running' : m.docker.length}</b></div>
          </div>
          <div class="card mcard">
            <div class="mcard-head">Toolchain</div>
            ${(m.tools || []).map((t) => `<div class="kv"><span>${esc(t.label)}</span><b class="mono">${t.version ? esc(t.version) : '<span class="hint">not found</span>'}</b></div>`).join('') || '<div class="hint">Checking…</div>'}
          </div>
        </div>
      </div>
      <div class="hint machines-note">Temperatures need vendor tools on Windows; GPU shows when <span class="mono">nvidia-smi</span> is available.</div>
    </div>`;
}

// Hover readout: map the pointer to the nearest sample.
$('#machinesPane').addEventListener('mousemove', (e) => {
  const sp = e.target.closest('.spark[data-key]');
  if (!sp) return;
  const r = sp.getBoundingClientRect();
  const n = Number(sp.dataset.n);
  const i = Math.round(((e.clientX - r.left) / r.width) * (n - 1));
  if (machinesUI.hover[sp.dataset.key] !== i) {
    machinesUI.hover = { [sp.dataset.key]: Math.max(0, Math.min(n - 1, i)) };
    const scroll = $('.machines-scroll') && $('.machines-scroll').scrollTop;
    renderMachinesPane();
    if ($('.machines-scroll')) $('.machines-scroll').scrollTop = scroll;
  }
});
$('#machinesPane').addEventListener('mouseleave', () => { machinesUI.hover = {}; renderMachinesPane(); });

window.udha.machines.onUpdate((m) => {
  machinesUI.data = m;
  if (state.section !== 'machines') return;
  const scroll = $('.machines-scroll') && $('.machines-scroll').scrollTop;
  renderMachinesList();
  renderMachinesPane();
  if ($('.machines-scroll')) $('.machines-scroll').scrollTop = scroll;
});

registerSection('machines', {
  async show() {
    const first = await window.udha.machines.start();
    if (first) machinesUI.data = first;
    renderMachinesList();
    renderMachinesPane();
  },
  hide() { window.udha.machines.stop(); },
});
