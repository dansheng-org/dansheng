#Requires -Version 7.0
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$modulePath=Join-Path $PSScriptRoot '../Dansheng.Workspace.psm1'
Import-Module $modulePath -Force
$module=Get-Module Dansheng.Workspace
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-lock-'+[Guid]::NewGuid().ToString('N'))}
$fixture=Get-DsPath $OutputDirectory
if(Test-Path -LiteralPath $fixture){throw 'Test output must be a new directory; existing files are retained.'}
[void][IO.Directory]::CreateDirectory($fixture)
$results=[Collections.Generic.List[object]]::new()
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add([pscustomobject]@{name=$Name;passed=$true})}
    catch{$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message});throw}
}
$lockPath=Join-Path $fixture 'workspace.lock'
try{
    Case 'default lock wait survives a holder lasting beyond five seconds' {
        $readyPath=Join-Path $fixture 'waiter-ready.txt'
        $resultPath=Join-Path $fixture 'waiter-result.json'
        $waiterPath=Join-Path $fixture 'waiter.ps1'
        $waiterScript=@'
param([string]$ModulePath,[string]$LockPath,[string]$ReadyPath,[string]$ResultPath)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$timer=[Diagnostics.Stopwatch]::StartNew()
$exitCode=0
try{
    $lock=& (Get-Module Dansheng.Workspace) {
        param($Path,$Ready)
        [IO.File]::WriteAllText($Ready,'Waiting for the synthetic workspace lock.')
        Open-DsWorkspaceLock $Path
    } $LockPath $ReadyPath
    try{$result=[ordered]@{acquired=$true;elapsed_ms=$timer.ElapsedMilliseconds;error=$null}}
    finally{$lock.Dispose()}
}catch{
    $result=[ordered]@{acquired=$false;elapsed_ms=$timer.ElapsedMilliseconds;error=$_.Exception.Message}
    $exitCode=1
}
$result|ConvertTo-Json|Set-Content -LiteralPath $ResultPath -Encoding utf8
exit $exitCode
'@
        [IO.File]::WriteAllText($waiterPath,$waiterScript,[Text.UTF8Encoding]::new($false))
        $holder=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $process=[Diagnostics.Process]::new()
        $started=$false
        try{
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($argument in @('-NoProfile','-File',$waiterPath,'-ModulePath',$modulePath,'-LockPath',$lockPath,'-ReadyPath',$readyPath,'-ResultPath',$resultPath)){$start.ArgumentList.Add($argument)}
            $process.StartInfo=$start;[void]$process.Start();$started=$true
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $readyTimer=[Diagnostics.Stopwatch]::StartNew()
            while(-not (Test-Path -LiteralPath $readyPath)){
                Assert (-not $process.HasExited -and $readyTimer.ElapsedMilliseconds -lt 15000) 'Lock waiter did not reach the acquisition attempt.'
                Start-Sleep -Milliseconds 20
            }
            $holdTimer=[Diagnostics.Stopwatch]::StartNew()
            while($holdTimer.ElapsedMilliseconds -lt 7000){Start-Sleep -Milliseconds 50}
            if(Test-Path -LiteralPath $resultPath){
                Assert (-not (Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json).acquired) 'Waiter acquired a lock while another process still held it.'
            }
            $holder.Dispose()
            Assert ($process.WaitForExit(60000)) 'Lock waiter did not finish after the holder released it.'
            $errorText=$stderr.GetAwaiter().GetResult();[void]$stdout.GetAwaiter().GetResult()
            $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
            Assert ($process.ExitCode -eq 0 -and $result.acquired) "Lock waiter failed after a seven-second holder: $($result.error) $errorText"
            Assert ($result.elapsed_ms -ge 7000) 'Lock waiter did not actually wait through the held-lock interval.'
        }finally{
            $holder.Dispose()
            if($started -and -not $process.HasExited){$process.Kill($true);[void]$process.WaitForExit(10000)}
            $process.Dispose()
        }
    }
    Case 'busy lock times out without breaking its holder and can be acquired after release' {
        $holder=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{
            $timer=[Diagnostics.Stopwatch]::StartNew()
            $caught=$null
            $unexpected=$null
            try{$unexpected=& $module {param($Path) Open-DsWorkspaceLock -Path $Path -TimeoutMilliseconds 250} $lockPath}
            catch{$caught=$_.Exception.Message}
            finally{if($unexpected){$unexpected.Dispose()}}
            Assert ($caught -match 'Workspace is busy; no task changes were applied') "Expected bounded lock refusal; received $caught"
            Assert ($timer.ElapsedMilliseconds -ge 250 -and $timer.ElapsedMilliseconds -lt 5000) 'Configured lock timeout was not bounded.'
            Assert ($holder.CanWrite -and $holder.Length -eq 0) 'Timeout changed or disposed another holder.'
        }finally{$holder.Dispose()}
        $recovered=& $module {param($Path) Open-DsWorkspaceLock -Path $Path -TimeoutMilliseconds 0} $lockPath
        $recovered.Dispose()
    }
}finally{
    $report=[ordered]@{format='dansheng-workspace-lock-fixtures-v1';passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object{-not $_.passed}).Count;tests=@($results);fixture_root=$fixture;synthetic_data_only=$true}
    Write-DsJson (Join-Path $fixture 'results.json') $report
}
$report|ConvertTo-Json -Depth 5
$global:LASTEXITCODE=0
