# 当前冻结源码的最终分层验证

这是 2026-11-09 独立研究批次的历史验收。原路径、当时未出生的分支和各项摘要保留
原文；它们不表示正式 Core main 的当前状态。后续迁移及功能集成使用新构建和测试，
见 [Core 集成记录](../core-integration-20261111.md)。

核对日期：2026-11-09。主线程已接收当前冻结代码的Windows/Linux全量、Android完整模拟器套件、两平台独立release重现、ZIP预检、实际解包Host和同包跨端执行，以及脱敏校园实读。定稿后的确定性复包结果随产物SHA256SUMS与外部receipt交付。后续主线程在本地保护进程中读取指定凭据并试验eHall新认证流程，没有导出原值、个人响应或会话。生产UI仍由独立项目承担。

## 本批源码身份

| 对象 | 已核验身份 | 口径 |
| --- | --- | --- |
| 当前生产输入冻结 | 66文件，SHA256 `fdbaeab6fda9ab71025830d32de05899b1310fd589aff79efc45069da97e5945` | 构建core二进制的Rust源/manifests/锁文件/toolchain/C头；不包含全部SDK/docs/tests/Lab |
| Windows源标识 | `current-production-validation.json`、`source-before.json`、`windows-acceptance.json`均绑定上述摘要 | 当批source_unchanged=true；只表示这个生产输入集合未变 |
| Linux执行快照 | 206文件；manifest SHA256 `28e6aabb5ddef95258758e54aa3b002d3dbddd59adfde991098fc2fd7e2c6856` | 另含五workspace测试、合成fixtures、Lab和允许插件源；不是同一个66文件摘要 |
| Linux guest生产子集 | 66/66与主冻结匹配，按相同清单顺序重算同fdbaeab6… | 实际对guest `/opt/dansheng-validation-eb783bcf/source`只读sha256sum；host副本也66/66匹配 |
| 当前workspace生产源 | 只读Get-DanshengBuildSource仍为66文件、同fdbaeab6… | 本文写作时无生产drift；文档修改后完整源码归档仍须生成/校验 |
| 最终原生服务探针 | receipt同fdbaeab6…；工具artifact SHA256 `64776fce889eaf0ee0945f4b6422db992478a37c3ab4705ea66f64810d488065` | 工具main/lock分别另有hash；不是Windows Host release EXE的hash |

当前分支`codex/fudan-service-research`尚无首次提交，不以不存在的HEAD commit标识产物。2026-11-07的349/204/136/8等旧数字只属于历史批次；本轮以以下原始日志重算值为准。

## 自动验证已接收与待接收

| 层级 | 当批证据与结果 | 接收边界 |
| --- | --- | --- |
| Windows原生全workspace | **501 passed、0 failed、1 ignored**；tests/clippy/fmt退出均0，生产源未变 | 已核对原始windows-tests.log汇总及acceptance；是当前debug/原生测试，不自动等于release重现/打包执行 |
| Linux原生全workspace | **499 passed、0 failed、1 ignored**；five-member full模式、fmt/strictClippy、ELF/C链接及实际ABI smoke均0 | 已接收当前代码Linux门槛，所有连接器实际重跑；真实Secret Service本批明确未测，详情见[Linux验收](linux-acceptance.md) |
| Android x86_64当前JNI/模拟器 | **完整31/31、JVM6项、两独立进程Keystore**通过，原生套件105.813秒 | 当前Rust库/APK和34项平台源身份匹配；合成页面/loopback，含9个JNI用例；不是学校真实WAF或ARM64真机 |
| Android ARM64当前构建与独立重现 | 两份独立target构建产物匹配，SO SHA256 `79b1064bb0c11a1cd073ee88d99a1e645e7621566a1dad10388482daaf49fc4f` | 当前66输入，cross-compile only；没有ARM64设备执行 |
| Windows当前release双构建 | 同编译路径空release缓存重建，两份EXE SHA256均`d89acf76b8798ba9c859e7ecc3911b198675fc1b50d96d9c96b3e2b99118f901` | 第一完整release缓存保留到另一目录，第二次独立编译；MinGW路径布局条件保留，不宣称任意路径字节相同 |
| 当前ZIP/源码/许可/解包Host | 三个ZIP预检通过；解包EXE实际IPC/MCP/新校园读取/撤权/备份恢复与同包执行通过 | 产物包含对应许可与元数据，VALIDATION.md绑定源码路径及hash；定稿后复包/verify结果随SHA256SUMS交付。Android ZIP是核心库 |

独立逐crate计数如下。Windows按其单个workspace日志的测试结果行归属统计；Linux按五份crate日志统计，未叠加console副本或旧批次。

| 成员 | Windows passed/failed/ignored | Linux passed/failed/ignored |
| --- | ---: | ---: |
| dansheng-core | 196 / 0 / 0 | 196 / 0 / 0 |
| dansheng-connectors | 270 / 0 / 1 | 270 / 0 / 1 |
| dansheng-host | 25 / 0 / 0 | 24 / 0 / 0 |
| dansheng-ffi | 2 / 0 / 0 | 2 / 0 / 0 |
| dansheng-lab | 8 / 0 / 0 | 7 / 0 / 0 |
| **总计** | **501 / 0 / 1** | **499 / 0 / 1** |

唯一ignored是`academic_programs::public_response_from_stdin`，手工有界stdin研究探针。组件中曾手工执行的公开schema解析不补算进自动套件。Host/Lab的两个Windows多项来自平台cfg差异；不把两端相同测试累计成“1000个独立需求”。

### Android最终执行与故障归属

旧验证AVD的进程启动很慢；新建仓库外owned API36 AVD `emulator-5594`，保留原`emulator-5588/5592`。不指定class的legacy discovery出现startup ANR，显式class才能取得有效测试结果。完整测试还发现验证宿主未授予精确闹钟权限、Copy夹带Node开发用pack.mjs、旧package断言/报告指纹以及缺少Owner页面到体育插件的可信宿主授权。

当前修复只调整验证宿主：runtime assets用Sync限定7文件；这7项逐个匹配研究开始前清单，当前package摘要为`98545163…9547`，旧d13摘要没有被当作当前结果。可信fixture按manifest明确批准单一插件/fixture-a/来源共享页面；生产adapter的默认拒绝策略保持由其实现。精确闹钟通过owned模拟器的系统Settings UI授予，并验证开关与实际alarm调用。

最终7类31项一次完整运行通过：Browser9、JobWakeBridge6、Vault3、Wake4、NativeABI7、ClosedLoop1、NativeCampusBridge1。Keystore seed/check在PID7890/7922分别通过。没有叠加前面的失败批或单类重跑。平台34输入摘要`61f674ba7b22b61af0143c1ce127c38cbb71ec5878a345edbb7328f78933cbfc`；Rust SO为`591d9881…8568`且与APK中实际条目匹配，详细APK/test-APK摘要见[Android receipt](evidence/android-final.json)。

ClosedLoop在真实JNI/QuickJS/SQLite/loopback HTTP上运行并重开，package SHA256 `eb037c94a2bd146d0c7d50ec098597e99ba27f2c9ea7852f6bd70e1ec5b6bc1a`，规范结果SHA256 `556afa430353b2329b39860c1bc7495eb31e758b7dbab04ef69a0a6c8fb91193`；Windows解包Host运行同一包后独立比较。

### 解包Host与同包跨端接收

解包EXE实际SHA256仍为d89acf76…f901。开发验证脚本只使用新建合成profile：真实IPC启动、MCP initialize/tools/list、同profile TODO读取、自授权限拒绝、备份创建/离线恢复、恢复后MCP授权清空均通过。新catalog/programs/eHall/library/Canvas只读方法能被真实MCP发现，reader.observe/bind/clear不暴露。授予明确来源/账号/能力后，MCP的fudan.catalog.semesters实际读取成功；撤销后同一调用被拒绝。

Windows同包测试真实执行HTTP/QuickJS/SQLite/IPC/MCP并重启Host，合成loopback只发1次GET且凭据匹配。其package与规范结果摘要分别为eb037c94…bc1a、556afa43…1193，均与当前Android相同。没有把合成认证或缓存重开当作学校登录；Node仅执行开发测试，不进入Core包。摘要见[解包执行receipt](evidence/unpacked-windows.json)和[成对构建](evidence/release-builds.json)。

## 当前原生Core公共服务：13/13固定只读检查

来源为仓库外`final-public-services-20261109T195920Z.json`，generated_at20:00:04 UTC、transport=`current_workspace_native_core`；13个case均`typed_read_succeeded`，raw_data_exported=false、remote_business_writes=0。它包含重复方法的分页/搜索case，**不是13个网站的全部接口验收**。

| 固定公共检查 | 实际返回/缓存证据 | 限度 |
| --- | --- | --- |
| catalog.semesters | 1来源记录、缓存1 | 学期目录结构，学期数不是record_count1的含义 |
| catalog.lessons首页/次页 | 每次1记录，累计缓存1→2；coverage=page | 两页验证，不是全校目录全量遍历 |
| catalog.course | 1记录、缓存1 | 匹配学期目录缓存投影；不冒称独立info端点已读 |
| catalog.syllabus | 1记录、32章节；coverage=window | 支持的惰性文本投影，不是完整动态表格/Word导出 |
| ehall.catalog | 10记录、缓存10；coverage=window | 有界公开服务目录，未证明所有用户可用或私人任务已读 |
| library.lookup两个case | 一个正常空结果，另一个1记录并缓存1；coverage=window | 搜索结果元数据；空结果真实成功，不转换成来源错误，也不推断全库为空 |
| library.bibliography | 1记录、缓存1 | 单条书目，非私人读者数据 |
| library.holdings | 1记录、缓存1；coverage=page | 一个馆藏页，不是全部单册或借阅行为 |
| programs.list首页/次页 | 每次1记录，累计缓存1→2；coverage=page | 公共培养方案目录，未经实测筛选未加入 |
| programs.detail | 1记录、8章节、40模块；section/course-tree coverage均window | 缓存目录ID限定的公开详情投影；特殊引用、歧义模块和动态区域未冒充完整规则，不能算本人学分/毕业认定 |

这批是当前生产Core已注册方法的实际请求、解析和持久缓存证据，超过单纯网页/脚本可达；个人业务可见性和其它平台执行仍需各自验收。未保存学校原始body/headers、书目名称、课程/专业标识或下载签名。

## Canvas两种认证与首个可见课程的范围

主线程分别生成`final-canvas-session-20261109T195920Z.json`（20:00:11 UTC）和`final-canvas-bearer-20261109T195920Z.json`（20:00:15 UTC）；没有将两种模式当失败后的自动fallback。本worker只读取脱敏结果，不接触输入凭据或私有会话。

| 检查 | 当批结果 | 能证明与不能证明的事项 |
| --- | --- | --- |
| 本轮显式密码HTTP Cookie认证 | state=profile_identity_verified，identity_matches=true；固定profile GET200 | 该HTTP会话的当前身份匹配；认证链完成与profile共同构成证据，未导出身份值 |
| 该Cookie会话的课程列表 | 固定per_page1 GET200，item_count1 | 取得一个可见课程；不推测用户学段/教师学生角色或全量课程 |
| 首课canvas.quizzes.sync | read_blocked，SourceHttpError/HTTP404 | 当前样本未读到Classic测验；不能返回假空列表，也不能据此断言全站无测验 |
| 首课canvas.discussions.sync | typed_read_succeeded，record_count0 | 该查询真实空列表；没有取得回复详情或执行已读更新 |
| 首课canvas.assignment_groups.sync | typed_read_succeeded，record_count1、cached_count1 | 一个作业组结构和缓存；不是成绩计算或作业提交 |
| 首课canvas.enrollments.self | typed_read_succeeded，record_count0 | 当前本人注册查询为空；不以此推断所有课程/账号没有注册 |
| 首课canvas.grades.self | typed_read_succeeded，record_count0 | 本人已发布成绩投影无记录；不是将未获数据算成0分/0学分 |
| 既存Bearer的profile | GET401、identity_matches=null、state=identity_unverified | 当前Bearer被拒绝；Cookie成功不使该Token变有效，没有创建新Token或偷偷变更认证模式 |

单个quiz详情、讨论详情/view、本人submission和其它课程/资源没有被此报告全部实读；它们当前代码的离线契约/权限验证纳入自动套件，真实结果仍按来源和资源逐项补充。这些请求remote_business_writes=0、automatic_password_retries=0，没有答题、发讨论、标已读、评教或提交作业。

## 仍保留的外部与平台边界

- eHall后续固定目标原型25项离线/strictClippy通过；新密码流程与私有self info200/e0共同绑定凭据账号，uid学号映射为null。当前Core todo首页0、done首页1，coverage=page；application因SourceSchemaChanged未通过。原型位于仓库外，不是生产login RPC；见[脱敏eHall实读](evidence/ehall-self-read.json)。
- 图书馆reader/current/history loans等私人接口与HostHeaders/BrowserSession的范围不能由公共lookup/bibliography/holdings代替；真实读者绑定/私人借阅仍待授权环境实读。Primo配置/搜索研究也不是这些接口的成功证据。
- 研究生新增培养/目录/学分/学位、官方课评任务、教学门户个人进度、icourse、云盘、论文、就业/迎新/奖助/地图/打印等保持[交付矩阵](delivery-matrix.md)和[学术协议研究](academic-next-protocols.md)的分级状态；网站入口不变成已实现业务。
- 本科个人课表500、my交互门槛、校园网络/DNS/VPN条件等历史/研究限制没有被公共方案详情成功消除；需要当前对应源和身份另验，不猜角色或重复密码。
- 页面执行留在平台认证页，缺能力明确拒绝；真实Secret Service、学校WAF/验证码和OEM息屏唤醒没有被本轮离线套件补证。
- 未执行真实预约、取消、充值/付款、邮件发送、申请/上传、评教/作业提交或续借。原M0–M5历史接收、Later项和独立生产UI范围仍分开，未commit/push/远程发布。

## 证据位置与最后门槛

以下均为仓库外或忽略目录中的脱敏日志/源码清单，不是个人profile：

| 材料 | 路径 |
| --- | --- |
| Windows测试/Clippy/acceptance/source-before | `%LOCALAPPDATA%/dansheng-research/20261109-fudan-services/final-windows-20261109T194316Z/` |
| Windows当前指针与生产冻结 | 同一父目录的`current-production-validation.json`、`frozen-production-source.json` |
| Linux日志/源码快照/阶段码/source proof | `C:/Code/dansheng/.local/linux-validation/20261109T194317Z-eb783bcf/` |
| 最终公共/Canvas Cookie/Bearer摘要 | `%LOCALAPPDATA%/dansheng-research/20261109-fudan-services/final-{public-services,canvas-session,canvas-bearer}-20261109T195920Z.json` |
| 原生探针源码/二进制绑定receipt | 同父目录`final-native-probes-20261109T195920Z.receipt.json` |
| Android当前库/APK/平台源码/完整31项与Keystore | 同父目录`fresh-avd-20261109/`，`final-{identity,process,instrumentation,vault-seed,vault-check}`及`acceptance.json` |
| 当前Windows/ARM64成对build receipts及重现 | `C:/Code/dansheng/.local/fudan-release-20261109/`的`windows-main/windows-independent/arm-main/arm-repeat`及reproduction JSON |
| eHall固定目标认证和当前Core私有队列 | 仓库外`ehall-auth-prototype-20261109/native-ehall-self.json`与`self-run-receipt.json`；仓库内仅脱敏摘要 |
| 解包Windows实际IPC/MCP/备份/同包 | 同研究父目录`unpacked-smoke-20261109/`；仓库内`evidence/unpacked-windows.json` |

当前Android、Windows/ARM64成对产物和解包执行已接收。研究开始时267文件中28项在批准实现/验收范围内修改、缺失0，git index字节保持；7项体育runtime源逐个匹配研究开始前hash。主线程对5组实际凭据的原值/URI/Base64/JSON形式检查源文件及脱敏导出，当前363文件零命中；后续文档定稿/复包再验证清单与凭据扫描。发布流程见[release.md](../release.md)，生产66输入摘要保持不变。
