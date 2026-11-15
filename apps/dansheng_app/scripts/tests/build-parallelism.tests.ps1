#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../build-parallelism.ps1')
$names = @('CARGO_BUILD_JOBS','DANSHENG_GRADLE_WORKERS')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$checks = 0
function Check([bool]$Value) { if (-not $Value) { throw 'Build concurrency fixture failed.' }; $script:checks++ }
try {
    foreach ($name in $names) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    $defaults = Get-DanshengBuildParallelism
    Check ($defaults.cargo -eq 3 -and $defaults.gradle -eq 2)
    $env:CARGO_BUILD_JOBS='24'; $env:DANSHENG_GRADLE_WORKERS='12'
    $remote = Get-DanshengBuildParallelism
    Check ($remote.cargo -eq 24 -and $remote.gradle -eq 12)
    foreach ($name in $names) {
        foreach ($bad in @('0','-1','257','all','12 --scan',' 12','1.5')) {
            [Environment]::SetEnvironmentVariable($name, $bad)
            $message = ''
            try { Get-DanshengBuildParallelism | Out-Null } catch { $message=$_.Exception.Message }
            Check ($message -like "$name must be an integer*")
        }
        [Environment]::SetEnvironmentVariable($name, '1')
        $null = Get-DanshengBuildParallelism
        $checks++
    }
    Write-Host "Build concurrency fixtures passed: $checks assertions."
} finally {
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}
