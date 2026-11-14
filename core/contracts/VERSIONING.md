# Core SDK、ABI 与模块版本契约

> 当前统一规则见[单仓库兼容规范](../../docs/CORE_COMPATIBILITY.md)。Core 与 App 在同一 PR 内修改；下列迁移基线属于历史记录。

## 2026-11-10 Dev Drive 迁移验收基线

活动 Core 主库为 `D:/Code/dansheng-core`，迁移时 main 基线提交为
`ac3d047ec3a269b52f21a80226b763c3838f5774`；App 主库为
`D:/Code/dansheng-app`，当时 main 提交为
`e5ca0f33bfe6c7451cb10978baa4bd9a25a5bdc9`。两侧准备工作树在
`D:/Worktrees/DS-001-repository-workflow/core|app` 的旧准备分支保留。现行修改位于正常
注册的 DS-002 配对任务，分别以两个真实 main 提交为基线；未提交的任务修改不会
因 HEAD 指向 main 提交而成为已发布源码。

新任务工作树由用户或 Herdr 管理，首选根目录 `D:/worktree`；已有路径和历史产物保持
原记录。新增服务的本次兼容性验证见 [Core 集成记录](../docs/core-integration-20261111.md)。
下列旧源码/SDK 摘要仅属于迁移验收基线；Core main 更新不会自动更新 App 的消费锁。

迁移验证从 D 盘 Core main 实际构建 Android SDK，源码摘要为
`8c79fd855d08aa15f577403a5b389c24559e8654c44450ce58fe6fea94f74e32`，AAR 摘要为
`cdae74743d402de9f885cc7806eb20c218ead1da69b89996d78ad56fe6ac79e3`。
此前 App 准备树的 `core.lock.json` 锁定上述真实 Core 提交与产物。原始 staging 收据
保留，实际 AAR 内 SO 的身份由同目录 `packaged-receipt.json` 单独验证。
App 准备分支及本地获取方式仍只满足开发验证，不能据此声称稳定发布门槛已通过。

任务源码修改（包含 Rust 文件中的测试改动）会改变构建输入摘要，必须实际重建对应 SDK 并更新消费锁，保留
旧 SDK/锁及其历史验证。`CoreRoot` 标识 SDK 的生产源码，`CoreToolsRoot` 或
`DANSHENG_CORE_TOOLS_ROOT` 只定位同一 Core 仓库的权威验证器；不能为了寻找工具
偷偷切换 SDK 源码。所有新产物、native/AGP 项目副本、收据与日志写入 D 盘任务
runtime，源码工作树和 C 原数据保持独立。

下文关于主库尚无提交、旧源码摘要与旧 AAR 的内容是建立 main 基线及迁移前的
历史验证记录；它们不描述当前 main，也不替代这次 D 盘构建的收据。

## 版本与接口约定

权威代码仍在 Core：`include/dansheng.h` 声明 C ABI v1，`core.info` 返回 API 1，
插件 manifest API 为 1。Cargo 和私有 TS 插件 SDK 当前版本为 0.1.0。App 的 Pigeon
生成绑定和 Android 宿主消费 JNI/AAR；没有现成 Dart Git package，不引入另一套 FFI。
产品 SemVer、API/ABI、源码摘要、Git commit 与文件摘要是不同身份。

App 使用 `core.lock.json`，格式 `dansheng-core-lock-v1`、模式 `native-sdk`。一份锁记录
准确 Core commit/源码及 Android adapter 摘要、ABI/API/工具链、Pigeon/pubspec.lock 身份、
AAR 外层与实际 packaged SO 摘要、运行所需官方模块/许可摘要及获取位置。它是 App 的
依赖选择，Core 的规范/发布收据是生产者依据；不维护两份手工 API 真相。

```powershell
& ./tools/workspace/New-DanshengCoreLock.ps1 -CoreRoot $CoreTree -AppRoot $AppTree `
  -ReceiptFile $Receipt -AarPath $Aar -Destination $Lock
& ./tools/workspace/Test-DanshengCoreDependency.ps1 -LockFile $Lock `
  -ArtifactDirectory $SdkDirectory -CoreRoot $CoreTree -AppRoot $AppTree
```

生成默认 dry-run，写入新锁必须 `-Apply`；拒绝覆盖已有锁。稳定发布要求 `-ForRelease`、
准确且已提交的 Core/App、完整 packaged native receipt、无本地 Pub 覆写及 credential-free
HTTPS 获取位置。发布 Tag 不移动；App/Core 的 tag 和版本各自独立。依赖更新通过新锁和
PR审查，不在运行时偷偷切换源或下载 latest。

## 迁移前准备 SDK 的历史验证

2026-11-10 迁移前 DS-001 准备任务重新构建的开发 AAR SHA 为
`af3bbfa49c7e78f27cab40db952a78141f72da7a745b2f02245b312514cb54c9`；对应 59 项 Core
输入摘要为 `ba160d52c1a583358fef9b232f547fec1ec4d1d9048d6cc52a49a402752bea4c`。
MCP 修正只在测试块内，但输入摘要仍会改变，因此实际重建了 ARM64/x86_64 SDK，
没有把旧产物改写成新来源。新的收据记录真实 packaged SO 摘要；源码和 SDK-only
两种依赖核验都通过。
主库没有提交，因此 `commit=null`，只能显式 `-AllowUnversioned` 并标记
`development_snapshot`。这不是已发布版本，不可伪造 SHA 或通过稳定发布门槛。

保留的旧 AAR（`a916840b…6c1fb`，来源 `8c79fd85…4e32`）收据的 arm64/x86 字段描述
staging SO，AAR 中 packaged SO 摘要不同。锁分别记录两者；旧收据只能作为明确的
开发快照，新的构建已记录真实 packaged 摘要。
不能把未核实的 strip 变换假装成已经证明的来源；不得为迁移改写旧收据或旧产物。
SDK 校验验证外层、两种实际 SO、官方资源和消费锁；SDK-only 使用者在
`ArtifactDirectory/resources` 提供同一已发布资源树，源码联调可显式提供 Core worktree。

跨模块 API 变化优先兼容增加；Rust 公开 enum 新 variant 也会影响外部穷举 match。
删除/改名/序列化改变先声明版本和迁移。先引入 Core 兼容层并测试，再配对 App PR 和
准确两侧 SHA；Core 合入/发布后更新 App 锁，在干净环境验证后授权 App 合入。

每个 App 发布收据另记录 App SHA、Core SHA、API/ABI、生成器、Rust/Flutter 工具链、
最终 APK/SDK 摘要。回滚使用同一发布组合；数据库/插件迁移和远端不确定写入不能由
简单换二进制推断可安全回滚。远程 PR/Release、真实设备和生产部署本轮未自动执行。
