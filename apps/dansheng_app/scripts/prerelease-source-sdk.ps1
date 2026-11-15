#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$Commit
)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $app '../..'))
$core = Join-Path $repo 'core'
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
. (Join-Path $PSScriptRoot 'prerelease-common.ps1')
Assert-DanshengPrereleaseCheckout -AppRoot $app -CoreRoot $core -Commit $Commit -RequireClean
$RuntimeRoot = Get-DanshengAppCheckedPath $RuntimeRoot
. (Join-Path $core 'scripts/runtime-common.ps1')
$RuntimeRoot = Resolve-DanshengRuntimeRoot -Root $core -RuntimeRoot $RuntimeRoot
$sdk = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path (Join-Path $RuntimeRoot 'native-sdk')
$lock = Join-Path $sdk 'core.lock.json'
if (Test-Path -LiteralPath $sdk) { throw 'Source SDK output already exists; choose a fresh runtime.' }
$saved = @{}
$names = @('DANSHENG_CORE_ROOT','DANSHENG_TASK_RUNTIME','CARGO_HOME','GRADLE_USER_HOME','GRADLE_HOME','ANDROID_USER_HOME')
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:DANSHENG_CORE_ROOT = $core
    $env:DANSHENG_TASK_RUNTIME = $RuntimeRoot
    $env:CARGO_HOME = Join-Path $RuntimeRoot 'cargo-home'
    $env:GRADLE_USER_HOME = Join-Path $RuntimeRoot 'gradle-cache'
    $env:ANDROID_USER_HOME = Join-Path $RuntimeRoot 'android-user'
    foreach ($dir in @($env:CARGO_HOME,$env:GRADLE_USER_HOME,$env:ANDROID_USER_HOME,(Join-Path $RuntimeRoot 'logs'))) {
        [void][IO.Directory]::CreateDirectory($dir)
    }
    # Bootstrap a fresh hosted runner before the existing offline producer runs.
    # Fetch all locked targets: native-notices also runs cargo metadata offline.
    Push-Location $core
    try {
        $rust = & rustc --version
        if ($LASTEXITCODE -ne 0 -or $rust -notmatch '^rustc 1\.99\.1 ') { throw 'Pinned Rust 1.99.1 is required.' }
        & cargo fetch --locked
        if ($LASTEXITCODE -ne 0) { throw 'Cannot populate the locked Cargo dependencies.' }
    } finally { Pop-Location }
    # Use a pinned installation, not Flutter's untracked generated wrapper.
    $gradleName = if ($IsWindows) { 'gradle.bat' } else { 'gradle' }
    $gradlePath = if ($env:GRADLE_HOME) { Join-Path $env:GRADLE_HOME "bin/$gradleName" } else {
        (Get-Command $gradleName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if (-not $gradlePath) { throw 'Install Gradle 9.7.1 on PATH or set GRADLE_HOME before building the source SDK.' }
    # Pass the host launcher explicitly; retain the common pinned-JAR validator.
    $launcher = Resolve-DanshengPrereleaseGradle -CommandPath $gradlePath
    $env:GRADLE_HOME = Split-Path -Parent (Split-Path -Parent $launcher)
    & $launcher --version
    if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the pinned Gradle distribution.' }
    $project = Join-Path $RuntimeRoot 'core-android-project'
    $inputs = @(& git --no-optional-locks -c core.quotepath=false -C $core ls-files --cached -- 'platform/android' 'include/dansheng.h')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate committed native build inputs.' }
    foreach ($inputPath in $inputs) {
        $from = Get-DanshengAppCheckedPath (Join-Path $core $inputPath)
        $to = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path (Join-Path $project $inputPath)
        if (Test-Path -LiteralPath $to) { throw 'Native warmup project already exists; choose a fresh runtime.' }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $to))
        [IO.File]::Copy($from, $to, $false)
    }
    # Resolve AGP/Kotlin/Android dependencies online in the runtime copy. This
    # warmup has no Rust payload and is never consumed as an SDK. prepare-native
    # subsequently builds both real Rust ABIs and the JNI adapter offline.
    & (Join-Path $project 'platform/android/gradlew.ps1') -GradleArguments @(':adapter:assembleRelease','--max-workers=2','--console=plain')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot populate the native Gradle dependencies.' }
    Assert-DanshengPrereleaseCheckout -AppRoot $app -CoreRoot $core -Commit $Commit -RequireClean
    & (Join-Path $PSScriptRoot 'prepare-native.ps1') -CoreRoot $core -CoreToolsRoot (Join-Path $core 'tools/workspace') `
        -RuntimeRoot $RuntimeRoot -ArtifactDirectory $sdk -LockFile $lock
    if ($LASTEXITCODE -ne 0) { throw 'Exact checkout SDK build failed.' }
    $null = Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot (Join-Path $core 'tools/workspace') -CoreRoot $core -LockFile $lock
    Assert-DanshengPrereleaseCheckout -AppRoot $app -CoreRoot $core -Commit $Commit -RequireClean
    [pscustomobject]@{ core_commit=$Commit; artifact_directory=$sdk; lock_file=$lock; source_mode='exact-checkout' } | ConvertTo-Json
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
