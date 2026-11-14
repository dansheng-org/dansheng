# Native Host/CLI/MCP entry point. Account data is never imported here.
[CmdletBinding()]
param(
    [ValidateSet('serve','call','mcp','schema')][string]$Action='serve',
    [string]$Method='core.info',
    [string]$Params='{}',
    [string]$RuntimeRoot,
    [string]$TargetDirectory,
    [string]$DataDirectory,
    [string]$ClientConfig,
    [switch]$SkipBuild,
    [switch]$Offline,
    [switch]$Background
)
$ErrorActionPreference='Stop'
$LocalRoot=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/runtime-common.ps1"
$LocalRuntime=Resolve-DanshengRuntimeRoot -Root $LocalRoot -RuntimeRoot $RuntimeRoot
if(-not $TargetDirectory){$TargetDirectory=if($env:CARGO_TARGET_DIR){$env:CARGO_TARGET_DIR}else{Join-Path $LocalRuntime 'cargo-target'}}
$TargetDirectory=Get-DanshengRuntimeOutput -RuntimeRoot $LocalRuntime -Path $TargetDirectory
if(-not $DataDirectory){$DataDirectory=if($env:DANSHENG_PROFILE){$env:DANSHENG_PROFILE}else{Join-Path $LocalRuntime 'profiles/core'}}
$DataDirectory=Get-DanshengRuntimeOutput -RuntimeRoot $LocalRuntime -Path $DataDirectory
if($ClientConfig){$ClientConfig=Get-DanshengRuntimeOutput -RuntimeRoot $LocalRuntime -Path $ClientConfig}
if($Background -and $Action -ne 'serve'){throw '-Background is only supported for serve; MCP must retain its stdio transport'}
$LocalBinary=Get-DanshengRuntimeOutput -RuntimeRoot $LocalRuntime -Path (Join-Path $TargetDirectory 'debug/dansheng-host.exe')
if(-not $SkipBuild){
    . "$PSScriptRoot/dev.ps1"
    $LocalSavedTarget=$env:CARGO_TARGET_DIR
    $env:CARGO_TARGET_DIR=$TargetDirectory
    Push-Location -LiteralPath $LocalRoot
    try{
        $LocalBuild=@('build','-p','dansheng-host','--locked')
        if($Offline){$LocalBuild+='--offline'}
        & cargo @LocalBuild
        if($LASTEXITCODE -ne 0){throw 'Native host build failed'}
    }finally{Pop-Location;$env:CARGO_TARGET_DIR=$LocalSavedTarget}
}
if(-not(Test-Path -LiteralPath $LocalBinary -PathType Leaf)){throw 'Build dansheng-host before using -SkipBuild'}
$LocalArgs=@('--data-dir',$DataDirectory)
if($ClientConfig){$LocalArgs+=@('--client-config',$ClientConfig)}
$LocalArgs+=$Action
if($Action -eq 'call'){$LocalArgs+=@($Method,$Params)}
if(-not $Background){
    & $LocalBinary @LocalArgs
    if($LASTEXITCODE -ne 0){throw 'Native host command failed'}
    return
}
$LocalLogs=Get-DanshengRuntimeOutput -RuntimeRoot $LocalRuntime -Path (Join-Path $LocalRuntime 'logs/host')
[void][IO.Directory]::CreateDirectory($LocalLogs)
$LocalId=[guid]::NewGuid().ToString('N')
$LocalProcess=Start-Process -FilePath $LocalBinary -ArgumentList @('--data-dir',('"'+$DataDirectory+'"'),'serve') -WorkingDirectory $LocalRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LocalLogs "$LocalId.stdout.log") -RedirectStandardError (Join-Path $LocalLogs "$LocalId.stderr.log")
# Return only process ownership and paths. No IPC tokens/config contents.
[ordered]@{pid=$LocalProcess.Id;data_directory=$DataDirectory;binary=$LocalBinary;log_directory=$LocalLogs;background=$true}|ConvertTo-Json
