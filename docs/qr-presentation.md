# 临时 QR 交接（M3）

`fudan.qr.present` 将校园卡二维码仅交给可信宿主 presenter。它不提供生产 UI、不付款、不自动接受条款，也不向调用者返回原码。`fudan.qr.status` 保持原有 `Ready` / `TermsNotAccepted` 状态语义。

## 协议与权限

协议依据：只读固定参考 `reference/DanXi/lib/repository/fdu/qr_code_repository.dart`，DanXi commit `3c1f5f026fbc7ca50e151865f813cdb381807abe`，Copyright (C) 2021 DanXi-Dev，GPL-3.0-or-later；沿用该文件的 GET `https://ecard.fudan.edu.cn/epay/wxpage/fudan/zfm/qrcode`、`#myText[value]` 和 `#btn-agree-ok` 条款标记。学校端点与解析仍仅在官方连接器中。

- 请求：`{"method":"fudan.qr.present","params":{"account_id":"<host-owned account>"}}`。调用身份由可信适配器绑定；JSON 参数不能指定 owner。
- 独立 capability：`fudan.identity.present`；仅精确 `Principal::owner()` 可调用。给普通客户端、MCP 或插件授权此 capability 也不能展示。`.read` 不授予展示权限。
- 现有 MCP 只收录 `.read` 官方服务，因此不暴露此方法；现有 native job 的 read/sync 检查拒绝它。未修改 Core、Host、MCP 或 SDK。
- 在请求二维码之前检查平台 advertise `credentials.present`，否则 `CapabilityUnavailable`，不联网。没有登录会话时沿用现有 HTTP 会话挑战，不自动登录。
- 只使用现有 HostSession HTTP 协议，不是浏览器会话的降级替代。保留账号的 Direct / Gateway / Auto 路由及全局 WebVPN 配置。官方客户端只调用一次 GET，无 QR 业务重试循环；网络层沿用现有 Auto 在连接尚未建立且返回 NetworkUnreachable 时的切换规则，不因本接口另行禁用 Auto。

## 数据流与返回值

服务在通用来源登记/缓存路径之前返回。实际官方客户端执行一次固定 GET，检查响应后解析内容，再发起一次：

```text
ServiceContext.platform.call("credentials.present", {
  principal, grant,
  input: {
    kind: "qr",
    account_id,
    origin: "https://ecard.fudan.edu.cn",
    payload: <临时二维码内容>,
    display_for_ms: 30000
  }
})
```

HTML 接受上限为 256 KiB（通用网络接收层仍有原有 8 MiB 上限），解码后的 payload 上限为 4096 UTF-8 字节。要求唯一 `#myText`、非空 value，拒绝控制字符、多个码、超长/非 UTF-8/缺失字段。条款标记优先：即便同页有二维码也返回 `TermsNotAccepted`；没有提交条款的请求路径。HTML实体由解析器解码，内容不作为脚本、HTML或可导航 URL 执行。

内部 `QrPresentation` 为 crate-private、单次消费类型，无 `Debug`、`Serialize`、`Clone`，不是可导出的 source model。仅在可信 platform 调用边界转为 JSON payload。二维码不进入 source records、KV cache、events、jobs 或返回值；Core 的现有审计仅记方法/结果元数据。没有二维码哈希、预览文本、上游 HTML 或 JSON 的返回接口。

宿主回执必须包含布尔 `presented`。服务只返回 `{"presented":true或false,"kind":"qr","display_for_ms":30000}`，丢弃其他字段。宿主错误的 code/message 均不透传，统一为固定 `PresentationFailed`；平台等待超过 30 秒为固定 `PresentationTimeout`，不会重试。取消/超时不等于证明二维码从未显示，不触发自动再次展示。

`display_for_ms` 是**本地显示上限**，不是服务器有效期或支付有效性的声明。这里没有承诺进程内存的完全清零：HTML解析器、通用 HTTP 与平台 JSON 都会有短暂分配；未新增 zeroize 依赖，也不以普通内存释放冒充安全擦除。

## Presenter 必须实现的责任

只有能兑现以下约束的可信宿主才应 advertise `credentials.present`；本变更不附带 UI/provider：

- 校验绑定身份、账号与来源，在当前受信任账号的前台、安全显示上下文呈现；不能将 payload 转发给 MCP、JS 插件或其他进程中的普通调用者。
- 将 payload 仅作为二维码数据渲染，不执行内容，不进入日志、遥测、剪贴板、持久缓存、通知、恢复快照或崩溃附件；按平台能力采用安全窗口/防后台快照措施。
- 从接受展示起用单调时钟限制最多 30 秒；用户取消、账号切换/退出、视图销毁或宿主进入不安全后台状态时立即隐藏并丢弃内容。尚未完成的平台 future 被取消/drop 或超时也必须触发清理；如果正常返回回执后仍在显示，宿主必须继续持有并执行上述计时与取消责任，不能留下无人管理的展示。
- 返回 `presented:true` 只表示本地呈现，false 表示未呈现/用户拒绝；不得宣称上游核验成功。不得自动续期、重新 GET、支付、同意条款或重复展示。需要再次展示时由 owner 新发起操作。

## 离线验证与复现

`core_adapter.rs::qr_presentation_tests` 在真实 Engine（含审计和临时 SQLite）内运行同一个生产交接函数、官方客户端 GET 与真实 HTML 解析；仅替换外部 `ConnectorTransport` 和平台 presenter。fixture 断言固定 URL、GET、HostSession、一次请求/一次交接，并检查返回/事件/任务/来源行及关闭后的合成 profile 文件没有合成原码。覆盖非 owner、缺 provider、条款/歧义/空/超长页、带 payload 的恶意回执/错误、传输失败无业务重试、取消释放、Auto 配置不阻止交接。它不是校园网络、底层 Auto 回退或操作系统显示实测；网络层既有测试负责回退规则。

`tests/qr_presentation.rs` 另经真实 `CampusService` 注册与 Engine 分派验证 owner/provider 边界、独立 capability 和 native job 拒绝。`tests/campus.rs` 验证原 status 序列化/Debug 不泄露合成原码。所有数据为新建临时 fixture，不读取真实 QR、凭据或用户 profile。

Windows 本地命令（隔离目标目录，不操作父线程 release 产物）：

```powershell
. ./scripts/dev.ps1
$env:CARGO_TARGET_DIR='C:/Code/dansheng/.local/qr-presentation-target'
cargo test -p dansheng-connectors --features services --locked --offline --lib qr_
cargo test -p dansheng-connectors --features services --locked --offline --test campus --test qr_presentation
cargo clippy -p dansheng-connectors --features services --all-targets --locked --offline -- -D warnings
rustfmt --check --edition 2024 crates/dansheng-connectors/src/campus.rs crates/dansheng-connectors/src/core_adapter.rs crates/dansheng-connectors/tests/campus.rs crates/dansheng-connectors/tests/qr_presentation.rs
```

2026-11-06 最终 Windows GNU 离线结果：QR 单元测试 **6/6**（含 Auto 放行）、campus 回归 **28/28**、真实 CampusService 边界集成 **1/1**；上述严格 clippy 与四文件 rustfmt 检查通过。合计 35 个不同测试，不将早期轮次叠加。首次原码落盘检查在打开 SQLite 时遇到 Windows 文件锁，已修正为关闭该合成 profile 后检查；最终轮次全通过。未运行真实服务、Android、Linux 或 release 复验；产物刷新由主线程负责。

本任务 Rust 文件已 freeze，SHA-256 如下；没有修改 Cargo.toml / Cargo.lock 或 Core/Host/MCP/SDK：

| 文件（相对 `crates/dansheng-connectors/`） | SHA-256 |
|---|---|
| `src/campus.rs` | `7a3f820dc8683a82ac5543ab25cf1fc6090864a6d8eeba188f99833c5cdf9879` |
| `src/core_adapter.rs` | `25a168e3a24c5c945d2561325f3cd1c77e7950f2d56bf7236bb62aaad8e3b9ac` |
| `tests/campus.rs` | `ce9d6f7f7a3d48cc1efacbc39989426cff3923d4c617bd26d3f5d53a970f0dd4` |
| `tests/qr_presentation.rs` | `05b6ae2fad0d2dc8732986279eedb3e01a772fbffe5593fe41c2f3d80eaf3cc4` |
