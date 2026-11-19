# 自托管 CI

本文记录个人仓 `DANSHENG/dansheng` 的预装工具、自托管 runner 和签名配置。组织仓的 GitHub 托管检查与手动同步流程见 [测试与验收](testing.md)。

## 调度与检查

所有执行 job 均使用自托管 runner；reusable workflow 的 `core`、`checks` 继续调用同一套检查，不另占 hosted runner。

| 现有检查 / job | 实际 runner labels | 覆盖 |
| --- | --- | --- |
| workspace-scripts | `[self-hosted, linux, x64, dansheng-scripts]` | Bash 入口；App/Core 路径、锁、APK archive、prerelease、monorepo、CI 缓存、Python audit 与 workspace entry 夹具 |
| flutter | `[self-hosted, linux, x64, 1402ubuntu]` | 锁定 Pub、手写格式、analyze、test、Pigeon 生成差异 |
| core / native (ubuntu-latest) | Linux 同上 | fmt、全 workspace/all-features/all-targets tests、strict Clippy、workspace/monorepo 夹具 |
| core / native (windows-latest) | Windows 同上 | fmt、全 workspace/all-features/all-targets tests、strict Clippy、Windows Robocopy/NTFS 依赖缓存隔离夹具；使用 GNU Rust，无需 MSVC |
| core / sdk | Linux 同上 | npm 锁、TypeScript check、Node runtime-path tests |
| core / android | Linux 同上 | Core ARM64 / x86_64 两 ABI 的 locked release 编译 |
| android-source-sdk | Linux 同上 | exact checkout 双 ABI Core、JNI/AAR、SDK lock/receipt 校验、App Kotlin/Pigeon debug 编译、Android host tests、APK payload audit |
| Pre-release build / publish | Linux 同上 | exact SHA SDK、原 GitHub Secrets 签名、ARM64 release、原有 APK/ELF/16 KiB/签名审计、SHA256SUMS、不可覆盖发布 |

`native` 的矩阵显示名保留 `ubuntu-latest` / `windows-latest`，以保留原 required-check 名称；它们不是 `runs-on`。实际调度只读取矩阵中的四个 self-hosted labels。

`workspace-scripts` 在 Linux 使用 Bash 启动，现有 `.ps1` 工具的回归测试由预装的 PowerShell 7 执行，Python audit 测试由 Bash 直接调用。worktree/monorepo 集成夹具只在 Linux native job 执行，不再在 Windows 重复启动大量 Git 进程。Windows runner 保留原生编译、Rust 检查和必须使用 Windows Robocopy/NTFS 的依赖缓存隔离测试。

Linux 当前部署 3 个通用 runner（`1402ubuntu`）和 4 个脚本专用 runner（`dansheng-scripts`）。脚本专用 runner 不带 `1402ubuntu` 标签，Rust/Android/Flutter 构建不能占用脚本池；`workspace-scripts` 有独立的 4 个并发席位。两类 runner 共用预装工具，各自维护注册身份和 checkout，脚本 runtime 继续按 run/job/attempt 隔离。新增专用 runner 不改变现有通用 runner 的编译缓存布局。

PR job 在调度前要求 `head.repo.full_name == github.repository`；外部 fork 的所有执行 job 跳过，不 checkout 或执行 fork 代码。不使用 `pull_request_target`。正常 push 仅监听 main。所有 checkout 固定到事件的精确 SHA，PR 使用 GitHub merge SHA；预发布使用成功 main push 的 `workflow_run.head_sha`。checkout 不持久化 token。

## Runner 环境接口

runner 父进程必须注入绝对路径 `DANSHENG_CI_ROOT`。公开 workflow 不包含用户目录、用户名、机器的 SSH 配置或环境入口 fallback。

- Windows：`Initialize-Runner.ps1` dot-source `$DANSHENG_CI_ROOT/runner-env.ps1`。
- Linux：bash 先 `source "$DANSHENG_CI_ROOT/runner-env.sh"`，再从该 PATH 启动 portable `pwsh -NoLogo -NoProfile`，执行同一个初始化脚本。
- 环境入口应导出所需的工具环境，失败时返回非零；入口不得输出密码、token 或完整环境。

| 入口提供 | 要求 |
| --- | --- |
| PATH | Git、PowerShell 7；按 job 提供 Python 3、Node 22/npm、Rust、Flutter、Java、Gradle、gh。Linux 另需 bash、chmod、sha256sum |
| RUSTUP_HOME / RUSTUP_TOOLCHAIN | 独立预装工具根；rustc 1.99.1。Windows 选择 `stable-x86_64-pc-windows-gnu`，Linux 选择预装的 1.99.1 GNU Linux toolchain。不能借用开发工作树的 Cargo 配置或凭据 |
| JAVA_HOME / GRADLE_HOME | Linux Android：Java 21、Gradle 9.7.1 安装根；不是缓存目录 |
| ANDROID_HOME / ANDROID_SDK_ROOT | 同一预装 SDK；NDK 30.0.16138531、platform android-37.0、build-tools 36.0.0（AGP 编译）及 37.0.0（审计）、cmdline-tools/latest、CMake 3.22.1；Rust 预装两个 Android targets |
| RUNNER_TOOL_CACHE | CI 专用工具缓存；由 runner 父进程部署配置提供，不尝试通过 GITHUB_ENV 覆写 GitHub 默认变量 |
| CARGO_BUILD_JOBS / DANSHENG_GRADLE_WORKERS | 每个 job 的并发预算；1402 当前可见 112 逻辑 CPU，配置为 32 / 16，三个 worker 同时最多分配 96 个 Cargo 编译任务。取值必须为 1 至 256 的整数；未配置时保留本地脚本 3 / 2 的默认值 |
| 其他工具环境 | 需要时提供 LIBCLANG_PATH、GNU compiler PATH / linker 变量、Flutter mirror 变量；初始化保留并导出到后续步骤 |

入口只选择已安装的工具。workflow 不执行 setup-*、rustup install、sdkmanager 安装或每次下载工具链；初始化验证工具版本/文件，缺失时失败。依赖解析仍通过锁定的 cargo fetch、npm ci、flutter pub get 和 Gradle 执行。

初始化向后续 Actions 步骤导出：

- `CARGO_BUILD_JOBS`、`DANSHENG_GRADLE_WORKERS` 和 `CMAKE_BUILD_PARALLEL_LEVEL` 显式写入 GITHUB_ENV；Gradle 启用项目并行并遵守同一 worker 预算。Android producer 不再用固定 `-j 3` 或 `--max-workers=2` 覆盖配置。Cargo 预算控制同时可运行的编译任务；依赖图末尾的单个模块仍可能处于串行阶段。

- `DANSHENG_CI_CACHE_ROOT=$DANSHENG_CI_ROOT/cache/{main|checks}/$GITHUB_JOB`。main 与 PR/其他分支缓存分开；相同 job 后续运行复用本机依赖缓存。
- 公共只读 seed 位于 `$DANSHENG_CI_ROOT/cache/cargo-home` 与 `cache/pub`。初始化按 job 需要单向导入 lane/job 缓存：native/android 只导入 Cargo，flutter 只导入 Pub，AndroidSource/Release 导入两者，workspace/sdk/publish 不导入无关 seed。允许列表仅为 `cargo-home/registry/cache`、`cargo-home/registry/index`、`pub/hosted`、`pub/hosted-hashes`；registry 的公开 index 元数据属于依赖数据。既有 job 文件不覆盖、不向 seed 回写，也不递归进入其他 lane/job。
- seed 不导入 Cargo bin/target、编译 target、git checkout、Gradle 缓存或 profile；允许树中的凭据、Cargo/npm/Git/Gradle 用户配置、锁文件与临时复制文件也排除，跳过链接及 `.git`、`.ssh`、`.dart_tool` 目录。seed 必须由部署者从公开依赖准备，不扫描或读取用户目录。
- `CARGO_HOME=.../cargo-home`、`PUB_CACHE=.../pub`、`GRADLE_USER_HOME=.../gradle`、`npm_config_cache=.../npm`。Android 生产脚本保留自身 runtime 缓存约束；`Invoke-Android.ps1` 从常驻缓存向 runtime 同步公开依赖子目录，结束时在 finally 中回存新文件，既有缓存文件不覆盖。只同步 Cargo registry archive/index、git 数据，Pub hosted/hash/git 和 Gradle caches/wrapper/native；不复制个人配置、credential、锁文件、签名或编译 target。
- `DANSHENG_TASK_RUNTIME=$DANSHENG_CI_ROOT/runtime/$GITHUB_RUN_ID/$GITHUB_JOB/$GITHUB_RUN_ATTEMPT`。已存在时拒绝复用；重新运行使用新的 attempt。
- `DANSHENG_TASK_HOME=$DANSHENG_TASK_RUNTIME/home` 是任务专用 home 变量；不重设或导出系统 `HOME` / `USERPROFILE`。Cargo target、Android user/AVD、XDG 配置/数据、APPDATA/LOCALAPPDATA、应用/浏览器 profile、GH_CONFIG_DIR、临时目录均显式隔离。Git global config 和 npm userconfig 为空的任务独立文件，清除继承的 Core source/SDK/lock/signing 选择，不读取工作树账号文件或共享测试凭据。导出 PATH 保留环境入口的优先级，使 CI Node 22 优先于系统 Node。
- Java 的 `user.home` 单独设置：`JAVA_TOOL_OPTIONS` 提供带引号的 `-Duser.home=<DANSHENG_TASK_HOME>`，兼容含空格路径，并对 Gradle、keytool 等 JVM 工具生效。清除继承的 `JAVA_OPTS`、`JDK_JAVA_OPTIONS`、`_JAVA_OPTIONS`，避免私人 JVM 参数覆盖该目录。Gradle/Pub/npm 继续使用显式缓存根；Java/Gradle 的运行用户数据不依赖系统 home 重定向。AndroidSource/Release 健康检查实际核验 JVM `user.home`。

CI 根可同时容纳 runner 的 `_work` checkout，但 runtime/cache 必须位于 checkout 之外。runtime/cache 不接受链接或链接祖先。权限限制只作用于本次 runtime、由该 runtime 推导出的 task home 及 signing 子路径，绝不对系统 home 或其他真实用户目录执行 chmod。不要把真实账号、Cargo credentials、Gradle properties/init scripts 或用户配置预置进公共依赖缓存。

检查类 job（Native、Android、AndroidSource 等）的 Rust 编译输出跨运行保留在 `$DANSHENG_CI_ROOT/build-cache/<lane>/<job>-<os>/`：`cargo-target`，以及 SDK 检查的 `cargo-arm64`、`cargo-x86`（经 `DANSHENG_CI_NATIVE_TARGET_ROOT` 传给 `prepare-native.ps1`）。原因：每次全新编译会重编全部依赖；Windows 桌面 runner 上每个新生成的可执行文件首次启动还要经过约 1–4 秒的信誉检查（Defender 目录排除不覆盖），一次运行新建约 120 个（构建脚本与测试程序），native job 因此 16–19 分钟而 CPU 大多空闲。`main` 与 `checks`（PR）两条 lane 互不共享；该目录不是依赖缓存，从不播种或发布；Cargo 的指纹保证复用正确，构建目录锁串行化并发 runner；单个目录超过 10 GiB 时在下一次初始化时清空重建（完整测试构建约 4 GiB）；SDK 检查旁的固定 `cargo-home` 上限 4 GiB。lane/job 依赖缓存（`cache/<lane>/<job>`）只增不减，超过 12 GiB 时同样清空，Cargo/Pub 随后由 seed 重新导入，Gradle 重新下载一次。体积统计使用托管枚举，跳过链接。Release/Publish 始终在本次 runtime 的空目录中编译，发布产物不依赖保留输出，`DANSHENG_CI_NATIVE_TARGET_ROOT` 对它们显式清空。

每个 job 最后通过 `always()` 执行 `Clear-Runtime.ps1 -Checkout $GITHUB_WORKSPACE`：核对 run/job/attempt 归属 marker 与链接祖先后，在本次 runtime 写入 `.ci-finished`，作为该 job 最近一次 runtime 保留以便排查；同时删除同名 job 此前已标记完成的 runtime（复制进来的 Cargo/Pub/Gradle 缓存、Gradle/CMake 中间产物、发布用 Cargo target、下载的发布载荷、tmp 与 task home）。未标记完成的 runtime（可能仍在运行）不删除；runtime 内的链接只删除链接本身，不跟随。随后对 checkout 执行 `git clean -ffdx`（actions/checkout 下次也会做），释放 Flutter/Gradle 构建目录。保留的编译输出和依赖缓存位于 runtime 之外，不受影响。删除失败只发出 warning。

## 签名与发布

继续使用仓库 Secrets `DANSHENG_PRERELEASE_KEYSTORE_BASE64` 和 `DANSHENG_PRERELEASE_KEYSTORE_PASSWORD`。源码 SDK 完成后才解码到本次 runtime 的 `signing/prerelease.p12`；Linux 目录 0700、文件 0600。密码只传给需要它的步骤，不写入 GITHUB_ENV 或缓存。

build 最后的 `always()` 步骤只删除该 run/job/attempt 的固定 `signing` 子目录，并核对 runtime 路径、归属 marker 和链接。SDK/APK 证据上传只列明公开产物，不上传 runtime 整体。runner 被强制杀死或掉电时，Actions 无法执行最后一步；每次初始化会删除 `runtime/<run>/<job>/<attempt>` 中未标记完成、且目录与 marker 均超过 24 小时未修改的遗留 runtime（远超 Actions 单 job 6 小时上限，不会删除仍在运行的 job），只识别数字 run/attempt 与合法 job 名，不进入链接；遗留 signing 文件随之删除。

发布 job 下载到自己的 runtime/release，先验证全部 SHA256SUMS 与必需资产，再创建新 tag、draft 并发布 prerelease。已有 release/tag 会失败，不覆盖、不移动 tag、不使用 `--clobber`。每次新 APK 发布仍须递增 pubspec 的版本和构建号；自动发布只在 main 的完整检查成功后触发，smoke 不触发发布。

## 验收

```powershell
./scripts/ci/tests/Runner.Tests.ps1
# 安装好 actionlint 后（声明自定义 self-hosted labels）：
actionlint -config-file scripts/ci/actionlint.yaml .github/workflows/app-ci.yml .github/workflows/core-ci.yml .github/workflows/app-prerelease.yml
```

该脚本使用合成环境、假工具与 dummy 签名字节，验证系统 HOME/USERPROFILE 保持不变、task home 与显式目录、chmod 越界拒绝、公共 seed 允许列表/只读/不覆盖/链接排除、runtime/缓存及 attempt 隔离、签名清理、相对路径每批 32 文件格式检查与生成文件排除。有本地 Java 时，另用真实 JVM 验证含空格的 `user.home`，只报告通过状态；不证明 runner 已上线或 Android 已成功构建。

部署者可手动触发 `app-ci.yml` 的 `workflow_dispatch`，设置 `smoke=true`。它保留七个检查的调度，执行预装平台健康检查，跳过业务构建。smoke dispatch 不满足自动预发布要求的 main push 事件。smoke 通过后，再使用 `smoke=false` 跟踪同一准确 SHA 的七项完整检查；仅凭 smoke 成功不能认定全部 tests 或产物已通过。

GitHub 接口依据：[self-hosted labels](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)、[job 条件与 reusable workflow inputs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)。部署、认证、runner 注册和真实 CI 验收由部署任务记录，不在这份文件中写入机器私有信息。
