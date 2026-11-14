function Get-AdapterSourceHash([string]$CoreRoot) {
    $base=Join-Path $CoreRoot 'platform/android'
    $names=@('build.gradle.kts','settings.gradle.kts','gradle.properties','adapter/build.gradle.kts')
    $names+=@(Get-ChildItem -LiteralPath (Join-Path $base 'adapter/src/main') -Recurse -File | ForEach-Object {
        [IO.Path]::GetRelativePath($base,$_.FullName).Replace('\','/')
    })
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $manifest=($names|ForEach-Object { "$((Get-FileHash -LiteralPath (Join-Path $base $_)).Hash.ToLowerInvariant())  $_" }) -join "`n"
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
}
