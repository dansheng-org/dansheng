# dansheng Android 客户端 0.1 开发计划（历史版本）

> 这是 0.1 初版计划。0.2 按新的产品安排将 eHall、eLearning、Agent、论坛、插件设为五个底部入口；普通场馆查询与手动预约属于 eHall，只有定时策略作为独立插件分发。下面的旧版插件交付约束不适用于 0.2 的手动场馆服务。

首版交付一个独立、可安装的 Flutter Android App。用户能启用官方插件、登录一个账号、查询场馆与时段、预览定时任务，并在离开页面后回来查看结果。以复旦体育预约作为第一条完整流程，再用一个只读校园功能验证框架可以复用。开发验收用合成账号和模拟预约服务，真实预约成功率不作为交付指标。

**交付约束：抢场是独立可开关的外部插件。** 客户端 APK 不含其脚本、场馆接口或专属页面；全新安装没有抢场入口。单独导入官方插件包后默认为禁用，授权启用才注册页面与任务。禁用撤销后续唤醒，卸载后客户端仍可使用；升级插件不需要重编客户端。验收分别检查空客户端、导入未启用、启用、禁用和卸载。

**架构决策：插件定义用户能做什么，Flutter 把声明画成界面，Rust 决定任务是否可以执行，Kotlin 负责让 Android 在合适的时机唤醒它。** Flutter 控件由 Flutter 绘制；用户关心的流畅度要靠滚动、输入和转场实测。系统 WebView 留给校园认证和必须在页面里执行的请求，插件设置页、列表和任务页均由 Flutter 渲染。

## 项目边界与现有基础

生产客户端建议单独建在 `C:/Code/dansheng-app`，首个平台为 Android，包名采用 `org.dansheng.app`；复用后的 Dart 界面可供其他平台接入。当前仓库继续维护 Rust Core、SDK、官方插件和 Android 平台适配器。按版本和源码指纹消费它们，不复制另一个 Rust 工作区，不把验证 APK 改名发布，不修改只读 DanXi 参考目录。

| 层 | 已有基础 | 首版需要交付 |
| --- | --- | --- |
| Flutter 客户端 | Core 仓库无生产 UI | 首页、插件与授权、插件页面、任务中心、账号与系统权限。视图只绘制；ViewModel 管表单草稿和页面状态，Repository 经同一个客户端访问 Core。 |
| Kotlin 宿主 | JNI、`PlatformPump`、系统 WebView、Keystore、闹钟、Receiver 和有截止时间的前台服务 | 进程级运行时、可见登录、账号验证、具体写入授权、任务恢复提示与通知；前后台使用相同宿主。 |
| Rust Core / FFI | SQLite、QuickJS、账号与授权、插件安装、任务领取、事件、平台请求队列 | 沿用 `plugins.run`、`jobs.schedule/status/run/cancel`、`events.poll` 与 C ABI v1。插件调度 API 属于 Core；不另建 `scheduler.*` 或第二套任务表。 |
| 官方插件 / 连接器 | `official.fudan-sports` 有场馆、日历、预约记录、定时、停止、核对动作；当前只发布一张状态卡 | 给插件补可渲染的表单描述和任务读模型；复旦端点、表单语义、时段策略及身份校验规则留在官方包。普通 HTTP 服务可走已有连接器，体育请求必须走已认证页面。 |

[现有 Android 验证记录](android-sports.md)中，API 36 x86_64 模拟器历史基线含 28 个不同的仪器测试和 5 个 JVM 测试；最终快照重新执行的是 8 个原生集成用例，8/8 通过。ARM64 是交叉编译及独立产物比对，未在 ARM64 设备运行。[Core 发布包](release.md)提供核心库，不是客户端 APK。这些记录是起点，新 App 需自己的安装、运行和性能证据。

## 两条调用路径

1. **用户在前台操作：** Flutter 表单在本地编辑，仅在加载、提交或状态变化时通信。Dart 的类型化客户端经 Pigeon 平台通道调用 Kotlin 宿主，再通过已有 JNI 请求 Core。调用异步返回；事件以 `events.poll` 游标做增量刷新，收到 `resync_required` 或重新打开页面时重读快照。宿主对 UI 开放具体操作，不能让插件传任意 owner 方法、权限或平台信封。插件动作始终由 Core 以该插件的授权运行。
2. **Android 在后台唤醒：** 官方插件调用 `ctx.jobs.schedule` → Core 持久化并请求 `jobs.wake.schedule` → Kotlin 注册 AlarmManager → Receiver 在系统允许时启动有时限的服务 → `CoreJobWakeHost` 重新核对账号、授权、任务和期限，经 JNI 调用 `jobs.run`。Core 原子领取；前台计时器和系统广播同时到达也只执行一次。无需 Flutter Activity、Dart isolate 或后台 FlutterEngine。

由 `Application` 安装原生运行入口，前台和 Receiver 共享并发安全的 `openOrGetEngine`，同一私有数据目录只开一个引擎、一套平台请求泵。退出 Activity 只移除界面订阅；关闭引擎时先停止泵并完成 JNI 清理。首版在 App 宿主进程使用**体育专用 WebView profile、同一时间一个体育账号**，在首次创建 WebView 前设置专用数据目录；其他功能不得复用其 Cookie 或 WebStorage。后台不自动弹登录页。

## 实施顺序与里程碑

每一阶段的出口都是下一阶段的前提。先用无校园网络依赖的例子打通 App，再接入体育；不把学校某个端点是否在线变成开发阻塞。

| 阶段 | 主要工作 | 可以交给下一阶段的证据 |
| --- | --- | --- |
| M0 可安装骨架 | 单独建立 Flutter 工程；固定 Flutter/JDK/Gradle/NDK 与 Core 输入。基于现有 Gradle adapter 为匹配 ABI 生成带 JNI 的 AAR，App 按版本引用。启用官方连接器的 FFI 构建；API 28 为最低版本，沿用现有 compile/target 37。 | 全新安装产品 debug APK；调用真实 `core.info`、写入合成数据并重开读取；核对 APK 内 Flutter、JNI、Core 的 ABI 与哈希，缺库或版本不符给出可识别错误。 |
| M1 首个插件页面 | 建立 Material 3 外壳与通用渲染器。用已有 closed-loop 测试包贯穿安装（默认禁用）→ 显示能力请求 → 授权启用 → 运行只读动作 → 卡片更新 → 杀进程重开仍能读缓存。测试包仅进开发变体。 | 第二个不同插件可复用同一渲染器，不用增加 Kotlin 或 Dart 的插件专属路由。拒绝或撤销授权、禁用、旧声明和未知组件都有可见结果。 |
| M2 体育只读流程 | 接入官方插件的 `visibleLogin`、`venues`、`calendar`、`appointments`、`appointmentDetail`。把适配器提供的**同一个 WebView** 放入可见登录界面；由官方集成在页面内执行只读身份探针并比对账号。没有可靠身份字段就保留未认证。 | 用模拟 SSO/WAF 完成选择场馆→日期→时段→查看记录；身份不匹配、切换账号、页面失效或进程死亡都不能复用旧句柄。经允许的真实只读验证单独记录。 |
| M3 定时与恢复 | 接入 `schedule`、`stop`、`reconcile`；在任务中心分别呈现业务计划、当前子任务和系统唤醒。实现宿主授权记录、通知、重新登录、系统权限引导和恢复入口。 | 离开 Flutter 后，系统能运行合成任务；断网、重复唤醒、撤权、截止时间、进程回收时得到明确终态或待处理原因。模拟服务端逐次记录请求，证明没有重复 POST。 |
| M4 内测交付 | 增加“校园卡余额”只读入口，调用已有 `fudan.ecard.balance`，独立处理其服务登录及离线/过期状态。完成中文、暗色、大字体、TalkBack、性能和 ABI 验收。 | 可分发的 ARM64 内测 APK、x86_64 验证 APK、安装说明、版本/哈希/许可证、分层测试报告。签名密钥在仓库外；没有真机数据就标“未验证”。 |

**首版接口约定**

- **插件 UI。** 沿用 [SDK](../sdk/index.d.ts) 中的 `card/list/detail/form/action/settings`。静态入口从 `plugins.list` 的 `manifest.ui` 读取，动态内容从 `ui.get(principal,id)` 读取；后者可由插件用 `ctx.ui.publish` 更新。首版为声明约定可选的 `ui_version: 1`、有稳定 ID 的字段、选项数据源和指向**本插件已声明动作**的按钮。支持日期、时间、单/多选和只读结果；绑定只取命名字段，不执行表达式、HTML 或下载的 Dart。旧卡片没有扩展字段照常显示，未知版本提示不兼容，单个坏插件不影响首页。静态声明不能自行扩大 grant。
- **体育表单。** 查询场馆和日期后，用 `calendar` 的结果填时段与场地，输出已有 [SportsPlan](../plugins/fudan-sports/types.d.ts)：账号、稳定 task ID、场馆、目标日期、带时区的开抢时间、各时段及场地优先顺序。按 `Asia/Shanghai` 展示复旦时间；改选场馆或日期时清除失效时段。先 `actions.preview` 再由宿主显示确认摘要；保存任务、停止本地任务和取消一条已存在的预约使用不同入口，后者要重新选择具体记录并单独授权。
- **任务列表。** 现有 `sports` 卡覆盖最近一次发布，不能当作任务列表。给官方插件增加一个只读动作，按当前账号读取其私有索引，返回最小任务摘要；用 `jobs.status` 查询对应子任务。每次 `enqueue` 将 Core 返回的 `wake_up` 与当前序号、job ID 一起保存在插件状态里，包括续跑阶段；前台重开还要核对 Android 当前权限与宿主持久订阅。明确显示“已保存但未注册闹钟”“等待唤醒”“需登录”“结果待核对”等状态；过期序号或其他账号的事件不能覆盖当前任务。
- **写入与核对。** 持久化用户确认的账号、任务、场馆、日期、时段/场地、动作和截止时间。Kotlin 的可信授权回调比对实际页面请求，再由 `PersistentMutationGate` 原子领取对应键；插件传 `approved:true` 无效。写请求发出后超时、断网或进程死亡均进入 `NeedsReconciliation`。先查预约记录；确认成功即停止，无法判断就保持待核对，权威结果证明未写入且用户重新确认才允许重试。禁用插件、切换账号或停止任务会撤掉后续唤醒，但不会撤销已到达学校的请求。

**Android 生命周期。** 用户关闭页面或退到桌面，原生入口仍可工作；进程被系统回收后可以重新打开 Core，但体育页面会话不会凭空恢复，没有有效身份就提示“需登录”，不提交预约。强行停止应用单列测试，下次用户打开再对账。重启或升级后仅重挂尚未到期且未领取的任务。缺少精确闹钟授权就明确提示去设置，回来后重新核对并只重挂符合条件的任务；前台服务被拒就记录需用户恢复。不能用不精确闹钟冒充精确定时，也不能把系统唤醒时间当作请求送达学校的时间。参见 Android 的[闹钟规则](https://developer.android.com/develop/background-work/services/alarms)和[后台启动前台服务限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)。

## 验收与发布条件

| 验收层 | 最小场景与通过条件 |
| --- | --- |
| Flutter 离线 | 真正通过声明生成两种插件页面；无权限、无数据、超时、失效时段、无障碍标签和大字号均可操作。列表懒加载，表单输入不逐键调用 Core，滚动/动画时不解析 Schema 或调用插件。 |
| 产品 APK / 模拟器 | API 36 x86_64 上用实际产品宿主、JNI、Core、QuickJS 和 WebView 跑 M1–M3。分别测试退到后台、Activity 销毁、普通进程回收、强行停止、重启和撤销精确闹钟权限。用仅做本地记账的任务证明进程能冷启动、Flutter 未启动且任务只领取一次；对体育任务独立验证会话丢失时零 POST。模拟超时后即使重复广播、重启或用户点停止，也不能再发一次写请求。 |
| Android 兼容性 | 在最低 API 28 验证前台服务真实启动，修正现有适配器无条件调用的三参数 `startForeground` 在低版本的兼容路径；在 API 33+ 覆盖通知授权拒绝、较新目标系统覆盖后台启动受限。Keystore 失效须关闭授权；退出账号等待 WebView 数据清理再切换。 |
| 时间与流畅度 | 分别记录计划唤醒、实际收到广播、Core 领取、首个模拟请求、结果到达；报告偏差分布和缺样原因。产品目标：同一 ARM64 设备以 Flutter profile 模式在 60 Hz 下重复插件列表滚动、进详情、填表三轮，每轮 UI 和 raster 帧耗时 p95 均不高于 16.7 ms，并报告超预算帧比例。先标设备、数据量及刷新率；模拟器功能通过不能代替此结论。[Flutter 性能测量方法](https://docs.flutter.dev/perf/ui-performance) |
| 安装包与真实服务 | 检查最终 APK 的 ABI、源码/二进制身份、许可证、[16 KB 页大小兼容](https://developer.android.com/guide/practices/page-sizes)，排除测试插件、凭据、调试日志和构建目录。分栏报告交叉编译、模拟器、ARM64 实机、真实校园只读、真实写入；每栏只填实际执行结果或“未执行”。本计划不授权真实预约、取消或发信。 |

首个可评审交付物是 **M0 + M1 的可安装 APK**：没登录学校也能点开两个不同的插件页面，看到来自真实 Rust Core 的结果。抢场内测在 M2、M3 完成后开放。远程插件市场、桌面/iOS 客户端、Android MCP 服务、通用 YAML 工作流引擎以及其余校园服务不占首版关键路径。

决策来源：[推荐跨平台插件技术栈](chatgpt-conversation://6af09acb-83ec-83e8-802a-e0d3efbb41d1)、[Core 路线图](roadmap.md)、[Android 宿主契约](android-sports.md)、[Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels)。
