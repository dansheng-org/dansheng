# 本地指令、计划与 Orca 共享

这些配置只作用于维护者本机，不是公开贡献者获取源码的前提。主工作目录保存真实 AGENTS.md、CLAUDE.md 和 `.agent-private/`；公开规范仍在 architecture、development 和 plans 文档中。

## Git 本地保护

先检查跟踪状态，再修改当前仓库 **common directory** 中的 `info/exclude`。链接 worktree 的 `.git` 通常是文件，不要把它误当目录。

```powershell
git ls-files -- AGENTS.md CLAUDE.md CLAUDE.local.md .agent-private
git rev-parse --path-format=absolute --git-common-dir
```

本地排除项至少为：

```gitignore
/AGENTS.md
/CLAUDE.md
/CLAUDE.local.md
/.agent-private/
```

已有嵌套私有指令可在同一 exclude 中追加对应规则。不要为这些本机文件向公开 `.gitignore` 新增规则。Git common exclude 被同仓库的所有工作树共享，但不会随 clone 复制到另一台机器。

如果 `git ls-files` 返回这些路径，仅忽略无法停止跟踪；先保全并说明状态，在得到授权后单独处理索引。不要 force-add、删除原文件或重写历史。已公开的旧内容不会因为本地忽略而从 Git 历史消失。

```powershell
git check-ignore -v AGENTS.md CLAUDE.md CLAUDE.local.md .agent-private/ROADMAP.md
git ls-files -- AGENTS.md CLAUDE.md CLAUDE.local.md .agent-private
git --no-optional-locks status --short
```

预期 check-ignore 指向 common `info/exclude`，ls-files 不返回私有路径，普通 status 不显示这些文件。对不存在的测试路径，check-ignore 只证明规则匹配，不能证明文件已经建立。

## Claude Code 入口

CLAUDE.md 内容保持为代码块外的一行：

```text
@AGENTS.md
```

[Claude 官方导入说明](https://code.claude.com/docs/en/memory#import-additional-files)支持该语法；相对路径相对引用文件解析。写在 Markdown 代码块或行内代码中的 `@...` 不会被当成导入。不要在 CLAUDE.md 复制第二套规则，也不要将所有私有计划写成自动导入。

在新的交互会话运行 `/context`，检查 Memory files 中实际加载的文件。若导入路径解析到工作目录外，可能需要 Claude 的外部导入确认；共享符号链接与不同版本的路径处理应实际检查，不能仅凭配置推断。文件进入上下文不保证模型在所有情况下遵守规则。

## Orca Worktree Shared Paths

1. 在 Orca 中选择实际主仓库 **dansheng**，核对路径；不要选仍指向旧目录的历史登记。
2. 打开该仓库的 **Repository Settings**，找到 **Worktree Shared Paths**。
3. 添加以下三个相对主工作目录的条目，保存：

   ```text
   AGENTS.md
   CLAUDE.md
   .agent-private/
   ```

4. 不添加 credentials.txt、profile、数据库、缓存或签名目录。保存后可用 `orca repo show --repo path:<主仓库绝对路径> --json` 检查 `symlinkPaths`；应包含三项，而不是仅看到设置已保存的提示。
5. 只在维护者另行授权的原生工作树创建流程中验证新树。不要为本次文档任务新建或删除工作树。

CLI 版本可能不提供 Shared Paths setter。没有相应入口或无法访问 Orca 窗口时，完成 Git/文件保护，按上述 UI 步骤手动配置；不要直接改正在运行的 Orca 内部存储文件来冒充配置成功。

## 链接与同步验证

建立前检查主目录和目标文件，确认主目录保存真实内容；每个目标必须不存在，或与现有内容逐项比对并先备份。禁止覆盖其他任务的同名私有文件。

Windows 文件 SymbolicLink 需要相应权限或开发者模式，目录 Junction 与文件符号链接不是同一种机制。不要自动提权、改系统权限或用 hardlink/副本冒充完整共享。其他平台按实际符号链接机制核验。

```powershell
Get-Item '<worktree>/AGENTS.md','<worktree>/CLAUDE.md','<worktree>/.agent-private' -Force |
  Select-Object FullName,LinkType,Target
Get-FileHash '<main>/AGENTS.md','<worktree>/AGENTS.md'
```

选取自建的无秘密 probe 文件，在主目录写入、从两个消费者读取，再从一个消费者更新并从主目录和另一个消费者读取。只改该 probe，不拿已有计划或凭据试验。

必须分开报告：① Orca 配置已保存；② 链接指向正确主目录；③ 更新读取一致；④ 新建 Git worktree 的实际接入。普通目录探针只能证明文件系统能力，不是跨工作树端到端验收。

根 `scripts/Enter-Dansheng.ps1` 只会在缺少入口时生成简短指令，不会自动配置 Orca 或复制私人计划。完整共享应先由维护者配置。磁盘同步不等于运行中 Agent 自动重载，也不提供并发写锁；计划按 Owner 协调，重大指令更新应明确通知相关会话重新读取。
