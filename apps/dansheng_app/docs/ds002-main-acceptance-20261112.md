# DS-002 App main 接收验证

2026-11-12。App 基线为 `e5ca0f33bfe6c7451cb10978baa4bd9a25a5bdc9`，工作树为 `D:/Worktrees/DS-002-devdrive-workflow/app`。App 和 Core 保持两个独立 Git 仓库；所有本轮构建、缓存、日志、SDK 和模拟器数据写入新的 D 盘运行目录。

## 相对于 main 的改进

- Core 依赖由 `core.lock.json` 记录准确提交、源码和 adapter 摘要、API/ABI、Pigeon/Pub 锁、AAR、实际 packaged native entry 以及公共资源。
- 构建与 APK 审计共用显式的 Core、工具、SDK、锁和工件参数。Core 源码与验证器分别选择，验证器必须属于同一 Git common directory。
- 原生 SDK 使用运行目录中的 Cargo/Gradle 目标和公共 Android 项目副本，避免改写 Core 源码或原 App 的 native 产物。环境变量在成功、不同继承环境及失败后恢复。
- 模拟器验证要求准确 ownership、独立 D 盘 AVD 和专用 ADB；SDK-only 资源有完整摘要校验。内部 beta 构建为显式选项，测试身份位于任务运行目录。
- APK 条目采用 ordinal 名称比较，允许 AAPT2 的大小写不同资源，同时拒绝真正重复的 ZIP 名称。
- 新增 App 源码 CI：固定 Flutter、校验 Pub 解算、手写 Dart 格式、静态分析、测试及 Pigeon 生成一致性。开发分支普通 push 不重复运行，PR 和 main push 执行检查。

使用同一 Dart 3.13.5 formatter 处理 main 基线后，63 个手写 Dart 文件与 DS-002 逐字节一致。页面、业务逻辑、测试语义和 Pigeon 协议没有新增功能差异；这部分改动是格式整理。两份生成绑定也与 Pigeon 29.1.1 的实际生成结果一致。

## 本轮 Core SDK

Core 来源为已经合入 Core main 的 `5ab13d93c39f8eb84a9208d40387b93c115fc8d9`。构建使用该提交的真实、干净 Git 工作树，Core 源码未改写。

| 身份 | 实际值 |
| --- | --- |
| App | 0.2.2+4；Flutter 3.47.7 / Dart 3.13.5 |
| Core / API / ABI | 0.1.0 / 1 / 1 |
| Pigeon | 29.1.1 |
| Core source SHA-256 | `5e482d26f6519f8199fecfae9fb5531d8e5cc5e7441ec3632e25bef6394b3590` |
| Android adapter SHA-256 | `77ec2d44d00fcb121d3b5b4856dcd67dc373c4f3bca004db84217faffee2c88c` |
| AAR SHA-256 | `6c956c05167b866c48b5a8e742d8ee86ea6d74adda42955273ba3c519dae9dec` |
| Packaged ARM64 SO SHA-256 | `d0b2db70b3ca84a18ff6d2b9cdf5b1b2f6ea2282d2a22d2fa151a36a12d3848a` |
| Packaged x86_64 SO SHA-256 | `9b39dd213dc5c4009dee25db3b4a6b88bca449c9429995a8b37b3d656d96f6c3` |
| 锁状态 | `development_snapshot`；packaged receipt 完整；7 项公共资源校验通过 |

ARM64 库实际完成 release 交叉编译，x86_64 库实际完成 debug 构建和符号处理，JNI/AAR 实际组装成功。没有已发布的不可变 SDK 获取位置，因此不将这份开发依赖声明为稳定发布 SDK。

## 实际验证

| 检查 | 结果 |
| --- | --- |
| 依赖路径与输出边界夹具 | 30 项通过 |
| Core 工具身份夹具 | 8 项通过 |
| APK 条目夹具 | 3 项通过 |
| 原生环境回归 | 3 项通过；24 个变量恢复；重复 AAR/锁字节一致；冲突副本保留并拒绝 |
| 锁定离线 Pub 解算 | 通过；`pubspec.lock` 字节未改变 |
| Dart 格式 | 63 个文件，0 个需修改 |
| Flutter analyze | 无诊断 |
| Flutter test | 133 项全部通过 |
| Pigeon 生成 | Dart/Kotlin 两份绑定字节一致 |
| PowerShell parser / Actionlint | 18 个脚本及 App CI 配置通过 |
| Android | debug APK、androidTest APK 构建成功；7 项 JVM 测试通过 |
| 产品 APK | 原生库/官方模块/许可载荷、16 KiB 对齐和签名核验通过 |
| API 36 x86_64 离线模拟器 | App 启动成功；设置页实际显示 `core.info` 的 API 1 / Core 0.1.0，验证 Dart → Pigeon → Kotlin → JNI → Rust |

模拟器在 App 启动前禁用网络，使用新的 D 盘 userdata 和专用 ADB；结束后该模拟器已关闭。此次没有使用私人账号/profile、学校服务或物理设备。androidTest APK 的编译与 JVM 测试、这次启动冒烟以及旧文档的完整 workbench 仪器验收是不同证据。

运行目录：`D:/Scratch/dansheng-app-ds002-main-20261112T215158Z`。源码验证使用与实际 Git 工作树逐字节对应的独立构建副本，保留工作树中的既有 ignored 数据。SDK 生产者和提交/合并对象始终是实际 Git 工作树，不将验证副本作为 Git 仓库。

详细收据与日志在该目录的 `source-validation.json`、`dart-change-classification.json`、`android-build-results.json`、`logs/native-environment-integration.json`、`logs/apk-payload-audit.json` 和 `ui-smoke-*/proof.json`。提交后的准确 App SHA 与本地 main 集成结果记录在仓库外的最终接收报告。App CI 配置已做静态验证；本轮不将未执行的 GitHub CI 称为通过。
