# 整体架构

## 当前结构

Dansheng 是单 Git 仓库，Rust Core 与 Flutter App 保持独立模块边界和版本。实际模块为 [core](../../core/README.md) 和 [apps/dansheng_app](../../apps/dansheng_app/README.md)。文档整理不搬迁源码，不引入示意中的 `packages/dansheng_core/`。

| 层 | 实际位置 | 权威职责 |
| --- | --- | --- |
| 通用内核 | `core/crates/dansheng-core` | HTTP/会话、存储、权限、任务、插件、文件与搜索等机制 |
| 官方服务 | `core/crates/dansheng-connectors`、`core/plugins` | 学校协议、业务约束、执行策略，执行时再次校验 |
| 平台宿主 | `core/platform`、`core/crates/dansheng-host`、App `android/` | OS、系统浏览器、凭据存储、通知、后台唤醒 |
| UI | `apps/dansheng_app/lib` | 展示、输入、导航、界面状态；预校验消费服务约束 |

依赖方向为 App → Core API；Core 不依赖具体 App 页面。通用内核不强绑学校端点、Flutter、MCP 或浏览器分发，由官方服务、Host 和适配层分别集成。

Android 链路为 **C ABI → JNI/AAR → Kotlin host → Pigeon/Dart**。C ABI、业务 JSON 和插件契约由 Core 定义，Pigeon 是 App 平台通道。[SDK 兼容规则](../CORE_COMPATIBILITY.md)要求精确的源码、产物和资源身份；同仓库源码不等于已重建 AAR。

认证请求在持有会话的页面执行，不以复制 Cookie 或原生 HTTP 推断 WebView/WAF 等价性。插件通过被授予的宿主能力访问资源，产品不嵌入 Node 或整套 Chromium。

## 平台与状态

| 范围 | 状态 | 证据边界 |
| --- | --- | --- |
| Android Flutter 产品及 Kotlin/JNI 宿主 | 已实现 | 源码、签名包、模拟器和真实服务分别验证 |
| Windows/Linux Rust Host、CLI、MCP | 已实现 | 不等于 Flutter 桌面客户端已实现 |
| Core/UI 分层、原生 SDK 锁、平台端口 | 已确定且在现有系统实施 | 新平台应按同一业务契约提供自己的宿主 |
| Flutter Windows/macOS/iOS、Web 客户端、桌面浏览器提供者 | 后续探索/待实施 | 不预建空平台目录，不凭可扩展性宣称支持 |

“已实现”表示有源码；“已确定待实现”需要设计依据；“探索”不承诺 API 或发布日期。历史结果只适用于其提交、平台与时间，见 [测试规范](../development/testing.md)。

## 模块化取舍

Flutter 应用内部组织平台宿主，独立客户端才新建 `apps/<client>`。现有 Dart 业务 UI 在 `lib/ui/campus/` 等目录，不为套模板改为 `features/`。

Rust workspace 使用 `core/Cargo.toml` 和 Cargo.lock；当前只有一个 Flutter package，保留其 Pub lock。出现多个独立 Dart package 后再评估 Pub Workspaces，它不管理 Rust。不因文档整理引入 Nx、Bazel、submodule 或第二套任务管理器。

## 详细说明与上游依据

- [App](app.md)、[Core](core.md)、[插件](plugin-system.md)、[公开方案](../plans/README.md)
- [Flutter 架构建议](https://docs.flutter.dev/app-architecture/recommendations)：按 UI/data 职责分层，结合现有 Rust 业务层。
- [Flutter 平台集成](https://docs.flutter.dev/platform-integration)：平台差异落在宿主边界。
- [Cargo workspaces](https://doc.rust-lang.org/cargo/reference/workspaces.html) 和 [Pub workspaces](https://dart.dev/tools/pub/workspaces)：各自管理实际存在的语言模块。
- [Git worktree](https://git-scm.com/docs/git-worktree)：共享历史、独立工作目录；运行资源还需隔离。

上述原则继承原架构说明，按本仓库情况采用，不代表所有大型项目具有相同目录命名。
