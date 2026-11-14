import type {
  JsonObject,
  PluginAction,
  PluginContext,
  PluginManifest,
  PluginStorageDiscardParams,
  PluginStorageDiscardResult,
  PluginStorageRestoreParams,
  PluginStorageRestoreResult,
  PluginStorageSnapshotsParams,
  PluginStorageSnapshotsResult,
  PluginStorageTransitionReceipt,
} from "../index.js";

const PLUGIN_ID = "example.notes-sync";

/**
 * Valid plugin manifest with declarative private storage migration schema.
 * Target storage version is 2; upgrades from legacy version 0 step-by-step.
 * Note: private ctx.storage is strictly for non-sensitive plugin state (e.g. cursors, preferences).
 * Credentials, passwords, or session tokens must never be placed in ctx.storage;
 * the platform vault manages secrets.
 */
export const manifest: PluginManifest = {
  id: PLUGIN_ID,
  version: "0.2.0",
  api_version: 1,
  entry: "main.mjs",
  name: "Example notes sync",
  capabilities: ["storage.read", "storage.write"],
  network: ["https://example.com"],
  actions: {
    syncNotes: {
      description: "Read and write private state during notes synchronization",
      mutating: false,
    },
  },
  storage_schema: {
    version: 2,
    migrations: [
      {
        from: 0,
        to: 1,
        operations: [
          {
            op: "rename_key",
            from: "legacy_cursor",
            to: "sync_cursor",
          },
          {
            op: "set_default",
            key: "preferences",
            value: {
              auto_sync: true,
              sync_interval: 15,
            },
          },
        ],
      },
      {
        from: 1,
        to: 2,
        operations: [
          {
            op: "patch_object",
            key: "preferences",
            rename_fields: {
              auto_sync: "enabled",
            },
            defaults: {
              notify_on_update: true,
            },
            remove_fields: ["legacy_flag"],
          },
          {
            op: "delete_key",
            key: "temporary_scratch",
          },
        ],
      },
    ],
  },
};

/**
 * Normal plugin action: interacts exclusively with private ctx.storage.
 * The plugin cannot inspect snapshots or trigger schema migrations directly.
 * Fresh empty installs or newly authorized scopes do not run historical defaults;
 * the action initializes required defaults at runtime when keys are absent.
 */
export const syncNotes: PluginAction = async (ctx: PluginContext) => {
  const storedPrefs = (await ctx.storage.get({ key: "preferences" })) as JsonObject | null;
  const prefs = storedPrefs ?? { enabled: true, notify_on_update: true };
  const isEnabled = prefs["enabled"] === true;

  if (isEnabled) {
    await ctx.storage.set({
      key: "last_sync_timestamp",
      value: new Date().toISOString(),
    });
  }

  return {
    synced: isEnabled,
    preferences: prefs,
  };
};

/**
 * Minimal interface representing a trusted host/operator Core RPC client.
 * Host calls require owner authorization and are NOT accessible to plugins.
 */
export interface HostRpcClient {
  call(method: "plugins.storage.snapshots", params: PluginStorageSnapshotsParams): Promise<PluginStorageSnapshotsResult>;
  call(method: "plugins.storage.restore", params: PluginStorageRestoreParams): Promise<PluginStorageRestoreResult>;
  call(method: "plugins.storage.discard", params: PluginStorageDiscardParams): Promise<PluginStorageDiscardResult>;
  call(method: "plugins.rollback", params: { plugin_id: string; generation?: string }): Promise<{ plugin_id: string; version: string; enabled: false }>;
  call(method: "plugins.enable", params: { plugin_id: string }): Promise<{ plugin_id: string; enabled: boolean; storage?: PluginStorageTransitionReceipt }>;
}

/**
 * Host operator recipe: query available storage snapshots.
 */
export async function listSnapshots(
  host: HostRpcClient,
  pluginId: string,
): Promise<PluginStorageSnapshotsResult> {
  return host.call("plugins.storage.snapshots", { plugin_id: pluginId });
}

/**
 * Host operator recipe: rollback code and recover matching private storage state.
 *
 * Workflow:
 * 1. Execute explicit code rollback (`plugins.rollback`). The plugin is automatically disabled.
 * 2. Operator selects an explicit snapshot_id from available snapshots. Multiple snapshots
 *    with the same declared version may exist from previous migrations or restores,
 *    each capturing different historical state.
 * 3. Verify that the selected snapshot's version strictly matches expectedStorageVersion.
 * 4. Restore storage (`plugins.storage.restore`). Core:
 *    - Replaces private storage while retaining per-grant namespace suffixes.
 *    - Automatically creates a reverse recovery snapshot of pre-restore state.
 *    - Leaves the plugin disabled.
 * 5. Explicitly re-enable the plugin (`plugins.enable`).
 */
export async function rollbackAndRecoverStorageRecipe(
  host: HostRpcClient,
  pluginId: string,
  targetGeneration: string,
  targetSnapshotId: string,
  expectedStorageVersion: number,
): Promise<{
  restoredVersion: number;
  reverseRecoverySnapshotId: string;
  enabled: boolean;
}> {
  // 1. Rollback code to previous generation (this also stops runs and disables the plugin).
  await host.call("plugins.rollback", {
    plugin_id: pluginId,
    generation: targetGeneration,
  });

  // 2. Query available recovery snapshots and locate the operator's chosen snapshot.
  const { snapshots } = await host.call("plugins.storage.snapshots", {
    plugin_id: pluginId,
  });

  const selectedSnapshot = snapshots.find(
    (s) => s.snapshot_id === targetSnapshotId,
  );
  if (!selectedSnapshot) {
    throw new Error(
      `Snapshot ${targetSnapshotId} not found for plugin ${pluginId}`,
    );
  }

  // 3. Verify snapshot version matches expected target storage schema version.
  if (selectedSnapshot.version !== expectedStorageVersion) {
    throw new Error(
      `Snapshot ${targetSnapshotId} has version ${selectedSnapshot.version}, but expected storage version ${expectedStorageVersion}`,
    );
  }

  // 4. Restore storage to the verified snapshot.
  // Note: the plugin must be disabled, and restored state remains disabled.
  const restoreResult = await host.call("plugins.storage.restore", {
    plugin_id: pluginId,
    snapshot_id: selectedSnapshot.snapshot_id,
  });

  // 5. Re-enable plugin after verifying compatibility.
  const enableResult = await host.call("plugins.enable", {
    plugin_id: pluginId,
  });

  return {
    restoredVersion: restoreResult.version,
    reverseRecoverySnapshotId: restoreResult.recovery_snapshot_id,
    enabled: enableResult.enabled,
  };
}

/**
 * Host operator recipe: discard an obsolete snapshot.
 */
export async function discardSnapshot(
  host: HostRpcClient,
  pluginId: string,
  snapshotId: string,
): Promise<PluginStorageDiscardResult> {
  return host.call("plugins.storage.discard", {
    plugin_id: pluginId,
    snapshot_id: snapshotId,
  });
}

/**
 * Typecheck boundary verification:
 * Private storage snapshots, restore, and discard are host-only RPCs.
 * They MUST NOT exist on the plugin's ctx.storage facade.
 */
export function pluginBoundaryTypecheck(ctx: PluginContext) {
  // @ts-expect-error plugins.storage.snapshots is a host-only RPC, not a ctx.storage method
  return ctx.storage.snapshots;
}
