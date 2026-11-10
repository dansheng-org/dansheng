param([string]$CoreRoot = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dansheng'))
$ErrorActionPreference = 'Stop'
$CoreRoot = (Resolve-Path -LiteralPath $CoreRoot).Path
$app = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot)).Path
. (Join-Path $CoreRoot 'scripts/release-common.ps1')
. (Join-Path $PSScriptRoot 'adapter-source.ps1')
$adapterHash=Get-AdapterSourceHash $CoreRoot
$fingerprint = (Get-DanshengBuildSource -Root $CoreRoot).sha256
$jni = Join-Path $app '.local/native/jni'
$short = 'x86_64'
$staging = New-Item -ItemType Directory -Force -Path (Join-Path $jni $short)
$armDir = New-Item -ItemType Directory -Force -Path (Join-Path $jni 'arm64-v8a')
Push-Location $CoreRoot
try {
    # Build product-specific feature sets in separate caches, retaining the historical Core receipts.
    . ./scripts/android-env.ps1 -Architecture aarch64
    $env:CARGO_TARGET_DIR = Join-Path $app '.local/cargo-arm64'
    $env:SOURCE_DATE_EPOCH = '0'
    $env:CFLAGS_aarch64_linux_android = Get-DanshengNativePrefixFlags -TargetDirectory $env:CARGO_TARGET_DIR
    $env:CC_SHELL_ESCAPED_FLAGS = '1'
    cargo build -p dansheng-ffi --target aarch64-linux-android --release --features campus-webvpn --locked --offline -j 3
    if($LASTEXITCODE -ne 0){throw 'Rust ARM64 build failed'}
    $armSo = Join-Path $armDir.FullName 'libdansheng_ffi.so'
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'aarch64-linux-android/release/libdansheng_ffi.so') -Destination $armSo
    . ./scripts/android-env.ps1 -Architecture x86_64
    $env:CARGO_TARGET_DIR = Join-Path $app '.local/cargo-x86'
    cargo build -p dansheng-ffi --target x86_64-linux-android --features campus-webvpn --locked --offline -j 3
    if($LASTEXITCODE -ne 0){throw 'Rust x86_64 build failed'}
    $debug = Join-Path $env:CARGO_TARGET_DIR 'x86_64-linux-android/debug/libdansheng_ffi.so'
    $target = Join-Path $staging.FullName 'libdansheng_ffi.so'
    & (Join-Path $DanshengNdkRoot 'bin/llvm-strip.exe') --strip-debug -o $target $debug
    if($LASTEXITCODE -ne 0){throw 'Cannot stage emulator library'}
    ./platform/android/gradlew.ps1 '-PandroidAbis=arm64-v8a,x86_64' "-PrustJniDir=$($jni.Replace('\','/'))" :adapter:assembleRelease --offline --max-workers=2 --console=plain
    if($LASTEXITCODE -ne 0){throw 'Adapter build failed'}
    if((Get-DanshengBuildSource -Root $CoreRoot).sha256 -ne $fingerprint){throw 'Core inputs changed during build'}
    if((Get-AdapterSourceHash $CoreRoot) -ne $adapterHash){throw 'Adapter inputs changed during build'}
} finally { Pop-Location }
$aar = Join-Path $app '.local/native/dansheng-android-0.1.0.aar'
Copy-Item -LiteralPath (Join-Path $CoreRoot 'platform/android/adapter/build/outputs/aar/adapter-release.aar') -Destination $aar
$metadata = [ordered]@{version='0.1.0';core_source_sha256=$fingerprint;features=@('services','card-login','campus-webvpn');aar_sha256=(Get-FileHash $aar).Hash;arm64_sha256=(Get-FileHash $armSo).Hash;x86_64_sha256=(Get-FileHash $target).Hash}
$metadata.adapter_source_sha256=$adapterHash
$metadata | ConvertTo-Json | Set-Content (Join-Path $app '.local/native/receipt.json') -Encoding utf8
& (Join-Path $PSScriptRoot 'native-notices.ps1') -CoreRoot $CoreRoot -Destination (Join-Path $app '.local/native/legal')
Write-Output $aar
