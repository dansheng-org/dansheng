# 贡献、构建与运行

## 开始贡献

先读 [README](../../README.md)、相关 [架构](../architecture/overview.md) 和 [公开方案](../plans/README.md)。检查分支、工作区改动、Git common directory 与 worktree 登记，保留他人的工作。

一个功能优先一条短期 feature branch、一个已分配 worktree 和一份 PR；同一任务可修改 Core/App，但应先约定接口和文件范围。不因落后 main 自动合并。创建/切换/删除工作树、提交、merge、rebase、push 和发布由维护者授权；普通编辑不自动授权这些操作。原生工具提供的工作树直接复用。

Core/App 属于同一个 Git common directory。旧 `core/tools/workspace` 配对管理器用于历史恢复，不再为新任务建两套仓库；其中 SDK 锁与验证工具仍有效。Windows 新任务推荐 `D:/worktree`，其他机器使用自己的授权路径。

## 工具与环境

固定 Flutter 3.47.7、Dart 3.13.5、Pigeon 29.1.1、Rust 1.99.1；Android 按项目配置使用 JDK 21、Gradle 9.7.1、AGP 9.3.2、SDK 37、NDK 30.0.16138531。安装路径由本机配置决定，不复制用户配置或工具安装进源码。

保留 `core/Cargo.lock`、`apps/dansheng_app/pubspec.lock`、`core/sdk/package-lock.json`。首次使用需公共依赖；`-Offline` 仅适用于已准备的缓存。

首次 clone 先完成 [Git 本地保护](local-agent-setup.md#git-本地保护)：确认私有入口未跟踪，并配置 common `info/exclude`。该文件不随 clone 复制；Enter 会生成缺失的本地入口，但不会替你建立忽略规则。已有配置的工作树只需核验，无需重复追加。

```powershell
# 已分配 worktree 的仓库根，PowerShell 7。
. ./scripts/Enter-Dansheng.ps1
./scripts/Check-Dansheng.ps1 -Component app
./scripts/Check-Dansheng.ps1 -Component core
```

Enter 设置当前 checkout 的独立 runtime、Cargo/Pub/Gradle 缓存、日志、profile 与 SDK 选择，不创建工作树或复制凭据。便携 Rust 工具用 `DANSHENG_TOOLCHAIN_ROOT` 选择。Git worktree 不隔离端口、数据库、浏览器和设备，这些资源也应归任务所有。

## Android SDK 与 App

App 消费精确的 [core.lock.json](../../apps/dansheng_app/core.lock.json)。本树源码联调需要重建 SDK/receipt/lock；SDK-only 使用锁定历史产物，不能宣称是当前源码的新编译结果。见 [兼容契约](../CORE_COMPATIBILITY.md)。

确认公共缓存和 SDK 模式后：

```powershell
./apps/dansheng_app/scripts/prepare-native.ps1 -CoreRoot $env:DANSHENG_CORE_ROOT `
  -RuntimeRoot $env:DANSHENG_TASK_RUNTIME -UpdateLock
./apps/dansheng_app/scripts/build-beta.ps1 -CoreRoot $env:DANSHENG_CORE_ROOT `
  -RuntimeRoot $env:DANSHENG_TASK_RUNTIME
```

SDK-only 镜像获取、权威验证与 CI 签名见 [Android Pre-release](../../apps/dansheng_app/docs/PRERELEASE.md)。保留旧签名身份、产物和收据；development_snapshot 不是稳定发布。

交互调试从 `apps/dansheng_app` 运行 `flutter run -d <任务拥有且已授权的设备>`，仍需正确 SDK 与环境。仅做源码检查时不必操作设备；物理设备操作需明确授权。

## Core Host 与插件

进入根环境后，在 `core` 执行：

```powershell
Set-Location core
./scripts/start-local.ps1 -Action serve -Offline
```

第二终端从**同一个 worktree 的仓库根**单独初始化，再调用；它不会继承第一终端的环境。如果第一终端显式选择了 runtime，两边都应传相同的 `-RuntimeRoot`：

```powershell
. ./scripts/Enter-Dansheng.ps1
Set-Location core
./scripts/start-local.ps1 -Action call -Method core.info -SkipBuild
```

数据目录、Host/CLI/MCP 见 [Core README](../../core/README.md)，插件见 [插件架构](../architecture/plugin-system.md)。公共依赖可缓存，私人 profile、凭据、签名不能作为缓存种子。

## PR 与发布

先确定模块边界和共用契约，再并行实现。按 [testing](testing.md) 提供证据并审阅 `git diff --check` 和完整 diff；只暂存已授权的明确路径，避免运行数据和私人计划进入 PR。

接口、数据迁移及行为改变同步架构/方案和兼容说明。模块可独立版本发布，跨模块功能在同一 PR 验证。push main 会触发 CI，成功后可能自动 Android Pre-release；推送不是纯本地动作。回滚需要匹配的 App、SDK 和数据兼容方案。

维护者本机指令与共享配置见 [local-agent-setup](local-agent-setup.md)，公开贡献不依赖私人计划内容。
