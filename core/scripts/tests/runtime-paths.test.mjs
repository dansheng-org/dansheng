import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { smokeRuntime, smokeBinary, smokeOutput } from '../runtime-paths.mjs';

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'dansheng-smoke-paths-'));
const runtime = path.join(fixture, 'runtime with spaces');
const source = path.join(fixture, 'source');
fs.mkdirSync(runtime);
fs.mkdirSync(source);
const names = ['DANSHENG_TASK_RUNTIME', 'DANSHENG_SMOKE_ROOT', 'DANSHENG_HOST_BIN', 'CARGO_TARGET_DIR'];

function environment(operation) {
  const previous = Object.fromEntries(names.map(name => [name, process.env[name]]));
  try {
    for (const name of names) delete process.env[name];
    process.env.DANSHENG_TASK_RUNTIME = runtime;
    operation();
  } finally {
    for (const name of names) {
      if (previous[name] === undefined) delete process.env[name];
      else process.env[name] = previous[name];
    }
  }
}

test('default smoke paths and explicit output preserve the selected runtime', () => environment(() => {
  assert.equal(smokeRuntime(source), runtime);
  assert.equal(smokeOutput(runtime, 'validation'), path.join(runtime, 'validation'));
  process.env.DANSHENG_SMOKE_ROOT = path.join(runtime, 'fresh evidence');
  assert.equal(smokeOutput(runtime, 'validation'), process.env.DANSHENG_SMOKE_ROOT);
  const binary = process.platform === 'win32' ? 'dansheng-host.exe' : 'dansheng-host';
  assert.equal(smokeBinary(runtime), path.join(runtime, 'cargo-target', 'debug', binary));
}));

test('relative and sibling output overrides fail before creating any output', () => environment(() => {
  process.env.DANSHENG_SMOKE_ROOT = '../outside';
  assert.throws(() => smokeOutput(runtime, 'validation'), /absolute path/);
  const outside = path.join(fixture, 'runtime with spaces-other', 'evidence');
  process.env.DANSHENG_SMOKE_ROOT = outside;
  assert.throws(() => smokeOutput(runtime, 'validation'), /inside the selected task runtime/);
  assert.equal(fs.existsSync(outside), false);
}));

test('a linked output ancestor cannot write through to another directory', () => environment(() => {
  const outside = path.join(fixture, 'preserved outside');
  const link = path.join(runtime, 'linked output');
  fs.mkdirSync(outside);
  fs.symlinkSync(outside, link, process.platform === 'win32' ? 'junction' : 'dir');
  process.env.DANSHENG_SMOKE_ROOT = path.join(link, 'new evidence');
  assert.throws(() => smokeOutput(runtime, 'validation'), /Linked smoke output/);
  assert.deepEqual(fs.readdirSync(outside), []);
}));

test('missing runtime and outside Cargo targets cannot fall back to source paths', () => environment(() => {
  delete process.env.DANSHENG_TASK_RUNTIME;
  assert.throws(() => smokeRuntime(source), /absolute runtime directory/);
  process.env.DANSHENG_TASK_RUNTIME = path.join(source, 'build');
  assert.throws(() => smokeRuntime(source), /outside source/);
  process.env.CARGO_TARGET_DIR = path.join(fixture, 'outside-target');
  assert.throws(() => smokeBinary(runtime), /inside the selected task runtime/);
}));

test('Core module smoke paths protect the entire registered checkout and primary repository', () => environment(() => {
  const primary = path.join(fixture, 'monorepo');
  const checkout = path.join(fixture, 'linked checkout');
  fs.mkdirSync(path.join(primary, 'core'), { recursive: true });
  fs.mkdirSync(path.join(primary, 'apps', 'dansheng_app'), { recursive: true });
  fs.writeFileSync(path.join(primary, 'core', 'Cargo.toml'), '# synthetic fixture\n');
  fs.writeFileSync(path.join(primary, 'apps', 'dansheng_app', 'pubspec.yaml'), 'name: fixture\n');
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  const git = (...args) => execFileSync('git', ['--no-optional-locks', '-C', primary, ...args], { env, stdio: 'pipe', windowsHide: true });
  git('init', '--initial-branch=main');
  git('add', '--all');
  git('-c', 'user.name=Runtime fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', '-c', `core.hooksPath=${path.join(fixture, 'no-hooks')}`, 'commit', '-m', 'Synthetic runtime fixture');
  git('worktree', 'add', '-b', 'fixture/runtime', checkout, 'HEAD');
  const core = path.join(checkout, 'core');
  assert.equal(smokeRuntime(core), runtime);
  for (const rejected of [path.join(checkout, 'apps', 'cache'), path.join(primary, 'cache'), fixture]) {
    process.env.DANSHENG_TASK_RUNTIME = rejected;
    assert.throws(() => smokeRuntime(core), /outside source checkouts/);
    if (rejected !== fixture) assert.equal(fs.existsSync(rejected), false);
  }
}));
