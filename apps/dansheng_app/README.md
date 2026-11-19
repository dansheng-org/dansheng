# 旦生 · Dansheng

[![源码检查](https://github.com/DANSHENG/dansheng/actions/workflows/app-ci.yml/badge.svg)](https://github.com/DANSHENG/dansheng/actions/workflows/app-ci.yml)

面向复旦校园生活的 Android 客户端，将校园服务、课程资料、日程和本机 Agent 入口放在同一个工作台。使用 Flutter 构建界面，通过同仓库的 [Rust Core 模块](../../core/README.md) 提供校园服务和原生能力。

旦生默认打开 **eHall**。校园服务随应用提供；目前唯一的可选扩展是**定时抢场**。安装或卸载它都不影响查场地、手动预约和取消已有预约。

| 底栏 | 可以做什么 |
| --- | --- |
| eHall | 校园卡与明细、教室座位和空闲节次、宿舍电量、图书馆与食堂客流、校车、公告和教务查询；查看场馆、选择日期与场地、手动预约或查询记录。校园邮箱暂为未接入入口。 |
| eLearning | 以日历选日期，看课程表、当天截止的作业和个人日程；浏览 Canvas 课程、公告、文件夹与资料。下载后在设备上阅读。 |
| Agent | 搜索本机校园记录、按已有资料回答问题；主动开启受令牌保护的本机 MCP 接口供外部 AI 客户端读取。默认关闭，不向局域网发布，不把本地资料自动发送给远程模型。 |
| 论坛 | 按全站或分区浏览树洞、置顶和楼层，切换排序、搜索、发帖和回复。提交前核对目标；超时可核对结果。 |
| 插件 | 导入和启停定时抢场、查看其任务。在 eHall 的场馆页选定时段后，只有启用了插件才显示创建定时任务的入口。 |

## 安装与使用

最低 Android 9（API 28），手机审阅包默认 ARM64。版本声明为 **0.2.4+6**。

自动发布流程生成 `dansheng-<版本>+<构建号>-arm64-prerelease.apk`，并附上 `SHA256SUMS` 与构建信息。2026-11-14 已发布 [0.2.4+6 ARM64 审阅版（c131b19）](https://github.com/DANSHENG/dansheng/releases/tag/prerelease-v0.2.4-build.6-c131b19ae64a)；其他版本以 [Releases](https://github.com/DANSHENG/dansheng/releases) 的实际附件为准。该版本使用锁定的 Core 开发快照，标记 **Pre-release**，不是稳定发布。新环境首次启用仍需准备 SDK 镜像和签名 Secrets，流程见 [发布说明](docs/PRERELEASE.md)，不能仅凭 workflow 配置推断上传成功。

既有内部测试包名为 `dansheng-android-arm64-beta.apk`；`dansheng-android-x86_64-debug.apk` 用于模拟器。自动 Pre-release 使用独立且持久的签名身份；不同签名不能直接覆盖安装，首次切换前先确认设备上的数据处理方式。

从 eHall 右上角设置账号；教务、Canvas、树洞和体育各自完成对应的登录。课表与作业不共用一个登录成功标记，某个服务不可用时，其他服务仍可使用。

在「账号与卡包」连接统一认证、树洞或 Canvas。成功验证后，设备用 Android Keystore 加密保存凭据；校园卡、教务、校车等可以复用同一账号的统一认证密码，树洞使用单独的注册邮箱与密码。切换账号不会串用凭据；选择「退出账号」会删除当前账号保存的登录信息。树洞后缀只决定邮箱候选顺序，实际登录由用户选定的邮箱决定。

eLearning 优先恢复已连接的 Canvas 凭据。令牌失效或没有令牌时，可以使用本机保存的统一认证账号尝试学校的 Canvas 登录；必须通过 Canvas 的个人资料接口核对账号后才会绑定新会话。某门课不开放资料不会登出其他课程。

需要定时预约时，从「插件 → 添加」选择独立发布的 `official.fudan-sports-0.2.0.dspack`。文件由系统选择器交给 App；原生 Material 3 面板展示所选包及来源状态。内置发布摘要匹配时不必手抄摘要，其他版本仍可使用独立可信来源提供的 SHA-256。安装后默认关闭；启用只为当前账号开放能力。精确闹钟未注册和任务已保存是不同状态；停止任务不会撤销学校已经收到的请求。[本版验收记录](docs/ehall-0.2.2.md)

MCP 的绑定地址、当前端口和复制配对信息的操作在 Agent 页提供。PC 客户端可用页面显示的 `adb forward` 命令转发，不需要把监听地址改为外网。关闭服务、切换账号或进程退出会使配对失效。

## 构建

本应用位于 Dansheng 单仓库的 apps/dansheng_app。统一规范见 [根开发规范](../../docs/DEVELOPMENT_WORKFLOW.md)。App 通过 `core.lock.json` 精确消费 Core 原生 SDK，绑定链路为 C ABI → JNI/AAR → Kotlin → Pigeon/Dart。

只做源码检查无需准备 Android 原生 SDK：

```powershell
flutter pub get --enforce-lockfile
./scripts/check-format.ps1
flutter analyze
flutter test
```

源码联调默认使用本工作树 ../../core 并重建精确 SDK 锁；SDK-only 使用已锁定的历史 Core 产物，两者不可混淆。使用 Flutter 3.47.7、Dart 3.13.5、JDK 21、Gradle 9.7.1、AGP 9.3.2、Android SDK 37 和 NDK 30.0.16138531。

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

## 单仓库任务开发

开发约定见 [统一工作流](../../docs/DEVELOPMENT_WORKFLOW.md) 和 [Core 兼容规范](../../docs/CORE_COMPATIBILITY.md)。每个功能一个任务 worktree，包含 App 与 Core。DS-001 和旧双仓库工作树仅作为历史参考。

在仓库根自动准备环境，再进入本应用目录：

```powershell
. ./scripts/Enter-Dansheng.ps1
Set-Location apps/dansheng_app
# 已准备本工作树的 SDK，并与 core.lock.json 核验一致后：
./scripts/package-workbench.ps1 -CoreRoot $env:DANSHENG_CORE_ROOT `
  -CoreToolsRoot $env:DANSHENG_CORE_TOOLS_ROOT `
  -ArtifactDirectory $env:DANSHENG_CORE_SDK_DIR -UsePreparedNative
```

源码联调默认选择本树 core/，实际重建后更新 SDK 锁；SDK-only 审阅明确使用锁定历史 Core。分发、日志、SDK 和 review signing 均位于任务 runtime；旧身份与工件保留。模拟器验证使用任务拥有的新 AVD，真实服务和设备操作须具体授权。

公开协作规则见 [贡献指南](../../docs/development/contributing.md)；本机 Agent 指令与计划独立保护，配置见 [本地共享说明](../../docs/development/local-agent-setup.md)。Enter 不会自动配置 Orca 共享，也不复制凭据。

## 验证记录

- [0.2.4 eHall 与提醒验收](docs/ehall-0.2.4.md)
- [0.2.2 校园卡、教室、校车与认证说明](docs/ehall-0.2.2.md)
- [2026-11-12 主线接收记录](docs/ds002-main-acceptance-20261112.md)
- [D 盘迁移历史](docs/devdrive-validation.md)

这些记录对应各自注明的源码与工件；新的 CI、模拟器或真机结果分别记录。
