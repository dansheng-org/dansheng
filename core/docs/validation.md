# dansheng-core 验收记录

冻结源码：`425318a872c96a78c39eaddb40e2a525160a92e2347863e8065a6aec92c1931d`（57 项 Rust/manifest/头文件构建输入）。工作区 `C:/Code/dansheng`，2026-11-07 UTC。完整源码归档还包含文档、SDK、平台适配与测试，其清单单独计算。

这是与生产 UI 分离的开发版 Core。验收范围按 [roadmap](roadmap.md) 与 [逐项审计](roadmap-completion-audit.md)；原文的 Later 项、真实预约/付款/发信和生产 UI 不被追加为本仓库门槛。实时校园验证、合成协议测试、模拟器执行及交叉编译分别记录。

## 当前代码与平台证据

| 层次 | 本次接收结果 | 证据与边界 |
| --- | --- | --- |
| Windows workspace，all features | **349 passed，0 failed** | `.local/release-current/workspace-claim-tests.log`，完整命令执行；不叠加历史轮次 |
| Windows 格式与静态检查 | **通过** | fmt；`.local/release-current/workspace-claim-clippy.log`，workspace/all-features/all-targets，`-D warnings` |
| Linux 当前源码覆盖 | **340 项覆盖通过** | 本轮实际 Core178 + Host24 + FFI2 = **204**；源码完全相同的连接器 **136** 沿用，未声称重跑340项；[Linux报告](linux-validation.md) |
| Linux C ABI / clippy / fmt | **通过** | 真实 ELF/C 链接与调用，`C ABI smoke passed`；冻结快照 `20261107T001921Z-eac732f2`；父独立复算150文件，drift=0 |
| Android 最新 Rust/JNI | **8/8 passed** | 同一专用 API36 x86_64 AVD `emulator-5588`，原样一次运行43.103秒，无重试归一；[Android报告](android-sports.md) |
| Android 平台基线 | **28 个不同 instrumentation 用例、5 JVM 用例** | 基线全套27 + 新闭环1；当前仅重跑受Rust变化影响的8项，未把纯Kotlin/WebView/Keystore基线伪称全套重跑 |
| Android ARM64 release | **交叉编译，两份SO字节一致** | 当前SHA256 `cf92e6c3f3c330cb2e3ef0769defcf654d3204b52b7a20d24efca6a5e9b9a17d`，16,313,648字节；两个独立缓存目录实际重编，非clean build；未执行ARM64 |
| SDK | **通过** | `.local/release-current/sdk-final.log`，50方法/14命名空间与TypeScript编译 |
| Windows release 重建 | **字节一致** | 独立保留首份产物，固定编译路径从空release缓存重建；SHA256 `90d2844af51216f505d241946b7e87f3f51ae1acd380e767426ea4995ae0fbab` |
| 归档与解包执行 | **通过** | 三ZIP逐文件/二进制/清单/许可核验，重复包hash相同；实际解包的Windows EXE完成IPC/MCP/备份恢复 |

Linux 150项清单 SHA256：`ce55a04c3ddf0acda0702a8bb7459ea5852a962f7f291734342f2c0e91c71b3e`。两种清单范围不同，不能互换。源码、工具和依赖已独立核对，原 `C:/Code/danxi` 的三项既有生成/依赖改动保持原状，公开参考 checkout 的 HEAD 与 `reference/manifest.json` 一致且无新改动。

## 验收中发现并修复的问题

- `Response.result:null` 经 IPC 反序列化后被当作字段缺失，导致桌面和 Android 返回语义不同。现在保留显式 null，错误响应仍无 result。
- async-imap 的 FETCH/LIST 流结束不能证明命令成功。现按相同命令 tag 的 `Done/OK` 确认完成；EOF、NO/BAD、错误 tag 或 BYE 不推进同步游标，也不将缺失 FLAGS 误当远端删除。真实 TLS 中断/取消/UIDVALIDITY恢复、明确拒绝及 STORE 的 OK/NO/BAD/EOF 均已验证；[中断证据](mail-interruption.md)。
- Android 发现 `plugins.run` 创建 scheduled 行后被后台 tick 先领取：任务虽成功，调用方却收到 `JobNotRunnable`。现创建和领取同事务提交，保留原始权限、活跃去重和取消保护；6项竞争/撤权/取消/未来任务/冲突回归及原始 Android 失败用例通过。
- [插件私有 KV 迁移](plugin-storage.md)按授权/账号分区执行，失败整批回滚并禁用插件；代码回退、数据恢复及反向恢复快照有实际 SQLite/QuickJS/重启验证。
- [QR 呈现](qr-presentation.md)从官方连接器将临时二维码交给可信平台端口，owner-only，不进入普通返回值、来源缓存或 MCP；未提供/宣称生产 presenter UI，不付款、不自动同意条款。

## 同一 JS 包与 release 验收

共同四文件包为 `plugins/fixtures/closed-loop/`，包 SHA256：
`eb037c94a2bd146d0c7d50ec098597e99ba27f2c9ea7852f6bd70e1ec5b6bc1a`。

实际 Windows Host/IPC/QuickJS/SQLite/MCP 与 Android JNI/原生loopback HTTP 都执行过同一包：认证挑战、不提前联网、会话导入、取数、私有及 canonical 存储、查询、UI描述、关闭重开后的持久性。MCP获得授权后读取同一来源及静态UI描述；动态私有UI和授权修改仍受限。这是合成身份，不能当作真实学校登录。

两端递归排序后的共同结果 SHA256：
`556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`。

Windows 最终 release 的同包、IPC/MCP、备份/恢复均已实际执行通过，使用不含开发工具链的最小 PATH。`shared-package-release.log`、`shared-package-final-comparison.json` 与 `host-release-smoke.json` 位于 `.local/release-current/`；其中记录真实被执行二进制的哈希，可与随后复现及打包产物直接比对。MCP读取同一profile的来源/待办、拒绝自行授权、恢复后保留数据并清除授权均已确认。归档内容另外由 `verify-package.ps1` 检查。

## 保存凭据的真实读取

凭据、会话密文和业务数据仍在仓库外 `%LOCALAPPDATA%/dansheng-lab/profiles/manual`。只读报告也保存在其同级 reports 目录；不导出原始页面、认证头、Token、余额或课程内容。

- Canvas Token 曾验证与保存账号一致，DPAPI持久化、重启后读取13门课程及原生同步任务通过。内容检查读取47项作业、96个文件元数据、39个目录、20个模块、4个页面和12条公告；没有据此声称下载全部文件或遍历全部详情。
- 同批3门课文件接口鉴权失败，11门课页面列表404，均保留失败状态。
- **当前复测**：保存的Bearer仍存在，独立内存Core会话访问固定Canvas profile接口返回 **401**。不能继续宣称当前Token可用，也未改成密码Cookie登录或自动创建远程Token。可用 `scripts/set-canvas-token.ps1` 在本机隐藏输入有效Token。
- 校园卡余额只读接口通过；不展示余额数值。公开教务通知曾真实读取14条。
- 本科 course-table 三种 Accept 均500；lesson-search入口200并识别101个学期选项，不等于课表成功或用户身份分类。
- 空教室拆分两个固定GET后均需要认证；配置为Auto，不从配置推定实际网关分支。一次WebVPN登录在 open_service、首次请求阶段超时，没有自动重试。

最新只读汇总：`%LOCALAPPDATA%/dansheng-lab/reports/final-core-readonly.json`。用户角色、学校网络及上游限制按 [静态排查](live-campus-triage.md)另列；不以校园卡成功推定其它来源全部成功，不把500/401等错误转换成成功的空数据。

## 产物与边界

按 [发布流程](release.md)生成 Windows Host、Android ARM64核心库和对应源码 ZIP；要求当前源码 receipts、两份匹配产物、固定ZIP元数据、源码/许可清单及归档内容校验。包内不含Node、Flutter、Chromium或真实profile。Windows验证固定编译时路径，以移走并保留首份 release 缓存、从空 release 缓存重建来比较；不宣称任意路径布局下的MinGW导入表都会一致。

测试没有执行真实预约、取消、付款、发邮件或作业提交。学校WAF、真实交互登录和系统通知/文件选择器的生产宿主接入不由合成页面证明；缺失平台能力明确返回 `CapabilityUnavailable`。Linux真实Secret Service与Android Keystore的历史原生验证保留在对应平台记录中，未混计为本轮重新执行。
