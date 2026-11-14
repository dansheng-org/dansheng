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
