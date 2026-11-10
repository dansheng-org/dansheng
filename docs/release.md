# 开发版构建与归档

发布目录包含 Windows x64 Host、Android ARM64 C ABI 核心库和对应源码归档。它们不包含生产 UI、Node、Flutter、Chromium 或真实 profile；Android ZIP 不是 APK。Android 实机行为不能由交叉编译推定。

构建输入固定为 `Cargo.lock`、Rust 1.99.1、项目的 GNU Windows 工具链和 Android NDK 30.0.16138531。以下脚本只修改当前进程的构建环境，不改用户或系统环境变量。

```powershell
./scripts/verify-windows-rebuild.ps1
./scripts/build-android-release.ps1
# ARM64 还需要另一独立输出目录的匹配 receipt，见下文。
./scripts/package.ps1
./scripts/verify-package.ps1
```

Windows 使用 GNU GCC/MSVCRT 编译环境和项目 LLVM LLD 链接器，PE 时间戳设为零；两平台都使用 `SOURCE_DATE_EPOCH=0`，并用 C 编译器的 `-ffile-prefix-map` 将构建目录映射为 `/dansheng-build`，防止 QuickJS 的 `__FILE__` 嵌入不同 target 目录。带引号的原生参数通过 `CC_SHELL_ESCAPED_FLAGS=1` 解析。脚本拒绝额外 Rust/C flags，避免未记录的构建配置。

MinGW 的 DLL 导入表布局还可能随输入库的路径排序改变。因此 Windows 字节一致性验证固定**编译时路径**：`verify-windows-rebuild.ps1` 保留第一份完整 release 缓存到 `.local/windows-reproduction/`，确认原 `target/release` 已不存在，再从空 release 缓存重建。两份实际文件位于不同目录，第二次不共享编译产物；debug 工具及所有 profile 不移动。它验证这一明确的工具链和路径布局，不宣称任意输出路径的 PE 一定相同，也不会修改二进制字节来制造一致。

下载的依赖源可复用。Android 可在另一个输出目录构建并比较：

```powershell
./scripts/build-android-release.ps1 -Independent `
  -TargetDirectory C:/Code/dansheng/.local/build-arm64/repro-independent `
  -Receipt C:/Code/dansheng/.local/android-current/arm64-independent-final-receipt.json
```

`-Independent` 要求目标目录尚不存在，不会删除已有缓存。对已存在的独立目录进行后续增量构建时需省略该开关，并将结果如实记为增量验证。不要把同一缓存命中的构建当成两次独立编译；是否得到相同二进制 SHA-256 以实际比较结果为准。

## 来源绑定

构建前后都对 Rust crate 源文件、Cargo manifests/锁文件、工具链声明和 C 头文件计算指纹。仅在输入未变、输出架构正确时写入 build receipt。打包时再次检查当前输入和二进制 SHA-256；旧产物不能配上当前源码清单。

默认 receipts 位于忽略的 `.local/release-current/windows-receipt.json` 和 `.local/android-current/arm64-receipt.json`，不会作为私人路径配置打入二进制包。打包还要求对应的 `windows-independent.json` / `arm64-independent-final-receipt.json`：二进制路径须不同，哈希必须相同；不匹配则不发布新目录。包内 `build-info.json` 保存编译器、特性、命令参数和产物哈希；`binary-source-manifest.sha256` 标识二进制构建输入，`source-manifest.sha256` 标识完整源码归档。两者口径不同：后者还包含文档、SDK、测试和平台适配源文件。

## 确定性归档与回退

归档按 ordinal 路径顺序写入，ZIP 时间统一为 1980-01-01，外部属性固定。修改源文件 mtime 不改变相同内容的归档。归档实现所用 .NET 版本记录在元数据中；不同工具链/压缩库版本的字节一致性不能凭此推定。

打包在 `dist` 内新建 staging 目录，校验输入没有在归档期间变化后才切换目录。旧发布目录保留为 `dist/.previous-*`，失败的 staging 可供排查；脚本不自动递归删除旧发布。ZIP 只包含明确的文件清单，不会夹带旧目录里的未知文件。

产物路径为 `dist/dansheng-core-0.1.0/`：

- `dansheng-core-0.1.0-windows-x64.zip`
- `dansheng-core-0.1.0-android-arm64.zip`
- `dansheng-core-0.1.0-source.zip`
- `SHA256SUMS`、构建/源码清单与许可声明

`verify-package.ps1` 读取实际 ZIP，核对全部源码文件哈希、二进制哈希、必需元数据和许可证，拒绝额外运行时文件、私有/生成目录或不固定的 ZIP 时间。只校验归档不等于运行测试；对应平台执行记录仍以 [验证记录](validation.md) 为准。

重复打包可以指定另一个 `dist` 子目录，再比较三份 ZIP 的哈希：

```powershell
./scripts/package.ps1 -OutputDirectory C:/Code/dansheng/dist/repro-package
./scripts/verify-package.ps1 -Directory C:/Code/dansheng/dist/repro-package
```

两轮期间源码、文档、依赖许可文本和 receipts 必须保持一致。源码有意改变时，应重新构建并获取新的 receipt；不应编辑 receipt 绕过来源校验。
