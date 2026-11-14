# D 盘 App 构建与验收

2026-11-10。主库位于 `D:/Code/dansheng-app`，当前源码工作树位于
`D:/Worktrees/DS-002-devdrive-workflow/app`；配对 Core 位于同任务的 `core`。
两个产品是独立 Git 仓库，本轮改动留在任务分支，原 main 与 C 原件保留。

运行目录为 `D:/Code/dansheng-workspace/local/runtime/DS-002-devdrive-workflow`：

- `native-sdk`：实际 AAR、JNI、收据和锁声明的公共 `resources`。
- `artifacts`：debug APK、内部 beta APK、androidTest APK 与外部插件包。
- `logs`：SDK、打包、APK 资源/原生库、签名和对齐检查结果。
- `signing/android-beta`：本任务自己的内部测试身份，原 C 签名文件保留原地。

锁与生产收据验证当前 AAR SHA-256
`0c0bcb12469dbd3cc66e7c26b8387f8da0e11214f59901e411a3163e74166e99`、实际 packaged SO、
Core 源码及 7 项公共模块/许可资源。当前状态是开发快照；稳定发布仍要求已接收源码与
不可变获取位置。路径改名后的新 SDK 使用真实摘要更新锁，并先备份旧锁。

`package-workbench.ps1 -UsePreparedNative -IncludeBeta` 已实际通过，133 项 Flutter 测试、
App analyze、7 项 JVM 测试、原生资源/16 KiB 对齐/签名检查通过。PowerShell APK 审计按
精确 ZIP 名称识别重名；AAPT2 的 `res/2F.xml` 与 `res/2f.xml` 可共存。
业务、Pigeon/原生绑定及 Pub 锁的 113 项冻结文件保持原字节。

详细日志位于 `D:/MigrationLogs/dansheng-devdrive-20261110T181357Z`。
实际运行证据由 `workflow-api36-workbench-result.json` 与
`workflow-api28-recovery-result.json` 给出，验证使用全新 D AVD 和独立 ADB，原手机、
C 凭据与旧 AVD/profile 保留。旧验收文档仍绑定其原来的源码与路径。

入口与参数见 [开发工作流](DEVELOPMENT_WORKFLOW.md)；ABI、SDK、版本规则由 Core 的
`contracts/VERSIONING.md` 负责。Flutter、Android SDK、JDK 和用户配置继续引用其实际
C 盘安装位置，开发缓存和任务数据使用 D 盘。
