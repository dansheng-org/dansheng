# 复旦服务接入研究

研究日期：2026-11-09。工作目录：`C:/Code/dansheng`；分支：`codex/fudan-service-research`。

研究批次完成协议研究、接入设计和独立原生只读探针；后续生产实施已接线本科目录/大纲、公共培养方案、eHall、图书馆和Canvas学习方法。当前代码与实读结果见[接入实施](implementation.md)，已接收和仍未接入项见[需求矩阵](delivery-matrix.md)，三平台验证与成对release/解包执行见[最终分层验证](final-validation.md)。下文优先级保留研究时状态，生产UI继续由独立App承担。

后续实施修改了官方连接器、通用网络/凭据能力、宿主类型及 Android 平台适配，按实施清单另行审计，不沿用研究工具批次“原文件改变0”的结论。

## 分支与工作区

当前仓库尚无首次提交，HEAD 原来指向未产生提交的 `main`。本轮将 HEAD 设置到未产生提交的研究分支，没有创建提交，也没有改变原有暂存状态。普通基于提交的 worktree 此时不能建立。

原工作区源文件清单和 index 指纹保存在仓库外 `%LOCALAPPDATA%/dansheng-research/20261109-fudan-services/` 的 `source-before.json` 与 `branch-journal.json`。研究文件集中在 `docs/fudan-service-research/` 和 `tools/fudan-service-research/`；验收时按这两个范围核对新增文件及原文件指纹。

## 最先实施的范围

| 批次 | 接入内容 | 已有依据 | 首批实现落点 |
| --- | --- | --- | --- |
| P0-A | 本科全校开课、目录中的课程信息、教学大纲、公开学期目录 | 公开页面给出实际请求路径；匿名 JSON、分页及大纲页已读取；真实 Core 已复核；独立课程详情样本404，先不依赖 | 官方 `academic_catalog` Rust 连接器，复用 `ConnectorTransport`、`SourceRecord` 和有界分页 |
| P0-B | eHall 公共服务目录 | 匿名 GET 返回 e/m/d 封套及服务列表；total=0 与非空 list 不一致，limit=1 未截断列表 | 官方 `ehall` Rust 连接器；来源目录、分类与安全的原站入口；客户端预算与未知覆盖率明确保留 |
| P1-A | eHall 待办、已办、我的申请 | 公开 DSL 与组件确认 GET 路径、page/pageSize、d.list/d.total；本人业务尚未验证 | 先实现服务自身认证/账号核对，再加只读任务连接器；保留远端状态和本地待办的区别 |
| P1-B | 图书馆馆藏、当前借阅、预约状态 | OPAC JS 给出 fdulspgw 路径和 access_token 头；Primo 配置 JSON 已验证，推导的搜索请求403 | 图书馆认证提供者和只读连接器；公共书目、私人借阅、历史分来源/权限 |
| P1-C | Canvas 经典测验、讨论、本人提交、作业分组 | Instructure 标准 GET 契约；当前已有 CanvasClient；本轮保存 Token 的 profile 请求401 | 在现有 `canvas.rs` 扩展；恢复有效认证后再做真实服务验收，不新建远程 Token |
| P2 | 公共培养方案、个人学分进展、研究生培养/学位状态、官方评教任务 | 部分公开入口/脚本和官方说明；个人 XHR 尚待发现 | 官方学术模块，明确学段/角色；学校认定与本地辅助计算分开 |
| P2 | 电卡认证历史、用电/购电记录、智慧体育记录、报修进度、就业/迎新/奖助 | 当前目录、公开脚本或官方指南；多数个人协议未验证 | 扩展现有 card/life 连接器及独立官方服务模块；先目录和只读状态 |
| P3 | icourse、校园云盘、地图/打印细节 | icourse DNS 未解析；云盘为 Proto 调用；地图与打印各有独立协议/业务 | 先解决网络、认证及字节传输，再做元数据；播放/上传/支付独立设计 |
| 后续写入 | 选退课、评教/作业提交、续借/预约、申请审批、充值/支付、挂失/限额 | 仅研究了部分官方功能或静态调用 | 每个动作单独验证、预览授权和结果对账；本轮没有执行这些业务操作 |

## P0 的具体接口

本科公开目录：

```text
GET /student/for-all/lesson-search
GET /student/for-all/lesson-search/semester/{semesterId}/search/{semesterId}
    ?queryPage__={page},{pageSize}
GET /student/for-all/lesson-search/info/{courseId}
GET /student/for-all/lesson-search/check-can-info?id={lessonId}
GET /student/for-all/lesson-search/teachingSyllabusInfo/{lessonId}
```

`semesterId` 从页面发现，`courseId` 与 `lessonId` 分开。研究探针的 527 只是 2026-11-09 的定点样本，生产连接器不能硬编码。目录具有 `_page_` 和 `_sorts_`，不根据第一页或学校当前目录规模推断全量。建议 API：`fudan.catalog.semesters/lessons/course/syllabus`，其中 course 首批从目录数据投影，独立 info URL 的样本404（包含页面公开的 REDIRECT_URL 参数也404），暂不作为稳定详情端点。check-can-info 返回 null 时前端没有收到禁止原因；非空返回用于显示 res.text，不应解析成普通 bool 或“缺数据”。

eHall：

```text
GET /appmarket/frontend/default/getApp?type=all
GET /personal/frontend/task?type=todo|done&page={page}&pageSize={pageSize}
GET /personal/frontend/task/apply?type=all&page={page}&pageSize={pageSize}
GET /personal/frontend/data/info
```

目录公开查询与个人可用性分区。`has_permission` 的匿名值不赋予账号权限；不能照抄前端 999999 的分页预算，也不能假定 limit 已被服务器执行。本轮两种 limit 条件均返回192项、total=0，应在有界响应内执行本地预算并保留未知覆盖率。个人任务原始查看/流程图 URL 不进普通 MCP、日志或全文索引；通过可信宿主的内部引用按需打开。

## 需要先补齐的通用接缝

1. **按服务绑定的认证提供者。** 现有原生 LoginTarget 只有固定服务；my、eHall、图书馆、研究生和课评不能因为都使用 UIS 就共享一个“已登录”标记。服务自身的私有读取及账号核对完成后才登记有效绑定；交互验证由平台宿主承担。
2. **Rust 连接器的页面上下文传输。** 当前 `core_adapter.rs` 的 BoundTransport 对 BrowserSession 明确返回 CapabilityUnavailable。不能只把枚举改成 BrowserSession 就宣称可用。需要由可信宿主传入已绑定的页面/session 句柄，或先采用已有官方 JS 插件/browser.request 路线；缺能力时保留明确失败。
3. **非标准凭据头。** 当前 HostToken 对应 Bearer，OPAC 使用 access_token。由可信宿主/原生官方服务解析凭据引用并注入，秘密不返回普通 JS 或 MCP；不能把 access_token 塞成 Authorization Bearer 就当兼容。
4. **有界的二进制请求/响应。** ConnectorRequest 本身可持有字节，但当前 BoundTransport 将请求体转换为 UTF-8 String，响应也来自 Core 的文本 body。云盘 Proto 请求需要通用字节传输或经授权的宿主桥，学校 Proto schema 留在连接器，不能加入共享 Core。
5. **每个来源的网络条件。** cloud 本次解析到校园私网，默认 Core 权限拒绝有明确原因；只允许具体 HTTPS 来源，或配置已验证网关。MCP 不借用 Owner 研究策略提权。icourse 的 DNS/校园网条件另行验证。

详细设计见 [架构与契约](architecture.md)。

## 首个实施批次的文件范围

建议下一次实施只包含两个公开连接器，先取得稳定闭环：

- 新增 `crates/dansheng-connectors/src/academic_catalog.rs`、`src/ehall.rs`；只加入公开目录方法，默认匿名。
- 在 connectors 的 `lib.rs`、`core_adapter.rs` 注册类型化只读方法及来源权限；Core engine 不写复旦路径。
- 新增人工合成的 `fixtures/academic_catalog/` 与 `fixtures/ehall/`、对应离线测试；不得复制本轮原始响应作为 fixture。
- UI/CLI/MCP 从同一来源查询；MCP allowlist 只新增已实现、已核验的方法。
- 本次实施不改变现有课表、个人门户或体育登录策略；新来源拥有自己的认证与错误状态。

## 验收

公开目录的最小闭环为：真实匿名读取 → 完整解析后写来源记录 → 关闭重开 → 权限化查询 → UI/CLI/MCP 读到同一记录。离线重点覆盖：

- 多学期、半学分、周次/节次、课程与开课编号混用、空教师、未公开大纲、HTML/脚本消毒。
- 目录非空但 total=0、重复页、页大小被忽略、排序变化、第二页失败、未知总数及有界覆盖。
- HTTP200 登录壳、JSON 非零 e/code、401/403、账号/来源越权、撤权后的缓存访问。
- 安装恢复不自动授予新来源权限；资料下载与原站入口打开拥有单独的来源/域/资产检查。

Windows/Linux 原生、Android 模拟器、ARM64 编译和真实校园读取分别出证据；本轮的原生研究探针只证明 Windows 当前 Core 的指定读取。

## 研究资料与真实记录

- [教学与学习](academic-learning.md)：开课/大纲、培养、研究生、课评、Canvas、录播。
- [门户与校园生活](portal-life-services.md)：eHall、my、电卡、用电、场地、智慧体育、报修。
- [图书馆与学生服务](library-student-services.md)：OPAC/Primo、借阅、论文、就业、迎新、奖助、云盘、地图、打印。
- [真实只读验证](validation.md)：主线程原生探针、认证限制、网络诊断、文件与暂存状态核对。
- [研究探针](../../tools/fudan-service-research/README.md)：独立构建、固定读取目标、凭据处理及报告约束。

凭据从用户指定的 `C:/Code/dansheng-app/credentials.txt` 在本机进程内读取。报告/临时 Core profile 在仓库外，探针不导出上游 body、Token、Cookie、账号值或原始重定向。新接口的研究不代表已获得远端写权限。
