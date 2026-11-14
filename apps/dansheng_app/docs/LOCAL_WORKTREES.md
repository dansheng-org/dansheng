# 本地工作树与私有文件

Dansheng 主仓库为 D:/Code/dansheng，所有新任务使用同一个 monorepo 的 Git worktree；Orca 基目录设为 D:/worktree。既有旧布局工作树保留作历史恢复，不自动改写。

公开规则在根 docs/AGENT_POLICY.md、docs/DEVELOPMENT_WORKFLOW.md 和 docs/CORE_COMPATIBILITY.md 中版本化。根 scripts/Enter-Dansheng.ps1 在缺少入口时生成简短、本地的 AGENTS.md 与 CLAUDE.md；不覆盖已有本机指令。Agent 启动时应先读这些文档并自动进入环境。

本机 AGENTS.md、CLAUDE.md、credentials.txt 由 .gitignore 排除，不应 force-add。旧提交中可能仍存在历史指令，迁移不重写旧历史。原个人指令与凭据保留在迁移备份，不进入产品源码、CI、SDK 或 APK。

新仓库不需要共享 credentials.txt。只有具体任务确有授权时才从原受保护位置访问凭据；共享路径不等于登录授权。Orca 可选共享无秘密的本机 Agent 入口，设置变更后必须检查实际链接目标，不能只凭 UI 配置宣称已生效。运行中的 Agent 不保证自动重载指令。

Windows 符号链接需要开发人员模式或相应权限；不为普通环境准备自动开启设备门户、发现服务或提权。已经存在的本机文件不能被共享链接直接覆盖。

构建资源遵循根入口的 owner.json：当前 worktree 独占外部 runtime，不能放在任何注册的源工作树内，也不能复用其他任务的签名、profile 或数据库。Git worktree 隔离不等于运行时隔离。

旧 Orca 会话/工作树登记作为历史记录保留；新功能使用新注册的 Dansheng 主目录和已合并 monorepo main。维护者尚未执行的 UI 设置或远程配置不得写成已验证事实。
