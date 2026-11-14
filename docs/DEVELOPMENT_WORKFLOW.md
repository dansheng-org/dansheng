# 单仓库开发规范

唯一活动产品仓库为 `D:/Code/dansheng`；Git 根包含 `core` 与 `apps/dansheng_app`。两模块属于同一个 Git common directory。原双仓库、研究快照、配对管理数据进入外部备份；不要在备份开展新功能。

## 分支与工作树

保持一个 main。一个功能、一份短期分支/PR、一个原生管理的工作树。优先使用 Orca/Codex/Claude 原生 worktree；Orca 新任务基目录为 `D:/worktree`。已有工作树保留，迁移后的 main 为新任务基线，不把旧布局分支直接当新功能工作树。

一个任务内 Core/App 可原子变更并一起评审。不同工作树的未提交修改不共享。不得在另一个 agent 的树写入；并行修改要划定文件所有权。DS 编号、TASK.md 和额外管理登记均非必要。

`core/tools/workspace` 中旧 New/Close 配对工作树管理器仅用于历史恢复；native SDK 生产、锁和验证器仍是有效工具。新任务从仓库根 `scripts/Enter-Dansheng.ps1` 进入，不再要求两套 repo。

## 环境与检查

```powershell
. ./scripts/Enter-Dansheng.ps1
./scripts/Check-Dansheng.ps1 -Component app
./scripts/Check-Dansheng.ps1 -Component core
```

进入脚本不创建 Git 分支或工作树，不复制私人数据；自动设置当前 worktree 的 Core、工具和独立 runtime、Cargo/Pub/Gradle/临时目录。工具安装路径通过 `DANSHENG_TOOLCHAIN_ROOT` 指定，非 Windows 可使用已安装 Rust 工具链。离线模式需要先准备公共依赖缓存。

Flutter 3.47.7、Dart 3.13.5、Pigeon 29.1.1、Rust 1.99.1；Android 使用项目锁定的 JDK/Gradle/AGP/SDK/NDK。保留 `apps/dansheng_app/pubspec.lock`、`core/Cargo.lock`、`core/sdk/package-lock.json`。不可为了通过构建无审查更新依赖。

App 检查格式、analyze、test 和 Pigeon 生成一致性；Core 检查 fmt、test、clippy 及受影响 SDK/平台。跨模块契约变更运行双方检查，另建 native SDK 和签名 APK。文档迁移也必须验证构建入口没有失效。CI 配置在根 `.github/workflows`；模块内部旧 CI 文件仅为历史布局，不作为活动入口。

## SDK、运行与发布

见 [依赖规则](CORE_COMPATIBILITY.md)。选择 SDK-only 或本树源码重建必须明确，不允许环境探测悄悄把源码切换为其他工作树。每份产物和测试记录绑定 commit、内容摘要及工具链；工作区 dirty 状态要如实记录。

每次交付 signed release APK；任务 review 身份与正式签名隔离。模拟器仅使用任务拥有的新数据目录；live services 和物理设备仍需具体授权。未执行平台不得标记通过。

提交前执行 `git diff --check` 并审阅具体变更；按路径暂存，不包含本机 AGENTS/CLAUDE、credentials、缓存或签名。跨模块变更用同一提交/PR，模块版本可独立；破坏性 API/ABI 或数据迁移单列兼容与回滚计划。

本地合并、远程推送、CI、Pre-release 与稳定发布是不同动作，分别报告。推送 main 可能触发现有自动 Pre-release，不以“迁移完成”代替发布授权。
