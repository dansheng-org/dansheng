#Requires -Version 7.0
[CmdletBinding()]
param([string]$FixtureRoot)

# Exercise unmodified production scripts in disposable Git repositories. A broken
# source-boundary guard must never write into a developer's real worktrees.
# All fixtures, logs and results are retained; this script performs no cleanup.
$ErrorActionPreference = 'Stop'
$entryTestSource = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entryTestComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Assert-EntryTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-EntryPathWithin([string]$Parent, [string]$Child) {
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    $childPath.Equals($parentPath, $entryTestComparison) -or
        $childPath.StartsWith($parentPath + [IO.Path]::DirectorySeparatorChar, $entryTestComparison)
}

if (-not $FixtureRoot) {
    $entryTestBase = if ($IsWindows) { 'D:/DevCache/dansheng/entry-tests' } else { Join-Path ([IO.Path]::GetTempPath()) 'dansheng-entry-tests' }
    $FixtureRoot = Join-Path $entryTestBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
}
Assert-EntryTest ([IO.Path]::IsPathFullyQualified($FixtureRoot)) 'FixtureRoot must be absolute.'
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot).TrimEnd('\', '/')
Assert-EntryTest (-not (Test-Path -LiteralPath $FixtureRoot)) 'FixtureRoot must be new; existing evidence is never overwritten.'
if ($IsWindows) {
    Assert-EntryTest ([IO.Path]::GetPathRoot($FixtureRoot) -ieq 'D:\') 'Windows fixtures must stay on D:.'
}
for ($entryTestAncestor = $FixtureRoot; $entryTestAncestor; $entryTestAncestor = [IO.Path]::GetDirectoryName($entryTestAncestor)) {
    if (Test-Path -LiteralPath $entryTestAncestor) {
        Assert-EntryTest (-not ((Get-Item -LiteralPath $entryTestAncestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Linked fixture paths or ancestors are refused.'
    }
}
$entryTestTrees = @(& git --no-optional-locks -C $entryTestSource worktree list --porcelain)
Assert-EntryTest ($LASTEXITCODE -eq 0) 'Cannot inspect source worktree registration.'
foreach ($entryTestTree in $entryTestTrees) {
    if ($entryTestTree -like 'worktree *') {
        $entryTestBoundary = $entryTestTree.Substring(9)
        Assert-EntryTest (-not ((Test-EntryPathWithin $entryTestBoundary $FixtureRoot) -or (Test-EntryPathWithin $FixtureRoot $entryTestBoundary))) 'FixtureRoot must be separate from every real source worktree.'
    }
}

[void][IO.Directory]::CreateDirectory($FixtureRoot)
$entryTestLogs = Join-Path $FixtureRoot 'logs'
$entryTestTools = Join-Path $FixtureRoot 'empty-toolchain'
$entryTestEmptyGit = Join-Path $FixtureRoot 'empty-git-template'
foreach ($entryTestDirectory in @($entryTestLogs, $entryTestTools, $entryTestEmptyGit)) {
    [void][IO.Directory]::CreateDirectory($entryTestDirectory)
}
$entryTestPrimary = Join-Path $FixtureRoot 'primary source'
$entryTestCheckout = Join-Path $FixtureRoot 'entry worktree'
$entryTestOther = Join-Path $FixtureRoot 'other worktree'
$entryTestEntry = Join-Path $entryTestCheckout 'scripts/Enter-Dansheng.ps1'
$entryTestRuntime = Join-Path $FixtureRoot 'runtimes/custom runtime'
$entryTestSdk = Join-Path $entryTestRuntime 'selected sdk'
$entryTestCases = [Collections.Generic.List[object]]::new()
$entryTestInputs = [Collections.Generic.List[object]]::new()
$entryTestInvocation = 0
$entryTestComplete = $false
$entryTestSetupError = $null

# Keep the caller's environment intact and avoid global Git settings, hooks,
# installed toolchains, profiles or SDKs. Only public source files are copied.
$entryTestEnvNames = @(
    'DANSHENG_TASK_RUNTIME', 'DANSHENG_CORE_ROOT', 'DANSHENG_CORE_TOOLS_ROOT',
    'DANSHENG_CORE_LOCK_FILE', 'DANSHENG_CORE_SDK_DIR', 'DANSHENG_TOOLCHAIN_ROOT',
    'DANSHENG_PROFILE', 'DANSHENG_LAB_PROFILE', 'DANSHENG_BROWSER_PROFILE',
    'CARGO_HOME', 'CARGO_TARGET_DIR', 'PUB_CACHE', 'PUB_HOSTED_URL', 'GRADLE_USER_HOME', 'npm_config_cache',
    'ANDROID_USER_HOME', 'ANDROID_AVD_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT',
    'TEMP', 'TMP', 'PATH', 'RUSTUP_HOME', 'RUSTUP_TOOLCHAIN', 'LIBCLANG_PATH',
    'CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER', 'CC_x86_64_pc_windows_gnu', 'AR_x86_64_pc_windows_gnu',
    'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_NAMESPACE',
    'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CEILING_DIRECTORIES',
    'GIT_CONFIG', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_GLOBAL',
    'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM', 'GIT_TEMPLATE_DIR', 'GIT_TERMINAL_PROMPT'
)
$entryTestSavedEnv = @{}
$entryTestPresentEnv = @{}
foreach ($entryTestName in $entryTestEnvNames) {
    $entryTestSavedEnv[$entryTestName] = [Environment]::GetEnvironmentVariable($entryTestName, 'Process')
    $entryTestPresentEnv[$entryTestName] = Test-Path -LiteralPath ('Env:' + $entryTestName)
}

function Invoke-EntryFixtureGit([string]$Root, [string[]]$Arguments) {
    $gitOutput = @(& git --no-optional-locks -c core.autocrlf=false -c core.safecrlf=false `
        -c "core.hooksPath=$entryTestEmptyGit" -C $Root @Arguments 2>&1)
    $gitExit = $LASTEXITCODE
    $gitOutput | Add-Content -LiteralPath (Join-Path $entryTestLogs 'git.log')
    Assert-EntryTest ($gitExit -eq 0) "Fixture Git failed: $($Arguments -join ' '). See logs/git.log."
    $gitOutput -join "`n"
}

function Invoke-RealEntry([hashtable]$EntryOptions = @{}) {
    $invokeOptions = $EntryOptions.Clone()
    $invokeOptions.ToolchainRoot = $entryTestTools
    $script:entryTestInvocation++
    $entryLog = Join-Path $entryTestLogs ('entry-{0:D2}.log' -f $script:entryTestInvocation)
    . $entryTestEntry @invokeOptions *> $entryLog
}

function Invoke-EntryCase([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $entryTestCases.Add([pscustomobject]@{ name = $Name; passed = $true; error = $null })
        Write-Host "PASS: $Name"
    } catch {
        $entryTestCases.Add([pscustomobject]@{ name = $Name; passed = $false; error = $_.Exception.Message })
        Write-Host "FAIL: $Name -- $($_.Exception.Message)"
    }
}

function Assert-SourceRuntimeRejected([string]$Candidate) {
    Assert-EntryTest (-not (Test-Path -LiteralPath $Candidate)) 'The rejection candidate must not already exist.'
    $rejection = $null
    try { Invoke-RealEntry @{ RuntimeRoot = $Candidate } } catch { $rejection = $_.Exception.Message }
    Assert-EntryTest (-not (Test-Path -LiteralPath $Candidate)) "Rejected source runtime was created: $Candidate"
    Assert-EntryTest ($rejection -like '*registered source checkout*') "Expected a source-boundary rejection; received: $rejection"
}

function Assert-ForeignOwnerRejected([string]$Candidate, [string]$OwnerWorktree, [string]$OwnerCommon) {
    [void][IO.Directory]::CreateDirectory($Candidate)
    $ownerPath = Join-Path $Candidate 'owner.json'
    [ordered]@{ worktree = $OwnerWorktree; common_dir = $OwnerCommon } | ConvertTo-Json | Set-Content -LiteralPath $ownerPath
    $ownerBefore = (Get-FileHash -LiteralPath $ownerPath).Hash
    $sentinel = Join-Path $Candidate 'preserve.txt'
    [IO.File]::WriteAllText($sentinel, 'Existing foreign fixture data must survive rejection.')
    $sentinelBefore = (Get-FileHash -LiteralPath $sentinel).Hash
    $runtimeBefore = $env:DANSHENG_TASK_RUNTIME
    $sdkBefore = $env:DANSHENG_CORE_SDK_DIR
    $rejection = $null
    try { Invoke-RealEntry @{ RuntimeRoot = $Candidate } } catch { $rejection = $_.Exception.Message }
    Assert-EntryTest ($rejection -like '*belongs to another checkout*') "Expected an owner rejection; received: $rejection"
    Assert-EntryTest ((Get-FileHash -LiteralPath $ownerPath).Hash -eq $ownerBefore) 'Foreign owner record was overwritten.'
    Assert-EntryTest ((Get-FileHash -LiteralPath $sentinel).Hash -eq $sentinelBefore) 'Foreign fixture data was modified.'
    Assert-EntryTest (@(Get-ChildItem -LiteralPath $Candidate -Force).Count -eq 2) 'Rejected foreign runtime gained cache/profile directories.'
    Assert-EntryTest ($env:DANSHENG_TASK_RUNTIME -ceq $runtimeBefore) 'Rejected owner changed the entered runtime.'
    Assert-EntryTest ($env:DANSHENG_CORE_SDK_DIR -ceq $sdkBefore) 'Rejected owner changed the selected SDK.'
}

try {
    foreach ($entryTestName in $entryTestEnvNames) {
        if ($entryTestName -ne 'PATH') { Remove-Item -LiteralPath ('Env:' + $entryTestName) -ErrorAction SilentlyContinue }
    }
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = Join-Path $FixtureRoot 'empty.gitconfig'
    [IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL, '')
    $env:GIT_TEMPLATE_DIR = $entryTestEmptyGit
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:ANDROID_HOME = Join-Path $FixtureRoot 'empty-android-sdk'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

    [void][IO.Directory]::CreateDirectory($entryTestPrimary)
    $null = Invoke-EntryFixtureGit $entryTestPrimary @('init', '--initial-branch=main')
    $entryTestPublicInputs = @('scripts/Enter-Dansheng.ps1', 'apps/dansheng_app/scripts/core-dependency.ps1', 'core/scripts/dev.ps1')
    foreach ($entryTestInput in $entryTestPublicInputs) {
        $entryTestFrom = Join-Path $entryTestSource $entryTestInput
        $entryTestTo = Join-Path $entryTestPrimary $entryTestInput
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $entryTestTo))
        Copy-Item -LiteralPath $entryTestFrom -Destination $entryTestTo
        $entryTestInputs.Add([pscustomobject]@{ path = $entryTestInput; sha256 = (Get-FileHash -LiteralPath $entryTestTo).Hash.ToLowerInvariant() })
    }
    # Only the isolated fixture Git database is changed below.
    $null = Invoke-EntryFixtureGit $entryTestPrimary (@('add', '--') + $entryTestPublicInputs)
    $null = Invoke-EntryFixtureGit $entryTestPrimary @('-c', 'user.name=Entry Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-m', 'Synthetic entry fixture')
    $null = Invoke-EntryFixtureGit $entryTestPrimary @('worktree', 'add', '--detach', $entryTestCheckout, 'HEAD')
    $null = Invoke-EntryFixtureGit $entryTestPrimary @('worktree', 'add', '--detach', $entryTestOther, 'HEAD')
    $entryTestCommon = [IO.Path]::GetFullPath((Invoke-EntryFixtureGit $entryTestCheckout @('rev-parse', '--path-format=absolute', '--git-common-dir')).Trim())
    foreach ($entryTestInput in $entryTestInputs) {
        Assert-EntryTest ((Get-FileHash -LiteralPath (Join-Path $entryTestCheckout $entryTestInput.path)).Hash -ieq $entryTestInput.sha256) 'Fixture checkout changed production script bytes.'
    }

    Invoke-EntryCase 'primary checkout runtime rejected before creation' {
        Assert-SourceRuntimeRejected (Join-Path $entryTestPrimary 'must-not-exist/runtime')
        Assert-EntryTest (-not (Test-Path -LiteralPath (Join-Path $entryTestPrimary 'must-not-exist'))) 'Primary checkout gained a runtime parent directory.'
    }
    Invoke-EntryCase 'other linked worktree runtime rejected before creation' {
        Assert-SourceRuntimeRejected (Join-Path $entryTestOther 'must-not-exist/runtime')
        Assert-EntryTest (-not (Test-Path -LiteralPath (Join-Path $entryTestOther 'must-not-exist'))) 'Other worktree gained a runtime parent directory.'
    }
    Invoke-EntryCase 'current checkout runtime rejected before creation' {
        Assert-SourceRuntimeRejected (Join-Path $entryTestCheckout 'must-not-exist/runtime')
    }
    Invoke-EntryCase 'explicit runtime owns caches and selects the requested SDK' {
        Invoke-RealEntry @{ RuntimeRoot = $entryTestRuntime; ArtifactDirectory = $entryTestSdk }
        Assert-EntryTest ($env:DANSHENG_TASK_RUNTIME -ceq $entryTestRuntime) 'Explicit runtime was replaced.'
        Assert-EntryTest ($env:DANSHENG_CORE_SDK_DIR -ceq $entryTestSdk) 'Explicit SDK selection was replaced.'
        $testOwner = Get-Content -LiteralPath (Join-Path $entryTestRuntime 'owner.json') -Raw | ConvertFrom-Json
        Assert-EntryTest ($testOwner.worktree -ceq $entryTestCheckout -and $testOwner.common_dir -ceq $entryTestCommon) 'Runtime owner does not identify the actual registered checkout.'
        foreach ($testVariable in @('CARGO_HOME', 'CARGO_TARGET_DIR', 'PUB_CACHE', 'GRADLE_USER_HOME', 'ANDROID_AVD_HOME', 'DANSHENG_PROFILE', 'DANSHENG_LAB_PROFILE', 'DANSHENG_BROWSER_PROFILE', 'TEMP', 'TMP')) {
            $testPath = [Environment]::GetEnvironmentVariable($testVariable, 'Process')
            Assert-EntryTest ($testPath -and (Test-EntryPathWithin $entryTestRuntime $testPath) -and (Test-Path -LiteralPath $testPath -PathType Container)) "$testVariable does not use a prepared directory in the selected runtime."
        }
        Assert-EntryTest ($env:DANSHENG_CORE_ROOT -ceq (Join-Path $entryTestCheckout 'core')) 'Core source escaped the entered worktree.'
    }
    Invoke-EntryCase 'second entry preserves custom runtime SDK owner and existing artifacts' {
        $testOwnerFile = Join-Path $entryTestRuntime 'owner.json'
        $testOwnerHash = (Get-FileHash -LiteralPath $testOwnerFile).Hash
        $testArtifact = Join-Path $entryTestRuntime 'artifacts/retained.txt'
        [IO.File]::WriteAllText($testArtifact, 'Preserve previous review artifacts.')
        $testArtifactHash = (Get-FileHash -LiteralPath $testArtifact).Hash
        Invoke-RealEntry
        Assert-EntryTest ($env:DANSHENG_TASK_RUNTIME -ceq $entryTestRuntime) 'Second entry switched away from the owned custom runtime.'
        Assert-EntryTest ($env:DANSHENG_CORE_SDK_DIR -ceq $entryTestSdk) 'Second entry discarded the custom SDK.'
        Assert-EntryTest ((Get-FileHash -LiteralPath $testOwnerFile).Hash -eq $testOwnerHash) 'Second entry rewrote the owner record.'
        Assert-EntryTest ((Get-FileHash -LiteralPath $testArtifact).Hash -eq $testArtifactHash) 'Second entry modified a retained artifact.'
    }
    Invoke-EntryCase 'foreign worktree owner rejected without modifying runtime or environment' {
        Assert-ForeignOwnerRejected (Join-Path $FixtureRoot 'runtimes/foreign worktree') $entryTestOther $entryTestCommon
    }
    Invoke-EntryCase 'foreign common directory owner rejected without modifying runtime or environment' {
        Assert-ForeignOwnerRejected (Join-Path $FixtureRoot 'runtimes/foreign repository') $entryTestCheckout (Join-Path $FixtureRoot 'foreign.git')
    }
    $entryTestComplete = $true
} catch {
    $entryTestSetupError = $_.Exception.Message
    throw
} finally {
    foreach ($entryTestName in $entryTestEnvNames) {
        if ($entryTestPresentEnv[$entryTestName]) {
            [Environment]::SetEnvironmentVariable($entryTestName, $entryTestSavedEnv[$entryTestName], 'Process')
        } else {
            Remove-Item -LiteralPath ('Env:' + $entryTestName) -ErrorAction SilentlyContinue
        }
    }
    $entryTestReport = [ordered]@{
        completed = $entryTestComplete
        passed = @($entryTestCases | Where-Object passed).Count
        failed = @($entryTestCases | Where-Object { -not $_.passed }).Count
        setup_error = $entryTestSetupError
        fixture = $FixtureRoot
        source = $entryTestSource
        powershell = $PSVersionTable.PSVersion.ToString()
        inputs = @($entryTestInputs)
        cases = @($entryTestCases)
    }
    $entryTestReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'results.json')
    Write-Host "Preserved entry fixtures and results: $FixtureRoot"
}
Assert-EntryTest ($entryTestComplete -and $entryTestReport.failed -eq 0) 'Entry runtime regression tests failed; inspect the preserved results.json and logs.'
$global:LASTEXITCODE = 0
