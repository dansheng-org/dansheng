// SPDX-License-Identifier: GPL-3.0-or-later
// Executed in the CURRENT authenticated document. Deliberately use current page
// fetch/XHR, including wrappers installed by that page. Never cache native APIs.
(function (key, id, p) {
  const box = window[key] || (window[key] = Object.create(null));
  const state = box[id] = { done: false };
  const finish = value => { state.done = true; state.value = value; };
  const failed = () => finish({ error: p.mutating ? 'NeedsReconciliation' : 'BrowserRequestFailed' });
  const clean = (status, url, body) => {
    if (!Number.isInteger(status) || status <= 0) return failed();
    if (body.length > p.max_body_chars) return finish({ error: p.mutating ? 'NeedsReconciliation' : 'ResponseTooLarge' });
    // Do not export response headers (cookies/tokens), request headers or exceptions.
    finish({ status, url, body });
  };
  try {
    if (p.transport === 'xhr') {
      const xhr = new XMLHttpRequest();
      state.abort = () => xhr.abort();
      xhr.open(p.method, p.url, true);
      xhr.timeout = p.timeout_ms;
      for (const name of Object.keys(p.headers)) xhr.setRequestHeader(name, p.headers[name]);
      xhr.onload = () => clean(xhr.status, xhr.responseURL || p.url, xhr.responseText);
      xhr.onerror = xhr.ontimeout = xhr.onabort = failed;
      let body = p.body || null;
      if (p.form_fields) {
        body = new FormData();
        for (const name of Object.keys(p.form_fields)) body.append(name, p.form_fields[name]);
      }
      xhr.send(body);
    } else {
      const controller = new AbortController();
      state.abort = () => controller.abort();
      const timeout = setTimeout(() => controller.abort(), p.timeout_ms);
      // Calling window.fetch preserves WAF patches and dynamic URL rewriting.
      window.fetch(p.url, { method: p.method, headers: p.headers,
        body: p.method === 'GET' ? undefined : p.body,
        credentials: 'same-origin', cache: 'no-store', signal: controller.signal })
        .then(async response => clean(response.status, response.url, await response.text()))
        .catch(failed).finally(() => clearTimeout(timeout));
    }
  } catch (_) { failed(); }
})
