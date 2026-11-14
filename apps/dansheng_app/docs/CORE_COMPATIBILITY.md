> 迁移前详细依赖与验收档案；当前规则见[统一兼容规范](../../../docs/CORE_COMPATIBILITY.md)。历史路径、SHA 和结果不改写为本轮结果。

# Core 原生 SDK 兼容性

## 当前锁定依赖

以 `core.lock.json` 为准：App `0.2.4+6`，Core commit
`b21ba39c43038c88ecb3519a40c00997add6bcdf`，AAR SHA-256
`4ba974f1cb2b48e60c07d837b986f592dbc20c3704e9a365b56936f8be3cd466`。
状态为 `development_snapshot`，`acquisition_uri=null`。Pre-release 使用
[独立下载清单](../../../.github/prerelease-sdk.json) 镜像这一组精确 SDK、资源与原始收据，
不会把它重新标记为 Core 稳定发布。首次镜像上传和签名配置见 [发布说明](PRERELEASE.md)。

App 的 SDK-only 发布路径调用锁定 Core 提交的权威验证器，不传源码根目录；验证 AAR、
实际 native entry、7 项资源和 Pub lock，再由现有 Gradle 边界复核。SDK 镜像携带从准确 Core
提交导出的两份权威工具，下载清单锁定其逐文件摘要；不替换 SDK 生产源码身份。
SDK ZIP 只允许明确列出的分发载荷，并额外锁定传输摘要。

## 历史接收与迁移

2026-11-12 的 DS-002 接收验证使用 Core `5ab13d93c39f8eb84a9208d40387b93c115fc8d9`，从真实 Git 工作树重建 SDK，并更新 `core.lock.json`。源码、AAR、打包原生库及本轮实际验证见 [main 接收记录](ds002-main-acceptance-20261112.md)。下文的迁移表格和旧 AAR 摘要保留为历史记录。

采用规范路线 B：Core 原生库/SDK + 精确 artifact lock。当前 Core 没有可供 App Git 依赖的 Dart package；本轮不引入 flutter_rust_bridge 或第三份接口权威源。

## 实际连接

`pigeons/dansheng.dart` → `lib/bridge.g.dart` / `android/app/src/main/kotlin/org/dansheng/app/Bridge.g.kt` → App Kotlin host → Core 的 JNI/AAR → `include/dansheng.h` C ABI 与 Rust。

AAR 包含 `libdansheng_android.so` 与 `libdansheng_ffi.so` 的 Android ABI 产物；官方手动场馆资源/许可证来自同一 Core 来源。App 不打入 Node、Chromium、外部定时插件或用户凭据。C header、JSON协议、插件 API/SDK由 Core 定义；App 的 Pigeon 文件是 App 平台通道，并不替代 Core 契约。

| 消费端/生产端 | 当前实际记录 | 验收状态 |
| --- | --- | --- |
| App | `0.2.2+4`；Flutter 3.47.7 / Dart 3.13.5 | 源码声明和历史记录，不代表 DS-001 远程 CI 或新设备验证 |
| Pigeon | pubspec.lock 固定 29.1.1 | Dart/Kotlin生成文件必须与此版本及输入一致 |
| Core / ABI / API | Core 0.1.0；C ABI 1；插件 manifest API 1 | 版本号与 ABI/API 号分开，不以相同数字推断兼容 |
| 保留的既存本地 AAR | 原 App `.local/native` 外层 AAR `a916840b…6c1fb`，Core source `8c79fd85…4e32` | 旧收据缺 packaged 摘要；原产物保持不动 |
| 迁移前 DS-001 AAR | 历史 task runtime `native-sdk-final`；外层 AAR `af3bbfa4…54c9`，Core source `ba160d52…ea4c`；旧锁保留于迁移记录 | commit=null、acquisition=null；历史 development snapshot，旧收据不改写 |
| D 盘 MainCore 新构建 AAR | 外层 AAR `cdae7474…79e3`，MainCore commit `ac3d047e…5774`，Core source `8c79fd85…4e32`；当前 `core.lock.json` 核对7项资源和2项实际打包 native entry | 原始 staging receipt 与独立 packaged receipt 均保留；development_snapshot、acquisition=null，未宣称发布 |
| packaged 与 staging SO | receipt 的 arm64/x86_64 staging 摘要可能不同于 AAR 内实际 entry | 生成新收据同时保存 packaged entry SHA；不把差异猜成已验证 strip 过程 |

## 单一锁定清单

`core.lock.json` 使用 Core 工具的 `dansheng-core-lock-v1/native-sdk` 格式，记录 Core版本/真实commit或development状态、source/adapter摘要、ABI/API、Pigeon/Pub锁、AAR与实际native entry、资源摘要及 acquisition。不要手填占位 SHA 或把 `main/latest` 当固定发布版本。

锁由 Core `tools/workspace/New-DanshengCoreLock.ps1` 生成，默认 dry-run；只有明确应用才 `-Apply`，且拒绝覆盖已有 lock。无提交时显式 `-AllowUnversioned`，结果为 `development_snapshot`，不称为发布。

本任务修正了 Core 的旧 MCP 测试分类，并在实际重建两种 ABI 的 SDK 后更新锁。
生产 MCP 过滤器、C ABI、Pigeon 绑定和 Dart/Kotlin 业务逻辑保持原行为；12项手写
Dart 差异仅由当前 formatter 产生，生成文件以固定 Pigeon 的逐字节一致性为准。

```powershell
# 在实际参数/产物已核对后，由可信主线程生成；此例不创建或发布产物。
& "$CoreTask/tools/workspace/New-DanshengCoreLock.ps1" `
  -CoreRoot $CoreTask -AppRoot $AppTask `
  -ReceiptFile '<真实 native receipt>' -AarPath '<真实 AAR>' `
  -Destination "$AppTask/core.lock.json" -AllowUnversioned
& "$CoreTask/tools/workspace/Test-DanshengCoreDependency.ps1" `
  -LockFile "$AppTask/core.lock.json" -ArtifactDirectory '<已准备的 SDK 目录>' `
  -CoreRoot $CoreTask -AppRoot $AppTask
```

`DANSHENG_CORE_SDK_DIR` 或显式 ArtifactDirectory 决定 SDK 根；默认使用记录的任务 runtime 下 `native-sdk`。原主目录 `.local/native` 只在显式选择后作为已核验输入使用。源码联调传 `-CoreRoot` / `DANSHENG_CORE_ROOT`；`-CoreToolsRoot` / `DANSHENG_CORE_TOOLS_ROOT` 独立选择包含权威验证器的 `tools/workspace`，必须与 SDK 源码属于同一 Git common directory。不会为了找到工具把 MainCore 的源码身份切换为另一工作树。正式 SDK 可将经校验资源放在 artifact directory 的 `resources/<Core相对路径>`，避免要求 App-only 任务复制 Core 源码。

`prepare-native.ps1` 在初始化任务 public Cargo cache 后才允许离线构建，输出 staging 与实际 packaged SO 摘要，生成真实新锁。锁已存在且 SDK 改变时，`-UpdateLock` 先在任务 logs 保留旧锁；旧收据和原产物不会被改成新构建身份。

SDK 同时携带已核验 lock 声明的公共模块与许可证，位于 `resources/<Core相对路径>`；
SDK-only 依赖核验无需另外访问源码目录。已有资源与 lock 不同会拒绝覆盖，应使用新
artifact directory。这里不复制账号、用户数据或 Core 的其他文件。

## 稳定发布与回滚

稳定验证使用 `Test-DanshengCoreDependency.ps1 -ForRelease`，必须有真实 Core commit、release状态、无凭据的不可变 acquisition、精确 AAR/native entry/resources及无本地 Pub override。当前两仓库的会话前 main 已有实际提交和 remote；DS-001 准备树及上表 SDK 仍是 development snapshot，不能把它们认证为稳定发布依赖。迁移后的新 SDK 必须由实际 D 盘 Core 构建并据其真实 receipt 重新锁定，不能修改旧 receipt 的身份。

每个 App 发布保存 App/Core 两侧commit、ABI/API、Pigeon/Rust/Flutter工具链及APK/AAR摘要。Core与App分别打不可变Tag；先Core接收/发布，再升级App lock并检查干净构建。源码改变后重新生成真实产物/receipt，不能编辑收据使旧包通过。

回滚为上一组 App+其锁定Core组合；数据/插件配置的兼容与迁移另验。仅回滚一侧二进制不保证数据可恢复。旧 validation、实验UI或单次设备结果不自动成为新组合的验收。
