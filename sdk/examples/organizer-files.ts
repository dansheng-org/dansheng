import type {
  JsonObject,
  PluginAction,
  PluginContext,
  PluginManifest,
} from "../index.js";

const PLUGIN_ID = "example.organizer-files";
const ACCOUNT_ID = "fixture-account";
const DOCUMENT_SOURCE = `${PLUGIN_ID}.documents`;
const ACTIVITY_SOURCE = `${PLUGIN_ID}.activity`;
const FIXTURE_URL = "https://example.com/fixture.txt";
const TIMEZONE = "Asia/Shanghai";

type OrganizeInput = JsonObject & {
  title: string;
  start_at: string;
  end_at: string;
  reminder_at: string;
};

type OrganizeResult = JsonObject & {
  asset_id: string;
  todo_id: string;
  event_id: string;
  reminder_id: string;
  activity_total: number;
  conflict_count: number;
};

export const manifest = {
  id: PLUGIN_ID,
  version: "0.1.0",
  api_version: 1,
  entry: "main.mjs",
  name: "Example organizer and files",
  capabilities: [
    "files.download",
    "files.list",
    "files.read",
    "files.index",
    "files.export",
    "sources.write",
    "todo.read",
    "todo.write",
    "calendar.read",
    "calendar.write",
    "activity.read",
    "activity.write",
    "reminders.read",
    "reminders.write",
  ],
  network: ["https://example.com"],
  actions: {
    organize: {
      description: "Exercise files and the profile organizer with synthetic data",
      mutating: false,
      input_schema: {
        type: "object",
        required: ["title", "start_at", "end_at", "reminder_at"],
        properties: {
          title: { type: "string", minLength: 1 },
          start_at: { type: "string" },
          end_at: { type: "string" },
          reminder_at: { type: "string" },
        },
        additionalProperties: false,
      },
    },
  },
  ui: [{ id: "organizer", type: "card", title: "Organizer" }],
} satisfies PluginManifest;

function isPluginHostError(error: unknown): error is Error & { code: string } {
  return (
    error instanceof Error &&
    typeof (error as { code?: unknown }).code === "string"
  );
}

async function expectExportUnavailable(
  ctx: PluginContext,
  assetId: string,
): Promise<void> {
  try {
    await ctx.files.export({ asset_id: assetId, account_id: ACCOUNT_ID });
  } catch (error) {
    if (!isPluginHostError(error) || error.code !== "CapabilityUnavailable") {
      throw error;
    }
    return;
  }
  throw new Error("files.export unexpectedly succeeded without a platform picker");
}

export const organize: PluginAction<OrganizeInput, OrganizeResult> = async (
  ctx,
  input,
) => {
  const asset = await ctx.files.download({
    url: FIXTURE_URL,
    account_id: ACCOUNT_ID,
    source_id: DOCUMENT_SOURCE,
    name: "fixture.txt",
    mime_type: "text/plain",
    max_bytes: 1_024,
  });
  await ctx.files.read({ asset_id: asset.asset_id, length: 16 });
  await ctx.files.list({ account_id: ACCOUNT_ID, limit: 10 });
  await ctx.files.index({ asset_id: asset.asset_id });
  await expectExportUnavailable(ctx, asset.asset_id);

  const todo = await ctx.todo.create({
    title: input.title,
    due_at: input.reminder_at,
    timezone: TIMEZONE,
  });
  const event = await ctx.calendar.create({
    title: input.title,
    start_at: input.start_at,
    end_at: input.end_at,
    timezone: TIMEZONE,
  });
  const reminder = await ctx.reminders.schedule({
    item_id: todo.id,
    at: input.reminder_at,
    timezone: TIMEZONE,
  });

  await ctx.todo.list({ completed: false, limit: 10 });
  await ctx.calendar.list({ from: input.start_at, to: input.end_at });
  await ctx.reminders.list({ item_id: todo.id, limit: 10 });
  const conflicts = await ctx.calendar.conflicts({
    from: input.start_at,
    to: input.end_at,
  });

  const synced = await ctx.activity.sync({
    source_id: ACTIVITY_SOURCE,
    account_id: ACCOUNT_ID,
    items: [
      {
        external_id: "synthetic-notice-1",
        title: input.title,
        kind: "notice",
        occurred_at: input.start_at,
      },
    ],
    complete: true,
  });
  const inbox = await ctx.activity.list({
    source_id: ACTIVITY_SOURCE,
    unread: true,
    limit: 10,
  });
  await ctx.activity.notifications({ limit: 10 });
  const first = inbox.items[0];
  if (first !== undefined) {
    await ctx.activity.read({ id: first.id });
  }
  await ctx.reminders.due({ now: input.reminder_at, limit: 10 });
  await ctx.reminders.cancel({ id: reminder.id });

  return {
    asset_id: asset.asset_id,
    todo_id: todo.id,
    event_id: event.id,
    reminder_id: reminder.id,
    activity_total: synced.inserted + inbox.total,
    conflict_count: conflicts.conflicts.length,
  };
};
