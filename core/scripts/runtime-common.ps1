# Shared path policy for local tools. This file does not create directories,
# provision caches, import accounts or launch a process.
function Get-DanshengCheckedPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path -match '[\x00-\x1f"*?]') {
        throw 'Use a fully qualified path without control characters, quotes or wildcards'
    }
    $absolute = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if (-not $absolute -or $absolute -eq [IO.Path]::GetPathRoot($absolute).TrimEnd('\','/')) {
        throw 'A drive or filesystem root is not a runtime directory'
    }
    for ($ancestor = $absolute; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Linked runtime paths or ancestors are refused'
            }
        }
    }
    $absolute
}

function Test-DanshengPathWithin {
    param([string]$Parent,[string]$Child,[switch]$AllowEqual)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/')
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\','/')
    ($AllowEqual -and $childPath.Equals($parentPath,$comparison)) -or
        $childPath.StartsWith($parentPath + [IO.Path]::DirectorySeparatorChar,$comparison)
}

function Get-DanshengSourceBoundary {
    param([Parameter(Mandatory)][string]$Root)
    $source=Get-DanshengCheckedPath $Root
    for($cursor=$source;$cursor;$cursor=[IO.Path]::GetDirectoryName($cursor)){
        if(Test-Path -LiteralPath (Join-Path $cursor '.git')){
            Import-Module (Join-Path $PSScriptRoot '../tools/workspace/Dansheng.Workspace.psm1') -DisableNameChecking
            $repo=Get-DsNativeRepository -Path $source -Component core
            return [pscustomobject]@{source=$source;checkout=$repo.checkout_root;primary=(Split-Path -Parent $repo.common_dir);isolated=([bool]$repo.module -or (Test-Path -LiteralPath (Join-Path $repo.checkout_root '.git') -PathType Leaf))}
        }
    }
    # Non-Git source distributions retain their explicit local runtime support.
    [pscustomobject]@{source=$source;checkout=$source;primary=$null;isolated=$false}
}

function Resolve-DanshengRuntimeRoot {
    param([Parameter(Mandatory)][string]$Root,[string]$RuntimeRoot)
    $boundary = Get-DanshengSourceBoundary $Root
    $sourceRoot = $boundary.checkout
    if (-not $RuntimeRoot) { $RuntimeRoot = $env:DANSHENG_TASK_RUNTIME }
    $linkedTask = $boundary.isolated
    if (-not $RuntimeRoot) {
        if ($linkedTask) { throw 'Enter the registered task using checkout root scripts/Enter-Dansheng.ps1 or pass its independent -RuntimeRoot' }
        $RuntimeRoot = Join-Path $sourceRoot '.local/runtime'
    }
    $runtime = Get-DanshengCheckedPath $RuntimeRoot
    if (Test-DanshengPathWithin $runtime $sourceRoot -AllowEqual) {
        throw 'Runtime directory cannot contain the source checkout'
    }
    if ($linkedTask -and (Test-DanshengPathWithin $sourceRoot $runtime)) {
        throw 'Task runtime data must stay outside the source checkout'
    }
    if ($linkedTask -and $boundary.primary) {
        $primary = $boundary.primary
        if ((Test-DanshengPathWithin $primary $runtime -AllowEqual) -or
            (Test-DanshengPathWithin $runtime $primary -AllowEqual)) {
            throw 'Task runtime data must stay separate from the primary repository'
        }
    }
    if ($env:DANSHENG_TASK_RUNTIME -and -not (Test-DanshengPathWithin (Get-DanshengCheckedPath $env:DANSHENG_TASK_RUNTIME) $runtime -AllowEqual)) {
        throw 'Runtime directory differs from the entered task runtime'
    }
    $runtime
}

function Get-DanshengRuntimeOutput {
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$Path)
    $runtime = Get-DanshengCheckedPath $RuntimeRoot
    $output = Get-DanshengCheckedPath $Path
    if (-not (Test-DanshengPathWithin $runtime $output)) {
        throw 'Output must be a child of the selected runtime directory'
    }
    $output
}

function Resolve-DanshengLabProfile {
    param([Parameter(Mandatory)][string]$Root,[string]$Profile,[string]$RuntimeRoot)
    if (-not $Profile) { $Profile = $env:DANSHENG_LAB_PROFILE }
    if (-not $Profile -and ($RuntimeRoot -or $env:DANSHENG_TASK_RUNTIME)) {
        $Profile = Join-Path (Resolve-DanshengRuntimeRoot -Root $Root -RuntimeRoot $RuntimeRoot) 'profiles/lab'
    }
    if (-not $Profile) { $Profile = $env:DANSHENG_PROFILE }
    if (-not $Profile) {
        throw 'Enter the registered task or pass an independent -RuntimeRoot or explicit -Profile'
    }
    $profilePath = Get-DanshengCheckedPath $Profile
    $boundary=Get-DanshengSourceBoundary $Root
    if ((Test-DanshengPathWithin $boundary.checkout $profilePath -AllowEqual) -or
        ($boundary.isolated -and $boundary.primary -and (Test-DanshengPathWithin $boundary.primary $profilePath -AllowEqual))) {
        throw 'Lab profile must stay outside the source checkout'
    }
    if ($RuntimeRoot -or $env:DANSHENG_TASK_RUNTIME) {
        $runtime = Resolve-DanshengRuntimeRoot -Root $Root -RuntimeRoot $RuntimeRoot
        if (-not (Test-DanshengPathWithin $runtime $profilePath)) {
            throw 'Lab profile must belong to the selected task runtime'
        }
    }
    $profilePath
}
