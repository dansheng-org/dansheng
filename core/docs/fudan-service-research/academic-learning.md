# 教学与学习服务接入研究

调查日期：2026-11-09。范围仅为公开页面、公开脚本、官方说明和当前源码；未读取 credentials.txt，未登录，未提交选课、评教、作业或其它业务写入。以下“公开实测”均为无凭据 GET；重定向到身份认证只记录登录边界，不保存上下文参数、Cookie 或页面内容。本文中的新 core 方法名是设计建议，不是现有 API。

## 结论和首批范围

最容易落地的是本科全校开课查询与课程大纲：本轮已无登录读到真实 JSON 查询页和大纲 HTML。培养方案公开页面也可打开且内嵌年级/院系/专业目录，但其详情查询、查询表格和开放时间需要继续核对。Canvas 应扩展已有通用连接器的测验、讨论和个人提交只读能力；课程、作业、文件、目录、模块、页面、公告和资料下载已经实现，不要重复建设。研究生门户、官方评教和 icourse 目前只能确认入口/功能或认证边界，不能编造内部动作 URL。

建议次序：P0 本科开课/大纲；P1 Canvas 只读扩展、本科公开培养方案；P2 个人培养/学分进展、研究生开课/培养/答辩状态；P3 官方评教任务只读、icourse 授权课程和录像目录。所有提交、答辩申请、评教填写、选退课、开测验和作业提交仍保留在原站或后续独立明确授权动作。

## 本科全校开课与教学大纲：已实测公开查询协议

入口：[全校开课查询](https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search)。2026-11-09 无凭据 GET HTTP 200，标题“全校开课查询”；HTML 自带学期选项，本轮默认 semester=527，显示 2026–2027 学年第一学期。编号仅是本轮观察，生产必须从页面发现，不能硬编码或从年份猜。

公开页面内联 JS 的 tableSearchUrl 明确为：

```text
GET /student/for-all/lesson-search/semester/{semesterId}/search/{semesterId}
GET /student/for-all/lesson-search/info/{courseId}
GET /student/for-all/lesson-search/check-can-info?id={lessonId}
GET /student/for-all/lesson-search/teachingSyllabusInfo/{lessonId}
GET /student/for-all/lesson-search/export-course-syllabus-word?ids={lessonIds}&REDIRECT_URL={...}
```

前四项为页面发现；其中 search、check-can-info 和 teachingSyllabusInfo 已实测。最后导出 URL 为页面发现、未调用，不作为首批接口。两个 ID 域不同：课程详情用 course.id，大纲用 lesson.id，不能互换。

实测 search/527 返回 HTTP 200、application/json，顶层 `data` 数组、`_page_`、`_sorts_`；默认 20 行。`_page_` 有 currentPage/rowsInPage/rowsPerPage/totalRows/totalPages，本轮 totalRows=6619、totalPages=331，仅为实时目录规模。首行键包含 scheduleText、teachLang、courseType、selectionLimit、code、openDepartment、nameZh、limitCount、minorCourse、remark、stdCount、examMode、courseProperty、compulsorys、requiredPeriodInfo、courseAwards、course、id、teacherAssignmentList、lessonCrossBizTypeName。course 子对象含 code/credits/nameZh/subjectClass/id/courseDifficultyLevel/courseTableType/firstSubject。无需保存教师姓名、具体课堂列表即可验证结构。

页面支持课程码、名称、学分、课程序号、院系、教师、校区、上课年级/院系/专业、周次/星期/节次/教室、授课语言、人数、课程分类和是否有审核大纲等筛选。实际查询键应直接解析页面 input/select 的 name；不根据中文标签猜键。公开 `semi-auto-table.js?v=00021` 使用 `_page_` 分页模型及 pageObject，脚本中可见 queryPage__ 的注释写法。本轮随后实际 GET `search/527?queryPage__=2,20`，返回 HTTP200、currentPage=2、rowsInPage=20，确认该参数可以取第二页。生产仍须限定页大小、核对页码/总数并报告 coverage，不能宣称第一页是全量。

从本轮搜索首行取得真实 lesson.id 后，check-can-info 返回 HTTP 200 JSON，长度4字节；teachingSyllabusInfo 返回 HTTP 200 HTML，标题“教学大纲 - 详情”。未调用任何上传、导出转档或业务写入。当前只证明一个公开大纲可访问，不证明所有课程均有大纲或无条件可读。

建议官方 Rust `FudanAcademicCatalogClient<T>` 放在 dansheng-connectors，与现有 `FudanTimetableClient` 共用 ConnectorTransport。请求使用匿名模式，个人身份不是公开目录前提；若以后出现会话要求则显式 AuthRequired，不能自动登录。首批建议方法：`fudan.catalog.semesters`、`fudan.catalog.lessons`（显式页/筛选/coverage）、`fudan.catalog.course`、`fudan.catalog.syllabus`。原始 HTML 不作为脚本运行；提取结构化章节及经过消毒的可展示内容。保留 semester/lesson/course 三种标识、学分精度、排课原文和解析状态，容量/人数仅作为观察，不推断可选资格。

离线验收：合成多学期/中英文/半学分/空教师/本研同课记录、空页与总数、第二页失败、筛选编码、结构变更、无大纲/未发布/403/SSO；大纲多标题/表格/附件/恶意脚本和跨域链接；确认只发 GET、无自动写入、不会将部分页包装成完整快照。真实只读验收另记录默认页、第二页和用户指定筛选页，并核对指定筛选键的语义。

## 本科培养方案、个人学分与教学门户

公开入口：[本科及本研融通教学培养方案](https://fdjwgl.fudan.edu.cn/manager/bizType/2/page-center/major-program-search-view?skipAuth=1)。本轮无凭据 HTTP 200，HTML 内嵌年级/院系/专业分层目录、方案详情组件和公开模式 skipAuth=1。页面 title 有异常的 `??..._zh??`，不是登录失败。界面含“功能未开放”弹窗模板，**模板存在不能证明当前查询被关闭**，需实际查询结果判断。

页面内联 JS 实际出现：

```text
GET /manager/bizType/{bizTypeId}/major-program-search/info/{modelId}
GET /manager/bizType/{bizTypeId}/major-program-search/real-info/{modelId}
```

公开模式选 info，认证模式选 real-info；modelId 从查询结果 ID 和 program-id 得到，而不是专业代码或学号。详情 JSON 组件引用 model、paragraphMode、programContent.paragraphs、courseModules/planCourses 等字段。**本轮未调用这些详情接口，表格数据查询地址和 modelId 尚未核验；这不是已完成的协议。** 页面另有文档转档 POST，明确不调用。后续先追踪公开 `page-index.js` 与页面配置的查询装配，取一条公开结果后验证 info；不得枚举猜 ID。

[计算机学院培养方案栏目](https://cs.fudan.edu.cn/24751/list.htm) 是公开院系资料来源；可作用户可查阅链接或文件索引，不能代替个人培养方案。年度与专业维度应保留，不能把公共要求直接认作某位学生已获学分。

[信息办本科教务介绍](https://xxb.fudan.edu.cn/bksjwgl/)说明学校系统含培养、毕业审核、学分清算和多元发展路径等；这是产品范围证明，不是这些操作已对学生开放的 API 证明。[2026教学门户说明](https://ecampus.fudan.edu.cn/c7/d1/c31333a772049/page.htm)确认门户聚合常用事项、开放时间、学分修读、微专业进度、毕业论文与通知。**未取得其具体门户 URL/公开前端数据端点**，不能凭“学业进展”猜 `/api/credits`。后续由可信宿主以明确本科角色进入官方 eHall 服务，记录 GET/XHR 路由和脱敏结构；个人进度应建 `AcademicProgress` 模型，关联源版本，和培养要求独立存储。

建议方法：先 `fudan.programs.catalog/list/detail`（公共方案），再认证后的 `fudan.academic.progress`。学分及毕业结论完全保留学校原始状态；本地差额仅为辅助计算且标明非官方认定。离线覆盖版本/修订/微专业/本研融通/缺项/重复课程/替代课程/不同学分制；缺个人进度不能返回零学分。

## 研究生培养、开课、学分和答辩状态

[研究生移动端](https://gsapp.fudan.edu.cn/) 本轮无凭据 GET 200，公开页面实际链接：

| 功能 | 公开链接（页面发现，不代表已登录读取） |
|---|---|
| 课表 | https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdkbapp/*default/index.do |
| 成绩 | https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdcjapp/*default/index.do |
| 培养方案 | https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdpyfaappfudan/*default/index.do |
| 课程评教 | https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddxspjappfudan/*default/index.do |
| 毕业与学位 | https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdxwappfudan/*default/index.do |

综合门户入口：https://gsportal.fudan.edu.cn/yjsmhpublicapp/sys/fddxyjsmhxt/index.do。本轮无凭据 GET 最终到 id.fudan.edu.cn 统一认证页（HTTP 200 登录外壳）；没有业务数据。此行为不能计作“研究生培养读取成功”。不持久化重定向中的认证上下文。

[研究生选课官方服务说明](https://xxb.fudan.edu.cn/yjsxk_41707/list.htm)确认已开课程查询、个人培养方案关联和选课冲突提示。[2024研究生FAQ](https://gs.fudan.edu.cn/1c/e9/c12939a662761/page.htm)给出 yjsxk.fudan.edu.cn/wsxk 及 eHall 培养方案入口，但这是2024来源，不能直接视为当前调用协议。[研究生院FAQ PDF](https://gs.fudan.edu.cn/_upload/article/files/0b/57/1ae45f094fde86ae49094853c2a7/e4ec13e9-538a-4fe6-a7ee-134c8d46f4f7.pdf)给出上述 gsportal、培养方案和“查看学分明细”；[研究生管理介绍](https://ecampus.fudan.edu.cn/yjsjygl/list.htm)确认学生可查询答辩申请及过程信息。上述说明只确定功能和服务入口，内部 BH/RZ/RW 等动作名未验证，不应照搬其它金智学校。

建议 `FudanGraduateClient<T>` 为官方连接器，沿用有权使用的 HostSession；如业务依赖页面上下文则明确 BrowserSession 并由平台执行，不能暗换 Rust HTTP。复用现有研究生课表/成绩解析，但培养计划、目录、学分审核、论文评阅/答辩阶段另建模型。首批 `fudan.graduate.program`、`fudan.graduate.offered_courses`、`fudan.graduate.credit_status`、`fudan.graduate.degree_status` 只是建议方法名，需主代理后续以明确研究生身份完成只读网络取证再定请求协议。

答辩论文、评阅意见可能高度敏感；默认仅阶段/期限/学校状态/需要本人处理的链接，不同步评阅正文和专家身份。首批绝不新增申请、导师选择、材料上传、选退课、评教提交。离线覆盖未进入学位流程、待审核、退回、材料缺失、非本人、角色不符、空数据和表单配置变更；结果按当前身份和学期隔离，不能自动由本科500切换到研究生。

## 官方教学评价

入口：https://ce.fudan.edu.cn/。本轮无凭据 GET 到 id.fudan.edu.cn 统一认证壳（HTTP200），未见业务前端、未登录。[教师发展中心录像/课评入口](https://cfd.fudan.edu.cn/yuyue2/demo.asp)确认统一认证及“复旦课评”微信入口；[旧版使用说明](https://jwc.fudan.edu.cn/_upload/article/files/23/7e/18fef6754c5db78c399e6e2076d9/a3f230d0-049c-47b5-ad89-7eacdae48ab7.pdf)展示日常反馈、我的评价任务、全校评估结果。这是旧手册功能说明，不能证明当前学生有教师级全校结果权限，也不能将蛋壳社区评价视为官方课评。

首批仅建议 `fudan.evaluation.tasks` 和按服务规则允许的任务状态/截止时间；不填写分数、不自动评教、不代交匿名问卷，不创建“已完成”状态。现有官方源码没有此协议，需后续本人身份只读页面观测。若 GET 打开问卷即创建答卷/写浏览状态，应把该动作作为有副作用处理，初期只跳转原站。离线覆盖多角色/已评价/未开放/已截止、匿名性字段剔除、HTTP200登录壳和错误问卷模板。

## Canvas/eLearning 只读缺口

复用当前 `crates/dansheng-connectors/src/canvas.rs` 的 CanvasClient、CanvasId（十进制字符串）、origin/API边界、Link分页、HostToken/HostSession/BrowserSession 显式模式；`core_adapter.rs:256`起已注册课程、作业、资料/下载、目录、模块、页面、公告。本文只研究未实现的能力。

Instructure 官方协议：

| 建议能力/首批新方法 | 标准只读 API | 注意事项 |
|---|---|---|
| `canvas.quizzes.sync` | GET /api/v1/courses/{course_id}/quizzes | 仅经典Quiz目录；不等同于New Quizzes，不开测验、不取未授权答案 |
| `canvas.discussions.sync` | GET /api/v1/courses/{course_id}/discussion_topics | 与公告拆分；回复内容需要独立详情能力 |
| `canvas.discussion.read` | GET /api/v1/courses/{course_id}/discussion_topics/{topic_id}/view | 以官方返回的可见性/锁定为准，勿猜线程深度 |
| `canvas.submission.read` | GET /api/v1/courses/{course_id}/assignments/{assignment_id}/submissions/self | 仅本人提交；include[]=submission_comments/attachments 按权限和最小字段选择 |
| `canvas.assignment_groups.sync` | GET /api/v1/courses/{course_id}/assignment_groups | 保留学校分组/权重，不生成权威总成绩 |

**本轮未登录复旦 Canvas 验证这些路由、scope、站点版本或返回字段**。现有复旦能力和 token 失效历史见 docs/live-campus-triage.md。标准协议见 [Quizzes](https://developerdocs.instructure.com/services/canvas/resources/quizzes)、[Discussion Topics](https://developerdocs.instructure.com/services/canvas/resources/discussion_topics) 和 [Submissions](https://developerdocs.instructure.com/services/canvas/resources/submissions)。

提交附件下载应沿用 managed files 和实时授权，不持久化带 verifier/token 的 URL；HTML使用已有富文本处理策略，不能执行。测验/提交缺权限应返回 PermissionDenied/Unsupported，不能删掉已缓存记录或显示“未提交”。New Quizzes 必须另查部署支持，不能把经典 quizzes 404解释为无测验。

离线验收：经典/新测验区分、未发布/锁定/不可见、超安全整数ID、多个评论/附件/延迟与重交、多页讨论/空页Link、课程列表可见而详情403、SSO200、未完成分页无快照覆盖。新方法先只读 grants，不暴露提交/评分/回复POST；不自动打开并标记课程已读的接口。真实复旦验证只读取明确可访问课程目录和本人只读条目，报告仅状态/结构计数。

## icourse 智慧教学资源与录播

官方入口 https://icourse.fudan.edu.cn/；本轮本机公开GET报主机解析失败，**不能判定学校服务下线或账号无权限**。没有取得首页JS或任何API。[教师发展中心2026手册](https://cfd.fudan.edu.cn/upload/2026031634924545.pdf)说明 UIS 登录、校外 VPN，截图有我的课程、我的资源、我的学习等。[录像指南](https://cfd.fudan.edu.cn/yuyue2/demo.asp)说明部分教室本地录制后应自行拷走，并指向 icourse；因此不能把所有教室录像推断为自动上传和学生可读。

可行路径是在复旦校园网或已授权 VPN 中验证 DNS 和入口，再由可信宿主可见登录。优先读取课程目录、节次标题、发布时间和访问权限。**复旦的录像、字幕和下载接口待取证。**

架构建议官方 `fudan-icourse` 连接器；若只能在已认证页面访问则可用官方JS插件承载学校查询和结构转换，经平台 BrowserSession执行。视频播放保留学校播放器/可见跳转，避免在核心内嵌浏览器/Chromium。若后续证明学校明确提供字幕/可下载文件，再复用托管资产/全文索引；HLS/DRM媒体不作为普通文件下载器默认能力。首批建议 methods `fudan.icourse.courses`、`fudan.icourse.recordings`（名称待协议取证），只导出元数据和受控打开动作。

离线验收：未授权/未发布/到期/无录像、校外网络/DNS失败、课程/媒体不同origin授权、播放URL短期失效、返回登录壳和无字幕；不发送观看心跳和进度写入。登录/播放/下载/字幕四项真实验收分别列账。

## 代码复用与实施边界

- `crates/dansheng-connectors/src/fudan.rs`：现有学期发现/课表、身份挑战和 SourceContext 约定。
- `crates/dansheng-connectors/src/campus.rs`：学术查询、结构变更错误、金额/时区与记录覆盖率等范式；培养与目录另外建结构，勿塞入 timetable。
- `crates/dansheng-connectors/src/canvas.rs:585`：统一有界列表分页；`:691`课程，`:724`作业，`:787`目录，`:865`模块，`:945`页面，`:1056`公告。
- `crates/dansheng-connectors/src/core_adapter.rs:228`：学校服务注册；`:256`Canvas已存在服务面。
- `crates/dansheng-connectors/src/login.rs`、`webvpn.rs`：认证和网关由可信宿主配置，SSO仅是进入服务的条件，不代表所有角色/资源授权。
- `reference/DanXi/lib/repository/fdu/edu_service_repository.dart`、`time_table_repository.dart`、`postgraduate_timetable_repository.dart`：固定复旦课表/成绩参考，无新培养/评教/录播完整协议。

本轮只新增研究文档，没有实现新连接器、fixture或客户端；没有运行构建/测试。公开GET的成功仅覆盖上述具体路径，认证后业务和平台/模拟器验收均未完成。


## 已有 Android 宿主能复用的部分

本轮只读核对独立 App 源码：`C:/Code/dansheng-app/android/app/src/main/kotlin/org/dansheng/app/CampusPortalActivity.kt:25` 固定 eLearning origin，`:31` 的常规允许域仅 my/uis/id/elearning，`:78` 起另有 jwc/gs 通知页分支，`:132` 起在 my 门户后转 Canvas CAS。`CampusLogins.kt:46`–`:50` 调用现有 ecard/academic/life/forum 登录，`:83` 调用 canvas.uis.login。该基础可复用可见认证、独立 WebView profile 和受控会话交接，但**目前这段代码没有将 ce/icourse/gsportal 作为通用允许域，更没有这些服务的类型化 Core 连接器**。不能因某网页可在 App 中打开就宣称上述数据同步已经实现；后续新增服务必须审查各自允许域、会话隔离、账号绑定和认证回执，不直接放宽为任意域名。
