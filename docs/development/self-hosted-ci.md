# 自托管 CI

## 调度与检查

所有执行 job 均使用自托管 runner；reusable workflow 的 `core`、`checks` 继续调用同一套检查，不另占 hosted runner。

| 现有检查 / job | 实际 runner labels | 覆盖 |
| --- | --- | --- |
| workspace-scripts | `[self-hosted, windows, x64, dansheng-win]` | App/Core 路径、锁、APK archive、prerelease、monorepo、Python audit 与 workspace entry 夹具 |
| flutter | `[self-hosted, linux, x64, 1402ubuntu]` | 锁定 Pub、手写格式、analyze、test、Pigeon 生成差异 |
| core / native (ubuntu-latest) | Linux 同上 | fmt、全 workspace/all-features/all-targets tests、strict Clippy、workspace/monorepo 夹具 |
| core / native (windows-latest) | Windows 同上 | 同上，另含依赖缓存隔离夹具；使用 GNU Rust，无需 MSVC |
| core / sdk | Linux 同上 | npm 锁、TypeScript check、Node runtime-path tests |
| core / android | Linux 同上 | Core ARM64 / x86_64 两 ABI 的 locked release 编译 |
| android-source-sdk | Linux 同上 | exact checkout 双 ABI Core、JNI/AAR、SDK lock/receipt 校验、App Kotlin/Pigeon debug 编译、Android host tests、APK payload audit |
| Pre-release build / publish | Linux 同上 | exact SHA SDK、原 GitHub Secrets 签名、ARM64 release、原有 APK/ELF/16 KiB/签名审计、SHA256SUMS、不可覆盖发布 |

`native` 的矩阵显示名保留 `ubuntu-latest` / `windows-latest`，以保留原 required-check 名称；它们不是 `runs-on`。实际调度只读取矩阵中的四个 self-hosted labels。

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
| 其他工具环境 | 需要时提供 LIBCLANG_PATH、GNU compiler PATH / linker 变量、Flutter mirror 变量；初始化保留并导出到后续步骤 |

入口只选择已安装的工具。workflow 不执行 setup-*、rustup install、sdkmanager 安装或每次下载工具链；初始化验证工具版本/文件，缺失时失败。依赖解析仍通过锁定的 cargo fetch、npm ci、flutter pub get 和 Gradle 执行。

初始化向后续 Actions 步骤导出：

- `DANSHENG_CI_CACHE_ROOT=$DANSHENG_CI_ROOT/cache/{main|checks}/$GITHUB_JOB`。main 与 PR/其他分支缓存分开；相同 job 后续运行复用本机依赖缓存。
- 公共只读 seed 位于 `$DANSHENG_CI_ROOT/cache/cargo-home` 与 `cache/pub`。初始化按 job 需要单向导入 lane/job 缓存：native/android 只导入 Cargo，flutter 只导入 Pub，AndroidSource/Release 导入两者，workspace/sdk/publish 不导入无关 seed。允许列表仅为 `cargo-home/registry/cache`、`cargo-home/registry/index`、`pub/hosted`、`pub/hosted-hashes`；registry 的公开 index 元数据属于依赖数据。既有 job 文件不覆盖、不向 seed 回写，也不递归进入其他 lane/job。
- seed 不导入 Cargo bin/target、编译 target、git checkout、Gradle 缓存或 profile；允许树中的凭据、Cargo/npm/Git/Gradle 用户配置、锁文件与临时复制文件也排除，跳过链接及 `.git`、`.ssh`、`.dart_tool` 目录。seed 必须由部署者从公开依赖准备，不扫描或读取用户目录。
- `CARGO_HOME=.../cargo-home`、`PUB_CACHE=.../pub`、`GRADLE_USER_HOME=.../gradle`、`npm_config_cache=.../npm`。Android 生产脚本保留自身 runtime 缓存约束；`Invoke-Android.ps1` 从常驻缓存向 runtime 同步公开依赖子目录，结束时在 finally 中回存新文件，既有缓存文件不覆盖。只同步 Cargo registry archive/index、git 数据，Pub hosted/hash/git 和 Gradle caches/wrapper/native；不复制个人配置、credential、锁文件、签名或编译 target。
- `DANSHENG_TASK_RUNTIME=$DANSHENG_CI_ROOT/runtime/$GITHUB_RUN_ID/$GITHUB_JOB/$GITHUB_RUN_ATTEMPT`。已存在时拒绝复用；重新运行使用新的 attempt。
- `DANSHENG_TASK_HOME=$DANSHENG_TASK_RUNTIME/home` 是任务专用 home 变量；不重设或导出系统 `HOME` / `USERPROFILE`。Cargo target、Android user/AVD、XDG 配置/数据、APPDATA/LOCALAPPDATA、应用/浏览器 profile、GH_CONFIG_DIR、临时目录均显式隔离。Git global config 和 npm userconfig 为空的任务独立文件，清除继承的 Core source/SDK/lock/signing 选择，不读取工作树账号文件或共享测试凭据。导出 PATH 保留环境入口的优先级，使 CI Node 22 优先于系统 Node。
- Java 的 `user.home` 单独设置：`JAVA_TOOL_OPTIONS` 提供带引号的 `-Duser.home=<DANSHENG_TASK_HOME>`，兼容含空格路径，并对 Gradle、keytool 等 JVM 工具生效。清除继承的 `JAVA_OPTS`、`JDK_JAVA_OPTIONS`、`_JAVA_OPTIONS`，避免私人 JVM 参数覆盖该目录。Gradle/Pub/npm 继续使用显式缓存根；Java/Gradle 的运行用户数据不依赖系统 home 重定向。AndroidSource/Release 健康检查实际核验 JVM `user.home`。

CI 根可同时容纳 runner 的 `_work` checkout，但 runtime/cache 必须位于 checkout 之外。runtime/cache 不接受链接或链接祖先。权限限制只作用于本次 runtime、由该 runtime 推导出的 task home 及 signing 子路径，绝不对系统 home 或其他真实用户目录执行 chmod。不要把真实账号、Cargo credentials、Gradle properties/init scripts 或用户配置预置进公共依赖缓存。

Rust 和 Android job 最后通过 `always()` 清理本次 runtime 下的 `cargo-target`、`cargo-arm64`、`cargo-x86` 编译目录，核对 run/job/attempt 归属并拒绝链接路径。公开依赖缓存、SDK 和审计证据保留，后续任务继续使用新的编译目录。

## 签名与发布

继续使用仓库 Secrets `DANSHENG_PRERELEASE_KEYSTORE_BASE64` 和 `DANSHENG_PRERELEASE_KEYSTORE_PASSWORD`。源码 SDK 完成后才解码到本次 runtime 的 `signing/prerelease.p12`；Linux 目录 0700、文件 0600。密码只传给需要它的步骤，不写入 GITHUB_ENV 或缓存。

build 最后的 `always()` 步骤只删除该 run/job/attempt 的固定 `signing` 子目录，并核对 runtime 路径、归属 marker 和链接。SDK/APK 证据上传只列明公开产物，不上传 runtime 整体。runner 被强制杀死或掉电时，Actions 无法执行最后一步；部署维护应在 runner 离线时处理遗留 signing 文件，禁止运行中的并发全根清理。

发布 job 下载到自己的 runtime/release，先验证全部 SHA256SUMS 与必需资产，再创建新 tag、draft 并发布 prerelease。已有 release/tag 会失败，不覆盖、不移动 tag、不使用 `--clobber`。每次新 APK 发布仍须递增 pubspec 的版本和构建号；自动发布只在 main 的完整检查成功后触发，smoke 不触发发布。

## 验收

```powershell
./scripts/ci/tests/Runner.Tests.ps1
# 安装好 actionlint 后（声明两个自定义 self-hosted labels）：
actionlint -config-file scripts/ci/actionlint.yaml .github/workflows/app-ci.yml .github/workflows/core-ci.yml .github/workflows/app-prerelease.yml
```

该脚本使用合成环境、假工具与 dummy 签名字节，验证系统 HOME/USERPROFILE 保持不变、task home 与显式目录、chmod 越界拒绝、公共 seed 允许列表/只读/不覆盖/链接排除、runtime/缓存及 attempt 隔离、签名清理、相对路径每批 32 文件格式检查与生成文件排除。有本地 Java 时，另用真实 JVM 验证含空格的 `user.home`，只报告通过状态；不证明 runner 已上线或 Android 已成功构建。

部署者可手动触发 `app-ci.yml` 的 `workflow_dispatch`，设置 `smoke=true`。它保留七个检查的调度，执行预装平台健康检查，跳过业务构建。smoke dispatch 不满足自动预发布要求的 main push 事件。smoke 通过后，再使用 `smoke=false` 跟踪同一准确 SHA 的七项完整检查；仅凭 smoke 成功不能认定全部 tests 或产物已通过。

GitHub 接口依据：[self-hosted labels](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)、[job 条件与 reusable workflow inputs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)。部署、认证、runner 注册和真实 CI 验收由部署任务记录，不在这份文件中写入机器私有信息。
