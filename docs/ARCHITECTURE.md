# 架构与平台边界

## 一个仓库，四层职责

| 层 | 位置 | 权威职责 |
| --- | --- | --- |
| 通用内核 | `core/crates/dansheng-core` | 会话、存储、任务、权限、插件执行与通用机制；不依赖 Flutter 或学校服务 |
| 官方服务 | `core/crates/dansheng-connectors`、`core/plugins` | 学校协议、业务约束、执行策略；执行时再次校验输入 |
| 平台宿主 | `core/platform`、`apps/dansheng_app/android`、Core host | OS、系统浏览器、凭据、通知、后台唤醒等平台能力；不复制业务权威规则 |
| UI | `apps/dansheng_app/lib` | 展示、输入、导航和界面状态；预校验消费 Core 约束 |

现有 Android 链路是 C ABI → JNI/AAR → Kotlin host → Pigeon/Dart。`core/include/dansheng.h` 和 Core 协议是权威契约；Pigeon 是 App 平台通道。迁移不更换绑定技术，也不把 Rust 假装为 Dart package。

浏览器认证请求在持有会话的页面中执行，不以 Rust HTTP 偷换 WebView/WAF 语义。通用 Core 不强绑 MCP、Flutter 或 Chromium。Node 仅用于开发工具与插件测试。

## 模块与平台组织

Flutter 共享 UI 按现有 feature/service 分层演进；平台差异由 host/adapter 承担，不按 Android/iOS 复制全部 UI 与业务。只有真实的新客户端才创建 `apps/<client>`。不预建空平台、不因项目规模引入 Nx、Bazel 或多余发布工具。

Rust crates 由 `core/Cargo.toml` 和 `core/Cargo.lock` 统一管理；目前只有一个 Flutter package，保留其 Pub lock。将来产生多个真正独立的 Dart package 时再评估 Pub Workspaces，它不管理 Rust。

| 目标 | 当前定位 | 验证要求 |
| --- | --- | --- |
| Android | Flutter App + Kotlin/JNI + Rust SDK | 源码、native 编译、签名 APK、模拟器分别记录 |
| Windows/Linux | Rust host/CLI/MCP 能力 | 各 OS native 测试；不等于 Flutter 桌面 App 已实现 |
| iOS/macOS/Web | 后续产品范围 | 先定义宿主能力与限制，再实施；Web 不直接加载现有 Android AAR |

## 采用的上游依据

- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)：清晰的 UI/data 边界、按职责组织和独立测试，结合现有 Rust 业务层使用。
- [Flutter platform integration](https://docs.flutter.dev/platform-integration)：平台宿主在平台边界实现。
- [Cargo workspaces](https://doc.rust-lang.org/cargo/reference/workspaces.html)：Rust workspace 统一依赖锁和构建配置。
- [Pub workspaces](https://dart.dev/tools/pub/workspaces)：仅在多 Dart package 时考虑统一解析。
- [Git worktree](https://git-scm.com/docs/git-worktree)：同仓库多工作树共享历史，工作目录与未提交状态独立。

这些原则用于本仓库的具体取舍，不宣称所有大型项目都有相同目录命名。
