# 校园卡与用电统计接口

本次为官方连接器的兼容性新增，C ABI／API 版本仍为 1，Pigeon 协议不变。权威数据结构与实现位于
crates/dansheng-connectors/src/campus_statistics.rs，服务注册位于 core_adapter.rs。

| 方法 | 权限 | 业务输入 | 结果 |
| --- | --- | --- | --- |
| fudan.ecard.statement | fudan.card.read | from、to，含两端的校园日期 | 完整 SourceBatch，coverage.state 为 complete |
| fudan.ecard.statistics | fudan.card.read | date 与 period：day／week／month／year | SourceRecord，payload 为 CardStatistics |
| fudan.electricity.statistics | fudan.life.read | period：day／week／month／year | SourceRecord，payload 为 UsageStatistics |

账号仍由受信宿主绑定；独立客户端遵守既有账号、会话及授权契约。App 白名单仅增加这三个只读业务方法。
完整查询沿用原有连接器端点、请求和认证，UI 不拼接学校请求或解析 HTML。

校园卡完整查询内部跟随校方分页，拒绝倒退的页码、后续页失败和超过 10,000 条的窗口，
不会把截断或部分结果称为完整明细。分钟精度下内容相同的合法交易保留每次出现，
以独立的快照记录标识避免存储冲突。超过查询边界时调用方应缩小查询范围。

校园卡统计使用 UTC+8 的业务日期；周从周一开始，月和年按自然月／自然年计算，支持闰年。
校方七列表格中的消费也可能使用正金额。根据名称字段（协议中的 transaction_type）识别明确的消费、
支付、扣款、缴费及充值／退款等方向，同时兼容旧的负金额支出；不能仅按金额正负区分收入与支出。
未知正金额通过 unclassified_count 单列，避免默认为入账；充值、退款等入账单列，不抵扣支出。
以整数分精确求和，按校方提供的交易类型、商户归集，不推测额外消费分类。

用电统计按校方记录日期归集。金额以百万分之一 kWh 精度的整数求和，结果以十进制字符串输出，
不把无法解析的记录算成零。源记录明确为零时保留零；没有记录的日期不补造零用电量。
有可信分页元数据时遍历完整记录；校方只提供窗口、无法确认完整性时返回 complete=false，
UI 必须保留此说明。每日明细、每周汇总、每月汇总和每年汇总使用同一组 Core 规则。

App 对完整日期范围和统计读取使用独立的 180 秒等待预算，其余请求继续沿用原预算；
超时通过已有取消流程结束操作，页面用账号及请求世代丢弃过期结果。

日期边界、整数金额、入账分离、跨时区归属、用电分组及非法记录由模块单元测试验证；
完整分页、重复内容的记录标识与后续页失败由 tests/campus.rs 验证。
App 通过新构建的 SDK 与准确 core.lock.json 消费这些新增方法；开发快照不称为已发布 SDK。
