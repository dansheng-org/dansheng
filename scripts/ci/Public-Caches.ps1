#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'Common.ps1')

function Sync-CiPublicDependencies(
    [string]$SourceRoot, [string]$DestinationRoot,
    [ValidateSet('CacheToRuntime','RuntimeToCache','SeedToCache')][string]$Direction,
    [ValidateSet('Cargo','Pub')][string[]]$SeedKinds = @('Cargo','Pub')
) {
    # The managed walk preserves the fixed allowlist and checks every destination
    # ancestor per entry. Avoid thousands of PowerShell provider/pipeline calls,
    # rather than memoizing path safety or parallelizing filesystem mutations.
    if (-not ('Dansheng.Ci.PublicDependencyCache' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'Public-Caches.cs')
    }
    $copied = [Dansheng.Ci.PublicDependencyCache]::Sync($SourceRoot, $DestinationRoot, $Direction, $SeedKinds)
    Write-Host "Public dependency cache synchronization complete ($copied new files)."
}
