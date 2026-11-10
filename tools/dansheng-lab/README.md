# Dansheng 本地实验台

独立开发宿主：同源静态 Web UI + 本机 Rust HTTP 服务，直接调用真实 `dansheng-core` Engine 与官方连接器。它不是生产 UI，也没有开放任意 Core RPC。

## 启动与停止

在项目根使用 PowerShell 7：

```powershell
./scripts/start-lab.ps1
```

首次构建后，脚本隐藏启动本地服务并在默认浏览器打开一次性授权链接。默认地址 `http://127.0.0.1:19764`，只绑定 IPv4 loopback；端口被占用时不会终止其他进程。`-Port 0` 自动分配空闲端口。`-SkipBuild` 使用已构建程序，`-NoBrowser` 仅启动。

默认数据目录为 `%LOCALAPPDATA%\dansheng-lab\profiles\manual`，与源码、DanXi 及正式 Core profile 分离。可用 `-Profile` 指定另一个仓库外的测试目录。程序拒绝把 profile 放进当前源码工作区。

```powershell
./scripts/probe-lab.ps1 -Probe status
./scripts/probe-lab.ps1 -Probe core
./scripts/probe-lab.ps1 -Probe ecard_balance
./scripts/stop-lab.ps1
```

重新运行启动脚本会复用正在运行的实例并生成新的一次性打开链接，不重置账号。停止通过本机管理令牌调用实例自身，不按不可靠的 PID 直接杀进程。后台日志只含启动地址或固定错误码，位于 `%LOCALAPPDATA%\dansheng-lab\logs`。

## 用户录入

1. 在页面输入完整学号与统一认证密码，点击 **加密保存凭据**。保存成功后表单清空；页面仅显示脱敏账号提示，不触发学校登录。
2. 选择学术教务、Canvas 或校园卡，点击 **验证登录并导入会话**。凭据只用于所选预设学校 HTTPS 登录链路。
3. 运行对应只读测试。只有私有业务读取成功才说明会话可用于该业务；公开通知和本地 Core 状态通过并不证明学校认证成功。

凭据通过复用 Host 的 Windows DPAPI vault 加密保存。SQLite 只保存随机账号 UUID、通用标签及读取到的业务缓存，不保存完整学号或密码。更换学号会创建新的账号 UUID，避免复用上一个账号的数据；重新保存密码会清除旧会话。**清除凭据与会话** 不删除已获取的业务缓存。

本期测试入口：Core 状态、教务公开通知、教务学期列表、Canvas 课程、当前账号缓存。校园卡可以尝试导入会话，尚无专用结果展示入口。没有预约提交、取消、付款、发邮件按钮；也没有任意 URL、任意方法或原始 vault 读取接口。

本机脚本另支持 `ecard_balance` 校园卡只读查询，以及 `academic_diagnostics` 脱敏请求对照。后者只请求四个固定教务地址/请求头组合，输出 HTTP 状态、响应大小、标准 MIME 类型、固定 DOM 计数和已知错误类别；不返回页面原文、Cookie、URL 票据或个人字段。它仅允许本机管理令牌调用，浏览器会话不能访问，也不提供任意 URL 输入。

### Canvas 访问令牌

用户可在本机终端运行 `./scripts/set-canvas-token.ps1`，隐藏输入令牌。它不会接受明文令牌命令行参数，也不会写入临时文件或环境变量；结果仅输出验证/保存状态。`./scripts/probe-lab.ps1 -Probe canvas_diagnostics` 可单独检查已保存 Bearer 是否存在、固定 profile 接口的 HTTP 状态及身份响应是否有效，原码与个人字段不输出，不更改当前账号的令牌或认证模式。

可信本机宿主可通过管理接口 `POST /api/canvas/token` 绑定用户提供的 Canvas 访问令牌。请求体为含 `token` 字段的 JSON；不要把真实值写入命令行、源码或日志。普通浏览器会话不能调用此入口。

绑定前通过固定的 Canvas profile 接口验证令牌，并匹配当前保存的账号；身份不符或验证失败时保留原会话。验证成功后，令牌进入仓库外的 Windows DPAPI vault，连接器切换到 `host_token`，重启后继续使用。实验台不会替用户创建远程令牌。再次执行 Canvas 密码登录会替换为 Cookie 会话，验证令牌时无需执行该登录操作。

`./scripts/probe-lab.ps1 -Probe canvas_content -CourseIndex 0` 直接调用 Core，检查指定课程的作业、文件、目录、模块、页面和公告，以及首个可用模块/页面的详情。输出仅包含数量、错误码和可用的数字 HTTP 状态；不输出课程名称、内容或资源标识。某项资源失败不会清除整个来源的令牌，也不会自动切换认证方式。

空教室失败可用 `./scripts/probe-lab.ps1 -Probe rooms_diagnostics` 拆分参考协议中的两个固定 GET。它沿用现有路由，仅输出数字状态、白名单 MIME/错误类别及结构计数；`configured_route_mode` 是配置，`actual_route:null` 表示当前响应不暴露实际分支，不能据此认定请求经过网关。上述诊断均只允许本机管理令牌，浏览器会话不能调用。

## 登录与验证边界

`dansheng-connectors/login` 为独立可选特性，参考固定版本 DanXi 的 UIS/NEO 登录协议。默认 Host/FFI 的 `services` 特性不会因此自动引入登录适配。原本需要 WebView/WAF 的体育功能不走这个原生 HTTP 登录入口。

验证码、短信或其他二次认证返回明确的 `InteractiveLoginRequired`，当前实验台尚未接入交互式认证。浏览器中的学校 Cookie 不会自动转移到这里。学校协议变化、校园网要求或代理路径也可能影响真实结果；离线测试与页面可用不代表真实账号已通过。

密码尝试无自动重试；服务串行处理保存、删除、登录，并对登录按钮调用间隔设置 45 秒限制。所有请求有大小与超时界限。用户实际录入前，只使用合成凭据验证存储与 UI，未提交任何真实校园密码。

## 本地访问与敏感信息

- 凭据、SQLite、会话密文和 `lab-control.json` 均在仓库外的私有目录；不要把整个 profile 复制进仓库或上传为报告。
- 浏览器首次打开通过 URL fragment 取得一次性启动 token，立即清除 fragment，再换成 HttpOnly、SameSite=Strict Cookie。API 有精确 Host/Origin、CSRF、JSON body 限制；未授权页面不能读取状态或操作凭据。
- 页面资源完全本地，无 CDN、第三方脚本或浏览器存储。响应设置 no-store、CSP 与禁止 iframe 嵌入。后端不记录请求体、请求凭据、认证票据或上游原始错误。
- `lab-control.json` 中的随机管理令牌用于本机脚本重开页面、查询限定测试和停止服务。它受文件 ACL 保护；管理接口仍然不能读取原始密码。
- `probe-lab.ps1` 仅输出状态、记录数、耗时和脱敏错误码，不把课程等个人结果打印到聊天。个人结果只在页面的折叠详情中显示。
- 启动子进程的代理设置遵循 Windows User/Machine 环境，避免继承不同的 Codex 进程代理；不修改注册表、系统代理或 TUN。

DPAPI 和 loopback 服务不构成抵抗同一 Windows 用户下恶意程序的独立安全边界。该环境只用于当前用户的本机开发测试。

## 开发验证

```powershell
. ./scripts/dev.ps1
cargo test -p dansheng-lab --locked
cargo test -p dansheng-connectors --features login --lib login --locked
cargo clippy -p dansheng-lab --all-targets --locked -- -D warnings
node --check tools/dansheng-lab/static/app.js
node --test tools/dansheng-lab/tests/frontend.test.mjs
```

HTTP 测试使用真实 loopback 服务器；Windows 合成凭据用真实 DPAPI，检查密文、SQLite 无凭据明文、重启恢复及清除。来源校验、一次性 bootstrap、CSRF、体积限制和拒绝未列入的远程写操作均有覆盖。真实学校验证要在用户录入后另行记录，不能与这些测试混称。

当前 Work 设置关闭了本地浏览器自动化，因此未进行浏览器渲染/点击验收。前端行为用离线 DOM 替身执行真实 `app.js` 验证：bootstrap 清除、凭据提交后清空且不触发登录、私有业务状态区分，以及会话失效后保持禁用。这不等同于浏览器端到端测试。

首次交付记录（2026-11-06）：4 项 HTTP/DPAPI 集成测试、4 项前端行为测试、21 项登录模块离线测试通过；登录筛选命令另匹配并通过了 1 项已有 IMAP 测试。Clippy `-D warnings`、Rust 格式和 JS/PowerShell 语法检查通过。启动/复用/停止脚本已实测；独立 smoke profile 经本测试台调用真实 Core 获取了 14 条公开教务通知。当时实际用户 profile 尚未录入，日志与独立审核记录在忽略的 `.local/lab-work/`。

用户录入后的功能验收直接经本机接口调用 Core，不依赖浏览器点击。后续真实账号检查报告放在仓库外 `%LOCALAPPDATA%\dansheng-lab\reports`，仅记录检查结果、统计数量和脱敏错误。`SourceHttpError` 保留来源 HTTP 状态，`SourceSchemaChanged` 仅包含编译时定义的来源/字段名，便于区分上游 HTTP 失败和本地解析失败。
