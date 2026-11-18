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

# Compiled outputs kept across runs, one directory per lane, job and OS. A fresh
# target per run recompiled every dependency and, on the Windows desktop runner,
# recreated ~120 executables that each pay a launch-time reputation check (1-4 s,
# not covered by Defender folder exclusions): ~20 min per native job. Cargo's
# fingerprints keep reuse correct and its build-directory lock serializes
# concurrent runners. The main and checks lanes never share outputs, and this
# is not a dependency cache (nothing here is ever seeded or published).
function Get-DanshengCiBuildCacheRoot($Layout) {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
    $job = [IO.Path]::GetFileName($Layout.cache)
    Assert-CiPlainPath (Join-Path $Layout.root "build-cache/$($Layout.lane)/$job-$os")
}

# Release and publishing jobs always build from an empty per-run target, so a
# published artifact never depends on outputs kept from earlier runs.
function Test-DanshengCiKeepsBuildOutputs([string]$Role) { $Role -notin @('Release', 'Publish') }

function Get-DanshengCiCargoTarget($Layout, [string]$Role) {
    if (Test-DanshengCiKeepsBuildOutputs $Role) {
        return Assert-CiPlainPath (Join-Path (Get-DanshengCiBuildCacheRoot $Layout) 'cargo-target')
    }
    Assert-CiPlainPath (Join-Path $Layout.runtime 'cargo-target')
}

# Managed enumeration never descends into links (they are skipped, not followed)
# and is far faster than a Get-ChildItem pipeline over 100k+ cache files.
function New-CiTreeEnumeration {
    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.IgnoreInaccessible = $true
    $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
    $options
}

function Get-CiDirectoryBytes([string]$Path) {
    [long]$bytes = 0
    foreach ($file in [IO.DirectoryInfo]::new($Path).EnumerateFiles('*', (New-CiTreeEnumeration))) { $bytes += $file.Length }
    $bytes
}

# Delete a CI-owned tree. Links inside it are removed, never followed, so data
# outside the tree survives. Read-only entries (Windows attributes, Unix
# directories without owner write) are made writable without following links.
function Remove-CiTree([string]$Path) {
    $full = Assert-CiPlainPath $Path
    if (-not [IO.Directory]::Exists($full)) { return }
    try { [IO.Directory]::Delete($full, $true); return }
    catch [System.IO.DirectoryNotFoundException] { return }
    catch { if (-not [IO.Directory]::Exists($full)) { return } }
    if ($IsWindows) {
        foreach ($entry in [IO.DirectoryInfo]::new($full).EnumerateFileSystemInfos('*', (New-CiTreeEnumeration))) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReadOnly) { $entry.Attributes = $entry.Attributes -band -bnot [IO.FileAttributes]::ReadOnly }
        }
    } else {
        # GNU chmod -R does not follow symbolic links met during traversal.
        & chmod -R u+rwX -- $full 2>$null
    }
    [IO.Directory]::Delete($full, $true)
}

# A kept build or dependency directory grows with every dependency and toolchain
# change; start it over once it passes the budget instead of letting the disk fill.
function Limit-DanshengCiBuildCache([string]$Path, [long]$MaxBytes) {
    $full = Assert-CiPlainPath $Path
    if (-not [IO.Directory]::Exists($full)) { return }
    $bytes = Get-CiDirectoryBytes $full
    if ($bytes -gt $MaxBytes) {
        Write-Host ("Kept directory {0} reached {1:N1} GiB; starting it over." -f [IO.Path]::GetFileName($full), ($bytes / 1GB))
        Remove-CiTree $full
    }
}

# Retention: each job keeps only its most recently finished runtime (for
# inspecting the last run). Clear-Runtime.ps1 marks its own runtime finished and
# then removes the finished runtimes of the same job (-Superseded). A runner that
# is killed, loses power or fails before exporting its runtime never marks it,
# so initialization also removes unfinished runtimes untouched for longer than
# any job may run (Actions caps jobs at 6 h). Running runtimes are never
# finished-marked and are younger than the cutoff, so neither pass touches them.
# Failures only warn: another runner may be removing the same directory.
function Clear-DanshengCiRuntimes($Layout, [switch]$Superseded, [TimeSpan]$MaxAge = [TimeSpan]::FromHours(24)) {
    $root = Assert-CiPlainPath (Join-Path $Layout.root 'runtime')
    if (-not [IO.Directory]::Exists($root)) { return }
    $cutoff = [DateTime]::UtcNow - $MaxAge
    $link = [IO.FileAttributes]::ReparsePoint
    $jobName = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Layout.runtime))
    function Test-Stale([IO.FileSystemInfo]$Item) { $Item.LastWriteTimeUtc -lt $cutoff }
    function Test-Finished([IO.DirectoryInfo]$Item) {
        $finished = [IO.FileInfo]::new((Join-Path $Item.FullName '.ci-finished'))
        $finished.Exists -and -not ($finished.Attributes -band $link)
    }
    function Remove-EmptyDirectory([IO.DirectoryInfo]$Item) {
        try { $Item.Refresh(); if (-not $Item.EnumerateFileSystemInfos().GetEnumerator().MoveNext()) { $Item.Delete() } } catch { }
    }
    $removed = 0
    foreach ($run in [IO.DirectoryInfo]::new($root).GetDirectories()) {
        if (($run.Attributes -band $link) -or $run.Name -notmatch '^\d+$') { continue }
        foreach ($job in $run.GetDirectories()) {
            if (($job.Attributes -band $link) -or $job.Name -notmatch '^[A-Za-z0-9_-]+$') { continue }
            if ($Superseded -and $job.Name -cne $jobName) { continue }
            foreach ($attempt in $job.GetDirectories()) {
                if (($attempt.Attributes -band $link) -or $attempt.Name -notmatch '^\d+$') { continue }
                if ($attempt.FullName -ceq $Layout.runtime) { continue }
                if ($Superseded) {
                    if (-not (Test-Finished $attempt)) { continue }
                } else {
                    if ((Test-Finished $attempt) -or -not (Test-Stale $attempt)) { continue }
                    $marker = [IO.FileInfo]::new((Join-Path $attempt.FullName '.ci-owned'))
                    if ($marker.Exists -and -not (Test-Stale $marker)) { continue }
                }
                try { Remove-CiTree $attempt.FullName; $removed++ }
                catch { Write-Warning "CI runtime $($run.Name)/$($job.Name)/$($attempt.Name) was not removed: $($_.Exception.Message)" }
            }
            Remove-EmptyDirectory $job
        }
        # A new attempt of an old run could be creating its directories right now.
        $run.Refresh(); if (Test-Stale $run) { Remove-EmptyDirectory $run }
    }
    $kind = if ($Superseded) { "superseded $jobName" } else { 'stale unfinished' }
    if ($removed) { Write-Host "Removed $removed $kind CI runtime(s)." }
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
