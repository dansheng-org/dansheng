# App 开发与双仓库工作流

DS-002 相对于 App main 的改进和 2026-11-12 的实际接收验证见 [main 接收记录](ds002-main-acceptance-20261112.md)。Core 来源以 `core.lock.json` 的准确提交为准；下面的迁移与准备任务描述保留其原始验收时间和路径。

本规约落实《Dansheng 双仓库多 Agent 版本管理实施规范》v1.0（2026-11-10）。保留两个独立产品仓库；普通父工作区不初始化 Git。既有工作台/Antigravity 验收记录继续保留，以下流程不会把历史结果改写为本轮已通过。

## 默认使用 Agent/Herdr 原生工作树

在 `D:/Code/dansheng-app` 选择 Codex/Herdr 的新工作树模式，或从该目录执行
`claude -w <任务名>`。本机 Codex CLI 也可用
`codex -C D:/Code/dansheng-app --worktree`。工作树已由工具创建时直接复用，不再要求
手工 DS 编号、额外登记或 TASK.md。每个编辑 Agent 独占一棵 Git 注册的工作树。

工具创建的 detached HEAD 可先编辑，提交前再建分支。构建所需的工具链、独立
runtime、SDK 与锁由 Agent 在启动/构建前自动准备；无需用户执行整套手工脚本。
App 消费明确且已验证的 Core SDK，跨仓库改动才协调 Core/App 来源和两侧版本。
以下 New/Initialize/Enter 是可选配对管理器，不是使用原生 worktree 的必经步骤。

## 现状与准备任务

经用户授权迁移后，Core 位于 `D:/Code/dansheng-core`，App 位于 `D:/Code/dansheng-app`；C 盘旧目录保留且只读。当前任务树位于 `D:/Worktrees/<TaskKey>/core|app`，分别共享 D 盘 Core/App 的 Git 对象，并有独立 index/HEAD。DS-001 只作为历史只读准备树保留。`D:/Code/dansheng` 是旧 main 的兼容入口，不是第三个产品仓库，也不是新脚本默认项目名。

最初准备时产品 main 尚无首次提交；经用户授权，Core/App 的会话前 main 已分别提交并推送。DS-001 仍是未接收的 orphan 准备树，其 149 项 review index 不等于提交，其中一份历史 Gradle 报告保留且未进入 main，实际基线源码为148项。普通任务必须基于真实提交。提交、远程配置、合并、研究迁移和清理由主线程列出影响并取得用户批准，本规约不自动授权这些操作。

## 一个任务，一个写入 worktree

1. 原生工具的任务名与分支名可直接使用，DS 编号只在使用配对管理器时采用；不设永久 agent 专属分支。App-only 不额外创建 Core 树。
2. 可选 Core `tools/workspace` 配对管理器提供 New/Status/Enter/Close，显式使用时先查看计划；工具已提供的工作树不重复创建。
3. 目标、允许修改范围与验收可记录在会话或可选 TASK.md。一个 worktree 不同时交给两个写入型 agent。
4. 开始前核对 cwd、任务分支和 `git --no-optional-locks rev-parse --path-format=absolute --git-common-dir`。Core/App 的 common directory 必须不同，同一仓库的任务 worktree 则共享该仓库的 common directory。
5. runtime_root 隔离 Cargo/Pub/Gradle、临时文件、端口、数据库、浏览器和测试资源。进入任务工具设置的环境不能授权读取原项目的私人 profile；worktree 本身不隔离副作用。

## App 与 Core 联调

当前使用原生 SDK 路线，详见 [CORE_COMPATIBILITY.md](CORE_COMPATIBILITY.md)。`-CoreRoot` 优先于 `DANSHENG_CORE_ROOT`；未指定时，目录名为 `app` 的任务先找配对 `core`，再找平级 `dansheng-core`，最后兼容既存 `dansheng`。SDK、lock、runtime 的相对路径均相对 App 解析。

```powershell
$TaskKey = '<已创建的任务 key>'
$AppTask = "D:/Worktrees/$TaskKey/app"
$CoreTask = "D:/Worktrees/$TaskKey/core"
$CoreTools = "$CoreTask/tools/workspace"
& "$CoreTools/Initialize-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace -TaskKey $TaskKey -Owner codex-workflow -CacheRoot D:/DevCache -Apply
. "$CoreTools/Enter-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace -TaskKey $TaskKey -Component app
Set-Location -LiteralPath $AppTask
$env:DANSHENG_CORE_ROOT = $CoreTask
$env:DANSHENG_CORE_TOOLS_ROOT = $CoreTools
# 使用任务入口/Initialize 的已记录 runtime_root 和缓存变量。
# public 缓存的种子来自 D:/DevCache，不能复制账号/Gradle用户配置/daemon。
# 已准备的 SDK 可放在任务 runtime_root；不要把原产物复制到源码。
# $env:DANSHENG_CORE_SDK_DIR = '<已核对的任务 artifact directory>'
flutter pub get --offline
flutter analyze
flutter test
```

本地源码构建只在获得 Core 构建授权后使用 `scripts/prepare-native.ps1 -CoreRoot $CoreTask`。App 构建脚本验证 native receipt/lock，Gradle 与 APK 审计读取相同的 Core 与 SDK 路径。不可把原 App `.local/native` 的旧 AAR 与另一个 Core 源码摘要拼成新收据。

prepare-native 使用显式 `-RuntimeRoot` 或任务入口的 `DANSHENG_TASK_RUNTIME`；未提供时按已核验的 task JSON 解析 runtime_root。SDK、分发产物、日志分别使用 `native-sdk`、`artifacts`、`logs`；Cargo home/target、Core Gradle/project cache 和 CMake staging 都使用任务运行目录。AGP 的公共 Android 构建输入复制到 runtime 的 `core-android-project`，收据仍绑定实际 `CoreRoot`，元数据不会写回 Core 源码。已有构建副本的字节与源码不同会拒绝覆盖，应选择新的运行目录。离线构建前运行 Initialize 准备 public Cargo 依赖。它拒绝把产物写进 Core checkout 或从任务树覆盖原 App 的 native 目录。

只读消费既存 MainCore SDK 时，明确传 `-CoreRoot D:/Code/dansheng-core -CoreToolsRoot $CoreTools -ArtifactDirectory D:/Code/dansheng-app/.local/native -UsePreparedNative`。源码位置与验证器位置分离，工具必须属于同一 Git common directory；不会将 SDK 源码改指另一工作树。需要换 SDK 锁时，`-UpdateLock` 先在任务 logs 备份旧锁。`-IncludeBeta` 才执行内部签名流程；默认使用任务 `signing/android-beta` 的新内部测试身份，`-SigningDirectory` 只接受同一 runtime 内的独立目录。C 盘原身份/DPAPI数据不自动迁移。

内部测试签名目录使用绝对路径，例如在已经完成 SDK 核验的任务中：

```powershell
./scripts/package-workbench.ps1 -CoreRoot $CoreTask -CoreToolsRoot $CoreTools `
  -ArtifactDirectory $env:DANSHENG_CORE_SDK_DIR -UsePreparedNative -IncludeBeta `
  -SigningDirectory (Join-Path $env:DANSHENG_TASK_RUNTIME 'signing/android-beta')
```

`prepare-native.ps1` 显式绑定 `-CoreRoot`/`-RuntimeRoot` 供复制后的 Gradle 启动器使用，
参数优先于已有任务环境；退出时恢复原来的 Cargo、Rust/NDK、源码和 runtime 环境值。

`verify-ui-runtime.ps1` 默认 dry-run；`-Apply` 创建全新 D AVD，禁用网络后安装 hash 已记录的 debug APK，点击 eHall 设置并检查真实 core.info 行。默认使用 API 36 离线镜像；重启恢复验证可显式选择 `-SystemImage 'system-images;android-28;default;x86_64'`，名称由每次运行独立生成。`-KeepAlive` 仅在后续全流程验收需要同一 disposable AVD 时使用。`verify-workbench.ps1`、`verify-product-emulator.ps1`、`check-wake-recovery.ps1` 都要求该 AVD 的 `-OwnershipFile`，拒绝借用旧设备/profile；重启还核对实际系统为 API 28，不依赖旧 AVD 名称。APK、androidTest、独立插件包和输出目录可显式传参。

打包将 debug APK、`dansheng-android-x86_64-androidTest.apk` 和独立插件放在任务
`artifacts`，验收默认读取这一组冻结工件；需要指定其他已核验工件时使用显式参数。

生成输出由 `.gitignore` 分类：`android/build` 下 Gradle HTML报告、`build`、`.cxx`、`.gradle`、native SDK、APK/AAR/dspack 和 runtime 不是产品源码。迁移前未跟踪的 `android/build/reports/problems/problems-report.html` 已按原字节归档、通过本机 Git info/exclude 精确排除；该规则只分类，不删除或改写保留的旧报告。fixture/正式源码即使名称相似，也不自动清理。

## 复核、提交与分阶段合并

`git --no-optional-locks diff --check`、`git --no-optional-locks diff` 后运行相关本地检查。只在用户批准后选择明确的 staged 路径并提交/推送/建 PR；生成文件也需要检查差异，不能用“生成了”替代契约一致性。

跨仓库 PR 使用相同 DS 编号，互链 Core/App PR 与测试过的 SHA。先接收兼容 Core，发布不可变的 SDK/Tag；App 固定新依赖，移除本地覆盖并在干净环境验证后再接收。删除旧 API 或数据迁移另列步骤；两个仓库不存在原子提交。当前没有远程 PR/ruleset，不能声称服务端保护已启用。

## 检查范围

- 本地源码：`scripts/check-format.ps1`、`flutter analyze`、`flutter test`。手写 Dart 采用当前 SDK 格式；Pigeon 生成文件以固定生成器的一致性检查为准，不另行手工格式化。
- 绑定：Pigeon 版本由 pubspec.lock 固定，运行 `dart run pigeon --input pigeons/dansheng.dart` 后确认两个生成文件无意外变化。
- Native SDK：Core 的 `Test-DanshengCoreDependency.ps1` 核对 lock、AAR/resources、source/ABI、Pub锁；稳定发布加 `-ForRelease`。
- 已准备 SDK 的环境回归：`scripts/tests/native-environment.integration.ps1` 使用显式 Core/CoreTools/runtime/artifact 参数，检查无预置任务和不同任务环境、失败后的恢复及既存构建副本保留；需要真实 SDK 和已初始化的离线缓存，普通源码 CI 不执行它。
- Android：得到正确 SDK 后才构建；模拟器与真实设备分别授权/记录。现有 `verify-*` 脚本可能操作资源或读取本机凭据，不能作为 CI 中自动可执行的只读脚本。
- `.github/workflows/app-ci.yml` 是最小源码 CI 配置，尚未在远程执行。缺真实已发布 Core acquisition 时，原生干净 CI 构建与稳定发布仍待接线，不能用虚构包/SHA凑齐。

清理需先确认任务已接收且没有 dirty/untracked 内容，保留可恢复记录。不执行 force remove、强制删分支、reset/clean、retag 或覆盖 remote。
