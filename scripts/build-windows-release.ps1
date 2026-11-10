param(
    [string]$TargetDirectory,
    [string]$Receipt,
    [switch]$Independent
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/dev.ps1"
. "$PSScriptRoot/release-common.ps1"
if((& rustc --version) -notmatch '^rustc 1\.99\.1 '){throw 'Release requires the pinned Rust 1.99.1 toolchain'}
if($env:RUSTFLAGS -or $env:CARGO_ENCODED_RUSTFLAGS){throw 'Custom Rust flags are not accepted by the reproducible release script'}
if($env:CFLAGS -or $env:TARGET_CFLAGS -or $env:CFLAGS_x86_64_pc_windows_gnu -or [Environment]::GetEnvironmentVariable('CFLAGS_x86_64-pc-windows-gnu','Process')){throw 'Custom native compiler flags are not accepted by the reproducible release script'}
$ReleaseLinkerDirectory=Join-Path $DanshengMingw.FullName 'bin'
$ReleaseLinker=Join-Path $ReleaseLinkerDirectory 'ld.lld.exe'
if(-not(Test-Path -LiteralPath $ReleaseLinker)){throw 'The project LLVM MinGW linker is required for deterministic PE imports'}
$ReleaseLinkerVersion=& $ReleaseLinker --version
if(-not $TargetDirectory){$TargetDirectory=Join-Path $DanshengRoot 'target'}
if(-not $Receipt){$Receipt=Join-Path $DanshengRoot '.local/release-current/windows-receipt.json'}
$TargetDirectory=[IO.Path]::GetFullPath($TargetDirectory)
$ReleaseBoundary=[IO.Path]::GetFullPath($DanshengRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if(-not $TargetDirectory.StartsWith($ReleaseBoundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Build target must be inside the workspace'}
if($Independent -and (Test-Path -LiteralPath $TargetDirectory)){throw 'Independent validation requires a new, empty target path'}
$ReleaseBefore=Get-DanshengBuildSource -Root $DanshengRoot
$ReleaseSavedTarget=$env:CARGO_TARGET_DIR;$ReleaseSavedEpoch=$env:SOURCE_DATE_EPOCH;$ReleaseSavedJobs=$env:CARGO_BUILD_JOBS;$ReleaseSavedCFlags=$env:CFLAGS_x86_64_pc_windows_gnu;$ReleaseSavedFlagParsing=$env:CC_SHELL_ESCAPED_FLAGS
try {
    $env:CARGO_TARGET_DIR=$TargetDirectory;$env:SOURCE_DATE_EPOCH='0';$env:CARGO_BUILD_JOBS='2'
    $env:CFLAGS_x86_64_pc_windows_gnu=Get-DanshengNativePrefixFlags -TargetDirectory $TargetDirectory
    $env:CC_SHELL_ESCAPED_FLAGS='1'
    Push-Location -LiteralPath $DanshengRoot
    try {
        $ReleaseArgs=@('rustc','-p','dansheng-host','--bin','dansheng-host','--release','--features','dansheng-core/pdf','--locked','--','-C','link-arg=-Wl,--no-insert-timestamp','-C','link-arg=-fuse-ld=lld','-C',('link-arg=-B'+$ReleaseLinkerDirectory.Replace('\','/')+'/'))
        & cargo @ReleaseArgs
        if($LASTEXITCODE -ne 0){throw 'Windows release build failed'}
        $ReleaseBinary=Join-Path $TargetDirectory 'release/dansheng-host.exe'
        $ReleaseProof=Write-DanshengBuildReceipt -Root $DanshengRoot -Before $ReleaseBefore -Binary $ReleaseBinary -Target windows-x64 -Features @('services','dansheng-core/pdf') -Receipt $Receipt -BuildArguments $ReleaseArgs -LinkerVersion $ReleaseLinkerVersion
        [ordered]@{receipt=$Receipt;binary=$ReleaseBinary;sha256=$ReleaseProof.artifact_sha256;source_sha256=$ReleaseProof.source_sha256;independent_target=[bool]$Independent}|ConvertTo-Json
    } finally {Pop-Location}
} finally {$env:CARGO_TARGET_DIR=$ReleaseSavedTarget;$env:SOURCE_DATE_EPOCH=$ReleaseSavedEpoch;$env:CARGO_BUILD_JOBS=$ReleaseSavedJobs;$env:CFLAGS_x86_64_pc_windows_gnu=$ReleaseSavedCFlags;$env:CC_SHELL_ESCAPED_FLAGS=$ReleaseSavedFlagParsing}
