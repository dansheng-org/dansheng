# Roadmap 原范围最终验收审计

2026-11-07 UTC，主线程接收。判据为 `docs/roadmap.md` 的 M0–M5 Scope、Required evidence、Evidence policy，以及 `AGENTS.md` 的边界。下面逐项区分实现、实际执行、跨编译和实时服务限制；没有把生产UI、Later项或未经授权的真实远端写入添加为门槛。

生产构建输入：57文件，SHA256 `425318a872c96a78c39eaddb40e2a525160a92e2347863e8065a6aec92c1931d`。主线程已独立核对代码、变更范围、Git diff、实际测试/构建日志、库/APK哈希、发布二进制和ZIP内容。没有以 worker 总结代替验收。

## 要求与证据

| Roadmap 原要求 | 当前实现与实际证据 | 接收结论与边界 |
| --- | --- | --- |
| M0：固定 DanXi/Dela/本地 sports 参考、归属、toolchain/CI/contracts | `reference/manifest.json`；两个公开checkout HEAD分别为3c1f5f0…与e82da12…，与清单一致且无新修改；本地选定sports快照、NOTICE/LICENSE、workspace/lock/toolchain/CI、implementation-contract均存在。 | 已接收。原DanXi三项既有生成/依赖改动未被覆盖；CI配置不冒充远程CI已运行。 |
| M0：Windows/Linux/Android真实Rust库、SQLite、QuickJS；区分编译与执行 | Windows349完整运行；Linux Core178/Host24/FFI2实际204项、C ABI smoke；Android最新x86_64 JNI native8/8及平台基线；ARM64双构建SO。 | 三平台实际执行已接收；ARM64仅交叉编译，未声称ARM64设备执行。 |
| M1：accounts/session broker、HTTP、auth challenge pause | `engine.rs`、`network.rs`、平台vault；真实DPAPI/Secret Service/Keystore历史原生证据；当前会话隔离/重启/注销、认证暂停与显式resume测试；真实Canvas/ecard使用记录。 | 已实现并接收。local_credentials_only不代表上游仍接受会话。失效Token不删除为“凭据不存在”，也不自动重复密码。 |
| M1：持久数据/任务、grants、JS install/run、UI-description、IPC/FFI/MCP及拒绝/取消/重启 | Store/Policy/QuickJS真实执行；Host自动timer与真实IPC；六项直接插件原子领取回归；同包release测试及真实MCP；平台ABI往返。 | 已接收。新增null转发与plugins.run/tick竞争修复均有实际复验；私有UI、来源和账号权限保持隔离。 |
| M1：同一JS包跨桌面/Android；login/data/save/query/UI-description/MCP闭环 | `plugins/fixtures/closed-loop`四文件包eb037…；Windows release与Android真实JNI/HTTP/SQLite返回共同归一结果556afa…；MCP读取相同来源、静态UI描述且不能提升权限；重开后数据保留、内存凭据消失。 | 已接收。Windows为实际release，最小PATH下执行；合成账号不冒充学校登录，Android不增加MCP服务。 |
| M2：Android页面上下文fetch/XHR、交互认证、账号切换、wake/foreground、官方sports | 系统WebView、原生JNI/pump、VisibleLoginPort、清理/撤销与账号绑定；AndroidWakePort/CoreJobWakeHost/JobWakeDispatcher；真实模拟器基线28不同instrumentation、5JVM，最新Rust相关8项重跑。 | 已接收Core/适配器范围。合成WAF和身份不证明真实学校WAF；生产可见登录/权限回调由宿主提供。 |
| M2：partial results、取消、deadline、reconciliation；无未经批准真实预约 | sports状态机与持久journal；JS状态机测试、真实JNI合成写入授权及未知结果阻断、Core不确定写入/可信对账回归。 | 已接收。没有真实预约、取消、付款；不会以验收为由执行这些动作。 |
| M3：UG/PG课表、考试/成绩、校园卡/QR、电费、空教室、占用率、体育、校车、通知 | `fudan.rs`/`campus.rs`/Core适配的实际传输、解析、授权、保存；来源形状/分页/错误契约；QR新增owner-only临时presenter交接及35项相关验证；ecard与通知实际读取。 | 原代码范围已实现并接收；并非所有校园源实时可用。身份、上游与网络限制见下。QR生产安全显示是宿主责任，不缓存或返回原码。 |
| M3：generic Canvas + Fudan配置；第二真实来源 | 原生Canvas课程/作业/文件/目录/模块/页面/公告、受限下载桥接；来源分区/分页与权限测试；真实Token曾读取13课程、47作业、96文件元数据等，另有ecard/公开通知。 | 第二真实来源证据已具备。当前Token返回401，不能沿用旧成功来称其当前可用；文件正文并未全部实读。 |
| M4：IMAP/MIME/SMTP、草稿/附件、UIDVALIDITY、中断同步 | 实际TLS MailService故障注入；断流、取消、epoch变更、FLAGS NO/BAD后保持旧commit并重开恢复；STORE OK/NO/BAD/EOF区分确认/待对账；附件/草稿/发送预览与idempotence回归。 | 已接收。匹配tagged OK后才提交，原错误提交/误标删除已修复。没有真实邮箱投递行为。 |
| M4：托管文件、下载恢复、全文检索/中文短词、TODO/calendar/ICS、activities、首次同步抑制 | Core assets/organizer/search真实SQLite及流式HTTP/Range/校验恢复；Unicode/PDF文本检索、短词literal搜索、时区/ICS、去重/通知抑制、恢复与权限测试。 | 已接收。不是仅缓存标题；通知/文件选择提供者属于宿主，无provider明确不可用。 |
| M5：签名catalog/install/update/rollback、grant变化、失败安装/迁移恢复、backup/restore、论坛/课程评价 | package/catalog签名与信任策略、阶段安装/历史恢复；私有KV事务迁移与反向快照；9项真实SQLite/QuickJS迁移用例；snapshot恢复后的授权/凭据绑定重置；community读连接器及来源测试。 | 已接收。生产目录服务/插件市场不作为额外门槛；SourceRecord、权限和来源身份保留。 |
| M5：来源/许可清单与可复现产物 | receipt核对当前源/实际二进制；Windows固定编译路径下空release缓存重建与首份哈希一致；ARM64两独立目录实际重编同hash；三个ZIP实际校验，重复打包hash逐项相同；解包的Windows EXE再次通过IPC/MCP/备份恢复。 | 已接收。Windows路径布局是明确条件，不宣称任意目录都同字节；ARM64不是clean build，也未执行。最终文档归档更新后仍需相同脚本再验证三ZIP。 |

## 当前批次身份

- Windows：`.local/release-current/workspace-claim-tests.log` **349/349**；workspace all-features/all-targets strict Clippy、fmt、SDK facade/TypeScript通过。
- Linux：`.local/linux-validation/20261107T001921Z-eac732f2/` 实际 **204**；未变连接器 **136** 沿用，合计340覆盖，不是重跑340。150文件清单 `ce55a04c3ddf0acda0702a8bb7459ea5852a962f7f291734342f2c0e91c71b3e`，父重新计算drift=0。
- Android：`.local/android-current/final-425/validation.json`；实际native **8/8**、原样一次43.103秒，库/APK身份匹配；基线28 instrumentation与5JVM不重复计数。旧7/8失败现场仍保留。
- 共同包 SHA256：`eb037c94a2bd146d0c7d50ec098597e99ba27f2c9ea7852f6bd70e1ec5b6bc1a`；结果SHA256：`556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`。
- Windows EXE：`90d2844af51216f505d241946b7e87f3f51ae1acd380e767426ea4995ae0fbab`；ARM64 SO：`cf92e6c3f3c330cb2e3ef0769defcf654d3204b52b7a20d24efca6a5e9b9a17d`。
- 归档、解包执行与重现报告：`.local/release-current/package-first-verification.json`、`package-repeat-verification.json`、`package-reproduction.json`、`unpacked-release-smoke.json`。最终交付以重新生成的 `dist/dansheng-core-0.1.0/SHA256SUMS` 与最后一次验证报告为准。

## 实时覆盖与范围结论

已保存凭据确实用于实际服务测试。当前Canvas保存Bearer仍在DPAPI，但独立Core profile GET401；此前真实课程读取保留为历史。ecard读取仍通过，余额不输出。academic本科入口500、lesson-search200；rooms需要VPN认证，明确一次WebVPN登录在open_service首请求超时，未自动重试。没有凭空归因、猜测用户角色或把失败变为成功空列表。详见 `validation.md` 与 `live-campus-triage.md`。

原范围的代码与平台/协议门槛已逐项接收。最终文档与归档重新校验完成后，可结束本开发任务；不将更新外部Token、所有学校接口即时可用或真实远端写入追加为原任务条件。完整的实时服务可用性、生产宿主UI/安全显示/通知/文件选择器及OEM行为仍需对应环境和宿主验收。

原文Later仍保持：图书借还、作业提交、视频/转录、桌面browser、macOS/iOS；不增加内置LLM/agent、SSH/终端、生产UI、云同步服务、Node或必带Chromium。未commit、push或远程发布。
