import type {
  JsonObject,
  JsonValue,
  PluginAction,
  PluginContext,
  PluginHostError,
  PluginManifest,
} from "../index.js";

const PLUGIN_ID = "example.courses";
const SOURCE_ID = `${PLUGIN_ID}.courses`;
const LOGIN_URL = "https://example.com/login";
const COURSES_URL = "https://example.com/api/courses";

type SyncInput = JsonObject & {
  account_id: string;
};

type SyncResult = JsonObject & {
  status: "synced" | "auth_required";
  count: number;
};

export const manifest = {
  id: PLUGIN_ID,
  version: "0.1.0",
  api_version: 1,
  entry: "main.mjs",
  name: "Example courses",
  capabilities: [
    "auth.status",
    "auth.requireLogin",
    "browser.login",
    "browser.request",
    "browser.evaluate",
    "storage.read",
    "storage.write",
    "sources.write",
    "ui.publish",
  ],
  network: ["https://example.com"],
  actions: {
    sync: {
      description: "Read courses through the authenticated host page",
      mutating: false,
      input_schema: {
        type: "object",
        required: ["account_id"],
        properties: {
          account_id: { type: "string", minLength: 1 },
        },
        additionalProperties: false,
      },
    },
  },
  ui: [{ id: "courses", type: "list", title: "Example courses" }],
} satisfies PluginManifest;

function isPluginHostError(error: unknown): error is PluginHostError {
  return (
    error instanceof Error &&
    typeof (error as { code?: unknown }).code === "string"
  );
}

async function requireBrowserSession(
  ctx: PluginContext,
  accountId: string,
): Promise<Awaited<ReturnType<PluginContext["browser"]["login"]>>> {
  try {
    return await ctx.browser.login({
      account_id: accountId,
      url: LOGIN_URL,
    });
  } catch (error) {
    if (!isPluginHostError(error) || error.code !== "CapabilityUnavailable") {
      throw error;
    }

    return ctx.browser.evaluate({
      operation: "session.requireLogin",
      account_id: accountId,
      url: LOGIN_URL,
    });
  }
}

export const sync: PluginAction<SyncInput, SyncResult> = async (
  ctx,
  input,
) => {
  const auth = await ctx.auth.status({ account_id: input.account_id });
  const session = auth.authenticated
    ? await ctx.browser.evaluate({
        operation: "session.status",
        account_id: input.account_id,
      })
    : await requireBrowserSession(ctx, input.account_id);
  const request = {
    account_id: input.account_id,
    url: COURSES_URL,
    method: "GET",
    transport: "fetch",
    headers: { Accept: "application/json" },
    deadline_epoch_ms: Date.now() + 8_000,
    ...(session.session_handle === undefined
      ? {}
      : { session_handle: session.session_handle }),
  } as const;
  const response = await ctx.browser.request(request);

  if (response.status !== 200) {
    throw new Error(`Course request failed with ${response.status}`);
  }

  let count = 0;
  try {
    const parsed: JsonValue = JSON.parse(response.body);
    if (Array.isArray(parsed)) count = parsed.length;
  } catch {
    throw new Error("Course response is not JSON text");
  }

  await ctx.storage.set({
    key: "last-sync",
    value: { at: new Date().toISOString(), count },
  });
  await ctx.sources.upsert({
    source_id: SOURCE_ID,
    account_id: input.account_id,
    external_id: "course-1",
    kind: "course",
    data: { name: "Example course" },
  });
  await ctx.ui.publish({
    id: "courses",
    component: {
      type: "list",
      title: "Example courses",
      items: [{ title: "Example course" }],
    },
  });

  return { status: "synced", count };
};
