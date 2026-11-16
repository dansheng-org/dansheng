#Requires -Version 7.0
# Synthetic environment and fake formatter only; no runner registration or credentials.
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng ci tests ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$saved = @{}
Get-ChildItem Env: | ForEach-Object { $saved[$_.Name] = $_.Value }
$inheritedSystemHome = [Environment]::GetEnvironmentVariable('HOME')
$inheritedUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected rejection: $Pattern; got: $message"
}
try {
    $env:CARGO_BUILD_JOBS = '32'
    $env:DANSHENG_GRADLE_WORKERS = '16'
    # A runner's checkout may live beneath CI_ROOT; only runtime/cache must be separate.
    $env:DANSHENG_CI_ROOT = Join-Path $fixture 'ci'
    $env:GITHUB_WORKSPACE = Join-Path $env:DANSHENG_CI_ROOT 'runner/_work/checkout'
    [void][IO.Directory]::CreateDirectory($env:GITHUB_WORKSPACE)
    $env:GITHUB_RUN_ID = '12345'; $env:GITHUB_RUN_ATTEMPT = '1'; $env:GITHUB_JOB = 'publish'
    $env:GITHUB_REF = 'refs/heads/main'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
    $env:GITHUB_ENV = Join-Path $fixture 'actions-env'; $env:GITHUB_PATH = Join-Path $fixture 'actions-path'
    [IO.File]::WriteAllText((Join-Path $env:DANSHENG_CI_ROOT 'runner-env.ps1'), '# Synthetic test environment; intentionally no tool installs.')
    function global:git { 'git version 2.50.0'; $global:LASTEXITCODE = 0 }
    function global:gh { 'gh version 2.80.0'; $global:LASTEXITCODE = 0 }
    $env:JAVA_OPTS = '-Duser.home=inherited-config'
    $env:JDK_JAVA_OPTIONS = '-Duser.home=inherited-config'
    $env:_JAVA_OPTIONS = '-Duser.home=inherited-config'
    & (Join-Path $scripts 'Initialize-Runner.ps1') -Role Publish
    $runtime = $env:DANSHENG_TASK_RUNTIME
    Assert ($env:CARGO_BUILD_JOBS -eq '32' -and $env:DANSHENG_GRADLE_WORKERS -eq '16') 'Runner discarded its concurrency budget.'
    Assert ($env:GRADLE_OPTS -match '-Dorg.gradle.workers.max=16' -and $env:GRADLE_OPTS -match '-Dorg.gradle.parallel=true') 'Gradle did not receive parallel worker settings.'
    Assert ((Get-Content -LiteralPath $env:GITHUB_ENV -Raw) -match '(?m)^CARGO_BUILD_JOBS=32\s*$') 'Cargo concurrency was not exported to later Actions steps.'
    Assert ($runtime -eq (Join-Path $env:DANSHENG_CI_ROOT 'runtime/12345/publish/1')) 'Runtime lost run/job/attempt isolation.'
    Assert ($env:CARGO_TARGET_DIR.StartsWith($runtime)) 'Cargo build outputs escaped runtime.'
    Assert ($env:CARGO_HOME -eq (Join-Path $env:DANSHENG_CI_ROOT 'cache/main/publish/cargo-home')) 'Dependency cache is not persistent and CI-owned.'
    Assert ($env:DANSHENG_PROFILE.StartsWith($runtime) -and $env:DANSHENG_TASK_HOME -eq (Join-Path $runtime 'home')) 'Inherited a shared profile.'
    Assert ([Environment]::GetEnvironmentVariable('HOME') -ceq $inheritedSystemHome) 'Initialization changed the system HOME variable.'
    Assert ([Environment]::GetEnvironmentVariable('USERPROFILE') -ceq $inheritedUserProfile) 'Initialization changed USERPROFILE.'
    Assert ((Get-Content -LiteralPath $env:GITHUB_ENV -Raw) -notmatch '(?m)^(HOME|USERPROFILE)=') 'System home variables were exported as task settings.'
    Assert (-not $env:JAVA_OPTS -and -not $env:JDK_JAVA_OPTIONS -and -not $env:_JAVA_OPTIONS) 'Inherited Java options can override task user.home.'
    Assert ($env:JAVA_TOOL_OPTIONS -ceq ('"-Duser.home={0}"' -f $env:DANSHENG_TASK_HOME.Replace('\','/'))) 'Java user.home is not explicitly isolated.'
    foreach ($name in @('GH_CONFIG_DIR','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_STATE_HOME','ANDROID_USER_HOME','npm_config_userconfig','GIT_CONFIG_GLOBAL','DANSHENG_LAB_PROFILE','DANSHENG_BROWSER_PROFILE')) {
        Assert ([Environment]::GetEnvironmentVariable($name).StartsWith($runtime)) "Explicit task isolation lost: $name"
    }
    # Use a real installed JVM if available, without printing properties/paths.
    $java = Get-Command java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($java) {
        $properties = @(& $java.Source -XshowSettings:properties -version 2>&1) -join "`n"
        $javaExit = $LASTEXITCODE
        $javaHomePattern = '(?m)^\s*user\.home\s*=\s*' + [regex]::Escape($env:DANSHENG_TASK_HOME.Replace('\','/')) + '\s*$'
        Assert ($javaExit -eq 0 -and $properties -match $javaHomePattern) 'Actual JVM did not isolate user.home (including path spaces).'
    }
    . (Join-Path $scripts 'Common.ps1')
    $ndkProperties = "Pkg.Desc = Android NDK`nPkg.Revision = 30.0.16138531-beta3`nPkg.BaseRevision = 30.0.16138531`nPkg.ReleaseName = r30-beta3`n"
    Assert (Test-CiPinnedNdk $ndkProperties) 'Rejected the pinned official r30-beta3 metadata.'
    Assert (Test-CiPinnedNdk 'Pkg.Revision = 30.0.16138531') 'Rejected the pinned base revision.'
    Assert (-not (Test-CiPinnedNdk ($ndkProperties.Replace('30.0.16138531-beta3','30.0.16138530-beta3')))) 'Accepted a different NDK build.'
    Assert (-not (Test-CiPinnedNdk 'Pkg.Revision = 30.0.16138531-beta4')) 'Accepted a different NDK prerelease.'
    $global:ciPermissionCalls = [Collections.Generic.List[object]]::new()
    function global:chmod { $global:ciPermissionCalls.Add(@($args)); $global:LASTEXITCODE = 0 }
    $layout = Get-DanshengCiLayout
    # Build outputs: kept per lane/job/OS for checks; releases build from empty.
    function Same([string]$a, [string]$b) { [IO.Path]::GetFullPath($a) -eq [IO.Path]::GetFullPath($b) }
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $keptRoot = Join-Path $env:DANSHENG_CI_ROOT 'build-cache'
    foreach ($role in @('Release', 'Publish')) {
        Assert ((Get-DanshengCiCargoTarget $layout $role).StartsWith($runtime)) "$role build outputs left the per-run runtime."
    }
    foreach ($role in @('Native', 'Android', 'AndroidSource')) {
        $target = Get-DanshengCiCargoTarget $layout $role
        Assert (Same $target (Join-Path $keptRoot "main/publish-$os/cargo-target")) "$role lost its kept main-lane build directory."
        Assert (-not $target.StartsWith((Join-Path $env:DANSHENG_CI_ROOT 'cache'))) 'Compiled outputs entered a dependency cache.'
    }
    $savedRef = $env:GITHUB_REF; $savedEvent = $env:GITHUB_EVENT_NAME
    try {
        $env:GITHUB_REF = 'refs/pull/7/merge'; $env:GITHUB_EVENT_NAME = 'pull_request'
        $checksTarget = Get-DanshengCiCargoTarget (Get-DanshengCiLayout) 'Native'
        Assert (Same $checksTarget (Join-Path $keptRoot "checks/publish-$os/cargo-target")) 'Pull requests share build outputs with main.'
    } finally { $env:GITHUB_REF = $savedRef; $env:GITHUB_EVENT_NAME = $savedEvent }
    # This Publish-role initialization must not hand a kept Android root to anything.
    Assert (-not $env:DANSHENG_CI_NATIVE_TARGET_ROOT) 'A release-side role inherited kept Android outputs.'
    Assert ((Get-Content -LiteralPath $env:GITHUB_ENV -Raw) -match '(?m)^DANSHENG_CI_NATIVE_TARGET_ROOT=\s*$') 'Kept Android output root was not reset for later steps.'
    $kept = Join-Path $fixture 'kept-target'
    [void][IO.Directory]::CreateDirectory($kept)
    [IO.File]::WriteAllBytes((Join-Path $kept 'artifact.bin'), [byte[]]::new(4096))
    Limit-DanshengCiBuildCache $kept 1MB
    Assert (Test-Path -LiteralPath (Join-Path $kept 'artifact.bin')) 'A kept build directory under budget was removed.'
    Limit-DanshengCiBuildCache $kept 1KB
    Assert (-not (Test-Path -LiteralPath $kept)) 'A kept build directory over budget was not started over.'
    Set-CiRuntimePermissions $layout
    Assert ($global:ciPermissionCalls.Count -eq 1) 'Runtime permissions helper did not run.'
    Assert (($global:ciPermissionCalls[0] -join '|') -ceq (@('700',$runtime,(Join-Path $runtime 'home')) -join '|')) 'chmod can affect a non-runtime directory.'
    $env:DANSHENG_TASK_HOME = $fixture
    Reject { Set-CiRuntimePermissions $layout } 'runtime task home'
    Assert ($global:ciPermissionCalls.Count -eq 1) 'Rejected chmod still changed directory permissions.'
    $env:DANSHENG_TASK_HOME = Join-Path $runtime 'home'
    Assert ((Get-Content -LiteralPath $env:GITHUB_ENV -Raw) -match 'DANSHENG_CI_CACHE_ROOT=') 'Actions environment was not exported.'
    $pathLines = @(Get-Content -LiteralPath $env:GITHUB_PATH)
    $expectedFirstPath = @($env:PATH.Split([IO.Path]::PathSeparator) | Where-Object { $_ })[0]
    Assert ($pathLines[-1] -eq $expectedFirstPath) 'Actions prepend order would select a global tool before the CI tool.'
    Assert ($env:GH_CONFIG_DIR.StartsWith($runtime)) 'Inherited GitHub CLI authentication profile.'
    Reject { & (Join-Path $scripts 'Initialize-Runner.ps1') -Role Publish } 'already exists'
    # Only dummy bytes are used, and the signing path is owned by this fixture.
    $env:KEYSTORE = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic signing bytes, not a key'))
    $env:KEYSTORE_PASSWORD = 'synthetic fixture password'
    & (Join-Path $scripts 'Write-Signing.ps1')
    $key = Join-Path $runtime 'signing/prerelease.p12'
    Assert (Test-Path -LiteralPath $key) 'Temporary signing file missing.'
    $env:DANSHENG_TASK_RUNTIME = $fixture
    Reject { & (Join-Path $scripts 'Clear-Signing.ps1') } 'exact CI run/job/attempt'
    Assert (Test-Path -LiteralPath $key) 'Rejected cleanup deleted signing data.'
    $env:DANSHENG_TASK_RUNTIME = $runtime
    [IO.File]::WriteAllText((Join-Path $runtime 'keep-evidence.txt'), 'preserve')
    & (Join-Path $scripts 'Clear-Signing.ps1')
    Assert (-not (Test-Path -LiteralPath (Join-Path $runtime 'signing'))) 'Signing cleanup did not run.'
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'keep-evidence.txt')) 'Cleanup deleted non-signing evidence.'
    . (Join-Path $scripts 'Common.ps1')
    $env:GITHUB_REF = 'refs/pull/1/merge'; $env:GITHUB_EVENT_NAME = 'pull_request'
    Assert ((Get-DanshengCiLayout).cache -eq (Join-Path $env:DANSHENG_CI_ROOT 'cache/checks/publish')) 'PR cache overlaps main cache.'
    $env:GITHUB_JOB = '../../outside'
    Reject { Get-DanshengCiLayout } 'identities'
    $env:GITHUB_JOB = 'publish'; $env:GITHUB_RUN_ATTEMPT = '2'
    Assert ((Get-DanshengCiLayout).runtime -ne $runtime) 'Rerun reuses prior attempt outputs.'

    # Exercise the cmd.exe-sensitive formatter boundary with 65 source paths and one generated file.
    $app = Join-Path $fixture 'app with spaces'
    foreach ($directory in @('lib','test','pigeons')) { [void][IO.Directory]::CreateDirectory((Join-Path $app $directory)) }
    foreach ($number in 1..65) { [IO.File]::WriteAllText((Join-Path $app "lib/long source name $number.dart"), 'void main() {}') }
    [IO.File]::WriteAllText((Join-Path $app 'lib/bridge.g.dart'), 'generated, must not format')
    $global:ciFormatCalls = [Collections.Generic.List[object]]::new()
    function global:dart { $global:ciFormatCalls.Add(@($args)); $global:LASTEXITCODE = 0 }
    & (Join-Path $scripts 'Check-Format.ps1') -AppRoot $app
    Assert ($global:ciFormatCalls.Count -eq 3) 'Formatter did not split 65 files into three batches.'
    $seen = @()
    foreach ($call in $global:ciFormatCalls) {
        $paths = @($call | Select-Object -Skip 3)
        Assert ($paths.Count -le 32) 'Formatter exceeded 32 paths.'
        foreach ($path in $paths) { Assert (-not [IO.Path]::IsPathFullyQualified($path)) 'Formatter received an absolute path.' }
        $seen += $paths
    }
    Assert ($seen.Count -eq 65 -and 'lib/bridge.g.dart' -cnotin $seen) 'Formatter changed exclusions or lost a file.'
    function global:dart { $global:LASTEXITCODE = 1 }
    Reject { & (Join-Path $scripts 'Check-Format.ps1') -AppRoot $app } 'formatting failed'

    . (Join-Path $scripts 'Public-Caches.ps1')
    $publicCache = Join-Path $fixture 'public-cache'
    $publicRuntime = Join-Path $fixture 'public-runtime'
    function Put([string]$Path, [string]$Value) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        [IO.File]::WriteAllText($Path, $Value)
    }
    Put (Join-Path $publicCache 'cargo-home/registry/cache/example/crate-1.crate') 'immutable archive'
    Put (Join-Path $publicCache 'cargo-home/credentials.toml') 'synthetic config, must never copy'
    Put (Join-Path $publicCache 'gradle/gradle.properties') 'synthetic config, must never copy'
    Put (Join-Path $publicCache 'gradle/caches/modules-2/public.jar') 'public jar'
    Put (Join-Path $publicCache 'pub/hosted/example/source.dart') 'public Dart source'
    Sync-CiPublicDependencies $publicCache $publicRuntime -Direction CacheToRuntime
    Assert (Test-Path -LiteralPath (Join-Path $publicRuntime 'cargo-home/registry/cache/example/crate-1.crate')) 'Cargo dependency was not seeded.'
    Assert (Test-Path -LiteralPath (Join-Path $publicRuntime 'gradle-cache/caches/modules-2/public.jar')) 'Gradle cache/runtime layout mapping failed.'
    Assert (Test-Path -LiteralPath (Join-Path $publicRuntime 'pub-cache/hosted/example/source.dart')) 'Pub cache/runtime layout mapping failed.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $publicRuntime 'cargo-home/credentials.toml'))) 'Copied a credentials file.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $publicRuntime 'gradle-cache/gradle.properties'))) 'Copied user Gradle configuration.'
    Put (Join-Path $publicRuntime 'gradle-cache/caches/modules-2/public.jar') 'existing runtime jar'
    Sync-CiPublicDependencies $publicCache $publicRuntime -Direction CacheToRuntime
    Assert ([IO.File]::ReadAllText((Join-Path $publicRuntime 'gradle-cache/caches/modules-2/public.jar')) -eq 'existing runtime jar') 'Cache seed replaced existing task bytes.'
    Put (Join-Path $publicRuntime 'cargo-home/registry/cache/example/crate-2.crate') 'new immutable archive'
    Put (Join-Path $publicRuntime 'signing/prerelease.p12') 'synthetic signing bytes, must never cache'
    Put (Join-Path $publicRuntime 'cargo-target/debug/build.bin') 'synthetic output, must never cache'
    Sync-CiPublicDependencies $publicRuntime $publicCache -Direction RuntimeToCache
    Assert (Test-Path -LiteralPath (Join-Path $publicCache 'cargo-home/registry/cache/example/crate-2.crate')) 'New dependency was not persisted.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $publicCache 'signing'))) 'Signing data reached a public cache.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $publicCache 'cargo-target'))) 'Compiled outputs reached a public cache.'
    Reject { Sync-CiPublicDependencies $publicCache $publicCache -Direction CacheToRuntime } 'overlap'

    # Global public seeds live above lane/job caches. They are read-only inputs,
    # and only Cargo registry data and Pub hosted/hash trees may be imported.
    $seedRoot = Join-Path $env:DANSHENG_CI_ROOT 'cache'
    Put (Join-Path $seedRoot 'cargo-home/registry/cache/example/seed.crate') 'public seed archive'
    Put (Join-Path $seedRoot 'cargo-home/registry/index/example/config.json') 'public registry metadata'
    Put (Join-Path $seedRoot 'pub/hosted/example/seed.dart') 'public seed Dart'
    Put (Join-Path $seedRoot 'pub/hosted-hashes/example/seed.sha256') 'public package hash'
    $blockedSeedPaths = @('cargo-home/bin/cargo.exe','cargo-home/credentials.toml','cargo-home/config.toml','cargo-home/target/debug/program.exe','cargo-target/debug/program.exe','pub/credentials.json','pub/git/private/source.dart','gradle/caches/private.jar','profiles/session.json')
    foreach ($relative in $blockedSeedPaths) { Put (Join-Path $seedRoot $relative) 'synthetic forbidden seed' }
    foreach ($relative in @('cargo-home/registry/cache/example/credentials.toml','pub/hosted/example/config.toml','pub/hosted/example/.npmrc','pub/hosted/example/.git/config','pub/hosted/example/.ssh/id_rsa','pub/hosted/example/.dart_tool/cache.bin')) {
        Put (Join-Path $seedRoot $relative) 'synthetic forbidden nested config'
        $blockedSeedPaths += $relative
    }
    $seedHash = (Get-FileHash -LiteralPath (Join-Path $seedRoot 'pub/hosted/example/seed.dart')).Hash
    $newCache = Join-Path $seedRoot 'checks/fresh-job'
    Sync-CiPublicDependencies $seedRoot $newCache -Direction SeedToCache
    foreach ($relative in @('cargo-home/registry/cache/example/seed.crate','cargo-home/registry/index/example/config.json','pub/hosted/example/seed.dart','pub/hosted-hashes/example/seed.sha256')) {
        Assert (Test-Path -LiteralPath (Join-Path $newCache $relative)) 'Fresh job did not import an allowed public seed.'
    }
    foreach ($relative in $blockedSeedPaths) { Assert (-not (Test-Path -LiteralPath (Join-Path $newCache $relative))) 'Seed import copied forbidden tool/config/profile/output data.' }
    if ($IsWindows) {
        $outsideSeed = Join-Path $fixture 'outside-seed'
        Put (Join-Path $outsideSeed 'private.txt') 'synthetic outside data'
        $seedLink = Join-Path $seedRoot 'pub/hosted/linked'
        New-Item -ItemType Junction -Path $seedLink -Target $outsideSeed | Out-Null
        Sync-CiPublicDependencies $seedRoot $newCache -Direction SeedToCache
        Assert (-not (Test-Path -LiteralPath (Join-Path $newCache 'pub/hosted/linked'))) 'Seed import followed a directory link.'
    }
    Assert (-not (Test-Path -LiteralPath (Join-Path $newCache 'main'))) 'Seed import recursed into lane caches.'
    Put (Join-Path $newCache 'pub/hosted/example/seed.dart') 'preserve job dependency'
    Sync-CiPublicDependencies $seedRoot $newCache -Direction SeedToCache
    Assert ([IO.File]::ReadAllText((Join-Path $newCache 'pub/hosted/example/seed.dart')) -ceq 'preserve job dependency') 'Seed import overwrote a job cache.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $seedRoot 'pub/hosted/example/seed.dart')).Hash -ceq $seedHash) 'Job cache wrote back into global seed.'
    Reject { Sync-CiPublicDependencies $seedRoot (Join-Path $seedRoot 'cargo-home/registry/cache/nested') -Direction SeedToCache } 'trees overlap'
    $pubOnly = Join-Path $seedRoot 'checks/pub-only'
    Sync-CiPublicDependencies $seedRoot $pubOnly -Direction SeedToCache -SeedKinds Pub
    Assert ((Test-Path -LiteralPath (Join-Path $pubOnly 'pub/hosted/example/seed.dart')) -and -not (Test-Path -LiteralPath (Join-Path $pubOnly 'cargo-home'))) 'Pub-only job imported unrelated seeds.'
    $env:GITHUB_JOB = 'fresh-flutter'; $env:GITHUB_RUN_ATTEMPT = '3'
    $env:GITHUB_ENV = Join-Path $fixture 'fresh-actions-env'; $env:GITHUB_PATH = Join-Path $fixture 'fresh-actions-path'
    function global:flutter { 'Flutter 3.47.7 stable'; $global:LASTEXITCODE = 0 }
    & (Join-Path $scripts 'Initialize-Runner.ps1') -Role Flutter
    Assert (Test-Path -LiteralPath (Join-Path $env:PUB_CACHE 'hosted/example/seed.dart')) 'Initialization did not import public seed into a fresh lane/job cache.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:CARGO_HOME 'registry'))) 'Flutter initialization imported unrelated Cargo seeds.'
    Assert ([Environment]::GetEnvironmentVariable('HOME') -ceq $inheritedSystemHome -and [Environment]::GetEnvironmentVariable('USERPROFILE') -ceq $inheritedUserProfile) 'Fresh job changed system home variables.'
    Write-Host "CI wrapper fixtures passed: $checks assertions."
} finally {
    foreach ($name in @('git','gh','dart','chmod','flutter')) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction SilentlyContinue }
    foreach ($name in @('ciFormatCalls','ciPermissionCalls')) { Remove-Variable $name -Scope Global -ErrorAction SilentlyContinue }
    # PowerShell string conversion can turn $null into an empty environment
    # value on recent .NET; Git treats an empty GIT_CONFIG_GLOBAL as an override.
    $addedNames = @(Get-ChildItem Env: | Where-Object { -not $saved.ContainsKey($_.Name) } | Select-Object -ExpandProperty Name)
    foreach ($name in $addedNames) { Remove-Item -LiteralPath "Env:$name" }
    foreach ($name in $saved.Keys | Where-Object { $_ -notin @('HOME','USERPROFILE') }) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
$global:LASTEXITCODE = 0
