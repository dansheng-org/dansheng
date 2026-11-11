# 图书馆与学生生活服务接入研究

研究日期：2026-11-09。范围：馆藏、资源发现、借阅/续借/预约、文献传递、学位论文；就业、迎新、奖助贷款、云盘、地图、自助打印。本文是研究方案，不代表已实现或已通过校园业务验收。

## 证据与操作边界

- **P：公开实测**：本次在命令工具中使用无账号、无 Cookie 的 HTTPS GET 获取官方首页、该首页直接引用的 JS 和 Primo 视图配置；还对一个推导的 Primo 只读搜索候选进行 GET，得到 403。记录状态、重定向、静态调用形状；没有提交表单或执行业务写入。
- **D：官方说明**：官网文章或官方手册描述的功能、规则、入口；不是本次登录后的观察。
- **H：待验证设计**：建议的模型、权限、接入方法。静态 JS 中的 API 只能证明前端代码包含这种调用，不能证明端点当前可用、匿名开放或返回契约稳定。
- 没有读取或使用 `C:/Code/dansheng-app/credentials.txt`，没有登录，没有续借、预约、提交、缴费、邮件、上传、分享或其他业务写入。没有获取个人记录。未保存公开前端原始包，避免复制其中不适宜进入诊断的配置值。
- 所有首批功能均为只读。远端只读查询有时使用 POST，必须逐个方法审核语义，不能把所有 POST 当可用读接口，也不能把 GET 当天然无副作用。

## 公开探测记录

下列长度是本次 PowerShell 响应文本字符数，仅用于辨别 SPA 壳与完整页面，不是响应体完整性或服务可用性断言。网页搜索工具对图书馆首页发生超时，命令工具随后成功，二者不是矛盾的业务结果。

| GET 入口 | 本次公开实测 P | 结论与限制 |
| --- | --- | --- |
| <https://library.fudan.edu.cn/> | 200，155426 字符，标题“复旦大学图书馆” | 可以读取公开导航与搜索表单；没有执行搜索 |
| <https://opac.fudan.edu.cn/> | 200，566 字符，标题“统一资源发现门户”；Vue SPA | 新门户存在；不是书目数据返回 |
| <https://thesis.fudan.edu.cn/> | 200，608 字符，标题 `paper` | SPA 壳可读；没有查询全文或个人论文 |
| <https://career.fudan.edu.cn/> | 200，67248 字符，标题“复旦大学就业指导与生涯发展处” | HTML/Vue 数据绑定和公开脚本可读；没有请求岗位列表 API |
| <https://cloud.fudan.edu.cn/> | 200，55559 字符，标题“复旦云盘” | 登录界面模板与脚本可读；未请求文件目录 |
| <https://map.fudan.edu.cn/> | 200，最终 <https://zlapp.fudan.edu.cn/site/schoolMap/model>，9098 字符 | 原地图域目前重定向到地图模块；未请求坐标/楼宇 API |
| <https://freshman.fudan.edu.cn/> | 200，最终 `/yx/#/share/…`，1811 字符 | 迎新 SPA 入口；最终 hash 是公开入口的一部分，本文不复制其中的签名样式值；没有身份或事项数据 |

静态证据来源（文件指纹式 URL 会变化，应从首页重新发现）：

- OPAC：<https://opac.fudan.edu.cn/static/js/app.ea0f02cf08d19b244213.js>。
- 学位论文：<https://thesis.fudan.edu.cn/js/app.229b4fd1.js>。
- 就业：<https://career.fudan.edu.cn/js/config.js>、<https://career.fudan.edu.cn/js/api.js> 与首页内联调用。
- 云盘：<https://cloud.fudan.edu.cn/static/js/packed-app.js?v4.0.16>；首页还引用 `packed-cc.js` 和 `tmpls-all-in-one.js`。
- 地图：最终页面直接引用 <https://zlapp.fudan.edu.cn/site/static/js/app.fc7113de7bb5fdfd5fe7.js?v=1788159066658>。这是多应用共享包；其中大量别校接口不能当复旦接口清单。

## 图书馆

### 馆藏与资源发现

**D**：[馆藏目录官方介绍](https://library.fudan.edu.cn/7/list.htm)将纸本、部分电子资源检索与登录后的个人借阅明确分开。[首页](https://library.fudan.edu.cn/)区分“资源发现”“馆藏目录”“数据库”“电子期刊”“电子图书”；这些不是同一个可无损合并的搜索索引。

**P**：首页同时包含新 OPAC、`/F` Aleph 旧搜索表单、旧 discovery/pds/MetaLib 与 CALIS 链接。旧链接存在不等于仍可用，不应据此首选老协议。首页的电子期刊 GET 表单 action 为 `https://sfx-86fdu.hosted.exlibrisgroup.com.cn/cgi-bin/86fdu/ej.cgi`；CASHL 表单为外部检索站。新门户 JS 包包含：

| 静态可见调用 | 已观察的协议形状 | 未确认项 |
| --- | --- | --- |
| `https://fdulspgw.fudan.edu.cn/urdh/open-api/opac/search/singleVolume` | GET + params | 参数完整 schema、匿名返回、分页/排序 |
| 同前缀 `/search/advanced` | POST + data | 查询体、结果 schema、是否会记录历史 |
| `https://fdulspgw.fudan.edu.cn/alsp/open-api/opac/v2/holdings` | GET + params | 文献 ID 与单册 ID 关系、可借状态枚举 |
| Primo 跳转 | `https://fudan-primo.hosted.exlibrisgroup.com.cn/primo-explore/search?vid=fdu` | 实际请求契约与校外全文权限 |

前端检索对象出现 `pageSize`、`pageNum:1`、`searchConditions`、`orderByField:"similarity"` 和资源类型字段；不能将借阅的 `pageNo` 与之混用。JS 还出现登录后搜索/浏览历史写入路径，故将来 page-context 只读查询应调用审核后的数据接口，不能通过模拟点击自动产生历史或收藏写入。

**P：Primo 实例进一步验证**：从上述 OPAC 官方脚本确认的实际 host/vid 出发，无账号 GET `https://fudan-primo.hosted.exlibrisgroup.com.cn/primo-explore/search?vid=fdu` 得到 200（4788 字符）；首页直接引用 `lib/bundle.js?version=4b78d47baf`（本次 200，4383738 字符）。公开 GET [实例配置](https://fudan-primo.hosted.exlibrisgroup.com.cn/primo_library/libweb/webservices/rest/v1/configuration/fdu) 返回 200、`application/json`（383491 字符），`primo-view.institution.institution-code` 为 `FDU`，并给出真实 tab/scope：

| tab | scope-id | 来源 |
| --- | --- | --- |
| `book_journal` | `book_journal` | `local`，`scope:(FDU)` |
| `default_tab` | `default_scope` | `local,adaptor`，本地 + Primo Central |
| `digital_tab` | `article_scope` | `adaptor`，Primo Central |

配置中的 `bulkSize` 是 `10`，可选 `10,20,30,50`；这只是视图配置，并非 API 强制上限。bundle 确有 `pnxs` 聚合结果和 `/rest/primo-explore/v1/` 路径逻辑。基于这些证据**推导**的匿名只读候选：`/primo_library/libweb/webservices/rest/primo-explore/v1/pnxs?vid=fdu&tab=book_journal&scope=book_journal&lang=zh_CN&offset=0&limit=1&q=any,contains,mathematics`，本次 GET 返回 **HTTP 403**，没有取得书目行。该请求无 token、无登录态；403 不能区分访客 JWT、访问策略、参数或其他限制，不能声称“匿名 REST 搜索已可用”。后续先在用户主动打开的官方页面观察真实只读搜索，再补齐精确参数/访客认证流程；不猜密钥、不尝试绕过 403。

**H**：官方 `fudan-library` 连接器负责协议/解析；可独立发布 `fudan-library-discovery` 官方插件，声明经过审核的 public origins。资源发现优先只索引题名、作者、出版信息、稳定资源 ID、可访问原文链接、馆藏摘要与来源，不默认下载全文。结果必须携带 `resource_family`，保持 OPAC/Primo/数据库导航/电子期刊来源区分。首版支持公开导航 + 书目搜索 + 单册馆藏；只有获得匿名接口真实返回 fixture 后才算可实现接口，不把本文 URL 直接登记为已实现 capability。

### 我的借阅、续借与预约

**D**：[官方使用指南](https://library.fudan.edu.cn/d5/2e/c42800a709934/page.htm)说明统一身份认证与图书馆单独认证入口，并说明续借和预约流程。本研究不复制初始密码规则。规则可能变动，未来界面应展示官方链接与更新时间，不能将次数或借期硬编码为核心规则。

**P**：首页可见 `/fdu_login.html`、`/api/oauth/callback?login=tac_login` 与 `/#/myLibrary`。OPAC JS 将业务基址设为 `https://fdulspgw.fudan.edu.cn`，私有读 API 使用 `access_token` header；这些是公共代码中的认证机制，不是本次取得了 token。

| JS 静态证据 | 参数/响应访问方式 | 接入结论 |
| --- | --- | --- |
| GET `/alsp/open-api/elib5/getReaderInfo` | `access_token` | 读者账户概要，私有、需登录后授权验证 |
| GET `/alsp/open-api/elib5/getReaderCurrentLoan` | `{pageSize:10,pageNo:1}`；前端访问 `data.code`、`data.data.total`、`data.data.list` | 当前借阅首选候选 |
| GET `/alsp/open-api/elib5/v2/getReaderHistoryLoan` | token + params | 借阅历史独立可选权限，不默认获取 |
| POST `/alsp/open-api/elib5/searchReaderRequest` | token + data | 当前预约查询候选，仍未发出请求 |
| POST `/alsp/open-api/elib5/renewLoan`、`/addRequest` | token + data | **写接口，首批禁用；本次没有调用** |

当前借阅前端尝试合并 `itemInfo.instance` 与 `itemInfo.item`；也有平铺行兼容。可见展示字段为 `title`、`author`、`checkoutDate`、`checkinDateTime`、`renewCount`、`barcode`、`temporaryLocationName`、`callNo`。其中 `checkinDateTime` 在前端被用于应还日期，不应未经真实响应核对就按英文名字解释为已归还时间。

**H**：首批只读 `Loan`、`HoldRequest`、可选 `ReaderSummary`。将读者姓名/学号/电话/邮箱排除默认同步；借阅条码作为账号作用域内 ID，不进入公开搜索或审计日志。提醒只由本地 calendar/reminder 接受已明确授权的到期日期生成，不自动续借。将来续借需单本预览、具体用户授权，超时标记不确定并重新读取应还日期/次数后才决定是否重试。预约、取消预约与取书方式变更是独立写能力。

### 文献传递、馆际互借与学位论文

**D**：[文献传递/馆际互借](https://library.fudan.edu.cn/32/list.htm)说明 CALIS、CASHL 等申请途径与版权范围；图书馆首页有 CALIS 账户跳转链。首批提供服务说明、资源定位与官方入口即可。不要把“未找到全文”自动转换为申请或邮件；申请、费用确认与取消均属于业务写入。第三方 CALLIS/CASHL 身份与权限不能推断为等同 UIS。

**D**：[学位论文](https://library.fudan.edu.cn/95/list.htm)、[论文提交说明](https://library.fudan.edu.cn/e7/ae/c42789a518062/page.psp)及[常见问题](https://library.fudan.edu.cn/_s928/09/38/c42789a723256/page.psp)确认 `thesis.fudan.edu.cn` 与图书馆检索入口；提交通过 UIS。公开发现不代表全文授权；检索与提交必须分开。

**P**：论文 JS 使用 Axios `baseURL:"/md/"`，定义 `papersearch/` 前缀及 POST `simpSearch`、`learnidPapers`、`keySearchByLearnid`、`keySearch` 等；`account/` 有登录与 `caslogin`，还出现 IP 权限检查、DRM 查看/加密路径操作。未调用任何一个，`/md/papersearch/simpSearch` 是静态组合候选而非已实测 API。各 `list` 的 `pageno/pagesize` 不保证就是论文检索分页。包包含论文检测/付款/提交能力，不能因共享包存在而把这些操作纳入首版。

**H**：论文首先作为 `BibliographicRecord {kind:thesis}`，保留作者、导师（若公开）、授予单位、学科、年份、摘要授权状态与官方详情 URL；全文默认 `open_in_official_site`。不绕过 DRM、IP 限制、 embargo 或资源许可；提交/撤回/查重付费全部排除。公共检索 API 验证前可复用 OPAC 学位论文分类导航。

## 就业与学生事务

### 就业 career

**D**：[复旦主站部门介绍](https://www.fudan.edu.cn/2019/0506/c431a103172/page.htm)确认官方域名与岗位、招聘、生涯服务职责。[官方三方/毕业去向资料](https://ygb.fudan.edu.cn/_upload/article/files/91/57/352e406d4192a76e513cb6c1b6b5/43a06809-35d4-4838-8776-e2aa1fbd56a0.pdf)说明学生登录与毕业去向办理；属于事务写流程，不等于公开招聘信息。

**P**：`config.js` 的 host 是 `/mobile.php`。首页内联代码以 POST 查询 `/job/getlist`（`jobtype:1/2`、`isunion:2`、`school_id`、`page:1`、`size:4`）、`/enrollment/getlist`、`/jobfair/getlist`、`/preach/getlist`（`publish_status:1`、`isair:3`、`page:1`、`size:20`）和 `/Article/getlist`；前端详情路由为 `/Zhaopin/zhiweiDetail.html`、`/Zhaopin/xiaozhao.html`、`/Zhaopin/zuijin.html` 等。

`api.js` 的公共请求包装器先 GET `/mobile.php/wx/getselock`，处理 `lock`/`expTime`，从 sessionStorage 读取短期 `auth` 与 `token` 并附加公共请求字段；代码兼容秒/毫秒过期时间并提前刷新。**未实际请求 lock/token、未重放这些接口**。不要把公开页面的 `login_user_id` 默认值当可用身份，亦不要让插件复制 sessionStorage token。页面还引用第三方平台，须按每个 origin 分开授权。

**H**：官方 `fudan-career` 插件首批读取公开岗位/实习、校招公告、宣讲会与招聘会。`JobPosting` 保存 ID、题名、单位、工作地点、招聘类型、发布时间/截止日期、官方详情 URL；薪资需保留单位和原文，不根据展示函数猜数字。`CareerEvent` 分开开始/结束时间、地点、线上/线下类型、报名要求；只提供本地加入日程，不自动报名。学生个人状态、简历、投递、咨询预约与毕业去向属于后续不同权限，首批禁用。需页面认证包装时用平台 BrowserSession；不能直接复刻 token 获取逻辑为共享 core HTTP。

### 迎新

**D**：[新版迎新系统说明（2024）](https://ecampus.fudan.edu.cn/92/b3/c33159a692915/page.htm)确认公告、事项入口、办理进度与结果聚合；这是多部门事项聚合，不是统一写协议。

**P**：首页重定向到 `/yx/` SPA，脚本包括 `static/config/apps-config.js`、微前端 `remoteEntry.js` 和 hash 命名主包；本次只读取 HTML，没有抓取个人事项 API，也未推断接口路径。是否适用当年年级/录取身份、UIS 或专用登录，需要用户手动进入官方页后验证；不沿用历史初始密码规则。

**H**：`fudan-onboarding` 官方插件优先 `Notice`、`ChecklistItem {status,deadline,official_url,last_checked}`；学院/宿舍/辅导员等个人信息不进入默认全局索引。缓存必须按账号、入学年、学生类别隔离；不把“页面无权限/未开放”解释为事项已完成。照片上传、意愿申请、考试、确认、户籍预约、缴费全部只转官方入口。

### 奖助、贷款

**D**：[信息办研究生奖助系统说明](https://ecampus.fudan.edu.cn/yjsjzgzgl/list.htm)确认困难认定、贷款、奖学金、助学金等模块；[研究生助学金用户手册](https://ygb.fudan.edu.cn/_upload/article/files/fc/d7/70abc8244759ac0d47227888bccc/a0ec54f4-d4a1-4314-a4fb-7bc80144e8f2.pdf)说明经 eHall 进入“研究生助学金”，在奖项申请页查看项目。[复旦在校学生入口](https://fudan.edu.cn/407/list.htm)区分本科、研究生与留学生奖助；不能共享一套 eligibility 推导。

**P**：本次没有登录 eHall、没有请求任何助学/贷款业务接口，也没有发现经真实响应验证的 JSON 契约。旧 URP 链接和系统介绍不是当前 API 证据。

**H**：官方 `fudan-student-affairs` 插件先做公开政策和项目通知目录，后续经明确授权验证 `AidOpportunity` 与当前用户 `ApplicationStatus`（只存项目/状态/日期/官方链接）。家庭经济、银行、身份证、医疗证明、金额和申请材料默认不采集。奖助结果与财务到账分属不同来源，不合并成“已到账”。申请、贷款合同、还款、撤回、材料提交属于后续高敏写入，排除首批。

## 云盘、地图、自助打印

### 复旦云盘

**D**：[信息化校园官方手册](https://ecampus.fudan.edu.cn/_upload/article/files/3f/03/ddffa4d64451bb45473c6d7bccc6/5be6fe1e-e48b-44f5-be5e-779e865caa6c.pdf)给出 `https://cloud.fudan.edu.cn` 并说明文件管理、备份、同步。

**P**：公开包版本字符串 `v4.0.16`；模板采用 Knockout 风格绑定，包内 `getBinary` 以 `application/x-protobuf` 读取 `/initinfo`、`/apps`，还存在文件属性/权限控制、下载/分享等不同操作。**不能据此断言它是 Seafile、Nextcloud、支持 WebDAV 或 S3**；本次没有查验协议 schema，没有调用文件 API、没有请求用户文件。匿名页面不证明校外登录、UIS SSO 或原生客户端 token 协议。

**H**：官方 `fudan-cloud` 连接器先由官方入口 + 用户可控认证开始，后续仅文件夹列表、元数据、手动选定下载。模型 `RemoteFile {opaque_id,parent_id,name,mime,size,modified_at,etag,downloadable}`，不用含账号的绝对远端路径充当全局键。路径、分享 URL、临时签名 URL 视为敏感信息；默认不导入全盘、不自动建立公开搜索索引。Proto schema/分页/ACL 未验证前，不实现猜测的 REST/WebDAV 客户端。上传、删除、重命名、同步回写、分享链接创建一律不属于首版。

### 校园地图

**D**：[信息办地图说明](https://icampus.fudan.edu.cn/xydt/)描述四校区与建筑/设施；[总务处官方问答](https://zongwuchu.fudan.edu.cn/39413/list.htm)确认 `map.fudan.edu.cn`。静态说明的数量是历史介绍，不是本次枚举结果。

**P**：当前 map 域转入 `zlapp`；共享 app 包的 `schoolMap.model` 为动态模块，命名表可见 `mapGuideIndex:"/map_guide/wap/default/info"`、`schoolMapList:"/map/wap/map/new-list"`、`schoolMapListmap:"/map/wap/map/info"`。未请求上述接口、未验证是否属于当前地图模块、是否需认证、坐标系或分页。不能把 app 包里的其他学校服务当复旦可用功能。

**H**：`fudan-map` 官方插件首批做公共 campus/POI 查询和官方地图打开；`CampusPoi {id,campus,name,category,address,coordinates?,coordinate_system?,official_url}`。未知坐标系时禁止计算距离/导航；照片仅引用来源，不批量复制。定位权限只在用户需要导航时由平台申请；公共楼宇搜索无需采集实时位置。公共 POI 可独立离线缓存，必须保留数据时间与来源；不抓实时人员位置。

### 自助打印：必须区分两套业务

**D**：[图书馆自助打印说明（2024）](https://library.fudan.edu.cn/xszl/e8/ba/c42136a518330/page.htm)明确“云佳印”及 <https://suprint.canon.com.cn>，用于读者文件打印/复印与移动支付；[信息办移动打印公告（2021）](https://xxb.fudan.edu.cn/20/23/c31333a401443/page.htm)明确 eHall“自助打印”用于成绩单/学籍证明等材料和终端分布。它们的账户、文件隐私、订单、收费和终端不能混为一个接口。

**P**：未访问第三方打印业务平台，未登录 eHall，也没有验证订单/设备 API。官方文章存在不表示当下价格/终端分布已现场核实。

**H**：`fudan-print-guide` 首批只有服务分类、当前官方说明链接、终端位置（获得只读接口后）和个人已有订单状态（后续授权）。`PrintTerminal` 标注 `service_kind:library_document|official_certificate` 和支持材料类别；价格保留来源和日期。禁止自动上传正文、建单、支付、发放打印码/二维码；订单取件码不进日志或普通 MCP 查询。只读查看现有订单也不能顺便创建免费订单。

## 跨服务契约与现有代码复用

以下均为 **H：拟议契约**，不是已有 MCP/API 方法。学校协议留在 `dansheng-connectors` 与官方插件；core 不增加复旦特定 HTTP、UIS、Proto 或 DOM 依赖。平台承担可视登录、认证页请求和下载交接；发布 core 不携带 Node/Chromium。

| 拟议来源/权限 | 首批输出 | 隔离与分页 |
| --- | --- | --- |
| `fudan.library.catalog.read` / `fudan.library.catalog` | 书目、馆藏摘要 | 公共；搜索参数/排序/资源类型与 continuation 绑定；前端 `pageNum/pageSize` |
| `fudan.library.loans.read` / `fudan.library.loans` | 当前借阅与到期日期 | account；静态 `pageNo/pageSize`，真实响应确认后适配 |
| `fudan.library.holds.read` / `fudan.library.holds` | 预约状态 | account；未确认分页，不假造全部成功 |
| `fudan.library.discovery.read` / `fudan.library.discovery` | 电子资源元数据/来源链接 | 明确数据库/Primo 来源；不默认全文 |
| `fudan.library.theses.read` / `fudan.library.theses` | 论文元数据 | 公开/校内/账号可见性分开；协议待测 |
| `fudan.career.read` / `fudan.career` | 岗位、公告、活动 | 公开与登录可见分区；静态 `page/size`，稳定 ID 去重 |
| `fudan.onboarding.read` / `fudan.onboarding` | 公告、事项只读状态 | account + cohort；未开放/拒绝/空列表分开 |
| `fudan.aid.opportunities.read`、`fudan.aid.status.read` | 通知/个人状态分权限 | 学段 + account；不采集申请正文 |
| `fudan.cloud.metadata.read`、`fudan.cloud.download` | 有界元数据、选定文件 | account + root；下载独立授权；协议未测 |
| `fudan.map.read` / `fudan.map` | 校区与 POI | 公共缓存；数据版本、坐标系，协议待测 |
| `fudan.print.guide.read` | 说明/终端 | 两类打印不同 source；订单需额外 account 权限 |

可复用的当前仓库事实（本次阅读核实）：

- `crates/dansheng-connectors/src/transport.rs` 已有 `Anonymous`、`HostToken`、`HostSession`、`OptionalSession`、`BrowserSession`；明确禁止缺失能力/认证时偷偷 fallback。采用 BrowserSession 的请求必须在已认证页面中实际执行；不要把 cookie 导出后用 Rust HTTP 冒充该模式。
- `crates/dansheng-connectors/src/core_adapter.rs` 的 `BoundTransport` 检查当前 grant、账号及 source capability，重定向后按 origin 重新选择凭据。新来源应复用而非绕过；`opac`→`fdulspgw`→UIS→第三方必须逐源审核，不能放通 `*.fudan.edu.cn`。
- `crates/dansheng-connectors/src/models.rs` 已有 `SourceContext` / `SourceRecord<T>`，包含 `account_id/source_id/external_id/observed_at/updated_at`。新模型复用来源封套，增加 `official_url`、`visibility`、`schema_version`、`cache_state`、可选 `source_updated_at`，而非覆盖核心来源字段。
- `crates/dansheng-core/src/search.rs` 的来源记录与本地 organizer 查询受各自权限约束。公开书目与私人借阅不能因同名题名而合并 owner；借阅/云盘/奖助默认不进入跨域公开搜索。
- `crates/dansheng-core/src/assets.rs` 已提供受配额/大小约束的托管下载与索引；只有用户选择下载且许可允许的资源才进入此流程，不把临时签名 URL 当持久记录或绕过平台流式下载限制。
- `crates/dansheng-core/src/platform.rs` 的 `PlatformPort` 用于认证/页面执行等平台能力；`services.rs`、`plugin_storage.rs` 可承担可信服务分发与插件私有缓存，不能让插件读取别的插件 token。
- `crates/dansheng-host/SERVICES.md` 的当前 MCP allowlist 并未自动包含本文服务。将来先定义 read 方法与能力再逐项注册；打印码、共享链接、个人借阅完整正文和云盘 token 不通过普通资源 URI 枚举。

共同的 `Page<T>` 建议为 `items,next_cursor?,total?,complete,observed_at`。cursor 是绑定查询、账号、source、schema 的不透明值；真实后端页码只留连接器内部。后端 total 可缺失/变化；重复 ID、页大小被截断、总数增长、空中间页、超过有界页数都需产生 `partial`，不能宣称全量。首版每次 20 条、最多 5 页作为本地预算示例，具体可配置；不是已观察到的服务限额。列表缺席不代表记录被删除，须区分完整快照与局部刷新。

错误统一输出 `AuthenticationRequired / PermissionDenied / NetworkUnavailable / UpstreamChanged / UnsupportedProtocol / PartialResult`；HTTP 200 登录壳、JSON 401、CSRF/验证码页面不能被解析成成功空列表。官方 URL 与同步时间可展示；token、Cookie、签名 URL、用户字段不进入日志、fixture 或导出诊断。

## 实施优先级与离线验收

1. **可立即做的最小增量**：官方入口/来源目录，公开岗位/宣讲信息与公开书目协议验证，地图 POI 协议验证。先通过匿名 GET/经审核只读 POST 获得返回结构，再开发解析；今天只完成入口和静态代码研究。
2. **需用户在官方页面手动登录后再研究**：当前借阅/预约、迎新事项、奖助状态、云盘元数据。授权边界仍只读；验证与脱敏必须在可信平台侧完成，认证材料不入此仓库。
3. **延后**：所有远端写入；全文批量下载；第三方文献传递申请；云盘上传/分享；打印上传/订单/支付。不能借“验证 API”执行这些动作。

本次仅新增文档，没有创建 fixture、实现或运行代码测试。后续应新增**人工合成且符合实测 schema 的**最小 fixtures（每个注明 schema 来源、采样日期、是否合成），不能保存真实用户行。验收至少覆盖：

- OPAC 新门户/旧 Aleph 链接共存、HTTP 200 登录壳、非 JSON、正常空列表、多个单册馆藏、多作者/缺 ISBN/重复记录；catalog 的 `pageNum` 与 loans 的 `pageNo` 不交叉。
- 借阅嵌套和平铺 schema、到期日期与借出日期、Asia/Shanghai 的仅日期字段、未知续借数、401、总数变化；不调用 renew/addRequest；用 fake transport 断言允许的 method/path 与无账号跨读。
- career 的岗位/实习/宣讲 schema、秒/毫秒时间、失效 auth 的错误形状、详情不存在和分页重复；锁值/token 只能是合成哨兵，日志必须不含哨兵。
- 论文只有元数据权限、无全文、IP/DRM 拒绝、延期公开；禁止退回其他下载源获取受限全文。
- 迎新不同 cohort/未开放/已完成/办理中/无资格；奖助本科/研/留学生类别隔离、无状态访问权；个人状态与公开通知不得混索引。
- 云盘未知 Proto schema 报 UnsupportedProtocol、二进制长度限制、Unicode/路径穿越文件名、父目录越权、分享 URL 不落日志、ACL 改变后下载拒绝、无权限时不改走匿名/原生 HTTP。
- 地图 unknown 坐标系、重复楼名跨校区、未知设施分类、过期 POI；不能用未知坐标系计算路线。
- 两类打印终端与订单分开；查询必须不发生上传/建单/支付；包含打印码的模拟响应在归一化/诊断中移除。
- 集成测试通过 fake PlatformPort 与 fake ConnectorTransport 验证认证请求留在 page context，origin/账号/权限撤销/重定向隔离，超时和取消不会偷偷重试写接口。

离线解析测试、跨平台构建、模拟器测试、真实只读校园验证分别报告。完成离线 fixture 不等于真实服务登录可用；今天没有真实用户业务验收。
