#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

# Initialization may fail before it exports an owned runtime.
if (-not $env:DANSHENG_TASK_RUNTIME) { return }

. (Join-Path $PSScriptRoot 'Common.ps1')
$layout = Get-DanshengCiLayout

function Assert-BuildOutputOwnership {
    # Common validates the runtime's ancestors; the marker itself must also be plain.
    $null = Assert-CiPlainPath (Join-Path $layout.runtime '.ci-owned')
    Assert-DanshengCiRuntime $layout
}

function Assert-BuildOutputTree([string]$Path) {
    $full = Assert-CiPlainPath $Path
    if ([IO.Path]::GetDirectoryName($full) -cne $layout.runtime -or
        [IO.Path]::GetFileName($full) -cnotin @('cargo-target', 'cargo-arm64', 'cargo-x86')) {
        throw 'Build output must be a fixed direct child of this runtime.'
    }
    try { $item = Get-Item -LiteralPath $full -Force }
    catch [System.Management.Automation.ItemNotFoundException] { return }
    if (-not $item.PSIsContainer) { throw 'Build output must be a directory.' }

    # Walk one directory at a time, rejecting links before any descent (including
    # hidden entries and dangling links). Do not recurse through reparse points.
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($full)
    while ($pending.Count) {
        $directory = $pending.Pop()
        $null = Assert-CiPlainPath $directory
        foreach ($child in Get-ChildItem -LiteralPath $directory -Force) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Build output descendants must not contain links.'
            }
            if ($child.PSIsContainer) { $pending.Push($child.FullName) }
        }
    }
}

Assert-BuildOutputOwnership
$outputs = @('cargo-target', 'cargo-arm64', 'cargo-x86') | ForEach-Object { Join-Path $layout.runtime $_ }
# Validate every candidate before deleting anything, so a bad later tree fails closed.
foreach ($output in $outputs) { Assert-BuildOutputTree $output }
foreach ($output in $outputs) {
    Assert-BuildOutputOwnership
    Assert-BuildOutputTree $output
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }
}
