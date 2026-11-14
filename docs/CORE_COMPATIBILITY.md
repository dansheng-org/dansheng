# Core 依赖与发布

## 同仓库源码与二进制依赖

`core/` 是 Rust 源码模块，`apps/dansheng_app/core.lock.json` 是 App 实际消费的 native SDK 清单。两者可处于不同时间点：迁移保留当前已核验 SDK 锁，绝不把旧二进制标为新 Core 编译结果。

当前继承 App 锁为 development_snapshot：Core `b21ba39c43038c88ecb3519a40c00997add6bcdf`，AAR SHA-256 `4ba974f1cb2b48e60c07d837b986f592dbc20c3704e9a365b56936f8be3cd466`。导入 Core main 为 `1501cc28e120f8a2dae9402d5d2de72629b33bad`，含后来 ecard 提交。锁以文件实际内容为准；SDK-only APK 不证明当前 Core main 的新增代码已编入。

## 两种明确构建模式

1. 源码联调：自动选择同一工作树 `core`，在新 runtime 构建 AAR，按真实源码/adapter 摘要生成 receipt 和 lock。Core 改动必须使用此模式验收；不能拿历史 SDK 替代。
2. SDK-only：按根 `.github/prerelease-sdk.json` 的不可变下载清单取得归档，核对传输摘要、锁定验证器、AAR/native entries/resources/Pub lock，再构建 App。此模式可用于纯 App/文档/目录迁移审阅。

```powershell
. ./scripts/Enter-Dansheng.ps1
# 公共 Cargo/Gradle 缓存已准备后，从真实源码构建并备份旧锁：
./apps/dansheng_app/scripts/prepare-native.ps1 -CoreRoot $env:DANSHENG_CORE_ROOT `
  -RuntimeRoot $env:DANSHENG_TASK_RUNTIME -UpdateLock
# 签名 ARM64 release 审阅：
./apps/dansheng_app/scripts/build-beta.ps1 -CoreRoot $env:DANSHENG_CORE_ROOT `
  -RuntimeRoot $env:DANSHENG_TASK_RUNTIME
```

锁/收据的 commit 必须是存在的提交；单仓库 commit 与 `core/` 内容身份同时记录。不能仅为目录迁移修改旧锁的 commit。稳定发布必须满足真实 committed inputs、不可变获取地址、资源完整性与 `-ForRelease` 门槛；development_snapshot 不是稳定依赖。

Core 的 ABI/API 与 App/Pigeon 通道各自有版本边界。模块可独立版本及 tag（新发布采用 `core/v...`、`app/v...` 命名，旧 tag 原样保留），整套发布记录同仓库 SHA 与各产物 SHA。回滚使用匹配的 App+SDK+数据兼容组合。

现有自动 Pre-release 流程保留原始 SDK 获取与签名校验。正式发布/远程迁移另行授权。历史详细记录见 [App 原生兼容档案](../apps/dansheng_app/docs/CORE_COMPATIBILITY.md) 与 [Core version contract](../core/contracts/VERSIONING.md)。
