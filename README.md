# Dansheng

本地优先的校园工作台，以 Flutter 应用、Rust 核心和受控插件连接校园服务。数据、账号权限和任务状态由本机管理，业务能力与界面保持模块边界。项目采用 GPL-3.0-or-later。

## 功能与平台

- **eHall**：校园卡、宿舍电量、教室、校车等校园服务，以及内置手动场馆流程。
- **eLearning**：课表与日历、Canvas 课程、作业和资料；服务分别处理认证状态。
- **本地资料与扩展**：带来源的搜索、用户主动开启的本机 MCP、论坛与插件管理。定时抢场以独立插件分发，默认关闭。

Android 是当前 Flutter 产品平台。Rust Host/CLI/MCP 提供 Windows/Linux 路径，不代表 Flutter 桌面客户端已实现。iOS、macOS、Web 客户端仍需单独设计和实施。校园接口可用性取决于服务、网络和账号；历史验收不等于当前实时可用。

## 技术栈与结构

Flutter 3.47.7 / Dart 3.13.5、Rust 1.99.1、SQLite、QuickJS；Android 使用 Kotlin/JNI、系统 WebView、Pigeon 29.1.1。依赖由 Cargo、Pub、插件 SDK 锁文件和 App 的 core.lock.json 固定。

```text
apps/dansheng_app/   Flutter 应用；lib/ 共享界面，android/ 平台宿主
core/               Rust workspace、官方连接器、原生 SDK、Host 与插件
docs/architecture/  当前架构、接口和平台边界
docs/development/   贡献、环境、构建与测试
docs/plans/         公开设计方案与历史计划索引
scripts/            本地环境和检查入口
.github/workflows/  CI 与 Android 预发布
```

Core 实际位于 core/；App 业务界面主要在 lib/ui/campus/。目录以源码为准，不要求存在示意中的 packages/dansheng_core/ 或 lib/features/。

## 安装、构建与运行

Android 审阅包从 [GitHub Releases](https://github.com/dansheng-org/dansheng/releases) 获取，核对该版本的 SHA256SUMS、ABI 和发布说明。当前发布为开发快照的 Pre-release；账号连接与插件启用由用户在应用中操作，见 [App 使用说明](apps/dansheng_app/README.md)。

首次 clone 先按 [本地配置](docs/development/local-agent-setup.md#git-本地保护)保护生成的本机文件；该本地设置不会随 clone 复制。随后从仓库根准备 PowerShell 7 环境并检查源码：

```powershell
. ./scripts/Enter-Dansheng.ps1
./scripts/Check-Dansheng.ps1 -Component app
./scripts/Check-Dansheng.ps1 -Component core
```

首次使用需安装固定工具链和准备公共依赖。Android 构建还需与 core.lock.json 匹配的原生 SDK；同仓库源码不会自动更新旧 AAR。SDK、签名构建与运行见 [贡献指南](docs/development/contributing.md)，本地 Host 服务见 [Core README](core/README.md)。

## 文档与贡献

- [整体架构](docs/architecture/overview.md) · [App](docs/architecture/app.md) · [Core](docs/architecture/core.md) · [插件](docs/architecture/plugin-system.md)
- [贡献指南](docs/development/contributing.md) · [测试规范](docs/development/testing.md) · [SDK 兼容契约](docs/CORE_COMPATIBILITY.md)
- [公开方案](docs/plans/README.md) · [Core 原范围验收](core/docs/roadmap-completion-audit.md)
- [单仓库迁移](docs/MONOREPO_MIGRATION.md) · [App 历史验收](apps/dansheng_app/docs/workbench-validation.md)

后续重点是现有服务可靠性、源码与 SDK 的可追溯联调，以及按实际需求实现新平台宿主。具体范围以相应方案和验收标准为准。欢迎按贡献指南提出可复核的变更；问题、代码和测试中不要附带凭据或私人校园数据。

许可见 [App LICENSE](apps/dansheng_app/LICENSE) 与 [Core LICENSE](core/LICENSE)；原始 Git 历史和来源归属保留。
