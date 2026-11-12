'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const git = require('../src/main/git');

test('branch names: suggestion is valid, junk is rejected', () => {
  assert.ok(/^udha\/my-repo-[0-9a-f]{4}$/.test(git.suggestBranch('My Repo')));
  assert.ok(git.validBranch('feature/x-1'));
  assert.ok(!git.validBranch('-x'));
  assert.ok(!git.validBranch('a..b'));
  assert.ok(!git.validBranch('has space'));
  assert.equal(git.worktreePath('C:\\r\\app', 'udha/x'), path.join('C:\\r\\app-wt', 'udha-x'));
});

test('create and remove a worktree in a throwaway repo', async () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'udha-git-'));
  const repo = path.join(base, 'app');
  fs.mkdirSync(repo);
  const run = (...a) => execFileSync('git', a, { cwd: repo, stdio: 'pipe' });
  run('init', '-q', '-b', 'main');
  run('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'init');

  const info = await git.repoInfo(repo);
  assert.equal(info.branch, 'main');
  assert.deepEqual(info.branches, ['main']);
  assert.equal(await git.repoInfo(base), null);

  const wt = await git.createWorktree(repo, 'udha/test-1', 'main');
  assert.equal(path.basename(wt), 'udha-test-1');
  assert.equal(path.basename(path.dirname(wt)), 'app-wt');
  assert.ok(fs.existsSync(wt));
  assert.equal(await git.currentBranch(wt), 'udha/test-1');

  fs.writeFileSync(path.join(wt, 'dirty.txt'), 'x');
  await assert.rejects(git.removeWorktree(wt, false));
  await git.removeWorktree(wt, true);
  assert.ok(!fs.existsSync(wt));
  fs.rmSync(base, { recursive: true, force: true });
});
