// Development-only tests; Node is not a runtime dependency of either plugin.
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import * as monitor from "../http-monitor/main.mjs";
import * as canvas from "../canvas-courses/main.mjs";
import * as fudan from "../fudan-timetable/main.mjs";

function context(responses = []) {
  const calls = [];
  let stored = null;
  const method = (name, implementation = () => null) => async params => {
    calls.push([name, params]); return implementation(params);
  };
  return { calls,
    http: { request: method("http.request", () => responses.shift()) },
    browser: { request: method("browser.request", () => responses.shift()) },
    storage: { get: method("storage.get", () => stored), set: method("storage.set", p => { stored = p.value; }) },
    auth: { status: method("auth.status", () => ({ authenticated: true })),
      requireLogin: method("auth.requireLogin", () => ({ code: "AuthRequired" })) },
    sources: { upsert: method("sources.upsert"), query: method("sources.query", () => []) },
    ui: { publish: method("ui.publish") }, jobs: { schedule: method("jobs.schedule", () => ({ job_id: "synthetic-job" })) },
  };
}
const page = (items, headers = {}, overrides = {}) => ({ status: 200, headers, body: JSON.stringify(items), ...overrides });

test("v1 manifests match named exports and contain only contract fields", async () => {
  for (const [directory, exports] of [["http-monitor", monitor], ["canvas-courses", canvas], ["fudan-timetable", fudan]]) {
    const manifest = JSON.parse(await readFile(new URL(`../${directory}/manifest.json`, import.meta.url), "utf8"));
    assert.deepEqual(Object.keys(manifest).sort(), ["id", "version", "api_version", "entry", "name", "capabilities", "network", "actions", "ui"].sort());
    assert.equal(manifest.api_version, 1);
    for (const name of Object.keys(manifest.actions)) assert.equal(typeof exports[name], "function");
    assert(!manifest.capabilities.includes("storage.get"));
  }
});

test("HTTP monitor uses host HTTP, private storage and UI and discards wire secrets", async () => {
  const ctx = context([{ status: 200, body: "SYNTHETIC-SECRET", headers: { Cookie: "SYNTHETIC-SECRET" } }, { status: 503 }]);
  const first = await monitor.check(ctx, {});
  assert.equal(first.changed, false);
  const next = await monitor.check(ctx, {});
  assert.equal(next.changed, true);
  assert.equal(next.status, 503);
  assert(!JSON.stringify(ctx.calls).includes("SYNTHETIC-SECRET"));
  assert.deepEqual(ctx.calls.slice(0, 4).map(call => call[0]), ["storage.get", "http.request", "storage.set", "ui.publish"]);
  assert.deepEqual(ctx.calls[0][1], { key: "last-check" });
});

test("timed monitor action delegates future work to the persistent host scheduler", async () => {
  const ctx = context();
  const run_at = new Date(Date.now() + 60_000).toISOString();
  assert.deepEqual(await monitor.schedule(ctx, { run_at }), { job_id: "synthetic-job" });
  assert.deepEqual(ctx.calls[0], ["jobs.schedule", { run_at, plugin_id: "official.http-monitor", action: "check", input: {} }]);
  await assert.rejects(() => monitor.schedule(ctx, { run_at: "2000-01-01" }));
});

test("Canvas requests every page through host session and stores only whitelisted sources", async () => {
  const ctx = context([
    page([{ id: 1, name: "Synthetic A", url: "SYNTHETIC-SECRET" }], { LiNk: '<https://elearning.fudan.edu.cn/api/v1/courses?opaque=a,b>; rel="next"' }),
    page([{ id: "9007199254740993", name: "Synthetic B" }]),
  ]);
  const result = await canvas.syncCourses(ctx, { account_id: "test-account" });
  assert.equal(result.status, "synced");
  assert.equal(result.count, 2);
  assert.equal(ctx.calls.filter(c => c[0] === "http.request").length, 2);
  assert.equal(ctx.calls.filter(c => c[0] === "browser.request").length, 0);
  assert(ctx.calls.filter(c => c[0] === "http.request").every(c => c[1].account_id === "test-account"));
  const saved = ctx.calls.filter(c => c[0] === "sources.upsert");
  assert.equal(saved[1][1].external_id, "test-account:course:9007199254740993");
  assert.equal(saved[0][1].source_id, "official.canvas-courses.courses");
  assert(!JSON.stringify(saved).includes("SYNTHETIC-SECRET"));
});

test("Canvas requires login explicitly and does not fake a successful sync", async () => {
  const ctx = context();
  ctx.auth.status = async () => ({ authenticated: false });
  assert.equal((await canvas.syncCourses(ctx, { account_id: "test-account" })).status, "auth_required");
  assert.deepEqual(ctx.calls.map(c => c[0]), ["auth.requireLogin"]);
});

test("Canvas later-page auth failure leaves all existing local sources untouched", async () => {
  const ctx = context([page([{ id: 1, name: "Synthetic" }], { link: '</api/v1/courses?cursor=2>; rel="next"' }), page([], {}, { status: 401 })]);
  assert.equal((await canvas.syncCourses(ctx, { account_id: "test-account" })).status, "auth_required");
  assert.equal(ctx.calls.filter(c => c[0] === "sources.upsert").length, 0);
});

test("Canvas rejects cross-origin and credential pagination before more I/O", async () => {
  for (const target of ["https://evil.example.invalid/api/v1/courses", "/api/v1/courses?access_token=SYNTHETIC", "/api/v1/courses?%61ccess_token=SYNTHETIC", "/api/v1/../login", "/api/v1/%2e%2e/login"]) {
    const ctx = context([page([{ id: 1 }], { link: `<${target}>; rel=next` })]);
    await assert.rejects(() => canvas.syncCourses(ctx, { account_id: "test-account" }), /Unsafe/);
    assert.equal(ctx.calls.filter(c => c[0] === "http.request").length, 1);
    assert.equal(ctx.calls.filter(c => c[0] === "sources.upsert").length, 0);
  }
});

test("Canvas follows next after empty pages and detects cycles", async () => {
  const next = "https://elearning.fudan.edu.cn/api/v1/courses?cursor=2";
  const ctx = context([page([], { link: `<${next}>; rel=next` }), page([], { link: `<${next}>; rel=next` })]);
  await assert.rejects(() => canvas.syncCourses(ctx, { account_id: "test-account" }), /cycle/);
  assert.equal(ctx.calls.filter(c => c[0] === "http.request").length, 2);
});

test("Canvas does not accept rounded JS numeric IDs or malformed JSON envelopes", async () => {
  for (const items of [[{ id: 9007199254740992 }], { error: "not a list" }]) {
    const ctx = context([page(items)]);
    await assert.rejects(() => canvas.syncCourses(ctx, { account_id: "test-account" }));
    assert.equal(ctx.calls.filter(c => c[0] === "sources.upsert").length, 0);
  }
});

test("cached course action queries only plugin-owned sources", async () => {
  const ctx = context();
  await canvas.cachedCourses(ctx, {});
  assert.deepEqual(ctx.calls, [["sources.query", { source_id: "official.canvas-courses.courses", kind: "canvas.course", limit: 100 }]]);
});

test("Canvas handles quoted punctuation in Link fields and final login redirects", async () => {
  const ctx = context([
    page([], { link: '<https://elearning.fudan.edu.cn/api/v1/courses?opaque=a,b>; title="x, <unrelated>; z"; rel="NEXT"' }),
    page([{id:1}]),
  ]);
  assert.equal((await canvas.syncCourses(ctx, {account_id:"test-account"})).count, 1);
  const redirected = context([page([], {}, {final_url:"https://elearning.fudan.edu.cn/login/canvas"})]);
  assert.equal((await canvas.syncCourses(redirected, {account_id:"test-account"})).status, "auth_required");
  assert(!redirected.calls.some(c => c[0] === "sources.upsert"));
});

const semester = { account_id: "test-account", semester_id: "901", starts_on: "2026-03-02" };

test("Fudan UG parses actual fields, multiple units and Sunday boundary via host session", async () => {
  const body = await readFile(new URL("../../../crates/dansheng-connectors/tests/fixtures/undergraduate.json", import.meta.url), "utf8");
  const ctx = context([{ status: 200, body }]);
  const result = await fudan.syncUndergraduate(ctx, semester);
  assert.equal(result.count, 2);
  const saved = ctx.calls.filter(c => c[0] === "sources.upsert");
  assert.equal(saved[0][1].data.start_unit, 1);
  assert.equal(saved[0][1].data.end_unit, 3);
  assert.deepEqual(saved[1][1].data.weeks, [0, 1, 2]);
  assert.equal(saved[0][1].source_id, "official.fudan-timetable.undergraduate");
  assert.equal(ctx.calls.find(c => c[0] === "http.request")[1].url, "https://fdjwgl.fudan.edu.cn/student/for-std/course-table/semester/901/print-data");
  assert.equal(ctx.calls.find(c => c[0] === "http.request")[1].account_id, "test-account");
  assert(!ctx.calls.some(c => c[0] === "browser.request"));
});

test("Fudan PG parses bitmap with week 1 at bit zero and selects an explicit origin", async () => {
  const body = await readFile(new URL("../../../crates/dansheng-connectors/tests/fixtures/postgraduate.json", import.meta.url), "utf8");
  const ctx = context([{ status: 200, body }]);
  const result = await fudan.syncPostgraduate(ctx, { ...semester, endpoint: "secondary" });
  assert.equal(result.count, 2);
  const saved = ctx.calls.filter(c => c[0] === "sources.upsert");
  assert.deepEqual(saved[0][1].data.weeks, [1, 3, 5]);
  assert.deepEqual(saved[1][1].data.teachers, []);
  assert(ctx.calls.find(c => c[0] === "http.request")[1].url.startsWith("http://yjsxktest.fudan.sh.cn/"));
});

test("Fudan auth challenge does not fall back to anonymous/browser requests or write fake empty sources", async () => {
  const ctx = context();
  ctx.auth.status = async () => ({ authenticated: false });
  ctx.auth.requireLogin = async () => { throw { code: "AuthenticationRequired" }; };
  const result = await fudan.syncUndergraduate(ctx, semester);
  assert.equal(result.status, "auth_required");
  assert.equal(result.challenge.origin, "https://fdjwgl.fudan.edu.cn");
  assert.equal(ctx.calls.length, 0);
});

test("Fudan rejects HTML SSO, malformed envelopes, invalid semester and all malformed activities before writes", async () => {
  const ctx = context([{ status: 200, body: '<html><form><input type="password"></form></html>' }]);
  assert.equal((await fudan.syncUndergraduate(ctx, semester)).status, "auth_required");
  for (const payload of [{}, {studentTableVms:[{activities:[{weekday:1,startUnit:1,endUnit:2,teachers:[],weekIndexes:[1],lessonId:1,lessonCode:"X",courseName:"First"},{weekday:0}]}]}]) {
    const invalid = context([page(payload)]);
    await assert.rejects(() => fudan.syncUndergraduate(invalid, semester));
    assert(!invalid.calls.some(c => c[0] === "sources.upsert"));
  }
  const invalid = context();
  await assert.rejects(() => fudan.syncUndergraduate(invalid, { ...semester, semester_id: "../login" }));
  await assert.rejects(() => fudan.syncUndergraduate(invalid, { ...semester, starts_on: "2026-03-01" }));
  assert.equal(invalid.calls.length, 0);
});
