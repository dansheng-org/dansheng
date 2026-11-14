# Dansheng

本地优先的跨平台校园工作台。一个 Git 仓库、一套功能分支和 PR；Rust Core 与 Flutter App 保持独立模块边界和版本。

```text
apps/dansheng_app/   Flutter 应用：共享 Dart UI、Android 平台宿主
core/               Rust Cargo workspace、官方服务连接器、C ABI、平台 SDK、插件
docs/               全项目架构、开发和发布规范
scripts/            单仓库环境与检查入口
.github/workflows/  统一 CI 与受控发布
```

`apps` 按应用命名。Android 位于 `apps/dansheng_app/android`；未来 iOS、Windows 等宿主加入同一个 Flutter 应用，只有独立客户端才新增应用目录。当前 Android App 已实现，不能据目录结构推断其他平台已完成。

从已分配的 Git worktree 开始（PowerShell 7）：

```powershell
. ./scripts/Enter-Dansheng.ps1
./scripts/Check-Dansheng.ps1 -Component app
./scripts/Check-Dansheng.ps1 -Component core
```

Agent 自动执行环境准备；无需用户管理第二套配对工作树。工具链见 [开发规范](docs/DEVELOPMENT_WORKFLOW.md)，构建 SDK 与签名审阅 APK 见 [依赖与发布](docs/CORE_COMPATIBILITY.md)。首次环境准备可能下载公共依赖。

- [架构与平台边界](docs/ARCHITECTURE.md)
- [统一 Agent 规范](docs/AGENT_POLICY.md)
- [迁移与回滚记录](docs/MONOREPO_MIGRATION.md)
- [App 功能与历史验收](apps/dansheng_app/README.md)
- [Core 模块说明](core/README.md)

两模块原始提交历史完整保留，历史记录中的双仓库路径仅描述当时环境。GPL-3.0-or-later，详见各模块 LICENSE。
