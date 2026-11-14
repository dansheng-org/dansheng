# 原生复旦服务研究探针

独立的开发研究工具，直接复用当前 dansheng-core Engine/HTTP 和官方 login 模块。不是已接入的生产业务，也不加入发布 workspace。依赖使用独立锁文件，默认构建和测试目录建议放仓库外。

## 构建与离线检查

在用户或 Herdr 提供的 Core 工作树中，PowerShell 7；主仓库为 `D:/Code/dansheng-core`。
构建目录和报告选择该任务的独立 D 盘 runtime，参考 [开发工作流](../../docs/DEVELOPMENT_WORKFLOW.md)：

```powershell
. ./scripts/dev.ps1
if (-not $env:DANSHENG_TASK_RUNTIME) { throw '先选择当前任务的独立运行目录' }
$researchHome = Join-Path $env:DANSHENG_TASK_RUNTIME 'research'
$researchTarget = Join-Path $researchHome 'build-target'
[void][IO.Directory]::CreateDirectory($researchHome)
cargo test --manifest-path tools/fudan-service-research/Cargo.toml --locked --offline --target-dir $researchTarget
cargo clippy --manifest-path tools/fudan-service-research/Cargo.toml --all-targets --locked --offline --target-dir $researchTarget -- -D warnings
cargo build --manifest-path tools/fudan-service-research/Cargo.toml --locked --offline --target-dir $researchTarget
```

## 运行

report 的父目录必须已存在，报告路径必须是新文件并在源仓库外。工具创建独立 Core profile，不复用 App/正式 Host 的账户或会话。

```powershell
$researchExe = Join-Path $researchTarget 'debug/fudan-service-research.exe'
& $researchExe --mode public --report (Join-Path $researchHome 'public-new.json')
& $researchExe --mode discovery --campus-lan --report (Join-Path $researchHome 'discovery-new.json')
& $researchExe --mode services --report (Join-Path $researchHome 'services-new.json')
& $researchExe --mode canvas --credentials 'C:/Code/dansheng-app/credentials.txt' --report (Join-Path $researchHome 'canvas-new.json')
& $researchExe --mode canvas-session --credentials 'C:/Code/dansheng-app/credentials.txt' --report (Join-Path $researchHome 'canvas-session-new.json')
```

模式：

- `public`：固定公开入口、配置和目录；不读凭据。
- `discovery`：已发现的 eHall 目录/匿名任务边界、本科目录/详情/大纲和云盘网络条件；不读凭据。
- `services`：直接调用当前已注册的公开 Core 方法，检查动态学期、分页、课程缓存投影、大纲、eHall目录、图书馆空查询及公共培养方案；只输出记录/缓存/章节计数与错误码，不导出业务数据，不读凭据。
- `canvas`：使用已提供 Bearer，先验证固定 profile 和账号。只有同一账号验证成功，才读首门可见课的经典测验、讨论、本人 enrollment 和作业分组；不提交。
- `canvas-session`：显式选择独立研究 profile 的一次 Canvas UIS 密码登录和原生 Cookie 模式；profile 必须核对为指定本人后才调用已注册学习方法。它不会从 `canvas` 自动切入，不替换 App 的 Bearer，也不宣称这是 BrowserSession。
- `academic`、`ecard`、`life`、`webvpn`：现有固定 LoginTarget 的单次密码流程及固定 GET 结构；只取得候选会话不等于业务通过。
- `all`：公开范围、Canvas 和上述顺序认证。InvalidCredentials/InteractiveLoginRequired 后停止剩余密码目标，不自动重试或切换 Canvas 认证方式。

`--campus-lan` 只用于匿名 public/discovery：在新建的私有研究 profile 中使用 Owner 的 `http.policy.set`，精确允许 `https://cloud.fudan.edu.cn` 解析到校园私网。仍保持 allow_private_network=false，不修改其它 profile、系统网络或普通 MCP grants。

开课探针的 semester=527 是 2026-11-09 从公开页面取得的研究样本；它不是生产学期发现算法。课程与大纲编号只从这页真实数据取得，并验证为非零数字 ID；诊断 URL 用占位符，不输出实际课号。

## 凭据与输出

兼容 App 的 `user/password/canvasToken` 键格式，只在进程内读取；忽略 forum 的 danxiuser/danxipassword，不执行论坛登录。Token、密码不作为命令行参数或环境变量。凭据结构没有 Debug/Serialize。

会话以 persist=false 导入新 Core，仅在内存使用；工具不承诺进程内存完全清零。报告只含 HTTP 状态、白名单 MIME/schema 键、结构计数、固定错误码、脱敏重定向类别与认证阶段。不会写上游 body、headers、个人字段、Cookie、Token 或签名链接。账号匹配未知为 null，明确不同才是 false。

所有业务探针固定 GET，不接受任意 URL、method、请求体或任务；官方 login 模块的 POST 只用于认证。本轮没有预约、取消、选课、评教、作业提交、邮件、充值、支付、挂失或审批动作。

运行失败/身份不明不会写成成功空结果；研究报告也不把页面200、session_candidate或默认页面列表当完整业务验收。报告中的 campus_lan_origins、credential_file_read 和 coverage 可以用来核对本次实际使用的条件。
