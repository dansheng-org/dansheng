# Core 架构与权威边界

本文是对当前单仓库源码与公开契约的导航，不改变既有架构、命名或接口。2026-11-14 静态审阅基线为 `c131b19ae64a5664f0b0bc9ae622c87553fe6f7d`；本轮没有构建、运行服务或访问设备。总览仍以[架构与平台边界](overview.md)为入口，插件机制见[插件系统](plugin-system.md)。

## 通用内核与官方服务

`core/` 是 Cargo workspace，不是单个 crate，也不是 Dart package。[workspace 清单](../../core/Cargo.toml)包含 `dansheng-core`、`dansheng-connectors`、`dansheng-host`、`dansheng-ffi` 和实验台工具。产品所称 Core 包含通用机制及其官方服务集成；学校协议不应因此进入通用内核。

| 模块 | 当前源码职责 | 边界 |
| --- | --- | --- |
| [dansheng-core](../../core/crates/dansheng-core/src/lib.rs) | Engine 分发、SQLite 数据与任务、HTTP 会话、权限、插件、托管文件、搜索、organizer、备份 | 不依赖 Flutter、MCP 或具体学校连接器 |
| [dansheng-connectors](../../core/crates/dansheng-connectors/src/lib.rs) | 复旦、Canvas、社区及邮件等协议、解析、业务约束与服务接入 | 学校端点和业务语义归此层；可选 feature 决定集成内容 |
| [官方插件](../../core/plugins) | 以现有 JS 插件形式提供官方业务行为 | 与原生连接器并存，不把所有业务假设为 JS 插件 |
| [dansheng-host](../../core/crates/dansheng-host/src/lib.rs) | 桌面本地服务、认证 IPC、调度及服务装配 | CLI/MCP 是服务客户端；不是另一份业务数据库 |
| [dansheng-ffi](../../core/crates/dansheng-ffi/src/lib.rs) | 可信嵌入、异步 C ABI、平台请求队列及服务装配 | 不提供不可信远程调用的身份隔离入口 |

连接器的[传输接口](../../core/crates/dansheng-connectors/src/transport.rs)分离请求与响应解析；[Cargo features](../../core/crates/dansheng-connectors/Cargo.toml)中的 `services` 才引入对通用内核的可选依赖，`login`、`webvpn` 再叠加相应能力。因此“连接器独立”指业务/传输边界，不是任何构建组合都没有 Core 依赖。

通用内核通过 [CoreService / ServiceContext](../../core/crates/dansheng-core/src/services.rs)接纳可信、静态链接的服务：服务声明 wire 方法及所需 capability，接收宿主绑定的 principal、grant 与通用存储/网络/平台端口。[CampusService](../../core/crates/dansheng-connectors/src/core_adapter.rs)和[邮件服务](../../core/crates/dansheng-connectors/src/mail/service.rs)是具体实现。它们不是 QuickJS 沙箱模块；新增接口仍须遵守执行时业务与权限检查。

## Core、宿主和 UI 各自的权威

| 契约或能力 | 权威位置 | 消费方责任 |
| --- | --- | --- |
| JSON Request/Response、principal、错误 | [api.rs](../../core/crates/dansheng-core/src/api.rs)、[Engine](../../core/crates/dansheng-core/src/engine.rs) | 保留请求 ID、错误码及显式 `result: null`，不能由参数伪造身份 |
| grant 与通用能力检查 | [policy.rs](../../core/crates/dansheng-core/src/policy.rs)、Engine、服务实现 | UI 提示或预校验不能替代执行检查 |
| C ABI v1 | [dansheng.h](../../core/include/dansheng.h)、[FFI 实现](../../core/crates/dansheng-ffi/src/lib.rs) | 遵守句柄、内存和异步生命周期契约 |
| OS 能力 | [PlatformPort](../../core/crates/dansheng-core/src/platform.rs)及平台适配器 | 实现真实浏览器、凭据保管、唤醒等能力；缺失时明确失败 |
| Android App 平台通道 | [Pigeon 定义](../../apps/dansheng_app/pigeons/dansheng.dart) | 生成 Dart/Kotlin 通道，映射到已有 Core 接口；不另定业务协议 |
| SDK 身份与兼容 | [版本契约](../../core/contracts/VERSIONING.md)、[单仓库兼容规范](../CORE_COMPATIBILITY.md) | 区分源码、API/ABI、消费锁和实际 AAR 内容 |

wire 请求形如 `{ "id": "...", "method": "namespace.operation", "params": {} }`，响应为同 ID 的 `result` 或 `error`。身份由入口绑定。这里的业务权威包括官方连接器和官方插件，并不要求把学校规则搬到 `dansheng-core`。宿主仍需对可信交互、页面会话和平台执行做本地检查，UI 负责展示、输入及确认。

## 桌面与 Android 调用路径

桌面路径为 CLI / stdio MCP → 认证本地 IPC → `dansheng-host` → Engine → 通用机制或已注册服务。Windows 使用 named pipe，Linux 使用 Unix socket；服务持有数据库和调度器。MCP 使用独立身份和 token，初始无业务授权，不能通过请求参数升级为 owner，也不能管理凭据、grant 或发布者信任。具体协议和映射见 [Host 说明](../../core/crates/dansheng-host/README.md)、[MCP 实现](../../core/crates/dansheng-host/src/mcp.rs)。

现有 Android 请求方向为 Flutter UI → Pigeon → Kotlin host → JNI/AAR → C ABI → Engine；平台能力调用则经 FFI 队列回到 Android 适配器。

- [Pigeon](../../apps/dansheng_app/pigeons/dansheng.dart)定义 `HostCommand` 和异步 `DanshengApi.invoke(command, payload)`，生成现有 Dart/Kotlin 绑定，不是 Rust 的 Dart package。
- [RuntimeHost](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/RuntimeHost.kt)管理嵌入实例与调用；[NativeCore.kt](../../core/platform/android/adapter/src/main/java/org/dansheng/android/NativeCore.kt)和 [JNI C 桥](../../core/platform/android/adapter/src/main/cpp/dansheng_jni.c)消费 C ABI。
- [PlatformPump](../../core/platform/android/adapter/src/main/java/org/dansheng/android/PlatformPump.kt)轮询平台请求并回送结果；[WebViewBrowserPort](../../core/platform/android/adapter/src/main/java/org/dansheng/android/WebViewBrowserPort.kt)负责页面操作，[CoreJobWakeHost](../../core/platform/android/adapter/src/main/java/org/dansheng/android/CoreJobWakeHost.kt)承接后台唤醒。

FFI 直接使用 `Principal::owner()`，只适用于可信本地宿主。不能把它直接暴露给不可信插件或 MCP 来代替认证 IPC。C 调用返回 operation 句柄，宿主 poll 获取 JSON 并按 allocation 句柄释放缓冲区；close 也须等待完成。平台能力采用 poll/respond，而非从 Rust 任意线程回调 UI。取消本地等待不会撤销已发生的外部操作，详见 [FFI 生命周期契约](../../core/crates/dansheng-ffi/README.md)。

## 会话、数据与任务

原生 HTTP 会话与 WebView 页面会话是不同边界。需要认证页面的服务请求必须在持有会话的页面执行 fetch/XHR，保留 WAF 和页面语义；不能因浏览器不可用就静默切换为 Rust HTTP。通用 [PlatformPort](../../core/crates/dansheng-core/src/platform.rs)未实现能力时返回 `CapabilityUnavailable`。[桌面平台实现](../../core/crates/dansheng-host/src/platform.rs)也不意味着已提供 Android 同等浏览器能力。

[Store](../../core/crates/dansheng-core/src/store.rs)保存业务数据、授权和任务；平台 vault 承担秘密保管，不能将插件 KV 当凭据库。[network.rs](../../core/crates/dansheng-core/src/network.rs)与[网络路由](../../core/docs/network-routing.md)处理通用请求机制；[assets](../../core/docs/assets.md)、[organizer](../../core/docs/organizer.md)和[备份](../../core/docs/backup.md)各有独立数据契约。

任务领取、持久化状态及恢复在 Core。`plugins.run` 的立即任务与调度 tick 使用受控领取，不能依靠 UI 去重防止竞争。平台唤醒结果与任务已入库是两件事；`not_armed` 不代表后台唤醒已经安排。外部写入结果不确定时保留 `NeedsReconciliation`，取消、重启或重试不能将其变成成功。参见 [Engine](../../core/crates/dansheng-core/src/engine.rs)、[立即任务回归源码](../../core/crates/dansheng-core/tests/immediate_plugin_jobs.rs)、[原生服务任务契约](../../core/docs/native-service-jobs.md)。

## 已有平台证据与未证明范围

下表引用公开历史记录，未读取其指向的私人数据或外部捕获，也未在本轮重跑。记录只证明各自注明的源码和产物，不能累加成当前 HEAD 的完整验收。

| 范围 | 可引用的既有证据 | 不能据此推断 |
| --- | --- | --- |
| Windows Rust Host/FFI | [2026-11-07 验收记录](../../core/docs/validation.md)记载 workspace 测试、IPC/MCP、归档解包运行；[2026-11-10 迁移记录](../../core/docs/devdrive-validation.md)记载后续构建验证 | Flutter Windows 产品已完成，或当前 HEAD 已重测 |
| Linux Rust Host/FFI | [Linux 记录](../../core/docs/linux-validation.md)明确区分 204 项实际执行与 136 项连接器沿用，并记录实际 ELF/C ABI smoke | 全部 340 项当批重跑、Flutter Linux UI 或与 Android 能力等价 |
| Android x86_64 | [Core Android 记录](../../core/docs/android-sports.md)及[App 验证入口](../../apps/dansheng_app/README.md)区分验证宿主、产品测试与受控页面 | 合成页面证明真实学校登录/预约，或模拟器证明 OEM 后台行为 |
| Android ARM64 | [历史 Core 验收](../../core/docs/validation.md)记录交叉编译；[迁移验收](../../core/docs/devdrive-validation.md)记录后续 SDK/App 打包 | 编译或 APK 存在证明 ARM64 实机执行 |
| iOS / macOS / Web | [现有项目总览](overview.md)将其列为后续产品范围 | 已有宿主、可直接复用 Android AAR 或已验证支持 |
| 校园服务 | [集成记录](../../core/docs/core-integration-20261111.md)、[研究交付矩阵](../../core/docs/fudan-service-research/delivery-matrix.md)按方法区分实现与真实读取 | 方法被注册、fixture 通过就代表当前账号/网络下可用 |

同仓库提交不会自动更新 App 的 native SDK。消费身份以 [core.lock.json](../../apps/dansheng_app/core.lock.json)及匹配收据为准；SDK-only 审阅不能证明当前 Rust 源码已进入 AAR。本轮仅新增说明，不验证或更新这些二进制身份。

后续仍需按具体变更补充当前源码的原生测试、对应 SDK 构建与设备证据；非 Android 产品宿主、ARM64 实机/OEM 行为及真实业务成功均不能由本次静态审阅补齐。旧文档的双仓库路径、早期里程碑和测试数保留其历史含义，现行组织与兼容规则以根目录文档为准。
