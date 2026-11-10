# Development launcher: use an installed Gradle 9.7.1; never download runtimes into core.
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GradleArguments)
$ErrorActionPreference = 'Stop'
$DanshengGradle = if ($env:GRADLE_HOME) {
    Join-Path $env:GRADLE_HOME 'bin/gradle.bat'
} else {
    Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.gradle/wrapper/dists/gradle-9.7.1-bin') -Filter gradle.bat -Recurse |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $DanshengGradle -or -not (Test-Path -LiteralPath $DanshengGradle)) {
    throw 'Install Gradle 9.7.1 or set GRADLE_HOME to its installation directory.'
}
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = 'C:/Android/Sdk' }
Push-Location -LiteralPath $PSScriptRoot
try {
    & $DanshengGradle @GradleArguments
    $DanshengBuildExit = $LASTEXITCODE
} finally { Pop-Location }
exit $DanshengBuildExit
