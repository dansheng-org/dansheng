# Academic / rooms 500：静态排查交接

2026-11-06。仅比较源码及 pinned `reference/DanXi`（HEAD 与 manifest 一致：`3c1f5f026fbc7ca50e151865f813cdb381807abe`）。未读真实 profile/凭据/报告，未联网、跑测试或修改源码；QR 保持冻结。本记录不复核本次真实响应，也不证明旧参考协议现在仍有效。

**结论：没有发现这两个 Lab 探针传了合成 semester/student association/building 的证据。HGD 明确来自参考楼号表；academic 固定走本科入口，角色适用性尚未确认。另有可静态确认的默认 WebVPN 覆盖缺口，但不能据此认定当前 500 的根因。不要直接归因“上游坏了”。**

| 检查项 | 精确指针与实际行为 | 判断 |
|---|---|---|
| rooms building/date | `tools/dansheng-lab/src/lib.rs:709` 固定 `building:"HGD"`，日期取 UTC+8 当天；`reference/DanXi/lib/common/constant.dart:629` 的邯郸楼号列表首项就是 HGD；`page/dashboard/empty_classroom_detail.dart:69` 把该列表值交给 repository。 | **不是合成占位楼号**。只能确认有历史协议依据，不能断言当前服务仍接受 HGD。Lab 不开放用户选择 building/date（`ProbeInput` 在 `lib.rs:79`）。 |
| rooms 请求字段/顺序 | `crates/dansheng-connectors/src/campus.rs:1532`：先 GET `http://10.64.130.6/daystatus.asp?b=HGD&day=<同一日期>`，成功后 GET `http://10.64.130.6/?b=HGD&c=&p=&day=<同一日期>`；参考 `repository/fdu/empty_classroom_repository.dart:27,51,73` 相同。 | 未发现漏传 c/p/day 或路径拼错。参考不要求 semester/student association。当前两次请求任何一步失败均整体返回错误；仅凭 `SourceHttpError:500` 无法定位是哪一步。测试里的“合成楼 &day=2000”（`tests/campus.rs:531`）没有进入 Lab。 |
| academic_semesters 参数 | Lab `lib.rs:706` 仅调用 `fudan.semesters(account_id)`；`core_adapter.rs:566` 固定 `undergraduate_semesters`；`fudan.rs:369` GET `/student/for-std/course-table`。参考 `time_table_repository.dart:67` 同样无 semester/association 查询参数。 | 没有合成学期，也不是漏传 semester/association。HTTP 500 发生于读取页面，早于 `parse_undergraduate_semesters`；不能用学期解析器的合成 fixture 解释该 HTTP 状态。 |
| 身份/路径分支 | Lab `lib.rs:587` 的 academic 登录与 `login.rs:64` 的 Academic.entry 同样绑定本科 course-table；Lab 的固定 probe 无身份分支。参考 `page/subpage_timetable.dart:174` 按已选用户组区分本科/研究生；研究生 `postgraduate_timetable_repository.dart:33` 使用另一组 `loadKbxx.do` URL。连接器已有 `fudan.postgraduate.sync`（`core_adapter.rs:585` / `fudan.rs:422`），要求显式 semester 元数据与 endpoint。 | **已确认 Lab academic 覆盖窄于连接器；是否错用到当前账号未知**。不能凭学号猜角色，亦不能因本科页 500 就擅自切换研究生路径。PG 的 semester 是日历元数据，不是传给服务端的学期筛选参数。 |
| semester → student association 链路 | 参考 `edu_service_repository.dart:63` 先取得学期，再在 `:67` GET `/course-table/semester/{defaultSemesterId}/print-data`，取 `studentTableVms[0].id`；连接器 `campus.rs:1218` 同源且要求唯一 studentTableVm。`fudan.rs:383` 默认从页面发现学期后再请求 print-data。 | student association 是服务器记录 ID，**不是登录学号**。它用于后续考试/成绩/GPA，不是当前学期列表 GET 的必填入参。Lab 当前没有在这些探针中填入该 ID；下一步也不要用 fixture 的数字替代。 |
| academic_diagnostic 的含义 | 本地入口 `POST /api/diagnostic/academic`（Lab `lib.rs:286,1068`）；前三次都是 course-table，只变 Accept；第四次为 `/student/for-all/lesson-search`。`academic_response_shape` 在 `:1121` 输出状态、长度、固定结构计数/错误标记；`:1118` 顶层固定 `ok:true`。 | 顶层 ok 仅表示诊断完成，**不是四个上游请求成功**；必须逐项看 `shape.http_status` / `error_code`。lesson-search 是另一个目录入口，不能把其成功直接当作课表成功或角色证明；当前 semesters connector 不会自动用它替代 course-table。 |
| 默认 WebVPN 覆盖 | Lab `lib.rs:776` 使用 `webvpn::DEFAULT_ORIGINS`，`:804` 仅保留其他 provider 的旧路由；该表（`connectors/src/webvpn.rs:15`）含 rooms 的 `http://10.64.130.6`，不含 `https://fdjwgl.fudan.edu.cn`；其中 PG 为 **https** `yjsxk`，而 `fudan.rs:22` 的 PG primary 是 **http**。Core `network.rs:473` 按完整 origin 精确匹配。 | **明确的默认配置覆盖不一致**：默认配置不能称作所有校园源均走 WebVPN；重新应用默认配置还会替换既有同 provider 自定义路由。PG scheme 不同不会匹配。未读取实际路由，不能判断当前账号是否用了默认值；这也不能解释“已知 rooms 经 WebVPN 后返回500”的具体来源。 |

## 父线程下一步可做的安全只读诊断（本任务未执行）

1. **先确认调用上下文而非重登录。** 在现有授权的本机控制通道读取 `http.routes.get`，只记录目标 logical origin 是否有规则、mode、provider及是否与请求 scheme 相符，不导出 profile、cookies、认证头或整个网关 URL。记录角色依据为“用户明确选择/可信来源确认/未知”，不记录学号并推断角色。不要为诊断先覆盖全局 WebVPN 配置。
2. **academic 按现有安全摘要逐项核对。** 使用已有 `/api/diagnostic/academic` 的 control 通道，保留 case、数字状态、白名单 content-type、结构计数和固定错误标记；不保存 HTML、title、Location、选项值或异常正文。只有 Accept 不同就改变结果，才能优先检查内容协商；只有 lesson-search 成功则只能收窄到 course-table 路径/角色/业务上下文，不能直接判角色或上游故障。若本科路径确实适用且返回结构有效，再使用真实选中的 semester 获取 print-data，association 仅在进程内传递，报告只记数量/是否存在。角色未确认时不自动尝试 PG；不造 semester/start date/association。
3. **rooms 拆开两个 GET。** 在现有 owner 会话和既有路由上，对上表两条固定逻辑 URL 使用完全相同的 HGD/date，分别给出 `rooms_status`、`rooms_detail` 标签；记录实际选用的 route mode、HTTP 状态、白名单 MIME、body 长度，以及 status 列表/详情标记是否存在。只在内存内检查结构，不回传响应全文。现有 `fudan.rooms` / Lab 错误只保留数字状态（`transport.rs:168` → `core_adapter.rs:156` → Lab `lib.rs:120`），缺阶段信息；不能从这一条错误判断是网关生成500还是后端应用500。若需比对其他楼，仅使用可信页面/已确认楼号，不能声称旧列表现在必然有效。

现有摘要不提供 Auto 的实际分支或 rooms 阶段；若后续受控诊断仍无法观测，应标记“未知”，不可从路由配置推定实际经过网关，也不能借采证导出原始响应。

当前无需据此改 QR/Core/Host 或冻结中的发行源码。以上只作为后续实读诊断的优先级与证据字段；未新增发布门槛。
