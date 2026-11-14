# 本地工作树与私有文件

当前配置方法统一到 [本地指令与 Orca 共享](../../../docs/development/local-agent-setup.md)。主工作目录保存真实 AGENTS.md、CLAUDE.md 和 .agent-private/；指令与计划由 Git common info/exclude 保护，不依赖公开 .gitignore。

共享目标为 AGENTS.md、CLAUDE.md 和 .agent-private/，不包含 credentials.txt、profile 或签名。配置保存、链接建立、更新可见及新工作树接入必须分别验证；运行中 Agent 不保证自动重载。

本页保留兼容链接。历史路径和旧工作树情况见对应日期的迁移记录，不将已归档记录作为新任务配置。
