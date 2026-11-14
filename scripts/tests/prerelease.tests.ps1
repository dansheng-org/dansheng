#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$app = Split-Path -Parent $scripts
. (Join-Path $scripts 'prerelease-common.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('dansheng-prerelease-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$checks = [Collections.Generic.List[string]]::new()
function Reject([scriptblock]$Action, [string]$Message, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notlike "*$Message*") { throw }; $rejected = $true }
    if (-not $rejected) { throw "Expected rejection: $Name" }
    $checks.Add($Name)
}
$id = Get-DanshengPrereleaseIdentity -AppRoot $app -Commit ('a' * 40)
if ($id.tag -notmatch '^prerelease-v\d+\.\d+\.\d+-build\.\d+-a{12}$' -or $id.apk_name -notmatch '-arm64-prerelease\.apk$') { throw 'Immutable prerelease identity is invalid.' }
$checks.Add('version and exact App SHA form an immutable tag')
Reject { Get-DanshengPrereleaseIdentity -AppRoot $app -Commit 'main' } 'exact App Git commit' 'mutable App ref rejected'
$lock = Get-Content -LiteralPath (Join-Path $app 'core.lock.json') -Raw | ConvertFrom-Json
$names = @(Get-DanshengPrereleaseFiles $lock)
if (@($names | Where-Object { $_ -match 'credentials|signing|\.p12|\.dpapi|^jni/' }).Count) { throw 'Private or staging paths entered SDK allowlist.' }
$checks.Add('SDK allowlist excludes private files and native staging')
$unsafeLock = $lock | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$unsafeLock.artifact.name = '../credentials.txt'
Reject { Get-DanshengPrereleaseFiles $unsafeLock } 'Unsafe SDK path' 'unsafe lock path rejected before archive operations'
$cases = @(
    @{name='wrong archive hash'; paths=$names; badHash=$true; message='SHA-256 differs'},
    @{name='path traversal'; paths=@($names + '../credentials.txt'); message='unexpected paths'},
    @{name='duplicate archive entry'; paths=@($names + $names[0]); message='unexpected paths'},
    @{name='missing resource'; paths=@($names | Select-Object -Skip 1); message='unexpected paths'},
    @{name='symbolic link entry'; paths=$names; linked=$true; message='linked entry'}
)
foreach ($case in $cases) {
    $archive = Join-Path $root ($checks.Count.ToString() + '.zip')
    $destination = Join-Path $root ('sdk-' + $checks.Count)
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $case.paths) {
            $entry = $zip.CreateEntry($name)
            if ($case.linked -and $name -ceq $names[0]) { $entry.ExternalAttributes = [int](0xA000 -shl 16) }
            $stream = $entry.Open()
            try { $stream.Write([Text.Encoding]::UTF8.GetBytes('synthetic payload')) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $hash = if ($case.badHash) { '0' * 64 } else { (Get-FileHash -LiteralPath $archive).Hash }
    Reject { & (Join-Path $scripts 'prerelease-sdk.ps1') -Action Install -Archive $archive -ArtifactDirectory $destination -CoreToolsRoot $root -Sha256 $hash } $case.message $case.name
    if (Test-Path -LiteralPath $destination) { throw 'Rejected archive wrote an SDK directory.' }
}
$existing = Join-Path $root 'existing-sdk'
[void][IO.Directory]::CreateDirectory($existing)
$sentinel = Join-Path $existing 'preserve.txt'
[IO.File]::WriteAllText($sentinel, 'existing SDK')
Reject { & (Join-Path $scripts 'prerelease-sdk.ps1') -Action Install -Archive $archive -ArtifactDirectory $existing -CoreToolsRoot $root -Sha256 ('0' * 64) } 'existing SDKs are preserved' 'existing SDK is not overwritten'
if ([IO.File]::ReadAllText($sentinel) -cne 'existing SDK') { throw 'Existing SDK was changed.' }
[pscustomobject]@{passed=$checks.Count;checks=@($checks);synthetic_archives_only=$true;fixture=$root} | ConvertTo-Json -Depth 4
$global:LASTEXITCODE = 0
