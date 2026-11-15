#Requires -Version 7.0
[CmdletBinding()]
param([string]$AppRoot = (Join-Path $PSScriptRoot '../../apps/dansheng_app'))
$ErrorActionPreference = 'Stop'
$AppRoot = (Resolve-Path -LiteralPath $AppRoot).Path
$files = @(foreach ($directory in @('lib','test','pigeons')) {
    Get-ChildItem -LiteralPath (Join-Path $AppRoot $directory) -Recurse -File -Filter '*.dart' | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($AppRoot, $_.FullName).Replace('\','/')
        if ($relative -cne 'lib/bridge.g.dart') { $relative }
    }
})
Push-Location $AppRoot
try {
    # dart.bat runs through cmd.exe on Windows: relative paths, at most 32/file batch.
    for ($start = 0; $start -lt $files.Count; $start += 32) {
        $batch = @($files[$start..([Math]::Min($start + 31, $files.Count - 1))])
        & dart format --output=none --set-exit-if-changed @batch
        if ($LASTEXITCODE -ne 0) { throw "Handwritten Dart formatting failed (batch $([int]($start / 32) + 1))." }
    }
} finally { Pop-Location }
$global:LASTEXITCODE = 0
