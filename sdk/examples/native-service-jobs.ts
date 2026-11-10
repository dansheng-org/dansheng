import type { NativeServiceJobScheduleParams, PluginContext } from '../index.js';

export const nativeCourseSync: NativeServiceJobScheduleParams = {
  kind: 'service',
  method: 'canvas.courses.sync',
  input: { account_id: 'example-account' },
  interval_seconds: 900,
  deadline_window_seconds: 60,
};

/** The trusted host sends this through its authenticated Core RPC client. */
export function nativeSyncRequest(id: string) {
  return { id, method: 'jobs.schedule', params: nativeCourseSync };
}

export function pluginBoundaryTypecheck(ctx: PluginContext) {
  // @ts-expect-error Native service scheduling must not widen the plugin facade.
  return ctx.jobs.schedule(nativeCourseSync);
}
