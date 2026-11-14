#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskKey,[ValidateSet('core','app')][string]$Component='core',[string]$ToolchainRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Environment.psm1') -Force -DisableNameChecking
$taskRecord=Read-DsTask $WorkspaceRoot $TaskKey
$taskStatus=Get-DsTaskStatus $WorkspaceRoot $TaskKey
if($taskStatus.state -ne 'ready'){throw 'Task is not ready.'}
$taskTarget=@($taskRecord.components|Where-Object name -eq $Component)
if($taskTarget.Count -ne 1){throw 'Requested component is not part of this task.'}
$taskCore=@($taskRecord.components|Where-Object name -eq 'core')
$taskCoreRoot=if($taskCore.Count){$taskCore[0].path}else{$taskRecord.core_repository}
$taskApp=@($taskRecord.components|Where-Object name -eq 'app')
$taskLock=if($taskApp.Count){Join-Path $taskApp[0].path 'core.lock.json'}else{$null}
$taskEnvironment=Get-DsRuntimeEnvironment -RuntimeRoot $taskRecord.runtime_root -CoreRoot $taskCoreRoot -CoreRepository $taskRecord.core_repository -CoreToolsRoot $PSScriptRoot -ToolchainRoot $ToolchainRoot -LockFile $taskLock
Clear-DsGitLocalEnvironment
foreach($taskName in $taskEnvironment.values.Keys){Set-DsProcessEnvironmentValue $taskName $taskEnvironment.values[$taskName]}
$env:DANSHENG_TASK_KEY=$TaskKey
$env:DANSHENG_WORKSPACE_ROOT=$taskRecord.workspace
Set-Location -LiteralPath $taskTarget[0].path
[pscustomobject]@{task=$TaskKey;cwd=(Get-Location).Path;runtime_root=$taskRecord.runtime_root;core_worktree=$env:DANSHENG_CORE_ROOT;core_tools=$env:DANSHENG_CORE_TOOLS_ROOT;toolchain_available=$taskEnvironment.toolchain.available}
$global:LASTEXITCODE=0
