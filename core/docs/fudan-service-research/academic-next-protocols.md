# 下一阶段学术只读协议：公共培养方案、研究生目录与课评任务

日期：2026-11-09。此文档是本轮新增协议核验，不重建已接线的本科开课/大纲catalog，也不改其实现。工作仅匿名GET学校公开页面/脚本和一条从公开结果取得的方案详情；没有读取credentials.txt、Vault或个人profile，没有登录，没有执行JS、POST、导出转档、选退课、答卷、评教或其它业务写入。页面/响应只在进程内分析，未复制原始响应为fixture。

证据分级：**P** 为此worker当次匿名GET及schema/分页核验；**S** 为学校当前页面/脚本中的明确调用；**D** 为官方功能说明；**H** 为后续模型/接入建议。P不等于现有Core方法，更不代表个人学业状态已读取。此前研究和真实Core探针另见 [academic-learning.md](academic-learning.md)、[validation.md](validation.md)。

## 优先级结论

| 次序 | 新业务 | 本轮证据 | 接入决策 |
| --- | --- | --- | --- |
| P1 | 公共本科及本研融通培养方案目录/详情 | 官方脚本GET；匿名首页/次页JSON和公开modelId详情200；分页/ID匹配通过 | 已具备实施一个独立官方只读connector的协议基础。它与学期lesson catalog不同，不把公共培养要求当本人已获学分 |
| P2 | 研究生开课/培养方案/学分/学位状态 | 公开gsapp菜单、官方指南；gsportal到统一认证；选课站本轮未获得HTTPS响应 | 保持新个人协议unverified。需要本人研究生角色/服务会话的只读观测，复用已有研课表/成绩，而不猜内部动作名 |
| P3 | 官方课评任务目录/期限/状态 | 教师发展中心公开说明；ce最终为统一认证页；未见业务JSON | 仅可先提供官方入口。待确认任务目录及问卷打开副作用后再写连接器，不自动开始/填写/提交问卷 |

## 公共培养方案：本轮补齐可执行只读协议

**P/S** 公开入口为 [本科及本研融通教学培养方案](https://fdjwgl.fudan.edu.cn/manager/bizType/2/page-center/major-program-search-view?skipAuth=1)。本次无凭据GET200，响应668149字节。页面内嵌`bizTypeId=2`、`baseURI=/bizType/2/page-center/major-program-search-view`和`currentURI`的`skipAuth=1`；脚本把公开模式标题改为“本科及本研融通教学培养方案”。原始HTML title中的本地化占位符不是认证判断。

**S** 当前页面实际引用 [page-index.js?v=00025](https://fdjwgl.fudan.edu.cn/manager/static/tool/js/page-index.js?v=00025)，本次GET200、50989字节。在该脚本`initTable`中，tableSearchUrl由`CONTEXT_PATH + baseURI`、`/search`或学期分支和表单query拼接；`$table.loadData("ajax", {url:tableSearchUrl,type:"get"})`明确是读取。本次已验证的培养查询不带学期路径，页面字段来自查询配置，不能照搬lesson catalog的semester路径。

由页面配置和该GET装配核验的公开请求：

```text
GET https://fdjwgl.fudan.edu.cn/manager/bizType/2/page-center/major-program-search-view/search
    ?skipAuth=1&queryPage__=1,1

GET https://fdjwgl.fudan.edu.cn/manager/bizType/2/page-center/major-program-search-view/search
    ?skipAuth=1&queryPage__=2,1

GET https://fdjwgl.fudan.edu.cn/manager/bizType/2/major-program-search/info/{公开结果的ID}
```

这些查询不是猜测后执行：search来自官方通用页面脚本，info来自页面详情组件；详情ID只取首个公开JSON结果的`ID`，没有枚举/猜ID，也没有使用学号或专业代码作为modelId。`queryPage__`沿用学校表格分页，并以当次实际页码返回验证。

### 当次结果与边界

| 请求 | 当次P证据 | 结论限度 |
| --- | --- | --- |
| search，page1,size1 | HTTP200，322字节，`application/json; charset=UTF-8`；顶层`data/_page_/_sorts_`；1行，currentPage=1、rowsInPage=1、rowsPerPage=1 | 公开目录确有业务JSON；不是登录壳、不是完整遍历 |
| search，page2,size1 | HTTP200；1行，currentPage=2；两页首行ID不同 | 确认分页参数有效；不能据两页推定全部方案可见/稳定 |
| 同批页1的分页总数 | totalRows=6216、totalPages=6216 | 仅该瞬间公开目录报告，不能硬编码/作为全量验收 |
| info，从页1公开ID派生 | HTTP200，1262702字节，JSON；返回`model.id`与请求ID一致 | 证实一个公开详情可读；未逐专业/年度验证，不能推定认证版real-info等价 |

search行的实际键为`YEARS, MAJOR_NAME, MAJOR_ID, DEPART_NAME, AUDIT_STATE, ID, NAME_ZH, DEPART_IDS, ROW_ID`。大小写来自学校接口，不转换成未经验证的lowerCamel参数。页面input/select实际有`YEARS, DEPART_IDS, MAJOR_ID, NAME_ZH`；这是S级筛选键发现，**本轮未验证每种筛选的操作符/多选值编码和结果语义**。`PARENT_URL`等页面导航字段不应开放为用户任意URL参数。

详情顶层实际键：`document, paragraphMode, model, programContent, studyRequire, courseModules`。一个样本有8个paragraph、34个顶层courseModules条目；这些数不是生产限制。

| 数据块 | 已观察结构 | 后续保留与排除建议H |
| --- | --- | --- |
| model | `id/nameZh/nameEn/grade/type/enabled/auditState/credits/duration/termsCount/effectiveOn/invalidOn`以及department/major/education等关联 | 保留方案身份、版本/有效期和公共要求。完整raw model不进普通记录；不把currentNode或关联对象推作本人审批状态 |
| programContent | `id/paragraphs/paragraphHierarchyLevel`；paragraph有`id/indexNo/level/titleZh/titleEn/contentZh/contentEn/instruction/param/paragraphParam` | 章节ID、层级、标题与消毒后正文；HTML惰性化，不运行页面脚本，不持久化隐含认证/签名链接 |
| paragraphMode | 以paragraph ID为键的模式对象，样本出现NORMAL/COURSE_MODULE_SETTING/STUDY_REQUIRE | 类型化已知模式、未知模式保留安全枚举；不依靠固定UUID或数组位置定位章节 |
| courseModules | module有`id/type/requireInfo/limitInfo/nameZh/nameEn/children/parentAssoc/planCourses/...`，同时包含较多管理配置/重复关联 | 有界ID树、父子关系、公共学分/课程要求；不复制循环/重复嵌套、管理权限、edit flags或关联raw objects；去重不能误删同课的不同要求归属 |
| studyRequire | 修读、阶段考核、转入转出与授予条件等schema字段 | 类型化官方公共要求，保持缺省/未知。字段含undergraduate/postgraduate不表示已读取任何人的成绩/学位状态 |
| document | 当次JSON存在该字段，未核验下载契约 | 首批不自动下载或转档；附件需另外审核稳定URL、授权、尺寸与签名剔除，再交托管assets |

页面详情组件在`skipAuth=1`时使用`info/{modelId}`，认证模式使用`real-info/{modelId}`。**real-info未调用、个人对应关系未验证**。公开页还包含html-to-docx转档POST和export-word/real-export-word；它们不是本轮只读数据需求，未执行，不能随详情自动调用。

### 独立connector与验收建议H

建议新模块`FudanProgramClient<T>`，复用`ConnectorTransport`、`SourceContext/SourceRecord`和schema错误，而非把培养方案塞进`FudanAcademicCatalogClient`或timetable模型。建议业务名`fudan.programs.list/detail`、能力`fudan.programs.read`，是设计建议，尚未注册。

- origin和公共路径固定在官方connector，传输显式Anonymous；认证挑战不自动切real-info或重登。
- ID以十进制字符串保留；`biz_type/program_id/major_id`域分开。详情必须校验请求ID；进一步需要公共列表来源的ID绑定或等价授权检查。
- 目录有界页/页大小/bytes/条目数；完整sync若后页失败，不把partial写成完整snapshot。不同筛选/年级/学段的source/checkpoint分区独立。
- 详情样本已约1.26MB，应明确正文/节点/深度/总bytes预算；安全处理parent/children与重复关联，不无限递归。未验证的`realPlanCourses`不推定个人选课。
- 成功空页、未开放/认证壳、重复/大ID、不同方案版本、字段改名、非JSON、HTTP403/404/500、页码/total变化、第二页失败均有人工合成fixture。
- 测试必须断言只有被发现的GET路径、无POST/导出、无签名值/脚本残留；匿名真实入口、第二页和已观察详情另作当前生产Core只读验收。
- 公共要求和本人`AcademicProgress`独立；学校学分/毕业认定原样保留，本地计算标辅助，不因缺少个人状态返回零学分。

## 研究生目录：官方入口明确，个人数据协议仍unverified

**P** 本次 [gsapp](https://gsapp.fudan.edu.cn/) GET200、7871字节，保持同origin，公开菜单链接如下。它们是S级入口，不是已执行个人API：

| 功能 | 菜单发现的入口 |
| --- | --- |
| 课表 | `https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdkbapp/*default/index.do` |
| 成绩 | `https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdcjapp/*default/index.do` |
| 培养方案 | `https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdpyfaappfudan/*default/index.do` |
| 课程评教 | `https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddxspjappfudan/*default/index.do` |
| 毕业与学位 | `https://yzsfwapp.fudan.edu.cn/gsapp/sys/yddwdxwappfudan/*default/index.do` |

**P** 综合入口`https://gsportal.fudan.edu.cn/yjsmhpublicapp/sys/fddxyjsmhxt/index.do`本次HTTP200，最终origin为`https://id.fudan.edu.cn`、path为`/ac/`，6328字节。这是认证页面边界，不是研究生培养JSON。粗略login关键字没有匹配，反而说明不能用单一正则或HTTP200判定业务读取成功。文档没有保存身份认证重定向query或Cookie。

**P/D** 官方FAQ曾给出`http://yjsxk.fudan.edu.cn/wsxk`。本次只请求其HTTPS对应入口，没有获得HTTP响应（HttpRequestException）；没有登录、改代理、切校内网或枚举其它端点。此结果不能认定旧官方入口下线，也不能区分TLS/网络/访问条件，不作为连接器协议。

[信息办研究生选课说明](https://xxb.fudan.edu.cn/yjsxk_41707/list.htm)确认开课查询、培养方案关联、课程冲突提示和本研贯通。它是功能来源，不包含可复用的匿名JSON端点。[研究生FAQ（2024）](https://gs.fudan.edu.cn/1c/e9/c12939a662761/page.htm)说明本人UIS进入eHall培养方案、选课系统查看学分明细及大纲；该历史说明的开放时间/限制不能作为2026运行参数。

后续只读发现H：由主线程/可信宿主先确认研究生身份与站点绑定，再在本人主动进入的页面观察目录XHR的确切GET/只读POST语义、request字段、分页和schema。`fudan.graduate.offered_courses/program/credit_status/degree_status`仍只是建议名；不能把其它学校金智的`queryXs...`/BH/RZ/RW等动作名拼接后执行。若数据依赖页面context，使用BrowserSession，不以导出cookie+Rust HTTP替代。已实现的研究生课表/成绩保持复用，不重复建设。

只同步必要的公开开课目录或本人阶段/期限/官方状态；不自动申请学位、选导师、选退课、上传论文/材料、读取评阅正文/专家身份。离线覆盖学段错误、未开流程、空数据、部分权限、未知状态、角色不符和方案版本变更。

## 官方课评任务：认证边界与副作用尚未验证

**P** 本次`https://ce.fudan.edu.cn/`匿名GET200，最终同样为`https://id.fudan.edu.cn/ac/`、6328字节；没有观察到课评任务业务JSON。未读取该页个人登录态，也未跟踪任何问卷动作。

[教师发展中心入口](https://cfd.fudan.edu.cn/yuyue2/demo.asp)明确官方课评网站和微信“复旦课评”、使用统一身份认证。[教学门户2026上线说明](https://ecampus.fudan.edu.cn/c7/d1/c31333a772049/page.htm)说明开放事项/学业进展等门户功能，并不披露课评任务协议。这些D级来源不授予全校结果访问权，也不能与蛋壳社区评价混淆。

首批H只建议`fudan.evaluation.tasks`：本人可见任务ID、学期、课程引用、开放/截止、学校已评价/未开放/已关闭状态和安全官方入口。确切路由、任务表单ID、状态枚举、匿名性字段和分页全部unverified，**本轮没有可发布连接器接口**。

问卷详情GET可能创建答卷、写入浏览态或签发提交上下文；未核验前不把它登记为普通read/sync，不自动打开以“查状态”。先目录只读或人工原站跳转；任何答分、填写、生成提交、完成标记或提交动作需要独立协议和具体授权。读接口fixture应包含已完成/多角色/未开放/截止、登录壳、未知问卷模板、匿名字段剔除和中途错误，不能伪造学校“已完成”状态。

## 接入前仍需主线程核验

| 项目 | 已满足 | 未满足 |
| --- | --- | --- |
| 公共培养方案list/detail | 官方当前GET装配、匿名两页JSON、从结果ID取详情、model.id匹配 | 客户端/类型/权限/来源缓存/SDK/MCP、筛选语义、多版本/深度/容量fixture、当前生产Core跨平台执行 |
| 研究生公共菜单 | 公开入口及功能链接、认证边界 | 当前个人业务路由/身份/响应/分页/可见性、网络条件及生产接线 |
| 官方课评任务 | 官方功能入口、认证边界 | 任务目录协议、匿名性、问卷打开副作用、状态/期限字段、生产实现和任何真实用户验收 |

以上P级探测由命令执行工具的匿名HTTP请求完成，属于独立协议研究；不是Engine、Host或MCP端到端调用。无账号访问没有复旦本人数据；当前Canvas401、本科个人课表500和my交互门槛不因公共培养详情200而消失。
