# dansheng-core

本地优先、与 UI 分离的 Rust 校园数据和自动化内核。Android 内嵌同一个核心；Windows/Linux 通过本地服务供 UI、CLI 和 MCP 共用数据。项目采用 GPL-3.0-or-later。

这是首个可运行的开发版本。代码实现、离线契约测试、模拟器执行和真实校园服务验证是不同的验收项；当前状态见 [验证记录](docs/validation.md)，长期阶段见 [roadmap](docs/roadmap.md)。生产 UI 不在这个仓库内。

需要先录入凭据测试时，使用 [本地实验台](tools/dansheng-lab/README.md)：在 PowerShell 7 运行 `./scripts/start-lab.ps1`，浏览器会打开仅限本机的测试 UI。凭据通过 DPAPI 保存到仓库外的独立 profile，录入后可以运行预设的只读验证。

## 组成

| 目录 / crate | 内容 |
| --- | --- |
| `dansheng-core` | HTTP/会话、SQLite、权限、任务、JS 插件、文件与搜索、日历待办、事件、签名包校验 |
| `dansheng-connectors` | 复旦课表和校园服务、Canvas、茶楼/蛋壳查询；可选原生 IMAP/SMTP 服务 |
| `dansheng-host` | 认证本地 IPC、CLI、stdio MCP、桌面凭据存储 |
| `dansheng-ffi` | UI 无关的异步 C ABI 和平台能力队列 |
| `platform/android` | Kotlin/JNI、系统 WebView、Keystore、唤醒与前台执行，以及独立验证宿主 |
| `plugins` / `sdk` | 官方示例、`fudan-sports` 插件、TypeScript 类型与契约审计 |

运行时不包含 Node.js、Flutter 或整套 Chromium。Node 仅用于 SDK 和插件开发测试；Android 使用系统 WebView。PDF 文本抽取通过 `dansheng-core/pdf` 特性选配。

## 构建与测试

需要 Rust 1.99.1 和平台 C 工具链。Windows 当前工作区的便携工具位于忽略的 `.local/toolchain`，不会加入用户全局 PATH：

```powershell
. ./scripts/dev.ps1
cargo test --workspace --all-features --locked
cargo clippy --workspace --all-features --all-targets --locked -- -D warnings
cargo build -p dansheng-host --release --locked
```

在其他机器上先安装 Rust 和本平台 C 编译器；不要依赖 `.local` 被提交。Linux 使用正常的 Rust/C 工具链，桌面凭据存储需要可用的 Secret Service。Windows 本地便携构建使用 GNU 工具链；CI 同时配置 Windows 和 Linux 原生验证。

```powershell
npm --prefix sdk ci --ignore-scripts
npm --prefix sdk run check
node --test plugins/examples/tests/examples.test.mjs
node --test plugins/fudan-sports/tests/plugin.test.mjs plugins/fudan-sports/tests/page-transport.test.mjs
```

Android Rust 构建：

```powershell
. ./scripts/android-env.ps1 -Architecture x86_64
cargo build -p dansheng-ffi --target x86_64-linux-android --release --locked
# ARM64 将 Architecture 改为 aarch64，target 改为 aarch64-linux-android。
```

Android 库、验证 APK、JNI 和模拟器命令见 [Android 接入说明](docs/android-sports.md)。C ABI 的唯一签名来源是 [dansheng.h](include/dansheng.h)。发布时使用 release 产物，debug `.so` 的调试信息不代表发布体积。

生产 Android 工作台位于独立工程 `C:/Code/dansheng-app`。eHall 的[手动场馆服务](plugins/builtin/fudan-venues/README.md)随 APK 提供；[定时抢场](plugins/fudan-sports/README.md)单独发布成 `.dspack`，导入后默认关闭。eLearning、Agent 和论坛都是内置功能。

当前本机产物位于忽略的 `dist/dansheng-core-0.1.0/`，包含 Windows x64 可执行程序、Android ARM64 核心库、对应源码、许可证和 SHA-256。使用 `./scripts/build-windows-release.ps1` 与 `./scripts/build-android-release.ps1` 生成绑定源码的 receipts，再运行 `./scripts/package.ps1` 和 `./scripts/verify-package.ps1`。脚本拒绝旧产物与当前源码混配；独立构建、确定性归档及回退说明见 [发布流程](docs/release.md)。它们是开发版核心产物，Android ZIP 不是完整 App。

## 桌面服务与 MCP

在一个终端启动服务，在另一个终端调用。`--data-dir` 应当是独立、私有的应用数据目录：

```powershell
./target/debug/dansheng-host.exe --data-dir .local/demo-profile serve
./target/debug/dansheng-host.exe --data-dir .local/demo-profile call core.info
./target/debug/dansheng-host.exe --data-dir .local/demo-profile call plugins.list
./target/debug/dansheng-host.exe --data-dir .local/demo-profile mcp
```

只有服务持有数据库和调度器。客户端通过 Windows named pipe 或 Linux Unix socket 连接。MCP 使用单独的身份和令牌，初始没有业务数据权限；由可信 UI/管理 CLI 设置权限后，才能查询来源、调用插件、操作待办或调度任务。MCP 不能配置凭据、修改授权或信任插件发布者。

服务会在私有 profile 的 `host` 目录生成连接配置和令牌文件。不要把该目录放入仓库或诊断导出。详细协议与工具清单见 [Host 说明](crates/dansheng-host/README.md) 和 [业务服务](crates/dansheng-host/SERVICES.md)。

## 插件与权限

插件由 manifest、JavaScript ES modules 和静态资源组成。安装后默认禁用；更新和回滚也需要重新启用。声明能力不代表获得授权，实际 I/O 仍由宿主检查。

- `http.request` 允许请求；非安全 HTTP 方法还需要 `http.write`。浏览器写入同样需要 `browser.write`。
- 非 owner 调用者执行真实写入，还需要对应动作的 `execute:<plugin>:<action>` 授权。插件声明 `mutating:false` 不能绕过检查。
- UI、MCP 与插件共用账号和来源数据；账号、来源及数据类别权限始终生效。邮件内容的通用检索也需要 `mail.read`。
- 插件的实际能力、来源、域名及账号范围受到原始调用者授权限制；后台续接保留原始调用者身份。
- 插件私有 KV 按有效权限和账号范围隔离，避免低权限调用读出先前高权限调用的缓存。权限变化会改变可访问的缓存范围；旧数据保留以便受控迁移。
- 不确定的外部写入结果会保留为 `NeedsReconciliation`，不能通过取消、重启或自动重试消除。实际对账由可信宿主确认。

从 [HTTP monitor](plugins/examples/http-monitor) 或 [Canvas 示例](plugins/examples/canvas-courses) 开始。类型和完整宿主方法见 [SDK](sdk/README.md)。普通插件不提供 Node、任意文件系统、原始数据库或原生模块访问。

## 平台与业务边界

`fudan-sports` 保存场馆端点、场地顺序和抢场策略；通用 Core 不包含这些学校规则。Android 浏览器适配器在已认证页面内使用 fetch/XHR，保留页面的 WAF 行为。缺少浏览器能力时返回明确错误。真实身份验证、操作授权界面和文件选择由生产宿主接入，验证宿主只使用合成身份与离线页面。

Windows 使用 DPAPI 加密会话文件，Linux 使用 Secret Service，Android 使用 Keystore。HTTP 会话导入和“凭据已加载”不构成真实学校登录验证；认证失效仍需宿主完成重新登录。

参考代码固定在 [reference/manifest.json](reference/manifest.json)：DanXi 上游、Dela 上游和本地 DanXi 抢场提交分别记录。`reference` checkout 不参与构建，原有 `C:/Code/danxi` 不被修改。移植来源见连接器和插件各自的 NOTICE。

## 子任务协作

本项目的 worker 范围和复核规则见 [AGENTS.md](AGENTS.md)。`scripts/invoke-agy-worker.ps1` 固定 cwd、保存 conversation_id，并核对精确续接 ID。模型输出只是待复核结果，最终需要文件差异、编译和测试证据。

本机 agy 已通过新会话和精确续接验证。调度脚本默认采用 Windows 用户/机器级代理环境，避免继承 Codex 进程中不同的显式代理；可用 `-ProxyMode Inherit` 保留调用者代理。详情见 [agy 调度与网络验证](docs/agy-workers.md)。
