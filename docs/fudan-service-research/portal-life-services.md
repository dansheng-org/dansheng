# 门户与校园生活服务接入研究

调查日期：2026-11-09。本文仅研究公开官网、无凭据 GET、公开前端脚本、现有连接器及 Android 门户适配器；未读取 credentials.txt 或用户 profile，未登录、提交表单、预约、取消、付款、发信、上传或收藏。新方法名均为设计建议，未实现。仅新增本文，不改教学、图书馆研究或产品代码。

## 证据分级与主要判断

- **P：公开实测**：无 Cookie、无认证的 GET 获得实际页面/JSON；只报告本次观察，不代表登录后业务已通过。
- **S：静态发现**：官网引用的公开 JS 或既存公开 JS 缓存中有调用路径、字段、方法；不是已执行该 API，也不是当前稳定契约证明。
- **D：官方说明**：官网指南确认功能；没有因此推定内部 API。
- **H：接入设计**：建议的模型、权限、方法及验收；不是现有能力。

最可直接推进的是 eHall 公共服务目录和个人任务只读适配。目录本轮匿名返回真实 JSON，但字段 total=0 与 list 长度 192 不一致，不能按 total 判空或声称覆盖所有服务。个人任务已从公开前端确定 GET 路径及分页形状，尚未登录读取。my 数据中心、eCard、宿舍用电已有部分连接器，应扩展而非重写。公共会场/集体场馆审批与个人体育预约不是同一业务；智慧体育新系统也不能用旧刷锻页充当已兼容。

## 官方说明与功能边界

| 服务 | 官方证据与入口 | 业务范围及当前缺口 |
| --- | --- | --- |
| eHall | [4.0 上线公告](https://ecampus.fudan.edu.cn/40/39/c33159a737337/page.htm)、[大厅介绍](https://ecampus.fudan.edu.cn/xxxtjs/list.htm)、[移动服务](https://ecampus.fudan.edu.cn/fdeHallxcx/list.htm) | D：统一任务中心区分待办、已办、申请，支持条件搜索；网上申办流程可追溯。移动服务列有户籍证明、组织关系、场地和临时卡延期。现有 Core 没有通用服务目录/我的申请/审批轨迹/证明管理。公开文案不证明任意申请都有可下载证书。 |
| my 数据中心 | [移动服务介绍](https://ecampus.fudan.edu.cn/fdeHallxcx/list.htm)、本轮 my 首页认证重定向 | D/P：个人数据入口需认证；已有成绩/餐饮/电量历史是有限表，不是全量个人档案。 |
| eCard | [官方指南](https://ecampus.fudan.edu.cn/xyyktsyzn/list.htm)、https://ecard.fudan.edu.cn | D：余额流水、生活码、挂失解挂、充值、限额/消费密码、消费与认证历史。已有余额、交易、QR 状态/可信展示；卡务、认证历史和充值未见业务适配。小程序存在不证明原生 NFC/SE 卡模拟能力。 |
| 宿舍用电 | [elife 操作手册](https://elife.fudan.edu.cn/operateFile/Manual.pdf)、当前 eHall 目录的 zlapp 入口 | D：宿舍选择、表读数/剩余电量、按月用电记录、购电记录、待付款单及支付。现有当前电量及 my 历史不等于覆盖全部 elife 字段和订单。旧手册为历史功能证据，当前目录指向不同入口，不能直接按手册猜 API。 |
| 场地审批 | [总务处指南](https://www.xyfw.fudan.edu.cn/39412/list.htm)、[新预约平台公告](https://ecampus.fudan.edu.cn/c7/cc/c33159a772044/page.htm) | D：公共会场包含会议讲座审批、授权码、预约与结单；集体体育借用、专业文体场馆另有审批。已有个人场馆预约/取消及定时插件不覆盖单位审批与公共会场流程。权限因身份/场地不同，不能把教职工业务默认开放给学生。 |
| 智慧体育 | [2026 考勤说明](https://fdty.fudan.edu.cn/5b/c8/c29222a482248/page.htm)、[学生端手册](https://fdty.fudan.edu.cn/_upload/article/files/a5/20/7678c8f5411d9407085d9d22e248/fd4a3077-f435-43f3-ba72-d2167a398de6.pdf) | D：小程序自 2023 上线，提供通知、个人码、运动记录、统计、排行及申诉；2026 查询指向“考勤与体测”。旧 fdtyjw 查询不能证明新系统兼容。首批只读，不做运动打卡、定位或申诉提交。 |
| 信息办报修 | [官方服务介绍](https://ecampus.fudan.edu.cn/wxbxpt/list.htm)、[信息化支撑](https://icampus.fudan.edu.cn/xxhzcfw/list.htm) | D：网络/一卡通报修、评价和回访，公众号菜单提供 UIS 入口。未发现可验证的公开工单 API；不把总务设施报修与信息办网络报修混成一个系统。 |

## 本轮公开 GET 与前端发现

### 探测记录 P

| GET | 本次结果 | 可得结论 |
| --- | --- | --- |
| `https://ehall.fudan.edu.cn/` | HTTP 200，标题“网上办事服务大厅” | 官网壳和直接引用的静态脚本可读。 |
| `https://ehall.fudan.edu.cn/appmarket/frontend/default/getApp?type=all` | HTTP 200 JSON，顶层 e/m/d，e=0；d 有 showSubCate/cates/list/total，list=192、total=0 | 匿名可读服务目录片段。没有调用收藏、跳转或任何个人接口；不能用 total=0 判断没有应用，也不能把匿名 has_permission 当账号授权。 |
| `https://my.fudan.edu.cn/` | HTTP 200，最终为 id.fudan.edu.cn 认证页 | 只是认证边界，未访问个人表。认证上下文/锁定参数不保存。 |
| `https://elife.fudan.edu.cn/` | 命令工具返回 InvalidOperationException | 没有可用响应证据，不能判定服务停机或接口不存在；公开手册可读。 |
| `https://booking.fudan.edu.cn/reservation/fe/site/special/special?id=48` | HTTP 200 页面壳，含 WAF 脚本及 bookingassets 引用 | 不是预约数据或有效会话证据；没有请求预约 API。 |

目录仅摘录非个人服务标识；没有导出原始目录响应（其中还有不需要持久化的联系人字段）。可重查的公开服务例：

| 本轮目录 id/name | extra_url.pc_url | 说明 |
| --- | --- | --- |
| 30019 一卡通信息查询 | `https://my.fudan.edu.cn/simple_list/ykt_xx` | P：目录字段；没有打开个人数据页。 |
| 30051 体育场馆集体借用 | `https://booking.fudan.edu.cn/reservation/fe/site/special/special?id=48` | P：与个人体育专题同入口并不表示表单/权限相同。 |
| 30119 宿舍电费充值 | `https://zlapp.fudan.edu.cn/site/fudanElectric/index?type=1` | P：比旧 elife 手册更直接的当前目录入口；未执行充值。 |
| 30221 校内会议讲座审批 | `https://myform.fudan.edu.cn/create/xcb_hcjyjsp` | P：是办件入口，不是已经确认的提交 API；本轮未打开 create 页面。 |

这些 id 是本轮观察，生产从目录发现并做类型/域校验，不能凭编号范围构造更多事项。

### eHall 前端 S：明确方法、路由和字段

本轮从首页发现并无凭据 GET 读取以下公开脚本；散列会变化，应重新从首页解析，不能长期锁定：

- [主包 index-XrYuYnyJ.js](https://ehallassets.fudan.edu.cn/vpage/project1/page1/assets/index-XrYuYnyJ.js)：配置 `withCredentials:true`，请求基址由当前页面计算，设置 X-Requested-With；包含 GET `/personal/frontend/data/info`。
- [DSL 配置 dls.js](https://ehallassets.fudan.edu.cn/vpage/project1/page1/dls.js?timestamp=20260907210358)：当前任务 tab 的 ajaxUrl、服务目录配置。
- [任务组件 index-PS69NXBl.js](https://ehallassets.fudan.edu.cn/vpage/project1/page1/assets/index-PS69NXBl.js)：用 `method:"get"` 加 page/pageSize 调用 DSL 的 ajaxUrl；读取 d.list/d.total；含 userLanguage 请求头。
- [目录组件 index-BBl2VKXo.js](https://ehallassets.fudan.edu.cn/vpage/project1/page1/assets/index-BBl2VKXo.js)：明确 GET 目录，PUT 收藏；后者本轮没有调用。

| 路径（同源 https://ehall.fudan.edu.cn） | 方法与已见参数 | 静态契约/限制 |
| --- | --- | --- |
| `/appmarket/frontend/default/getApp` | GET `type=all|collect,limit,cate_id` | 目录 GET 已 P；collect 表示个人订阅，未测。d.list 字段有 id/name/icon/dsc/keywords/extra_url/category_name/cate_ids/app_kind/has_permission 等。候选关键字搜索是否由服务端支持待核，首批可在有界缓存内筛选。 |
| `/personal/frontend/task` | GET `type=todo|done,page,pageSize` | DSL 默认一度给出 pageSize=999999；适配器禁止照抄，建议每页 20–50、最大 100。 |
| `/personal/frontend/task/apply` | GET `type=all,page,pageSize` | 我的申请；d.list/d.total 来自组件。未测空列表、身份和分页实际语义。 |
| `/personal/frontend/task/notify` | GET `notify_status,page,pageSize` | 我的知会；未读查询 notify_status=0。读取是否改变已读状态尚待确认。 |
| `/personal/frontend/data/info` | GET | eHall 身份信息，不是 my.fudan.edu.cn 的全量数据中心。 |
| `/ucs/frontend/msg/index` | GET `keyword,ucs_type,source,starttime,page,pagesize,status` | 组件存在消息计数调用，不等于已拿到消息内容/业务权限。 |
| `/appmarket/frontend/default/collect` | **PUT** `app_id,opera=add|del` | 明确收藏写入，排除首批只读和匿名探测。 |

任务组件还读取 `form_url_view`、`process_pic_url`、知会 `url`。这是服务端下发的查看/流程图链接，不是固定的“审批轨迹 JSON API”。不得自动解引用任意跨域 URL，更不能把含 task/token 的链接交给 MCP 或日志。首批返回标题/状态/节点/时间和安全内部引用，流程链接交给可信 UI；读取完整轨迹、证书下载仍需登录发现。

任务组件包含其它高校分支（例如广州高校地址），那是通用产品包，不是复旦服务证据；只采用复旦 DSL 实际引用的分支。

### 预约平台公共 JS 缓存 S

实际缓存位于 **`C:/Code/dansheng-app/.local/ehall-booking-bundles`**，主 Core 的 `.local/ehall-booking-bundles` 不存在。只读取该公开 JS 目录；不扫描相邻 profile 或凭据。

`entry.76b5bf62.js` 的 action→path 映射存在：

```text
site/appointmentDetail -> /site/appointment/appointment-detail
site/getProcessUrl    -> /site/appointment/get-process-url
site/resourceLaunch   -> /site/resource/launch
```

同包还有 `/site/appointment/appointment-voucher-detail`、`/api/app/list`、`/api/app/get-items`、`/api/app/proc` 等字符串。此处只是静态路径映射，没有独立确认每个 action 的 HTTP method、参数或只读性；尤其 proc、launch、签入、上传、授权操作不能因为存在路径而探测。生产 URL 常有 `/reservation` 前缀，应按现有客户端和运行时配置确认，不凭缓存字符串盲拼。

已有插件协议的 method 才可直接确认：`plugins/builtin/fudan-venues/api.mjs:48` 的 request 在 fields 缺省时 GET、有 fields 时 POST，固定 PATHS 在同文件第 10 行。现有 `main.mjs`/政策文件对个体预约有具体验证；集体审批、授权码、流程轨迹不能复用为“已经支持”。缓存调用链和登录后响应是下一步证据需求。

## 现有实现与可复用平台边界

| 当前源码 | 已确定实现 |
| --- | --- |
| `crates/dansheng-connectors/src/core_adapter.rs:227` | 复旦课表、成绩、GPA、eCard、用电、人数、空教室、体育、校车、公告、QR 等服务方法；没有通用 eHall。 |
| `crates/dansheng-connectors/src/campus.rs:1319` | my 成绩表 `/data_tables/bks_xx_cj.json`。 |
| `crates/dansheng-connectors/src/energy_history.rs:270` | POST `/data_tables/ykt_xszsqyydqk.json`，multipart draw/start/length；PageWindow 有界分页；只读查询 POST 不是支付。 |
| `crates/dansheng-connectors/src/campus.rs:1406` | GET `/epay/myepay/index` 余额。交易先 GET `/epay/consume/index` 取 CSRF，再只读 POST `/epay/consume/query`，带 pageNo、日期窗等；日期窗≤366天、页≤10000。 |
| `crates/dansheng-connectors/src/campus.rs:1474` | zlapp `/fudanelec/wap/default/info` 当前电量。 |
| `crates/dansheng-connectors/src/campus.rs:1566` | fdtyjw 旧体育查询，待核新系统。 |
| `crates/dansheng-connectors/src/campus.rs:1642` | QR 状态与可信展示路径；展示是凭据操作，不得作为普通查询/MCP 内容返回。 |
| `C:/Code/dansheng-app/android/app/src/main/kotlin/org/dansheng/app/CampusPortalActivity.kt:20` | 专用 WebView entry 为 my `/simple_list/stqk`；在学校页面完成身份流程，再以 Canvas profile 核对同一账号并移交会话。当前 allowed host 只有 my、id、uis、elearning，不含 eHall/eCard/booking/zlapp。 |

CampusPortalActivity 不是现成的通用 eHall 浏览器：不能直接扩大 allowed 集合就假设账号检查、跳转、凭据共享都成立。主代理可复用现有 Login/Core 的固定 GET 和单次认证探针，但要分别报告“身份中心通过”“服务绑定/本人核对通过”“业务响应解析通过”。本次没有运行这些探针。

学校端点、字段、状态映射和角色规则放 `dansheng-connectors` 的官方模块或有明确 grants 的官方插件；不进 generic Core。浏览器/WAF 域必须在已认证页面执行 fetch/XHR，缺少平台口返回 CapabilityUnavailable/WafChallengeRequired；不以 Rust HTTP 静默替换。公开纯 HTTP 查询和已有明确 HttpSession 连接器可保留各自既有契约，不能以此授权把任意浏览器会话导入网络层。

## 首批只读接口与模型 H

建议 P0 目录；P1 任务和现有门户表扩展；P2 卡片认证历史、elife 订单/记录、智慧体育/报修只读（后者先发现协议）。以下均是建议，未注册为真实 Core/MCP 方法。

| 建议方法 | 最小模型 | 账号/权限和分页 |
| --- | --- | --- |
| `fudan.ehall.catalog` | ServiceSummary{id,title,description,category,platforms,availability,ref,observed_at} | `fudan.ehall.catalog.read`；匿名目录与个人可用性分区存储。limit≤100，原站分页不明时返回 bounded/unknown coverage，不能宣称 complete。 |
| `fudan.ehall.tasks` | TaskSummary{id,kind,status,title,current_step,submitted_at,updated_at,ref} | `fudan.ehall.tasks.read` + account grant；kind=todo/done/application/notification，page≥1、page_size≤50，最大页数/响应体/时间预算；不返回发起人全量信息和原始外链。 |
| `fudan.ehall.task.read` | TaskDetail{summary,steps?,attachments?,coverage} | 同账号/来源权限。步骤、证书/附件只能在协议已验证后开放；未发现时返回 capability unavailable，不能伪造空轨迹。 |
| `fudan.portal.tables.list/read` | 固定 TableDefinition + typed rows | 建议先做固定官方表枚举，不接受任意 table/path/SQL；按数据域细分 academic/card/life grants，而非一个万能 personal-data grant。 |
| `fudan.ecard.auth_records` | CardAuthEvent{id,time,location,event_kind,result} | 新 `fudan.card.identity_history.read` + account；日期窗、游标和延迟明确；不含生活码/token。待登录发现路径，不能套交易 API。 |
| `fudan.energy.rooms/status/usage/orders` | DormRef、EnergySnapshot、DailyUsage、PurchaseOrderSummary | `fudan.life.energy.read`；房间必须来自本人授权列表；用电与购电分页分开；RMB 用整数分，kWh 用十进制定点/原单位，缺值不当零。 |
| `fudan.pe.activities/summary` | ExerciseRecord、PeriodSummary、source/semester/rule_version | `fudan.pe.read` + account；新旧来源明确，状态 unknown/invalid 不当有效刷锻；不采集原始 GPS 轨迹。 |
| `fudan.repairs.list/read` | RepairTicket{id,category,status,created_at,steps} | `fudan.repairs.read` + account；个人电话、地址、图片不默认进搜索；路径及读是否标已读仍待发现。 |

MCP 只暴露上述已实现且通过审核的读方法，复用现有 core_call allowlist + account/source/domain ACL；不能把设计名一次性放入 allowlist。目录可返回经域校验的公开原站入口，个人详情用内部 ref。任务来源同步到现有活动/待办时存远端来源引用，保留本地完成状态与远端审批状态区别；不可在本地 complete 后声称远端已办。

分页验收必须容忍目录 total 不可靠、未知总量、空末页、重复页、排序变化；遇到单页失败保留上次快照并返回 incomplete。初次全量和增量均设 page/item/byte/time 预算；不照抄 DSL 的 999999/9999，也不因“只读”无限并发。

## 后续写入的单独授权与对账 H

首批不开放申办、审批、收藏、充值、挂失、密码/限额、报修提交、运动打卡。后续每种动作都要单独验证端点语义和授权，不提供任意 URL/method/form 的代理工具。

1. 预览读取最新服务状态，绑定账号、动作、服务/目标 ID、表单版本、资料摘要、金额币种、收款/充值对象、费用、附件资产 hash、资格条件和有效期；以规范化输入 hash 生成具体审批对象，秘密/票据不进入预览。
2. 用户批准这个具体 hash；MCP/插件 principal 的输入绑定由可信宿主授予，调用方 confirm=true 本身不能授权。审批权限不能由“能看到待办”推导。
3. 提交前再次校验资格/余额/价格/目标，持久化 mutation ledger；远端提供幂等键才按其契约使用，没有则禁止用猜测键声称幂等。
4. 提交后超时/断网/崩溃为 uncertain，禁止自动重试。按服务端申请号/订单号/交易号核对状态；充值创建订单与支付分开，支付优先交官方收银台。余额变化不单独证明某订单成功；任务从首页消失不证明撤回成功。
5. 无权读到权威结果时要求可信 owner 在官网核对并登记证据摘要；不能靠首屏未见记录认定未提交。成功/不确定动作封存原预览，状态变化需要新预览。

## 有意义的离线验收 H

- eHall 目录：用合成目录固定复现 list 非空/total=0、无权限项、分类/多平台 extra_url、缺字段、超大正文、重复 ID、跨域/带用户信息 URL；只向授权 UI 返回安全入口。匿名 has_permission=y 不能赋予业务权。
- 任务：todo/done/application/notification 不混；本人账号和账号切换缓存隔离；第二页失败不能覆盖为全量；未知状态保留 raw enum 的脱敏映射；重定向登录或 HTML/WAF 不解析为零任务。
- 轨迹和附件：服务端 form_url_view/process_pic_url 含签名或非白名单域时不进入日志/FTS/MCP；静态图片不得伪称机器可读审批轨迹；下载需 asset 权限与尺寸上限。
- eCard/energy：交易方向/金额精度、卡认证与消费严格区分、房间不归属拒绝、CSRF 到期、日期窗和分页边界；current、usage、purchase、unpaid 各自时间和 coverage 不混淆。
- 体育：同一记录新旧系统来源和学期隔离，待审核/无效不计有效，规则变化不硬编码到 generic Core；统计与明细不相等时返回差异而非补造记录。
- 写入账本：模拟服务端已接受但丢响应、进程重启、相同预览重复提交、旧权限撤销、同额不同订单、附件变化；验证不二次提交并允许只读对账。全套离线 fixture 使用合成人名、单号、手机号和图像，不复制真实页面或个人响应。

这些是验收计划，本研究未运行测试；不得把它们表述为已经通过。

## 待登录发现步骤（由主代理执行）

1. 先用现有 Core/Login 固定 GET 确认认证边界；每次只发起一次明确登录流程，MFA/扫码交用户。观察服务自身成功页面与本人标识，不把 HTTP 200 或凭据已加载当成功。
2. eHall 在认证页面手动打开任务 tab，抓一页 network 调用的 method/path、分页及响应 schema；目录继续按当前前端发现，核对角色差异。只记录结构/计数/脱敏示例，不导出 Cookie/token/审批人姓名或原始签名 URL。
3. 点击已有申请的“查看”前确认不会接单/改变状态；核对流程图、轨迹、附件和证书是否独立 API，记录是否有 read-side mutation。没有本人申请时只标 unavailable/no-fixture，不能新建测试申请。
4. my 只点现有固定表，确认表目录和数据标签；eCard 只打开卡信息、认证历史；能源只选本人宿舍的用电/购电/待付款查询，不点充值或支付。读 POST 必须由抓包/前端调用验证语义。
5. 智慧体育/报修：从官方入口核对小程序/网页域、授权方式、本人只读记录，先确认 WebView 是否有合法可用入口；不能从包中提取用户 token，也不能重放运动打卡或定位。无可调用公开协议时提供官方跳转。
6. 公共场馆读既有审批/预约详情，检查集体资格、授权码与个人预约差异，不发新申请。缓存 JS 的 proc/launch 等必须停留静态审计，直到具体写入获得额外授权。

研究产物不含原始公开 JS 包、认证上下文、个人数据或凭据。主代理的真实探针结果应另以脱敏摘要追加，并与本文 P/S/D/H 分级逐项对应。
