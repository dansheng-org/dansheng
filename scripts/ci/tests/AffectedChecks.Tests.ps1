#Requires -Version 7.0
# Real Git fixtures in a fresh task directory; no builds or real repository writes.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-AffectedChecks.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng affected checks ' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $fixture 'repo with spaces'
$eventPath = Join-Path $fixture 'event.json'
$outputPath = Join-Path $fixture 'github output.txt'
$checks = 0
$cases = 0
$saved = @{}
$envNames = @('BASE_SHA', 'GITHUB_BASE_REF', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0',
    'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'HOME', 'USERPROFILE', 'XDG_CONFIG_HOME')
foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Git([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command git -CommandType Application | Select-Object -First 1).Source)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @($start.Environment.Keys)) {
        if ($name.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase)) { [void]$start.Environment.Remove($name) }
    }
    $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $start.Environment['GIT_CONFIG_GLOBAL'] = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    $start.Environment['GIT_AUTHOR_NAME'] = 'Affected checks fixture'
    $start.Environment['GIT_AUTHOR_EMAIL'] = 'fixture@example.invalid'
    $start.Environment['GIT_COMMITTER_NAME'] = 'Affected checks fixture'
    $start.Environment['GIT_COMMITTER_EMAIL'] = 'fixture@example.invalid'
    foreach ($arg in (@('-C', $repo, '-c', 'commit.gpgsign=false', '-c', ('core.hooksPath=' + (Join-Path $fixture 'no-hooks'))) + $Arguments)) {
        $start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Synthetic Git failed: $err" }
        $text.TrimEnd("`r", "`n")
    } finally { $process.Dispose() }
}
function Put([string]$Path, [string]$Text = 'synthetic fixture bytes') {
    $full = Join-Path $repo $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full, $Text, [Text.UTF8Encoding]::new($false))
}
function Commit([string[]]$Parents) {
    $tree = Git @('write-tree')
    $arguments = @('commit-tree', $tree, '-m', 'Synthetic affected check')
    foreach ($parent in $Parents) { $arguments += @('-p', $parent) }
    Git $arguments
}
function Changed([string]$Path, [string]$Parent = $script:base) {
    [void](Git @('read-tree', $Parent))
    Put $Path ('changed-' + [guid]::NewGuid().ToString('N'))
    [void](Git @('add', '--', $Path))
    Commit @($Parent)
}
function Check([string]$Name, [string]$Head, [string]$Before = $script:base,
    [string]$EventName = 'push', [string]$Want = 'true', [string]$Reason = 'dependency-or-unknown-path',
    [hashtable]$Payload, [string]$Ref = 'refs/heads/main', [string]$Sha = $Head) {
    [void](Git @('update-ref', 'HEAD', $Head))
    if ($null -eq $Payload) { $Payload = @{ before = $Before; after = $Head; ref = $Ref } }
    [IO.File]::WriteAllText($eventPath, ($Payload | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($outputPath, '')
    $result = & $helper -RepositoryRoot $repo -EventName $EventName -EventPath $eventPath -ExpectedSha $Sha -ExpectedRef $Ref -OutputPath $outputPath
    Assert ($result.workspace_fixtures -ceq $Want) "$Name decision: expected $Want, got $($result.workspace_fixtures) ($($result.reason))"
    Assert ($result.reason -ceq $Reason) "$Name reason: expected $Reason, got $($result.reason)"
    Assert ([IO.File]::ReadAllText($outputPath) -ceq "workspace_fixtures=$Want`nreason=$Reason`n") "$Name has unstable GitHub output"
    $script:cases++
}

function Set-PoisonGitEnvironment {
    # Only this test process and its children; never touch the real user config.
    $env:HOME = $script:poisonProfile
    $env:USERPROFILE = $script:poisonProfile
    $env:XDG_CONFIG_HOME = $script:poisonProfile
    $env:GIT_CONFIG_GLOBAL = Join-Path $script:poisonProfile '.gitconfig'
    $env:GIT_CONFIG_SYSTEM = $env:GIT_CONFIG_GLOBAL
    $env:GIT_CONFIG_NOSYSTEM = '0'
}

function FixtureWouldRun([string]$Outcome, [string]$Output) {
    # Interpret only the two comparisons from the checked-in workflow guard.
    # No shell evaluation; the syntax is validated before any truth-table checks.
    foreach ($comparison in [regex]::Matches($script:fixtureGuard, "steps\.affected\.(outcome|outputs\.workspace_fixtures) != '([^']*)'")) {
        $actual = if ($comparison.Groups[1].Value -eq 'outcome') { $Outcome } else { $Output }
        if ($actual -cne $comparison.Groups[2].Value) { return $true }
    }
    return $false
}

try {
    $workflow = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../../.github/workflows/core-ci.yml')).Replace("`r`n", "`n")
    $steps = @([regex]::Matches($workflow, '(?ms)^      - (?:name|run|uses):.*?(?=^      - |^  [a-z][a-z-]*:|\z)') | ForEach-Object Value)
    $affectedStep = @($steps | Where-Object { $_ -match '(?m)^        id: affected$' })
    Assert ($affectedStep.Count -eq 1) 'Expected one Determine step'
    Assert ([regex]::Matches($workflow, '(?m)^\s+continue-on-error:').Count -eq 1 -and
        $affectedStep[0] -match '(?m)^        continue-on-error: true$') 'Only Determine may continue on error'
    $fixtureGuard = "steps.affected.outcome != 'success' || steps.affected.outputs.workspace_fixtures != 'false'"
    foreach ($name in @('Worktree workflow integration fixtures', 'Dependency cache isolation fixtures')) {
        $step = @($steps | Where-Object { $_.StartsWith("      - name: $name`n") })
        Assert ($step.Count -eq 1 -and $step[0].Contains("!inputs.smoke && ($fixtureGuard)")) "$name must fail open on failed classification, even with a false output"
        $hostOs = if ($name -eq 'Worktree workflow integration fixtures') { 'Linux' } else { 'Windows' }
        Assert ($step[0].Contains("runner.os == '$hostOs'")) "$name must stay on its intended host"
    }
    $rustSteps = @($steps | Where-Object { $_ -match '^      - run: cargo (fmt|test|clippy) ' })
    Assert ($rustSteps.Count -eq 3) 'Expected all three Rust checks'
    foreach ($step in $rustSteps) {
        Assert ($step.Contains('        if: ${{ !inputs.smoke }}') -and -not $step.Contains('steps.affected')) 'Rust checks must remain independent of classification'
    }
    $selfTest = @($steps | Where-Object { $_.StartsWith("      - name: Test affected-check scheduling`n") })
    Assert ($selfTest.Count -eq 1 -and $selfTest[0].Contains('        if: ${{ !inputs.smoke }}') -and
        -not $selfTest[0].Contains('steps.affected')) 'Scheduling tests must fail normally and never gate themselves'
    foreach ($state in @(
        @('success', 'false', $false), @('success', 'true', $true), @('success', '', $true),
        @('failure', 'false', $true), @('failure', 'true', $true), @('failure', '', $true),
        @('skipped', 'false', $true), @('cancelled', 'false', $true)
    )) { Assert ((FixtureWouldRun $state[0] $state[1]) -eq $state[2]) "Incorrect fixture gate: outcome=$($state[0]), output=$($state[1])" }
    [void][IO.Directory]::CreateDirectory($repo)
    $poisonProfile = Join-Path $fixture 'synthetic user profile'
    [void][IO.Directory]::CreateDirectory($poisonProfile)
    [IO.File]::WriteAllText((Join-Path $poisonProfile '.gitconfig'), '[malformed global config')
    Set-PoisonGitEnvironment
    [void](Git @('init', '--initial-branch=main'))
    Assert ((Git @('config', '--global', '--list')) -ceq '') 'Test Git wrapper inherited user global configuration'
    [void](Git @('config', 'core.autocrlf', 'false'))
    $forum = 'core/crates/dansheng-connectors/src/forum_actions.rs'
    $ui = 'apps/dansheng_app/lib/ui/campus/forum/hole_card.dart'
    $dependency = 'core/tools/workspace/Dansheng.Workspace.psm1'
    $dependencies = @(
        $dependency, 'core/tools/workspace/tests/Test-Environment.ps1',
        'core/scripts/release-common.ps1', 'core/scripts/runtime-common.ps1',
        'scripts/Enter-Dansheng.ps1', 'scripts/ci/Get-AffectedChecks.ps1',
        'scripts/ci/tests/AffectedChecks.Tests.ps1', 'scripts/ci/Invoke-WorkspaceFixtures.ps1',
        '.github/workflows/core-ci.yml', '.github/workflows/app-ci.yml', '.github/workflows/new-workflow.yml',
        'core/Cargo.toml', 'core/Cargo.lock', 'core/rust-toolchain.toml', 'core/.cargo/config.toml',
        'core/crates/dansheng-connectors/Cargo.toml',
        'core/platform/android/adapter/build.gradle.kts', 'core/platform/android/adapter/src/main/Bridge.kt',
        'core/include/dansheng.h', 'core/plugins/builtin/fudan-venues/main.mjs',
        'apps/dansheng_app/pubspec.yaml', 'apps/dansheng_app/pubspec.lock',
        'apps/dansheng_app/android/gradle.properties', 'core/sdk/package.json', '.gitattributes',
        # Nested build configuration must not borrow a product directory's allowlist.
        'core/crates/dansheng-connectors/src/mail/test-harness/Cargo.toml',
        'core/crates/dansheng-connectors/tests/.cargo/config.toml',
        'apps/dansheng_app/test/fixtures/pubspec.yaml',
        'apps/dansheng_app/lib/.github/workflows/check.yml',
        'new-build-config.unknown',
        'apps/dansheng_app/lib/ui/campus/forum/build.gradle.kts',
        'core/crates/dansheng-connectors/src/generate.ps1',
        'core/crates/dansheng-connectors/tests/build.sh',
        'core/crates/dansheng-connectors/src/run.cmd',
        'core/crates/dansheng-connectors/src/unknown.extension',
        'apps/dansheng_app/lib/generate.ps1', 'apps/dansheng_app/pigeons/generate.sh',
        'apps/dansheng_app/android/app/src/main/Android.mk',
        'apps/dansheng_app/android/app/src/main/Application.mk',
        'apps/dansheng_app/android/app/src/main/helper.exe'
    )
    foreach ($path in (@($forum, $ui) + $dependencies)) { Put $path }
    $pubspec = "name: synthetic_fixture`nversion: 0.2.14+16`nenvironment:`n  sdk: ^3.13.5`ndependencies:`n  flutter:`n    sdk: flutter`n"
    $bumpedPubspec = $pubspec.Replace('0.2.14+16', '0.2.15+17')
    Put 'apps/dansheng_app/pubspec.yaml' $pubspec
    [void](Git @('add', '--all'))
    $base = Commit @()
    # Exercise the allowlist directly, then check the real Git/event/output path
    # with combined changes. Avoid hundreds of redundant native Git launches.
    $null = . $helper -RepositoryRoot $repo -EventName fixture-tests -EventPath $eventPath -OutputPath $outputPath
    Assert ((Invoke-AffectedGit @('config', '--global', '--list')) -ceq '') 'Classifier Git wrapper inherited user global configuration'
    $business = @(
        $forum, $ui, 'core/crates/dansheng-connectors/tests/suites/forum_actions.rs',
        'core/crates/dansheng-connectors/tests/forum_webvpn_live.rs',
        'apps/dansheng_app/test/campus/forum_test.dart',
        'apps/dansheng_app/test/campus/forum_floor_layout_test.dart',
        'apps/dansheng_app/test/support/forum_preview_app.dart',
        'apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/ForumRiskConsent.kt',
        'apps/dansheng_app/android/app/src/test/kotlin/org/dansheng/app/ForumRiskConsentTest.kt',
        'core/crates/dansheng-connectors/src/core_adapter.rs',
        'core/crates/dansheng-connectors/src/transport.rs',
        'core/crates/dansheng-core/tests/unrelated_product.rs',
        'apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusLogins.kt',
        'apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusServices.kt',
        'apps/dansheng_app/pigeons/dansheng.dart', 'core/docs/network-routing.md',
        'docs/development/testing.md', 'core/crates/dansheng-connectors/README.md', 'README.md',
        'core/crates/dansheng-connectors/src/library.rs', 'docs/new-input.md',
        'core/crates/dansheng-core/tests/fixtures/response.json',
        'core/crates/dansheng-core/tests/fixtures/page.html',
        'core/crates/dansheng-core/tests/fixtures/message.eml',
        'apps/dansheng_app/test/fixtures/response.json',
        'apps/dansheng_app/android/app/src/main/AndroidManifest.xml',
        'apps/dansheng_app/android/app/src/main/assets/bridge.mjs',
        # ArgumentList and NUL parsing preserve shell metacharacters and Unicode.
        'apps/dansheng_app/lib/ui/campus/forum/空 格 [x] $(); & name.dart'
    )
    foreach ($path in $business) {
        Assert (Test-ProductPath $path) "Forum business path unexpectedly requires fixtures: $path"
        Put $path ('business-' + [guid]::NewGuid().ToString('N'))
    }
    [void](Git @('add', '--all'))
    Check 'combined forum business changes' (Commit @($base)) -Want false -Reason product-only
    foreach ($path in $dependencies) { Assert (-not (Test-ProductPath $path)) "Dependency/unknown path skipped fixtures: $path" }
    Check 'workflow change' (Changed '.github/workflows/core-ci.yml')
    Check 'helper change' (Changed 'scripts/ci/Get-AffectedChecks.ps1')
    Check 'product path with PowerShell tool' (Changed 'core/crates/dansheng-connectors/src/generate.ps1')
    Check 'Android native build file' (Changed 'apps/dansheng_app/android/app/src/main/Android.mk')
    Check 'unrelated product change' (Changed 'core/crates/dansheng-connectors/src/library.rs') -Want false -Reason product-only
    # PR #22's exact fifteen paths, with synthetic content and history only.
    $pr22Paths = @(
        'apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusLogins.kt',
        'apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/CampusServices.kt',
        'apps/dansheng_app/android/app/src/main/kotlin/org/dansheng/app/ForumRiskConsent.kt',
        'apps/dansheng_app/android/app/src/test/kotlin/org/dansheng/app/ForumRiskConsentTest.kt',
        'apps/dansheng_app/lib/ui/campus/forum/forum_page.dart',
        'apps/dansheng_app/lib/ui/campus/forum/forum_service.dart',
        'apps/dansheng_app/pubspec.yaml', 'apps/dansheng_app/test/campus/forum_test.dart',
        'core/crates/dansheng-connectors/README.md',
        'core/crates/dansheng-connectors/src/core_adapter.rs',
        'core/crates/dansheng-connectors/src/forum_actions.rs',
        'core/crates/dansheng-connectors/src/transport.rs',
        'core/crates/dansheng-connectors/tests/forum_webvpn_live.rs',
        'core/docs/network-routing.md', 'docs/development/testing.md'
    )
    [void](Git @('read-tree', $base))
    foreach ($path in $pr22Paths) { Put $path ('PR22 synthetic product change: ' + $path) }
    Put 'apps/dansheng_app/pubspec.yaml' $bumpedPubspec
    [void](Git (@('add', '--') + $pr22Paths))
    $pr22Head = Commit @($base)
    Check 'PR22 fifteen-file product combination' $pr22Head -Want false -Reason product-only
    $pr22Result = & $helper -RepositoryRoot $repo -EventName push -EventPath $eventPath -ExpectedSha $pr22Head -ExpectedRef refs/heads/main -OutputPath $outputPath
    Assert ($pr22Result.changed_paths -eq 15) 'PR22 fixture must contain exactly fifteen changed paths'
    [void](Git @('read-tree', $pr22Head))
    $pr22Merge = Commit @($base, $pr22Head)
    Check 'PR22 merge event' $pr22Merge -EventName pull_request -Ref refs/pull/22/merge -Want false -Reason product-only -Payload @{
        number = 22; pull_request = @{ base = @{ sha = $base }; head = @{ sha = $pr22Head } }
    }
    Check 'product and docs mixed with workflow configuration' (Changed '.github/workflows/core-ci.yml' $pr22Head)
    Check 'product and docs mixed with Cargo configuration' (Changed 'core/.cargo/config.toml' $pr22Head)
    # Strict version-only comparison: dependencies, SDK, whitespace, malformed or
    # duplicate version lines, newline conversion and final-newline loss all run full.
    Assert (Test-PubspecVersionOnlyContent $pubspec $bumpedPubspec) 'Version-only pubspec content rejected'
    Assert (Test-PubspecVersionOnlyContent ($pubspec.Replace("`n", "`r`n")) ($bumpedPubspec.Replace("`n", "`r`n"))) 'Unchanged CRLF should allow a version bump'
    foreach ($invalidPubspec in @(
        $bumpedPubspec.Replace('sdk: flutter', 'sdk: changed'),
        $bumpedPubspec.Replace('^3.13.5', '^3.14.0'),
        $bumpedPubspec.Replace('version: 0.2.15+17', 'version: 0.2.15'),
        $bumpedPubspec.Replace('version: 0.2.15+17', 'version: "0.2.15+17"'),
        ($bumpedPubspec + "version: 1.0.0+1`n"),
        $bumpedPubspec.Replace("`n", "`r`n"), $bumpedPubspec.TrimEnd("`n"),
        $bumpedPubspec.Replace('name: ', 'name:  '), $pubspec
    )) { Assert (-not (Test-PubspecVersionOnlyContent $pubspec $invalidPubspec)) 'Non-version pubspec change was accepted' }
    foreach ($spec in @(
        @('version-only blob', $bumpedPubspec, 'false'),
        @('dependency blob', $bumpedPubspec.Replace('sdk: flutter', 'sdk: changed'), 'true'),
        @('SDK blob', $bumpedPubspec.Replace('^3.13.5', '^3.14.0'), 'true'),
        @('newline blob', $bumpedPubspec.Replace("`n", "`r`n"), 'true')
    )) {
        [void](Git @('read-tree', $base))
        Put 'apps/dansheng_app/pubspec.yaml' $spec[1]
        [void](Git @('add', '--', 'apps/dansheng_app/pubspec.yaml'))
        Check $spec[0] (Commit @($base)) -Want $spec[2] -Reason $(if ($spec[2] -eq 'false') { 'product-only' } else { 'dependency-or-unknown-path' })
    }
    [void](Git @('read-tree', $base))
    [void](Git @('update-index', '--force-remove', '--', 'apps/dansheng_app/pubspec.yaml'))
    $noPubspec = Commit @($base)
    Check 'pubspec deleted blob read fails open' $noPubspec -Reason git-error
    Check 'pubspec added blob read fails open' $base -Before $noPubspec -Reason git-error
    Check 'leading BOM filename is not a safe path' (Changed ([string][char]0xFEFF + $ui))
    $forumHead = Changed $forum
    Check 'empty diff' $base -Want false -Reason empty-diff
    Check 'manual full' $forumHead -EventName workflow_dispatch -Reason manual-full
    Check 'unknown event' $forumHead -EventName workflow_call -Reason unknown-event-full
    Check 'initial push' $forumHead -Before ('0' * 40) -Reason missing-push-before
    Check 'absent before' $forumHead -Before '' -Reason missing-push-before
    Check 'unavailable before' $forumHead -Before ('f' * 40) -Reason git-error
    Check 'bad before' $forumHead -Before '--help' -Reason missing-push-before
    Check 'wrong checkout' $forumHead -Sha $base -Reason checkout-sha-mismatch
    Check 'wrong event after' $forumHead -Payload @{ before = $base; after = $base; ref = 'refs/heads/main' } -Reason push-payload-mismatch
    Check 'wrong push ref' $forumHead -Payload @{ before = $base; after = $forumHead; ref = 'refs/heads/other' } -Reason push-payload-mismatch

    Check 'output failure setup' $forumHead -Want false -Reason product-only
    $blockedOutput = Join-Path $fixture 'output path is a directory'
    [void][IO.Directory]::CreateDirectory($blockedOutput)
    $classificationOutcome = 'success'
    try {
        $null = & $helper -RepositoryRoot $repo -EventName push -EventPath $eventPath -ExpectedSha $forumHead -ExpectedRef refs/heads/main -OutputPath $blockedOutput
    } catch { $classificationOutcome = 'failure' }
    Assert ($classificationOutcome -ceq 'failure') 'Output write failure must surface as a failed classification step'
    # The preceding successful call already wrote false: a failed step must still
    # run fixtures even if GitHub captured such a value before the exception.
    Assert ([IO.File]::ReadAllText($outputPath).Contains('workspace_fixtures=false')) 'Expected a simulated previously captured false output'
    Assert (FixtureWouldRun $classificationOutcome 'false') 'Failed classification with partial false output skipped fixtures'
    $withoutOutput = & $helper -RepositoryRoot $repo -EventName push -EventPath $eventPath -ExpectedSha $forumHead -ExpectedRef refs/heads/main -OutputPath ''
    Assert ($withoutOutput.workspace_fixtures -ceq 'false') 'Missing-output setup should classify the product change as skippable'
    Assert (FixtureWouldRun 'success' '') 'Missing GitHub output must run fixtures'

    # Last commit is forum-only, but the whole push includes a fixture dependency.
    $middle = Changed $dependency
    $multiple = Changed $forum $middle
    Check 'multi-commit push' $multiple
    Check 'multi-commit before missing' $multiple -Before ('e' * 40) -Reason git-error

    [void](Git @('read-tree', $base))
    [void](Git @('update-index', '--force-remove', '--', $dependency))
    Check 'deleted dependency' (Commit @($base))
    [void](Git @('read-tree', $base))
    [void](Git @('update-index', '--force-remove', '--', $forum))
    Check 'deleted forum source' (Commit @($base)) -Want false -Reason product-only
    foreach ($spec in @(@($dependency, 'apps/dansheng_app/lib/ui/campus/forum/old-module.dart'), @($ui, 'scripts/renamed fixture.ps1'), @($ui, 'apps/dansheng_app/lib/ui/campus/forum/renamed.dart'))) {
        [void](Git @('read-tree', $base))
        [void](Git @('update-index', '--force-remove', '--', $spec[0]))
        Put $spec[1]
        [void](Git @('add', '--', $spec[1]))
        $safe = $spec[1].EndsWith('/renamed.dart')
        Check "rename: $($spec[0])" (Commit @($base)) -Want ((-not $safe).ToString().ToLowerInvariant()) -Reason $(if ($safe) { 'product-only' } else { 'dependency-or-unknown-path' })
    }
    if (-not $IsWindows) {
        foreach ($name in @("tab`t.dart", "newline`n.dart", 'quote".dart')) {
            $reason = if ($name.Contains("`n")) { 'dependency-or-unknown-path' } else { 'product-only' }
            Check 'special filename' (Changed "apps/dansheng_app/lib/ui/campus/forum/$name") -Want $(if ($name.Contains("`n")) { 'true' } else { 'false' }) -Reason $reason
        }
    }

    # Model a GitHub synthetic merge; first parent is base, second is PR head.
    [void](Git @('read-tree', $forumHead))
    $merge = Commit @($base, $forumHead)
    $pr = @{ number = 123; pull_request = @{ base = @{ sha = $base }; head = @{ sha = $forumHead } } }
    Check 'PR merge' $merge -EventName pull_request -Ref refs/pull/123/merge -Payload $pr -Want false -Reason product-only
    $relevant = Changed $dependency $forumHead
    [void](Git @('read-tree', $relevant))
    $relevantMerge = Commit @($base, $relevant)
    $relevantPr = @{ number = 123; pull_request = @{ base = @{ sha = $base }; head = @{ sha = $relevant } } }
    Check 'PR dependency' $relevantMerge -EventName pull_request -Ref refs/pull/123/merge -Payload $relevantPr
    Check 'PR head checkout' $forumHead -EventName pull_request -Ref refs/pull/123/head -Payload $pr -Reason not-pr-merge-ref
    Check 'PR wrong parents' $merge -EventName pull_request -Ref refs/pull/123/merge -Payload $relevantPr -Reason pr-parents-mismatch
    Check 'PR missing payload' $merge -EventName pull_request -Ref refs/pull/123/merge -Payload @{ number = 123 } -Reason invalid-pr-payload
    Check 'PR nonmerge commit' $forumHead -EventName pull_request -Ref refs/pull/123/merge -Payload $pr -Reason pr-parents-mismatch

    # Untrusted ambient Git/config/base hints must not redirect a comparison.
    $env:BASE_SHA = $relevantMerge
    $env:GITHUB_BASE_REF = $relevantMerge
    $env:GIT_DIR = Join-Path $fixture 'nonexistent.git'
    $env:GIT_WORK_TREE = Join-Path $fixture 'nonexistent-tree'
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'core.worktree'
    $env:GIT_CONFIG_VALUE_0 = Join-Path $fixture 'wrong-worktree'
    Check 'injected environment' $relevantMerge -EventName pull_request -Ref refs/pull/123/merge -Payload $relevantPr
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Set-PoisonGitEnvironment

    # Real depth-two clones prove the exact PR and multi-commit push behavior.
    $source = $repo
    [void](Git @('update-ref', 'HEAD', $merge))
    $shallow = Join-Path $fixture 'shallow pr'
    [void](Git @('clone', '--quiet', '--no-checkout', '--depth=2', ([uri]::new($source + [IO.Path]::DirectorySeparatorChar).AbsoluteUri), $shallow))
    $repo = $shallow
    Check 'shallow PR merge' $merge -EventName pull_request -Ref refs/pull/123/merge -Payload $pr -Want false -Reason product-only
    $repo = $source
    $depthOne = Join-Path $fixture 'depth one pr'
    [void](Git @('clone', '--quiet', '--no-checkout', '--depth=1', ([uri]::new($source + [IO.Path]::DirectorySeparatorChar).AbsoluteUri), $depthOne))
    $repo = $depthOne
    Check 'PR base object missing' $merge -EventName pull_request -Ref refs/pull/123/merge -Payload $pr -Reason git-error
    $repo = $source
    [void](Git @('update-ref', 'HEAD', $multiple))
    $shallow = Join-Path $fixture 'shallow push'
    [void](Git @('clone', '--quiet', '--no-checkout', '--depth=2', ([uri]::new($source + [IO.Path]::DirectorySeparatorChar).AbsoluteUri), $shallow))
    $repo = $shallow
    Check 'shallow push before unavailable' $multiple -Reason git-error

    [IO.File]::WriteAllText($eventPath, '{ malformed json')
    $result = & $helper -RepositoryRoot $repo -EventName push -EventPath $eventPath -ExpectedSha $multiple -ExpectedRef refs/heads/main -OutputPath $outputPath
    Assert ($result.workspace_fixtures -ceq 'true' -and $result.reason -ceq 'comparison-unavailable') 'Malformed event did not fail open'
    $result = & $helper -RepositoryRoot $fixture -EventName push -EventPath $eventPath -ExpectedSha $multiple -ExpectedRef refs/heads/main -OutputPath $outputPath
    Assert ($result.workspace_fixtures -ceq 'true' -and $result.reason -ceq 'git-error') 'Non-repository did not fail open'
    Write-Host "Affected-check fixtures passed: $cases cases, $checks assertions."
} finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    $full = [IO.Path]::GetFullPath($fixture)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($full) -notlike 'dansheng affected checks *') { throw 'Fixture cleanup escaped its temporary directory.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
