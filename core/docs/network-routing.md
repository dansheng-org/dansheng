# Core 应用级网络路由

通用实现位于 `dansheng-core::network_routes` 与 `Network`，复旦地址编码和允许目标位于可选 `dansheng-connectors/webvpn`。不把学校域名或认证协议写进通用 Core，也不改变系统 VPN、代理注册表或浏览器网络栈。

## 账号与路由配置

仅 owner 可以调用 `http.routes.set/get`。每个账号保存最多 64 个精确 origin 映射：

```json
{
  "account_id": "account-id",
  "routes": [{
    "provider": "fudan.webvpn",
    "origin": "https://forum.fduhole.com",
    "gateway_prefix": "https://webvpn.fudan.edu.cn/https/ENCODED_HOST",
    "mode": "auto"
  }]
}
```

上例是协议形状示意，不是可直接发送的完整地址。实际 prefix 由官方适配器生成。`direct` 直接请求，`gateway` 使用已配置网关，`auto` 优先直连，并仅在 GET/HEAD 尚未建立连接的失败后尝试一次网关。已明确配置的私有 IP 资源可预选网关；普通直连仍执行原有 private-network 权限检查。HTTP 401/403/500、响应读取中断以及任何写操作都不触发跨路由重发。

配置保存在 `core:network-routes`，重启后加载。备份/恢复清除这类网络授权，防止从快照恢复一个未重新确认的外发网关。配置变更进入会话指纹，避免沿用其他路由条件下的断点下载状态。

## 两个地址与两层认证

- 调用者仍传原始资源 URL；先按原站 origin、账号及当前授权检查，再转换为实际 HTTPS 网关地址。
- 网关的 DNS、TLS 和目标 IP 仍验证。插件不能直接请求已配置网关域名来绕过原站权限。
- 网关 Cookie 按账号和网关 origin 隔离；不把原站 Cookie 直接塞入网关 Cookie 头。
- 连接器明确区分 Cookie、Bearer 和匿名资源。Bearer 模式缺少 Token 时不能改用 Cookie；匿名资源可使用账号的网关认证，但直连时不会附带原站凭据。
- 对外响应 URL、Location 和分页 Link 转回逻辑原站地址；未配置的网关路径失败关闭。网关登录重定向明确要求重新认证。
- 单个资源返回 401 不删除整个 origin 的会话：部分服务用 401 表达资源访问限制。失效与重新登录由认证层处理；显式 logout、替换和 Cookie 到期仍生效。

WebView 的页面上下文请求保持原平台端口；本模块不把页面 fetch/XHR 替换为 Rust HTTP。IMAP/SMTP 也不经这个 HTTP 网关路由，整机隧道属于系统/平台层。

## 本机验证入口

`manage-lab.ps1` 在宿主内部读取已经加密保存的凭据，命令参数不含学号、密码或 token：

```powershell
./scripts/manage-lab.ps1 -Action login -Target webvpn
./scripts/manage-lab.ps1 -Action webvpn -Mode auto
./scripts/probe-lab.ps1 -Probe network_routes
./scripts/probe-lab.ps1 -Probe rooms
```

默认目标沿用 DanXi 白名单。显式 `-Origins` 可指定适配器接受的复旦资源 origin；身份认证入口和 WebVPN 本身不能成为循环路由目标。`-Mode direct` 关闭所选映射的网关传输。真实网关登录或资源读取失败必须保留为失败，离线映射测试不证明真实校内可达。

测试包括独立 AES-CFB 向量、URL/分页反向映射、原站权限检查、账号隔离、Cookie/Bearer 类型隔离、真实本地 TLS 网关、连接失败只读回退和 HTTP 500/写操作不重发。真实测试报告另存仓库外的本机 reports 目录。

## 复旦 WebVPN 开关：全部 fudan.edu.cn 服务

`fudan.webvpn.configure {mode}` 把开关语义固定在 Rust 侧：

- `gateway`（App 的“开”）：`webvpn::FUDAN_ORIGINS` 里每个 fudan.edu.cn 服务（以及内网空教室 `http://10.64.130.6`）一律经 WebVPN；`direct`（“关”）一律直连。树洞（fduhole.com）不属于开关范围，开启时保持 `auto`，只在直连失败时回落。
- `FUDAN_ORIGINS` 由单元测试 `fudan_origins_cover_every_connector_address` 守护：连接器源码中出现的任何 fudan.edu.cn 地址都必须在列表里（身份认证 id/uis 与 WebVPN 本身除外），新增服务漏配会直接测试失败。
- 网关只携带 WebVPN Cookie，站点会话保存在 WebVPN 服务端。实测（2026-11-15）WebVPN 会话不会把 UIS 单点登录带进被代理站点：elearning、fdjwgl、ecard、zlapp、my 经网关都会跳到被代理的 id.fudan.edu.cn 登录页。因此开启后各服务的登录也必须经网关完成：
  - `login::login_via_gateway` 复用同一 UIS 登录流程，只替换传输层：逻辑 URL 编码为网关地址，响应 `Location` 和页面内被网关改写的链接（`webvpn::decode_text`）还原为逻辑 URL，原有的跳转目标、票据和口令重放检查保持不变；成功后导出更新后的 WebVPN Cookie。
  - `uis_sign_in` / `canvas.uis.login` 在目标源为 `gateway` 时走网关登录；WebVPN 会话缺失或过期时用同一 UIS 口令先登录 WebVPN 再重试一次（口令已提交后不再重试）。
  - 云盘默认使用 UIS 口令，但可在云盘单独修改：Android 宿主依次尝试已保存的云盘口令、已保存的 UIS 口令（云盘拒绝过的 UIS 口令以摘要记录，不再重发），仅在云盘明确返回 `InvalidCredentials` 时才弹窗；`Timeout`/网络错误原样上报，不弹窗。`fudan.cloud.login` 与 `canvas.token.bind` 在 WebVPN 会话缺失时返回 `WebVpnLoginRequired`，由宿主先登录 WebVPN 再重试。
  - 云盘会话独立于 WebVPN 会话：直连会话不随开关进入网关。云盘在无会话时以 200 和空 protobuf 应答 `/user`，Core 将其报告为 `AuthenticationRequired`（空目录列表同样先核对会话），宿主据此在 WebVPN 内重新登录云盘。
- 数据请求遇到网关跳往被代理的身份认证页时，`decode_location` 已返回 `AuthenticationRequired`，宿主据此重新登录（经网关）。
- 树洞的登录不经过 WebVPN，网关会话缺失或过期不能报成树洞 `AuthenticationRequired`：宿主会据此丢弃已保存的树洞口令并重新索要。树洞令牌仍在而请求被网关拒绝时（`forum_actions` 的读取，以及连接器传输层对 `FORUM_ORIGINS` 的 Bearer 读取）返回 `WebVpnLoginRequired`，宿主只用已保存的 UIS 口令恢复 WebVPN 会话后重试该读取。
- `community.tea.login` 是幂等的登录请求，不产生远端写入：直连没有得到应答（或树洞路由为 `gateway`）时改经 WebVPN 发送；发送前先用一次 GET 确认网关会话仍有效，缺失或过期返回 `WebVpnLoginRequired`。没有应答的登录报网络错误，不报 `NeedsReconciliation`。发帖、回复仍然不跨路由重发。
- 部分校园查询用 POST 发送（电费历史与统计、图书馆和食堂人数等）。Network 把所有 POST 当写入，没有确认的应答报 `NeedsReconciliation`；连接器传输层对 `.read` 能力改为按读取处理：被重定向说明会话被送去登录，报 `AuthenticationRequired`（宿主登录后重读），其余报 `Timeout`，可直接刷新。真正的写入能力（`.write`）不变。宿主登录后的第一次重读若仍被弹回，会稍等后再读一次再报错。
- Engine 在服务调用发出 POST 后比对账号会话指纹，指纹变化即报 `NeedsReconciliation`（"service session changed after dispatch"）。指纹覆盖账号的全部来源，页面刚登录时另一个服务登录写入新会话就会触发，表现为"登录后提示待核对、刷新即好"。这项核对只用于写入；`.read` 服务改为只重查授权，授权变化报普通错误。
- 树洞楼层的修改（`community.tea.floor.modify`，`PATCH /api/floors/{id}/_webvpn`）与删除（`community.tea.floor.delete`）重复执行结果不变，没有应答时报网络错误；举报（`community.tea.report`）不可重复，保留 `NeedsReconciliation`。三者都只限本机所有者，并由 Android 宿主逐次确认。
- 限制：cookie-CSRF 写操作（Canvas 网页会话发信）按原设计拒绝网关路由；一律走网关后需改用 Canvas 令牌。

实测入口（只读，凭据仅在进程内读取）：`DANSHENG_TEST_CREDENTIALS=<file> cargo test -p dansheng-connectors --features services,webvpn --test webvpn_live -- --ignored --nocapture`。树洞在 WebVPN 开启、网关会话缺失和强制经网关三种情况下的登录与读取用 `--test forum_webvpn_live`。
