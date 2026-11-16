#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

function Test-CiPinnedNdk([string]$Properties) {
    # Google's r30 beta3 archive uses a prerelease suffix in Pkg.Revision.
    [regex]::IsMatch($Properties, '(?m)^Pkg\.Revision\s*=\s*30\.0\.16138531(?:-beta3)?\s*$')
}

function Assert-CiPlainPath([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'CI paths must be absolute.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')) { throw 'A filesystem root is not a CI directory.' }
    for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'CI runtime/cache paths must not contain links.'
        }
    }
    $full
}

function Get-DanshengCiLayout {
    if (-not $env:DANSHENG_CI_ROOT) { throw 'Runner parent must supply DANSHENG_CI_ROOT.' }
    $root = Assert-CiPlainPath $env:DANSHENG_CI_ROOT
    if ($env:GITHUB_RUN_ID -notmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^\d+$' -or $env:GITHUB_JOB -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'Expected GitHub run, attempt and job identities.'
    }
    $runtime = Assert-CiPlainPath (Join-Path $root "runtime/$env:GITHUB_RUN_ID/$env:GITHUB_JOB/$env:GITHUB_RUN_ATTEMPT")
    $lane = if ($env:GITHUB_REF -eq 'refs/heads/main' -and $env:GITHUB_EVENT_NAME -ne 'pull_request') { 'main' } else { 'checks' }
    $cache = Assert-CiPlainPath (Join-Path $root "cache/$lane/$env:GITHUB_JOB")
    [pscustomobject]@{ root=$root; runtime=$runtime; cache=$cache; lane=$lane; identity="$env:GITHUB_RUN_ID/$env:GITHUB_JOB/$env:GITHUB_RUN_ATTEMPT" }
}

# Where Cargo writes build outputs for a role. Everything stays in the run's own
# runtime, except Windows native checks: that runner is a desktop machine where
# every newly created executable pays a launch-time reputation check (1-4 s,
# not covered by Defender folder exclusions), and a fresh target recreated ~120
# executables (build scripts and test harnesses) per run, ~20 min per job.
# There, one build directory per lane is kept across runs. Cargo's fingerprints
# keep it correct and its build-directory lock serializes concurrent users; the
# main and checks lanes never share outputs, and it is not a dependency cache.
function Get-DanshengCiCargoTarget($Layout, [string]$Role) {
    if ($IsWindows -and $Role -eq 'Native') {
        return Assert-CiPlainPath (Join-Path $Layout.root "build-cache/$($Layout.lane)/native-windows/cargo-target")
    }
    Assert-CiPlainPath (Join-Path $Layout.runtime 'cargo-target')
}

# A kept build directory grows with every dependency and toolchain change;
# start it over once it passes the budget instead of letting the disk fill.
function Limit-DanshengCiBuildCache([string]$Path, [long]$MaxBytes) {
    $full = Assert-CiPlainPath $Path
    if (-not (Test-Path -LiteralPath $full)) { return }
    $bytes = (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($bytes -gt $MaxBytes) {
        Write-Host ("Kept build directory reached {0:N1} GiB; starting it over." -f ($bytes / 1GB))
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

function Assert-DanshengCiRuntime($Layout) {
    if (-not $env:DANSHENG_TASK_RUNTIME -or (Assert-CiPlainPath $env:DANSHENG_TASK_RUNTIME) -cne $Layout.runtime) {
        throw 'Refusing a runtime outside this exact CI run/job/attempt.'
    }
    $marker = Join-Path $Layout.runtime '.ci-owned'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or [IO.File]::ReadAllText($marker) -cne $Layout.identity) {
        throw 'CI runtime ownership marker differs.'
    }
}

function Set-CiRuntimePermissions($Layout) {
    Assert-DanshengCiRuntime $Layout
    $taskHome = Assert-CiPlainPath (Join-Path $Layout.runtime 'home')
    if (-not $env:DANSHENG_TASK_HOME -or (Assert-CiPlainPath $env:DANSHENG_TASK_HOME) -cne $taskHome) {
        throw 'Permission changes require this runtime task home.'
    }
    # Fixed runtime paths only. Never chmod the runner account's HOME/USERPROFILE.
    & chmod 700 $Layout.runtime $taskHome
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict CI runtime permissions.' }
}
