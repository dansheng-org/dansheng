#Requires -Version 7.0
# Only synthetic markers, directories and Git repositories; never initialize or inspect a real runner.
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$cleanup = Join-Path $scripts 'Clear-Runtime.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng runtime cleanup ' + [guid]::NewGuid().ToString('N'))
$names = @('DANSHENG_CI_ROOT', 'DANSHENG_TASK_RUNTIME', 'GITHUB_RUN_ID',
    'GITHUB_JOB', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REF', 'GITHUB_EVENT_NAME', 'GITHUB_WORKSPACE')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$inheritedSystemHome = [Environment]::GetEnvironmentVariable('HOME')
$inheritedUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
$checks = 0
$links = [Collections.Generic.List[string]]::new()

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Put([string]$Path, [string]$Value = 'synthetic bytes') {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Value)
}
function Link([string]$Path, [string]$Target) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
    $script:links.Add($Path)
}
function Unlink([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [void]$script:links.Remove($Path)
}
function Seed {
    Put (Join-Path $runtime '.ci-owned') '987654/synthetic-job/2'
    foreach ($path in @('cargo-target/debug/output.bin', 'gradle-cache/caches/modules-2/dep.jar',
        'native-sdk/receipt.json', 'signing/prerelease.p12', 'home/gh/hosts.yml', 'tmp/scratch')) {
        Put (Join-Path $runtime $path)
    }
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected rejection: $Pattern; got: $message"
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'gradle-cache/caches/modules-2/dep.jar')) 'Rejected cleanup deleted runtime data.'
}
function Age([string]$Path, [double]$Hours) {
    $stamp = [DateTime]::UtcNow.AddHours(-$Hours)
    $marker = Join-Path $Path '.ci-owned'
    if (Test-Path -LiteralPath $marker) { [IO.File]::SetLastWriteTimeUtc($marker, $stamp) }
    [IO.Directory]::SetLastWriteTimeUtc($Path, $stamp)
}

try {
    $env:DANSHENG_CI_ROOT = Join-Path $fixture 'ci'
    $env:GITHUB_RUN_ID = '987654'
    $env:GITHUB_JOB = 'synthetic-job'
    $env:GITHUB_RUN_ATTEMPT = '2'
    $env:GITHUB_REF = 'refs/heads/main'
    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
    $runtime = Join-Path $env:DANSHENG_CI_ROOT 'runtime/987654/synthetic-job/2'
    $env:DANSHENG_TASK_RUNTIME = $runtime
    Seed
    $outside = Join-Path $fixture 'outside'
    Put (Join-Path $outside 'keep.bin')
    $preserved = @(
        (Join-Path $env:DANSHENG_CI_ROOT 'cache/main/synthetic-job/gradle/caches/dep.jar'),
        (Join-Path $env:DANSHENG_CI_ROOT 'build-cache/main/synthetic-job-linux/cargo-target/keep.bin'),
        (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987654/synthetic-job/1/cargo-target/keep.bin'),
        (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987654/other-job/2/cargo-target/keep.bin'),
        (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987653/synthetic-job/2/cargo-target/keep.bin'),
        (Join-Path $outside 'keep.bin')
    )
    foreach ($path in $preserved | Select-Object -SkipLast 1) { Put $path }
    $hashes = @{}
    foreach ($path in $preserved) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
    function Assert-Preserved {
        foreach ($path in $preserved) {
            Assert ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ceq $hashes[$path]) "Cleanup changed preserved bytes: $path"
        }
    }

    # The finished runtime is kept as the job's most recent one.
    Link (Join-Path $runtime 'tmp/linked-dir') $outside
    [IO.File]::CreateSymbolicLink((Join-Path $runtime 'tmp/linked-file'), (Join-Path $outside 'keep.bin')) | Out-Null
    [IO.File]::CreateSymbolicLink((Join-Path $runtime 'tmp/dangling'), (Join-Path $outside 'missing-file')) | Out-Null
    $readOnly = Join-Path $runtime 'home/readonly.bin'
    Put $readOnly
    [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)
    if (-not $IsWindows) { & chmod 555 (Join-Path $runtime 'home'); Assert ($LASTEXITCODE -eq 0) 'chmod fixture setup failed.' }
    $olderOnly = Join-Path $env:DANSHENG_CI_ROOT 'runtime/987650/synthetic-job/1'
    Put (Join-Path $olderOnly '.ci-owned') '987650/synthetic-job/1'; Put (Join-Path $olderOnly '.ci-finished') '987650/synthetic-job/1'
    $otherFinished = Join-Path $env:DANSHENG_CI_ROOT 'runtime/987650/other-job/1'
    Put (Join-Path $otherFinished '.ci-owned') '987650/other-job/1'; Put (Join-Path $otherFinished '.ci-finished') '987650/other-job/1'
    & $cleanup
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'gradle-cache/caches/modules-2/dep.jar')) 'Most recent runtime was not kept.'
    Assert ([IO.File]::ReadAllText((Join-Path $runtime '.ci-finished')) -ceq '987654/synthetic-job/2') 'Runtime was not marked finished.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987650/synthetic-job'))) 'Earlier finished runtime (and its empty job directory) was kept.'
    Assert (Test-Path -LiteralPath $otherFinished) "Another job's runtime was removed."
    Assert-Preserved
    & $cleanup # Re-running keeps its own runtime.
    Assert (Test-Path -LiteralPath (Join-Path $runtime '.ci-finished')) 'Repeated cleanup removed its own runtime.'

    # The next finished run supersedes it: links are removed, not followed; read-only entries go too.
    $nextRuntime = Join-Path $env:DANSHENG_CI_ROOT 'runtime/987655/synthetic-job/1'
    $env:GITHUB_RUN_ID = '987655'; $env:GITHUB_RUN_ATTEMPT = '1'; $env:DANSHENG_TASK_RUNTIME = $nextRuntime
    Put (Join-Path $nextRuntime '.ci-owned') '987655/synthetic-job/1'
    & $cleanup
    Assert (-not (Test-Path -LiteralPath $runtime)) 'Superseded runtime was kept.'
    Assert (Test-Path -LiteralPath (Join-Path $nextRuntime '.ci-finished')) 'Newest runtime was not kept.'
    Assert (Test-Path -LiteralPath (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987654/synthetic-job/1')) 'Unfinished (possibly running) attempt was removed.'
    Assert-Preserved
    [void]$links.Remove((Join-Path $runtime 'tmp/linked-dir'))
    Remove-Item -LiteralPath $nextRuntime -Recurse -Force
    & $cleanup # A missing runtime is an idempotent success.
    $env:GITHUB_RUN_ID = '987654'; $env:GITHUB_RUN_ATTEMPT = '2'; $env:DANSHENG_TASK_RUNTIME = $runtime
    Seed

    # Initialization failure must skip even when the layout environment is invalid.
    $env:DANSHENG_TASK_RUNTIME = ''
    $env:DANSHENG_CI_ROOT = 'relative-invalid'
    & $cleanup
    $env:DANSHENG_TASK_RUNTIME = $runtime
    Reject { & $cleanup } 'absolute'
    $env:DANSHENG_CI_ROOT = Join-Path $fixture 'ci'

    foreach ($identity in @('wrong', '987653/synthetic-job/2', '987654/other-job/2', '987654/synthetic-job/1')) {
        Put (Join-Path $runtime '.ci-owned') $identity
        Reject { & $cleanup } 'marker differs'
    }
    Remove-Item -LiteralPath (Join-Path $runtime '.ci-owned') -Force
    Reject { & $cleanup } 'marker differs'
    Seed
    $env:DANSHENG_TASK_RUNTIME = $outside
    Reject { & $cleanup } 'exact CI run/job/attempt'
    $env:DANSHENG_TASK_RUNTIME = 'relative-runtime'
    Reject { & $cleanup } 'absolute'
    $env:DANSHENG_TASK_RUNTIME = $runtime

    # A linked CI root ancestor or a linked marker fails before any deletion.
    $ancestorLink = Join-Path $fixture 'linked-ci'
    Link $ancestorLink $env:DANSHENG_CI_ROOT
    $env:DANSHENG_CI_ROOT = $ancestorLink
    $env:DANSHENG_TASK_RUNTIME = Join-Path $ancestorLink 'runtime/987654/synthetic-job/2'
    Reject { & $cleanup } 'links'
    $env:DANSHENG_CI_ROOT = Join-Path $fixture 'ci'
    $env:DANSHENG_TASK_RUNTIME = $runtime
    Unlink $ancestorLink
    $marker = Join-Path $runtime '.ci-owned'
    $externalMarker = Join-Path $outside 'marker'
    Put $externalMarker '987654/synthetic-job/2'
    Remove-Item -LiteralPath $marker -Force
    [IO.File]::CreateSymbolicLink($marker, $externalMarker) | Out-Null
    $links.Add($marker)
    Reject { & $cleanup } 'links'
    Unlink $marker
    Remove-Item -LiteralPath $externalMarker -Force
    Seed

    # Checkout cleanup is opt-in and removes only untracked/ignored build outputs.
    $checkout = Join-Path $fixture 'checkout'
    Put (Join-Path $checkout 'tracked.txt')
    Put (Join-Path $checkout '.gitignore') "build/`n"
    & git -C $checkout -c init.defaultBranch=main init -q
    & git -C $checkout -c user.name=fixture -c user.email=fixture@invalid add tracked.txt .gitignore
    & git -C $checkout -c user.name=fixture -c user.email=fixture@invalid commit -qm fixture
    Assert ($LASTEXITCODE -eq 0) 'Fixture checkout setup failed.'
    Put (Join-Path $checkout 'build/app/outputs/app-debug.apk')
    Put (Join-Path $checkout '.dart_tool/package_config.json')
    $env:GITHUB_WORKSPACE = $checkout
    & $cleanup
    Assert (Test-Path -LiteralPath (Join-Path $checkout 'build/app/outputs/app-debug.apk')) 'Checkout was cleaned without -Checkout.'
    Seed
    Reject { & $cleanup -Checkout 'relative-checkout' } 'absolute Git checkout'
    & $cleanup -Checkout $checkout
    Assert (-not (Test-Path -LiteralPath (Join-Path $checkout 'build')) -and -not (Test-Path -LiteralPath (Join-Path $checkout '.dart_tool'))) 'Checkout build outputs were kept.'
    Assert ((Test-Path -LiteralPath (Join-Path $checkout 'tracked.txt')) -and (Test-Path -LiteralPath (Join-Path $checkout '.git'))) 'Checkout cleanup removed tracked files.'
    Assert-Preserved

    # Stale sweep: only old run/job/attempt runtimes go; links and unknown names are never entered.
    . (Join-Path $scripts 'Common.ps1')
    $env:GITHUB_RUN_ID = '987700'; $env:GITHUB_JOB = 'sweeper'; $env:GITHUB_RUN_ATTEMPT = '1'
    $layout = Get-DanshengCiLayout
    $runtimeRoot = Join-Path $env:DANSHENG_CI_ROOT 'runtime'
    $stale = Join-Path $runtimeRoot '987600/old-job/1'
    $staleUnmarked = Join-Path $runtimeRoot '987601/crashed-job/1'
    $markedRecently = Join-Path $runtimeRoot '987602/long-job/1'
    $fresh = Join-Path $runtimeRoot '987603/running-job/1'
    $foreign = Join-Path $runtimeRoot 'not-a-run/job/1'
    Put (Join-Path $stale '.ci-owned') '987600/old-job/1'; Put (Join-Path $stale 'gradle-cache/dep.jar')
    Put (Join-Path $staleUnmarked 'cargo-home/registry/dep.crate')
    Put (Join-Path $markedRecently '.ci-owned') '987602/long-job/1'
    Put (Join-Path $fresh '.ci-owned') '987603/running-job/1'
    Put (Join-Path $foreign 'keep.bin')
    $runLink = Join-Path $runtimeRoot '987604'
    Link $runLink (Join-Path $fixture 'outside')
    Age $stale 30; Age $staleUnmarked 30; Age $foreign 30
    [IO.Directory]::SetLastWriteTimeUtc($markedRecently, [DateTime]::UtcNow.AddHours(-30))
    $keptLatest = Join-Path $runtimeRoot '987605/idle-job/1'
    Put (Join-Path $keptLatest '.ci-owned') '987605/idle-job/1'; Put (Join-Path $keptLatest '.ci-finished') '987605/idle-job/1'
    Age $keptLatest 300
    Clear-DanshengCiRuntimes $layout
    Assert (Test-Path -LiteralPath $keptLatest) 'Sweep removed a job''s most recent finished runtime.'
    Assert (-not (Test-Path -LiteralPath $stale) -and -not (Test-Path -LiteralPath $staleUnmarked)) 'Stale runtimes were kept.'
    Assert ((Test-Path -LiteralPath $markedRecently) -and (Test-Path -LiteralPath $fresh)) 'Sweep removed a runtime that may still run.'
    Assert (Test-Path -LiteralPath (Join-Path $foreign 'keep.bin')) 'Sweep entered an unrecognized directory.'
    Assert (Test-Path -LiteralPath $runLink) 'Sweep removed a linked run directory.'
    Unlink $runLink
    Assert-Preserved

    # Size measurement skips links, so outside data never counts toward (or triggers) a reset.
    $measured = Join-Path $fixture 'measured'
    [void][IO.Directory]::CreateDirectory($measured)
    [IO.File]::WriteAllBytes((Join-Path $measured 'a.bin'), [byte[]]::new(1000))
    [IO.File]::WriteAllBytes((Join-Path $outside 'big.bin'), [byte[]]::new(100000))
    Link (Join-Path $measured 'linked') $outside
    Assert ((Get-CiDirectoryBytes $measured) -eq 1000) 'Directory size followed a link.'
    Limit-DanshengCiBuildCache $measured 500
    Assert (-not (Test-Path -LiteralPath $measured)) 'Over-budget directory was kept.'
    [void]$links.Remove((Join-Path $measured 'linked'))
    Assert (Test-Path -LiteralPath (Join-Path $outside 'big.bin')) 'Budget reset followed a link.'
    Assert-Preserved

    Assert ([Environment]::GetEnvironmentVariable('HOME') -ceq $inheritedSystemHome) 'Changed system HOME.'
    Assert ([Environment]::GetEnvironmentVariable('USERPROFILE') -ceq $inheritedUserProfile) 'Changed USERPROFILE.'
    Write-Host "Runtime cleanup fixtures passed: $checks assertions."
} finally {
    foreach ($link in @($links.ToArray())) { Unlink $link }
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $fullFixture = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($fullFixture) -notlike 'dansheng runtime cleanup *') {
        throw 'Refusing to remove a fixture outside the designated temporary directory.'
    }
    if (-not $IsWindows -and (Test-Path -LiteralPath $fullFixture)) { & chmod -R u+rwX -- $fullFixture 2>$null }
    if (Test-Path -LiteralPath $fullFixture) { Remove-Item -LiteralPath $fullFixture -Recurse -Force }
}
