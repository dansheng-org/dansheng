param([string]$TargetDirectory,[string]$Receipt,[switch]$Independent,[string]$RuntimeRoot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/release-common.ps1"
$DanshengRoot=Split-Path -Parent $PSScriptRoot
$ReleaseRuntime=Resolve-DanshengRuntimeRoot -Root $DanshengRoot -RuntimeRoot $RuntimeRoot
if(-not $TargetDirectory){$TargetDirectory=if($env:CARGO_TARGET_DIR){$env:CARGO_TARGET_DIR}else{Join-Path $ReleaseRuntime 'cargo-target'}}
if(-not $Receipt){$Receipt=Join-Path $ReleaseRuntime 'android-current/arm64-receipt.json'}
$TargetDirectory=Get-DanshengRuntimeOutput -RuntimeRoot $ReleaseRuntime -Path $TargetDirectory
$Receipt=Get-DanshengRuntimeOutput -RuntimeRoot $ReleaseRuntime -Path $Receipt
if($Independent -and (Test-Path -LiteralPath $TargetDirectory)){throw 'Independent validation requires a new, empty target path'}
. "$PSScriptRoot/android-env.ps1" -Architecture aarch64
if((& rustc --version) -notmatch '^rustc 1\.99\.1 '){throw 'Release requires the pinned Rust 1.99.1 toolchain'}
if($env:RUSTFLAGS -or $env:CARGO_ENCODED_RUSTFLAGS){throw 'Custom Rust flags are not accepted by the reproducible release script'}
if($env:CFLAGS -or $env:TARGET_CFLAGS -or $env:CFLAGS_aarch64_linux_android -or [Environment]::GetEnvironmentVariable('CFLAGS_aarch64-linux-android','Process')){throw 'Custom native compiler flags are not accepted by the reproducible release script'}
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
        $ReleaseProof=Write-DanshengBuildReceipt -Root $DanshengRoot -Before $ReleaseBefore -Binary $ReleaseBinary -Target android-arm64 -Features @('services') -Receipt $Receipt -BuildArguments $ReleaseArgs -LinkerVersion $ReleaseLinkerVersion -RuntimeRoot $ReleaseRuntime
        [ordered]@{receipt=$Receipt;binary=$ReleaseBinary;sha256=$ReleaseProof.artifact_sha256;source_sha256=$ReleaseProof.source_sha256;independent_target=[bool]$Independent}|ConvertTo-Json
    } finally {Pop-Location}
} finally {$env:CARGO_TARGET_DIR=$ReleaseSavedTarget;$env:SOURCE_DATE_EPOCH=$ReleaseSavedEpoch;$env:CARGO_BUILD_JOBS=$ReleaseSavedJobs;$env:CFLAGS_aarch64_linux_android=$ReleaseSavedCFlags;$env:CC_SHELL_ESCAPED_FLAGS=$ReleaseSavedFlagParsing}
