# 复旦新增服务 Core 接入

日期：2026-11-09。分支 `codex/fudan-service-research`，仓库仍无首次提交。
本文对应研究之后的生产实施批次；此前研究工具批次的“Core 源码未改变”不适用于本批。
通用 Core 继续不含学校协议、Flutter、MCP 或浏览器运行时；生产 UI 由独立 App 承担。

## 已接线的方法

| 服务 | 新 Core 方法 | 权限与输出 |
| --- | --- | --- |
| 本科开课/大纲 | `fudan.catalog.semesters/lessons/course/syllabus` | `fudan.catalog.read`；动态学期、有界目录、大纲惰性文本；course 为同学期缓存投影 |
| 公共培养方案 | `fudan.programs.list/detail` | `fudan.programs.read`；公共要求、章节与课程树投影；详情 ID 必须已出现在同账号目录 |
| eHall | `fudan.ehall.catalog/tasks/tasks.sync` | 目录 `fudan.ehall.catalog.read`；个人队列 `fudan.ehall.tasks.read`；todo/done/application 分来源，保留分页 stop/coverage |
| 图书馆公共数据 | `fudan.library.lookup/bibliography/holdings` | `fudan.library.catalog.read`；条码/索书号、书目和馆藏；详情 ID 从查询结果取得 |
| 图书馆私人数据 | `fudan.library.loans.current/history` | 当前 `fudan.library.loans.read`，历史 `fudan.library.history.read`；秘密头及可信读者绑定均必需；私人 schema 未真实接收 |
| Canvas 学习 | `canvas.quizzes.sync/quiz.read/discussions.sync/discussion.read/discussion.view/assignment_groups.sync/submission.self/enrollments.self/grades.self` | `canvas.read`；经典测验、讨论、分组及本人数据；本人接口核对 profile，保留分页身份过滤 |

接口由 CampusService 注册到同一 Engine，Host/FFI 的 services 构建自动注册。
MCP 的专用身份仍需账号/业务权限，只纳入 .read 方法，登录/配置/凭据展示/读者观察与绑定排除。
类型在 `sdk/campus-services.d.ts`，没有增加 QuickJS ctx 命名空间或原始凭据接口。

## 凭据与传输

- HostHeaders 对应通用 SecretHeaders；Owner auth.session.set 可导入 secret_headers，按精确 origin/account 绑定，使用平台 Vault 或显式 persist:false。默认 Any/Cookie/Bearer 不发送这些头；覆盖、重定向、替换、恢复和 logout 独立验证。
- Network.request_bytes 保留 NUL、非 UTF-8 字节，并复用授权、DNS/TLS、路由、期限和重定向。Proto/octet-stream 由连接器显式选择。当前页面端口只提供文本，缺页面字节能力时明确失败。
- Canvas browser_session 核对可信平台的账号、origin、认证状态和 live handle，在当前认证页面执行 fetch；不降级为原生 HTTP。Android 保留安全 content-type/Link 和未改变的调用方查询字段。
- 每个连接器实例固定一次凭据 generation 或页面 handle；同步期间凭据/路由/页面会话更换会中止。原生和页面 I/O 返回前重查权限，避免混合主体或撤权后提交。

图书馆 reader.observe/bind/clear 是 Owner-only。observe 返回 ObservedUnbound 指纹且不自动绑定。
宿主需独立确认本人后提供基线；读取时每次先核对 getReaderInfo，MCP 参数不能代替已存基线。
见 [认证研究](library-ehall-auth.md)：OPAC 当前为第三方 OAuth，其特定应用 token 最终用于 fdulspgw access_token 头；UIS 或任意 Cookie 不能直接代替。

## 缓存与错误

目录按学期/规范查询，详情与馆藏按资源 ID，个人队列/借阅按类别与主体分区。
记录与 checkpoint 事务提交，缺席不自动删除。集合 stop/complete、coverage、协议验证与身份状态保留到 checkpoint。
Canvas 后页失败不会把前页数据提交成完整结果。

实际 eHall 前十项含一段9757字节说明及两段 URL 说明。超限/不安全的可选说明用 description_state 标明省略，目录条目保留；脚本/样式/模板文本排除。
已观察的 e=10013 且含 d.loginUrl 时按认证失败处理，跳转与 message 不进入记录或错误输出。

## 实读与限度

公开生产 Core 的13次有界调用已成功：动态学期、两页开课、课程投影、32段大纲、10项 eHall 目录窗口、图书馆空/非空查询、书目与馆藏、两页培养目录及8章节/40模块详情。
这些结果不是全校资料完整遍历；大纲/培养详情保留 Window 覆盖范围。

本地指定凭据另用于独立 Canvas UIS Cookie profile：profile HTTP200并核对为本人。
首门可见课的讨论、作业分组、本人注册及已发布成绩返回类型化结果，部分列表为空，不能推广到所有课程。
该课经典测验返回HTTP404，现存App Bearer的profile仍401。Cookie试验没有替换App Bearer，也没有以BrowserSession名义执行原生HTTP。

eHall追加了仓库外固定目标认证原型：一次新密码流程完成，私有info GET200/e0并返回非空uid。uid是不透明服务标识，学号映射保持未验证；依据本轮新凭据流程和服务私有self端点，当前Core读取本人队列：todo首页0条、done首页1条；application返回SourceSchemaChanged，未伪造空结果。原型没有增加生产login RPC，Host仍需提供该服务的会话；详见[脱敏实读](evidence/ehall-self-read.json)。

图书馆私人OAuth、读者绑定和借阅仍未实读。研究生培养/学位、官方评教、论文、云盘、就业、迎新、奖助、地图、打印等按[完整需求矩阵](delivery-matrix.md)继续保留未确认项；字节基础不等于云盘Proto schema已实现。
没有真实预约、取消、选课、评教/作业提交、邮件、充值、支付、续借或申请。

## 批次身份

生产 Rust 输入66项，冻结指纹：

`fdbaeab6fda9ab71025830d32de05899b1310fd589aff79efc45069da97e5945`

Windows全量501 passed/1 ignored、Linux499 passed/1 ignored，均零失败并通过strictClippy/fmt；Android当前API36 x86_64完整31/31、JVM6项、两进程Keystore通过。Windows和ARM64各两份独立编译产物哈希匹配；ARM64仍仅交叉编译，没有真机执行。归档和解包证据见[最终分层验证](final-validation.md)。
旧349项/204项/Android8项属于历史基线，本批数量与产物只以新日志/receipts为准。
