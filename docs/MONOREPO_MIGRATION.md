# 2026-11-14 单仓库迁移

## 来源与保全

用户明确授权合并仓库、统一规范及将 D:/Code 下其他 Dansheng 目录移入备份。此次仅执行本地迁移，不推送、不归档远程 Core、不创建远程发布。

| 来源 | 导入提交 | 处理 |
| --- | --- | --- |
| App main | `c61a5148e2c7315f48d6ae77fd99e025ec188ac3` | App 作为主历史，目录移入 apps/dansheng_app |
| Core main | `1501cc28e120f8a2dae9402d5d2de72629b33bad` | 非 squash subtree 导入 core，保留原始提交对象与父链 |

已检查并 fetch 两仓库：eHall、elearning、ecard 已提交分支均进入对应 main。`feat/webvpn` 工作树仍有 `core_adapter.rs` 和 `webvpn.rs` 两项未提交修改，未自动整合或丢弃。App 两个旧功能树原有 AGENTS/CLAUDE 暂存删除状态保留。

外部备份根为 `D:/Backups/dansheng-migration-20261114`：

- `app.bundle`、`core.bundle`：迁移前全部 Git refs 与历史，均通过 `git bundle verify`。
- `app-main-source.zip`、`core-main-source.zip`：精确旧 main 源码归档。
- `webvpn-uncommitted.patch`：两项修改的 binary diff；原工作树继续保留。
- `before.json`：旧 HEAD、worktree 登记与修改状态。
- `dansheng-core`、`dansheng-workspace`、`dansheng-fudan-service-research-20261110`：迁移收尾时原目录原样移入；不删除内部私人数据。
- `app-local`：原 App 根的旧构建、私人本机文件和其他未跟踪内容，逐项保留；不进入提交或发布。

工具安装迁移到 `D:/DevTools/dansheng-rust`，作为只读公共工具使用。新任务缓存与产物位于 `D:/DevCache/dansheng/runtime/<checkout-hash>`，不借用旧 profile/签名。

## 当前布局与历史解释

最终主目录 `D:/Code/dansheng` 为真实 Git 工作目录，取代旧的 Core junction。现有已注册工作树路径保留，Git common directory 指针在主目录移动后 repair；旧 Core 工作树指向备份 Core repo。旧历史工作树不自动转成新布局，新的功能任务从统一 main 创建。

迁移任务为 `migration/monorepo`，工作树 `D:/worktree/dansheng-app/monorepo-migration`。历史路径有意不改名。源码结构、CI、native 路径解析、模块根校验和运行资源隔离均适配 monorepo。所有本机 AGENTS/CLAUDE 入口不跟踪；公共规则在 `docs/AGENT_POLICY.md` 版本化，根 Enter 为新 checkout 生成无私人内容的入口。

采用非 squash subtree 仅为一次历史导入；日常开发不再 subtree pull/push，不使用 submodule。Core 和 App 仍可独立版本发布，但跨模块功能在同一 PR 原子接收。

## 验证与限制

逐项真实运行结果与工件记录补充于 [迁移验证](MONOREPO_VALIDATION.md)。旧 validation/workbench-workers 文档与旧 CI 文件保留为历史，不能替代本次执行。

本次审阅 APK 消费原 `core.lock.json` 的 development_snapshot；它不证明导入 Core main 新增 ecard 代码已编入 APK。源码联调入口与 SDK 锁工具已适配模块目录，未来 Core 改动必须实际重建 SDK。模拟器、真实服务、物理设备与远程 CI 未由此迁移自动授权。

## 回滚方法

保留当前目录及本轮 diff/产物后，从 bundle 在另一个新目录恢复所需旧 repo/branch，或查阅备份旧 main ZIP；不要 reset/clean 当前仓库。旧 Core repo 及其 dirty WebVPN 工作树可继续用于恢复未完成工作。需要恢复主目录布局时先停止相关任务，核对所有工作树 dirty/untracked/ignored 数据，再按 `before.json` 反向迁移并运行 `git worktree repair`。旧签名身份只从原备份位置显式选择，不被 review identity 替换。
