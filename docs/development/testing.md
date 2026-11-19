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

个人仓 `DANSHENG/dansheng` 使用[自托管 Windows/Linux runner](self-hosted-ci.md)，运行日常 App 和 Core 检查并发布签名 Android Pre-release。组织仓 `dansheng-org/dansheng` 同步同一份工作流，正式版本使用 GitHub 托管的 `ubuntu-24.04` 和 `windows-2025`，在任务开始时准备需要的固定版本工具。组织仓日常推送、PR 和手动触发的通用检查会跳过任务。

在个人仓手动运行 **App and Core checks** 时，可设置 `smoke=true` 验证七个任务的调度和工具环境。完整检查用默认的 `smoke=false`。CI 手写 Dart 格式检查使用相对路径、每批最多 32 个文件，并排除 Pigeon 生成的 `lib/bridge.g.dart`。

## 手动同步组织仓

在个人仓的 `main` 完成验收后，从组织仓的本地副本执行以下命令。`upstream` 指向个人仓，`origin` 指向组织仓。

```powershell
git switch main
git fetch upstream
git push origin upstream/main:refs/heads/main
git pull --ff-only origin main
```

若推送因历史分叉被拒绝，先在个人仓处理差异，再重新同步。

## 组织仓正式版本

将验收过的提交同步到组织仓 `main` 后，向组织仓推送匹配 `pubspec.yaml` 版本名的 `vX.Y.Z` 标签。`Organization release` 会先验证标签和 Core SDK 锁，然后运行七项完整检查，全部通过后构建并审计签名的 ARM64 APK。APK、校验和和审计报告保存在该运行的 Actions artifact，供维护者发布。

正式构建沿用 [Core 稳定发布契约](../../core/contracts/VERSIONING.md)。发布提交需要带完整打包收据的 `release` 状态 Core 锁，以及 `.github/prerelease-sdk.json` 中与它匹配的 SDK ZIP 和 SHA-256。ZIP 可来自组织仓中对工作流可读的 Release 附件，或无需登录的 HTTPS 地址。签名使用组织仓的 `DANSHENG_RELEASE_KEYSTORE_BASE64` 和 `DANSHENG_RELEASE_KEYSTORE_PASSWORD`，PKCS#12 中的密钥别名为 `dansheng-beta`。

Native CI 的 Rust fmt、全 workspace 测试和严格 Clippy 仍按原命令执行。耗时较长的 worktree/依赖隔离夹具按变更范围调度：工作区工具、构建脚本或 CI 配置发生变化时执行；已知类型的普通业务源码、测试与文档变动不重复执行这些 Git 夹具。`pubspec.yaml` 只有版本行变化时也按产品变动处理，依赖与 SDK 配置变化仍执行夹具。未知文件、手动全量运行，以及无法可靠取得比较基线或变更清单的情况，均执行完整夹具。判定步骤自身失败也回退到完整执行。调度决定和原因会写入 job 日志。

Windows native job 使用 Cargo 的 `strip = symbols` 配置移除 dev/test 产物的符号表，减少程序体积；测试断言和溢出检查沿用原设置。该配置仅通过 CI 环境变量生效，本地开发配置和发布构建配置各自独立。首次切换 profile 设置需要重新编译依赖，后续仍复用持久编译缓存。性能验证应分别记录编译、测试程序首次启动和测试体执行耗时；启动检查仍可能发生。

本地共享检查使用 `git ls-files`、`git check-ignore -v`、链接目标和双向读取。没有第二个授权 worktree 时不能声称跨工作树已实测。Claude 配置语法与实际加载结果也应分开报告。

## Rust 集成测试调试入口

以下命令在 `core/` 目录执行；从仓库根目录先运行 `. ./scripts/Enter-Dansheng.ps1`，再进入 `core/`。

`dansheng-connectors` 的 20 个普通集成测试模块和 `dansheng-core` 的 10 个普通集成测试模块分别归入各 crate 的 `tests/suites/*.rs`，由各自的 `tests/integration.rs` 注册。新增普通测试按业务模块放入 `tests/suites/`，并在 `integration.rs` 中注册，沿用模块内所需的 feature 门控。旧 `--test <模块名>` 现在对应 `--test integration <模块名>::`：

```powershell
cargo test -p dansheng-connectors --test integration --locked campus::
cargo test -p dansheng-core --test integration --locked plugin_storage::
cargo test -p dansheng-core --test integration --locked assets::
cargo test -p dansheng-core --test integration --locked backup::
```

一次 `cargo test` 只接受一个运行时 filter。多个旧 target 合并后，需要分别执行，或省略 filter 运行整个 integration 组，例如：

```powershell
cargo test -p dansheng-connectors --features services --test integration --locked campus::
cargo test -p dansheng-connectors --features services --test integration --locked qr_presentation::
cargo test -p dansheng-core --test integration --all-features --locked
cargo clippy -p dansheng-core --test integration --all-features --locked -- -D warnings
```

Clippy 的集成测试 target 使用 `--test integration`，不接受测试运行时 filter；上例检查整个 integration target。`forum_live.rs`、`webvpn_live.rs` 和 `forum_webvpn_live.rs` 保持独立 target，live 测试仍为 `ignored`，不纳入普通 suites；执行须另有明确授权并满足对应 feature/环境要求。

历史验收记录中的旧命令、路径和哈希保留原样；复现时按上述关系选择当前入口，不将旧结果视作合并后的验证结果。

## 分层验收

分别报告源码/静态检查、native 编译、模拟器、真实服务读取、物理设备与远程 CI。ARM64 编译不等于实机执行，离线页面/夹具不证明学校 WAF、认证与预约可用。

登录、预约/取消、提交、支付、邮件、部署和设备操作需具体授权。未知外部写入结果先对账再重试。模拟器与浏览器使用任务独立数据目录，不借用私人 profile。

审阅 APK 可以消费明确标记的 development_snapshot，稳定发布仍需 [SDK 门槛](../CORE_COMPATIBILITY.md) 和授权。失败时保留现场并报告，不能用 debug APK 替代请求的 release 工件。

## 历史材料

[App 验收](../../apps/dansheng_app/docs/workbench-validation.md)、[Core 原范围审计](../../core/docs/roadmap-completion-audit.md)、[迁移验证](../MONOREPO_VALIDATION.md)保留原日期与边界。旧结果不能重写为本次检查或当前实时校园服务状态。
