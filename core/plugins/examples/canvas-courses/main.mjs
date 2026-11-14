// SPDX-License-Identifier: GPL-3.0-or-later
// Pagination/source mapping informed by Chang-Yo/Dela e82da12f, GPL-3.0-or-later.
// See ../../../crates/dansheng-connectors/NOTICE.md. No Dela runtime is used.
const ORIGIN = "https://elearning.fudan.edu.cn";
const SOURCE = "official.canvas-courses.courses";
const FIRST = ORIGIN + "/api/v1/courses?include[]=term&per_page=100";

function apiUrl(value) {
  // QuickJS has no browser URL global. Restrict to this manifest's literal origin.
  const absolute = value.startsWith("/api/v1/") ? ORIGIN + value : value;
  if (!absolute.startsWith(ORIGIN + "/api/v1/") || /[\\\s#]/.test(absolute)
      || /%(?:2f|5c|25|2e)/i.test(absolute.split("?")[0])
      || /(?:^|\/)\.{1,2}(?:\/|$|\?)/.test(absolute)
      || /[?&](?:access_token|token|authorization|session_token|verifier)=/i.test(absolute)) {
    throw new Error("Unsafe Canvas pagination URL");
  }
  for (const pair of (absolute.split("?")[1] || "").split("&")) {
    let key;
    try { key = decodeURIComponent(pair.split("=")[0]).toLowerCase(); }
    catch { throw new Error("Unsafe Canvas pagination URL"); }
    if (["access_token", "token", "authorization", "session_token", "verifier"].includes(key)) {
      throw new Error("Unsafe Canvas pagination URL");
    }
  }
  return absolute;
}

function splitHeader(value, delimiter) {
  const parts = [];
  let start = 0, uri = false, quoted = false, escaped = false;
  for (let i = 0; i < value.length; i++) {
    const c = value[i];
    if (escaped) { escaped = false; continue; }
    if (quoted && c === "\\") { escaped = true; continue; }
    if (!uri && c === '"') quoted = !quoted;
    else if (!quoted) {
      if (c === "<") uri = true;
      else if (c === ">") uri = false;
      else if (!uri && c === delimiter) { parts.push(value.slice(start, i)); start = i+1; }
    }
  }
  if (quoted || uri || escaped) throw new Error("Invalid Canvas Link header");
  parts.push(value.slice(start));
  return parts;
}

function nextPage(headers) {
  const pairs = Array.isArray(headers) ? headers : Object.entries(headers || {});
  let next = null;
  for (const [name, value] of pairs) {
    if (name.toLowerCase() !== "link") continue;
    const entries = splitHeader(String(value), ",");
    for (const entry of entries) {
      const match = /^\s*<([^>]+)>\s*(.*)$/.exec(entry);
      if (!match) throw new Error("Invalid Canvas Link header");
      const isNext = splitHeader(match[2], ";").some(parameter => {
        const relation = /^\s*rel\s*=\s*(?:"([^"]*)"|([^;\s]+))\s*$/i.exec(parameter);
        return relation && (relation[1] || relation[2]).toLowerCase().split(/\s+/).includes("next");
      });
      if (!isNext) continue;
      const target = apiUrl(match[1]);
      if (next !== null && next !== target) throw new Error("Conflicting Canvas next links");
      next = target;
    }
  }
  return next;
}

function externalId(value) {
  if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return String(value);
  if (typeof value === "string" && /^\d{1,32}$/.test(value)) return value;
  throw new Error("Invalid Canvas course ID");
}

async function authRequired(ctx, accountId) {
  try {
    const challenge = await ctx.auth.requireLogin({ account_id: accountId, origin: ORIGIN });
    return { status: "auth_required", challenge };
  } catch (error) {
    if (error && (error.code === "AuthenticationRequired" || error.code === "AuthRequired")) {
      return { status: "auth_required", challenge: { code: error.code, account_id: accountId, origin: ORIGIN } };
    }
    throw error;
  }
}

export async function syncCourses(ctx, input) {
  const accountId = input && input.account_id;
  if (typeof accountId !== "string" || !accountId.trim()) throw new Error("account_id is required");
  const auth = await ctx.auth.status({ account_id: accountId, origin: ORIGIN });
  if (!auth || auth.authenticated !== true) return authRequired(ctx, accountId);
  let url = FIRST;
  const seen = new Set();
  const records = [];
  const observedAt = new Date().toISOString();
  // Collect every page before publishing any local snapshot. Later-page errors retain cache.
  while (url !== null) {
    url = apiUrl(url);
    if (seen.has(url)) throw new Error("Canvas pagination cycle");
    if (seen.size >= 40) throw new Error("Canvas pagination limit exceeded");
    seen.add(url);
    const response = await ctx.http.request({
      account_id: accountId, url, method: "GET", headers: { Accept: "application/json" },
    });
    if (response.status === 401 || (response.status >= 300 && response.status < 400)) {
      return authRequired(ctx, accountId);
    }
    if (!Number.isInteger(response.status) || response.status < 200 || response.status >= 300) {
      throw new Error("Canvas HTTP request failed");
    }
    const finalUrl = response.final_url || response.url;
    if (finalUrl && !finalUrl.startsWith(ORIGIN + "/api/v1/")) return authRequired(ctx, accountId);
    if (finalUrl) apiUrl(finalUrl);
    if (typeof response.body !== "string" || response.body.length > 2 * 1024 * 1024) {
      throw new Error("Invalid Canvas body");
    }
    if (/^\s*(?:<!doctype|<html|<form)/i.test(response.body)) return authRequired(ctx, accountId);
    let page;
    try { page = JSON.parse(response.body); } catch { throw new Error("Invalid Canvas JSON"); }
    if (!Array.isArray(page)) throw new Error("Canvas did not return a course list");
    if (records.length + page.length > 5000) throw new Error("Canvas course limit exceeded");
    for (const course of page) {
      if (!course || typeof course !== "object") throw new Error("Invalid Canvas course");
      const id = externalId(course.id);
      // Whitelist fields; never persist raw remote JSON, cookies or signed URLs.
      records.push({ source_id: SOURCE, external_id: accountId + ":course:" + id, kind: "canvas.course", data: {
        account_id: accountId, external_id: id, observed_at: observedAt,
        name: typeof course.name === "string" ? course.name : null,
        course_code: typeof course.course_code === "string" ? course.course_code : null,
        term: course.term && typeof course.term.name === "string" ? course.term.name : null,
      } });
    }
    url = nextPage(response.headers);
  }
  for (const record of records) await ctx.sources.upsert(record);
  await ctx.ui.publish({ id: "courses", component: {
    type: "list", title: "Canvas courses", items: records.map(record => ({
      id: record.external_id, title: record.data.name || record.data.course_code || record.data.external_id,
    })),
  } });
  return { status: "synced", count: records.length, observed_at: observedAt };
}

export async function cachedCourses(ctx, _input) {
  return ctx.sources.query({ source_id: SOURCE, kind: "canvas.course", limit: 100 });
}
