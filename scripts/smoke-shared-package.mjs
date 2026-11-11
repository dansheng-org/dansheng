// Development only: actual native Host/QuickJS/SQLite/IPC/MCP, synthetic loopback data.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { smokeRuntime, smokeBinary, smokeOutput } from './runtime-paths.mjs';

const root = path.resolve(import.meta.dirname, '..');
const runtime = smokeRuntime(root);
const binary = smokeBinary(runtime, 'release');
const packageDir = path.join(root, 'plugins/fixtures/closed-loop');
const output = smokeOutput(runtime, 'validation/shared-package');
fs.mkdirSync(output, { recursive: true });
const profile = path.join(fs.mkdtempSync(path.join(output, 'paired-')), 'profile');
const execute = promisify(execFile);
const childEnv = { ...process.env, HTTP_PROXY: '', HTTPS_PROXY: '', ALL_PROXY: '',
  http_proxy: '', https_proxy: '', all_proxy: '', NO_PROXY: '127.0.0.1,localhost,::1', no_proxy: '127.0.0.1,localhost,::1' };
const account = 'fixture-account', plugin = 'fixture.closed-loop', source = `${plugin}.courses`;
const params = { account_id: account };
const query = { account_id: account, source_id: source, external_id: `${account}:course-1` };
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const normalize = value => Array.isArray(value) ? value.map(normalize) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, normalize(value[key])])) : value;
function packageIdentity() {
  const names = fs.readdirSync(packageDir).sort();
  assert.deepEqual(names, ['LICENSE', 'README.md', 'main.mjs', 'manifest.json']);
  const files = names.map(name => ({ path: name, sha256: hash(fs.readFileSync(path.join(packageDir, name))) }));
  return { files, sha256: hash(files.map(file => `${file.sha256}  ${file.path}\n`).join('')) };
}
const identity = packageIdentity();
const wire = { account_id: account, id: 'course-1', title: 'Synthetic course', count: 2 };
let requests = 0, accepted = 0, host, mcp;
const server = http.createServer((request, response) => {
  requests++;
  if (request.method !== 'GET' || request.url !== '/fixture'
      || request.headers.authorization !== 'Bearer synthetic-fixture-bearer') {
    response.writeHead(401, { Connection: 'close' }); response.end(); return;
  }
  accepted++;
  const body = JSON.stringify(wire);
  response.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), Connection: 'close' });
  response.end(body);
});
async function cli(method, input = {}) {
  const { stdout } = await execute(binary, ['--data-dir', profile, 'call', method, JSON.stringify(input)],
    { cwd: root, env: childEnv, windowsHide: true, timeout: 30000, maxBuffer: 2 * 1024 * 1024 });
  const result = JSON.parse(stdout);
  assert.equal(result.error, undefined, `native ${method} returned ${result.error?.code}`);
  return result.result;
}
async function startHost() {
  host = spawn(binary, ['--data-dir', profile, 'serve'], { cwd: root, env: childEnv, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  host.stdout.resume(); host.stderr.resume();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    assert.equal(host.exitCode, null, 'fixture Host exited');
    try { await cli('core.info'); return; } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('fixture Host startup timeout');
}
async function stop(child) {
  if (!child || child.exitCode !== null) return;
  const exited = once(child, 'exit'); child.kill(); await exited;
}
function mcpClient() {
  mcp = spawn(binary, ['--data-dir', profile, 'mcp'], { cwd: root, env: childEnv, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  mcp.stderr.resume();
  let next = 1, buffer = ''; const pending = new Map();
  mcp.stdout.on('data', chunk => {
    buffer += chunk.toString('utf8');
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'), line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      const value = JSON.parse(line), waiter = pending.get(value.id);
      if (waiter) { clearTimeout(waiter.timer); pending.delete(value.id); waiter.resolve(value); }
    }
  });
  mcp.on('exit', () => { for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(new Error('MCP exited')); } pending.clear(); });
  function request(method, input = {}) {
    const id = next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error('MCP fixture timeout')); }, 15000);
      pending.set(id, { resolve, reject, timer });
      mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params: input }) + '\n');
    });
  }
  async function call(method, input = {}) {
    const result = await request('tools/call', { name: 'core_call', arguments: { method, params: input } });
    assert.equal(result.error, undefined);
    const value = JSON.parse(result.result.content.find(content => content.type === 'text').text);
    return { ...value, tool_error: result.result.isError === true };
  }
  return { request, call, initialized() { mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} }) + '\n'); } };
}
const report = { success: false, platform: 'windows-x64', phase: process.env.DANSHENG_VERIFICATION_PHASE || path.basename(path.dirname(binary)),
  binary_path: path.relative(root, binary), package_sha256: identity.sha256,
  package_files: identity.files, binary_sha256: hash(fs.readFileSync(binary)), checks: [] };
try {
  server.listen({ host: '127.0.0.1', port: 19765, exclusive: true });
  await once(server, 'listening'); // EADDRINUSE rejects; never kill another owner or switch origin.
  await startHost();
  const manifest = JSON.parse(fs.readFileSync(path.join(packageDir, 'manifest.json'), 'utf8'));
  await cli('plugins.install', { path: packageDir });
  await cli('permissions.set', { subject: `plugin:${plugin}`, grant: {
    capabilities: manifest.capabilities, origins: manifest.network, account_ids: [account], allow_private_network: true,
  } });
  await cli('plugins.enable', { plugin_id: plugin });
  const action = action => cli('plugins.run', { plugin_id: plugin, action, input: params });
  const authRequired = await action('sync');
  assert.deepEqual(authRequired, { status: 'auth_required', account_id: account, challenge: 'AuthenticationRequired' });
  assert.equal(await action('readCache'), null); assert.equal(requests, 0);
  report.checks.push('real auth broker challenge with no HTTP dispatch');
  await cli('auth.session.set', { account_id: account, origin: manifest.network[0], bearer: 'synthetic-fixture-bearer', persist: false });
  const authentication = await cli('auth.status', params);
  assert.equal(authentication.verification, 'local_credentials_only');
  const sync = await action('sync'), cache = await action('readCache');
  assert.equal(sync.status, 'synced'); assert.equal(sync.records, 1);
  assert.equal(requests, 1); assert.equal(accepted, 1);
  const rows = await cli('sources.query', query); assert.equal(rows.length, 1);
  const record = Object.fromEntries(['owner', 'account_id', 'source_id', 'external_id', 'kind', 'data'].map(key => [key, rows[0][key]]));
  const ui = await cli('ui.get', { principal: `plugin:${plugin}`, id: 'summary' });
  const client = mcpClient();
  const initialized = await client.request('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'shared-package-verification', version: '0.1' } });
  assert.equal(initialized.error, undefined); client.initialized();
  const subject = (await client.call('core.info')).result.principal;
  assert.notEqual(subject, 'owner');
  assert.equal((await client.call('sources.query', query)).tool_error, true);
  await cli('permissions.set', { subject, grant: { capabilities: ['sources.read', 'plugins.list', 'ui.get'], account_ids: [account], source_ids: [source] } });
  const readBack = await client.call('sources.query', query);
  assert.equal(readBack.tool_error, false); assert.equal(readBack.result.length, 1);
  assert.deepEqual(readBack.result[0].data, record.data);
  const packages = await client.call('plugins.list');
  assert.deepEqual(packages.result.find(item => item.id === plugin).manifest.ui, manifest.ui);
  // Dynamic UI state belongs to the plugin, not the MCP reader's own namespace.
  assert.equal((await client.call('ui.get', { principal: `plugin:${plugin}`, id: 'summary' })).result, null);
  assert.equal((await client.call('permissions.set', { subject, grant: { capabilities: ['*'] } })).tool_error, true);
  report.checks.push('real stdio MCP reads granted source and static UI descriptor; private UI and authorization remain scoped');
  await stop(mcp); mcp = null;
  await stop(host); host = null;
  await startHost();
  assert.equal((await cli('auth.status', params)).authenticated, false);
  assert.deepEqual(await action('readCache'), cache);
  assert.equal((await cli('sources.query', query)).length, 1);
  assert.deepEqual(await cli('ui.get', { principal: `plugin:${plugin}`, id: 'summary' }), ui);
  assert.equal(requests, 1);
  assert.equal(packageIdentity().sha256, identity.sha256, 'shared package changed during execution');
  report.normalized = normalize({ sync, cache, source: record, ui });
  report.normalized_sha256 = hash(JSON.stringify(report.normalized));
  report.network = { requests, accepted, loopback_only: true };
  report.checks.push('native HTTP, QuickJS, private/canonical SQLite data and UI description survive a real Host restart');
  report.success = true;
} catch (error) {
  report.error = String(error);
  throw error;
} finally {
  await stop(mcp); await stop(host);
  server.closeAllConnections(); if (server.listening) await new Promise(resolve => server.close(resolve));
  fs.writeFileSync(path.join(output, 'shared-package-windows.json'), JSON.stringify(report, null, 2) + '\n');
  if (report.success) process.stdout.write(JSON.stringify(report, null, 2) + '\n');
}
