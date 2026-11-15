#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('SourceSdk','Release')][string]$Mode,
    [string]$Commit
)
. (Join-Path $PSScriptRoot 'Public-Caches.ps1')
$layout = Get-DanshengCiLayout
Assert-DanshengCiRuntime $layout
$cache = $layout.cache
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$app = Join-Path $repo 'apps/dansheng_app'
$core = Join-Path $repo 'core'
# Production scripts isolate their Cargo/Pub/Gradle homes beneath RuntimeRoot.
# Reuse only public dependency bytes; do not change their source/output guards.
Sync-CiPublicDependencies $cache $layout.runtime -Direction CacheToRuntime
try {
    if ($Mode -eq 'SourceSdk') {
        if ($Commit -notmatch '^[0-9a-f]{40}$') { throw 'Pass the exact checked-out source SHA.' }
        & (Join-Path $app 'scripts/prerelease-source-sdk.ps1') -RuntimeRoot $layout.runtime -Commit $Commit
    } else {
        & (Join-Path $app 'scripts/build-prerelease.ps1') -RuntimeRoot $layout.runtime `
            -ArtifactDirectory (Join-Path $layout.runtime 'native-sdk') -CoreToolsRoot (Join-Path $core 'tools/workspace') `
            -CoreRoot $core -LockFile (Join-Path $layout.runtime 'native-sdk/core.lock.json')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Android production script failed.' }
} finally {
    Sync-CiPublicDependencies $layout.runtime $cache -Direction RuntimeToCache
}
