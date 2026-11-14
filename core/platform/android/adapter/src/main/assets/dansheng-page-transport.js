// SPDX-License-Identifier: GPL-3.0-or-later
// Executed in the CURRENT authenticated document. Deliberately use current page
// fetch/XHR, including wrappers installed by that page. Never cache native APIs.
(function (key, id, p) {
  const box = window[key] || (window[key] = Object.create(null));
  const state = box[id] = { done: false };
  const finish = value => { state.done = true; state.value = value; };
  const failed = () => finish({ error: p.mutating ? 'NeedsReconciliation' : 'BrowserRequestFailed' });
  const safeHeaders = (url, read) => {
    const headers = Object.create(null);
    if (!read) return headers;
    for (const name of ['content-type', 'link']) {
      const value = read(name);
      if (!value) continue;
      if (value.length > (name === 'link' ? 32768 : 1024) || /[\r\n\0]/.test(value)) throw new Error();
      if (name === 'link') {
        const base = new URL(url, p.url);
        for (const match of value.matchAll(/<([^>]*)>/g)) {
          const target = new URL(match[1], base);
          if (target.origin !== base.origin || target.username || target.password || target.hash) throw new Error();
          for (const key of target.searchParams.keys()) {
            if (/token|ticket|signature|password|credential|session|secret|auth/i.test(key) ||
                /^(api_key|apikey|sig|verifier)$/i.test(key) || /^x-(amz|goog)-/i.test(key)) throw new Error();
          }
        }
      }
      headers[name] = value;
    }
    return headers;
  };
  const clean = (status, url, body, readHeaders) => {
    if (!Number.isInteger(status) || status <= 0) return failed();
    if (body.length > p.max_body_chars) return finish({ error: p.mutating ? 'NeedsReconciliation' : 'ResponseTooLarge' });
    // Only bounded content-type and safe same-origin pagination Link survive.
    // Authentication headers, request headers and exceptions never leave the page.
    try { finish({ status, url, body, headers: safeHeaders(url, readHeaders) }); }
    catch (_) { failed(); }
  };
  try {
    if (p.transport === 'xhr') {
      const xhr = new XMLHttpRequest();
      state.abort = () => xhr.abort();
      xhr.open(p.method, p.url, true);
      xhr.timeout = p.timeout_ms;
      for (const name of Object.keys(p.headers)) xhr.setRequestHeader(name, p.headers[name]);
      xhr.onload = () => clean(xhr.status, xhr.responseURL || p.url, xhr.responseText,
        typeof xhr.getResponseHeader === 'function' ? name => xhr.getResponseHeader(name) : null);
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
        .then(async response => clean(response.status, response.url, await response.text(),
          response.headers && typeof response.headers.get === 'function' ? name => response.headers.get(name) : null))
        .catch(failed).finally(() => clearTimeout(timeout));
    }
  } catch (_) { failed(); }
})
