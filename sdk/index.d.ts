/**
 * dansheng-core plugin manifest v1 and mediated ctx declarations.
 *
 * This package contains declarations only. Plugin code is plain ES module
 * source executed by the core QuickJS runner; there is no Node.js or browser
 * runtime in the SDK or in released core artifacts.
 */

/** JSON 标量；number 必须有限。 */
export type JsonPrimitive = string | number | boolean | null;

/** 可安全交给 JSON.parse/JSON.stringify 的值。 */
export type JsonValue = JsonPrimitive | JsonObject | JsonValue[];

/** JSON 对象。 */
export interface JsonObject {
  [key: string]: JsonValue;
}

/** manifest 的 input_schema 与 core 接受的对象或布尔 JSON Schema 一致。 */
export type JsonSchema = boolean | JsonObject;

/** core 和 Android page port 当前已知的能力名。 */
export type BrowserCapability =
  | "browser.open"
  | "browser.navigate"
  | "browser.login"
  | "browser.close"
  | "browser.request"
  | "browser.evaluate";

/** 托管文件能力名。 */
export type FilesCapability =
  | "files.download"
  | "files.list"
  | "files.read"
  | "files.delete"
  | "files.index"
  | "files.export";

/** 本地 organizer 能力名。 */
export type OrganizerCapability =
  | "todo.read"
  | "todo.write"
  | "calendar.read"
  | "calendar.write"
  | "activity.read"
  | "activity.write"
  | "reminders.read"
  | "reminders.write";

/** 已知 capability 名；manifest 在运行时仍接受字符串。 */
export type KnownCapability =
  | "http.request"
  | "auth.status"
  | "auth.requireLogin"
  | "storage.read"
  | "storage.write"
  | "sources.read"
  | "sources.write"
  | "jobs.schedule"
  | "jobs.cancel"
  | "jobs.status"
  | "ui.publish"
  | "notifications.show"
  | "capabilities.has"
  | BrowserCapability
  | FilesCapability
  | OrganizerCapability;

/** core 当前接受的声明式 UI 组件类型。 */
export type UiComponentType =
  | "card"
  | "list"
  | "detail"
  | "form"
  | "action"
  | "settings";

/**
 * ui.publish 的组件载荷。core 校验 type；其余字段由平台 UI 解释。
 * 组件必须保持 JSON 可序列化。
 */
export type UiComponent = JsonObject & {
  type: UiComponentType;
};

/**
 * 声明式表单字段类型。
 */
export type UiFieldType =
  | "text"
  | "date"
  | "datetime"
  | "select"
  | "multiselect"
  | "identifier";

/**
 * 字段选项动态数据源。
 * 目标动作接收 `{ account_id, ...dependsOnValues }` 并返回 `UiOptionItem[]`。
 */
export interface UiFieldSource {
  action: string;
  dependsOn?: string[];
}

/**
 * 声明式表单字段声明。
 */
export interface UiFieldDeclaration {
  id: string;
  label: string;
  type: UiFieldType;
  source?: UiFieldSource;
  clearOnChange?: string[];
}

/**
 * 声明式表单按钮动作声明。
 */
export interface UiButtonDeclaration {
  label: string;
  action: string;
  prepare?: string;
  fields?: string[];
  confirm?: boolean;
}

/**
 * 通用声明式 UI v1 表单声明（manifest.ui 条目）。
 */
export interface UiFormDeclaration {
  id: string;
  type: "form" | UiComponentType;
  title: string;
  ui_version?: 1;
  time_zone?: string;
  fields: UiFieldDeclaration[];
  buttons: UiButtonDeclaration[];
}

/**
 * 通用动态选项返回值条目。
 */
export interface UiOptionItem<T = JsonValue> {
  label: string;
  value: T;
}

/**
 * manifest.ui 中的声明对象。core 只要求它是 JSON 对象；约定字段为
 * id/type/title，但声明本身不渲染 UI，也不会自动创建组件。
 * 首版支持通用表单描述 `UiFormDeclaration`（ui_version: 1）。
 */
export type UiDeclaration = UiFormDeclaration | JsonObject;

/** manifest 中的一个动作声明。 */
export interface PluginActionDeclaration {
  description: string;
  mutating: boolean;
  input_schema?: JsonSchema;
}

/** catalog/manifest 的发布者身份；不是授权或信任锚。 */
export interface PluginPublisher {
  id: string;
  key_id: string;
}

/** 包内容摘要；与 publisher 成对声明，不含 manifest.json 的循环摘要。 */
export interface PackageIntegrity {
  sha256: string;
}

/**
 * 私有存储单个重命名键操作。
 * 键名长度限制 1..256 字节，且必须不包含任何 Unicode 控制字符（char::is_control）。
 */
export interface PluginStorageRenameKeyOperation {
  op: "rename_key";
  from: string;
  to: string;
}

/**
 * 私有存储单个删除键操作。
 * 键名长度限制 1..256 字节，且必须不包含任何 Unicode 控制字符（char::is_control）。
 */
export interface PluginStorageDeleteKeyOperation {
  op: "delete_key";
  key: string;
}

/**
 * 私有存储设置缺省值操作（仅在目标键缺失时写入）。
 * 键名长度限制 1..256 字节，且必须不包含任何 Unicode 控制字符（char::is_control）。
 * 注意：全新空安装或新增授权范围不会补跑历史默认值操作，插件动作应在正常代码中初始化必要缺省值。
 */
export interface PluginStorageSetDefaultOperation {
  op: "set_default";
  key: string;
  value: JsonValue;
}

/**
 * 私有存储 JSON 对象局部修补操作。
 * 键名与字段名均限制 1..256 字节，且不包含任何 Unicode 控制字符（char::is_control）。
 * 字段修改操作总数限制在 1..128 之间，修改后的 JSON 对象序列化不得超过 1 MiB。
 */
export interface PluginStoragePatchObjectOperation {
  op: "patch_object";
  key: string;
  rename_fields?: Record<string, string>;
  defaults?: Record<string, JsonValue>;
  remove_fields?: string[];
}

/**
 * 私有存储声明式迁移原子操作，与 core 的 PluginStorageOperation serde 标记完全一致。
 */
export type PluginStorageOperation =
  | PluginStorageRenameKeyOperation
  | PluginStorageDeleteKeyOperation
  | PluginStorageSetDefaultOperation
  | PluginStoragePatchObjectOperation;

/**
 * 私有存储单个版本升级步骤（严格要求 from + 1 === to）。
 */
export interface PluginStorageMigration {
  from: number;
  to: number;
  operations: PluginStorageOperation[];
}

/**
 * 插件私有 ctx.storage 的声明式版本与迁移定义。
 * 仅用于插件隔离的私有 KV 存储，不适用于 sources、organizer、assets 或 vault。
 */
export interface PluginStorageSchema {
  version: number;
  migrations?: PluginStorageMigration[];
}

/**
 * Plugin manifest v1，字段与 core 的 PluginManifest 一致。
 *
 * capabilities 是声明，不是授权。network 必须是唯一的规范 HTTP(S) origin，
 * 不含路径、查询、片段或内嵌凭据。actions 的键必须对应入口模块的具名导出。
 * publisher 与 integrity 必须同时出现或同时省略；catalog 信任锚、过期时间和
 * 序列号由 host 的受信配置决定，不在插件请求中提供。
 */
export interface PluginManifest {
  id: string;
  version: string;
  api_version: 1;
  entry: string;
  name: string;
  capabilities: string[];
  network: string[];
  actions: Record<string, PluginActionDeclaration>;
  ui?: UiDeclaration[];
  publisher?: PluginPublisher;
  integrity?: PackageIntegrity;
  storage_schema?: PluginStorageSchema;
}

/** core 支持的原生 HTTP 方法。 */
export type HttpMethod =
  | "GET"
  | "HEAD"
  | "POST"
  | "PUT"
  | "PATCH"
  | "DELETE"
  | "OPTIONS";

/** ctx.http.request 参数。凭据必须由 host session 注入，插件不得提交。 */
export interface HttpRequest {
  url: string;
  method?: HttpMethod;
  headers?: Record<string, string>;
  body?: JsonValue;
  account_id?: string;
  timeout_ms?: number;
  follow_redirects?: boolean;
}

/**
 * ctx.http.request 结果。body 当前始终是文本；即使服务返回 JSON，也需要
 * 插件自行 JSON.parse 并校验。
 */
export interface HttpResponse {
  status: number;
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** auth.status 参数；origin 可帮助平台定位账号会话，但 core 只读取 account_id。 */
export interface AuthStatusParams {
  account_id: string;
  origin?: string;
}

/** auth.status / auth.requireLogin 的已认证结果。 */
export interface AuthStatus {
  account_id: string;
  authenticated: boolean;
  /** 只表示本地存在可用凭据，不代表已向学校验证身份。 */
  verification?: "local_credentials_only";
}

/** auth.requireLogin 参数。未登录时调用会以 AuthenticationRequired 拒绝。 */
export type AuthRequireLoginParams = AuthStatusParams;

/** ctx.storage.get 参数。 */
export interface StorageGetParams {
  key: string;
}

/** ctx.storage.set 参数。 */
export interface StorageSetParams {
  key: string;
  value: JsonValue;
}

/** ctx.storage.delete 参数。 */
export interface StorageDeleteParams {
  key: string;
}

/**
 * 单个私有存储快照元数据条目。
 * 由 host 在快照创建或恢复时持久化于 core:plugin-storage-snapshots。
 */
export interface PluginStorageSnapshotRecord {
  snapshot_id: string;
  plugin_id: string;
  version: number;
  created_at: string;
  scopes: number;
  entries: number;
  bytes: number;
  sha256: string;
}

/**
 * Trusted host/operator RPC: plugins.storage.snapshots 参数（owner-only 只读查询，不获取写生命周期锁，非 ctx API）。
 */
export interface PluginStorageSnapshotsParams {
  plugin_id: string;
}

/**
 * Trusted host/operator RPC: plugins.storage.snapshots 结果。
 */
export interface PluginStorageSnapshotsResult {
  version: number;
  snapshots: PluginStorageSnapshotRecord[];
}

/**
 * Trusted host/operator RPC: plugins.storage.restore 参数（owner-only，需持有生命周期写锁，非 ctx API）。
 * 恢复前插件必须处于禁用状态，且快照版本必须与当前 manifest 声明的 storage_schema 版本一致。
 */
export interface PluginStorageRestoreParams {
  plugin_id: string;
  snapshot_id: string;
}

/**
 * Trusted host/operator RPC: plugins.storage.restore 结果。
 * 恢复后插件保持 disabled 状态；同时返回恢复前自动创建的反向恢复快照 recovery_snapshot_id。
 */
export interface PluginStorageRestoreResult {
  plugin_id: string;
  version: number;
  restored: true;
  enabled: false;
  recovery_snapshot_id: string;
}

/**
 * Trusted host/operator RPC: plugins.storage.discard 参数（owner-only，需持有生命周期写锁，非 ctx API）。
 */
export interface PluginStorageDiscardParams {
  plugin_id: string;
  snapshot_id: string;
}

/**
 * Trusted host/operator RPC: plugins.storage.discard 结果。
 */
export interface PluginStorageDiscardResult {
  discarded: true;
  snapshot_id: string;
}

/**
 * plugins.enable 成功时返回的私有存储迁移执行收据。
 * 若未发生版本迁移或为全新初始安装，snapshot_id 为 null。
 */
export interface PluginStorageTransitionReceipt {
  from: number;
  version: number;
  snapshot_id: string | null;
}

/**
 * ctx.sources.upsert 参数。
 *
 * source_id 必须以 `<当前 manifest id>.` 开头；host 会拒绝越界命名空间。
 */
export interface SourceUpsertParams {
  source_id: string;
  external_id: string;
  kind: string;
  data: JsonValue;
  account_id?: string;
}

/** ctx.sources.upsert 的确认结果。 */
export interface SourceUpsertResult {
  source_id: string;
  external_id: string;
  updated_at: string;
}

/** ctx.sources.query 过滤条件；limit 由 host 限制在 1..500。 */
export interface SourceQueryParams {
  source_id?: string;
  kind?: string;
  account_id?: string;
  external_id?: string;
  record_owner?: string;
  summary?: boolean;
  limit?: number;
}

/** ctx.sources.query 返回的一条本地记录。 */
export interface SourceRecord<T extends JsonValue = JsonValue> {
  owner: string;
  account_id: string;
  source_id: string;
  external_id: string;
  kind: string;
  data: T;
  updated_at: string;
}

export type SourceSummary = { title: string; snippet: string; asset_id: string | null };

/** 托管文件状态；downloading/promoting/deleting 是短期内部状态。 */
export type ManagedAssetState =
  | "downloading"
  | "partial"
  | "promoting"
  | "ready"
  | "deleting";

/** files.download 结果及 files.list 条目的元数据。 */
export interface ManagedAsset {
  asset_id: string;
  owner: string;
  account_id: string;
  source_id: string;
  name: string;
  mime_type: string;
  state: ManagedAssetState;
  size: number;
  max_bytes: number;
  sha256: string | null;
  created_at: string;
  updated_at: string;
  indexed_at: string | null;
  error_code: string | null;
  progress: {
    bytes: number;
    limit: number;
  };
  resumable: boolean;
}

/** files.download 参数；不接受文件系统路径，method 只能是 GET。 */
export interface FilesDownloadParams {
  url: string;
  method?: "GET";
  headers?: Record<string, string>;
  account_id?: string;
  source_id?: string;
  name?: string;
  mime_type?: string;
  sha256?: string;
  max_bytes?: number;
  timeout_ms?: number;
  asset_id?: string;
  resume?: boolean;
}

/** files.list 参数。 */
export interface FilesListParams {
  account_id?: string;
  source_id?: string;
  state?: ManagedAssetState;
  limit?: number;
  offset?: number;
}

/** files.list 结果。 */
export interface FilesListResult {
  items: ManagedAsset[];
  offset: number;
  limit: number;
}

/** files.read 参数；length 默认 64 KiB，最大 1 MiB。 */
export interface FilesReadParams {
  asset_id: string;
  account_id?: string;
  offset?: number;
  length?: number;
}

/** files.read 的 base64 分片结果。 */
export interface FilesReadResult {
  asset_id: string;
  encoding: "base64";
  data: string;
  offset: number;
  length: number;
  next_offset: number;
  eof: boolean;
}

/** files.delete / files.index / files.export 的公共定位参数。 */
export interface FileAssetParams {
  asset_id: string;
  account_id?: string;
}

/** files.delete 结果。 */
export interface FilesDeleteResult {
  asset_id: string;
  deleted: true;
}

/** files.index 结果。 */
export interface FilesIndexResult {
  asset_id: string;
  owner: string;
  account_id: string;
  source_id: string;
  external_id: string;
  kind: "document";
  text_bytes: number;
  indexed_at: string;
}

/** files.export 参数；缺少可信平台文件选择器时拒绝 CapabilityUnavailable。 */
export type FilesExportParams = FileAssetParams;
export interface FilesExportResult { asset_id: string; exported: boolean; }

/** 托管文件入口。 */
export interface FilesApi {
  download(params: FilesDownloadParams): Promise<ManagedAsset>;
  list(params?: FilesListParams): Promise<FilesListResult>;
  read(params: FilesReadParams): Promise<FilesReadResult>;
  delete(params: FileAssetParams): Promise<FilesDeleteResult>;
  index(params: FileAssetParams): Promise<FilesIndexResult>;
  export(params: FilesExportParams): Promise<FilesExportResult>;
}

/** organizer 条目种类。 */
export type OrganizerItemKind = "todo" | "event";

/** organizer 条目的来源：本地个人条目或 canonical source 投影。 */
export type OrganizerItemOrigin = "personal" | "source";

/** 创建 source link 时提供的 canonical source 引用。 */
export interface OrganizerSourceRef {
  account_id?: string;
  source_id: string;
  external_id: string;
  record_owner?: string;
}

/** organizer 条目返回的 canonical source 引用。 */
export interface OrganizerItemSource {
  account_id: string;
  source_id: string;
  external_id: string;
  record_owner?: string;
}

/** TODO/event 的统一视图。不适用的字段为 null 或空字符串。 */
export interface OrganizerItem {
  id: string;
  kind: OrganizerItemKind;
  origin: OrganizerItemOrigin;
  title: string;
  notes: string;
  location: string;
  timezone: string;
  due_at: string | null;
  start_at: string | null;
  end_at: string | null;
  completed_at: string | null;
  source: OrganizerItemSource | null;
  created_at: string;
  updated_at: string;
}

/** TODO/calendar 列表结果。 */
export interface OrganizerListResult {
  items: OrganizerItem[];
  total: number;
}

/** todo.create 参数。 */
export interface TodoCreateParams {
  title: string;
  notes?: string;
  due_at?: string | null;
  timezone?: string;
}

/** todo.update 允许修改的字段；due_at 可用 null 清除。 */
export interface TodoUpdateChanges {
  title?: string;
  notes?: string;
  due_at?: string | null;
  timezone?: string;
}

/** todo.update 参数。 */
export interface TodoUpdateParams {
  id: string;
  changes: TodoUpdateChanges;
}

/** todo.complete 参数；completed 缺省为 true，false 表示重新打开。 */
export interface TodoCompleteParams {
  id: string;
  completed?: boolean;
}

/** todo.get / todo.delete 参数。 */
export interface TodoIdParams {
  id: string;
}

/** todo.list 参数。 */
export interface TodoListParams {
  completed?: boolean;
  limit?: number;
  offset?: number;
  from?: string;
  to?: string;
  timezone?: string;
}

/** todo.link 参数。 */
export interface TodoLinkParams {
  source: OrganizerSourceRef;
}

/** todo.delete 结果。 */
export interface TodoDeleteResult {
  id: string;
  deleted: true;
}

/** todo 入口。 */
export interface TodoApi {
  list(params?: TodoListParams): Promise<OrganizerListResult>;
  get(params: TodoIdParams): Promise<OrganizerItem>;
  create(params: TodoCreateParams): Promise<OrganizerItem>;
  update(params: TodoUpdateParams): Promise<OrganizerItem>;
  complete(params: TodoCompleteParams): Promise<OrganizerItem>;
  delete(params: TodoIdParams): Promise<TodoDeleteResult>;
  link(params: TodoLinkParams): Promise<OrganizerItem>;
}

/** calendar.create 参数。 */
export interface CalendarCreateParams {
  title: string;
  start_at: string;
  end_at: string;
  notes?: string;
  location?: string;
  timezone?: string;
}

/** calendar.update 允许修改的字段。 */
export interface CalendarUpdateChanges {
  title?: string;
  notes?: string;
  location?: string;
  timezone?: string;
  start_at?: string;
  end_at?: string;
}

/** calendar.update 参数。 */
export interface CalendarUpdateParams {
  id: string;
  changes: CalendarUpdateChanges;
}

/** calendar.get / calendar.delete 参数。 */
export interface CalendarIdParams {
  id: string;
}

/** calendar.list 参数。 */
export interface CalendarListParams {
  limit?: number;
  offset?: number;
  from?: string;
  to?: string;
  timezone?: string;
}

/** calendar.conflicts 的候选事件。 */
export interface CalendarConflictCandidate {
  start_at: string;
  end_at: string;
  exclude_id?: string;
}

/** calendar.conflicts 参数。 */
export interface CalendarConflictParams {
  from?: string;
  to?: string;
  timezone?: string;
  candidate?: CalendarConflictCandidate;
}

/** 两个已存在事件的重叠。 */
export interface CalendarConflictPair {
  left_id: string;
  right_id: string;
  start_at: string;
  end_at: string;
}

/** 候选事件与一个已存在事件的重叠。 */
export interface CalendarCandidateConflict {
  id: string;
  start_at: string;
  end_at: string;
}

/** 无 candidate 的冲突结果。 */
export interface CalendarConflictResult {
  conflicts: CalendarConflictPair[];
}

/** 有 candidate 的冲突结果。 */
export interface CalendarCandidateConflictResult {
  conflicts: CalendarCandidateConflict[];
}

/** calendar.export_ics 参数；不支持分页。 */
export interface CalendarExportIcsParams {
  from?: string;
  to?: string;
  timezone?: string;
  completed?: boolean;
  include_todos?: boolean;
}

/** calendar.export_ics 结果。 */
export interface CalendarExportIcsResult {
  content_type: "text/calendar; charset=utf-8";
  ics: string;
}

/** calendar.link 参数。 */
export interface CalendarLinkParams {
  source: OrganizerSourceRef;
}

/** calendar.delete 结果。 */
export interface CalendarDeleteResult {
  id: string;
  deleted: true;
}

/** calendar 入口。 */
export interface CalendarApi {
  list(params?: CalendarListParams): Promise<OrganizerListResult>;
  get(params: CalendarIdParams): Promise<OrganizerItem>;
  conflicts(
    params: CalendarConflictParams & {
      candidate: CalendarConflictCandidate;
    },
  ): Promise<CalendarCandidateConflictResult>;
  conflicts(params?: CalendarConflictParams): Promise<CalendarConflictResult>;
  export_ics(
    params?: CalendarExportIcsParams,
  ): Promise<CalendarExportIcsResult>;
  create(params: CalendarCreateParams): Promise<OrganizerItem>;
  update(params: CalendarUpdateParams): Promise<OrganizerItem>;
  delete(params: CalendarIdParams): Promise<CalendarDeleteResult>;
  link(params: CalendarLinkParams): Promise<OrganizerItem>;
}

/** activity.sync 的单条摘要；不接受任意 payload 或凭据。 */
export interface ActivitySyncItem {
  external_id: string;
  title: string;
  kind: string;
  occurred_at: string;
}

/** activity.sync 参数。 */
export interface ActivitySyncParams {
  source_id: string;
  account_id?: string;
  items: ActivitySyncItem[];
  complete?: boolean;
}

/** activity.sync 结果。 */
export interface ActivitySyncResult {
  inserted: number;
  notifications: number;
  initial_sync: boolean;
  initialized: boolean;
}

/** 本地 activity 的 notification 状态。 */
export type ActivityNotificationState = "suppressed" | "pending" | "claimed";

/** activity 收件箱条目。 */
export interface ActivityItem {
  id: string;
  account_id: string;
  source_id: string;
  external_id: string;
  title: string;
  kind: string;
  occurred_at: string;
  notification: ActivityNotificationState;
  read_at: string | null;
  archived_at: string | null;
  item_id: string | null;
}

/** activity.list 参数。 */
export interface ActivityListParams {
  account_id?: string;
  source_id?: string;
  unread?: boolean;
  archived?: boolean;
  limit?: number;
  offset?: number;
}

/** activity.list 结果。 */
export interface ActivityListResult {
  items: ActivityItem[];
  total: number;
}

/** activity.read / activity.archive 参数；value 缺省为 true。 */
export interface ActivityStateParams {
  id: string;
  value?: boolean;
}

/** activity.notifications 参数。 */
export interface ActivityNotificationsParams {
  limit?: number;
}

/** activity.notifications 结果。 */
export interface ActivityNotificationsResult {
  items: ActivityItem[];
}

/** activity 收件箱入口。 */
export interface ActivityApi {
  list(params?: ActivityListParams): Promise<ActivityListResult>;
  sync(params: ActivitySyncParams): Promise<ActivitySyncResult>;
  read(params: ActivityStateParams): Promise<ActivityItem>;
  archive(params: ActivityStateParams): Promise<ActivityItem>;
  notifications(
    params?: ActivityNotificationsParams,
  ): Promise<ActivityNotificationsResult>;
}

/** reminder 状态。 */
export type ReminderState = "pending" | "fired" | "cancelled";

/** 本地 reminder。 */
export interface Reminder {
  id: string;
  item_id: string;
  at: string;
  timezone: string;
  state: ReminderState;
  created_at: string;
  fired_at: string | null;
}

/** reminders.schedule 参数。 */
export interface ReminderScheduleParams {
  item_id: string;
  at: string;
  timezone?: string;
}

/** reminders.list 参数。 */
export interface ReminderListParams {
  item_id?: string;
  limit?: number;
  offset?: number;
}

/** reminders.list 结果。 */
export interface ReminderListResult {
  items: Reminder[];
}

/** reminders.cancel 参数。 */
export interface ReminderCancelParams {
  id: string;
}

/** reminders.cancel 结果。 */
export interface ReminderCancelResult {
  id: string;
}

/** reminders.due 参数。 */
export interface ReminderDueParams {
  now?: string;
  limit?: number;
}

/** 一条已认领 reminder 及其单一 activity。 */
export interface ReminderClaim {
  reminder: Reminder;
  activity_id: string;
}

/** reminders.due 结果。 */
export interface ReminderDueResult {
  items: ReminderClaim[];
}

/** reminders 入口。 */
export interface RemindersApi {
  list(params?: ReminderListParams): Promise<ReminderListResult>;
  schedule(params: ReminderScheduleParams): Promise<Reminder>;
  cancel(params: ReminderCancelParams): Promise<ReminderCancelResult>;
  due(params?: ReminderDueParams): Promise<ReminderDueResult>;
}

/** ctx.jobs.schedule 参数。时间使用 RFC 3339 字符串。 */
export interface JobScheduleParams {
  plugin_id: string;
  action: string;
  input?: JsonValue;
  account_id?: string;
  run_at?: string;
  prepare_at?: string;
  deadline_at?: string;
  deadline_window_seconds?: number;
  wake_precision?: "exact" | "inexact";
  interval_seconds?: number;
  dedup_key?: string;
}

/** Trusted host/MCP wire params for jobs.schedule; NOT accepted by ctx.jobs.schedule.
 * The live CoreService directory and current grants decide whether method is a read.
 */
export interface NativeServiceJobScheduleParams {
  kind: "service";
  method: string;
  input: JsonObject & { account_id: string };
  run_at?: string;
  prepare_at?: string;
  deadline_at?: string;
  deadline_window_seconds?: number;
  wake_precision?: "exact" | "inexact";
  interval_seconds?: number;
  dedup_key?: string;
}

/** Result of a trusted native service schedule request. */
export interface NativeServiceJobScheduleResult extends JobScheduleResult {
  kind: "service";
}

/** ctx.jobs.schedule 结果。 */
export interface JobScheduleResult {
  job_id: string;
  run_at: string;
  state: JobState;
  wake_up:
    | { state: "host_must_remain_running" }
    | { state: "not_armed"; error: { code: string; message: string } }
    | { job_id: string; scheduled: true; precision: "exact" | "inexact"; exact: boolean; wake_at: string; run_at: string; deadline_at: string; capabilities: JsonObject };
}

/** ctx.jobs.cancel 参数。 */
export interface JobCancelParams {
  job_id: string;
  account_id?: string;
}

/** ctx.jobs.cancel 结果；已提交的远端动作不会被撤销。 */
export interface JobCancelResult {
  job_id: string;
  state: JobState;
  note: string;
}

/** ctx.jobs.status 按 job_id 查询时的参数。 */
export interface JobStatusByIdParams {
  job_id: string;
  account_id?: string;
}

/** ctx.jobs.status 列出任务时的参数。 */
export interface JobStatusFilterParams {
  account_id?: string;
}

/** core 当前持久化的 job 状态。 */
export type JobState =
  | "scheduled"
  | "running"
  | "succeeded"
  | "failed"
  | "cancelled"
  | "waiting_for_auth"
  | "waiting_for_approval"
  | "needs_reconciliation"
  | "expired";

/** ctx.jobs.status 返回的 job 记录。 */
export interface JobRecord {
  id: string;
  owner: {
    id: string;
    kind: string;
  };
  data: JsonObject;
  state: JobState;
  run_at: string;
  result: JsonValue | null;
  updated_at: string;
}

/** ctx.ui.publish 参数。 */
export interface UiPublishParams {
  id: string;
  component: UiComponent;
}

/** ctx.ui.publish 结果。 */
export interface UiPublishResult {
  sequence: number;
}

/** ctx.capabilities.has 参数。 */
export interface CapabilitiesHasParams {
  name: string;
}

/** host 抛出的受控错误；message 不包含服务正文。 */
export interface PluginHostError extends Error {
  code: string;
}

/**
 * 平台页面请求方法。Android 当前只接受 GET/POST；其他平台可能支持更多。
 */
export type BrowserMethod = "GET" | "POST";

/** 页面请求传输方式。 */
export type BrowserTransport = "fetch" | "xhr";

/**
 * browser.request 参数。session_handle 是不透明 host 句柄，不是凭据；
 * Android 当前还要求 deadline_epoch_ms，其他平台可能按账号管理会话。
 */
export interface BrowserRequestParams {
  account_id: string;
  url: string;
  method?: BrowserMethod;
  session_handle?: string;
  transport?: BrowserTransport;
  headers?: Record<string, string>;
  body?: string;
  form_fields?: Record<string, string>;
  deadline_epoch_ms?: number;
  mutation_key?: string;
}

/** 页面响应头，可为对象或 [name, value] 数组；平台可以省略。 */
export type BrowserResponseHeaders =
  | Record<string, string>
  | Array<[string, string]>;

/**
 * browser.request 结果。body 是文本；Android 当前不导出响应头，其他平台
 * 可能提供 headers/final_url。
 */
export interface BrowserResponse {
  status: number;
  body: string;
  url?: string;
  final_url?: string;
  headers?: BrowserResponseHeaders;
}

/** browser.open / browser.login 参数。登录必须在可见平台 UI 完成。 */
export interface BrowserLoginParams {
  account_id: string;
  url: string;
}

/** browser.evaluate 仅允许具名操作，不允许插件提供任意 JavaScript。 */
export type BrowserEvaluateParams =
  | {
      operation: "session.status";
      /** 无有效页面会话时由宿主返回 AuthenticationRequired；不打开登录 UI。 */
      require_authenticated?: boolean;
      account_id: string;
      url?: string;
    }
  | {
      operation: "session.requireLogin";
      account_id: string;
      url: string;
    };

/** 页面会话状态；session_handle 由 host 签发。 */
export interface BrowserSession {
  account_id: string;
  authenticated: boolean;
  session_handle?: string;
}

/** browser.navigate 参数。 */
export interface BrowserNavigateParams {
  account_id: string;
  session_handle: string;
  url: string;
}

/** browser.navigate 结果。 */
export interface BrowserNavigateResult {
  navigating: true;
}

/** browser.close 参数。 */
export interface BrowserCloseParams {
  account_id: string;
  session_handle: string;
}

/** browser.close 结果。 */
export interface BrowserCloseResult {
  closed: true;
}

/** 原生 HTTP 访问入口。 */
export interface HttpApi {
  request(params: HttpRequest): Promise<HttpResponse>;
}

/** 账号会话入口；不接收密码、cookie、token 等凭据。 */
export interface AuthApi {
  status(params: AuthStatusParams): Promise<AuthStatus>;
  requireLogin(params: AuthRequireLoginParams): Promise<AuthStatus>;
}

/** 插件私有 JSON 键值存储入口。 */
export interface StorageApi {
  get(params: StorageGetParams): Promise<JsonValue | null>;
  set(params: StorageSetParams): Promise<null>;
  delete(params: StorageDeleteParams): Promise<null>;
}

/** 本地 source 记录入口。 */
export interface SourcesApi {
  upsert(params: SourceUpsertParams): Promise<SourceUpsertResult>;
  query(params: SourceQueryParams & { summary: true }): Promise<SourceRecord<SourceSummary>[]>;
  query<T extends JsonValue = JsonValue>(
    params: SourceQueryParams,
  ): Promise<SourceRecord<T>[]>;
}

/** host 管理的持久任务入口。 */
export interface JobsApi {
  schedule(params: JobScheduleParams): Promise<JobScheduleResult>;
  cancel(params: JobCancelParams): Promise<JobCancelResult>;
  status(params: JobStatusByIdParams): Promise<JobRecord>;
  status(params?: JobStatusFilterParams): Promise<JobRecord[]>;
}

/** 声明式 UI 发布入口。 */
export interface UiApi {
  publish(params: UiPublishParams): Promise<UiPublishResult>;
}

/** 平台通知入口；payload/result 由具体平台定义，必须可 JSON 序列化。 */
export interface NotificationsApi {
  show(params: JsonValue): Promise<JsonValue>;
}

/**
 * 认证页面能力入口。
 *
 * 这些方法由当前 core ctx 固定暴露，但每个方法对应的平台端口是可选的；
 * 平台未提供或未授权时会以 CapabilityUnavailable 等错误拒绝。页面请求必须
 * 在已认证页面执行，不能用 ctx.http.request 静默替代。
 */
export interface BrowserApi {
  request(params: BrowserRequestParams): Promise<BrowserResponse>;
  evaluate(params: BrowserEvaluateParams): Promise<BrowserSession>;
  open(params: BrowserLoginParams): Promise<BrowserSession>;
  navigate(params: BrowserNavigateParams): Promise<BrowserNavigateResult>;
  login(params: BrowserLoginParams): Promise<BrowserSession>;
  close(params: BrowserCloseParams): Promise<BrowserCloseResult>;
}

/**
 * 查询当前插件授权中是否包含某个 capability。
 *
 * 这里查询的是 host grant，不是平台端口广告，也不代表某次动作已获用户批准。
 */
export interface CapabilitiesApi {
  has(params: CapabilitiesHasParams): Promise<boolean>;
}

/**
 * core 注入给每个具名动作的唯一 ctx。
 *
 * 所有方法接收一个 JSON 参数（缺省为 {}）并返回 JSON Promise。manifest 的
 * capabilities 只声明需求；host 独立校验 grant、账号、origin 和命名空间。
 */
export interface PluginContext {
  readonly http: HttpApi;
  readonly auth: AuthApi;
  readonly storage: StorageApi;
  readonly sources: SourcesApi;
  readonly files: FilesApi;
  readonly todo: TodoApi;
  readonly calendar: CalendarApi;
  readonly activity: ActivityApi;
  readonly reminders: RemindersApi;
  readonly jobs: JobsApi;
  readonly ui: UiApi;
  readonly notifications: NotificationsApi;
  readonly browser: BrowserApi;
  readonly capabilities: CapabilitiesApi;
}

/**
 * 插件动作：入口模块的具名导出 `(ctx, input)`。
 *
 * core 同时接受同步值和 Promise；最终结果必须能 JSON.stringify 且不超过
 * host 载荷配额。
 */
export type PluginAction<
  Input extends JsonValue = JsonValue,
  Output extends JsonValue = JsonValue,
> = (ctx: PluginContext, input: Input) => Output | Promise<Output>;
