#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Workspace','Flutter','Native','Sdk','Android','AndroidSource','Release','Publish')][string]$Role)
. (Join-Path $PSScriptRoot 'Common.ps1')
$layout = Get-DanshengCiLayout
if ($IsWindows) {
    # Linux sources runner-env.sh before starting portable PowerShell.
    $entry = Join-Path $layout.root 'runner-env.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'Missing runner-env.ps1 in DANSHENG_CI_ROOT.' }
    . $entry
    if (-not $?) { throw 'Runner environment initialization failed.' }
}
if ((Assert-CiPlainPath $env:DANSHENG_CI_ROOT) -cne $layout.root) { throw 'Runner environment changed its CI root.' }
$workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\', '/')
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
foreach ($directory in @($layout.runtime, $layout.cache)) {
    if ($directory.Equals($workspace, $comparison) -or $directory.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, $comparison) -or $workspace.StartsWith($directory + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'CI runtime/cache and checkout must be separate directories.'
    }
}
if (Test-Path -LiteralPath $layout.runtime) { throw 'CI runtime already exists; rerun with a new attempt.' }
[void][IO.Directory]::CreateDirectory($layout.runtime)
[IO.File]::WriteAllText((Join-Path $layout.runtime '.ci-owned'), $layout.identity)
$env:DANSHENG_TASK_RUNTIME = $layout.runtime
$env:DANSHENG_CI_CACHE_ROOT = $layout.cache
$taskHome = Assert-CiPlainPath (Join-Path $layout.runtime 'home')
. (Join-Path $PSScriptRoot '../../apps/dansheng_app/scripts/build-parallelism.ps1')
$parallelism = Get-DanshengBuildParallelism
$cargoTarget = Get-DanshengCiCargoTarget $layout $Role
if (-not $cargoTarget.StartsWith($layout.runtime)) { Limit-DanshengCiBuildCache $cargoTarget 40GB }
$values = @{
    DANSHENG_CI_ROOT=$layout.root; DANSHENG_TASK_RUNTIME=$layout.runtime; DANSHENG_CI_CACHE_ROOT=$layout.cache
    DANSHENG_TASK_HOME=$taskHome
    CARGO_HOME=(Join-Path $layout.cache 'cargo-home'); CARGO_TARGET_DIR=$cargoTarget
    PUB_CACHE=(Join-Path $layout.cache 'pub'); GRADLE_USER_HOME=(Join-Path $layout.cache 'gradle')
    npm_config_cache=(Join-Path $layout.cache 'npm'); npm_config_userconfig=(Join-Path $layout.runtime 'home/.npmrc')
    GH_CONFIG_DIR=(Join-Path $layout.runtime 'home/gh')
    ANDROID_USER_HOME=(Join-Path $layout.runtime 'android-user'); ANDROID_AVD_HOME=(Join-Path $layout.runtime 'android-user/avds')
    DANSHENG_PROFILE=(Join-Path $layout.runtime 'profiles/core'); DANSHENG_LAB_PROFILE=(Join-Path $layout.runtime 'profiles/lab')
    DANSHENG_BROWSER_PROFILE=(Join-Path $layout.runtime 'profiles/browser')
    XDG_CONFIG_HOME=(Join-Path $layout.runtime 'home/config'); XDG_CACHE_HOME=(Join-Path $layout.cache 'xdg')
    XDG_DATA_HOME=(Join-Path $layout.runtime 'home/data'); XDG_STATE_HOME=(Join-Path $layout.runtime 'home/state')
    APPDATA=(Join-Path $layout.runtime 'home/appdata'); LOCALAPPDATA=(Join-Path $layout.runtime 'home/localappdata')
    TEMP=(Join-Path $layout.runtime 'tmp'); TMP=(Join-Path $layout.runtime 'tmp'); TMPDIR=(Join-Path $layout.runtime 'tmp')
    GIT_CONFIG_GLOBAL=(Join-Path $layout.runtime 'home/.gitconfig'); GIT_CONFIG_NOSYSTEM='1'; GIT_TERMINAL_PROMPT='0'
    CARGO_BUILD_JOBS=[string]$parallelism.cargo
    DANSHENG_GRADLE_WORKERS=[string]$parallelism.gradle
    CMAKE_BUILD_PARALLEL_LEVEL=[string]$parallelism.gradle
    GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.parallel=true -Dorg.gradle.workers.max=$($parallelism.gradle)"
    JAVA_TOOL_OPTIONS=('"-Duser.home={0}"' -f $taskHome.Replace('\','/'))
}
foreach ($name in $values.Keys) {
    [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process')
    if ($name -notin @('GIT_CONFIG_GLOBAL','npm_config_userconfig','GIT_CONFIG_NOSYSTEM','GIT_TERMINAL_PROMPT','GRADLE_OPTS','JAVA_TOOL_OPTIONS','CARGO_BUILD_JOBS','DANSHENG_GRADLE_WORKERS','CMAKE_BUILD_PARALLEL_LEVEL')) {
        [void][IO.Directory]::CreateDirectory((Assert-CiPlainPath $values[$name]))
    }
}
# Empty task-owned configuration; never import a developer's credentials/profile.
foreach ($name in @('GIT_CONFIG_GLOBAL','npm_config_userconfig')) { [IO.File]::WriteAllText($values[$name], '') }
# Drop source/SDK selections inherited from an interactive developer session.
$resetNames = @('DANSHENG_CORE_ROOT','DANSHENG_CORE_TOOLS_ROOT','DANSHENG_CORE_SDK_DIR','DANSHENG_CORE_LOCK_FILE','DANSHENG_WORKSPACE_ROOT','DANSHENG_BETA_STORE','DANSHENG_BETA_PASSWORD','JAVA_OPTS','JDK_JAVA_OPTIONS','_JAVA_OPTIONS')
foreach ($name in $resetNames) {
    [Environment]::SetEnvironmentVariable($name, $null)
    Add-Content -LiteralPath $env:GITHUB_ENV -Value "$name=" -Encoding utf8
}
if (-not $IsWindows) {
    Set-CiRuntimePermissions $layout
}
. (Join-Path $PSScriptRoot 'Public-Caches.ps1')
$seedKinds = switch ($Role) {
    { $_ -in @('Native','Android') } { 'Cargo' }
    'Flutter' { 'Pub' }
    { $_ -in @('AndroidSource','Release') } { 'Cargo'; 'Pub' }
}
if ($seedKinds) { Sync-CiPublicDependencies (Join-Path $layout.root 'cache') $layout.cache -Direction SeedToCache -SeedKinds @($seedKinds) }
# Preserve provisioned tool roots and native compiler settings across Actions steps.
$exportNames = @($values.Keys) + @('PATH','JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','GRADLE_HOME','RUSTUP_HOME','RUSTUP_TOOLCHAIN','DANSHENG_TOOLCHAIN_ROOT','LIBCLANG_PATH','RUSTC','RUSTDOC','RUSTFMT','PUB_HOSTED_URL','FLUTTER_STORAGE_BASE_URL')
$exportNames += @(Get-ChildItem Env: | Where-Object Name -match '^(CC_|CXX_|AR_|CARGO_TARGET_)' | Select-Object -ExpandProperty Name)
foreach ($name in $exportNames | Sort-Object -Unique) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -eq $value) { continue }
    if ($value -match '[\r\n]') { throw "Multiline CI environment value refused: $name" }
    if ($name -eq 'PATH') {
        # Actions prepends each path entry. Reverse file order to preserve the
        # entry script's tool precedence (CI Node 22 before global Node 24).
        $parts = @($value.Split([IO.Path]::PathSeparator) | Where-Object { $_ })
        [array]::Reverse($parts)
        foreach ($part in $parts) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $part -Encoding utf8 }
    } else { Add-Content -LiteralPath $env:GITHUB_ENV -Value "$name=$value" -Encoding utf8 }
}
# Preinstalled tools only. A version mismatch fails rather than installing tools.
function Check-Tool([string]$Command, [string[]]$Arguments, [string]$Pattern) {
    $output = @(& $Command @Arguments 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $output -notmatch $Pattern) { throw "Preinstalled $Command failed its pinned health check ($Pattern)." }
    Write-Host "$Command health check passed."
}
Check-Tool git @('--version') '^git version '
if ($Role -eq 'Sdk') {
    Check-Tool node @('--version') '^v22\.'
    Check-Tool npm @('--version') '^\d+\.'
}
if ($Role -in @('Native','Android','AndroidSource','Release')) {
    if (-not $env:RUSTUP_HOME -or -not $env:RUSTUP_TOOLCHAIN) { throw 'Runner environment must select the preinstalled Rust toolchain explicitly.' }
    Check-Tool rustc @('--version') '^rustc 1\.99\.1 '
    if ($Role -eq 'Native') {
        Check-Tool cargo @('fmt','--version') '^rustfmt '
        Check-Tool cargo @('clippy','--version') '^clippy '
        $hostPattern = if ($IsWindows) { '(?m)^host: x86_64-pc-windows-gnu\s*$' } else { '(?m)^host: x86_64-unknown-linux-gnu\s*$' }
        Check-Tool rustc @('-vV') $hostPattern
    }
}
if ($Role -in @('Flutter','AndroidSource','Release')) { Check-Tool flutter @('--version') '(?m)^Flutter 3\.47\.7\s' }
if ($Role -in @('Workspace','AndroidSource','Release')) { Check-Tool python @('--version') '^Python 3\.' }
if ($Role -in @('Android','AndroidSource','Release')) {
    if (-not $env:ANDROID_HOME -or -not $env:ANDROID_SDK_ROOT -or $env:ANDROID_HOME -cne $env:ANDROID_SDK_ROOT) { throw 'Select one preinstalled Android SDK in ANDROID_HOME and ANDROID_SDK_ROOT.' }
    $ndk = Join-Path $env:ANDROID_SDK_ROOT 'ndk/30.0.16138531'
    if (-not (Test-CiPinnedNdk (Get-Content -LiteralPath (Join-Path $ndk 'source.properties') -Raw))) { throw 'Pinned NDK 30 is missing.' }
    foreach ($name in @('ANDROID_NDK_HOME','ANDROID_NDK_ROOT','ANDROID_NDK_PATH','NDK_HOME')) {
        [Environment]::SetEnvironmentVariable($name, $ndk)
        Add-Content -LiteralPath $env:GITHUB_ENV -Value "$name=$ndk" -Encoding utf8
    }
    Check-Tool rustup @('target','list','--installed') '(?m)^aarch64-linux-android\s*$'
    Check-Tool rustup @('target','list','--installed') '(?m)^x86_64-linux-android\s*$'
}
if ($Role -in @('AndroidSource','Release')) {
    Check-Tool java @('-version') '(?m)(?:openjdk|java) version "21(?:\.|\")'
    $homePattern = '(?m)^\s*user\.home\s*=\s*' + [regex]::Escape($taskHome.Replace('\','/')) + '\s*$'
    Check-Tool java @('-XshowSettings:properties','-version') $homePattern
    if (-not $env:GRADLE_HOME) { throw 'Runner environment must supply preinstalled GRADLE_HOME.' }
    Check-Tool gradle @('--version') '(?m)^Gradle 9\.7\.1\s*$'
    foreach ($path in @('platforms/android-37.0/android.jar','build-tools/36.0.0/source.properties','build-tools/37.0.0/source.properties','cmdline-tools/latest/bin/sdkmanager','cmake/3.22.1/source.properties')) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:ANDROID_SDK_ROOT $path) -PathType Leaf)) { throw "Preinstalled Android tool missing: $path" }
    }
}
if ($Role -in @('Release','Publish')) { Check-Tool gh @('--version') '^gh version ' }
Write-Host "CI runtime prepared; $Role preinstalled tool health checks passed."
