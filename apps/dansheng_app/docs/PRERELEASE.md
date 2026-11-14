# Android 自动 Pre-release

发布对象为 ARM64 的签名 Android release APK。Core 仍是 `core.lock.json` 声明的开发快照，
GitHub Release 始终标记 Pre-release，且不设为稳定 Latest。

## 自动流程

1. 推送 main 后，`App and Core checks` 完成格式、分析、测试、Pigeon 与脚本检查。
2. 仅该仓库 main 的 push 检查成功才触发 `Android Pre-release`；PR 和失败的检查不发布。
3. 按通过检查的准确 App SHA 检出，使用随 SDK 镜像提供、按 lock 的 Core SHA 导出的权威验证工具。
4. 使用当前仓库的 `GITHUB_TOKEN` 下载 `.github/prerelease-sdk.json` 固定的 Release ZIP，支持私有仓库；先核验传输 SHA-256，再核验 Core lock、
   AAR/native entry、资源、Pub lock、原始生产收据和许可证。SDK-only 消费不需要重编 Core。
5. 使用固定签名 Secrets 构建 ARM64 APK，运行载荷、ELF/ZIP 16 KiB 对齐和签名检查。
6. 保存 Actions artifact，再创建 draft、上传附件，最后发布 Pre-release。

也可在 Actions 的 `Android Pre-release` 页面对 main 执行 Run workflow；手动模式会再次运行
源码检查。流程不登录学校服务、不操作模拟器或物理设备。

标签格式为 `prerelease-v<version>-build.<build>-<App SHA 前12位>`。每个提交独立保留工件；
已存在的 Release 会使重跑停止，不移动标签、不覆盖附件。若发布结果不确定，先查询对应
Release/draft、目标 SHA 与附件摘要再处理，不能盲目重试。

## 首次启用

这些步骤会写入远程，需要仓库维护者授权。workflow/config 的存在不表示已完成上传、配置或远程执行。

### 1. SDK 快照镜像

当前清单对应 Core `b21ba39c43038c88ecb3519a40c00997add6bcdf` 的已有 SDK：

| 项目 | 值 |
| --- | --- |
| App 仓库镜像 tag | `sdk-snapshot-b21ba39c4303-4ba974f1cb2b` |
| ZIP | `core-sdk-b21ba39c4303-4ba974f1cb2b-tools.zip` |
| ZIP SHA-256 | `16431bf1ffbea0b6eed6d099c58220fb904404b76761a66c2266470f8b828126` |
| AAR SHA-256 | `4ba974f1cb2b48e60c07d837b986f592dbc20c3704e9a365b56936f8be3cd466` |

由 App 发布仓库镜像既存开发 SDK，不修改或发布 Core 仓库。ZIP 只包含 AAR、原始 receipt、
7 项锁定资源、两份许可文件和两份 Core 验证工具，不包含 staging 输出、账号、配置、缓存或签名。
验证工具由真实 Core commit 的 `git archive` 导出，文件摘要与 commit 记在下载清单中；调用前逐文件核验。
单仓库可保持私有；不把个人 GitHub 令牌存入 CI。旧 SDK 镜像仍按精确历史版本消费，源码位于本仓库 core/。

本地生成／验证使用：

```powershell
./scripts/prerelease-sdk.ps1 -Action Pack -Archive '<新的 ZIP 绝对路径>' `
  -ArtifactDirectory '<已验证 SDK>' -CoreToolsRoot '<锁定 Core 提交>/tools/workspace'
./scripts/prerelease-sdk.ps1 -Action Install -Archive '<ZIP 绝对路径>' `
  -ArtifactDirectory '<任务 runtime 下的全新 native-sdk 目录>' `
  -CoreToolsRoot '<任务 runtime 下的全新 native-sdk 目录>/validation-tools' -Sha256 '<生成后的实际 ZIP 摘要>'
```

初次将上述 ZIP 发布到清单指定的镜像 Pre-release；镜像说明应写明 Core SHA、source 摘要、
AAR/ZIP 摘要及 development_snapshot。它是 App 的开发依赖镜像，不是 Core 稳定版本。
更新 SDK 时先按正常流程生成新 lock，再生成新的镜像 tag/ZIP 和下载清单；保留所有旧镜像。

### 2. 专用签名 Secrets

在 App 仓库的 Settings → Secrets and variables → Actions 配置：

| Secret | 内容 |
| --- | --- |
| `DANSHENG_PRERELEASE_KEYSTORE_BASE64` | 专用 PKCS12 keystore 的 Base64，alias 必须为 `dansheng-beta` |
| `DANSHENG_PRERELEASE_KEYSTORE_PASSWORD` | 对应 store/key 密码 |

使用独立持久身份，后续自动版本沿用；没有 Secrets 时构建失败，不退回 debug 签名，也不会
每次重新生成身份。本地私钥与 DPAPI 密码文件保留在授权任务 runtime 的 signing 目录，
不进入源码、日志、Actions artifact 或 Release 附件。不覆盖旧 beta/生产签名。

新身份与设备上旧包的签名可能不同，首次切换不保证可覆盖安装。保持原设备数据与签名，
另行决定安装或迁移方式。

### 3. 接收工作流并执行

审阅、授权提交／推送并接收到 main 后，新的 main push 会走自动流程。也可对 main 手动执行。
自动建 tag/Release 使用仓库 `GITHUB_TOKEN`，只有 publish job 具有 `contents: write`。
构建 job 只读仓库，并使用任务独立的 Pub/Gradle/Android 用户目录。

## 工件与验证范围

Release 附件包括 APK、`SHA256SUMS`、`build-info.json`、`apk-audit.json`、`signature.txt`
和 `zipalign.txt`。构建信息记录 App/Core SHA、开发依赖状态、工具链和载荷摘要。
构建成功不等同于模拟器执行、真机行为或真实校园服务可用。

本地审阅可用 `build-prerelease.ps1 -RuntimeRoot <独立D盘目录> -ArtifactDirectory <该目录下SDK>`
加 `-CoreToolsRoot <准确Core工具>` 与 `-ReviewSigning`。该选项仅在本机创建／复用任务签名，
CI 禁止使用它。审阅工件标记源码是否存在未提交修改；CI 要求源码和锁不发生变化。

稳定版继续要求真实 Core release、不可变 acquisition 和 `-ForRelease` 验证，另行授权。
