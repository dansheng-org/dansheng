# 本机 agy worker 与代理环境

2026-11-06 已验证 `gemini-3.8-flash-high` / `high` 可从当前 Codex 工作区调用。

## 本次故障原因与证据

Codex 工具进程继承了 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`WS_PROXY`、`WSS_PROXY`，均指向本机 `127.0.0.1:10808`，并带有本地地址的 `NO_PROXY`。Windows 用户级和机器级环境没有这些变量，WinINET 代理关闭，WinHTTP 为 direct；v2rayN 的 sing-box TUN 仍然开启。

继承显式代理和去掉显式代理时，Cloudflare trace 返回了不同出口：前者为 IPv6/LAX，后者为 IPv4/SLC，均标记 US。去掉进程代理变量后，仍可由现有 TUN 接管流量，不能称为绕过 TUN 或裸直连。完整 IP 与观察值保存在忽略的 `.local/agy-network-fix/network-observations.json`。

在相同可执行文件、模型、账号和项目目录下进行对照：

| 调用 | 结果 |
| --- | --- |
| 继承 Codex 进程代理 | `FAILED_PRECONDITION (400): User location is not supported for the API use.`，退出 3，没有生成 token |
| 清除上述代理变量，续接原失败会话 | 退出 0，实际生成 README 总结并产生 token；JSON 仍携带历史地区错误及 `status: ERROR` |
| 修复脚本，新会话 | `SUCCESS`，退出 0，生成三句 README 总结 |
| 修复脚本，精确续接新会话 | `SUCCESS`，退出 0，返回指定验证短句，conversation ID 一致 |

因而已确认本次失败与继承的显式代理路径有关；两份 agy 安装路径都曾在该路径下失败，切换程序本身没有解决问题。Cloudflare 的位置标签不等于模型服务的位置判定，且不同目标域名可能走不同路由；不能仅凭此认定 Google 对某个具体 IP 或 IPv6 的判定机制。没有重置登录、修改全局代理、重启代理服务或轮换节点。

成功会话：`2f31e841-a2c5-462f-b9ea-f27d2bea2d0f`。原始输出、调用记录和独立审核结果分别保存到 `.local/workers/` 和 `.local/agy-network-fix/acceptance.json`。旧失败会话保留供审计；脚本不把“退出码 0 但 JSON 报错”直接当作成功。

## 固定调用入口

迁移后先进入已登记任务，worker 的新输出、会话 ID 和锁文件写到该任务 runtime 的
`workers/`。原 C 盘 `.local/workers` 和网络故障证据保留原文，下面的现行入口不续写
那份历史目录。仅在已经授权委派的任务中调用 worker。

```powershell
$runtime = $env:DANSHENG_TASK_RUNTIME
./scripts/invoke-agy-worker.ps1 -RuntimeRoot $runtime `
  -Name readme-review `
  -PromptFile (Join-Path $runtime 'tmp/readme-prompt.txt') `
  -Scope README.md
```

先将具体只读或限定文件范围的任务写入 PromptFile。脚本默认使用 PATH 中的 `agy`，也可通过 `-AgyPath` 显式指定程序；不再固定到另一份 `.gemini/bin` 安装。

默认 `-ProxyMode UserEnvironment` 将本次调用的代理环境恢复为 Windows 持久化的 User/Machine 设置，User 优先。该机器上两级均未设置，因此仅在调用期间移除继承的代理变量。脚本在 `finally` 中恢复调用者原值，不写注册表、不改系统代理或 TUN。此模式不执行交互终端的 PowerShell profile；需要保留调用者手动设定的代理时使用 `-ProxyMode Inherit`。

续接使用已保存的 ID：

```powershell
$session = Get-Content -Raw (Join-Path $runtime 'workers/readme-review-session.json') | ConvertFrom-Json
./scripts/invoke-agy-worker.ps1 -RuntimeRoot $runtime `
  -Name readme-followup `
  -ConversationId $session.conversation_id `
  -PromptFile (Join-Path $runtime 'tmp/readme-followup.txt') `
  -Scope README.md
```

脚本固定 cwd 为项目根，传递 `--add-dir`、`--dangerously-skip-permissions`、`--output-format json`、`--print-timeout 30m`、`--print`，保存每次输出与 conversation ID，并逐字核对续接 ID。文件锁阻止并行续接同一个会话。调用记录不保存代理凭据。

## 验收范围

主 Agent 检查了两次成功返回、精确续接 ID、真实 token 用量、README 原文、源码文件哈希和 Git diff。只读 worker 没有修改项目文件；本次修复只涉及调度脚本与相关说明。PowerShell 语法检查和 Git whitespace 检查通过，实测调用后代理环境恢复。未改 Rust/Android 业务代码，因此没有重复运行无关构建和测试。
