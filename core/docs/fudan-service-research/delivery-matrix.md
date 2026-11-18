# dansheng-core 本轮完整交付需求与验收矩阵

本页保留 2026-11-09 研究批次的范围和证据；其中的分支状态、源码摘要、路径和测试数
只属于当时的独立研究副本。转入正式 Core 历史后的接口兼容性、当前构建与主线集成
另见 [Core 集成记录](../core-integration-20261111.md)，不复用旧产物身份作为新版本证明。

核对日期：2026-11-09。分支 `codex/fudan-service-research`，尚无首次提交。当前生产输入66项，冻结摘要 `fdbaeab6fda9ab71025830d32de05899b1310fd589aff79efc45069da97e5945`；完整摘要以[最终分层验证](final-validation.md)及构建 receipts 为准。主线程已接收 Windows/Linux 全量与公开服务实读，Android 和发布阶段分别接收。研究发现、生产方法、平台执行与本人业务结果在本矩阵分列，尚未接入的网站不会因通用基础完成而消失。

## 范围与状态定义

原始范围以 [roadmap](../roadmap.md) 的 M0–M5 为准：通用 Rust Core、官方连接器、受控 JS 插件、桌面 Host/MCP、C ABI 和 Android 平台适配。生产 UI 是独立项目。研究中出现的网站功能并不自动成为“已实现”服务；协议发现、生产接线、组件测试、平台执行、账号实读和发布归档分别记录。

| 标记 | 含义 | 可接受证据 |
| --- | --- | --- |
| 已接收历史基线 | 2026-11-07 的 M0–M5 曾独立接收 | [最终原范围审计](../roadmap-completion-audit.md)及其绑定日志/源码指纹；只适用于该批次 |
| 已接线，整体验收待收 | 当前源码存在 CoreService 方法和调用分发 | 实際读取注册表、分发、持久化/ACL；还需当前批次测试和执行 |
| 代码已接收，平台分列 | 当前冻结输入通过 Windows/Linux 全量及原生桥接测试 | Android、发布和真实账号实读仍按各自证据接收 |
| 仅连接器/组件 | 类型化客户端与离线测试存在，宿主入口未证实 | 客户端源码和对应组件日志；不能据此声明 UI/MCP 可用 |
| 实施中 | 已有局部改动，主线程尚未接收 | 不计为已完成；待文件、差异、测试及接线独立核对 |
| 公开协议已实测 | 无凭据 GET 得到期望业务 schema | 当前方法、来源、状态、分页/结构摘要；不等于生产连接器已实现 |
| 协议候选/待本人验证 | 仅公开页面脚本、官方手册或认证入口 | 未观察的请求参数、身份、分页和返回 schema 标为 unverified |
| 外部障碍 | 当前网络/认证/上游限制阻止实读 | 记录实际阶段和状态，不能转换为零数据/假成功，不能套用别站或另一学段 |

`docs/requirements-audit.md` 是 2026-11-06 的历史过程核对，包含当时未完成的 Linux、同包和 Canvas 扩展项。它不能覆盖 2026-11-07 的最终接收，也不能证明本轮新源码通过。[本轮研究验证](validation.md)中的“Core 源码未改变”只适用于研究工具批次；现在已进入实施，不能继续作为新连接器的身份结论。

## 原 M0–M5 能力与本轮复验门槛

| 稳定 ID | 必需能力 | 当前实现落点 | 历史接收与本轮必须收的证据 |
| --- | --- | --- | --- |
| BASE-M0-REF | DanXi、Dela、选定本地体育快照固定；许可证/NOTICE；不污染只读参考 | `reference/manifest.json`、`LICENSE`、Cargo workspace/lock、CI、`docs/implementation-contract.md` | 历史已接收；本轮核对参考 HEAD/工作树、新增来源归属、工具链及构建输入。CI 文件存在不代表远程 CI 执行 |
| BASE-M0-RUNTIME | Windows/Linux/Android 实际加载 Rust、SQLite、QuickJS | `crates/dansheng-core`、Host、FFI、Android adapter | 历史三平台执行已接收，ARM64仅编译；当前新增文件/依赖需新平台批次，不沿用旧二进制 |
| BASE-M1-AUTH | 账号/会话代理、平台 Vault、明确认证挑战及暂停恢复 | `network.rs`、Host security/platform、Android Keystore、`login.rs` | 历史会话/撤销/隔离证据；本轮扩展凭据类型、origin、页面身份和账号切换需负向复验，不从“凭据已加载”推定学校登录成功 |
| BASE-M1-POLICY | 调用者、账号、来源、域名及插件授权交集；本地 IPC/FFI/MCP 不提升权限 | Core policy/store/services、Host frame/security/mcp、FFI | 当前新增业务方法必须检查注册能力、来源 ACL 和账号；MCP/任务目录只暴露合格方法，配置/登录/二维码/可信对账仍排除 |
| BASE-M1-JOBS | 持久任务、取消/重启/期限/去重、直接插件原子领取、未知写结果对账 | `engine.rs`、`store.rs`、`native_jobs.rs`、`tests/immediate_plugin_jobs.rs` | 历史竞态修复已接收；新服务可计划性、权限撤销、部分/错误结果、真实 timer 与 IPC 需当前源码复验 |
| BASE-M1-JS | 无 Node 的 QuickJS 插件、同包跨端闭环、声明式 UI 描述 | `src/plugins`、`plugins/fixtures/closed-loop`、SDK、`ui.publish` | 历史 Windows/Android 同包结果匹配；新冻结批次重跑相关闭环，合成身份与真实学校身份分列 |
| BASE-M2-PAGE | 已认证页面 fetch/XHR、可见登录、账号切换、唤醒/前台与学校体育策略外置 | `platform/android/adapter`、`plugins/fudan-sports`、`plugins/builtin/fudan-venues` | 历史模拟器已接收；通用页面请求的新接线需绑定/撤销/超时/缺能力测试。真实学校 WAF、OEM 灭屏行为与生产 UI 回调仍单列 |
| BASE-M2-WRITE | 体育取消/期限/部分结果及不确定写入保存与对账 | sports journal、Core reconciliation、Android PersistentMutationGate | 历史离线/模拟器已接收；未经具体授权不以验收名义做真实预约、取消或付款 |
| BASE-M3-FUDAN | 本研课表、考试/成绩、卡务/QR、用电/房间、空教室、占用率、体育、校车、通知 | `fudan.rs`、`campus.rs`、`energy_history.rs`、`core_adapter.rs` | 原范围历史已接收；当前源码回归。真实各源逐项记录，学校卡务成功不能代替其它来源 |
| BASE-M3-CANVAS | 通用 Canvas 来源配置、课程/作业/资料/目录/模块/页面/公告、受限下载 | `canvas.rs`、CoreAdapter、托管 assets | 原范围历史已接收；本轮新增学习方法另见下表，当前 Token 401 不用历史读数宣称可用 |
| BASE-M4-MAIL | IMAP/MIME/SMTP、草稿/附件、UIDVALIDITY、断流/NO/BAD/EOF、STORE未知结果 | `src/mail`、Core assets、`docs/mail-interruption.md` | 历史 TLS 故障注入已接收；本轮依赖/凭据代理修改后运行必要回归。SMTP接收、最终投递和未知结果分开；无实际外部邮件投递 |
| BASE-M4-ORGANIZER | 文件/Range恢复、全文与中文短词、TODO/日历/ICS、活动/通知抑制 | `assets.rs`、`organizer.rs`、`search.rs`、相应集成测试 | 历史已接收；新来源内容/权限不能绕过 files/mail/source 分类。通知和文件选择器由平台提供 |
| BASE-M5-PLUGINS | 签名目录、安装/升级/回滚、信任/授权变化、私有KV迁移/快照 | `plugins/package.rs`、`catalog.rs`、`plugin_storage.rs`、SDK | 历史已接收；新方法不能让 JS 访问原始凭据、任意FS/DB/原生模块。私有KV与canonical来源/organizer/assets不是同一迁移对象 |
| BASE-M5-BACKUP | 备份恢复、授权/凭据绑定与路由重置 | `backup.rs`、store binding epoch | 历史已接收；新敏感头配置纳入恢复清洗，不能恢复后静默复用系统 Vault 中的旧身份 |
| BASE-M5-COMMUNITY | 茶楼/蛋壳查询及已存在受控论坛动作 | `community.rs`、`forum_actions.rs` | 来源/账号/写权限仍独立；社区课评不等同学校官方评价任务 |
| BASE-M5-RELEASE | 对应源码/许可/架构、可复现构建、确定性ZIP及解包运行 | `scripts/build-*-release.ps1`、`package.ps1`、`verify-package.ps1` | 本轮当前源码生成 receipts 和独立匹配产物；旧dist不能配新源码清单，具体门槛见发布表 |

## 本轮新增 Fudan/Canvas 服务交付面

| ID | 能力/方法 | 当前静态状态 | 已有证据和仍需证据 |
| --- | --- | --- | --- |
| NEW-FDU-CATALOG | `fudan.catalog.semesters/lessons/course/syllabus` | 代码已接收，平台分列：`academic_catalog.rs` → `expanded_services.rs` → `CampusService` | 当前生产 Core 已实读动态学期、两页开课、课程缓存投影及32段大纲；权限/分页/持久化测试通过。`course` 是匹配学期已缓存目录投影，独立课程详情样本404；覆盖范围保持 page/window |
| NEW-FDU-EHALL-CATALOG | `fudan.ehall.catalog` | 代码已接收，平台分列：`ehall.rs` → expanded service | 当前 Core 实读10项目录窗口；保留 total=0 与非空列表及服务端limit未执行的语义。可选说明超限/含敏感链接时省略说明并保留条目，目录24项测试通过 |
| NEW-FDU-EHALL-TASKS | `fudan.ehall.tasks`、`fudan.ehall.tasks.sync` | 代码已接收，真实队列部分通过 | 独立固定目标新密码流程+私有self info200/e0；不透明uid的学号映射未验证。当前Core的todo首页0、done首页1；application因SourceSchemaChanged被拒绝。原生login仍为仓库外研究原型，生产Host需提供服务会话；分页/stop/coverage/撤权等离线通过 |
| NEW-CANVAS-LEARNING | `canvas.quizzes.sync`、`canvas.quiz.read`、`canvas.discussions.sync`、`canvas.discussion.read/view` | 代码已接收，平台分列：`canvas.rs` → CoreAdapter | 当前learning13项、content11项及完整workspace通过。独立UIS Cookie profile200并核对本人，所测首课讨论为空，经典测验404；不是全站测验不可用。Classic元数据不等于New Quizzes，不开测验/答题/标已读 |
| NEW-CANVAS-SELF | `canvas.assignment_groups.sync`、`canvas.submission.self`、`canvas.enrollments.self`、`canvas.grades.self` | 代码已接收，真实资源分列 | 本人ID/分页身份过滤与字段消毒测试通过。Cookie首课作业组1项、本人注册与已发布成绩列表为空；单个submission尚未实读。原App Bearer仍401，Cookie成功不改变该Token状态 |
| NEW-LIBRARY | `fudan.library.lookup/bibliography/holdings/loans.current/loans.history` | 代码已接收；公共实读成功，私人借阅待验 | 当前 Core 实读正常空/非空lookup、由结果发现的单条书目/馆藏；Library24项及Core桥接通过。私人借阅必须精确access_token头和可信读者基线；私人schema仍unverified，Primo搜索403单列 |
| NEW-LIBRARY-OWNER | `fudan.library.reader.observe/bind/clear` | 代码已接收；能力 `fudan.library.configure`，Owner-only | observe仅返回ObservedUnbound指纹；宿主独立核对后显式bind。MCP/JS读取和调度不能覆盖基线，私人读取前重新核对reader；不是自动绑定本人 |
| NEW-SECRET-HEADERS | 宿主托管非Bearer敏感认证头与 `Network::request_bytes` | 代码已接收，平台分列 | 精确account/origin、头碰撞/重定向/路由、替换/logout/备份清洗、二进制8MiB预算及IO前后凭据generation/权限租约测试通过。页面handle换代不能混合主体；字节能力不等于云盘Proto schema已实现 |
| NEXT-PUBLIC-PROGRAMS | `fudan.programs.list/detail` 公共培养方案 | 代码已接收，公共实读成功 | 当前 Core 两页目录及8章节/40模块详情实读成功，programs12项自动测试通过、1手动stdin用例ignored；详情ID须出现在同账号目录缓存。公共要求不代表个人已得学分/毕业认定 |
| NEXT-GRADUATE | 研究生公开入口、培养方案/开课/学分/学位状态 | 官方功能证据+认证边界，个人协议unverified | gsapp公开菜单可读；gsportal→id/ac；yjsxk HTTPS此次未取得响应。保持现有研课表/成绩实现，新增目录不抄金智其它学校动作名 |
| NEXT-EVALUATION | 官方课评任务/截止/状态 | 官方功能证据+认证边界，个人协议unverified | ce→id/ac，未见业务JSON。先任务元数据，问卷打开是否建答卷/写浏览态尚不明，不能作为无副作用GET自动执行 |
| NEXT-OTHER-SITES | 个人数据中心/教学门户、icourse、云盘、论文、就业、迎新、奖助、地图、打印 | 按研究文档分别为官方说明、公开脚本或网络/认证边界；未全量接入 | [教学](academic-learning.md)、[生活门户](portal-life-services.md)、[图书馆与学生服务](library-student-services.md)。目录入口不代表每个服务协议，也不将打印/申请/上传/支付写入纳入“只读” |
| NEXT-LIFE-DETAILS | 一卡通完整认证/消费历史、elife完整用电/购电/待付款、智慧体育新系统、报修、集体场地审批、eHall详情/知会 | 未接入或协议待验 | 现有卡余额/部分卡务、用电历史与体育预约基础不覆盖这些独立系统；见[生活门户细项](portal-life-services.md)。本轮没有支付、审批、报修提交或场地业务写入 |

## 通用端口、原生服务与SDK/MCP

| ID | 已有通用机制 | 本轮必须确认的交付点 |
| --- | --- | --- |
| PORT-VAULT | Windows DPAPI、Linux Secret Service、Android Keystore；platform-owned认证 | 新源各自绑定真实origin/account；HostToken/HostSession/BrowserSession/匿名模式保持显式；非Bearer敏感头仅通过可信宿主导入，普通ctx/日志/返回/fixture不含真实值 |
| PORT-PAGE | `PlatformPort`、Android系统WebView和绑定句柄；新`page_transport.rs`只读桥接 | session.status的principal/account/origin/authenticated校验、原始调用者授权重查；缺provider即CapabilityUnavailable，不暗用Rust HTTP；真实SSO/验证码由宿主交互 |
| PORT-NETWORK | Core应用级direct/gateway/auto；官方WebVPN编码在connector | 私网来源显式授权；网关与原站凭据分开；仅GET/HEAD连接建立前失败可受控fallback，401/403/500/响应断流/写请求不跨路由重发；IMAP/SMTP不经HTTP网关 |
| PORT-WAKE | generic native/plugin jobs、Android唤醒/前台、通知和安全presenter | 新只读service复用持久调度，不另外开学校timer；QR/文件选择/系统通知仍平台负责；缺能力明确拒绝 |
| API-NATIVE | `CoreService`目录、`Engine::register_service`、Host/FFI默认注册CampusService/MailService | 新方法注册、输入验证、source分区、records持久化、来源ACL与错误码；只存在客户端不算接线；不得接受caller自造身份/服务注册 |
| API-JOBS | `jobs.schedule`的`kind:"service"`与SDK `NativeServiceJobScheduleParams` | 方法由受信目录提供，capability为read/sync，原caller grant与输入digest绑定；调用、状态和缓存结果授权重查；配置/登录/写方法不可被“readOnly:true”变成只读任务 |
| API-SDK | TypeScript ctx固定14命名空间；宿主用统一Request/Response及host-only原生任务类型 | 新学校RPC不是自动新增ctx命名空间。主线程决定宿主类型/示例和方法文档；SDK facade/tsc检查与Rust真实接口一致，不让ctx接收凭据 |
| API-MCP | `core_call`按CampusService目录与`.read`能力筛选，专用身份和初始空授权 | 验新方法工具可发现、授权后可调用、撤销后拒绝；configure/login/bind/敏感presenter/reconcile排除。Allowlist不等于已授权，真实stdin/stdout协议需要执行证据 |

## 平台、源码身份和发布验收

| ID | 历史实际证据，均为2026-11-07批次 | 本轮接受条件 |
| --- | --- | --- |
| VALID-WIN | Windows workspace349/349、strict Clippy/fmt；Windows release IPC/MCP/同包/备份恢复 | 当前冻结输入 **501 passed/0 failed/1 ignored**，strictClippy/fmt通过；SDK检查通过。release重现/解包运行另收，不加旧数 |
| VALID-LINUX | Core178+Host24+FFI2=204实跑；连接器136按哈希沿用；C ABI smoke。见[Linux记录](../linux-validation.md) | 当前五workspace **499 passed/0 failed/1 ignored**，所有连接器实际重跑；fmt/strictClippy/原生C ABI smoke通过、guest66/66匹配。真实Secret Service本批未验；详见[本轮Linux](linux-acceptance.md) |
| VALID-ANDROID-X64 | 最终JNI native8/8；平台基线28个不同instrumentation、5JVM；共同插件包真实执行 | 当前Rust/APK身份匹配，**完整31/31、JVM6项、两进程Keystore**通过；包含9个当前JNI用例。合成页面/loopback不证明学校WAF或OEM行为；见final-validation |
| VALID-ANDROID-ARM64 | SO双构建hash匹配；没有ARM64设备执行 | 当前源码两份独立target编译，SO SHA256均`79b1064b…fc4f`；明确compiled-only，没有ARM64设备执行 |
| VALID-LIVE-PUBLIC | 本轮研究工具公开目录/大纲/eHall/图书馆首页/Primo配置的Core GET证据 | 新生产方法通过当前release或真实Engine读取相同公开固定目标；报告schema/coverage/状态且不导出body/headers/个人数据 |
| VALID-LIVE-PRIVATE | 本轮Canvas401、UG课表500、my交互门槛；其它目标见[研究验证](validation.md) | 各服务本人身份、账号绑定、实际使用route和只读结果分列；未执行的WebVPN流程不是“认证失败”；外部障碍如实保留，不造成功，不未经批准重复认证 |
| RELEASE-INPUT | 旧生产helper57文件指纹`425318a8…`及旧build receipts | 新增Rust/manifest/头文件进入当前生产输入；构建前后无drift；full源码归档还含SDK/tests/docs/plugin/platform，与binary source清单口径分开 |
| RELEASE-REPRO | 固定Windows编译路径下空release缓存重建；ARM64不同输出；旧三个ZIP确定性验证 | 当前Windows两份EXE均`d89acf76…f901`，同编译路径空release缓存重建；ARM64两份独立target SO相同。均绑定当前66输入；ZIP重现另列 |
| RELEASE-PACKAGE | 开发版Host/SO/source ZIP及许可/SHASUMS、解包Windows smoke | 当前三个ZIP预检通过，解包Host实际IPC/MCP/新方法发现/公开调用/撤权/备份恢复通过；Windows/Android同包和规范结果hash一致。定稿后再复包与校验，结果随产物SHA256SUMS交付；Android ZIP是核心库 |

## 主线程接收顺序

1. 收当前catalog/eHall/Canvas接线与library/敏感头/页面代理的实际差异；检查worker独占范围、第三方归属和越界修改。
2. 收新增服务offline+CoreService权限/持久化/分页/取消/恢复的集成证据；更新宿主方法说明和SDK示例，执行MCP发现/拒绝用例。
3. 公共培养方案已完成生产接线、离线/桥接及有界实读；研究生/课评保持unverified，先本人页面只读取证，不用猜测协议补齐功能表。
4. 冻结当前生产输入和完整源码；跑Windows、Linux、Android相关批次，再生成当前release receipts、独立重现、ZIP及解包执行结果。
5. 最终验收报告填写实际数、hash、执行架构和外部障碍；本矩阵的“待收”由主线程依据这些证据更新，不能只凭此文档标完成。

原roadmap Later/明确排除项继续单列：实际作业提交、视频/转录、桌面browser provider、macOS/iOS、内置LLM/通用Agent、SSH/终端、生产UI、云同步服务、Node或强制Chromium。图书馆只读发现本轮可以扩展，真实续借/预约仍需要独立协议和具体写入授权。
