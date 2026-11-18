# Flutter App 架构与实现边界

本文依据 2026-11-14 单仓库源码与公共文档整理，记录当前结构，不新增功能计划。本次仅做静态审阅，未运行构建、模拟器或校园服务验证；下文验收数据均属于所链接文档的历史记录。

## 位置与实际平台

`core/` 与 `apps/dansheng_app/` 共享 Git 历史。前者维护 Rust 核心、官方连接器和平台适配；后者是一个 Flutter package，包含 Dart UI 与 Android Kotlin 宿主。职责以[根架构](overview.md)为准：Core/官方服务负责业务契约与执行检查，平台负责 OS 能力，UI 负责输入、展示、导航和页面状态。

| 平台 | 当前 App 范围 | 证据与限制 |
| --- | --- | --- |
| Android | 已有 Flutter 工程、Kotlin 宿主及 JNI/AAR 接入；最低 API 28 | [Gradle 配置](../../apps/dansheng_app/android/app/build.gradle.kts)、[App README](../../apps/dansheng_app/README.md)。ARM64 审阅包、x86_64 模拟器验证有历史记录，不等于本轮构建或 ARM64 真机验证。 |
| Windows/Linux | 属于 Core host/CLI/MCP 的平台范围 | [根架构](overview.md)；当前 App 没有对应 Flutter 桌面宿主目录，不能从 Rust 支持推导出桌面 App 已实现。 |
| iOS/macOS/Web | 后续产品范围，当前 App 未提供这些平台工程 | [根架构](overview.md)明确要求先定义宿主能力与限制；共享 Dart UI 本身不代表平台接入完成。 |

[pubspec.yaml](../../apps/dansheng_app/pubspec.yaml)声明版本 `0.2.4+6`；运行依赖是 Flutter 与 flutter_localizations，开发依赖包括 Pigeon。当前没有引入 Riverpod、Bloc、Provider 或 go_router。

## 启动、导航与页面生命周期

[main.dart](../../apps/dansheng_app/lib/main.dart)先初始化 Flutter binding，创建 `DanshengClient` 和 `DanshengController`，运行 `DanshengApp` 后异步初始化状态。根 `MaterialApp` 固定中文本地化，通过 `ListenableBuilder` 响应主题与字号变化；主题定义在 [app_theme.dart](../../apps/dansheng_app/lib/ui/theme/app_theme.dart)。

[HomeShell](../../apps/dansheng_app/lib/ui/screens/home_shell.dart)使用 `NavigationBar` 与 `IndexedStack`，五栏依次为 eHall、eLearning、Agent、论坛、插件，默认 eHall。`opened` 集合使页面首次选择时才创建，之后留在栈中；`TickerMode` 只启用当前栏动画。页面 key 包含当前账号与栏目编号，切换账号会重建对应页面状态。

详情、设置、账号和任务页使用 `Navigator.push` / `MaterialPageRoute`，不是声明式路由表。[eHall 首页](../../apps/dansheng_app/lib/ui/campus/ehall/ehall_page.dart)是可编辑的小组件看板：每个服务一个小组件，可隐藏、长按拖动排序，并在图标 1×1、小 2×1、横条 4×1、中 2×2、大 4×2 之间切换，尺寸越大显示的信息越多（例如电量走势、各节空闲教室数、后续校车）；点击后进入详情。打开首页只读取本机 `campus.cached` 中由此前实时读取写入的结果，不访问校园服务；下拉刷新或小组件的“立即刷新”才发起实时读取，场馆与邮箱只作快捷入口。布局（顺序、尺寸、显示与内容选项）由宿主方法 `ehall.layout.get` / `ehall.layout.set` 存于设备级 SharedPreferences，不分账号、未登录也可读取，不进入 Core 的账号缓存；代码见 [board/](../../apps/dansheng_app/lib/ui/campus/ehall/board/) 与 [BoardLayoutStore.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/BoardLayoutStore.kt)。宿主事件的 `open_tasks` 通过控制器导航流让外壳切到插件栏并压入 `TasksScreen`；它不是通用 URL 深链接路由器。

## 状态管理与数据流

当前是全局协调器、功能协调器和页面局部状态并存的结构，未统一抽象成每个功能一套 Repository/ViewModel。

- [DanshengController](../../apps/dansheng_app/lib/ui/core/dansheng_state.dart)继承 `ChangeNotifier`，协调账号、插件、任务、系统权限、Core 信息、余额及主题/字号。`refreshAll` 并行读取基础快照，不主动登录无关校园服务；余额由独立动作读取。主题与字号 setter 只更新内存状态，此处没有持久化实现。
- 根组件每两秒尝试增量轮询，避免重入，初始化完成前跳过；`onHide` 停止计时器，`onShow` 恢复。控制器维护事件游标，`resync_required` 时重读快照，`ui_changed` 经广播流使组件失效；有事件时更新任务。轮询错误被捕获，不应把它描述为保证成功的实时推送或后台调度。
- [LearningController](../../apps/dansheng_app/lib/ui/campus/learning/learning_controller.dart)也是 `ChangeNotifier`，单独管理选中日期、学期、本科/研究生模式、课表和 Canvas 数据。教务与 Canvas 分别维护加载、认证、错误和缓存标记；课程详情错误按课程与方法记录。账号变化递增请求 token 并清空数据，异步回写检查 token。顶层非认证失败可尝试缓存，课程详情也有独立缓存回退路径。
- eHall 详情、场馆、论坛和 Agent 页面还使用 `StatefulWidget` / `setState` 保存筛选、加载与交互状态；论坛与 Agent 各有 Dart service/model 层。持久化数据通过宿主/Core 获取，并非由全局控制器持有一份完整校园数据库。

## 功能边界与源码入口

以下“已实现”指存在 UI 与调用链，不保证任意账号或校方服务当前可用。

| 功能 | 已实现的 App 范围 | 主要源码 |
| --- | --- | --- |
| eHall | 校园卡、空教室、电量、场馆、图书馆/食堂客流、校车、公告、成绩/GPA/考试小组件，可显示/隐藏、排序与调整尺寸；邮箱明确显示“暂未接入” | [ehall_page.dart](../../apps/dansheng_app/lib/ui/campus/ehall/ehall_page.dart)、[life_page.dart](../../apps/dansheng_app/lib/ui/campus/ehall/life_page.dart) |
| 校园卡 | 账号页余额；详情按单日查询完整账单，独立支出统计页选择周/月/年。UI 展示 Core 返回结果，不自行决定消费分类或完整分页规则 | [account_balance_screen.dart](../../apps/dansheng_app/lib/ui/screens/account_balance_screen.dart)、[ecard_detail.dart](../../apps/dansheng_app/lib/ui/campus/ehall/ecard_detail.dart)、[Core 统计接口](../../core/docs/campus-statistics.md) |
| 电量 | 电量详情与走势、阈值提醒设置；规则与去重属于 Core，系统检查和通知由 Android 承担 | [power_detail.dart](../../apps/dansheng_app/lib/ui/campus/ehall/power_detail.dart)、[power_alert_settings.dart](../../apps/dansheng_app/lib/ui/campus/ehall/power_alert_settings.dart)、[PowerAlerts.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/PowerAlerts.kt)、[Core 预警说明](../../core/docs/electricity-alerts.md) |
| 场馆 | 查场馆与日期、选时段和场地优先级、手动预约、记录与取消；启用定时抢场插件后才显示定时任务入口 | [venue_page.dart](../../apps/dansheng_app/lib/ui/campus/venues/venue_page.dart)、[CampusVenueHost.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusVenueHost.kt)。普通手动服务与外部定时插件的产品边界不同。 |
| eLearning | 周/月日历、课表、截止作业、个人日程、Canvas 课程/公告/文件夹/资料；按选中课程读取资料，下载返回资产 ID 后交宿主打开 | [learning_page.dart](../../apps/dansheng_app/lib/ui/campus/learning/learning_page.dart)、[learning_controller.dart](../../apps/dansheng_app/lib/ui/campus/learning/learning_controller.dart)、[course_page.dart](../../apps/dansheng_app/lib/ui/campus/learning/course_page.dart)、[personal_agenda.dart](../../apps/dansheng_app/lib/ui/campus/learning/personal_agenda.dart) |
| Agent | 应用内流式模型聊天与只读校园工具。「本地检索与配对」提供本机资料问答、检索和回环 MCP 配对 | [Agent 架构与配置](agent.md)、[本地服务](../../apps/dansheng_app/lib/ui/campus/agent/agent_service.dart) |
| 论坛 | 分区/全站浏览、排序、搜索、树洞与楼层、发帖/回复和结果核对 | [forum_page.dart](../../apps/dansheng_app/lib/ui/campus/forum/forum_page.dart)、[forum_service.dart](../../apps/dansheng_app/lib/ui/campus/forum/forum_service.dart)、[CampusServices.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusServices.kt) |
| 插件与任务 | 导入、启停、卸载、任务查看；产品目前提供定时抢场。通用 schema 渲染基础仍在，不等于所有校园页面都由插件生成 | [plugins_screen.dart](../../apps/dansheng_app/lib/ui/screens/plugins_screen.dart)、[tasks_screen.dart](../../apps/dansheng_app/lib/ui/screens/tasks_screen.dart)、[schema_screen.dart](../../apps/dansheng_app/lib/ui/screens/schema_screen.dart)、[schema_renderer.dart](../../apps/dansheng_app/lib/ui/schema/schema_renderer.dart)、[schema_models.dart](../../apps/dansheng_app/lib/ui/schema/schema_models.dart) |

## 平台桥接与执行权威

前台调用链为：Flutter 页面 → Dart client/service → Pigeon → Kotlin 宿主 → JNI/AAR → Rust Core/官方服务。不是 Dart FFI 直接调用 Rust，也没有把 `core/` 作为 Dart package 引入。

1. [DanshengClient](../../apps/dansheng_app/lib/ui/core/dansheng_client.dart)以可替换的 `DanshengBridge` 隔离生产通道与测试替身，生产使用 `PigeonDanshengBridge`。方法参数与结果通过 JSON 字符串传输，错误以 `PlatformException` 等形式交给 UI。
2. [pigeons/dansheng.dart](../../apps/dansheng_app/pigeons/dansheng.dart)定义 `HostCommand` 和异步 `DanshengApi.invoke`，生成 [bridge.g.dart](../../apps/dansheng_app/lib/bridge.g.dart) 与 [Bridge.g.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/Bridge.g.kt)。Pigeon 保证枚举和通道契约，不把 JSON 内所有校园数据自动变成强类型。
3. 校园页面的 [CampusApi](../../apps/dansheng_app/lib/ui/campus/campus_api.dart)走同一个 bridge，以 `HostCommand.campus` 发送命名方法及参数；`campusError` 将认证、权限、网络、待核对等错误映射为用户提示。
4. [MainActivity.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/MainActivity.kt)注册 Pigeon，分派命令、打开系统文件选择器/权限设置、确认插件动作并检查预览摘要；[CampusServices.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusServices.kt)限定校园操作、绑定当前账号、协调登录、缓存、资料打开及专用功能宿主。它不向 Flutter 暴露任意 Core owner 请求入口。
5. [RuntimeHost.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/RuntimeHost.kt)管理原生引擎、平台请求泵、WebView port、Keystore、通知与唤醒；[DanshengApplication.kt](../../apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/DanshengApplication.kt)提供进程级宿主。业务/API/ABI 权威仍属于 Core；UI 输入检查和原生确认不替代执行侧检查。

认证和受 WAF 约束的页面请求保留其 WebView 会话语义，不能把现有链路理解为统一改走普通 HTTP。后台任务由原生宿主与 Core 调度；Flutter 的两秒事件轮询只是前台状态刷新。电量预警使用 Android JobScheduler/JobService，不能据此承诺精确每小时到达或厂商后台可靠性。

### 源码与 SDK 的版本边界

[core.lock.json](../../apps/dansheng_app/core.lock.json)当前为 `development_snapshot`，记录 Core 基线 `b21ba39c43038c88ecb3519a40c00997add6bcdf`；[根兼容规范](../CORE_COMPATIBILITY.md)记录其 AAR 摘要及后续 Core 导入提交。开发快照还绑定实际源码摘要/receipt，不能只凭基线 SHA 推断二进制内容。同仓库当前 Core 的后续 ecard 修改也不能自动视为已经编入此 SDK。

源码联调与 SDK-only 是两种不同验收方式；本文没有重建 SDK、修改锁或验证产物。历史 AAR、APK、测试与实时服务结果应保持各自来源，不用新目录布局替换其历史身份。

## 已有验收证据与未实现范围

| 对象 | 现有公开证据 | 不能据此推导的结论 |
| --- | --- | --- |
| eHall/ecard | [2026-11-12 修复](../../apps/dansheng_app/docs/ehall-repair-20261112.md)记录七列账单、分钟精度兼容与 Android 明细读取；[0.2.3](../../apps/dansheng_app/docs/ehall-0.2.3.md)记录单日完整账单和统计 UI；[0.2.4](../../apps/dansheng_app/docs/ehall-0.2.4.md)进一步修正正金额消费分类，并记录周/月/年明细金额一致性及后台电量通知验证 | 0.2.3 的旧金额方向说明不是最终规则；文档保持原样，后续修正另有记录。历史成功不是本轮实测、所有 eHall 服务当前可用或长期真机后台验证。 |
| eLearning | [0.2.1 工作台验收](../../apps/dansheng_app/docs/workbench-validation.md)记录 Canvas 统一认证恢复、13 门课程、开放课程 19 个文件及一份课件读取；同时记录部分课程权限不足与本科课表 HTTP 500 | UI 和连接器已存在不代表本科课表当前可读；早期 Core 的 token 401 与后来的 App 恢复结果属于不同测试上下文，不能覆盖成一个永久状态。 |
| 未接入入口 | eHall 源码直接显示校园邮箱暂未接入 | Core 存在相关能力也不等于 App 邮箱产品已交付。 |
| 后续学习服务研究 | [academic-learning.md](../../core/docs/fudan-service-research/academic-learning.md)讨论培养/学位、课评、Canvas 测验/讨论/本人提交记录、课堂录像等扩展，并标明建议方法与协议取证限制 | 研究方法名、公开入口和其他学校资料不能当作本 App 已实现的页面、复旦接口或实时验证结果。 |

## 现有公共计划的阅读顺序

- [Android 工作台计划 0.2](../../core/docs/android-app-plan.md)：已有五栏产品安排、校园与学习数据、论坛/本地搜索、手动与定时场馆分离及分层验收顺序。计划中的独立仓库位置是历史布局；当前使用本单仓库路径。具体实现以本文源码入口和各版本验收为证。
- [Android 计划 0.1](../../core/docs/android-app-plan-0.1.md)：明确标为历史版本；其中“所有体育入口均由外部插件提供”的初版约束不适用于 0.2 手动场馆服务。
- [Core roadmap](../../core/docs/roadmap.md)与[完成审计](../../core/docs/roadmap-completion-audit.md)：是 Core 范围的里程碑及历史接收记录，不能直接转写为 Flutter 全平台或全部校园服务的 App 完成清单。
- [学习服务研究](../../core/docs/fudan-service-research/academic-learning.md)：补充尚需协议与身份取证的探索范围；本文仅指向已有研究，不新增实施承诺。
