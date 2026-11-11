# 双仓库版本管理实施记录

## 迁移验收位置与基线（2026-11-10）

Core 主库为 `D:/Code/dansheng-core`，当时 main 基线提交为
`ac3d047ec3a269b52f21a80226b763c3838f5774`；App 主库为
`D:/Code/dansheng-app`，main 为 `e5ca0f33bfe6c7451cb10978baa4bd9a25a5bdc9`。
迁移任务在 `D:/Worktrees`，登记及独立缓存/profile/产物在
`D:/Code/dansheng-workspace/local`。DS-001 准备树已经迁到 D 盘，但仍未出生；
正常任务从真实 main SHA 创建，例如本次 `chore/DS-003-core-paths`。
工具链只读引用 D 盘 Core 主库安装；C 盘原件保留。现在新工作树由用户或 Herdr
创建到 `D:/worktree`，Agent 使用指定目录，自动准备运行资源并按请求提交/合并。
下列提交和 SDK 身份是历史基线，新的功能集成见 [Core 集成记录](core-integration-20261111.md)。

下面内容保留建立 main 与迁移之前的验收状态、C 路径和旧产物身份。
它们是历史证据，不表示当前主库尚无提交，也不能直接作为新的任务命令。
现行操作见 [开发工作流](DEVELOPMENT_WORKFLOW.md) 和 [发行入口](release.md)。

本次按用户提供的《Dansheng 双仓库多 Agent 版本管理实施规范》v1.0 实施。
记录的是本机实际结果；没有创建远程仓库、产品提交、PR、Tag 或部署。

## 路径与保护

| 项目 | 原目录 | 本轮写入工作树 | 分支 |
| --- | --- | --- | --- |
| Core | `C:/Code/dansheng` | `C:/Code/dansheng-workspace/worktrees/DS-001-repository-workflow/core` | `chore/DS-001-repository-workflow` |
| App | `C:/Code/dansheng-app` | `C:/Code/dansheng-workspace/worktrees/DS-001-repository-workflow/app` | `chore/DS-001-repository-workflow` |

两个产品 Git common directory 独立。普通父目录 `C:/Code/dansheng-workspace` 和
`C:/Code` 没有外层 `.git`；项目没有搬迁。主线尚无首次提交，准备工作树通过
Git `--orphan` 注册，共享各自原对象库，有独立工作文件、HEAD 和 index。它们不是
已提交的普通 PR 基线。Core 主索引原有204项 intent-to-add，没有当成真实提交。

原 Core 267项、App 149项保留快照和研究347项都与审计摘要一致。App 149项中包含
一份旧 Gradle 报告，保留文件和备份，但首次提交清单只含148项源码。研究目录仍为
保留的独立恢复快照，本任务没有将其整体覆盖或合入 Core。

## 阶段交付

| 阶段 | 实际内容 | 验证与剩余事项 |
| --- | --- | --- |
| 0 审计 | 真实路径、主线/索引、历史/远程、267/149快照、实际 C ABI/JNI/AAR/Pigeon 接入及备份 | 无产品主线提交/remote/tag；凭据与原产物保留 |
| 1 规则 | 两库 AGENTS/CLAUDE、开发流程、PR模板、忽略与文本规则；Git登记的准备工作树 | 原主目录未改；首次提交和主线集成仍需批准 |
| 2 工具 | Core `tools/workspace` 的 New/Status/Enter/Close、Bootstrap、PairChecks、SDK lock/validator；CI配置 | 41个真实 Git/文件系统/容器场景通过；App16场景通过；CI YAML解析通过，远程未执行 |
| 3 契约 | 采用已有原生 SDK 路线B；Core权威协议、精确源码/Adapter/Pub/native/resource摘要和稳定门槛 | 新两ABI SDK、源码及SDK-only核验、debug APK及包审计通过；真实SHA/发布获取位置与配对PR仍待基线/远程建立 |
| 4 并行 | 两个真实AI Agent在同一合成仓库的不同任务worktree写入 | 278/77次写入，区间重叠11.9872713秒；各自文件/index独立，fixture main/index不变 |

管理工具默认 dry-run，明确 `-Apply` 才写入；关闭另需 `-ConfirmRemoval` 和 owner，
并拒绝 dirty/untracked/ignored/链接目录。它们不执行自动 init、commit、fetch、push、
PR、merge、force、删分支或清运行数据。来源主库必须有真实提交、保持 clean；运行
目录隔离 Cargo/Pub/Gradle/npm、临时文件、Core profile、浏览器和 Android 用户目录。
Git 本地覆盖变量在原生调用前隔离；工作树不是操作系统权限沙箱。

## 验收

- Windows GNU Rust 1.99.1：fmt、381项 workspace/all-features/all-targets 测试、严格 Clippy通过。
- TS SDK：runtime facade和typecheck通过。
- PowerShell 7.6.9：Core41项工作流集成场景、App16项依赖路径/容器场景通过。
- Flutter 3.47.7 / Dart 3.13.5：63个手写Dart格式检查、analyze、133项Flutter测试通过。
- Pigeon 29.1.1：Dart/Kotlin重生与现有绑定逐字节一致，pubspec.lock未改。
- SDK：ARM64/x86_64原生构建通过；源码、Adapter、2个packaged FFI entries、7个资源和Pub锁核对通过；SDK-only也通过。
- APK：android-x64 debug构建和原生库/资源包审计通过；没有安装或运行设备，没有学校服务测试。

Rust仅修正旧MCP测试的错误分类，并明确断言13项登录/绑定/写方法不可暴露。
`#[cfg(test)]` 前11247字节生产代码逐字节相同；C ABI、生产过滤器和业务调用保持
原行为。App12项手写Dart只做formatter调整；固定Pigeon生成文件不另行手工格式化。

由于源摘要改变，实际重建SDK，AAR SHA256为
`af3bbfa49c7e78f27cab40db952a78141f72da7a745b2f02245b312514cb54c9`，59项输入摘要为
`ba160d52c1a583358fef9b232f547fec1ec4d1d9048d6cc52a49a402752bea4c`。新收据记录实际
packaged摘要，原 AAR/收据保留。当前 `commit=null`、acquisition为空，稳定发布门槛
正确拒绝；不能将本次开发包当作发布。

## 审核资料与待批准操作

仓库外审计/备份：`%LOCALAPPDATA%/dansheng-repository-management/20261110`。
完整源文件diff与变更清单：`C:/Code/dansheng-workspace/local/validation/final-review`。
测试/并行证据：`C:/Code/dansheng-workspace/local/validation`；构建与日志在 `local/runtime`。

首次主线提交计划只选原 Core267项和App148项已核验源码，不使用整个准备index，
不清理任何未提交/忽略数据。应由用户批准后创建各自首次本地main基线，并将已有
准备分支接到该基线，再审查本次维护变更。远程私库/规则、正常配对PR、主线合并、
不可变Tag/发布和研究迁移另行授权。Codex内部差异捕获引用在保护报告中单独记录，
不当作产品main提交，不自行删除或重写。
