// Real CLI + local IPC + MCP stdio integration. Development Node only.
import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import { smokeRuntime, smokeBinary, smokeOutput } from './runtime-paths.mjs';

const exec = promisify(execFile);
const root = path.resolve(import.meta.dirname, '..');
const runtime = smokeRuntime(root);
const binary = smokeBinary(runtime);
const evidence = smokeOutput(runtime, 'validation');
fs.mkdirSync(evidence, { recursive: true });
const fixtureRoot = fs.mkdtempSync(path.join(evidence, 'host-smoke-'));
const profile = path.join(fixtureRoot, 'profile');
let host, mcp;
const checks = [];

async function cli(method, params = {}) {
  const { stdout } = await exec(binary, ['--data-dir', profile, 'call', method, JSON.stringify(params)], { cwd: root, windowsHide: true, timeout: 60000, maxBuffer: 4 * 1024 * 1024 });
  const response = JSON.parse(stdout);
  assert.equal(response.error, undefined, `${method}: ${JSON.stringify(response.error)}`);
  return response.result;
}
async function startHost() {
  host = spawn(binary, ['--data-dir', profile, 'serve'], { cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let diagnostic = '';
  host.stderr.on('data', chunk => { diagnostic = (diagnostic + chunk).slice(-65536); });
  host.stdout.resume();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (host.exitCode !== null) throw new Error(`host stopped: ${diagnostic}`);
    try { const info = await cli('core.info'); assert.equal(info.name, 'dansheng-core'); return info; } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`host startup timed out: ${diagnostic}`);
}
async function stop(child) {
  if (!child || child.exitCode !== null) return;
  const exit = once(child, 'exit');
  child.kill();
  await exit;
}
function mcpClient() {
  mcp = spawn(binary, ['--data-dir', profile, 'mcp'], { cwd: root, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
  const waiting = new Map(); let buffer = ''; let nextId = 1;
  mcp.stderr.resume();
  mcp.stdout.on('data', chunk => {
    buffer += chunk.toString('utf8');
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'); const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      let message;
      try { message = JSON.parse(line); } catch (error) { for (const p of waiting.values()) p.reject(error); waiting.clear(); continue; }
      if (message.id !== undefined && waiting.has(message.id)) { const p = waiting.get(message.id); waiting.delete(message.id); clearTimeout(p.timer); p.resolve(message); }
    }
  });
  mcp.on('exit', () => { for (const p of waiting.values()) { clearTimeout(p.timer); p.reject(new Error('MCP exited before response')); } waiting.clear(); });
  function request(method, params) {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { waiting.delete(id); reject(new Error(`${method} timed out`)); }, 15000);
      waiting.set(id, { resolve, reject, timer });
      mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  return { request, notify(method, params = {}) { mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n'); } };
}

try {
  await startHost(); checks.push('native service and authenticated IPC');
  const todo = await cli('todo.create', { title: 'Synthetic CLI to MCP shared task' });
  const client = mcpClient();
  const initialized = await client.request('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'dansheng-smoke', version: '0.1.0' } });
  assert.equal(initialized.error, undefined); assert.equal(initialized.result.serverInfo.name, 'dansheng-host');
  client.notify('notifications/initialized');
  const identity = await client.request('tools/call', { name: 'core_call', arguments: { method: 'core.info', params: {} } });
  const mcpSubject = JSON.parse(identity.result.content.find(item => item.type === 'text').text).result.principal;
  assert.notEqual(mcpSubject, 'owner');
  await cli('permissions.set', { subject: mcpSubject, grant: { capabilities: ['todo.read', 'todo.write', 'sources.read', 'jobs.status'] } });
  const listed = await client.request('tools/list', {});
  assert.ok(listed.result.tools.some(tool => tool.name === 'core_call')); checks.push('real MCP initialize/tools/list over stdio');
  const methods = listed.result.tools.find(tool => tool.name === 'core_call').inputSchema.properties.method.enum;
  for (const method of ['fudan.catalog.semesters', 'fudan.programs.list', 'fudan.ehall.tasks', 'fudan.library.loans.current', 'canvas.grades.self']) {
    assert.ok(methods.includes(method), `MCP does not advertise ${method}`);
  }
  for (const method of ['fudan.library.reader.observe', 'fudan.library.reader.bind', 'fudan.library.reader.clear']) {
    assert.equal(methods.includes(method), false, `MCP advertises owner configuration ${method}`);
  }
  checks.push('new campus reads are discoverable while reader configuration is excluded');
  const called = await client.request('tools/call', { name: 'core_call', arguments: { method: 'todo.list', params: {} } });
  assert.notEqual(called.result.isError, true, JSON.stringify(called.result));
  const payload = JSON.parse(called.result.content.find(item => item.type === 'text').text);
  assert.ok(payload.result.items.some(item => item.id === todo.id)); checks.push('MCP reads the same profile TODO created through CLI');
  const denied = await client.request('tools/call', { name: 'core_call', arguments: { method: 'permissions.set', params: { subject: 'mcp', grant: { capabilities: ['mail.send'] } } } });
  assert.equal(denied.result.isError, true); checks.push('MCP cannot grant itself permissions');
  const catalogArgs = { name: 'core_call', arguments: { method: 'fudan.catalog.semesters', params: { account_id: 'release-public' } } };
  assert.equal((await client.request('tools/call', catalogArgs)).result.isError, true);
  checks.push('new campus calls require an explicit MCP grant');
  if (process.argv.includes('--public-catalog')) {
    await cli('accounts.upsert', { account_id: 'release-public', label: 'Public release verification', provider: 'research' });
    await cli('permissions.set', { subject: mcpSubject, grant: {
      capabilities: ['todo.read', 'todo.write', 'sources.read', 'jobs.status', 'fudan.catalog.read'],
      origins: ['https://fdjwgl.fudan.edu.cn'], account_ids: ['release-public'],
    } });
    const catalog = await client.request('tools/call', catalogArgs);
    assert.notEqual(catalog.result.isError, true, 'authorized public catalog read failed');
    const catalogResult = JSON.parse(catalog.result.content.find(item => item.type === 'text').text);
    assert.equal(catalogResult.error, undefined);
    assert.ok(catalogResult.result.payload);
    await cli('permissions.set', { subject: mcpSubject, grant: { capabilities: ['todo.read', 'todo.write', 'sources.read', 'jobs.status'] } });
    assert.equal((await client.request('tools/call', catalogArgs)).result.isError, true);
    checks.push('a new public Core read succeeds through granted MCP and is denied after revocation');
  }
  await stop(mcp); mcp = null;
  let publicProbe;
  if (process.argv.includes('--public-notices')) {
    try {
      const notices = await cli('fudan.notices', { account_id: 'public-verification', page: 1 });
      publicProbe = { success: true, source: 'https://jwc.fudan.edu.cn', records: notices.records.length, coverage: notices.coverage };
    } catch (error) {
      publicProbe = { success: false, error: String(error) };
      try {
        const response=await cli('http.request',{url:'https://jwc.fudan.edu.cn/9397/list.htm',follow_redirects:false,timeout_ms:15000});
        publicProbe.anonymous_http={status:response.status,bytes:Buffer.byteLength(response.body),redirect_origin:response.headers.location?new URL(response.headers.location,'https://jwc.fudan.edu.cn').origin:null};
      } catch (transportError) { publicProbe.anonymous_http={error:String(transportError)}; }
    }
  }
  const snapshot = await cli('backup.create');
  assert.equal(snapshot.complete, true); checks.push('full managed snapshot through live service');
  await stop(host); host = null;
  const { stdout } = await exec(binary, ['--data-dir', profile, 'restore', snapshot.path], { cwd: root, windowsHide: true, timeout: 60000, maxBuffer: 1024 * 1024 });
  const restored = JSON.parse(stdout); assert.equal(restored.restored, true); checks.push('offline restore with a recoverable previous profile');
  await startHost();
  const items = await cli('todo.list'); assert.ok(items.items.some(item => item.id === todo.id));
  const grants = await cli('permissions.get', { subject: mcpSubject }); assert.equal(grants.capabilities.length, 0); checks.push('restored data survives while MCP grants are reset');
  const report = { success: true, profile, previous_profile: restored.previous_profile, checks, public_probe: publicProbe,
    school_requests: process.argv.includes('--public-catalog') || process.argv.includes('--public-notices') };
  fs.writeFileSync(path.join(evidence, 'host-smoke-results.json'), JSON.stringify(report, null, 2) + '\n');
  process.stdout.write(JSON.stringify({ success: true, checks, public_probe: publicProbe }, null, 2) + '\n');
} catch (error) {
  fs.writeFileSync(path.join(evidence, 'host-smoke-results.json'), JSON.stringify({ success: false, checks, error: String(error) }, null, 2) + '\n');
  throw error;
} finally {
  await stop(mcp); await stop(host);
}
