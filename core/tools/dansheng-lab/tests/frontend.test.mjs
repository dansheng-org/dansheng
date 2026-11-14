// Offline JS behavior tests, not a browser rendering test. All data is synthetic.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const html = await readFile(new URL('../static/index.html', import.meta.url), 'utf8');
const source = await readFile(new URL('../static/app.js', import.meta.url), 'utf8');

async function page() {
  const elements = new Map([...html.matchAll(/id="([^"]+)"/g)].map(([, id]) => {
    const classes = new Set();
    return [id, {
      value: '', textContent: '', className: '', disabled: false,
      classList: { add: (...v) => v.forEach(x => classes.add(x)), remove: (...v) => v.forEach(x => classes.delete(x)), contains: v => classes.has(v) },
      events: {}, addEventListener(event, handler) { this.events[event] = handler; },
      closest() { return null; }, focus() {},
    }];
  }));
  const events = {}, requests = [];
  const state = { stored: false, selectedProbe: 'core', unauthorized: false };
  const location = { hash: '#token=synthetic-bootstrap', pathname: '/', search: '' };
  const document = {
    getElementById: id => elements.get(id) ?? null,
    querySelectorAll: () => [],
    querySelector: selector => selector.includes('probe_type') ? { value: state.selectedProbe } : { value: 'academic' },
    addEventListener: (event, handler) => { events[event] = handler; },
  };
  const context = {
    document, URLSearchParams, AbortController, performance, setTimeout, clearTimeout,
    console: { log() { throw new Error('Unexpected console output'); } },
    window: {
      location,
      history: { replaceState() { location.hash = ''; } },
      get localStorage() { throw new Error('Unexpected browser persistence'); },
      get sessionStorage() { throw new Error('Unexpected browser persistence'); },
    },
    fetch: async (url, options) => {
      assert.equal(location.hash, '', 'bootstrap must leave the URL before any fetch');
      assert.equal(options.credentials, 'same-origin');
      requests.push({ url, ...options });
      const status = state.unauthorized ? 401 : 200;
      let payload;
      if (status === 401) payload = { error: { code: 'SessionRequired', message: 'reopen' } };
      else if (url === '/api/session') payload = { csrf_token: 'synthetic-csrf' };
      else if (url === '/api/status') payload = {
        credentials: { stored: state.stored, username_hint: state.stored ? '20****23' : null },
        session: { authenticated: false, verification: 'local_credentials_only' },
        runtime: { core_available: true, mode: 'local_lab', version: '0.1.0' },
      };
      else if (url === '/api/credentials') {
        assert.equal(options.headers['X-CSRF-Token'], 'synthetic-csrf');
        state.stored = options.method !== 'DELETE';
        payload = { stored: state.stored, username_hint: '20****23' };
      } else if (url === '/api/probe') {
        payload = { ok: true, probe: state.selectedProbe, elapsed_ms: 2, summary: { count: 1, message: 'synthetic result' }, result: [{ title: '<script>malicious()</script>' }] };
      } else throw new Error('Unexpected request destination');
      return { ok: status === 200, status, headers: { get: () => 'application/json' }, json: async () => payload };
    },
  };
  vm.runInNewContext(source, context, { timeout: 1000 });
  events.DOMContentLoaded();
  await new Promise(setImmediate);
  return { elements, requests, state };
}

test('bootstrap is exchanged once and removed before requests; no browser storage', async () => {
  const ui = await page();
  assert.deepEqual(ui.requests.map(r => r.url), ['/api/session', '/api/status']);
  assert.equal(ui.elements.get('btn-save-credentials').disabled, false);
  assert.equal(ui.elements.get('btn-login-target').disabled, true);
});

test('saving synthetic credentials clears inputs, does not log in, and displays only a mask', async () => {
  const ui = await page();
  ui.elements.get('input-student-id').value = '20770000123';
  ui.elements.get('input-password').value = 'only-an-offline-fixture-password';
  await ui.elements.get('form-credentials').events.submit({ preventDefault() {} });
  assert.equal(ui.elements.get('input-student-id').value, '');
  assert.equal(ui.elements.get('input-password').value, '');
  assert.equal(ui.requests.some(r => r.url === '/api/login'), false);
  assert.equal(ui.elements.get('btn-login-target').disabled, false);
  const visibleText = [...ui.elements.values()].map(el => el.textContent).join('\n');
  assert.equal(visibleText.includes('20770000123'), false);
  assert.equal(visibleText.includes('only-an-offline-fixture-password'), false);
  assert.equal(ui.elements.get('pipeline-session-state').textContent, '未导入');
});

test('local/public probes never claim a private authenticated read and JSON uses text', async () => {
  const ui = await page();
  for (const probe of ['core', 'public_notices', 'cache']) {
    ui.state.selectedProbe = probe;
    await ui.elements.get('btn-run-probe').events.click();
    assert.equal(ui.elements.get('pipeline-probe-state').textContent, '私有来源待验证');
  }
  assert.match(ui.elements.get('probe-result-json').textContent, /<script>/);
  ui.state.selectedProbe = 'academic_semesters';
  await ui.elements.get('btn-run-probe').events.click();
  assert.match(ui.elements.get('pipeline-probe-state').textContent, /教务学期列表已通过/);
});

test('an expired session stays disabled after the request finally handler', async () => {
  const ui = await page();
  ui.state.unauthorized = true;
  await ui.elements.get('btn-run-probe').events.click();
  assert.equal(ui.elements.get('btn-run-probe').disabled, true);
  assert.equal(ui.elements.get('btn-save-credentials').disabled, true);
});
