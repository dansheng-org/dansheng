# Core 新增服务兼容性与主线集成

本次将保留的 Fudan 研究功能接到正式 Core Git 历史，同时集成此前验证过的
D 盘路径、独立运行资源和开发流程。Core 与 App 仍是两个独立仓库。
记录和主线集成日期为 2026-11-11；兼容性构建日志使用 UTC 时间。

## 来源与修改范围

- 正式 Core 基线为 `ac3d047ec3a269b52f21a80226b763c3838f5774`，267 个源码文件。
- 独立研究副本 `D:/Code/dansheng-fudan-service-research-20261110` 的 347 个源码
  全部匹配恢复 journal，差异为 28 项修改、80 项新增。
- 只转入这 108 项研究增量；与迁移工作流重叠的 7 个文件按共同基线三方处理，
  其中 5 个存在文本冲突。原研究副本、其它工作树、原项目和凭据保持原样。
- 实施使用已有、Git 登记的 `D:/Worktrees/DS-002-devdrive-workflow/core`，没有新建或搬迁
  产品工作树。构建、缓存、合成 profile 和日志位于新的
  `D:/Scratch/dansheng-core-integration-20261111T015425Z`。
- 审计、完整差异及集成结果保存于
  `D:/MigrationLogs/dansheng-core-integration-20261111T015425Z`。

当前验证生产输入为 **66 项**，SHA-256 为
`5e482d26f6519f8199fecfae9fb5531d8e5cc5e7441ec3632e25bef6394b3590`。
该口径包括 Rust/manifests/lock/toolchain/C 头文件，包含源码文件内的测试代码；
不是完整仓库的文件摘要。研究原批次的 `fdbaeab6…`、迁移批次的 59 项输入和旧 SDK
摘要只用于各自历史，不标识本次合入版本。准确集成提交见本文件的 Git 历史和
仓库外 `merge-result.json`，无需在提交内引用自身 SHA。

## 新增的 26 个校园方法

| 范围 | 新方法 |
| --- | --- |
| 开课目录和大纲 | `fudan.catalog.semesters/lessons/course/syllabus` |
| 公共培养方案 | `fudan.programs.list/detail` |
| eHall | `fudan.ehall.catalog/tasks/tasks.sync` |
| Canvas 测验和讨论 | `canvas.quizzes.sync`、`canvas.quiz.read`、`canvas.discussions.sync`、`canvas.discussion.read/view` |
| Canvas 本人学习数据 | `canvas.assignment_groups.sync`、`canvas.submission.self`、`canvas.enrollments.self`、`canvas.grades.self` |
| 图书馆发现与借阅 | `fudan.library.lookup/bibliography/holdings/loans.current/loans.history` |
| 图书馆可信读者绑定 | `fudan.library.reader.observe/bind/clear`，仅 Owner 配置入口 |

校园目录从 50 项增为 76 项，旧方法名称和权限键均保留。功能存在与本人真实业务
成功是两项不同证据；私人借阅、eHall 部分队列、Canvas Token 等限制仍按
[研究矩阵](fudan-service-research/delivery-matrix.md)记录。本次兼容性检查没有读取真实
凭据或重新执行学校业务。培养方案、官方课评、云盘和其它网站也不会因目录入口
或通用传输能力完成而被视为全部接入。

## 兼容性结论

原 **83 个 Core 方法标识**保留；`include/dansheng.h`、全部 FFI 源码、Core
Request/Response 定义与基线逐字节相同。旧 HTTP 结构和方法签名保持，
`auth.session.set` 只新增可选 `secret_headers`；旧 Bearer/Cookie 参数继续接受。
TS 的 BrowserSession 只增加可选 `origin`，既有 `require_authenticated` 保留。

以下变化需消费方理解：

- Rust 公开枚举增加 `CredentialKind::SecretHeaders`、`TransportAuth::HostHeaders`
  和 `AuthMode::SecretHeaders`。外部穷举 `match` 要补分支或通配分支，不能把
  C ABI 稳定理解为 Rust 源码无条件兼容。
- 新敏感头仅通过可信宿主按账号、origin 和明确类型导入。与调用者手工头发生
  冲突时拒绝请求；旧 setter 替换该 origin 且不传新字段时清除其新敏感头。
- 服务和分页在 I/O 前后重新检查权限、账号和凭据身份；中途退出、换号、撤权或
  轮换会话时失败，避免将不同身份的数据合并为同一结果。
- 新 typed BrowserSession 服务要求当前页的可信 account/origin/authenticated/handle
  回执。缺少端口时返回 CapabilityUnavailable，不改用原生 HTTP。
- 原生读取流超时保留 Timeout；外部写入超时仍保留需要对账的不确定结果。
  页面响应 URL 可以保留安全查询参数，认证材料仍移除。
- MCP 保留原过滤规则，自动发现符合 `.read` 权限的新方法；读者绑定、登录、
  配置及可信写入/对账方法继续排除。默认真实 Host 冒烟仅用合成数据，学校公开
  检查改为显式 `--public-catalog` / `--public-notices`。

独立 review 未发现阻断本次 main 整合的新增生产源码问题。一个诊断限制仍存在：
部分 Android 页面 GET 超时会先返回 BrowserRequestFailed，再显示为
SourceTransportUnavailable；本次不将原生 Timeout 的测试结论扩展到全部页面端口。

## 本次实际验证

| 检查 | 结果与边界 |
| --- | --- |
| Windows Rust 全 workspace/all-features/all-targets | **501 passed，0 failed，1 ignored**；ignored 为手动 stdin 探针 |
| Rust fmt、严格 Clippy、原生构建 | 通过，Rust 1.99.1 Windows GNU；全部使用当前 66 项输入 |
| SDK facade 与 TypeScript 检查 | 通过，没有增设可访问原始凭据的插件命名空间 |
| Node 插件、页面与输出路径回归 | **44 项通过**；合成数据，包含越界和 junction 写前拒绝 |
| PowerShell 工作流和缓存隔离 | **68 项通过**：Workspace 42、Environment 6、RuntimePaths 20 |
| 全部 PowerShell 脚本语法 | **34 文件通过**，没有语法错误 |
| 原 C ABI smoke | 编译/执行均通过，使用原 C 客户端调用当前 DLL；含 open/request/poll/free/close 和无效句柄检查 |
| 真实 IPC/MCP 与同包回归 | **9 项 IPC/MCP 检查通过**；QuickJS/SQLite/认证挑战/重启闭环通过，loopback 1 次 GET，没有学校请求 |
| Android Rust | 当前 x86_64 与 ARM64 release SO 构建通过；两个架构均仅编译，不冒充设备执行 |
| Android 适配层/JNI | **6 项 JVM 测试通过**；双 ABI release AAR、x86_64 JNI 验证 APK 和 test APK 构建通过 |
| 原 App 消费新 Core | 原 main 的 148 项源码只复制到临时验证目录；**7 项 JVM 测试通过**，配当前双 ABI SDK 的 x86_64 debug APK 构建成功；业务代码及 pub 锁没有改动 |

历史 Linux 499 项、Android 31/JVM 6 项和旧 release 重现均保留于研究文档，不计为
本轮重新执行。本次没有生产设备、真实服务写入、远程 CI、Release 或发布。

当前双 ABI AAR SHA-256 为
`c6a978f19630edbe1006d835595d04e6d0dba3018d64dee5982e8508c9f1227b`。
原 App 验证 APK SHA-256 为
`c04f292c7fee82be867ed806bbd136059e96fddfafc135dc53c7892264c2fef4`。
APK 中实际的 x86_64 FFI entry 与当前 debug/release AAR 的 x86_64 entry 均为
`c9a58349257260bf9b675b8ba1ab6816a516a102f6644f8950f538dd1d6e4563`。
AGP 打包后的 SO 与 Rust staging SO 分别记录，未假定两个摘要相同。
App 的旧 `../../dansheng` 和 `.local/native` 路径仅在临时目录映射，首次缺少忽略的
Gradle wrapper 的失败记录保留，补齐本地构建条件后通过。没有安装或运行 APK。
最终边界审计保留独立 ordinal 清单摘要与构建脚本摘要两个口径；66 项文件内容和
摘要逐个一致，文件排列差异没有被当作源码变更或新构建。

## App 依赖与工作树使用

App 主库基线 `e5ca0f33bfe6c7451cb10978baa4bd9a25a5bdc9` 不因 Core 合并而更新。
其旧路径及 SDK 获取方式尚未合入迁移修正；新 Core main 的源码/SDK 身份也不会
自动写进 App 的消费锁。本次仅集成 Core，App 源码、分支、索引及锁保持原样。
后续 App 采用新的 Core commit/SDK 时要更新精确依赖并完成对应验证。

新任务工作树由用户手动或 Herdr 创建到 **`D:/worktree`**。Agent 在指定树内开发，
自动准备独立运行资源，并在用户要求后完成提交和合并。额外 DS 编号、TASK.md
和配对脚本不是前提。已有 `D:/Worktrees` 路径、历史任务及验证资料保留，Agent
不自动创建、搬迁或删除产品工作树。

本次 Core 提交和本地 main 合并已获用户明确授权。合并前复查 main 的基线和 clean
状态，通过普通提交与 fast-forward 集成，保留之前提交；本地合并与远程推送分别
报告，本轮不自动推送两个仓库。
