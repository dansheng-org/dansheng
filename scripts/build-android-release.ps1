param([string]$TargetDirectory,[string]$Receipt,[switch]$Independent)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/android-env.ps1" -Architecture aarch64
. "$PSScriptRoot/release-common.ps1"
if((& rustc --version) -notmatch '^rustc 1\.99\.1 '){throw 'Release requires the pinned Rust 1.99.1 toolchain'}
if($env:RUSTFLAGS -or $env:CARGO_ENCODED_RUSTFLAGS){throw 'Custom Rust flags are not accepted by the reproducible release script'}
if($env:CFLAGS -or $env:TARGET_CFLAGS -or $env:CFLAGS_aarch64_linux_android -or [Environment]::GetEnvironmentVariable('CFLAGS_aarch64-linux-android','Process')){throw 'Custom native compiler flags are not accepted by the reproducible release script'}
if(-not $TargetDirectory){$TargetDirectory=Join-Path $DanshengRoot '.local/build-arm64'}
if(-not $Receipt){$Receipt=Join-Path $DanshengRoot '.local/android-current/arm64-receipt.json'}
$TargetDirectory=[IO.Path]::GetFullPath($TargetDirectory)
$ReleaseBoundary=[IO.Path]::GetFullPath($DanshengRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if(-not $TargetDirectory.StartsWith($ReleaseBoundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Build target must be inside the workspace'}
if($Independent -and (Test-Path -LiteralPath $TargetDirectory)){throw 'Independent validation requires a new, empty target path'}
$ReleaseBefore=Get-DanshengBuildSource -Root $DanshengRoot
$ReleaseSavedTarget=$env:CARGO_TARGET_DIR;$ReleaseSavedEpoch=$env:SOURCE_DATE_EPOCH;$ReleaseSavedJobs=$env:CARGO_BUILD_JOBS;$ReleaseSavedCFlags=$env:CFLAGS_aarch64_linux_android;$ReleaseSavedFlagParsing=$env:CC_SHELL_ESCAPED_FLAGS
try {
    $env:CARGO_TARGET_DIR=$TargetDirectory;$env:SOURCE_DATE_EPOCH='0';$env:CARGO_BUILD_JOBS='2'
    $env:CFLAGS_aarch64_linux_android=Get-DanshengNativePrefixFlags -TargetDirectory $TargetDirectory
    $env:CC_SHELL_ESCAPED_FLAGS='1'
    Push-Location -LiteralPath $DanshengRoot
    try {
        $ReleaseArgs=@('build','-p','dansheng-ffi','--target','aarch64-linux-android','--release','--locked')
        & cargo @ReleaseArgs
        if($LASTEXITCODE -ne 0){throw 'Android ARM64 release build failed'}
        $ReleaseBinary=Join-Path $TargetDirectory 'aarch64-linux-android/release/libdansheng_ffi.so'
        $ReleaseLinkerVersion=& (Join-Path $DanshengNdkRoot 'bin/ld.lld.exe') --version
        $ReleaseProof=Write-DanshengBuildReceipt -Root $DanshengRoot -Before $ReleaseBefore -Binary $ReleaseBinary -Target android-arm64 -Features @('services') -Receipt $Receipt -BuildArguments $ReleaseArgs -LinkerVersion $ReleaseLinkerVersion
        [ordered]@{receipt=$Receipt;binary=$ReleaseBinary;sha256=$ReleaseProof.artifact_sha256;source_sha256=$ReleaseProof.source_sha256;independent_target=[bool]$Independent}|ConvertTo-Json
    } finally {Pop-Location}
} finally {$env:CARGO_TARGET_DIR=$ReleaseSavedTarget;$env:SOURCE_DATE_EPOCH=$ReleaseSavedEpoch;$env:CARGO_BUILD_JOBS=$ReleaseSavedJobs;$env:CFLAGS_aarch64_linux_android=$ReleaseSavedCFlags;$env:CC_SHELL_ESCAPED_FLAGS=$ReleaseSavedFlagParsing}
