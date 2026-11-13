# 电量预警

规则与持久化状态由官方 electricity_alert 模块负责。Android 系统 JobScheduler 负责联网周期任务，
JobService 在后台启动 Core 检查，不依赖 Flutter 页面或常驻前台服务。

| Core 方法 | 作用 |
| --- | --- |
| fudan.electricity.alert.get | 获取当前账号的配置、检查结果和通知待发状态 |
| fudan.electricity.alert.set | 保存 enabled 与 threshold_kwh；阈值必须有限且大于零 |
| fudan.electricity.alert.check | 开启时读取真实余额，校验配置世代后更新阈值状态 |
| fudan.electricity.alert.ack | 按 delivery_key 确认已投递的通知 |

这些方法要求本地 owner；只读插件即使获准读取校园生活数据，也不能修改预警配置。
配置和状态按账号隔离，存于 Core 的独立命名空间；时间间隔由 Core 配置提供，当前为 3600 秒。

剩余电量不高于阈值时创建待发通知，负余额欠费同样属于低电量。检查失败或非有限数值不会被当作零。
同一低电量阶段投递成功后不重复提醒；余额回升超过阈值后重新启用。修改阈值或关闭配置会取消旧待发状态，
旧配置下完成的网络读取不能覆盖新配置。通知令牌在应用进程重开后仍保留，宿主实际投递后才确认。

App 的 powerAlert.get／set／check 绑定当前账号，不接受 UI 提供的余额或通知确认令牌。
开启前检查系统通知权限；配置成功后安排周期任务及一次立即检查。后台使用既有安全凭据恢复，
不弹登录页面，不删除保存的密码；明确密码错误时暂停自动使用，避免反复尝试。
切换账号、退出账号或关闭预警会取消当前平台任务和通知；切回账号时可恢复该账号已保存的配置。

通知使用独立渠道、固定平台标识与 delivery_key 去重，内容不包含账号或余额；新低电量阶段替换旧通知。
周期任务要求联网、可跨系统重启持久化，系统节电和调度约束可能延后执行。强行停止应用后需重新打开恢复。
平台注册与通知测试、真实余额读取、Core 阈值测试及经过自然时间间隔／重启的验证应分开记录。

依据：[Android JobInfo.Builder](https://developer.android.com/reference/android/app/job/JobInfo.Builder)。
