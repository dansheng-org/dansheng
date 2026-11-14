# 插件系统：运行时、授权与契约

本文描述现有 `dansheng-core` 插件实现，不提出新的插件架构。2026-11-14 静态审阅基线为 `c131b19ae64a5664f0b0bc9ae622c87553fe6f7d`；没有执行插件、构建或真实业务。总架构见 [Core](core.md)，完整开发接口见 [TypeScript SDK](../../core/sdk/README.md)。

## 插件与官方连接器的区别

JS 插件是 manifest、ES module 源码及静态资源的包，由 Core 校验和执行。官方原生连接器通过 [CoreService](../../core/crates/dansheng-core/src/services.rs)注册到 Engine，属于可信静态链接代码，不能等同于 JS 沙箱。两者都可承载官方业务规则，通用内核负责共享机制。

当前官方资源包括[内置手动场馆服务](../../core/plugins/builtin/fudan-venues/README.md)和独立分发的 [fudan-sports](../../core/plugins/fudan-sports/README.md)。后者承载定时抢场策略，导入后默认关闭；名称和分发边界沿用现状。`sdk/` 是插件 TypeScript 声明及开发校验工具，不是 Node 生产宿主，也不是 Flutter/Dart package。

## 契约来源

| 契约 | 权威源码或文档 | 解释 |
| --- | --- | --- |
| manifest API 1 | [manifest.rs](../../core/crates/dansheng-core/src/plugins/manifest.rs) | 字段、版本、ID、origin、声明合法性 |
| 包与归档 | [package.rs](../../core/crates/dansheng-core/src/plugins/package.rs)、[archive.rs](../../core/crates/dansheng-core/src/plugins/archive.rs) | 文件边界、校验、安装和版本保留 |
| JS 执行与 ctx | [runtime.rs](../../core/crates/dansheng-core/src/plugins/runtime.rs) | `PluginRunner`、`PluginHost`、`METHODS`、`CTX_FACTORY` |
| 授权和执行调度 | [engine.rs](../../core/crates/dansheng-core/src/engine.rs)、[policy.rs](../../core/crates/dansheng-core/src/policy.rs) | 原调用者、插件身份、grant、任务与外部写入检查 |
| 开发者类型 | [index.d.ts](../../core/sdk/index.d.ts)、[SDK 文档](../../core/sdk/README.md) | 描述实际 ctx；不凭类型声明新增运行能力 |
| API/ABI/包版本 | [VERSIONING](../../core/contracts/VERSIONING.md) | 产品版本、manifest API、Core API、C ABI 是不同边界 |

[早期 implementation contract](../../core/docs/implementation-contract.md)保留设计接口和当时分工，不能把其中早期 ctx 清单或“后续里程碑”当作当前完成度。当前方法应核对运行时、Engine、SDK 三者；已有[门面审计脚本](../../core/sdk/scripts/check-runtime-facade.mjs)用于检查它们的对应关系，本轮未运行该脚本。

## manifest 与包生命周期

manifest 必需字段为 `id`、`version`、`api_version`、`entry`、`name`、`capabilities`、`network`、`actions`；可选 `ui`、`publisher`、`integrity`、`storage_schema`。action 声明包含 `description`、`mutating`、可选 `input_schema`，对应具名导出 `(ctx, input)`。输入声明与 UI 预校验不替代业务实现的执行检查。

解析器拒绝重复 JSON key、未知 manifest 字段、不支持的 API 版本和非法标识；`network` 必须列出唯一、规范的 HTTP(S) origin，不接受带路径、查询、片段或内嵌凭据的地址。包内模块通过相对路径导入，不能逃逸包根目录；校验拒绝不安全路径和链接。运行时从验证后的包快照加载源码，不提供 Node 模块、原生扩展、任意文件系统或原始数据库访问。

安装经过 staging 校验再提升，旧版本保留以便恢复。新安装、升级及代码回滚都保持禁用并要求重新启用；权限变动记录包括新增能力、origin、action、变更为 mutating 及发布者变化。包存在不等于已授权执行，官方身份也不是跳过 grant 的理由。

[catalog.rs](../../core/crates/dansheng-core/src/plugins/catalog.rs)实现按发布者限定的 Ed25519 catalog：可信宿主配置公钥与接受序列，检查签名、过期和回放。`publisher` 与 `integrity` 必须同时声明或省略；内容摘要排除 manifest 以避免循环，catalog 另外绑定 manifest 字节。支持本地包与签名目录不意味着任意导入包都有已验证签名，也不意味着已部署在线插件市场。

## QuickJS 执行模型

[PluginRunner](../../core/crates/dansheng-core/src/plugins/runtime.rs)使用 `rquickjs`，每次执行在独立原生线程内创建、驱动和销毁 QuickJS runtime/context，并使用该线程的 Tokio current-thread executor。这里是进程内 JS 隔离，不是每个插件一个 OS 沙箱进程。Node 只用于开发检查。

当前 `PluginLimits::default()` 为 32 MiB JS heap、512 KiB JS stack、30 秒 wall timeout；host call 默认 10 秒，最多 128 次、同时待处理最多 8 次，单次 payload 1 MiB、累计 8 MiB。宿主可以选择受控 limits，显式前台登录有单独等待设置；这些默认值不保证任何平台或业务必定在该时间内完成。

ctx 调用以 JSON 参数跨 `PluginHost.call`，返回异步 JSON 结果或受控错误。取消令牌同时阻止新分发并中断 JS，等待 Promise 不能逃过截止时间。已发出的远端写入仍可能产生效果，停止 JS 不能当作事务回滚。

## 声明、授权与调用者交集

`capabilities` 是需求声明，`network` 是插件网络上限；实际授权来自可信宿主保存的 [Grant](../../core/crates/dansheng-core/src/policy.rs)。调用参数不能设置可信 principal、grant 或“已批准”身份。Engine 的 `RunHost` 每次 host 调用重新检查插件版本、任务状态和有效权限，而非只在启动时授权一次。

1. 插件以 `plugin:<id>` principal 运行，实际方法须在 manifest 声明并通过插件 grant；origin 进一步限制在 manifest 的 `network`。
2. 原调用者不是 owner 时，重查其 action 授权及账号范围，将插件的 capability、origin、account、source 范围收窄到双方交集；根输入绑定的账号再进一步收窄。
3. `plugin:<id>:<action>` 控制动作调用；非 owner 的实际写入还需 `execute:<id>:<action>`，并检查已有输入约束。把 action 标为 `mutating: false` 不能绕过真实写入检查。
4. 非安全原生 HTTP 方法额外需要 `http.write`，页面写入需要 `browser.write`；具体网络、账号、来源与平台权限仍须满足。

owner 入口不执行非 owner 的调用者交集分支，但插件自身声明和 grant 仍生效。FFI 入口以 owner 身份绑定，可信 App 必须正确管理确认和平台授权；桌面 MCP 使用独立认证身份，不能借 FFI 绕过限制。详见 [Core 宿主边界](core.md)。

`ctx.capabilities.has` 查询当前有效 grant，不证明平台实现了该端口，也不证明某动作已获执行批准。平台不可用、认证失效和拒绝授权是不同结果，不能统一成成功空值。

## ctx、数据与页面能力

ctx 覆盖 HTTP、认证状态、私有 storage、sources、jobs、声明式 UI、通知、browser、托管 files，以及 todo/calendar/activity/reminders；精确方法与参数以 [SDK](../../core/sdk/README.md)和运行时表为准。

- `storage.get/set/delete` 的私有命名空间绑定插件和有效权限/账号范围，低权限调用不能读出此前高权限缓存。权限变化后旧分区保留，不自动变成新授权可读。迁移仅适用私有 KV，参见 [plugin_storage.rs](../../core/crates/dansheng-core/src/plugin_storage.rs)与[迁移契约](../../core/docs/plugin-storage.md)：声明式版本迁移和快照恢复不能等同于代码回滚，也不涵盖 sources、任务或托管文件。凭据应进入平台 vault。
- `sources.upsert` 使用 `<插件 id>.` 来源命名空间；派生数据保留访问限制，后续查询和搜索继续检查。organizer 默认插件私有，只有可信 grant 的 `organizer_scope: "profile"` 才切换为 profile 共享，仍需逐项能力和数据授权。
- `files` 是受管理的资产接口，不暴露任意本机路径。SDK 对当前 `files.export` 明确记录缺少可信平台文件选择器时拒绝，不能因类型或 capability 名称存在就承诺导出支持。
- `ui.publish` 发布 Core 保存的声明式组件并产生事件，UI 决定如何渲染；不向宿主注入插件 HTML/脚本。manifest UI 声明不意味着所有平台已经实现相同组件。
- `auth.status` 检查原生 HTTP 会话；WebView 页面会话另由 browser 端口确认。`browser.evaluate` 只提供具名会话操作，不接受任意插件 JS。认证页面请求保留页面 fetch/XHR 语义，不能静默降级为 `http.request`。Android 约束见 [WebViewBrowserPort](../../core/platform/android/adapter/src/main/java/org/dansheng/android/WebViewBrowserPort.kt)。

## 任务、恢复和证据限制

插件的 `ctx.jobs.schedule` 只能安排自己的已声明 action；可信宿主/已授权 MCP 的[原生服务任务](../../core/docs/native-service-jobs.md)是另一类 wire 参数，不能从 SDK 类型推出插件已获得任意原生任务入口。

任务持久化原调用者，执行时重查权限；立即任务原子领取，避免 tick 与 `plugins.run` 重复执行。取消运行中的外部写入可能留下 `needs_reconciliation`，可信宿主对账前不自动重放。平台 `wake_up` 结果独立报告，不能将任务保存成功描述为 OS 已可靠唤醒。相关源码为 [Engine](../../core/crates/dansheng-core/src/engine.rs)、[Store](../../core/crates/dansheng-core/src/store.rs)和[竞争回归测试](../../core/crates/dansheng-core/tests/immediate_plugin_jobs.rs)。

已有[插件单元测试](../../core/crates/dansheng-core/src/plugins/tests.rs)、[包测试](../../core/crates/dansheng-core/src/plugins/package_tests.rs)、[闭环测试](../../core/crates/dansheng-core/tests/closed_loop.rs)与[历史平台验收](../../core/docs/validation.md)可作为证据入口。测试源码存在不代表本轮执行通过；历史 Windows/Linux、Android x86_64 模拟器与 ARM64 编译结果也不能互换。平台证据及尚未证明的 iOS/macOS/Web、实机和真实业务范围见 [Core 平台矩阵](core.md)。本轮没有新增运行结果或扩大支持承诺。
