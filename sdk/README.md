# dansheng-core TypeScript 插件 SDK

本目录只提供 `index.d.ts` 类型声明、编译示例和运行时门面审计，不包含运行时代码、
Node.js、Chromium、`fetch` 或生产依赖。插件入口仍是交给 core QuickJS 执行的普通
ES module 源码；类型包用于编辑器提示和编译期检查。

```ts
import type {
  PluginAction,
  PluginContext,
  PluginManifest,
} from "@dansheng/plugin-sdk";
```

包名 `@dansheng/plugin-sdk` 是私有 scoped 包。`sdk/package.json` 没有 `dependencies`；
TypeScript 只在 `devDependencies` 中，用于 `npm run typecheck`。

## Manifest v1

`PluginManifest` 与 core 的 Rust 类型一致：

```json
{
  "id": "official.example",
  "version": "0.1.0",
  "api_version": 1,
  "entry": "main.mjs",
  "name": "Example",
  "capabilities": ["http.request", "storage.read", "storage.write"],
  "network": ["https://example.com"],
  "actions": {
    "sync": {
      "description": "Fetch example data",
      "mutating": false
    }
  },
  "ui": [{ "id": "summary", "type": "card", "title": "Example" }]
}
```

约束：

- `api_version` 必须是 `1`；`entry` 是包内相对 `.js`/`.mjs` 源文件。
- `actions` 中每个键都必须在入口模块中有同名具名导出，签名为 `(ctx, input)`。
  同步返回和 Promise 返回都支持，但结果必须可 JSON 序列化。
- `input_schema` 只能是 JSON 对象或布尔值。`ui` 是 JSON 对象数组；声明本身不渲染，
  也不代表已经发布 UI。
- 未知字段、重复 JSON 键、非法 id、非规范 origin 等会由 core 拒绝。
- `network` 必须是唯一、规范的 HTTP(S) origin，例如 `https://example.com`，不能带
  路径、查询、片段或内嵌凭据。

### publisher 与 integrity

发布到签名 catalog 的包必须同时声明 `publisher` 和 `integrity`：

```json
{
  "publisher": { "id": "official.example", "key_id": "release-key-1" },
  "integrity": { "sha256": "REPLACE_WITH_ACTUAL_PACKAGE_SHA256" }
}
```

`PluginPublisher` 只有 `id` 和 `key_id`；`PackageIntegrity` 只有 64 位小写十六进制
`sha256`。两者必须同时出现或同时省略。`integrity.sha256` 绑定包文件内容摘要，不包含
`manifest.json` 以避免循环；catalog 另行绑定 manifest 字节。catalog 的信任锚、签名、
过期时间和单调序列号属于 host 的受信配置，不是 manifest 或 ctx 可设置/读取的字段。

## capability 与 grant

manifest 的 `capabilities` 只是声明插件需要哪些能力，不是授权。插件以
`plugin:<plugin id>` 身份运行，host 会独立检查 grant、账号、origin、source 命名空间、
过期时间和用户对变更动作的执行授权。请求参数不能伪造 principal、grant、批准标记或
可信身份。

当前 core 的 capability 映射：

| capability | ctx 方法 |
| --- | --- |
| `http.request` | `http.request` |
| `auth.status` | `auth.status` |
| `auth.requireLogin` | `auth.requireLogin` |
| `storage.read` | `storage.get` |
| `storage.write` | `storage.set`、`storage.delete` |
| `sources.read` | `sources.query` |
| `sources.write` | `sources.upsert`；`files.index` 还额外需要它 |
| `jobs.schedule` | `jobs.schedule` |
| `jobs.cancel` | `jobs.cancel` |
| `jobs.status` | `jobs.status` |
| `ui.publish` | `ui.publish` |
| `notifications.show` | `notifications.show` |
| `browser.open` | `browser.open` |
| `browser.navigate` | `browser.navigate` |
| `browser.login` | `browser.login` |
| `browser.close` | `browser.close` |
| `browser.request` | `browser.request` |
| `browser.evaluate` | `browser.evaluate` |
| `capabilities.has` | `capabilities.has`（查询当前 grant；不要求声明） |
| `files.download` | `files.download`；还额外需要 `http.request` |
| `files.list` | `files.list` |
| `files.read` | `files.read` |
| `files.delete` | `files.delete` |
| `files.index` | `files.index` |
| `files.export` | `files.export` |
| `todo.read` | `todo.list`、`todo.get` |
| `todo.write` | `todo.create`、`todo.update`、`todo.complete`、`todo.delete`、`todo.link` |
| `calendar.read` | `calendar.list`、`calendar.get`、`calendar.conflicts`、`calendar.export_ics` |
| `calendar.write` | `calendar.create`、`calendar.update`、`calendar.delete`、`calendar.link` |
| `activity.read` | `activity.list` |
| `activity.write` | `activity.sync`、`activity.read`、`activity.archive`、`activity.notifications` |
| `reminders.read` | `reminders.list` |
| `reminders.write` | `reminders.schedule`、`reminders.cancel`、`reminders.due` |

`ctx.capabilities.has({ name })` 查询当前 host grant 是否允许该 capability。它不查询
平台端口是否可用，也不代表某个 `mutating` 动作已获用户批准。`mutating: true` 只是声明；
host 仍要求用户对具体动作的显式执行授权。外部写超时或失联属于未确定结果，插件应报告
或进入 `NeedsReconciliation`，在核对前不得自动重试预约、取消、发送等远端变更。

## ctx 方法

所有 ctx 方法只接收一个 JSON 参数（可省略，等价于 `{}`），返回 JSON Promise。host
拒绝时抛出 `Error`，错误对象带有受控字符串 `code`；不要把服务响应正文当作错误消息
或日志内容。

### 基础入口

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `http.request` | `HttpRequest` | `HttpResponse` |
| `auth.status` | `AuthStatusParams` | `AuthStatus` |
| `auth.requireLogin` | `AuthStatusParams` | 已登录时 `AuthStatus`，否则拒绝 |
| `storage.get` | `{ key }` | `JsonValue \| null` |
| `storage.set` | `{ key, value }` | `null` |
| `storage.delete` | `{ key }` | `null` |
| `sources.upsert` | `SourceUpsertParams` | `SourceUpsertResult` |
| `sources.query` | `SourceQueryParams` | `SourceRecord[]` |
| `jobs.schedule` | `JobScheduleParams` | `JobScheduleResult` |
| `jobs.cancel` | `JobCancelParams` | `JobCancelResult` |
| `jobs.status` | `{ job_id }` 或 `{}` | `JobRecord` 或 `JobRecord[]` |
| `ui.publish` | `UiPublishParams` | `{ sequence }` |
| `notifications.show` | 平台定义 JSON | 平台定义 JSON |
| `capabilities.has` | `{ name }` | `boolean` |

`HttpResponse.body` 当前始终是文本，不是已解析对象；请自行 `JSON.parse` 并验证结构。
`ui.publish` 的 `component.type` 只能是 `card`、`list`、`detail`、`form`、`action` 或
`settings`。manifest 的 `ui` 只是声明，通常写成 `{ id, type, title }`，发布时仍需调用
`ctx.ui.publish({ id, component })`；core 保存组件并发布 `ui_changed` 事件，实际渲染由
平台 UI 决定，插件不能注入 HTML 或脚本。

### 声明式通用 UI 模式 (ui_version: 1)

从 manifest 的 `ui` 读取声明（静态入口），首版约定可选的 `ui_version: 1` 通用表单模式：

```json
{
  "id": "sports_plan_form",
  "type": "form",
  "title": "场地预约与定时",
  "ui_version": 1,
  "time_zone": "Asia/Shanghai",
  "fields": [
    { "id": "task_id", "label": "任务 ID", "type": "identifier" },
    { "id": "venue_id", "label": "场馆", "type": "select", "source": { "action": "venueOptions" }, "clearOnChange": ["selected_slots"] },
    { "id": "target_date", "label": "预约日期", "type": "date", "clearOnChange": ["selected_slots"] },
    { "id": "release_at", "label": "开抢时间", "type": "datetime" },
    { "id": "selected_slots", "label": "预约时段与场地", "type": "multiselect", "source": { "action": "slotOptions", "dependsOn": ["venue_id", "target_date"] } }
  ],
  "buttons": [
    { "label": "预约定时", "action": "schedule", "prepare": "prepareSchedule", "fields": ["task_id", "venue_id", "target_date", "release_at", "selected_slots"], "confirm": true }
  ]
}
```

- **字段类型 (`type`):**
  - `text`: 普通单行文本输入。
  - `date`: 日期选择（ISO `YYYY-MM-DD`）。
  - `datetime`: 日期时间选择。当表单声明 `time_zone: "Asia/Shanghai"` 时，客户端原生 Dart 返回带 `+08:00` 偏移的 ISO 字符串。
  - `select`: 单选下拉列表。
  - `multiselect`: 多选列表。
  - `identifier`: 稳定任务标识符，由宿主自动生成或绑定，用户无需手动输入。
- **动态选项数据源 (`source: { action, dependsOn }`):**
  - 目标插件动作接收 `{ account_id, ...dependsOnValues }`，返回 `[{ label: string, value: JsonValue }]`。
  - `dependsOn` 声明依赖字段名；前序字段变化时自动重新拉取。
  - `clearOnChange` 声明变更时清除的下游字段 ID 列表。
  - 表单向所有数据源与按钮动作自动传递当前上下文的 `account_id`。
- **按钮与规范化准备动作 (`prepare`):**
  - 按钮支持声明可选的 `prepare` 动作（如 `prepareSchedule`），它是插件暴露的纯 JS 动作。
  - `prepare` 负责将用户交互选项规范化为严格的业务计划（如 `SportsPlan`），返回 `{ canonical_input, summary, prepare, ...plan }`。
  - 宿主在用户确认时展示规范化摘要，用户确认后再向 Core 提交受控调用，禁止隐藏关键操作参数。


### 托管文件

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `files.download` | `FilesDownloadParams` | `ManagedAsset` |
| `files.list` | `FilesListParams` | `FilesListResult` |
| `files.read` | `FilesReadParams` | `FilesReadResult` |
| `files.delete` | `FileAssetParams` | `FilesDeleteResult` |
| `files.index` | `FileAssetParams` | `FilesIndexResult` |
| `files.export` | `FilesExportParams` | `{ asset_id, exported }`；缺少平台文件选择器时拒绝 `CapabilityUnavailable` |

`files.download` 只接受 GET 和 `url`，不接受文件系统路径、任意目标目录或调用者
principal。`account_id`、`source_id`、文件名和 MIME 都是元数据；Range、条件头和
`Accept-Encoding` 由 asset manager 控制。插件文档 source 必须以 `<plugin id>.` 开头，
默认是 `<plugin id>.documents`。`files.read` 返回 base64 文本，`length` 默认 64 KiB、
最大 1 MiB。`files.index` 把可提取的文本写入 `document` source，并额外要求
`sources.write`。`files.export` 当前没有可信平台文件选择器，因此类型为
`Promise<never>`，不能把 `files.export` 当作普通下载/保存 API。

`ManagedAsset` 元数据包含 `asset_id`、`owner`、`account_id`、`source_id`、`name`、
`mime_type`、`state`、`size`、`max_bytes`、`sha256`、时间戳、`indexed_at`、
`error_code`、`progress` 和 `resumable`。`state` 可能是 `downloading`、`partial`、
`promoting`、`ready` 或 `deleting`；失败会保留可发现的 partial 元数据，错误只记录
受控错误码，不记录正文、URL 参数或凭据。

### Organizer 权限与 profile

organizer 是本地 SQLite 服务，不发起网络请求、不调用平台通知、不接受文件路径或任意
SQL。一个 data directory 对应一个用户 profile：

- 可信 owner 与已授权的 `Client`/`Mcp` adapter 共享 profile organizer；adapter 身份
  仍由 host 绑定，不能由请求参数覆盖。
- 插件默认使用自己的私有 organizer 命名空间，不能读取其他插件或 profile 的 TODO、
  calendar、activity、reminder。
- 插件只有在 host grant 显式包含 `organizer_scope: "profile"` 时才共享 profile
  organizer；这个 grant 字段不是 manifest capability，也不能由插件请求设置。
- 即使共享 profile，所有读写仍要满足 `todo.*`、`calendar.*`、`activity.*`、
  `reminders.*` capability 以及 source/account 的实时授权。
- 请求参数没有 owner/profile 选择字段；profile 归属由 host 绑定的 principal 和 grant
  决定，不能通过 JSON 参数切换。

source link 需要 `sources.read`；链接只保存 canonical identity 和本地完成覆盖层，不复制
原始 source payload。`todo.link` 只接受 `assignment`，`calendar.link` 只接受
`timetable`。链接后 source 被删除或权限撤销时，list/export 会隐藏它，get 返回
`NotFound`；本地 unlink 仍可执行。不要假设 owner 能绕过另一个插件的私有命名空间。

### TODO 与 calendar

| 方法 | 参数 |
| --- | --- |
| `todo.create` | `TodoCreateParams` |
| `todo.update` | `TodoUpdateParams` |
| `todo.complete` | `TodoCompleteParams` |
| `todo.get`、`todo.delete` | `TodoIdParams` |
| `todo.list` | `TodoListParams` |
| `todo.link` | `TodoLinkParams` |
| `calendar.create` | `CalendarCreateParams` |
| `calendar.update` | `CalendarUpdateParams` |
| `calendar.get`、`calendar.delete` | `CalendarIdParams` |
| `calendar.list` | `CalendarListParams` |
| `calendar.conflicts` | `CalendarConflictParams` |
| `calendar.export_ics` | `CalendarExportIcsParams` |
| `calendar.link` | `CalendarLinkParams` |

创建/更新/完成/get/link 返回 `OrganizerItem`；delete 返回 `{ id, deleted: true }`；
list 返回 `{ items, total }`。`OrganizerItem` 包含 `id`、`kind`、`origin`、`title`、
`notes`、`location`、`timezone`、`due_at`、`start_at`、`end_at`、`completed_at`、
`source`、`created_at`、`updated_at`；不适用的字段为 `null` 或空字符串。

`todo.update` 的 `changes` 可包含 `title`、`notes`、`timezone`、`due_at`；
`due_at: null` 是唯一允许的清空操作。`calendar.update` 的 `changes` 可包含事件字段。
时间使用 RFC 3339 或本地 ISO 日期时间，默认时区 `Asia/Shanghai`；DST 歧义/不存在时间
必须用显式 offset 消歧。事件窗口使用半开区间，相邻事件不冲突。

`calendar.conflicts` 在没有 `candidate` 时返回 `CalendarConflictResult`（事件对）；
有候选事件时返回 `CalendarCandidateConflictResult`（候选与现有事件）。超过 5,000 对
会返回 `LimitExceeded`。`calendar.export_ics` 返回
`{ content_type: "text/calendar; charset=utf-8", ics }`，默认包含 TODO，因此还要求
`todo.read`；分页参数会被拒绝。

### activity 与 reminders

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `activity.sync` | `ActivitySyncParams` | `ActivitySyncResult` |
| `activity.list` | `ActivityListParams` | `ActivityListResult` |
| `activity.read` | `ActivityStateParams` | `ActivityItem` |
| `activity.archive` | `ActivityStateParams` | `ActivityItem` |
| `activity.notifications` | `ActivityNotificationsParams` | `ActivityNotificationsResult` |
| `reminders.schedule` | `ReminderScheduleParams` | `Reminder` |
| `reminders.list` | `ReminderListParams` | `ReminderListResult` |
| `reminders.cancel` | `ReminderCancelParams` | `ReminderCancelResult` |
| `reminders.due` | `ReminderDueParams` | `ReminderDueResult` |

`activity.sync` 只接收 `external_id`、`title`、`kind`、`occurred_at` 摘要，不接受任意
payload、URL 或凭据。初次同步的条目是 `suppressed`；分页初始导入只有最后一页设置
`complete: true`。后续新 ID 才变成 `pending`，重复 replay 不会重新通知。`activity.read`
和 `activity.archive` 的 `value: false` 只撤销本地状态，不会重新 arm 通知。
`activity.notifications` 是本地 at-most-once handoff，不保证平台已展示；host 可读取
durable inbox 补偿。

`reminders.schedule` 需要目标 item 的 `todo.read` 或 `calendar.read`；同一 item 和同一
毫秒 instant 会去重。`reminders.due` 原子认领到期 reminder，并在同一事务写入一条
`organizer.reminders` activity；它不调用平台通知。`reminders.cancel` 只取消 pending
状态，不删除去重历史。

### 浏览器端口

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `browser.request` | `BrowserRequestParams` | `BrowserResponse` |
| `browser.evaluate` | `BrowserEvaluateParams` | `BrowserSession` |
| `browser.open` | `BrowserLoginParams` | `BrowserSession` |
| `browser.navigate` | `BrowserNavigateParams` | `{ navigating: true }` |
| `browser.login` | `BrowserLoginParams` | `BrowserSession` |
| `browser.close` | `BrowserCloseParams` | `{ closed: true }` |

这些方法由当前 core ctx 暴露，但每个方法对应的平台端口是可选能力。平台未实现、未授权
或已失活时，调用会以 `CapabilityUnavailable`、`PermissionDenied`、
`AuthenticationRequired` 等错误拒绝，不会返回伪造成功。需要认证页面的请求必须在已认证
页面执行；不能因为 browser 端口不可用就静默改用 `ctx.http.request`。

`browser.evaluate` 只接受具名 `session.status` 和 `session.requireLogin` 操作，不接受
插件提供的任意 JavaScript。`session_handle` 是不透明 host 句柄，不是凭据；Android
当前还要求 `deadline_epoch_ms`，且只接受 GET/POST。页面响应 `body` 是文本，`headers`
可能不存在，不能假定平台一定导出响应头。`mutation_key` 只是 host 去重声明，不是用户
批准令牌。

平台缺少较新的 `browser.login` 时，可捕获 `CapabilityUnavailable` 并回退到
`browser.evaluate({ operation: "session.requireLogin", account_id, url })`；
`examples/basic.ts` 提供了可编译的回退示例。回退只改变认证入口，不改变页面请求必须
在已认证页面执行这一边界。

`ctx.auth.status` 查询的是 core 原生 HTTP 会话，不等同于 Android WebView 页面会话；
需要页面会话时使用 `browser.evaluate({ operation: "session.status" })` 或平台登录入口。
两者不能通过复制 cookie/token 互相替代。认证只使用 `account_id` 和不透明
`session_handle`，不接收密码、cookie、bearer token 或其他凭据。

### 存储与 source 隔离

`storage.get/set/delete` 的命名空间由 host 绑定到插件和本次调用的有效账号、能力、
来源及网络范围。根输入的 `account_id` 会进一步收窄范围；较低权限调用不能读取
先前较高权限调用的私有缓存。相同范围的任务续接共享状态，权限变化后旧数据保留，
需要受控迁移。SDK 不提供跨命名空间读取；不存在的键返回 `null`。每个命名空间最多
16 MiB，单值最多 1 MiB。插件应保存结构化数据，不保存凭据或原始敏感响应。

非安全 HTTP 方法额外需要 `http.write`，浏览器写入需要 `browser.write`。非 owner
执行实际写入还需要对应的 `execute:<plugin>:<action>`，不会因 `mutating:false` 而
跳过。派生 source 会继承有效的数据读取权限标签，查询和搜索继续检查这些标签。

任务续接应把持久化阶段序号放进 `input`。默认去重不包含 `run_at` 和 `deadline_at`，
仅改变重试时间不会创建重复任务。`wake_up` 是实际平台结果；`not_armed` 不代表后台
唤醒已安排。取消运行中的任务可能保留 `needs_reconciliation`，可信宿主确认结果前
不会自动重发写入。

`sources.upsert` 的 `source_id` 必须以 `<当前插件 id>.` 开头。`external_id` 标识该
source 内稳定记录。`sources.query` 只能读取 host grant 允许的 source；不要把账号凭据、
URL 签名或未筛选的远端响应放进 `data`。

`sources.query` 可用 `external_id` 和 `record_owner` 精确读取详情，或使用 `summary:true`
取得标题、片段和 asset ID。单次结果最多 4 MiB，超出时应减少 limit 或请求摘要。
统一 `search.query` 返回摘要，避免一次搜索传回几十份 PDF 或完整邮件正文。

## 编译与门面审计

```powershell
cd sdk
npm install --ignore-scripts
npm run check
```

`npm run check` 先运行 `scripts/check-runtime-facade.mjs`，从
`crates/dansheng-core/src/plugins/runtime.rs` 读取 `METHODS` 和 `CTX_FACTORY`，再与
`index.d.ts` 的 `PluginContext` 接口和 README 方法表比对。任一运行时方法缺少声明、
声明了运行时不存在的方法、工厂漏接方法或 README 漏记方法都会失败。

随后 `tsc -p tsconfig.json` 以 `strict`、`exactOptionalPropertyTypes`、
`noUncheckedIndexedAccess` 和 `noEmit` 检查声明及 `examples/*.ts`。示例只用于编译：
`examples/basic.ts` 展示认证页面/HTTP/storage/source/UI；`examples/organizer-files.ts`
展示 files 与 organizer 全命名空间。它们不执行真实服务调用，也不包含凭据。
# 原生服务任务类型

`NativeServiceJobScheduleParams` / `NativeServiceJobScheduleResult` 描述可信宿主或已授权 MCP 的 `jobs.schedule` wire 参数。它们不扩展插件的 `ctx.jobs.schedule`；插件仍只能调度自己的已声明 action。示例见 `examples/native-service-jobs.ts`，权限、恢复和取消规则见 `docs/native-service-jobs.md`（仓库根目录下）。
