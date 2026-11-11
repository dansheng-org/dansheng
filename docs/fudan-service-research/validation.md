# 本轮研究与只读验证记录

日期：2026-11-09。工作区 `C:/Code/dansheng`，未产生提交的 `codex/fudan-service-research` 分支。

## 验证层级

| 层级 | 本轮证据 |
| --- | --- |
| 源码与公开协议研究 | 三份分领域文档；主线程独立阅读协议/代码、实际页面脚本和结果 |
| 研究工具离线验证 | **10/10 通过**，研究工具单元测试，不是全 Core 业务套件 |
| 格式/静态检查 | 研究工具 cargo fmt 与 all-targets Clippy `-D warnings` 通过 |
| Windows 原生 Core | 独立工具实际调用当前 Engine/HTTP/login；23项首次公共检查、9项定点复核及认证读取 |
| Linux/Android/ARM64 | 本轮未执行；不沿用旧平台结果来标记新服务已通过 |
| 真实远程业务写入 | **0**；只有固定 GET 和现有认证 POST，没有预约、充值、邮件或提交 |

工具构建与 source/binary SHA 见 [verification.json](evidence/verification.json)。首批旧工具的哈希见 [native-core-all.receipt.json](evidence/native-core-all.receipt.json)；当前工具对应 discovery/canvas 两份报告。现有 Core 源码在各批次间未改变。

## 匿名与定点 Core 结果

[首次入口探针](evidence/native-core-all.json) 和 [定点复核](evidence/native-core-discovery.json) 不包含上游 body、headers、姓名、账号、Cookie、Token、课号或签名 URL。

| 项目 | 本次实际结果 | 接入判断 |
| --- | --- | --- |
| 本科开课 search/527 | Core GET200，JSON object，受限页1项；来源 totalRows=6619 | 公开目录可直接作为首批协议；规模不是固定限额或全量证明 |
| 本科开课页/公开培养方案页 | Core GET200 | 有实际入口；培养方案详情/个人学业进展仍待协议验证 |
| check-can-info | Core GET200、JSON null | 页面 JS 的逻辑为 res 非空则显示 res.text 并禁止；null 表示没有该阻止原因，不表示查询失败或普通 bool |
| teachingSyllabusInfo | 从真实目录的 lesson.id 构造一次 GET，Core 返回200 HTML | 大纲页协议可达；不同课程的发布情况、正文解析与覆盖需分别验收 |
| 独立课程 info | Core 对一个 course.id 请求404 | 未接入的详情候选；另一次匿名请求加入公开 JS 的 REDIRECT_URL 后仍404、无课程标签。不猜更多ID或归因角色；先从目录投影课程信息 |
| eHall getApp type=all | Core GET200；e=0、d.list **192**、d.total **0** | 可读取公开服务目录；不能按 total 判空或宣称所有账号可用 |
| eHall getApp limit=1 | Core GET200；仍192项、total=0 | limit 没有实现本轮预期的列表截断；客户端限制 bytes/items/time，不依赖服务器参数 |
| eHall todo/apply，无会话 | Core GET302、同站跳转 | 个人任务不是匿名 API；尚未验证本人业务响应和分页 |
| OPAC/图书馆首页 | Core GET200 | 公开入口可达，不等于私人借阅接口通过 |
| Primo 配置 | Core GET200 JSON，实际 FDU 实例/视图来自官方 OPAC JS | 配置可用；工人对推导 pnxs 搜索得403，不把它当已成功的检索协议 |
| cloud，默认 Core 策略 | PermissionDenied；DNS 独立解析为校园私网 | 拒绝来自网络权限检查，不是HTTP401或接口消失 |
| cloud，单一来源策略 | 仅在新 profile 允许 `https://cloud.fudan.edu.cn`，Core GET200 登录页 | 验证了指定私网来源的传输；没有登录云盘或获取用户文件 |
| icourse | Core NetworkUnreachable；独立 DNS 解析失败 | 校园网/DNS/VPN 条件待验证，不能断言下线或账户无权 |
| ehall/new/index.html | Core404；实际首页/公开 DSL 可读 | 新接入从当前首页发现资源，不使用猜测版本路径 |

cloud 复核使用 Owner 的 `http.policy.set`：allow_private_network=false，private_network_origins 只有 cloud 的 HTTPS origin。没有更改全局代理、系统 VPN、App profile 或其它客户端授权。普通 MCP 不自动取得此策略。

`login_markers` 是研究提示，不是登录壳分类器。图书馆公开首页本身包含 UIS 登录链接，不能据此判断未成功读公开页；生产解析应结合期望 schema、明确认证挑战和当前身份验证。

## 指定凭据的读取与认证

凭据由主线程在本机读取 `C:/Code/dansheng-app/credentials.txt`，没有传给工人或复制进本仓库。每个密码目标使用现有官方 LoginTarget 的一次流程；会话在新 profile 的 Core 中 persist=false，仅在内存使用。

| 目标 | 本轮结果 | 已确认边界 |
| --- | --- | --- |
| Canvas 提供的 Bearer | 最新 [Canvas 报告](evidence/native-core-canvas.json) profile GET **401**，identity_matches=null | Bearer 被当前入口拒绝，不能验证同一账号；没有改用密码 Cookie、创建新 Token 或读取课程详情 |
| 本科教务 | 现有认证链返回候选会话，固定个人 course-table GET **500** | 登录链完成不等于本科课表可用；不从账号格式猜学段，不自动切研究生 |
| eCard | 认证链返回候选会话；根 epay GET302 | 不是余额/流水的新验收；本轮没有追加卡务或支付动作 |
| 宿舍 | 认证链返回候选会话；固定信息页 GET200 | 确认该页的只读可达，不导出房间/电量，不据此声明全部用电接口兼容 |
| my/个人数据中心 | **InteractiveLoginRequired**，阶段 submit_credentials | 交互验证由平台宿主完成；没有猜验证码或自动重交 |
| WebVPN 密码目标 | 由于上一步交互门槛，剩余密码流程停止 | 没有把本轮未执行的认证记成失败或成功；公开入口已独立GET到认证边界 |

首批 all 报告是旧版研究包装器，其 Canvas `false` 只表示没有得到可核对 profile；当前工具已修复未知/不同账号语义，401 结果以新报告的 null 为准。这是诊断语义修复，未改变学校结果或现有 Core 代码。

## 文件与范围核对

主线程在仓库外保存了研究前267个源文件的指纹，验收时核对：原文件改变0、缺失0、index SHA保持一致。新文件仅位于 docs/fudan-service-research 与 tools/fudan-service-research。未创建提交；原主分支尚无首次提交，不能假称已经建立了基于 main 提交的普通 worktree。

导出前对新文档、工具源码/锁文件和所有报告扫描了五个指定凭据字段的原值、URL编码、Base64编码，没有命中；临时 profile 和构建目录在 `%LOCALAPPDATA%/dansheng-research/20261109-fudan-services/`。报告只保留固定目标、状态、schema/计数和诊断阶段。

后续实施新连接器仍需合成 fixture、分页/权限/认证/页面执行负向用例及跨端验证。本轮所列待登录/未确认路径不会作为已实现 API 加入 Core/MCP。
