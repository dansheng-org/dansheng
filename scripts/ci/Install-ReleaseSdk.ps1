#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$layout = Get-DanshengCiLayout
Assert-DanshengCiRuntime $layout
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$app = Join-Path $repo 'apps/dansheng_app'
$manifest = Get-Content -LiteralPath (Join-Path $repo '.github/prerelease-sdk.json') -Raw | ConvertFrom-Json
$uri = [uri]$manifest.uri
if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'SDK acquisition must use credential-free HTTPS.'
}
if ($manifest.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'An exact SDK archive SHA-256 is required.' }

$archive = Join-Path $layout.runtime 'release-sdk.zip'
$sdk = Join-Path $layout.runtime 'native-sdk'
$install = @{
    Action = 'Install'
    Archive = $archive
    ArtifactDirectory = $sdk
    CoreToolsRoot = Join-Path $sdk 'validation-tools'
    Sha256 = $manifest.sha256
}
$parts = $uri.AbsolutePath.Trim('/') -split '/'
if ($uri.Host -eq 'github.com' -and $parts.Count -eq 6 -and
    "$($parts[0])/$($parts[1])" -eq $env:GITHUB_REPOSITORY -and
    $parts[2] -ceq 'releases' -and $parts[3] -ceq 'download') {
    $tag = [uri]::UnescapeDataString($parts[4])
    $asset = [uri]::UnescapeDataString($parts[5])
    if ($tag -notmatch '^[a-z0-9][a-z0-9._+-]*$' -or $asset -notmatch '^[a-z0-9][a-z0-9._+-]*\.zip$') {
        throw 'Use an exact GitHub release tag and SDK ZIP asset name.'
    }
    gh release download $tag --repo $env:GITHUB_REPOSITORY --pattern $asset --output $archive
    if ($LASTEXITCODE -ne 0) { throw 'Could not download the pinned SDK from the organization release.' }
} else {
    $install.Uri = $uri.AbsoluteUri
}
& (Join-Path $app 'scripts/prerelease-sdk.ps1') @install
