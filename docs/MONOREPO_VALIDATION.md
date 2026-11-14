# 单仓库迁移验证（2026-11-14）

迁移工作树：`D:/worktree/dansheng-app/monorepo-migration`，分支 `migration/monorepo`。
runtime：`D:/DevCache/dansheng/runtime/8ec0917b285c`。

## 已观察结果

| 检查 | 结果 |
| --- | --- |
| Flutter 3.47.7 / Dart 3.13.5 | 命令实测符合要求 |
| Cargo 1.99.1 | 命令实测符合要求 |
| cargo fmt / test --workspace --all-features --all-targets --locked --offline | 格式通过；34 组共 512 通过、0 失败、1 忽略，退出码 0 |
| Pub enforce-lockfile、手写 Dart 格式 | 通过，锁未改变，75 文件无格式变化 |
| flutter analyze | No issues found |
| flutter test | 129 通过 |
| Pigeon 29.1.1 重新生成 | Dart/Kotlin 生成文件无差异 |
| App PowerShell 路径/依赖/归档/发布 fixtures | 69 断言通过 |
| Python audit 路径 fixtures | 2 通过 |
| 根 3 份 GitHub workflows actionlint | 通过；未执行远程 CI |
| Core monorepo fixtures | 20 通过，包含跨工作树拒绝、嵌套 repo 拒绝、commit-lock 后代约束 |
| Core 旧工作流、runtime、环境 fixtures | 43、20、6 通过 |
| Node runtime tests | 5 通过 |
| 根 Enter 资源隔离回归 | 7 通过：阻止写入主树/其他树，保留已选 SDK/runtime，拒绝其他 owner |
| Core 原目录与迁移目录源码身份 | 68 项输入摘要一致；adapter 摘要一致 |
| SDK-only | 真实镜像 hash、权威验证器、AAR/native/resources/Pub lock 验证通过 |
| 将旧 SDK 与当前模块源码强行配对 | 按预期拒绝 |
| ARM64 release APK | 构建、内容审计、zipalign -c -P 16 4、apksigner verify 均通过 |

首次审阅 APK：`artifacts/review/dansheng-0.2.4+6-arm64-prerelease.apk`（相对上述 runtime）。
SHA-256：`fdf738c886004dca699bc10e103e4ebe9f7fe1d1bbcefe0921df4882b2935ae0`。
版本 `0.2.4+6`，ABI ARM64；使用新建任务 review identity，未替换原签名。
构建时迁移规范尚在编辑，因此该包的 build-info 如实标记 dirty；后续冻结源码重建另用独立输出目录，保留本包。

冻结代码提交 `dc5e8f984de6d94a3e9d1031d970bf94b87ca9d0` 后已实际重建到 `artifacts/review-final/`，build-info 的 `app_worktree_dirty=false`。APK SHA-256 与上文一致，内容/签名/16 KiB 对齐再次通过。之后仅补充本迁移验证与目录收尾说明，没有改变该包对应的 App/Core 代码。

## 证据位置

- runtime `logs/flutter-analyze.log`、`logs/flutter-tests.log`、`logs/core-tests.log`、`logs/core-source-relocation.json`、`logs/final-actionlint.log`。
- runtime `artifacts/review/` 内 APK、build-info、SHA256SUMS、APK 审计、签名和对齐记录。
- `D:/Scratch/dansheng-monorepo-app-checks-20261114/evidence-20261114T075030Z`：App fixtures、SDK验证、lint 与源码快照。
- runtime `validation/core-modules-final-37dbb191b1c64329b4b7adb345ebc24d/result.json`：Core 20 项模块契约实测。

日志和私人 runtime 均不提交为源码。本轮没有执行新的模拟器、真实服务、物理设备测试，也没有推送或远程发布；旧记录不作为本轮这些层面的证据。SDK 明确是锁定的历史 development_snapshot，未将目录迁移称为新 native SDK 编译。
