# 本地工作树与私有文件

产品源码与维护者的本机 Agent 指令、凭据分离，不需要另建 GitHub 配置仓库。
仓库可见性由维护者另行管理；本地共享设置与自动发布流程不改变 GitHub 仓库可见性。

## 本机布局

主目录为 `D:/Code/dansheng-app`。Orca 的 App 仓库工作树基目录设为 `D:/worktree`，
只影响以后由 Orca 创建的工作树；既有工作树与其他工具的默认目录不会因此迁移。

Orca Repository Settings 的 Worktree Shared Paths 包含：

```text
AGENTS.md
CLAUDE.md
credentials.txt
```

`AGENTS.md` 是主要指令源，`CLAUDE.md` 只包含 `@AGENTS.md`。凭据不进入文档、日志、
SDK、APK 或发布附件；共享文件不构成登录或服务操作授权。

Git common directory 下的 `info/exclude` 使用根路径规则忽略这些文件，以及个人指令覆盖。
该排除文件由同一仓库的 worktree 共用，不会推送到远程。仓库 `.gitignore` 则负责可公开的
缓存、构建产物和临时状态分类。

## Windows 链接权限

Windows 上的文件符号链接需要开发人员模式或创建时的管理员权限。设置 Shared Paths
不会自动授予系统权限。维护者可在 Windows 设置搜索“开发人员模式”后手动启用。
远程设备门户和设备发现不是本地文件共享的前提。

Windows/Linux 的符号链接读取相同源文件；普通编辑后的内容由各工作树共同看到。
已运行 Agent 的上下文不保证即时更新，应新建会话或明确重新加载指令。

## 现有工作树与版本接收

已存在的同名文件必须先比较和备份，再从索引停止跟踪并建立链接。不要直接覆盖某个
工作树特有的指令或凭据。`git rm --cached` 只准备停止跟踪的暂存变更，本地文件保留；
该删除仍需通过正常提交与接收流程进入各分支。忽略规则对已跟踪文件无效。

旧提交仍含有旧指令文件。基于旧提交创建工作树时，Git 可能再次检出它们，阻止共享路径
建立；应先接收停止跟踪的变更，或在该工作树明确处理索引与备份。停止跟踪并不会删除
远程历史，本轮不重写任何分支或历史。

检查使用 `git ls-files -- AGENTS.md CLAUDE.md credentials.txt`、`git check-ignore -v -- …`
和文件的 LinkType/Target。不能只看设置已保存就宣称实际链接成功。

新克隆不会携带 `info/exclude`、Orca 设置或本机文件；需由维护者重新提供本地配置。
Core 仓库的指令与凭据不通过 App 的共享路径配置混用。
