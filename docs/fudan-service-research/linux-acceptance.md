# Linux 当前源码验收

验收日期：2026-11-09，最终日志独立核对截至20:14 UTC。本文记录冻结生产输入在已拥有的 WSL2 分发上的实际运行。最终Linux批次已通过：**499 passed、0 failed、1 ignored**；不沿用旧Connectors136项。Android执行、独立release构建和最终归档尚未因本Linux结果而接收。

## 环境与边界

核验的 `ownership.json` 与 HKCU Lxss 注册表一致：名称 `dansheng-validation-f294b1ec`，GUID `{d64c4f9e-74c2-4e3c-9030-23b231ad6ac2}`，install/base path 为 `C:/Code/dansheng/.local/linux-validation/20261106T192944Z-f294b1ec/distro`，版本 WSL2。启动前该分发停止，默认 GUID 指向它；没有其它分发。只按指定分发启动验证，没有重建、重启、注销或设置默认分发。

`scripts/verify-linux.ps1` 保留 HOME 原值。Cargo/Rustup/target 显式使用拥有的 `/opt/dansheng-validation-f294b1ec` 缓存；每批新建 `/opt/dansheng-validation-<8hex>`，TMP/XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_CACHE_HOME/XDG_RUNTIME_DIR 指向这批目录。非交互脚本禁用 profile/rc/BASH_ENV/ENV；清除继承的 D-Bus 地址，未连接真实桌面钥匙串。guest 运行数据存于上述分发 VHD，对应 Windows 的 `.local/linux-validation` 安全边界。

脚本 full 模式逐个运行 workspace 五个成员的 `cargo test --all-features --all-targets --locked --offline`，另有 fmt、workspace strict Clippy、FFI build/ELF/C 编译与真实 C ABI smoke。Lab 的 Linux 测试也实际执行；Windows cfg 的凭据测试不计入 Linux。任何依赖编译或仅被 Clippy 检查均不计作测试运行。

禁止内容没有进入源快照：reference、App 工程、用户数据、真实 credentials/profile、.git、.local、target、dist 和原始凭据包。只复制脚本允许的生产 Rust、测试、合成 fixtures、必要 workspace manifest、锁文件、头文件和插件源文件。本次仅可改验收脚本、本文及 `.local/linux-validation` 运行产物，未提交。

## 非最终批次

首批 `.local/linux-validation/20261109T192202Z-19d58ffd` 在父代理通知新增 Library 凭据 generation lease/IO 后授权复核之前已经启动。因此保留它的完整执行日志，但明确标为非最终，不作为当前最终生产源码验收。

该批 206 文件，捕获区间 `2026-11-09T19:22:14.0155719Z`–`19:22:22.1618736Z`；source-manifest SHA-256 `809cb89864d0b4ae43d3a40a9e9a2ae4ee79c93be8a23c2a04b2ebc5961e511d`；Cargo.lock SHA-256 `c3d86a57fc9df10886f6d8474db6551a39c94bdb1104e7a9763956e429954c75`。捕获后/执行前清单与逐文件哈希一致。标识文件 `non-final-batch.json` 记录父代理新增修复导致该批不是最终验收。运行末尾生产哈希检查如有 drift 将拒绝接受，不会自动修复或覆盖源码。

该批 native process exit=1，实际 Core 196、Connectors 267、Host 23、FFI 2、Lab 7 通过，共 **495 passed、1 failed、1 ignored**。Host 失败目标是 `mcp::tests::registered_service_surface_excludes_configuration_and_credential_presentation`，旧测试在 `mcp.rs:377` 将 `fudan.portal.bind` 判为只读查询。其失败后独立执行的 contract 6 项及 scheduler 10 项全部通过，没有将仅编译的目标计为测试。Connectors 唯一 ignored 是 `academic_programs::public_response_from_stdin`，标记为手工提供有界 stdin 公开响应的研究探针，不用于自动验收。

fmt、strict Clippy、FFI build/ELF/C 链接/native smoke、guest 206 项源哈希都通过。主机末尾检查发现 `bridge_bytes_tests.rs`、`core_adapter.rs`、`expanded_services.rs`、`page_transport.rs`、`tests/expanded_service_bridge.rs` 5 项变化，added=removed=0，因此明确拒绝作为最终验收。注册表及默认 GUID 完全不变。逐阶段码与计数保存在 `acceptance-summary-nonfinal.json`、`linux-results/results/stages.tsv`、`production-source-proof.json`；没有修改失败的 Rust 源码或重建环境。

## 最终批次

最终证据根为`C:/Code/dansheng/.local/linux-validation/20261109T194317Z-eb783bcf`，guest源码为`/opt/dansheng-validation-eb783bcf/source`。主线程原native session78333完成后，其`native-process-result.json`记录exit0、模式full、cache_reused=true、environment_retained=true；`result.txt`为failures=0。此文档worker仅读取既有日志并运行只读sha256sum，没有重新编译或执行测试，也没有读取真实凭据/profile。

### 实际测试数字，按当批原始日志重算

从五份`test-<crate>.log`各自的`test result:`汇总行计数；没有叠加console重复输出、先前批次或仅被编译的依赖。

| workspace成员 | passed | failed | ignored | 汇总行数/证据 |
| --- | ---: | ---: | ---: | --- |
| dansheng-core | 196 | 0 | 0 | 11；`linux-results/results/test-dansheng-core.log` |
| dansheng-connectors | 270 | 0 | 1 | 14；`test-dansheng-connectors.log` |
| dansheng-host | 24 | 0 | 0 | 4；`test-dansheng-host.log` |
| dansheng-ffi | 2 | 0 | 0 | 1；`test-dansheng-ffi.log` |
| dansheng-lab | 7 | 0 | 0 | 3；`test-dansheng-lab.log` |
| **合计** | **499** | **0** | **1** | **33个汇总行** |

唯一ignored为`academic_programs::public_response_from_stdin`，它需要手工提供有界stdin公开响应，不在自动离线套件中运行。此前组件手工公开解析另有独立记录，不能补算为本Linux500项。Windows为501/0/1，Host多1项、Lab多1项来自平台cfg差异；不混计为跨平台“共1000项”的同一套件。

`native-verify.sh` full模式确实逐个执行五个成员的`cargo test --all-features --all-targets --locked --offline`。当前连接器270项全部实跑，包括新catalog/programs/eHall/Canvas/library及来源桥接测试；旧136项没有沿用。

### 静态、ABI与源码身份

| 检查 | 当批实际结果 | 证据 |
| --- | --- | --- |
| workspace fmt | exit0 | `stages.tsv`的fmt；`fmt.log`空输出 |
| workspace all-features/all-targets严格Clippy | exit0 | `clippy.log`逐项检查五crate，结束成功；`stages.tsv`clippy0 |
| FFI构建/ELF/C链接 | 全部exit0 | `ffi-build.log`、`ffi-elf.log`、`ffi-link.log` |
| 原生C ABI实际运行 | exit0；`C ABI smoke passed` | `ffi-native.log`，不是仅编译 |
| guest源码校验 | 执行前206项OK，结束206项OK，FAILED=0 | `source-before.log`、`source-unchanged.log` |
| host捕获副本/当前源 | changed=added=removed=0 | `production-source-proof.json`；unchanged=true |
| Secret Service真实接入 | **本批未验证** | `secret-service-status.txt`明确NOT_VERIFIED；TestVault不代表真实keyring成功 |

冻结身份分两种口径：

- **66个生产Rust构建输入**：主线程`frozen-production-source.json` SHA256 **`fdbaeab6fda9ab71025830d32de05899b1310fd589aff79efc45069da97e5945`**。包含核心crate manifests/源文件、workspace lock/toolchain和C头，不代表完整源码归档。
- **206文件Linux执行快照**：`source-manifest.sha256`的SHA256 **`28e6aabb5ddef95258758e54aa3b002d3dbddd59adfde991098fc2fd7e2c6856`**；包括测试、合成fixtures和Lab等允许文件。捕获区间19:43:26.5128671–19:43:35.1249789 UTC，逐文件一致；不是原子文件系统快照。
- 本文档worker逐个核对Windows冻结清单与host的Linux`source/`副本，**66/66匹配、缺失0、hash差异0**；又在指定分发对guest真实66文件执行只读`/usr/bin/sha256sum`，按主清单ordinal顺序重建相同摘要，**guest66/66匹配，摘要同fdbaeab6…**。
- 同时只读调用`Get-DanshengBuildSource`核对当前workspace仍为66输入、同摘要。它没有编译、更新receipt或接触用户数据。文档变动不在此66输入内，最终完整源码归档仍需重新核验。

Cargo.lock为`c3d86a57fc9df10886f6d8474db6551a39c94bdb1104e7a9763956e429954c75`；Linux环境日志记录Ubuntu24.04.5、Rust/Cargo1.99.1、GNU C13.3.0、WSL2 x86_64、CARGO_BUILD_JOBS=2、RUST_TEST_THREADS=2。实际debug SO为x86-64 ELF，C smoke不是ARM64或最终release验收。

### 范围与环境保持

`registrations-after.json`与复用前登记记录一致：同分发名、GUID、WSL2、base path及默认GUID；没有新增/注销/重建或切换默认分发。guest使用已拥有的工具链/target缓存，环境保留。

本批Host contract/native scheduler和MCP surface回归实际运行；这不等同外部生产MCP客户端会话，也不证明复旦在线服务。真实校园请求只引用主线程独立脱敏报告，见[最终分层验证](final-validation.md)。本Linux接受范围是当前冻结代码的完整离线/原生测试、静态和ABI门槛，保留前述Secret Service、实时学校及其它平台边界。

真实学校服务、凭据登录、预约/取消/付款/发信、真实 Secret Service set/get/delete/restart、Android/Windows 运行及发布产物均不属于本次 Linux 验收。
