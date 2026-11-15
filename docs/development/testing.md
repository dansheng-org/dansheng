# 验证范围与证据

验证应覆盖实际变更，配置存在、构建成功或 worker 报告不能替代集成验收。记录提交、依赖锁、工具链、命令和退出码；产物保留 SHA-256，工作区 dirty 状态如实说明。

| 变更 | 相关验证 |
| --- | --- |
| 纯文档/本地指令与共享配置 | 链接、源码路径、事实状态、Git 跟踪/忽略、实际加载/共享探针、diff 范围；不因此重建业务 APK |
| Dart/UI | 格式、analyze、相关 flutter test；按影响追加布局和交互验证 |
| Pigeon/平台边界 | 固定生成器一致性、两端契约、平台构建及宿主测试 |
| Rust/Core/插件 | fmt、相关 tests/fixtures、clippy；协议变更同步消费者与负面用例 |
| SDK/锁/构建链 | 真实源码与 receipt、AAR/native entries/resources/Pub lock、重建和内容审计 |
| 产品行为/绑定/Android 构建 | 适用的签名 ARM64 release 审阅 APK、版本/ABI/哈希、载荷/对齐/签名；运行层另验 |

用户要求更具体的检查时按任务执行。已经通过的相关检查不因文档措辞调整重复全量构建；新代码、失败或未解决风险才扩大范围。

## 检查入口

```powershell
. ./scripts/Enter-Dansheng.ps1
./scripts/Check-Dansheng.ps1 -Component app
./scripts/Check-Dansheng.ps1 -Component core
```

App 包含锁定 Pub 解析、手写格式、analyze、test、Pigeon 生成及差异检查。Pigeon 29.1.1 输入为 App `pigeons/dansheng.dart`，输出 Dart `lib/bridge.g.dart` 与 Android `Bridge.g.kt`；生成文件不手改或单独格式化。

Core 包含 `cargo fmt --all -- --check`、`cargo test --workspace --all-features --all-targets --locked` 和 strict Clippy。插件 SDK 使用自身 npm lock、类型检查和 Node tests。精确 CI 命令见 [app-ci.yml](../../.github/workflows/app-ci.yml) 和 [core-ci.yml](../../.github/workflows/core-ci.yml)。

自托管 Windows/Linux runner 的分工、预装环境接口、缓存/签名隔离与 smoke 验收见 [自托管 CI](self-hosted-ci.md)。CI 手写 Dart 格式检查使用相对路径、每批最多 32 个文件，并排除 Pigeon 生成的 `lib/bridge.g.dart`。

本地共享检查使用 `git ls-files`、`git check-ignore -v`、链接目标和双向读取。没有第二个授权 worktree 时不能声称跨工作树已实测。Claude 配置语法与实际加载结果也应分开报告。

## 分层验收

分别报告源码/静态检查、native 编译、模拟器、真实服务读取、物理设备与远程 CI。ARM64 编译不等于实机执行，离线页面/夹具不证明学校 WAF、认证与预约可用。

登录、预约/取消、提交、支付、邮件、部署和设备操作需具体授权。未知外部写入结果先对账再重试。模拟器与浏览器使用任务独立数据目录，不借用私人 profile。

审阅 APK 可以消费明确标记的 development_snapshot，稳定发布仍需 [SDK 门槛](../CORE_COMPATIBILITY.md) 和授权。失败时保留现场并报告，不能用 debug APK 替代请求的 release 工件。

## 历史材料

[App 验收](../../apps/dansheng_app/docs/workbench-validation.md)、[Core 原范围审计](../../core/docs/roadmap-completion-audit.md)、[迁移验证](../MONOREPO_VALIDATION.md)保留原日期与边界。旧结果不能重写为本次检查或当前实时校园服务状态。
