#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Pack','Install')][string]$Action,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$CoreToolsRoot,
    [string]$Uri,
    [string]$Sha256
)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'prerelease-common.ps1')
$lock = Get-Content -LiteralPath (Join-Path $app 'core.lock.json') -Raw | ConvertFrom-Json
$files = @(Get-DanshengPrereleaseFiles $lock)
$Archive = [IO.Path]::GetFullPath($Archive)
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
if ($Action -eq 'Pack') {
    $null = Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $ArtifactDirectory -CoreToolsRoot $CoreToolsRoot
    if (Test-Path -LiteralPath $Archive) { throw 'SDK archives are immutable; choose a fresh output path.' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Archive))
    $zip = [IO.Compression.ZipFile]::Open($Archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $files) {
            $entry = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
            $sourcePath = if ($name.StartsWith('validation-tools/')) { Join-Path $CoreToolsRoot ($name.Substring('validation-tools/'.Length)) } else { Join-Path $ArtifactDirectory $name }
            $source = [IO.File]::OpenRead($sourcePath)
            $target = $entry.Open()
            try { $source.CopyTo($target) } finally { $source.Dispose(); $target.Dispose() }
        }
    } finally { $zip.Dispose() }
} else {
    if ($Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'An exact SDK archive SHA-256 is required.' }
    if (Test-Path -LiteralPath $ArtifactDirectory) { throw 'Install into a fresh SDK directory; existing SDKs are preserved.' }
    if ($Uri) {
        $url = [Uri]$Uri
        if (-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https' -or $url.UserInfo -or $url.Query -or $url.Fragment) {
            throw 'SDK acquisition must use credential-free HTTPS.'
        }
        if (Test-Path -LiteralPath $Archive) { throw 'Download path already exists.' }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Archive))
        Invoke-WebRequest -Uri $url -OutFile $Archive
    }
    if ((Get-FileHash -LiteralPath $Archive).Hash -ine $Sha256) { throw 'Downloaded SDK archive SHA-256 differs.' }
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $names = @($zip.Entries | ForEach-Object FullName)
        if ($names.Count -ne $files.Count -or @($names | Select-Object -Unique).Count -ne $files.Count -or
            @($names | Where-Object { $_ -cnotin $files }).Count) { throw 'SDK archive contains missing, duplicate or unexpected paths.' }
        foreach ($entry in $zip.Entries) {
            if ($entry.Length -lt 1 -or $entry.Length -gt 256MB -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'SDK archive contains an empty, oversized or linked entry.'
            }
        }
        [void][IO.Directory]::CreateDirectory($ArtifactDirectory)
        foreach ($entry in $zip.Entries) {
            $destination = Join-Path $ArtifactDirectory $entry.FullName
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
        }
    } finally { $zip.Dispose() }
    $null = Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $ArtifactDirectory -CoreToolsRoot $CoreToolsRoot
}
[pscustomobject]@{ archive=$Archive; sha256=(Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant(); core_commit=$lock.core.commit; state=$lock.state } | ConvertTo-Json
