# Linux 集成复验：直接插件任务原子领取修复

本批于 2026-11-07 UTC 捕获并在保留的 WSL2 中实际执行。**实际运行 204 passed、0 failed；Connectors 136 项按父授权和源码哈希沿用。实际数与沿用数分列，不是重新跑了 340 项。**

fmt、workspace all-features/all-targets 严格 clippy、FFI 构建及实际 C ABI smoke 均通过，native process exit 0。未重复 mail TLS/QR、vault 或额外 HTTP 补证，未读取真实 profile/Token。

## 冻结与哈希

证据根：.local/linux-validation/20261107T001921Z-eac732f2/。

| 项目 | 值 |
| --- | --- |
| 父生产 helper，57 文件 | 425318a872c96a78c39eaddb40e2a525160a92e2347863e8065a6aec92c1931d |
| helper 复核 | manifest 重算一致，复制后 57 项逐文件匹配 |
| 允许源码快照 | 150 文件，2026-11-07 00:19:25–00:19:29 UTC |
| source-manifest.sha256 的 SHA-256 | ce55a04c3ddf0acda0702a8bb7459ea5852a962f7f291734342f2c0e91c71b3e |
| Cargo.lock SHA-256 | c3d86a57fc9df10886f6d8474db6551a39c94bdb1104e7a9763956e429954c75 |
| 捕获后及结束时 drift | changed=0、added=0、removed=0 |
| 冻结副本完整性 | 全部逐文件哈希一致 |

生产 helper 相对 8071546c 批仅变化 Core engine.rs / store.rs；新 core/tests/immediate_plugin_jobs.rs 六 case 及最新 Lab control-only rooms/canvas 脱敏诊断源码/测试均已捕获。helper 的生产范围与完整源码快照范围不同，不能直接比较两个清单哈希。

材料：parent-final-source-freeze.json、source-identity-proof.json、source-manifest.sha256、snapshot.json、source/、source.tar。完整接收结果为 acceptance-summary.json，逐例结果为 feature-execution.json。

## 本轮实际运行

| crate / 检查 | 实际结果 | 日志，相对证据根 |
| --- | --- | --- |
| Core all-features / all-targets | 178 passed，0 failed | linux-results/results/test-dansheng-core.log |
| Host all-features / all-targets | 24 passed，0 failed | linux-results/results/test-dansheng-host.log |
| FFI all-features / all-targets | 2 passed，0 failed | linux-results/results/test-dansheng-ffi.log |
| **实际测试合计** | **204 passed，0 failed，0 ignored** | acceptance-summary.json |
| workspace strict clippy，all-features / all-targets / -D warnings | exit 0，包含当前 Lab src/tests 的 Linux cfg 检查 | linux-results/results/clippy.log |
| fmt --all -- --check | exit 0 | linux-results/results/fmt.log |
| FFI .so 构建 / ELF / C 链接 / 实际 smoke | 全部 exit 0 | linux-results/results/ffi-build.log、ffi-elf.log、ffi-link.log、ffi-native.log |
| native process / 源码检查 | exit 0 / 全部一致 | native-process-result.json、linux-results/results/source-unchanged.log |

immediate_plugin_jobs 六 case 全部实际通过：预先原子保留、tick 不抢占、重复不重执行、取消后保持不确定状态不重放、执行前重查原调用者权限、未来计划去重及不同 action 碰撞拒绝。它们已计入 Core 178，不额外叠加。

实际 C smoke 加载 Linux x86-64 ELF 并完成 core open/request/close。debug 共享库位于保留缓存 target/debug/libdansheng_ffi.so，本批 SHA-256 为 291ce6c2aa530de186b56b395fe0dc5212e053586c20f6ac97f97d8c347e951a；证据为 native-abi-evidence.log。这是 Linux 实际运行，不是 Android/Windows 执行或最终 Release 刷新。

## Connectors 沿用，未重跑

| 项目 | 沿用结果 / 依据 |
| --- | --- |
| 已运行基线 | .local/linux-validation/20261106T221416Z-f68aa4d9/ |
| 基线 Connectors | 136 passed，0 failed |
| 源码比较 | 全部 60 个允许的 Connectors 源码、测试、fixtures、manifest/声明文件完全相同，增删改均为 0 |
| 本轮 Connectors 测试 | 未执行；没有重复 mail TLS/QR |
| 接受方式 | 按父授权和 Connector 源码身份沿用 |

Core 依赖在本轮确实改变，不能把该证明描述成整个依赖图未变。沿用范围和授权依据在 source-identity-proof.json / acceptance-summary.json 中明确记录。Connectors 库作为 Host/FFI 依赖及 clippy 对象被编译/检查，不等于重跑其测试。

当前分列覆盖为 **204 本轮实际 + 136 沿用 = 340 项**，不是本轮全跑 340，也不与旧 299、19 或 334 再次累加。

## 范围与保留

本轮通过 -CoreHostFfiOnly 模式执行，命令为分别对 core/host/ffi 的 cargo +1.99.1 test --all-features --all-targets --locked --offline，另有 workspace strict clippy、fmt、FFI build/C smoke。CARGO_BUILD_JOBS=2、RUST_TEST_THREADS=2，实际环境日志有记录。依赖编译不算其它 crate 测试运行。

继续复用 dansheng-validation-f294b1ec，注册 ID {d64c4f9e-74c2-4e3c-9030-23b231ad6ac2}；身份目录 .local/linux-validation/20261106T192944Z-f294b1ec/。本批 guest 源码目录 /opt/dansheng-validation-eac732f2，共用 Cargo/Rustup/target 为 /opt/dansheng-validation-f294b1ec。VHD/身份一致，缓存保留，没有重建、重启、注销或清理用户资源。

没有执行 Lab 运行时测试或真实 control diagnostics；仅 Linux clippy 包含最新 Lab 源码及测试配置。父侧 Windows 8 测试和真实 Android native 结果独立记录，不混入本轮。

没有读取真实 profile/Token、LOCALAPPDATA 下 lab profile/vault 或 C:/Code/danxi/reference。只写 scripts/verify-linux.ps1、本文及 .local/linux-validation/，未改 Rust/其它 docs/依赖锁文件，未 commit。所有运行数据均为合成 fixture/临时测试目录。

fixture package 的源码存在仍不是两端同包执行证明；父侧 normalizedHash 匹配和最终 Release 刷新另行记录。上一版报告归档于本轮 previous-validation-report.md，旧批日志原样保留。

## 复现

新的同范围冻结批可使用：

当前任务从 D 盘工作树运行，新的 snapshot/日志写到任务 runtime 的 `linux-validation`。
下面 `$environment` 是 2026-11-06 留存环境的证据位置；不将旧 C 路径改成新的编译来源。
是否执行或修改该留存发行版仍需对应授权，不因目录迁移自动重建或注销它。

~~~powershell
# This is a retained 2026-11-06 environment/evidence directory, not a new output path.
$environment = 'C:/Code/dansheng/.local/linux-validation/20261106T192944Z-f294b1ec'
pwsh -NoProfile -File ./scripts/verify-linux.ps1 -RuntimeRoot $env:DANSHENG_TASK_RUNTIME -ExecuteNative -CoreHostFfiOnly -KeepDistribution -EnvironmentDirectory $environment
~~~

亦可先 -PrepareSnapshot，再指定新的 -SnapshotDirectory；已执行快照拒绝覆盖。日志总流为 native-console.log，分阶段退出码为 linux-results/results/stages.tsv。

