# eHall 0.2.4+6 审阅记录

## 修复与新增

| 项目 | 当前行为 |
| --- | --- |
| 支出统计日历 | 周按整行选择一周，月选择月份，年选择年份；按钮显示相应周期层级；日历运算使用日期字段，避免设备夏令时把周一算成周日 |
| 支出统计金额 | 校方“名称”字段中的消费即使金额为正也计入支出，退款和充值等入账单列；未知正金额列为待分类，不再直接认作入账 |
| 统计复核 | 对真实周／月／年结果分别读取同范围完整明细，核对条目数和消费金额总和，并确认分类条目存在 |
| 用电图定位 | 首次加载、最新日期变化或切换统计周期后定位最右端；用户主动浏览历史后，普通重建不会抢回滚动位置 |
| 电量预警 | 寝室电量页新增“设置预警提醒”，可保存阈值、开关、立即检查与查看最近检查／提醒状态 |

上一版真实验证只确认了读取条数，没有核对金额方向。此次实测发现十条消费记录均为正金额，
因此按正负号分类会错误地产生零支出；修复位于 Core 官方统计模块，UI 不另写支出计算规则。

预警配置、阈值判断、低电量阶段去重和持久化待发通知位于 Core electricity_alert 模块。
Android 使用 JobScheduler／JobService 每约一小时联网检查，不依赖打开 Flutter 页面或常驻前台服务；
开启前检查通知权限，配置后另安排一次检查。剩余电量不高于阈值（含负余额欠费）时提醒一次，
补电超过阈值后重新启用。检查失败不当作零电量；账号切换和关闭会取消平台任务与通知。
系统节电、网络约束可能延后执行，强行停止应用后需要重新打开恢复。

## 来源与依赖

- App：C:/Users/ASCENDER/orca/workspaces/dansheng-app/ehall，feat/ehall，
  基线 1ffa1325c6b30ee2189563bf3ec92c1517bc94bb 加未提交修改。
- Core：C:/Users/ASCENDER/orca/workspaces/dansheng-core/ehall-card，DANSHENG/ehall-card，
  基线 b21ba39c43038c88ecb3519a40c00997add6bcdf 加未提交修改。
- Core source SHA-256：171db768b48b74233179db1d610ecfa9591ea44eee0192bdc1d2a0f93fa8aa4f。
- AAR SHA-256：4ba974f1cb2b48e60c07d837b986f592dbc20c3704e9a365b56936f8be3cd466。
- 最终 SDK：D:/Scratch/dansheng-ehall-20261112/native-sdk-alerts-final-20261113T081508Z。
- ARM64／x86_64 SDK 均实际构建，core.lock.json 已更新；依赖仍为 development_snapshot，
  C ABI／API 均为 1，未声明稳定 SDK 发布。Pub 锁和两份 Pigeon 绑定字节不变。
- 服务说明见 Core docs/campus-statistics.md、docs/electricity-alerts.md。

## 实际验证与边界

| 检查 | 观察结果 |
| --- | --- |
| Flutter | 最终 128 项测试通过；格式通过；静态分析无诊断 |
| Core | 最终 95 项库单元、30 项校园服务及 1 项预警权限／配置接口测试通过 |
| Core 规则 | 低于及等于阈值、欠费负余额、去重、补电重启用、持久化、账号隔离、失败非零、旧配置结果丢弃均有覆盖 |
| Android JVM | 12 项通过 |
| Pigeon | 重新生成比对，Dart／Kotlin 绑定和 pubspec.lock 不变 |
| 真实校园卡 | 周 9 条、月 26 条、年 449 条；三种周期支出非零、与同范围明细求和相符、分类非空，未导出私人金额／商户 |
| Windows 真实电量只读 | 登录成功，实际余额读取成功；未导出读数 |
| API 36 模拟器 | 新独立 AVD 离线启动，设置页实际执行 core.info；最终 SDK 的 debug APK hash 为 6d7e150fcefb461274f235a551817aaca08025862e0064794f61bf41007ede89 |
| Android 后台真实链路 | 最终 debug APK 上登录成功；强制唤起系统任务，真实取电后投递通知；第二次成功取电没有重复提醒 |
| Android 平台 | 实际注册 3600000 ms 周期、持久化任务；通知投递、相同令牌替换、新阶段替换和关闭清理均通过 |
| 热重载 | 所属模拟器上的 Flutter machine 热重载返回 code 0 |
| Release APK | ARM64、非 debuggable；版本名 0.2.4，Android versionCode 2006；载荷／签名／ZIP 与 ELF 16 KiB 对齐通过 |

后台链路通过系统命令强制唤起周期任务验证，未自然等待一小时，也未做手机或设备重启后的长期实测。
首次模拟器登录曾返回 NetworkError；成功重测记录另存，未将首次失败算为成功。
验收观察逻辑会等待新一轮结果，不将历史错误或登录恢复中的中间状态当作此次最终失败。
没有预约、取消、支付、邮件发送或物理设备操作。测试中的高阈值和通知已关闭清理。

## 审阅包

内部签名的 ARM64 release：
D:/Scratch/dansheng-ehall-20261112/artifacts/release-review-20261113T082025Z/dansheng-0.2.4+6-ehall-arm64-release.apk。

SHA-256：60b581db18b8aa85282451b2e3c11d2077e68a9f5296359a6a432d5ed9f45dae。

该目录保存 review-build.json、audit-release.json、signature.txt、app.diff、core.diff、
变更文件摘要与本轮只读及后台检查结果。任务 logs/alerts-* 保存构建和测试日志；
logs/corrected-statistics-live.json 保存金额一致性校验，logs/android-alerts.json 保存最终后台链路结果。
日志仅记录状态、计数和布尔校验，不导出密码、Cookie、个人金额或姓名。
两仓库均未暂存、提交、推送或合并。

周期任务限制依据：[Android JobInfo.Builder](https://developer.android.com/reference/android/app/job/JobInfo.Builder)。
