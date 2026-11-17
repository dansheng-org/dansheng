#Requires -Version 7.0
# Only synthetic markers and directories; never initialize or inspect a real runner.
$ErrorActionPreference = 'Stop'
$cleanup = Join-Path (Split-Path -Parent $PSScriptRoot) 'Clear-BuildOutputs.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng build outputs ' + [guid]::NewGuid().ToString('N'))
$names = @('DANSHENG_CI_ROOT', 'DANSHENG_TASK_RUNTIME', 'GITHUB_RUN_ID',
    'GITHUB_JOB', 'GITHUB_RUN_ATTEMPT', 'GITHUB_REF', 'GITHUB_EVENT_NAME', 'CARGO_TARGET_DIR')
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
function Reject([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected rejection: $Pattern; got: $message"
    foreach ($name in @('cargo-target', 'cargo-arm64', 'cargo-x86')) {
        Assert (Test-Path -LiteralPath (Join-Path $runtime "$name/debug/output.bin")) 'Rejected cleanup deleted build data.'
    }
}
function Seed {
    Put (Join-Path $runtime '.ci-owned') '987654/synthetic-job/2'
    foreach ($name in @('cargo-target', 'cargo-arm64', 'cargo-x86')) {
        Put (Join-Path $runtime "$name/debug/output.bin")
    }
}
function Link([string]$Path, [string]$Target) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
    $script:links.Add($Path)
}
function Unlink([string]$Path) {
    Remove-Item -LiteralPath $Path -Force
    [void]$script:links.Remove($Path)
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
    # Even a supplied target pointing outside the runtime must never be used.
    $env:CARGO_TARGET_DIR = $outside
    $preserved = @(
        (Join-Path $runtime '.ci-owned'),
        (Join-Path $runtime 'native-sdk/sdk.aar'),
        (Join-Path $runtime 'native-sdk/receipt.json'),
        (Join-Path $runtime 'evidence/build.json'),
        (Join-Path $runtime 'cargo-home/registry/cache/dependency.crate'),
        (Join-Path $runtime 'cargo-target-extra/keep.bin'),
        (Join-Path $env:DANSHENG_CI_ROOT 'cache/main/synthetic-job/cargo-home/registry/cache/dependency.crate'),
        (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987654/synthetic-job/1/cargo-target/keep.bin'),
        (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987654/other-job/2/cargo-target/keep.bin'),
        (Join-Path $env:DANSHENG_CI_ROOT 'runtime/987653/synthetic-job/2/cargo-target/keep.bin'),
        (Join-Path $outside 'keep.bin')
    )
    foreach ($path in $preserved | Select-Object -Skip 1) { Put $path }
    $hashes = @{}
    foreach ($path in $preserved) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
    & $cleanup
    foreach ($name in @('cargo-target', 'cargo-arm64', 'cargo-x86')) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $runtime $name))) 'Build output was not removed.'
    }
    foreach ($path in $preserved) {
        Assert ((Get-FileHash -LiteralPath $path).Hash -ceq $hashes[$path]) 'Cleanup changed preserved bytes.'
    }
    & $cleanup # Missing output directories are an idempotent success.
    Seed

    # Initialization failure must skip even when the layout environment is invalid.
    $env:DANSHENG_TASK_RUNTIME = ''
    $env:DANSHENG_CI_ROOT = 'relative-invalid'
    & $cleanup
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'cargo-target/debug/output.bin')) 'Empty runtime did not skip cleanup.'
    $env:DANSHENG_TASK_RUNTIME = $runtime
    Reject { & $cleanup } 'absolute'
    $env:DANSHENG_CI_ROOT = Join-Path $fixture 'ci'

    foreach ($identity in @('wrong', '987653/synthetic-job/2', '987654/other-job/2', '987654/synthetic-job/1')) {
        Put (Join-Path $runtime '.ci-owned') $identity
        Reject { & $cleanup } 'marker differs'
    }
    Seed
    Remove-Item -LiteralPath (Join-Path $runtime '.ci-owned') -Force
    Reject { & $cleanup } 'marker differs'
    Seed
    $env:DANSHENG_TASK_RUNTIME = $outside
    Reject { & $cleanup } 'exact CI run/job/attempt'
    $env:DANSHENG_TASK_RUNTIME = 'relative-runtime'
    Reject { & $cleanup } 'absolute'
    $env:DANSHENG_TASK_RUNTIME = $runtime

    # A linked ancestor, fixed output, or descendant all fail before any deletion.
    $ancestorLink = Join-Path $fixture 'linked-ci'
    Link $ancestorLink $env:DANSHENG_CI_ROOT
    $env:DANSHENG_CI_ROOT = $ancestorLink
    $env:DANSHENG_TASK_RUNTIME = Join-Path $ancestorLink 'runtime/987654/synthetic-job/2'
    Reject { & $cleanup } 'links'
    $env:DANSHENG_CI_ROOT = Join-Path $fixture 'ci'
    $env:DANSHENG_TASK_RUNTIME = $runtime
    Unlink $ancestorLink

    $outputLink = Join-Path $runtime 'cargo-x86'
    $parked = Join-Path $runtime 'parked-output'
    Move-Item -LiteralPath $outputLink -Destination $parked
    Link $outputLink $parked
    Reject { & $cleanup } 'links'
    Unlink $outputLink
    Move-Item -LiteralPath $parked -Destination $outputLink

    $nestedLink = Join-Path $runtime 'cargo-x86/debug/.linked'
    Link $nestedLink $outside
    Reject { & $cleanup } 'links'
    Assert ((Get-FileHash -LiteralPath (Join-Path $outside 'keep.bin')).Hash -ceq $hashes[(Join-Path $outside 'keep.bin')]) 'Link rejection changed outside data.'
    Unlink $nestedLink

    $danglingLink = Join-Path $runtime 'cargo-x86/debug/.dangling'
    [IO.File]::CreateSymbolicLink($danglingLink, (Join-Path $outside 'missing-file')) | Out-Null
    $links.Add($danglingLink)
    Reject { & $cleanup } 'links'
    Unlink $danglingLink

    # A fixed output occupied by a regular file is suspicious, not a build tree.
    Move-Item -LiteralPath $outputLink -Destination $parked
    Put $outputLink
    $message = ''
    try { & $cleanup } catch { $message = $_.Exception.Message }
    Assert ($message -match 'must be a directory') 'Accepted a regular file as a build output directory.'
    Assert (Test-Path -LiteralPath (Join-Path $runtime 'cargo-target/debug/output.bin')) 'File rejection partially deleted outputs.'
    Remove-Item -LiteralPath $outputLink
    Move-Item -LiteralPath $parked -Destination $outputLink

    # A marker symlink must not borrow the contents of a plain external file.
    $marker = Join-Path $runtime '.ci-owned'
    $externalMarker = Join-Path $outside 'marker'
    Put $externalMarker '987654/synthetic-job/2'
    Remove-Item -LiteralPath $marker -Force
    [IO.File]::CreateSymbolicLink($marker, $externalMarker) | Out-Null
    $links.Add($marker)
    Reject { & $cleanup } 'links'
    Unlink $marker
    Seed
    & $cleanup
    Assert ([Environment]::GetEnvironmentVariable('HOME') -ceq $inheritedSystemHome) 'Changed system HOME.'
    Assert ([Environment]::GetEnvironmentVariable('USERPROFILE') -ceq $inheritedUserProfile) 'Changed USERPROFILE.'
    Write-Host "Build output fixtures passed: $checks assertions."
} finally {
    foreach ($link in @($links.ToArray())) { Unlink $link }
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $fullFixture = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($fullFixture) -notlike 'dansheng build outputs *') {
        throw 'Refusing to remove a fixture outside the designated temporary directory.'
    }
    if (Test-Path -LiteralPath $fullFixture) { Remove-Item -LiteralPath $fullFixture -Recurse -Force }
}
