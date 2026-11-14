# App 开发与双仓库工作流

DS-002 相对于 App main 的改进和 2026-11-12 的实际接收验证见 [main 接收记录](ds002-main-acceptance-20261112.md)。Core 来源以 `core.lock.json` 的准确提交为准；下面的迁移与准备任务描述保留其原始验收时间和路径。

本规约落实《Dansheng 双仓库多 Agent 版本管理实施规范》v1.0（2026-11-10）。保留两个独立产品仓库；普通父工作区不初始化 Git。既有工作台/Antigravity 验收记录继续保留，以下流程不会把历史结果改写为本轮已通过。

## 分层职责与归属判定

采用“通用内核、官方服务模块、平台宿主、UI”四层分类。前两层属于 Core 仓库的不同模块，
后两层属于 App／平台实现。职责按业务含义与依赖划分，不按 Rust、Kotlin、Dart 或 JS 语言划分。

| 层次 | 应负责的职责 | 典型内容 |
| --- | --- | --- |
| 通用内核 | 跨学校、跨入口的公共能力与执行保障 | 存储、权限、通用网络能力、任务持久化与状态机、操作去重、不确定结果记录与核对机制、插件执行 |
| 官方连接器／插件 | 学校接口协议、服务语义和业务策略 | 服务网址与路径、登录协议、CSRF、请求表单、响应解析、规范化业务模型、预约数量限制、场地尝试与退避策略、取消资格及核对证据 |
| 平台宿主 | 实际调用操作系统、浏览器与设备能力，并执行平台边界校验 | Android WebView、Keystore、通知、AlarmManager、文件选择、原生确认窗口、会话与当前账号绑定 |
| UI | 用户输入、展示和操作组织 | 服务卡片、页面、日期选择、场地勾选、优先级编辑、加载与进度展示、金额／时间格式化、状态码对应文案 |

### 判定顺序

1. 仅影响可视呈现或操作方式，归 UI。
2. 需要具体操作系统、浏览器或设备 API，执行部分归平台宿主；业务模块定义执行目的与规则。
3. 描述某所学校的协议、数据含义或业务约束，归官方连接器／插件。
4. 跨学校、跨服务复用的基础能力与执行保障，归通用内核。

再做跨入口检验：将 Flutter 页面换成 CLI、MCP 或后台任务后仍必须成立的业务规则，
必须在 Core 服务层有权威实现。平台 API 的调用继续通过平台端口完成，平台依赖不因此进入通用内核。

### 容易混淆的边界

| 问题 | 归属与约定 |
| --- | --- |
| 最多选择几个时段 | 官方服务模块定义限制并在执行前最终校验；UI 从服务约束读取限制，允许提前提示 |
| 场地优先级 | UI 收集用户顺序；官方服务模块决定按该顺序尝试、何时换候选以及何时停止 |
| 拥挤退避、重试、执行窗口 | 官方服务模块定义业务策略；通用调度器管理持久化执行状态，宿主提供计时／唤醒能力 |
| 是否可取消及原因 | Core 返回权威资格与结构化原因；UI 展示按钮和说明，不按服务端状态字符串另推一套规则 |
| 业务日期、截止时间与校园时区 | 官方服务模块定义语义与校验；UI 按该语义格式化，设备时区不能改变业务含义 |
| 用户确认 | Core 准备准确操作与可核验预览；UI／宿主展示确认；Core 与宿主在执行边界核验授权、账号及操作绑定 |
| 网址与可信来源 | 连接器或其版本化服务配置声明端点、登录入口及来源需求；宿主依据已核验来源与自身权限边界执行校验 |
| 参数 | UI 提供日期、页码、用户选择等业务输入；连接器生成协议字段、CSRF、请求头和请求体并解析结果 |
| 密码、Cookie 与会话 | 交互输入及安全存取走宿主；按授权端口／租约供服务执行使用，不让页面自行持有或拼装底层认证材料 |
| 错误与状态 | Core 输出结构化状态、原因、所需验证或核对动作；UI 负责文案与交互，不把未确定结果显示成成功 |

UI 的提前校验用于反馈体验，Core 的最终校验保障所有入口的一致行为，两者使用同一份服务约束。
业务接口向上提供规范化结果与操作状态，避免让 UI 解析学校 HTML、推断学校私有状态或手工拼接服务协议。
可配置的网址也由服务配置与权限规则约束，不把“用户可选参数”等同于任意网络请求权限。

### 对照示例与评审要求

- 校园卡：UI 提供日期或统计周期，宿主绑定账号；官方连接器负责域名、CSRF、查询表单、完整分页遍历、
  表格解析、金额与时间语义及支出归集；UI 展示完整日期明细和规范化统计结果。
- 场馆：UI 形成时段与场地优先级计划；官方模块校验约束、执行候选策略、处理已有预约与不确定结果；
  宿主执行 WebView 请求、交互认证与确认；UI 展示进度和核对入口。
- 取消：官方模块判断资格并核对真实结果；宿主展示并绑定用户确认；UI 消费资格与状态，
  不以列表暂时缺少记录推断取消成功。

新增或迁移逻辑时，在变更说明中给出归属层、该层的权威数据／规则、调用接口及必要验证。
跨界面必须一致的业务规则用 Core 的无 UI 测试验证；平台端口用适配器测试验证；显示与交互用 UI 测试验证。
现有 App 中的候选尝试／退避策略、按私有字段推断取消资格以及重复常量，按此标准登记并逐步迁移。
规范写入本身不表示这些实现已经迁移；实际迁移另行明确范围与兼容接口，保留现有 C ABI → JNI/AAR → Pigeon 链路。

本节为两仓库开发流程中的同文规约；修改分类规则时同步维护经授权的 Core 与 App 工作树。

## 默认使用 Agent/Herdr 原生工作树

在 `D:/Code/dansheng-app` 选择 Codex/Herdr 的新工作树模式，或从该目录执行
`claude -w <任务名>`。本机 Codex CLI 也可用
`codex -C D:/Code/dansheng-app --worktree`。工作树已由工具创建时直接复用，不再要求
手工 DS 编号、额外登记或 TASK.md。每个编辑 Agent 独占一棵 Git 注册的工作树。

工具创建的 detached HEAD 可先编辑，提交前再建分支。构建所需的工具链、独立
runtime、SDK 与锁由 Agent 在启动/构建前自动准备；无需用户执行整套手工脚本。
App 消费明确且已验证的 Core SDK，跨仓库改动才协调 Core/App 来源和两侧版本。
以下 New/Initialize/Enter 是可选配对管理器，不是使用原生 worktree 的必经步骤。

## 现状与准备任务

经用户授权迁移后，Core 位于 `D:/Code/dansheng-core`，App 位于 `D:/Code/dansheng-app`；C 盘旧目录保留且只读。当前任务树位于 `D:/Worktrees/<TaskKey>/core|app`，分别共享 D 盘 Core/App 的 Git 对象，并有独立 index/HEAD。DS-001 只作为历史只读准备树保留。`D:/Code/dansheng` 是旧 main 的兼容入口，不是第三个产品仓库，也不是新脚本默认项目名。

最初准备时产品 main 尚无首次提交；经用户授权，Core/App 的会话前 main 已分别提交并推送。DS-001 仍是未接收的 orphan 准备树，其 149 项 review index 不等于提交，其中一份历史 Gradle 报告保留且未进入 main，实际基线源码为148项。普通任务必须基于真实提交。提交、远程配置、合并、研究迁移和清理由主线程列出影响并取得用户批准，本规约不自动授权这些操作。

## 一个任务，一个写入 worktree

1. 原生工具的任务名与分支名可直接使用，DS 编号只在使用配对管理器时采用；不设永久 agent 专属分支。App-only 不额外创建 Core 树。
2. 可选 Core `tools/workspace` 配对管理器提供 New/Status/Enter/Close，显式使用时先查看计划；工具已提供的工作树不重复创建。
3. 目标、允许修改范围与验收可记录在会话或可选 TASK.md。一个 worktree 不同时交给两个写入型 agent。
4. 开始前核对 cwd、任务分支和 `git --no-optional-locks rev-parse --path-format=absolute --git-common-dir`。Core/App 的 common directory 必须不同，同一仓库的任务 worktree 则共享该仓库的 common directory。
5. runtime_root 隔离 Cargo/Pub/Gradle、临时文件、端口、数据库、浏览器和测试资源。进入任务工具设置的环境不能授权读取原项目的私人 profile；worktree 本身不隔离副作用。

## App 与 Core 联调

当前使用原生 SDK 路线，详见 [CORE_COMPATIBILITY.md](CORE_COMPATIBILITY.md)。`-CoreRoot` 优先于 `DANSHENG_CORE_ROOT`；未指定时，目录名为 `app` 的任务先找配对 `core`，再找平级 `dansheng-core`，最后兼容既存 `dansheng`。SDK、lock、runtime 的相对路径均相对 App 解析。

```powershell
$TaskKey = '<已创建的任务 key>'
$AppTask = "D:/Worktrees/$TaskKey/app"
$CoreTask = "D:/Worktrees/$TaskKey/core"
$CoreTools = "$CoreTask/tools/workspace"
& "$CoreTools/Initialize-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace -TaskKey $TaskKey -Owner codex-workflow -CacheRoot D:/DevCache -Apply
. "$CoreTools/Enter-DanshengTask.ps1" -WorkspaceRoot D:/Code/dansheng-workspace -TaskKey $TaskKey -Component app
Set-Location -LiteralPath $AppTask
$env:DANSHENG_CORE_ROOT = $CoreTask
$env:DANSHENG_CORE_TOOLS_ROOT = $CoreTools
# 使用任务入口/Initialize 的已记录 runtime_root 和缓存变量。
# public 缓存的种子来自 D:/DevCache，不能复制账号/Gradle用户配置/daemon。
# 已准备的 SDK 可放在任务 runtime_root；不要把原产物复制到源码。
# $env:DANSHENG_CORE_SDK_DIR = '<已核对的任务 artifact directory>'
flutter pub get --offline
flutter analyze
flutter test
```

本地源码构建只在获得 Core 构建授权后使用 `scripts/prepare-native.ps1 -CoreRoot $CoreTask`。App 构建脚本验证 native receipt/lock，Gradle 与 APK 审计读取相同的 Core 与 SDK 路径。不可把原 App `.local/native` 的旧 AAR 与另一个 Core 源码摘要拼成新收据。

prepare-native 使用显式 `-RuntimeRoot` 或任务入口的 `DANSHENG_TASK_RUNTIME`；未提供时按已核验的 task JSON 解析 runtime_root。SDK、分发产物、日志分别使用 `native-sdk`、`artifacts`、`logs`；Cargo home/target、Core Gradle/project cache 和 CMake staging 都使用任务运行目录。AGP 的公共 Android 构建输入复制到 runtime 的 `core-android-project`，收据仍绑定实际 `CoreRoot`，元数据不会写回 Core 源码。已有构建副本的字节与源码不同会拒绝覆盖，应选择新的运行目录。离线构建前运行 Initialize 准备 public Cargo 依赖。它拒绝把产物写进 Core checkout 或从任务树覆盖原 App 的 native 目录。

只读消费既存 MainCore SDK 时，明确传 `-CoreRoot D:/Code/dansheng-core -CoreToolsRoot $CoreTools -ArtifactDirectory D:/Code/dansheng-app/.local/native -UsePreparedNative`。源码位置与验证器位置分离，工具必须属于同一 Git common directory；不会将 SDK 源码改指另一工作树。需要换 SDK 锁时，`-UpdateLock` 先在任务 logs 备份旧锁。`-IncludeBeta` 才执行内部签名流程；默认使用任务 `signing/android-beta` 的新内部测试身份，`-SigningDirectory` 只接受同一 runtime 内的独立目录。C 盘原身份/DPAPI数据不自动迁移。

内部测试签名目录使用绝对路径，例如在已经完成 SDK 核验的任务中：

```powershell
./scripts/package-workbench.ps1 -CoreRoot $CoreTask -CoreToolsRoot $CoreTools `
  -ArtifactDirectory $env:DANSHENG_CORE_SDK_DIR -UsePreparedNative -IncludeBeta `
  -SigningDirectory (Join-Path $env:DANSHENG_TASK_RUNTIME 'signing/android-beta')
```

`prepare-native.ps1` 显式绑定 `-CoreRoot`/`-RuntimeRoot` 供复制后的 Gradle 启动器使用，
参数优先于已有任务环境；退出时恢复原来的 Cargo、Rust/NDK、源码和 runtime 环境值。

`verify-ui-runtime.ps1` 默认 dry-run；`-Apply` 创建全新 D AVD，禁用网络后安装 hash 已记录的 debug APK，点击 eHall 设置并检查真实 core.info 行。默认使用 API 36 离线镜像；重启恢复验证可显式选择 `-SystemImage 'system-images;android-28;default;x86_64'`，名称由每次运行独立生成。`-KeepAlive` 仅在后续全流程验收需要同一 disposable AVD 时使用。`verify-workbench.ps1`、`verify-product-emulator.ps1`、`check-wake-recovery.ps1` 都要求该 AVD 的 `-OwnershipFile`，拒绝借用旧设备/profile；重启还核对实际系统为 API 28，不依赖旧 AVD 名称。APK、androidTest、独立插件包和输出目录可显式传参。

打包将 debug APK、`dansheng-android-x86_64-androidTest.apk` 和独立插件放在任务
`artifacts`，验收默认读取这一组冻结工件；需要指定其他已核验工件时使用显式参数。

生成输出由 `.gitignore` 分类：`android/build` 下 Gradle HTML报告、`build`、`.cxx`、`.gradle`、native SDK、APK/AAR/dspack 和 runtime 不是产品源码。迁移前未跟踪的 `android/build/reports/problems/problems-report.html` 已按原字节归档、通过本机 Git info/exclude 精确排除；该规则只分类，不删除或改写保留的旧报告。fixture/正式源码即使名称相似，也不自动清理。

## 复核、提交与分阶段合并

`git --no-optional-locks diff --check`、`git --no-optional-locks diff` 后运行相关本地检查。只在用户批准后选择明确的 staged 路径并提交/推送/建 PR；生成文件也需要检查差异，不能用“生成了”替代契约一致性。

跨仓库 PR 使用相同 DS 编号，互链 Core/App PR 与测试过的 SHA。先接收兼容 Core，发布不可变的 SDK/Tag；App 固定新依赖，移除本地覆盖并在干净环境验证后再接收。删除旧 API 或数据迁移另列步骤；两个仓库不存在原子提交。当前没有远程 PR/ruleset，不能声称服务端保护已启用。

## 检查范围

每次完成用户要求的改动后，都要生成供用户审阅的已签名 Android release APK，默认 ARM64，
并在回复中交付实际 APK 路径／链接、版本、ABI、SHA-256 和实际校验结果。debug 包或测试报告
不能替代 release 审阅包。使用当前工作树的固定工具链、已核验 `core.lock.json` 与隔离的 D 盘
runtime；审阅签名身份在该 runtime 内创建／复用，保留旧工件和既有身份，不擅自替换原签名。

已有 SDK 时可运行：

```powershell
./scripts/build-beta.ps1 -CoreRoot $CoreTask -CoreToolsRoot $CoreTools `
  -ArtifactDirectory $env:DANSHENG_CORE_SDK_DIR -RuntimeRoot $env:DANSHENG_TASK_RUNTIME `
  -OutputDirectory '<本次任务内的独立输出目录>'
```

该脚本实际使用 `flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub`，
产出内部签名的 release 审阅包。随后执行 `scripts/audit-apk.ps1 -Release -Abi arm64-v8a`、
`zipalign -c -P 16 4` 和 `apksigner verify`，保留构建与核验记录。

审阅包可以消费明确标注的 `development_snapshot`，不因此成为稳定发布。正式发布继续遵守
`-ForRelease` 的依赖门槛并另行授权；构建失败时必须说明真实错误与剩余阻塞，不能称已完成。

- 本地源码：`scripts/check-format.ps1`、`flutter analyze`、`flutter test`。手写 Dart 采用当前 SDK 格式；Pigeon 生成文件以固定生成器的一致性检查为准，不另行手工格式化。
- 绑定：Pigeon 版本由 pubspec.lock 固定，运行 `dart run pigeon --input pigeons/dansheng.dart` 后确认两个生成文件无意外变化。
- Native SDK：Core 的 `Test-DanshengCoreDependency.ps1` 核对 lock、AAR/resources、source/ABI、Pub锁；稳定发布加 `-ForRelease`。
- 已准备 SDK 的环境回归：`scripts/tests/native-environment.integration.ps1` 使用显式 Core/CoreTools/runtime/artifact 参数，检查无预置任务和不同任务环境、失败后的恢复及既存构建副本保留；需要真实 SDK 和已初始化的离线缓存，普通源码 CI 不执行它。
- Android：得到正确 SDK 后才构建；模拟器与真实设备分别授权/记录。现有 `verify-*` 脚本可能操作资源或读取本机凭据，不能作为 CI 中自动可执行的只读脚本。
- `.github/workflows/app-ci.yml` 是最小源码 CI 配置，尚未在远程执行。缺真实已发布 Core acquisition 时，原生干净 CI 构建与稳定发布仍待接线，不能用虚构包/SHA凑齐。

清理需先确认任务已接收且没有 dirty/untracked 内容，保留可恢复记录。不执行 force remove、强制删分支、reset/clean、retag 或覆盖 remote。
