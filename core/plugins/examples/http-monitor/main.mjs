// SPDX-License-Identifier: GPL-3.0-or-later
// No Node, browser globals, timers, direct fetch, or credentials.
const TARGET = "https://example.com/";

export async function check(ctx, _input) {
  const previous = await ctx.storage.get({ key: "last-check" });
  const response = await ctx.http.request({ url: TARGET, method: "GET" });
  if (!Number.isInteger(response.status) || response.status < 100 || response.status > 599) {
    throw new Error("Invalid host HTTP status");
  }
  // Deliberately exclude response headers/body/redirect URLs from stored diagnostics.
  const snapshot = {
    target: TARGET,
    status: response.status,
    checked_at: new Date().toISOString(),
    changed: previous != null && previous.status !== response.status,
  };
  await ctx.storage.set({ key: "last-check", value: snapshot });
  await ctx.ui.publish({ id: "monitor", component: {
    type: "card", title: "HTTP monitor", status: snapshot.status,
    changed: snapshot.changed, checked_at: snapshot.checked_at,
  } });
  return snapshot;
}

export async function schedule(ctx, input) {
  if (!input || typeof input.run_at !== "string" || !Number.isFinite(Date.parse(input.run_at))
      || Date.parse(input.run_at) <= Date.now()) {
    throw new Error("A future run_at timestamp is required");
  }
  return ctx.jobs.schedule({
    run_at: input.run_at,
    plugin_id: "official.http-monitor", action: "check", input: {},
  });
}
