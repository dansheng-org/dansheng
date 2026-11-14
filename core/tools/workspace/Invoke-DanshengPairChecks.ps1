#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CoreWorktree,
    [Parameter(Mandatory)][string]$AppWorktree,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$LockFile,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [string]$WorkspaceRoot,
    [string]$ToolchainRoot,
    [ValidateRange(1,32)][int]$FlutterTestConcurrency=2,
    [switch]$Offline,
    [switch]$AllowPreparation,
    [switch]$NativeSmoke,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Environment.psm1') -Force -DisableNameChecking
$taskComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$taskCore=Get-DsRepository $CoreWorktree;$taskApp=Get-DsRepository $AppWorktree
if($taskCore.common_dir -eq $taskApp.common_dir){throw 'Paired checks require independent product repositories.'}
foreach($taskRepo in @($taskCore,$taskApp)){
    if((Test-Path -LiteralPath (Join-Path $taskRepo.path '.git') -PathType Container) -or $taskRepo.branch -notmatch '^(feat|fix|refactor|chore)/DS-'){throw 'Checks must run in named linked task worktrees, never product main or copied repositories.'}
    if(-not $taskRepo.head -and -not $AllowPreparation){throw 'A committed baseline is required; preparation checks must be explicitly labelled.'}
    $taskListed=(Invoke-DsGit $taskRepo.path @('worktree','list','--porcelain')).text.Replace('\','/') -split "`n"
    if(('worktree '+$taskRepo.path.Replace('\','/')) -cnotin $taskListed){throw 'Both checks require Git-registered worktrees.'}
}
if($taskCore.branch -cne $taskApp.branch){throw 'Paired Core/App worktrees must use the same task ID and complete branch name.'}
$taskKey=($taskCore.branch -split '/',2)[1]
if($taskKey -cnotmatch '^DS-[0-9]{3,8}-[a-z0-9]+(?:-[a-z0-9]+)*$'){throw 'Invalid paired task identity.'}
$taskPair=Get-DsPath (Split-Path -Parent $taskCore.path)
if(-not (Get-DsPath (Split-Path -Parent $taskApp.path)).Equals($taskPair,$taskComparison) -or (Split-Path -Leaf $taskPair) -cne $taskKey -or (Split-Path -Leaf $taskCore.path) -cne 'core' -or (Split-Path -Leaf $taskApp.path) -cne 'app'){throw 'Paired trees must be the registered core/app siblings for one task.'}
$taskTreeRoot=Get-DsPath (Split-Path -Parent $taskPair)
if($WorkspaceRoot){$taskWorkspace=Get-DsPath $WorkspaceRoot}
else{
    $taskWorkspace=Get-DsPath (Split-Path -Parent $taskTreeRoot)
}
if(Test-Path -LiteralPath (Join-Path $taskWorkspace '.git')){throw 'Task checks require an ordinary parent workspace.'}
$taskRuntime=Get-DsPath $RuntimeRoot
if(-not (Test-DsWithin (Join-Path $taskWorkspace 'local/runtime') $taskRuntime)){throw 'Paired check resources must stay in their parent workspace local/runtime directory.'}
if($AllowPreparation){
    if($taskCore.head -or $taskApp.head -or $taskCore.branch -cne 'chore/DS-001-repository-workflow' -or -not (Split-Path -Leaf $taskRuntime).StartsWith('DS-001-', [StringComparison]::Ordinal)){throw 'Preparation exception only accepts the audited unborn DS-001 pair and its own runtime.'}
}else{
    $taskRegistration=Read-DsTask $taskWorkspace $taskKey
    if(-not (Get-DsRecordedWorktreeRoot $taskRegistration).Equals($taskTreeRoot,$taskComparison)){throw 'Pair worktree parent differs from task registration.'}
    $taskStates=(Get-DsTaskStatus $taskWorkspace $taskKey).worktrees
    if($taskRegistration.state -ne 'ready' -or $taskRegistration.scope -ne 'Both' -or -not (Get-DsPath $taskRegistration.runtime_root).Equals($taskRuntime,$taskComparison) -or @($taskStates).Count -ne 2){throw 'Pair or runtime does not match ready task registration.'}
    foreach($taskRepo in @($taskCore,$taskApp)){
        if(-not @($taskStates|Where-Object {$_.path -eq $taskRepo.path -and $_.branch -ceq $taskRepo.branch}).Count){throw 'Pair does not match its registered worktrees.'}
    }
}
foreach($taskRepo in @($taskCore,$taskApp)){
    if((Test-DsWithin $taskRepo.path $taskRuntime) -or (Test-DsWithin (Split-Path -Parent $taskRepo.common_dir) $taskRuntime)){throw 'Runtime caches must stay outside original and task source folders.'}
}
$taskCommands=@(
    [pscustomobject]@{root=$taskCore.path;tool='cargo';arguments=@('fmt','--all','--','--check')},
    [pscustomobject]@{root=$taskCore.path;tool='cargo';arguments=@('test','--workspace','--all-features','--all-targets','--locked')},
    [pscustomobject]@{root=$taskCore.path;tool='cargo';arguments=@('clippy','--workspace','--all-features','--all-targets','--locked','--','-D','warnings')},
    [pscustomobject]@{root=(Join-Path $taskCore.path 'sdk');tool='npm';arguments=@('ci','--ignore-scripts')},
    [pscustomobject]@{root=(Join-Path $taskCore.path 'sdk');tool='npm';arguments=@('run','check')},
    [pscustomobject]@{root=$taskApp.path;tool='flutter';arguments=@('pub','get')},
    [pscustomobject]@{root=$taskApp.path;tool='pwsh';arguments=@('-NoProfile','-File',(Join-Path $taskApp.path 'scripts/check-format.ps1'))},
    [pscustomobject]@{root=$taskApp.path;tool='flutter';arguments=@('analyze')},
    [pscustomobject]@{root=$taskApp.path;tool='flutter';arguments=@('test','--concurrency',[string]$FlutterTestConcurrency)}
)
if($NativeSmoke){$taskCommands += [pscustomobject]@{root=$taskApp.path;tool='flutter';arguments=@('build','apk','--debug','--target-platform','android-x64','--no-pub')}}
if($Offline){
    foreach($taskCommand in $taskCommands){
        if($taskCommand.tool-eq'cargo' -and $taskCommand.arguments[0]-in@('test','clippy')){
            $taskOptions=[Collections.Generic.List[string]]::new()
            foreach($taskOption in $taskCommand.arguments){$taskOptions.Add($taskOption)}
            $taskSeparator=$taskOptions.IndexOf('--')
            if($taskSeparator-lt0){$taskOptions.Add('--offline')}else{$taskOptions.Insert($taskSeparator,'--offline')}
            $taskCommand.arguments=$taskOptions.ToArray()
        }elseif(($taskCommand.tool-eq'npm' -and $taskCommand.arguments[0]-eq'ci') -or ($taskCommand.tool-eq'flutter' -and $taskCommand.arguments[0]-eq'pub')){$taskCommand.arguments+=@('--offline')}
    }
}
$taskPlan=[pscustomobject]@{applied=$false;core=$taskCore;app=$taskApp;runtime_root=$taskRuntime;lock_file=(Get-DsPath $LockFile);artifact_directory=(Get-DsPath $ArtifactDirectory);preparation=[bool]$AllowPreparation;native_smoke=[bool]$NativeSmoke;offline=[bool]$Offline;flutter_test_concurrency=$FlutterTestConcurrency;commands=$taskCommands;device_install_or_remote_business_writes=$false}
if(-not $Apply){$taskPlan|ConvertTo-Json -Depth 8;$global:LASTEXITCODE=0;return}
$taskRuntimeEnvironment=Get-DsRuntimeEnvironment -RuntimeRoot $taskRuntime -CoreRoot $taskCore.path -CoreRepository (Split-Path -Parent $taskCore.common_dir) -CoreToolsRoot $PSScriptRoot -ToolchainRoot $ToolchainRoot -ArtifactDirectory $ArtifactDirectory -LockFile $LockFile
$taskEnvironment=$taskRuntimeEnvironment.values
$taskEnvironment.DANSHENG_TASK_KEY=$taskKey
$taskEnvironment.DANSHENG_BETA_STORE=$null;$taskEnvironment.DANSHENG_BETA_PASSWORD=$null
$taskGitNames=@(Get-DsGitLocalEnvironmentNames)+@([Environment]::GetEnvironmentVariables('Process').Keys|Where-Object {$_ -match '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$'})
$taskSaved=@{};foreach($taskName in (@($taskEnvironment.Keys)+$taskGitNames|Select-Object -Unique)){$taskSaved[$taskName]=[Environment]::GetEnvironmentVariable($taskName,'Process')}
$taskLockBefore=(Get-FileHash -LiteralPath (Join-Path $taskApp.path 'pubspec.lock')).Hash
try{
    Clear-DsGitLocalEnvironment
    & (Join-Path $PSScriptRoot 'Test-DanshengCoreDependency.ps1') -LockFile $LockFile -ArtifactDirectory $ArtifactDirectory -CoreRoot $taskCore.path -AppRoot $taskApp.path|Out-Null
    if($IsWindows -and -not $taskRuntimeEnvironment.toolchain.available){throw 'Initialize the pinned toolchain before running paired product checks.'}
    foreach($taskName in $taskEnvironment.Keys){Set-DsProcessEnvironmentValue $taskName $taskEnvironment[$taskName]}
    foreach($taskFolder in @('cargo-target','cargo-home','pub-cache','gradle-cache','npm-cache','android-user/avds','profiles/core','browser','tmp','logs')){[void][IO.Directory]::CreateDirectory((Get-DsPath (Join-Path $taskRuntime $taskFolder)))}
    $taskIndex=0
    foreach($taskCommand in $taskCommands){
        $taskProgram=(Get-Command $taskCommand.tool -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
        Push-Location -LiteralPath $taskCommand.root
        try{
            $taskArguments=@($taskCommand.arguments)
            & $taskProgram @taskArguments 2>&1|Tee-Object -FilePath (Join-Path $taskRuntime "logs/check-$taskIndex.log")
            if($LASTEXITCODE -ne 0){throw "Paired check failed: $($taskCommand.tool). Existing files are retained for review."}
        }finally{Pop-Location}
        $taskIndex++
    }
    if((Get-FileHash -LiteralPath (Join-Path $taskApp.path 'pubspec.lock')).Hash -ne $taskLockBefore){throw 'Dependency resolution changed App lockfile; inspect it instead of silently restoring/publishing.'}
    [pscustomobject]@{applied=$true;checks=$taskCommands.Count;core_base=$taskCore.head;app_base=$taskApp.head;preparation=[bool]$AllowPreparation;offline=[bool]$Offline;runtime_root=$taskRuntime;device_install_or_remote_business_writes=$false}|ConvertTo-Json -Depth 5
    $global:LASTEXITCODE=0
}finally{foreach($taskName in $taskSaved.Keys){Set-DsProcessEnvironmentValue $taskName $taskSaved[$taskName]}}
