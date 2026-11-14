# 统一 Agent 规范

适用于整个 Dansheng monorepo；模块细节见 ARCHITECTURE、DEVELOPMENT_WORKFLOW 和 CORE_COMPATIBILITY。个人本机 AGENTS.md/CLAUDE.md 只作为入口，不提交私人配置。

1. 动手前读任务说明，检查 `git --no-optional-locks status --short --branch`、绝对 Git common directory 和 `git worktree list --porcelain`。在用户提供或原生工具创建的单个任务工作树内工作；不直接编辑 main，不重复建立配对 Core/App 树。
2. 一个功能任务可原子修改 Core、App 和必要文档；明确文件范围，不借此重构无关模块。复杂任务最多并行三个子任务，文件写入范围互斥；主线程整合结果并独立验收。
3. 构建前自动 dot-source `scripts/Enter-Dansheng.ps1`，使用该工作树独立 runtime。新 Windows 工作树位于 `D:/worktree`，缓存、产物、日志、签名、模拟器数据留在 D 盘源码树外。共享只读工具安装可复用，私人 profile/凭据不得复制。
4. 业务和 API/ABI 权威属于 Core，平台宿主负责 OS 能力，UI 负责输入与展示。任何 UI 预校验不替代 Core 执行检查；保留真实认证页面执行语义。
5. 保持 Cargo/Pub/npm 锁文件，Pigeon 29.1.1 生成 Dart/Kotlin；Flutter 3.47.7 / Dart 3.13.5 / Rust 1.99.1。生成文件不手改；接口变更同时更新消费者、测试、兼容说明。
6. `core.lock.json` 仍准确锁定 native SDK。源码同仓库不代表 AAR 自动同步。源码联调需重建 SDK/receipt/lock；SDK-only 审阅明确报告它使用的历史 Core SHA。禁止改旧收据或虚构版本/SHA/CI 结果。
7. 先 diff review 和对应检查，再按用户授权提交、合并或推送。普通编辑不自动授权提交/发布；明确的合并任务可执行必要的本地整合。远程推送会触发发布时需属于明确授权范围。
8. 不 reset/clean/force-push、重写历史、改 tag、删除分支或工作树。保留别人 dirty/untracked/ignored 工作。迁移或清理必须有明确范围、可恢复备份和复核记录。
9. 登录、真实预约/取消、提交、支付、邮件、部署、物理设备和签名身份变更需要具体授权。超时的外部写入先对账再重试；日志和测试不暴露凭据。
10. 每项用户改动交付已签名 Android release 审阅 APK，默认 ARM64，使用已核验 SDK 和任务自己的 review identity，保留之前产物与身份。报告路径、版本、ABI、SHA-256 和实际验证；失败则报告准确阻塞，不能用 debug APK 替代。
11. 区分源码检查、native 编译、模拟器、真实服务读取、物理设备和远程 CI。配置文件与其他 worker 总结不是执行证据。历史 validation 与 workbench-workers 记录不可改写为本轮结果。
12. 交接报告工作树/分支、改动与 diff、命令结果、Core 依赖、APK、剩余阻塞和待授权操作。Antigravity 使用独立 conversation ID 与互斥文件范围；ID 和会话记录保存在源码外，不传私人 profile。
