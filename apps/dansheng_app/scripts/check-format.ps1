#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$appRoot=Split-Path -Parent $PSScriptRoot
$files=@(foreach($directory in @('lib','test','pigeons')){
    Get-ChildItem -LiteralPath (Join-Path $appRoot $directory) -Recurse -File -Filter '*.dart' | Where-Object {
        [IO.Path]::GetRelativePath($appRoot,$_.FullName).Replace('\','/') -ne 'lib/bridge.g.dart'
    } | Select-Object -ExpandProperty FullName
})
# Pigeon owns its generated Dart style; generation consistency is checked separately.
& dart format --output=none --set-exit-if-changed @files
exit $LASTEXITCODE
