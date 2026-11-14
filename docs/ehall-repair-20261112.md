# eHall 修复与验证（2026-11-12）

## 来源与工作树

- App：`C:/Users/ASCENDER/orca/workspaces/dansheng-app/ehall`，`feat/ehall`，基线 `1ffa1325c6b30ee2189563bf3ec92c1517bc94bb`。
- 经本轮单独授权的 Core：`C:/Users/ASCENDER/orca/workspaces/dansheng-core/ehall-card`，`DANSHENG/ehall-card`，基线 `b21ba39c43038c88ecb3519a40c00997add6bcdf`。
- 用户确认的只读旦夕来源：`D:/Code/danxi`，本地 `1.5.3+350`，`f6a4532d6ae080950b6dcc5e87f6b9331d1a0b41`。本轮使用的场馆 Dart 文件没有工作区差异；未将它称为已查询远程的最新发布。
- 两侧修改均未暂存、提交、推送或合并。Core 修复属于未提交源码快照，并非该基线提交已包含的修复。

## 行为

首页各服务卡片只有一行标题、图标和箭头，点击直接进入详情。首页不查询校园服务，也不在卡片内展开余额、空位和场次。

校园卡故障在同一账号下实际复现：余额成功，明细先返回 `ecard transactions.columns`。学校交易表现在有七列，而旧解析器只接受四列；继续验证又发现学校时间只有时分。Core 同时兼容四／七列和时分／时分秒，未知列结构继续拒绝，金额仍取原第四列。App 按 Core coverage 翻页，正确解开记录 envelope，以分显示金额、以校园时区显示时间，切换账号重置页码。

场馆对照 `sports_reservation_page.dart`、`sports_reservation_venue_page.dart`、`sports_reservation_center_page.dart`、`sports_reserve_repository.dart` 和 `sports_sniper_runner.dart`：

| 流程 | 本轮行为 |
| --- | --- |
| 查找 | 场馆搜索、校区分类与排序、今日起 60 天日期选择 |
| 选择 | 最多三个时段；每时段按点选顺序排列场地；已开始的时段不可选；刷新保留仍有效的选择，换日期／场馆清空选择 |
| 手动预约 | 一次原生确认包含所有候选；逐时段、逐场地尝试；每时段成功一次即停止该时段；已有预约时停止整个计划；拥挤响应等待一秒再尝试下一场地 |
| 原生边界 | 每个实际候选仍由 Core 生成 canonical input、审批摘要、mutation key 与持久化日志，保留 WebView／WAF 会话；没有将体育请求替换成普通 HTTP |
| 不确定结果 | 停止后续写入并读回待核对任务；保留既有跨手动／定时入口的防重复写入边界；本轮没有真实提交预约或取消 |
| 记录 | 预约详情、取消资格与取消结果核对；识别 Core 的 `reconciled_cancelled`；凭证使用同一体育 Cookie 存储的受限 WebView 打开 |
| 定时 | 沿用独立 `official.fudan-sports` 插件的已存在执行器和权限流程；配置页接收全部时段及场地优先级，并提供任务中心入口。没有把未安装／未启用的插件伪装成可运行任务 |
| 账号／请求 | 账号世代和独立请求序号阻止旧账号、旧日期请求回写新页面 |

## 依赖与工件

固定 Flutter 3.47.7、Dart 3.13.5、Pigeon 29.1.1。`pubspec.lock` 和两份 Pigeon 生成绑定字节未改变。

`core.lock.json` 已更新为真实重建的开发快照：

- Core source SHA-256：`5c4c3a6e9476742e87a8b290a0db0e5abc17c0f05c896eef3c406960b6eae5ce`。
- AAR SHA-256：`d31eb83ed1533aadbdd8fb90040329221987f019e40249040d1bfbeaa3ac4184`。
- ARM64 与 x86_64 SDK 均已编译；7 项资源与实际 packaged native entry 校验通过。API／ABI 均为 1。
- 依赖状态仍是 `development_snapshot`，没有伪造发布地址或稳定发布验证。

全部任务缓存、SDK、日志、私有测试 profile、模拟器 userdata 和工件位于 `D:/Scratch/dansheng-ehall-20261112`。没有借用原账号 profile 或原签名身份；凭据只读使用用户指定的文件，未进入源码、测试夹具或诊断输出。

## 本轮实际验证

| 层次 | 命令／证据 | 观察结果 |
| --- | --- | --- |
| App 源码 | `scripts/check-format.ps1`、`flutter analyze --no-pub`、`flutter test --no-pub` | 格式通过、无诊断、118 项测试通过 |
| 绑定 | `dart run pigeon --input pigeons/dansheng.dart` 前后比对 | 两份绑定和 Pub 锁字节不变 |
| Core | `cargo fmt --all --check`；`cargo test -p dansheng-connectors --locked --offline --all-features --test campus` | 29 项通过，覆盖旧表格、新七列表格和分钟精度 |
| Android 编译 | `prepare-native.ps1`、`package-workbench.ps1 -UsePreparedNative`、只读 runner 单独构建 | ARM64／x86_64 SDK、x86_64 debug APK、两种 test APK 成功 |
| Android JVM | `:app:testDebugUnitTest` | 12 项通过，其中 5 项验证优先级、逐时段成功、已有预约停止、拥挤退避、不确定写入停止和账号变化 |
| APK | payload 审计、`zipalign -c -P 16 4`、`apksigner verify` | 原生载荷、对齐、签名通过 |
| 离线模拟器 | `verify-ui-runtime.ps1 -Apply -KeepAlive`，专用 API 36 AVD／ADB | 首页实际为一行入口；设置中的动态 core.info 验证 Dart → Pigeon → Kotlin → JNI → Rust |
| Windows 真实只读 | 本轮源码重建的 host 与专用 profile | 余额、明细成功；另外验证无记录日期窗口正常返回零条 |
| Android 真实只读 | `CampusReadOnlyRunner`，专用 AVD，单次 nonce 配对传入凭据 | 首次及重启后校园卡明细均成功，读到 10 条；场馆身份核验成功，25 个场馆及场次可读，静默登录未显示网页 |
| 热重载 | 同一专用模拟器上的 Flutter machine `app.restart(fullRestart:false)` | 返回 `code:0`，完成 reassemble，无源码变化时 reload 0 libraries |

最终 x86_64 debug APK：`artifacts/dansheng-android-x86_64-debug.apk`，SHA-256 `af17036790486be2c36ca99510bac25fb36128c1585b0274313e78b42fc78a11`。这是模拟器调试包；没有物理设备执行或 ARM64 设备运行结果。

运行目录中 `logs/app.diff`、`logs/core.diff`、`logs/flutter-tests-final.log`、`logs/core-campus-tests.log`、`logs/android-readonly.json`、`logs/audit-debug.json`、`logs/core-dependency-final.json`、`logs/hot-reload.json` 及 `ui-smoke-*/proof.json` 保存本轮证据。源码更改见 Git diff；新增文件由最终清单逐一记录。已有历史验收文档保持原状。没有待批准的提交／合并／部署操作。
