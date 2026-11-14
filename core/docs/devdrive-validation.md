# Dev Drive 路径与工作流验收

2026-11-10。两个独立产品仓库分别为 `D:/Code/dansheng-core` 和
`D:/Code/dansheng-app`。普通工作区 `D:/Code/dansheng-workspace` 与工作树父目录
`D:/Worktrees` 都没有 Git 仓库。C 盘原件保留，未删除原项目、凭据、历史产物或 profile。

## 当前源码与运行目录

| 内容 | 当前位置 |
| --- | --- |
| Core 主库 | `D:/Code/dansheng-core` |
| App 主库 | `D:/Code/dansheng-app` |
| 当前 Core 任务 | `D:/Worktrees/DS-002-devdrive-workflow/core` |
| 当前 App 任务 | `D:/Worktrees/DS-002-devdrive-workflow/app` |
| 任务登记 | `D:/Code/dansheng-workspace/local/tasks` |
| 当前任务运行数据 | `D:/Code/dansheng-workspace/local/runtime/DS-002-devdrive-workflow` |
| 公共依赖种子 | `D:/DevCache` |
| 迁移与验收日志 | `D:/MigrationLogs/dansheng-devdrive-20261110T181357Z` |

两个任务都是 Git 注册的 worktree，基于 Core `ac3d047ec3a269b52f21a80226b763c3838f5774`
和 App `e5ca0f33bfe6c7451cb10978baa4bd9a25a5bdc9`。本轮改动未提交、合并或推送。
DS-001 保留为历史准备树。`D:/Code/dansheng` 兼容入口只服务旧主线引用，现行代码使用
`dansheng-core` 名称。

工具程序和持久配置按真实位置保留：Flutter 在 `C:/flutter`，Android SDK 在
`C:/Android/Sdk`，手动 Gradle/SDK 使用 Microsoft JDK 21；Flutter 沿用 Android Studio
的 JBR 25.0.3。项目固定的 Rust 1.99.1/GNU 工具链取自
`D:/Code/dansheng-core/.local/toolchain`，C 原件及用户全局工具安装保留。
Gradle、Pub、npm、pnpm 公共缓存使用 D 盘，任务自己的可写缓存由 Enter/Initialize 设置。

## 可复用入口

```powershell
$Task = 'DS-002-devdrive-workflow'
$Tools = "D:/Worktrees/$Task/core/tools/workspace"
. "$Tools/Enter-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace `
  -TaskKey $Task -Component core
```

初始化使用 `Initialize-DanshengTask.ps1`，默认只返回计划，授权的任务中加 `-Apply` 才复制
缺失公共依赖。已有文件、配置、凭据、另一任务与原件不覆盖。任务 SDK 默认位于
`native-sdk`，分发输出位于 `artifacts`，日志位于 `logs`；各自与源码独立。

## 本轮已执行检查

- Rust fmt、381 项 all-features/all-targets 测试、严格 Clippy 与 TS SDK 检查通过。
- App analyze 与 133 项 Flutter 测试通过。初次 Windows SocketException 10055 的加载失败
  原样保留，默认测试并发改为 2 后完整复测通过。
- 42 项工作树管理测试、6 项缓存边界回归、38 项 App 路径/工具检查通过。
- 实际 SDK 构建检查无预置任务、不同任务环境、冲突副本失败后的 24 项环境恢复。
- 完整 App 打包通过，包括双 ABI SDK、debug/内部 beta/androidTest、7 项 JVM 测试、原生库与
  官方资源校验、16 KiB 对齐和签名。APK 名称使用精确 ZIP 比较，3 项回归保留 AAPT2
  大小写不同的资源并拒绝精确重名。

当前 Core 的 59 项构建输入摘要：
`ba160d52c1a583358fef9b232f547fec1ec4d1d9048d6cc52a49a402752bea4c`。
Windows 两次独立编译的 SHA-256 都为
`6dcfacf4edab2ba63b4fe88cb627312bc20dfbbe77bfbe6707170c10761ebc2a`；
Android ARM64 两个全新 target 使用相同公共依赖源码目录，SHA-256 都为
`96d472a7b721612691a86265e6477e6934db3d4c2de5c0af80907826a48d6260`。
不同 Cargo home 会改变 Rust 嵌入的依赖路径；该失败对照及原收据保留，详见
[发布配方](release.md)。不复用第二次编译对象，也不修改二进制制造一致。

App 当前锁定的 AAR 为
`0c0bcb12469dbd3cc66e7c26b8387f8da0e11214f59901e411a3163e74166e99`。
它携带锁声明的 7 项公共模块/许可资源，SDK-only 核验通过；状态是
`development_snapshot`，不代表已经发布。旧 AAR/旧锁与不同构建目录的结果保留。

## 运行证据与边界

上述日志目录的 `workflow-progress.json` 记录整体状态；
`workflow-app-artifacts-frozen.json` 固定实际 APK/androidTest/插件哈希。
`workflow-api36-workbench-result.json` 与 `workflow-api28-recovery-result.json` 记录本轮
新建 D AVD 的 UI、工作台与权限/重启恢复；只有实际完成的记录才会标记 `passed=true`。
使用独立 ADB、ownership 与显式 serial，关闭范围限于该次新建模拟器。

Core C ABI/FFI/RPC 生产源码保持基线，MCP 修改位于测试区；App 业务、绑定和 Pub 锁的
113 项冻结文件保持原字节。C 原件与 Git 保护以
`workflow-final-compatibility-protection.json` 为依据；旧 D DS-001 App index 的历史字节差异
保留，其 149 项内容与标志一致。全局 GitHub URL 重写规则为零。

这是本地构建与受控运行验收，真实学校服务、ARM64 实机、远程 CI/规则与发布分别记录。
文档中的 C 盘工具、原件与历史证据路径按真实位置保留，不把历史结果改写成本轮验证。
