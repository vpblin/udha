// Git helpers for sessions: what branch a folder is on, and a worktree per
// session so several assistants can work the same repo without stepping on
// each other. Same layout as the mac app: <repo>-wt\<branch with / folded to ->.
'use strict';

const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function git(cwd, args, timeout = 15000) {
  return new Promise((resolve, reject) => {
    execFile('git', args, { cwd, timeout, windowsHide: true, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const msg = (stderr || err.message || '').trim().split('\n').filter(Boolean).pop() || 'git failed';
        reject(new Error(msg.replace(/^fatal: /, '')));
      } else resolve(stdout.trim());
    });
  });
}

/** { root, branch, branches[] } for a folder inside a repo, or null. */
async function repoInfo(dir) {
  if (!dir || !fs.existsSync(dir)) return null;
  let root;
  try { root = path.normalize(await git(dir, ['rev-parse', '--show-toplevel'])); } catch { return null; }
  const [branch, list] = await Promise.all([
    git(dir, ['rev-parse', '--abbrev-ref', 'HEAD']).catch(() => null),
    git(dir, ['for-each-ref', '--format=%(refname:short)', '--sort=-committerdate', 'refs/heads']).catch(() => ''),
  ]);
  return { root, branch: branch === 'HEAD' ? null : branch, branches: list.split('\n').filter(Boolean).slice(0, 50) };
}

async function currentBranch(dir) {
  try {
    const b = await git(dir, ['rev-parse', '--abbrev-ref', 'HEAD'], 5000);
    return b === 'HEAD' ? null : b;
  } catch { return null; }
}

/** A branch name nobody has yet: udha/<slug>-<4 hex>. */
function suggestBranch(label) {
  const slug = String(label || 'task').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 24) || 'task';
  return `udha/${slug}-${crypto.randomBytes(2).toString('hex')}`;
}

function validBranch(name) {
  return /^[A-Za-z0-9._/-]+$/.test(name) && !name.startsWith('-') && !name.includes('..') && !name.endsWith('/') && !name.endsWith('.lock');
}

/** Folder for a branch's worktree, next to the repo. */
function worktreePath(root, branch) {
  return path.join(`${root}-wt`, branch.replace(/[\\/]/g, '-'));
}

/** Create a worktree on a new branch (from `base`), or check out an existing branch. Returns its folder. */
async function createWorktree(dir, branch, base) {
  if (!validBranch(branch)) throw new Error(`"${branch}" isn't a valid branch name`);
  const info = await repoInfo(dir);
  if (!info) throw new Error('That folder is not inside a git repository');
  const target = worktreePath(info.root, branch);
  if (fs.existsSync(target)) throw new Error(`${target} already exists`);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  if (info.branches.includes(branch)) {
    await git(info.root, ['worktree', 'add', target, branch], 60000);
  } else {
    await git(info.root, ['worktree', 'add', '-b', branch, target, ...(base ? [base] : [])], 60000);
  }
  return target;
}

/** Remove a session's worktree. Refuses (git's own check) when it has uncommitted changes unless forced. */
async function removeWorktree(worktreeDir, force = false) {
  const root = await git(worktreeDir, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  const repo = path.dirname(root);
  await git(repo, ['worktree', 'remove', ...(force ? ['--force'] : []), worktreeDir], 60000);
}

module.exports = { repoInfo, currentBranch, suggestBranch, validBranch, worktreePath, createWorktree, removeWorktree };
