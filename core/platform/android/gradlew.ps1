# Development launcher: use a pinned read-only Gradle 9.7.1 installation.
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GradleArguments)
$ErrorActionPreference = 'Stop'
$DanshengGradleName=if($IsWindows){'gradle.bat'}else{'gradle'}
$DanshengUserHome=if($env:HOME){$env:HOME}else{[Environment]::GetFolderPath('UserProfile')}
$DanshengGradle = if ($env:GRADLE_HOME) {
    Join-Path $env:GRADLE_HOME "bin/$DanshengGradleName"
} else {
    $DanshengGradleRoots=@(
        $env:DANSHENG_GRADLE_INSTALL_ROOT,
        $(if($env:DANSHENG_CACHE_ROOT){Join-Path $env:DANSHENG_CACHE_ROOT 'gradle/wrapper/dists/gradle-9.7.1-bin'}),
        $(if($env:GRADLE_USER_HOME){Join-Path $env:GRADLE_USER_HOME 'wrapper/dists/gradle-9.7.1-bin'}),
        $(if($DanshengUserHome){Join-Path $DanshengUserHome '.gradle/wrapper/dists/gradle-9.7.1-bin'}),
        $(if($IsWindows){'D:/DevCache/gradle/wrapper/dists/gradle-9.7.1-bin'})
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique
    foreach($DanshengGradleRoot in $DanshengGradleRoots){
        $DanshengCandidate=Get-ChildItem -LiteralPath $DanshengGradleRoot -Filter $DanshengGradleName -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 1 -ExpandProperty FullName
        if($DanshengCandidate){$DanshengCandidate;break}
    }
}
if (-not $DanshengGradle -or -not (Test-Path -LiteralPath $DanshengGradle)) {
    throw 'Install Gradle 9.7.1 or set GRADLE_HOME to its installation directory.'
}
$DanshengAndroidSourceRoot=if($env:DANSHENG_CORE_ROOT){$env:DANSHENG_CORE_ROOT}else{Split-Path -Parent (Split-Path -Parent $PSScriptRoot)}
. (Join-Path $DanshengAndroidSourceRoot 'scripts/runtime-common.ps1')
$DanshengGradle=Get-DanshengCheckedPath $DanshengGradle
if(-not(Test-Path -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $DanshengGradle)) 'lib/gradle-launcher-9.7.1.jar'))){
    throw 'The selected Gradle installation must be version 9.7.1'
}
if (-not $env:ANDROID_HOME) {
    $env:ANDROID_HOME = if($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}elseif($IsWindows){'C:/Android/Sdk'}elseif($DanshengUserHome){Join-Path $DanshengUserHome 'Android/Sdk'}else{throw 'Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK installation.'}
}
# The installation stays read-only; Gradle's cache/project cache is task-owned.
$DanshengRuntime=if($env:DANSHENG_TASK_RUNTIME){Resolve-DanshengRuntimeRoot -Root $DanshengAndroidSourceRoot -RuntimeRoot $env:DANSHENG_TASK_RUNTIME}else{$null}
$DanshengSavedGradleHome=$env:GRADLE_USER_HOME
if($DanshengRuntime){
    $DanshengGradleCache=if($env:GRADLE_USER_HOME){$env:GRADLE_USER_HOME}else{Join-Path $DanshengRuntime 'gradle-cache'}
    $env:GRADLE_USER_HOME=Get-DanshengRuntimeOutput -RuntimeRoot $DanshengRuntime -Path $DanshengGradleCache
    $DanshengProjectCache=Get-DanshengRuntimeOutput -RuntimeRoot $DanshengRuntime -Path (Join-Path $DanshengRuntime 'gradle-project-cache/core-android')
    $GradleArguments=@('--project-cache-dir',$DanshengProjectCache)+@($GradleArguments)
}
Push-Location -LiteralPath $PSScriptRoot
try {
    & $DanshengGradle @GradleArguments
    $DanshengBuildExit = $LASTEXITCODE
} finally { Pop-Location; $env:GRADLE_USER_HOME=$DanshengSavedGradleHome }
exit $DanshengBuildExit
