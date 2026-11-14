# eHall 0.2.3+5 审阅记录

## 本轮行为

| 页面 | 改动 |
| --- | --- |
| 校园卡明细 | 只选择单日，Core 自动遍历完整明细，移除手动翻页；切换日期或账号丢弃旧请求结果 |
| 校园卡统计 | 明细页的“支出统计”卡片进入独立页面，可选自然周／月／年；按交易类型、商户查看支出，入账单列 |
| 用电走势 | 按天／周／月／年归集，保留柱状图；横向滚动容纳完整短坐标，数值位于各自柱顶；真实零值高度为零 |
| 体育场馆 | 日期文字和日历按钮在同一行垂直居中；具体场地选中后仅显示优先级序号，隐藏额外对勾 |
| 校车 | 下拉框选中项和菜单文字居中；方向和交换按钮统一使用 rounded Material 图标，移除“双向”文字，保留读屏标签 |

按四层规范，日期范围查询、完整分页、消费及用电统计由 Core 官方连接器实现，
App 仅负责用户输入、格式化、坐标绘制和平台调用。新增读接口是
fudan.ecard.statement、fudan.ecard.statistics、fudan.electricity.statistics；
参数、语义、完整性及边界见 Core 工作树 docs/campus-statistics.md。

支出以整数分计，负金额计支出，正金额作为含充值／退款等的入账单列，不抵扣支出。
用电统计按自然日／周／月／年分组；校方只给窗口时明确说明完整性未确认，
未知数值报错，不将其伪装为零或完整年度记录。

## 来源与依赖

- App 工作树：C:/Users/ASCENDER/orca/workspaces/dansheng-app/ehall，分支 feat/ehall，
  基线 1ffa1325c6b30ee2189563bf3ec92c1517bc94bb，加本轮未提交修改。
- Core 工作树：C:/Users/ASCENDER/orca/workspaces/dansheng-core/ehall-card，分支 DANSHENG/ehall-card，
  基线 b21ba39c43038c88ecb3519a40c00997add6bcdf，加未提交的解析与统计实现。
- Core source SHA-256：06c50a88dc6e0328b336ad3aecf1f17b66d793b32121e978c5b7d4361b036a5b。
- AAR SHA-256：59dfefa9d50f7281ab82d905294897a9072d5468beb4cc82f3d0aca29b74f9c3。
- 新 SDK：D:/Scratch/dansheng-ehall-20261112/native-sdk-statistics-20261113T061715Z，
  两个 Android ABI 实际构建，core.lock.json 已据真实产物更新。
- 依赖仍为 development_snapshot，C ABI／API 均为 1；未创建或宣称稳定 SDK 发布。
- Flutter 3.47.7、Dart 3.13.5、Pigeon 29.1.1；Pub 锁与两份生成绑定字节不变。

## 实际检查

| 层次 | 结果 |
| --- | --- |
| 源码格式、静态分析 | check-format 通过，flutter analyze 无诊断 |
| Flutter 全套测试 | 最终 122 项通过，含单日明细、统计页面、四种用电周期、窄屏坐标、柱值位置、日期控件及场地序号 |
| Core 最新针对性检查 | 4 项统计单元测试及 30 项校园服务测试通过；覆盖周一／闰年、精确金额、入账分离、完整分页与重复交易标识 |
| Core 较早的完整连接器回归 | 276 项通过、1 项忽略；补充重复交易标识后又完成上述最新针对性检查 |
| Android JVM | 12 项通过 |
| Pigeon | 实际重新生成并比对，Dart／Kotlin 绑定及 pubspec.lock 不变 |
| SDK、APK | 新 ARM64／x86_64 SDK、x86_64 debug 与 ARM64 release 均实际构建；载荷与资源核验、签名及 ZIP／ELF 16 KiB 对齐通过 |
| API 36 模拟器 | 新的独立 AVD 离线启动，设置页动态 core.info 验证完整原生调用链；随后以最终源码热重载成功 |
| 界面渲染 | 额外 4 项组件／渲染检查通过，五个页面以合成数据生成截图并检查；这些截图不是私人账号的服务截图 |
| 真实校园卡只读 | 新源码 host、独立 profile：当日明细 3 条，本周 8 条，本月 25 条，本年 448 条，全部返回完整结果 |

本轮没有新完成信息门户的人工 2FA，所以用电汇总以连接器夹具、组件和界面测试为证，
不将其称为本轮真实用电统计查询成功。没有执行真实预约、取消、付款或物理设备操作。

## 审阅包与证据

最终 ARM64 release 审阅包为内部签名、非 debuggable；版本名 0.2.3，Android versionCode 2005。
APK：
D:/Scratch/dansheng-ehall-20261112/artifacts/release-review-20261113T064322Z/dansheng-0.2.3+5-ehall-arm64-release.apk。

SHA-256：f5f85d5daf05fd6e7ee68a162c020981bb767ebeaa6fadcd415f3d5bbe9e2a71。

构建、审计、签名与来源记录在该目录的 build-release.log、audit-release.json、signature.txt、
review-build.json；完整测试与只读诊断在任务 runtime 的 logs/refinements-*、
logs/statistics-unit-final.log、logs/statistics-campus-final.log、logs/statistics-live.json。
合成渲染截图位于 artifacts/refinements-0.2.3/previews。
两仓库完整 diff、状态及变更文件摘要随审阅包保存；均未暂存、提交、推送或合并。
