// This PC's stats for the Machines section (SystemStatsCollector.swift).
// Cheap numbers (CPU, memory, network) every tick from Node and `netstat -e`;
// heavier ones (processes, disks, GPU) on a slower cadence; toolchain versions
// once. Only runs while the section is open.
'use strict';

const os = require('os');
const fs = require('fs');
const { execFile } = require('child_process');

const HISTORY = 90;           // samples kept per series (3 min at 2 s)

function run(cmd, args, timeout = 8000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout, windowsHide: true, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => resolve(err ? null : String(stdout)));
  });
}

function cpuTimes() {
  return os.cpus().map((c) => {
    const t = c.times;
    return { idle: t.idle, total: t.user + t.nice + t.sys + t.idle + t.irq };
  });
}

/** `netstat -e`: cumulative bytes received / sent across interfaces. */
function parseNetstat(text) {
  const line = String(text || '').split(/\r?\n/).find((l) => /^\s*Bytes\s/i.test(l));
  if (!line) return null;
  const nums = line.trim().split(/\s+/).slice(1).map(Number);
  return nums.length >= 2 && nums.every(Number.isFinite) ? { rx: nums[0], tx: nums[1] } : null;
}

/** nvidia-smi CSV → GPUs. */
function parseNvidia(text) {
  return String(text || '').split(/\r?\n/).filter((l) => l.trim()).map((l) => {
    const [name, util, used, total, temp] = l.split(',').map((s) => s.trim());
    return { name, util: Number(util), memUsed: Number(used) * 1048576, memTotal: Number(total) * 1048576, temp: Number(temp) };
  }).filter((g) => g.name && Number.isFinite(g.util));
}

class MachineStats {
  constructor({ onUpdate }) {
    this.onUpdate = onUpdate;
    this.timer = null;
    this.slowTimer = null;
    this.history = { cpu: [], mem: [], rx: [], tx: [], gpu: [] };
    this.last = null;
    this.prevCpu = null;
    this.prevNet = null;
    this.prevProc = null;
    this.slow = { disks: [], processes: [], gpus: [], docker: null };
    this.tools = null;
  }

  start() {
    if (this.timer) return;
    this.prevCpu = cpuTimes();
    this.tick();
    this.slowTick();
    this.timer = setInterval(() => this.tick(), 2000);
    this.slowTimer = setInterval(() => this.slowTick(), 6000);
    if (!this.tools) this.loadTools();
  }

  stop() {
    clearInterval(this.timer);
    clearInterval(this.slowTimer);
    this.timer = this.slowTimer = null;
  }

  push(key, value) {
    const h = this.history[key];
    h.push({ t: Date.now(), v: value });
    if (h.length > HISTORY) h.shift();
  }

  async tick() {
    const now = cpuTimes();
    const perCore = now.map((c, i) => {
      const p = this.prevCpu[i] || c;
      const total = c.total - p.total;
      return total > 0 ? Math.max(0, Math.min(100, 100 * (1 - (c.idle - p.idle) / total))) : 0;
    });
    this.prevCpu = now;
    const cpu = perCore.reduce((a, b) => a + b, 0) / (perCore.length || 1);
    const memTotal = os.totalmem();
    const memUsed = memTotal - os.freemem();
    this.push('cpu', cpu);
    this.push('mem', (100 * memUsed) / memTotal);

    const net = parseNetstat(await run('netstat', ['-e'], 4000));
    let rxRate = null;
    let txRate = null;
    if (net && this.prevNet) {
      const dt = (Date.now() - this.prevNet.t) / 1000;
      rxRate = Math.max(0, (net.rx - this.prevNet.rx) / dt);
      txRate = Math.max(0, (net.tx - this.prevNet.tx) / dt);
      this.push('rx', rxRate);
      this.push('tx', txRate);
    }
    if (net) this.prevNet = { ...net, t: Date.now() };

    this.last = {
      at: Date.now(),
      host: os.hostname(),
      os: `${os.version()} (${os.release()})`,
      arch: os.arch(),
      cpuModel: (os.cpus()[0] || {}).model || 'CPU',
      cores: perCore.length,
      uptime: os.uptime(),
      cpu, perCore, memTotal, memUsed, rxRate, txRate,
      ...this.slow,
      tools: this.tools,
      history: this.history,
    };
    this.onUpdate(this.last);
  }

  async slowTick() {
    // Disks: every fixed drive letter that answers statfs.
    const disks = [];
    for (const letter of 'CDEFGHIJKLMNOPQRSTUVWXYZ') {
      const root = `${letter}:\\`;
      try {
        if (!fs.existsSync(root)) continue;
        const s = fs.statfsSync(root);
        const total = s.blocks * s.bsize;
        if (total > 0) disks.push({ name: `${letter}:`, total, free: s.bavail * s.bsize });
      } catch { /* not ready */ }
    }

    // Processes: CPU seconds are cumulative, so the rate is the delta between polls.
    const ps = await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      'Get-Process | Select-Object Id,ProcessName,CPU,WorkingSet64 | ConvertTo-Json -Compress'], 10000);
    let processes = this.slow.processes;
    if (ps) {
      try {
        const list = JSON.parse(ps);
        const t = Date.now();
        const cores = os.cpus().length || 1;
        const prev = this.prevProc;
        processes = list.map((p) => {
          const before = prev && prev.map.get(p.Id);
          const dt = prev ? (t - prev.t) / 1000 : 0;
          const cpu = before != null && dt > 0 && p.CPU != null ? Math.max(0, ((p.CPU - before) / dt / cores) * 100) : 0;
          return { pid: p.Id, name: p.ProcessName, cpu, mem: p.WorkingSet64 || 0 };
        }).sort((a, b) => b.cpu - a.cpu || b.mem - a.mem).slice(0, 10);
        this.prevProc = { t, map: new Map(list.map((p) => [p.Id, p.CPU])) };
      } catch { /* keep last */ }
    }

    const smi = await run('nvidia-smi', ['--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu', '--format=csv,noheader,nounits'], 5000);
    const gpus = parseNvidia(smi);
    if (gpus.length) this.push('gpu', gpus[0].util);

    const dockerOut = await run('docker', ['ps', '--format', '{{.Names}}'], 4000);
    const docker = dockerOut == null ? null : dockerOut.split(/\r?\n/).filter(Boolean);

    this.slow = { disks, processes, gpus, docker };
  }

  async loadTools() {
    const probe = async (label, cmd, args) => {
      const out = await run(cmd, args, 8000);
      const v = out && (out.match(/\d+\.\d+(\.\d+)?/) || [])[0];
      return { label, version: v || null };
    };
    this.tools = await Promise.all([
      probe('Node', 'node', ['--version']),
      probe('Git', 'git', ['--version']),
      probe('Claude Code', 'cmd.exe', ['/d', '/c', 'claude', '--version']),
      probe('Codex', 'cmd.exe', ['/d', '/c', 'codex', '--version']),
      probe('Python', 'cmd.exe', ['/d', '/c', 'python', '--version']),
      probe('Docker', 'docker', ['--version']),
    ]);
  }
}

module.exports = { MachineStats, parseNetstat, parseNvidia };
