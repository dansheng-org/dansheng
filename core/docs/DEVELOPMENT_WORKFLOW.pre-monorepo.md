# 双仓库开发工作流

Core 活动主库为 `D:\Code\dansheng-core`，App 为 `D:\Code\dansheng-app`。两者的
Git 对象库、主分支、历史、远程、PR 与发布独立。普通工作区使用
`D:\Code\dansheng-workspace`，`local/` 存放可选任务登记与运行资源。新任务的工作树
统一由用户手动或 Herdr 创建到 `D:\worktree`，目录名和布局由管理者选择。
此前 `D:\Worktrees` 下的已登记工作树保留现状，不自动搬迁。普通父目录没有 `.git`。C盘原项目保留为只读参考，
历史验收和发行收据中的原路径保留原文；不把旧路径替换成新构建证据。

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

## 默认日常操作：用户或 Herdr 管理工作树

两个产品目录已经分别是 Git 仓库，无需重新 git init。用户或 Herdr 从对应仓库的
main 创建工作树并指定 `D:/worktree` 内的位置，然后在该目录启动 Agent。Agent
直接使用这棵树，完成代码修改、测试，以及用户要求的提交和合并；创建、选址、
搬迁和清理由用户或 Herdr 管理。DS 编号、额外登记和 TASK.md 不是编辑前提。

在已经创建的工作树里启动，不再给 Agent 添加创建工作树的参数：

```powershell
# 先在 Herdr 中打开所选工作树，或将终端切换到它的实际目录。
codex
claude
```

Herdr 的 New/Open worktree 用于创建或打开任务。TUI 的 `[worktrees] directory`
可设为 `D:/worktree`；桌面版的目录配置与 TUI 独立，创建后应核对实际路径。
用户自行采用 Codex 桌面端创建时，Settings > Worktrees > Worktree root 同样选择
`D:/worktree`。这些是管理者的设置；Agent 不修改个人设置或另建工作树。

一个工作树同时只有一位编辑 Agent。原生暂时 detached HEAD 可以编辑，提交前再创建
任务分支。Agent 自动准备固定工具链、独立构建目标和 D runtime；SDK/AAR、凭据、
profile 和设备数据不会因为 Git worktree 而自动复制或隔离。用户无需手工调用
New/Initialize/Enter，现有 helpers 可由 Agent 或 setup hook 使用。

跨仓库修改时才明确 Core 来源、SDK/lock 和两侧测试版本。下文编号式配对管理器保留
为可选工具，只有用户明确选用时才创建任务树。未合入 main 的任务修改不会
自动进入从 main 新建的工作树。

## 当前路径与历史起点

迁移后两个产品 main 已有本地及远程基线。DS-001 准备分支仍未出生，文件及独立
review index完整保留。正常 DS-002 配对任务已从 Core `ac3d047e`、App `e5ca0f33` 的真实
main 提交创建，DS-003 为独立 Core 路径任务。以下2026-11-10初始审计描述的是建立
基线前的状态，不是当前main。现行任务登记可从 `D:/Code/dansheng-workspace/local/tasks`
读取，不能把准备树的未出生 HEAD 当作任务提交。

2026-11-10 只读审计：两个主库均在未出生的 `main`，无提交、remote 或 tag。
Core 有 204 个 intent-to-add 占位和 63 个未追踪源码；占位不等于真实暂存。
App 快照有 149 项，其中 148 项源码和一份旧 Gradle 构建报告；报告保留但排除于首次
提交清单。源码与 Git 元数据已在仓库外备份；凭据、缓存、原有
产物、数据和签名身份原地保留。此前 Fudan 研究目录是独立恢复副本；在获准转入
真正 Core 任务分支前保持不动，不合并其无共同历史的仓库或覆盖整份源码。

DS-001 的两个准备目录通过 `git worktree add --orphan` 注册到各自原 Git 对象库。
已审计快照载入这些树的独立 review index；没有复制 `.git` 或凭据，没有改主目录
索引或提交。复核发现 App review index 也包含上述旧报告，不能直接把整个 index
作为首次提交。这是本轮准备的特殊状态，不能作为普通任务
或可发布 SHA。首次主线提交、将准备分支接到基线、远程建立/保护/PR/合并仍需审批。

## 正常任务（需要已批准的提交基线）

命令中的路径使用实际配置，脚本本身不硬编码用户目录。先查看计划，再明确执行。

```powershell
$CoreRepo = 'D:\Code\dansheng-core'
$AppRepo = 'D:\Code\dansheng-app'
$Workspace = 'D:\Code\dansheng-workspace'
$Worktrees = 'D:\worktree'
# 工具在真实任务树中；批准集成后可从 Core 主库调用。
$Tools = 'D:\Worktrees\DS-002-devdrive-workflow\core\tools\workspace'

& "$Tools\New-DanshengTask.ps1" -CoreRepo $CoreRepo -AppRepo $AppRepo `
  -WorkspaceRoot $Workspace -WorktreeRoot $Worktrees -TaskId DS-042 -Slug scheduler -Kind feat -Scope Both -Owner codex
# 审查路径、分支和两侧 base_sha 后才追加 -Apply。
& "$Tools\Get-DanshengTaskStatus.ps1" -WorkspaceRoot $Workspace -TaskKey DS-042-scheduler
. "$Tools\Enter-DanshengTask.ps1" -WorkspaceRoot $Workspace -TaskKey DS-042-scheduler -Component core
```

新任务先初始化独立依赖缓存，再进入环境；初始化默认 dry-run，明确 `-Apply` 才复制
缺失的公共依赖数据，已有文件、用户配置、凭据和其他任务目录保留。普通 Enter 与
PairChecks 均由 Git common-dir 找固定工具链，并设置真实任务的 Cargo/Pub/Gradle、
profile、日志和目标目录。App-only 的 Core 源码指向只读主库，验证器工具另选可信目录。

```powershell
& "$Tools\Initialize-DanshengTask.ps1" -WorkspaceRoot $Workspace `
  -TaskKey DS-042-scheduler -Owner codex -CacheRoot 'D:/DevCache'
# 审查计划后在已授权的任务中追加 -Apply；依赖解析验证追加 -ValidateDependencies。
```

主库 App 的旧 Gradle HTML 报告已在 D 盘精确分类为生成物；原路径和字节保留，
归档与本地 Git 排除记录见迁移日志 `workflow-generated-report-classification.json`。
正常 Core/App/Both 来源现在可创建任务，默认仍拒绝未分类的 dirty source。

Core-only/App-only 只创建相应组件；跨仓库任务使用相同编号/分支名，并登记各自准确
基线 SHA。源仓库 dirty 或没有提交时拒绝自动创建；分支/目标目录已存在时不覆盖。
重复调用同一已登记任务仅核验身份并返回状态。部分创建失败保留可审查的记录和树，
不自动回滚删除。工具不执行 fetch、push、PR、merge、commit 或 git init。

管理工具集中在 Core 的 `tools/workspace`。App 和其他 Agent 调用同一套工具。
工具生成的 `TASK.md` 在任务父目录，任务登记在 `local/tasks`；`-WorktreeRoot`可独立指定
工作树父目录，旧版未设置时仍默认工作区的`worktrees/`。不把任务便笺提交到
主线。Codex/Claude/Antigravity 已自行创建的 worktree 不再双建，先人工核对其 Git
common dir、分支和任务归属。当前工具不自动接管未登记目录或 detached HEAD。

## Agent 与运行资源

一个编辑型 Agent 对应一棵明确 worktree。复核者只读；并行处理同一文件必须拆分
任务分支并通过 PR 集成。任务运行目录包含独立 Cargo target/home、Pub/Gradle cache、
tmp、profile、browser、artifact 和 log。`Enter-DanshengTask.ps1` 设置这些环境；不导入
其他账号数据。工具链可执行文件可以只读引用，禁止共享可写构建输出。

端口由服务在 loopback 上动态分配，IPC/profile 路径按任务独立；手机/模拟器、浏览器
认证和系统权限需要另外隔离和授权。不要因源码 worktree 不同就假定外部效果隔离。
同一 Windows 用户的 Git 工作流不是 OS 沙箱，Agent 仍必须遵守授权的写入目录。

## 依赖和验证

实际 App 使用 native SDK/AAR/JNI/Pigeon，采用 [版本契约](../contracts/VERSIONING.md)。
本地联调显式传 Core worktree，稳定构建必须有固定 Core commit、SDK SHA 和已发布
获取位置。禁止 main/latest、未验证 local override、未知 Git SHA 或把开发快照称为 Release。

相关修改运行 `git diff --check`，管理脚本运行 `tools/workspace/tests/Test-Workspace.ps1`；
Rust/SDK 修改运行既有 fmt、all-features tests/Clippy 和 SDK check。App 执行 Flutter 分析、
测试及相应平台冒烟。CI/模拟器/跨编译/真机/学校实读分开报告；没有远程执行记录时
不能声称 GitHub CI 或分支保护已生效。

Windows 依赖缓存回归使用 `tools/workspace/tests/Test-Environment.ps1`，覆盖保留既存字节、
排除用户配置/凭据、链接写前拒绝和输出边界。默认新建临时 fixture，也可指定新的
`-OutputRoot D:/Scratch/<验证名>`；已有 fixture 拒绝复用，测试数据保留供复核。

`Invoke-DanshengPairChecks.ps1` 汇总配对检查，默认只读计划，明确 `-Apply` 才执行。
它拒绝 main/独立 clone，要求准确任务工作树、Core 锁与独立 RuntimeRoot；工作树与
登记目录分开时显式提供 `-WorkspaceRoot`，例如 `D:/Code/dansheng-workspace`。显式
`-AllowPreparation` 才接受当前未出生的准备树。可选 `-NativeSmoke` 仅构建 debug APK，
不安装设备、不使用生产发布密钥。不要在没有匹配 SDK/合法依赖基线时宣称平台构建通过。

配对脚本默认用两个 Flutter 测试进程，避免同时执行原生编译时一次启动大量测试
监听器；需要调整时显式传 `-FlutterTestConcurrency`。测试错误原样保留，不自动清缓存、
关闭其他进程或更改 Windows 网络配置。

## 关闭与集成

关闭默认仅返回计划。真正移除必须是已登记、确认 clean、无未处理 untracked/ignored
文件的任务树，并显式提供 `-Apply -ConfirmRemoval` 和 owner。它不删分支、不清运行目录；
部分关闭失败需要人工核查。不要用 `--force`、reset 或 clean。

每个实际修改的仓库单独集成。跨仓库变化先验证兼容 Core，再将 App 锁到准确版本并
完成干净验证。用户明确要求提交或合并时，Agent 在检查通过后执行，不重复索要
同一授权；合并前复查目标 main 的状态和提交，保留其它任务工作。远程推送、PR、
发布和部署分别报告，未获对应授权时不自动执行。工作树创建和关闭仍由用户或 Herdr 管理。
