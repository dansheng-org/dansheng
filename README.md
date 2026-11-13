# 旦生 Android 工作台

DS-002 的源码对照、最新 Core SDK、构建和离线模拟器验证见 [main 接收记录](docs/ds002-main-acceptance-20261112.md)。D 盘迁移的历史记录见 [迁移验收](docs/devdrive-validation.md)。

0.2.2 的校园卡、教室、校车、用电记录及两种校园认证入口见 [eHall 使用和验收说明](docs/ehall-0.2.2.md)。

旦生默认打开 **eHall**。校园服务随应用提供；目前唯一的可选扩展是**定时抢场**。安装或卸载它都不影响查场地、手动预约和取消已有预约。

| 底栏 | 可以做什么 |
| --- | --- |
| eHall | 校园卡与明细、教室座位和空闲节次、宿舍电量、图书馆与食堂客流、校车、公告和教务查询；查看场馆、选择日期与场地、手动预约或查询记录。校园邮箱暂为未接入入口。 |
| eLearning | 以日历选日期，看课程表、当天截止的作业和个人日程；浏览 Canvas 课程、公告、文件夹与资料。下载后在设备上阅读。 |
| Agent | 搜索本机校园记录、按已有资料回答问题；主动开启受令牌保护的本机 MCP 接口供外部 AI 客户端读取。默认关闭，不向局域网发布，不把本地资料自动发送给远程模型。 |
| 论坛 | 按全站或分区浏览树洞、置顶和楼层，切换排序、搜索、发帖和回复。提交前核对目标；超时可核对结果。 |
| 插件 | 导入和启停定时抢场、查看其任务。在 eHall 的场馆页选定时段后，只有启用了插件才显示创建定时任务的入口。 |

## 安装与使用

手机安装 `dansheng-android-arm64-beta.apk`；模拟器安装 `dansheng-android-x86_64-debug.apk`。最低 Android 9（API 28）。从 eHall 右上角设置账号；教务、Canvas、树洞和体育各自完成对应的登录。课表与作业不共用一个登录成功标记，某个服务不可用时，其他服务仍可使用。

在「账号与卡包」连接统一认证、树洞或 Canvas。成功验证后，设备用 Android Keystore 加密保存凭据；校园卡、教务、校车等可以复用同一账号的统一认证密码，树洞使用单独的注册邮箱与密码。切换账号不会串用凭据；选择「退出账号」会删除当前账号保存的登录信息。树洞后缀只决定邮箱候选顺序，实际登录由用户选定的邮箱决定。

eLearning 优先恢复已连接的 Canvas 凭据。令牌失效或没有令牌时，可以使用本机保存的统一认证账号尝试学校的 Canvas 登录；必须通过 Canvas 的个人资料接口核对账号后才会绑定新会话。某门课不开放资料不会登出其他课程。

需要定时预约时，从「插件 → 添加」选择独立发布的 `official.fudan-sports-0.2.0.dspack`。文件由系统选择器交给 App；原生 Material 3 面板展示所选包及来源状态。内置发布摘要匹配时不必手抄摘要，其他版本仍可使用独立可信来源提供的 SHA-256。安装后默认关闭；启用只为当前账号开放能力。精确闹钟未注册和任务已保存是不同状态；停止任务不会撤销学校已经收到的请求。[本版验收记录](docs/ehall-0.2.2.md)

MCP 的绑定地址、当前端口和复制配对信息的操作在 Agent 页提供。PC 客户端可用页面显示的 `adb forward` 命令转发，不需要把监听地址改为外网。关闭服务、切换账号或进程退出会使配对失效。

## 构建

Core 源码必须检出 `core.lock.json` 中的准确提交。配对任务目录 `app` 会优先查找旁边的 `core`，普通目录会查找平级 `dansheng-core`；显式参数/环境设置优先，既存 `dansheng` 目录仍可兼容。使用 Flutter 3.47.7、Dart 3.13.5、JDK 21、Gradle 9.7.1、AGP 9.3.2、Android SDK 37 和 NDK 30.0.16138531。

```powershell
# 在已分配的 App 工作树执行；CoreRoot 对应锁定的 Core 提交。
$CoreRoot = '<准确 Core 工作树的绝对路径>'
$CoreToolsRoot = "$CoreRoot/tools/workspace"
$RuntimeRoot = '<本任务已初始化依赖缓存的 D 盘运行目录>'
flutter pub get
dart run pigeon --input pigeons/dansheng.dart
./scripts/package-workbench.ps1 -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot `
  -RuntimeRoot $RuntimeRoot
```

SDK、构建日志和分发工件使用所选运行目录。复用已验证 SDK 时传 `-UsePreparedNative -ArtifactDirectory <SDK目录>`；更换 SDK 锁时，`-UpdateLock` 会先保留旧锁。当前锁是带真实 Core 提交及完整 packaged receipt 的开发快照，稳定发布仍要求不可变的已发布获取位置。

Gradle 将官方手动场馆适配模块装入 APK 的 `assets/builtin-venues/`；不打入外部定时插件，不打入 Node 或 Chromium。Rust Core、QuickJS 和 Android JNI 来自源码收据绑定的 AAR，发布密钥不在项目内。账号数据和课程资料由系统私有目录保存，凭据不写日志。

## 验证

运行 `flutter analyze`、`flutter test`。在 `android` 目录运行 `./gradlew.bat :app:testDebugUnitTest :app:assembleDebugAndroidTest -Ptarget-platform=android-x64`。产品仪器测试 `workbench` 和 `agentProbe` 分别覆盖受控页面中的手动预约与真实回环 MCP；这些测试不向学校提交写操作。APK 内原生库、文件清单及 ELF 对齐用 `scripts/audit-apk.py` 核对。真机帧率与 OEM 后台行为需在真实设备单独测量，不能由模拟器推定。

完整打包脚本是 `scripts/package-workbench.ps1`，默认使用 PowerShell APK 审计，也可通过 `-Python` 指定 Python 审计器。模拟器联调使用 `scripts/verify-workbench.ps1`；发布面板的截图来自 `scripts/verify-workbench-ui.py` 驱动的实际系统文件选择和安装流程。

## 双仓库任务开发

新协作规则见 [AGENTS.md](AGENTS.md)、[开发工作流](docs/DEVELOPMENT_WORKFLOW.md) 和 [Core 兼容矩阵](docs/CORE_COMPATIBILITY.md)。已有目录和历史验收保留；DS-001 仅为历史只读准备树，当前工作流使用真实 main 提交创建的任务 worktree，未经接收不构成发布。

配对任务可通过 `-CoreRoot` 或 `DANSHENG_CORE_ROOT` 指向授权的 Core worktree，`DANSHENG_CORE_SDK_DIR` / `-ArtifactDirectory` 指向任务原生 SDK。未指定 Core 时按配对 `core`、平级 `dansheng-core`、既存 `dansheng` 的顺序查找；SDK 默认为记录的 task runtime 下 `native-sdk`，不把原 App 的 AAR/收据与另一份 Core 源码混用。`core.lock.json` 固定真实来源与工件；无提交的开发 snapshot 不会通过稳定发布验证。

新工作流在真实 main 提交创建的任务树中运行。SDK 源码与工具位置分别使用 `-CoreRoot` 和 `-CoreToolsRoot`；主线 Core 尚未接收管理脚本时，可使用同仓库已注册任务树里的验证器，源码身份保持指向实际 SDK 生产者。

```powershell
$TaskKey = '<已创建的任务 key>'
$AppTask = "D:/Worktrees/$TaskKey/app"
$CoreTools = "D:/Worktrees/$TaskKey/core/tools/workspace"
& "$CoreTools/Initialize-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace -TaskKey $TaskKey -Owner codex-workflow -CacheRoot D:/DevCache -Apply
. "$CoreTools/Enter-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace -TaskKey $TaskKey -Component app
Set-Location $AppTask
# 只读消费已核验的主线 SDK；不在这里重编 Native 或读取签名密钥。
./scripts/package-workbench.ps1 -CoreRoot D:/Code/dansheng-core -CoreToolsRoot $CoreTools -ArtifactDirectory D:/Code/dansheng-app/.local/native -UsePreparedNative
```

分发输出使用任务 runtime 的 `artifacts`，日志使用 `logs`，SDK 输出使用 `native-sdk`。完整 debug/独立插件/androidTest 组合默认内置 PowerShell APK 审计，不要求 Python；需要内部 beta 签名时显式加 `-IncludeBeta`。内部测试签名默认在该任务的 `signing/android-beta` 创建并复用，也可通过 `-SigningDirectory` 选择同一 runtime 内的目录；C 盘原签名身份和 DPAPI 文件保留原地。`verify-ui-runtime.ps1` 默认只展示计划，`-Apply` 才创建全新 D AVD，并通过真实设置页面验证 Dart→Pigeon→Kotlin→JNI→Rust。
