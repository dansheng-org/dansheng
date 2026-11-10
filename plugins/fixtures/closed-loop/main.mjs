// SPDX-License-Identifier: GPL-3.0-or-later
// Shared, unchanged verification package. No secrets or browser/Node APIs.
const ORIGIN = 'http://127.0.0.1:19765';
const SOURCE = 'fixture.closed-loop.courses';
const ACCOUNT = 'fixture-account';

function account(input) {
  if (!input || input.account_id !== ACCOUNT || Object.keys(input).length !== 1) {
    throw new Error('Expected the synthetic fixture account only');
  }
  return input.account_id;
}

export async function sync(ctx, input) {
  const account_id = account(input);
  const auth = await ctx.auth.status({ account_id });
  if (!auth.authenticated) {
    try {
      await ctx.auth.requireLogin({ account_id });
    } catch (error) {
      if (error.code !== 'AuthenticationRequired') throw error;
      return { status: 'auth_required', account_id, challenge: 'AuthenticationRequired' };
    }
    // Completing an external login is a trusted host operation. Never invent it.
    return { status: 'auth_required', account_id, challenge: 'AuthenticationRequired' };
  }
  const response = await ctx.http.request({ account_id, url: ORIGIN + '/fixture', method: 'GET' });
  if (response.status !== 200) throw new Error('Unexpected synthetic HTTP status');
  const wire = JSON.parse(response.body);
  if (wire.account_id !== account_id || wire.id !== 'course-1' ||
      wire.title !== 'Synthetic course' || wire.count !== 2) {
    throw new Error('Unexpected synthetic HTTP body');
  }
  const snapshot = { account_id, source_id: SOURCE, external_id: account_id + ':course-1',
    title: wire.title, count: wire.count };
  await ctx.storage.set({ key: 'last-sync', value: snapshot });
  await ctx.sources.upsert({ account_id, source_id: SOURCE, external_id: snapshot.external_id,
    kind: 'fixture.course', data: { title: snapshot.title, count: snapshot.count } });
  const rows = await ctx.sources.query({ account_id, source_id: SOURCE, external_id: snapshot.external_id });
  if (rows.length !== 1 || rows[0].data.title !== snapshot.title || rows[0].data.count !== snapshot.count) {
    throw new Error('Synthetic source read-back mismatch');
  }
  await ctx.ui.publish({ id: 'summary', component: { type: 'card', title: snapshot.title,
    value: snapshot.count, account_id, source_id: SOURCE, external_id: snapshot.external_id } });
  return { status: 'synced', ...snapshot, records: rows.length };
}

export async function readCache(ctx, input) {
  account(input);
  return await ctx.storage.get({ key: 'last-sync' });
}
