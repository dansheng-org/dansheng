#Requires -Version 7.0
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../Dansheng.Workspace.psm1') -Force
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-workflow-'+[Guid]::NewGuid().ToString('N'))}
$fixture=Get-DsPath $OutputDirectory
if(Test-Path -LiteralPath $fixture){throw 'Test output must be a new directory; existing files are retained.'}
[void][IO.Directory]::CreateDirectory($fixture)
$results=[Collections.Generic.List[object]]::new()
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add([pscustomobject]@{name=$Name;passed=$true})}
    catch{$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message});throw}
}
function Throws([scriptblock]$Body,[string]$Pattern){
    $caught=$null;try{& $Body|Out-Null}catch{$caught=$_.Exception.Message}
    Assert ([bool]$caught -and $caught -match $Pattern) "Expected refusal matching $Pattern; received $caught"
}
function Seed([string]$Name,[switch]$Unborn){
    $root=Join-Path $fixture $Name;[void][IO.Directory]::CreateDirectory($root)
    [void](Invoke-DsGit $root @('init','--initial-branch=main'))
    [IO.File]::WriteAllText((Join-Path $root 'README.md'),"Synthetic Git fixture only.`n")
    [IO.File]::WriteAllText((Join-Path $root '.gitignore'),"/build/`n")
    if(-not $Unborn){
        [void](Invoke-DsGit $root @('add','--','README.md','.gitignore'))
        [void](Invoke-DsGit $root @('-c','user.name=Workflow fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','-c',('core.hooksPath='+ (Join-Path $fixture 'no-hooks')),'commit','-m','seed synthetic fixture'))
    }
    $root
}
$core=Seed 'core repo'
# Packaged Windows hosts can expose a virtual LocalAppData alias. Use the actual
# root reported by native Git rather than weakening the repository-root guard.
$core=Get-DsPath (Invoke-DsGit $core @('rev-parse','--show-toplevel')).text
$fixture=Get-DsPath ([IO.Path]::GetDirectoryName($core))
$app=Seed 'app repo';$workspace=Join-Path $fixture 'ordinary workspace'
$initialCore=Get-DsRepository $core;$initialApp=Get-DsRepository $app
$coreIndex=(Get-FileHash -LiteralPath (Join-Path $core '.git/index')).Hash
$appIndex=(Get-FileHash -LiteralPath (Join-Path $app '.git/index')).Hash
$newArgs=@{CoreRepo=$core;AppRepo=$app;WorkspaceRoot=$workspace;Kind='chore';Owner='fixture-agent'}
Case 'Git calls ignore inherited repository and injected config overrides' {
    $names=@('GIT_COMMON_DIR','GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0')
    $saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try{
        $env:GIT_COMMON_DIR=$initialApp.common_dir;$env:GIT_CONFIG_COUNT='1';$env:GIT_CONFIG_KEY_0='core.worktree';$env:GIT_CONFIG_VALUE_0=$app
        Assert ((Get-DsRepository $core).common_dir -eq $initialCore.common_dir) 'Inherited Git environment redirected a Core read to App.'
        Assert ($env:GIT_COMMON_DIR -eq $initialApp.common_dir) 'Read-only Git helper changed the caller environment.'
        $nativeNames=(Invoke-DsGit $core @('rev-parse','--local-env-vars')).text -split "`n"
        Assert (-not @($nativeNames|Where-Object {$_ -notin @(Get-DsGitLocalEnvironmentNames)}).Count) 'Git local environment list has unhandled variables.'
    }finally{foreach($name in $saved.Keys){Set-DsProcessEnvironmentValue $name $saved[$name]}}
}
Case 'native source enumeration temporarily clears and restores Git environment' {
    $names=@('GIT_DIR','GIT_WORK_TREE');$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try{
        $env:GIT_DIR=$initialApp.common_dir;$env:GIT_WORK_TREE=$app
        $nativeTop=Invoke-DsWithCleanGitEnvironment -Action {param($Root) & git --no-optional-locks -C $Root rev-parse --show-toplevel} -Arguments @($core)
        Assert ((Get-DsPath ($nativeTop -join '')) -eq $core -and $env:GIT_DIR -eq $initialApp.common_dir -and $env:GIT_WORK_TREE -eq $app) 'Source enumeration used another repository or failed to restore its caller.'
    }finally{foreach($name in $saved.Keys){Set-DsProcessEnvironmentValue $name $saved[$name]}}
}
Case 'dry-run creates no source/registry/runtime files' {
    $plan=New-DsTask @newArgs -TaskId DS-801 -Slug core-only -Scope Core
    Assert (-not $plan.applied -and -not (Test-Path -LiteralPath $workspace)) 'Dry-run mutated workspace.'
}
Case 'Core-only branch/worktree uses its exact committed base' {
    $created=New-DsTask @newArgs -TaskId DS-801 -Slug core-only -Scope Core -Apply
    Assert ($created.status.worktrees.Count -eq 1 -and $created.status.worktrees[0].name -eq 'core') 'Wrong scope.'
    Assert ($created.status.worktrees[0].head -eq $initialCore.head) 'Wrong base.'
}
Case 'App-only branch/worktree uses a different Git database' {
    $created=New-DsTask @newArgs -TaskId DS-802 -Slug app-only -Scope App -Apply
    Assert ($created.status.worktrees.Count -eq 1 -and $created.status.worktrees[0].name -eq 'app') 'Wrong App scope.'
    Assert ((Get-DsRepository $created.status.worktrees[0].path).common_dir -eq $initialApp.common_dir) 'App shared Core history.'
}
Case 'paired task has same ID/branch with independent exact bases' {
    $created=New-DsTask @newArgs -TaskId DS-803 -Slug paired -Scope Both -Apply
    Assert ($created.status.worktrees.Count -eq 2) 'Pair missing a component.'
    Assert ($created.status.worktrees[0].branch -eq $created.status.worktrees[1].branch) 'Pair names differ.'
    Assert ((Get-DsRepository $created.status.worktrees[0].path).common_dir -ne (Get-DsRepository $created.status.worktrees[1].path).common_dir) 'Pair became monorepo.'
}
Case 'external worktree parent keeps registration and runtime in the workspace' {
    $external=Join-Path $fixture 'separate worktrees'
    $created=New-DsTask @newArgs -WorktreeRoot $external -TaskId DS-829 -Slug external-layout -Scope Both -Apply
    Assert ($created.status.worktrees.Count -eq 2 -and (Test-DsWithin $external $created.status.worktrees[0].path)) 'Worktrees were not created in the selected external parent.'
    $record=Read-DsTask $workspace 'DS-829-external-layout'
    Assert ((Get-DsRecordedWorktreeRoot $record) -eq (Get-DsPath $external) -and (Test-DsWithin (Join-Path $workspace 'local/runtime') $record.runtime_root)) 'Runtime or registration escaped its workspace.'
    $plan=& (Join-Path $PSScriptRoot '../Invoke-DanshengPairChecks.ps1') -CoreWorktree $created.status.worktrees[0].path -AppWorktree $created.status.worktrees[1].path -WorkspaceRoot $workspace -RuntimeRoot $record.runtime_root -LockFile (Join-Path $fixture 'unused-lock.json') -ArtifactDirectory $fixture | ConvertFrom-Json
    Assert (-not $plan.applied) 'External pair dry-run started a build.'
    [void](Close-DsTask $workspace 'DS-829-external-layout' 'fixture-agent' -Apply -ConfirmRemoval)
    Assert (-not(Test-Path -LiteralPath $created.status.worktrees[0].path) -and (Test-Path -LiteralPath $record.runtime_root)) 'External closure removed runtime data or kept the clean worktree.'
}
Case 'paired checks refuse different task branches before any build' {
    $pair=Get-DsTaskStatus $workspace 'DS-803-paired'
    $other=Get-DsTaskStatus $workspace 'DS-801-core-only'
    Throws {& (Join-Path $PSScriptRoot '../Invoke-DanshengPairChecks.ps1') -CoreWorktree $other.worktrees[0].path -AppWorktree $pair.worktrees[1].path -RuntimeRoot $pair.runtime_root -LockFile (Join-Path $fixture 'unused-lock.json') -ArtifactDirectory $fixture} 'same task ID'
}
Case 'paired checks require the runtime belonging to the registered task' {
    $pair=Get-DsTaskStatus $workspace 'DS-803-paired'
    Throws {& (Join-Path $PSScriptRoot '../Invoke-DanshengPairChecks.ps1') -CoreWorktree $pair.worktrees[0].path -AppWorktree $pair.worktrees[1].path -RuntimeRoot (Join-Path $workspace 'local/runtime/DS-999-other') -LockFile (Join-Path $fixture 'unused-lock.json') -ArtifactDirectory $fixture} 'runtime does not match'
}
Case 'task runtime cannot be redirected into a product source directory' {
    $path=Join-Path $workspace 'local/tasks/DS-803-paired.json'
    $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $original=$record.runtime_root
    try{$record.runtime_root=$core;Write-DsJson $path $record -ReplaceOwned;Throws {Get-DsTaskStatus $workspace 'DS-803-paired'} 'runtime directory differs'}
    finally{$record.runtime_root=$original;Write-DsJson $path $record -ReplaceOwned}
}
Case 'component source repository cannot silently switch to another worktree' {
    $path=Join-Path $workspace 'local/tasks/DS-803-paired.json'
    $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $original=$record.components[0].repository
    try{$record.components[0].repository=(Get-DsTaskStatus $workspace 'DS-801-core-only').worktrees[0].path;Write-DsJson $path $record -ReplaceOwned;Throws {Get-DsTaskStatus $workspace 'DS-803-paired'} 'source repository differs'}
    finally{$record.components[0].repository=$original;Write-DsJson $path $record -ReplaceOwned}
}
Case 'changing both record source fields cannot replace the primary repository' {
    $path=Join-Path $workspace 'local/tasks/DS-803-paired.json';$record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $original=$record.core_repository
    try{
        $other=(Get-DsTaskStatus $workspace 'DS-801-core-only').worktrees[0].path
        $record.core_repository=$other;$record.components[0].repository=$other;Write-DsJson $path $record -ReplaceOwned
        Throws {Get-DsTaskStatus $workspace 'DS-803-paired'} 'primary repository root|overlaps a product source'
    }finally{$record.core_repository=$original;$record.components[0].repository=$original;Write-DsJson $path $record -ReplaceOwned}
}
Case 'task entry isolates Android profiles and clears inherited Git overrides' {
    $names=@('GIT_COMMON_DIR','CARGO_TARGET_DIR','CARGO_HOME','PUB_CACHE','GRADLE_USER_HOME','npm_config_cache','ANDROID_USER_HOME','ANDROID_AVD_HOME','TEMP','TMP','DANSHENG_TASK_KEY','DANSHENG_TASK_RUNTIME','DANSHENG_PROFILE','DANSHENG_BROWSER_PROFILE','DANSHENG_CORE_SDK_DIR','DANSHENG_CORE_ROOT')
    $saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    Push-Location
    try{
        $env:GIT_COMMON_DIR=$initialApp.common_dir
        & (Join-Path $PSScriptRoot '../Enter-DanshengTask.ps1') -WorkspaceRoot $workspace -TaskKey DS-803-paired -Component app | Out-Null
        $runtime=(Read-DsTask $workspace 'DS-803-paired').runtime_root
        Assert (-not $env:GIT_COMMON_DIR -and $env:ANDROID_USER_HOME -eq (Join-Path $runtime 'android-user') -and $env:ANDROID_AVD_HOME -eq (Join-Path $runtime 'android-user/avds') -and $env:DANSHENG_PROFILE -eq (Join-Path $runtime 'profiles/core')) 'Task entry inherited shared Git/Android/profile state.'
        Assert ($env:DANSHENG_CORE_SDK_DIR -eq (Join-Path $runtime 'native-sdk') -and $env:DANSHENG_CORE_SDK_DIR -ne (Join-Path $runtime 'artifacts')) 'Task entry mixed SDK input with App distribution output.'
        $nativeCommon=@(& git --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>$null)
        Assert ($LASTEXITCODE -eq 0 -and (Get-DsPath ($nativeCommon -join '')) -eq $initialApp.common_dir) 'Native Git inherited empty repository variables after task entry.'
    }finally{Pop-Location;foreach($name in $saved.Keys){Set-DsProcessEnvironmentValue $name $saved[$name]}}
}
Case 'an unregistered existing runtime cannot be adopted or overwritten' {
    $runtime=Get-DsPath (Join-Path $workspace 'local/runtime/DS-821-existing-runtime');[void][IO.Directory]::CreateDirectory($runtime)
    [IO.File]::WriteAllText((Join-Path $runtime 'keep.txt'),'Retain unregistered runtime data.')
    Throws {New-DsTask @newArgs -TaskId DS-821 -Slug existing-runtime -Scope Core -Apply} 'runtime directory already exists'
    Assert ((Test-Path -LiteralPath (Join-Path $runtime 'keep.txt')) -and -not (Test-Path -LiteralPath (Join-Path $workspace 'worktrees/DS-821-existing-runtime'))) 'Runtime was overwritten or adopted.'
}
Case 'same owned ready task is idempotent without resetting content' {
    $before=(Get-DsTaskStatus $workspace 'DS-801-core-only').worktrees[0].head
    $again=New-DsTask @newArgs -TaskId DS-801 -Slug core-only -Scope Core -Apply
    Assert ($again.idempotent -and -not $again.applied -and $again.status.worktrees[0].head -eq $before) 'Repeat changed task.'
}
Case 'another owner cannot take over an existing task' {
    $other=$newArgs.Clone();$other.Owner='other-agent'
    Throws {New-DsTask @other -TaskId DS-801 -Slug core-only -Scope Core -Apply} 'another identity'
}
Case 'same repository cannot masquerade as Core/App pair' {
    Throws {New-DsTask -CoreRepo $core -AppRepo $core -WorkspaceRoot $workspace -TaskId DS-804 -Slug invalid -Owner fixture} 'TWO independent'
}
Case 'nested worktree directory is refused before mutation' {
    Throws {New-DsTask -CoreRepo $core -AppRepo $app -WorkspaceRoot $core -TaskId DS-804 -Slug nested -Owner fixture} 'outside both'
}
Case 'task/ref path traversal is refused' {
    Throws {New-DsTask @newArgs -TaskId DS-804 -Slug '../escape' -Scope Core -Apply} 'metacharacters'
}
Case 'unborn product baseline is refused without initialization or commit' {
    $unborn=Seed 'unborn fixture' -Unborn
    Throws {New-DsTask -CoreRepo $unborn -AppRepo $app -WorkspaceRoot (Join-Path $fixture 'unborn-workspace') -TaskId DS-804 -Slug unborn -Owner fixture -Scope Core -Apply} 'NeedsInitialCommit'
    Assert (-not (Get-DsRepository $unborn).head) 'Unborn repository was committed.'
}
Case 'dirty reference working files are preserved and refused' {
    [IO.File]::WriteAllText((Join-Path $app 'uncommitted.txt'),'Keep this synthetic uncommitted file.')
    Throws {New-DsTask @newArgs -TaskId DS-804 -Slug dirty-source -Scope App -Apply} 'uncommitted content'
    Assert (Test-Path -LiteralPath (Join-Path $app 'uncommitted.txt')) 'Dirty content disappeared.'
    # The fixture owns this file; preserve it in an external archive instead of cleaning.
    [IO.File]::Move((Join-Path $app 'uncommitted.txt'),(Join-Path $fixture 'preserved-uncommitted.txt'))
}
Case 'source changes while task creation waits are preserved and refused' {
    $lock=[IO.File]::Open((Join-Path $workspace 'local/workspace.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-File',(Join-Path $PSScriptRoot '../New-DanshengTask.ps1'),'-CoreRepo',$core,'-AppRepo',$app,'-WorkspaceRoot',$workspace,'-TaskId','DS-818','-Slug','source-race','-Kind','chore','-Scope','App','-Owner','fixture-agent','-Apply')){$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;[void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $change=Get-DsPath (Join-Path $app 'concurrent-uncommitted.txt')
    try{
        Start-Sleep -Milliseconds 500
        [IO.File]::WriteAllText($change,'Preserve concurrent synthetic source change.')
        $lock.Dispose();$lock=$null
        Assert ($process.WaitForExit(15000)) 'Source-race creator did not finish.'
        Assert ($process.ExitCode -ne 0) 'A changed source was accepted.'
        Assert ($stderr.GetAwaiter().GetResult() -match 'uncommitted content|changed before task creation') 'Unexpected source-race failure.'
        [void]$stdout.GetAwaiter().GetResult()
        Assert ((Test-Path -LiteralPath $change) -and -not (Test-Path -LiteralPath (Join-Path $workspace 'worktrees/DS-818-source-race'))) 'Concurrent changes were overwritten or a tree was provisioned.'
    }finally{
        if($lock){$lock.Dispose()};$process.Dispose()
        if(Test-Path -LiteralPath $change){[IO.File]::Move($change,(Get-DsPath (Join-Path $fixture 'preserved-concurrent-uncommitted.txt')))}
    }
}
Case 'linked runtime cache is refused before entering a task environment' {
    $created=New-DsTask @newArgs -TaskId DS-819 -Slug linked-runtime -Scope Core -Apply
    $target=Get-DsPath (Join-Path $fixture 'link-target');[void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'keep.txt'),'Preserve external synthetic target.')
    $cache=Get-DsPath (Join-Path $created.status.runtime_root 'cargo-home')
    [IO.Directory]::Move($cache,(Get-DsPath (Join-Path $fixture 'preserved-empty-cargo-home')))
    $type=if($IsWindows){'Junction'}else{'SymbolicLink'}
    [void](New-Item -ItemType $type -Path $cache -Target $target)
    $envBefore=$env:CARGO_HOME
    Throws {& (Join-Path $PSScriptRoot '../Enter-DanshengTask.ps1') -WorkspaceRoot $workspace -TaskKey DS-819-linked-runtime} 'Linked path refused'
    Assert ($env:CARGO_HOME -eq $envBefore -and (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))) 'Linked runtime changed the environment or target.'
}
Case 'linked task subtree blocks closure and preserves its external target' {
    $created=New-DsTask @newArgs -TaskId DS-820 -Slug linked-task -Scope Core -Apply
    $tree=Get-DsPath $created.status.worktrees[0].path
    $target=Get-DsPath (Join-Path $fixture 'task-link-target');[void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'keep.txt'),'Retain target beyond task source.')
    $link=Get-DsPath (Join-Path $tree 'linked-content');$type=if($IsWindows){'Junction'}else{'SymbolicLink'}
    [void](New-Item -ItemType $type -Path $link -Target $target)
    Throws {Close-DsTask $workspace 'DS-820-linked-task' 'fixture-agent' -Apply -ConfirmRemoval} 'retained|Linked'
    Assert ((Test-Path -LiteralPath $tree) -and (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))) 'Linked task or target was removed.'
}
Case 'linked core profile is refused before task environment changes' {
    $created=New-DsTask @newArgs -TaskId DS-822 -Slug linked-profile -Scope Core -Apply
    $profile=Get-DsPath (Join-Path $created.status.runtime_root 'profiles/core')
    [IO.Directory]::Move($profile,(Get-DsPath (Join-Path $fixture 'preserved-empty-core-profile')))
    $target=Get-DsPath (Join-Path $fixture 'profile-link-target');[void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'keep.txt'),'Retain synthetic profile target.')
    $type=if($IsWindows){'Junction'}else{'SymbolicLink'};[void](New-Item -ItemType $type -Path $profile -Target $target)
    $before=$env:DANSHENG_PROFILE
    Throws {& (Join-Path $PSScriptRoot '../Enter-DanshengTask.ps1') -WorkspaceRoot $workspace -TaskKey DS-822-linked-profile} 'Linked path refused'
    Assert ($env:DANSHENG_PROFILE -eq $before -and (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))) 'Profile environment or target changed.'
}
Case 'existing branch is refused, not reset or force-checked-out' {
    [void](Invoke-DsGit $core @('branch','chore/DS-804-occupied'))
    Throws {New-DsTask @newArgs -TaskId DS-804 -Slug occupied -Scope Core -Apply} 'already present'
    Assert ((Invoke-DsGit $core @('rev-parse','chore/DS-804-occupied')).text -eq $initialCore.head) 'Existing branch changed.'
}
Case 'existing destination is refused and preserved' {
    $destination=Join-Path $workspace 'worktrees/DS-804-existing'
    [void][IO.Directory]::CreateDirectory($destination)
    [IO.File]::WriteAllText((Join-Path $destination 'keep.txt'),'Keep existing fixture target.')
    Throws {New-DsTask @newArgs -TaskId DS-804 -Slug existing -Scope Core -Apply} 'directory already exists'
    Assert (Test-Path -LiteralPath (Join-Path $destination 'keep.txt')) 'Destination overwritten.'
}
Case 'workspace lock survives slow holders and keeps bounded refusal' {
    & (Join-Path $PSScriptRoot 'Test-WorkspaceLock.ps1') -OutputDirectory (Join-Path $fixture 'lock-fixtures') | Out-Null
}
Case 'concurrent task provisioning preserves both independent indexes' {
    $processes=@(foreach($spec in @(@('DS-805','parallel-a'),@('DS-806','parallel-b'))){
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-File',(Join-Path $PSScriptRoot '../New-DanshengTask.ps1'),'-CoreRepo',$core,'-AppRepo',$app,'-WorkspaceRoot',$workspace,'-TaskId',$spec[0],'-Slug',$spec[1],'-Kind','chore','-Scope','Core','-Owner','fixture-agent','-Apply')){$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start;[void]$process.Start()
        [pscustomobject]@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
    })
    foreach($entry in $processes){
        try{Assert ($entry.process.WaitForExit(60000)) 'Concurrent creator did not finish.';$errorText=$entry.stderr.GetAwaiter().GetResult();Assert ($entry.process.ExitCode -eq 0) "Concurrent creation failed: $errorText";[void]$entry.stdout.GetAwaiter().GetResult()}
        finally{$entry.process.Dispose()}
    }
    $a=(Get-DsTaskStatus $workspace 'DS-805-parallel-a').worktrees[0].path
    $b=(Get-DsTaskStatus $workspace 'DS-806-parallel-b').worktrees[0].path
    [IO.File]::WriteAllText((Join-Path $a 'agent-a.txt'),'Synthetic agent A task.')
    [IO.File]::WriteAllText((Join-Path $b 'agent-b.txt'),'Synthetic agent B task.')
    [void](Invoke-DsGit $a @('add','--','agent-a.txt'))
    Assert (-not (Test-Path -LiteralPath (Join-Path $b 'agent-a.txt'))) 'A overwrote B.'
    Assert (-not (Invoke-DsGit $b @('diff','--cached','--name-only')).text) 'A staging leaked into B index.'
    Assert ((Get-DsRepository $a).common_dir -eq (Get-DsRepository $b).common_dir) 'Test used clones instead of Git worktrees.'
}
Case 'dirty task cannot close and its edited file survives' {
    Throws {Close-DsTask $workspace 'DS-805-parallel-a' 'fixture-agent' -Apply -ConfirmRemoval} 'retained'
    Assert (Test-Path -LiteralPath (Join-Path $workspace 'worktrees/DS-805-parallel-a/core/agent-a.txt')) 'Dirty worktree disappeared.'
}
Case 'ignored important task data blocks closure' {
    $tree=(Get-DsTaskStatus $workspace 'DS-801-core-only').worktrees[0].path
    [void][IO.Directory]::CreateDirectory((Join-Path $tree 'build'))
    [IO.File]::WriteAllText((Join-Path $tree 'build/keep.txt'),'Synthetic ignored data.')
    Throws {Close-DsTask $workspace 'DS-801-core-only' 'fixture-agent' -Apply -ConfirmRemoval} 'retained'
    Assert (Test-Path -LiteralPath (Join-Path $tree 'build/keep.txt')) 'Ignored file was lost.'
}
Case 'clean closure is dry-run by default and needs explicit removal confirmation' {
    $plan=Close-DsTask $workspace 'DS-802-app-only' 'fixture-agent'
    Assert ($plan.eligible -and -not $plan.applied -and (Test-Path -LiteralPath $plan.paths[0])) 'Close dry-run mutated tree.'
    Throws {Close-DsTask $workspace 'DS-802-app-only' 'fixture-agent' -Apply} 'ConfirmRemoval'
}
Case 'clean fixture closure retains branch, record and runtime data' {
    $before=Get-DsTaskStatus $workspace 'DS-802-app-only'
    [void](Close-DsTask $workspace 'DS-802-app-only' 'fixture-agent' -Apply -ConfirmRemoval)
    Assert (-not (Test-Path -LiteralPath $before.worktrees[0].path)) 'Clean task not removed.'
    Assert (Test-Path -LiteralPath $before.runtime_root) 'Runtime directory was deleted.'
    Assert ((Invoke-DsGit $app @('show-ref','--verify','--quiet','refs/heads/chore/DS-802-app-only') @(0,1)).exit_code -eq 0) 'Task branch was deleted.'
}
Case 'a tampered record cannot point cleanup at main' {
    $recordPath=Join-Path $workspace 'local/tasks/DS-803-paired.json'
    $record=Get-Content -Raw -LiteralPath $recordPath|ConvertFrom-Json
    $record.components[0].path=$core
    Write-DsJson $recordPath $record -ReplaceOwned
    Throws {Close-DsTask $workspace 'DS-803-paired' 'fixture-agent' -Apply -ConfirmRemoval} 'outside the registered'
    Assert (Test-Path -LiteralPath (Join-Path $core 'README.md')) 'Main was touched.'
}
Case 'source HEAD/index/workspace identities are unchanged after tasks' {
    Assert ((Get-DsRepository $core).head -eq $initialCore.head -and (Get-DsRepository $app).head -eq $initialApp.head) 'Main history changed.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $core '.git/index')).Hash -eq $coreIndex -and (Get-FileHash -LiteralPath (Join-Path $app '.git/index')).Hash -eq $appIndex) 'Reference indexes changed.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $workspace '.git'))) 'Workspace became monorepo.'
}
Case 'standalone clone cannot masquerade as a registered task worktree' {
    $fake=Seed 'ordinary workspace/worktrees/DS-812-fake-clone/core'
    $fakeInfo=Get-DsRepository $fake
    $record=[pscustomobject]@{format='dansheng-task-v1';key='DS-812-fake-clone';workspace=$workspace;branch='main';owner='fixture-agent';state='ready';runtime_root=(Join-Path $workspace 'local/runtime/DS-812-fake-clone');core_repository=$fake;app_repository=$app;core_common_dir=$fakeInfo.common_dir;app_common_dir=$initialApp.common_dir;components=@([pscustomobject]@{name='core';path=$fake;repository=$fake;common_dir=$fakeInfo.common_dir;base_sha=$fakeInfo.head})}
    Write-DsJson (Join-Path $workspace 'local/tasks/DS-812-fake-clone.json') $record
    Throws {Get-DsTaskStatus $workspace 'DS-812-fake-clone'} 'linked Git worktree|overlaps a product source'
}
Case 'native SDK lock validates exact container and embedded payload bytes' {
    $script:sdkRoot=Join-Path $fixture 'synthetic-sdk';[void][IO.Directory]::CreateDirectory($sdkRoot)
    $script:sdkFile=Join-Path $sdkRoot 'fixture.aar'
    $archive=[IO.Compression.ZipFile]::Open($sdkFile,[IO.Compression.ZipArchiveMode]::Create)
    $entries=@(foreach($name in @('jni/arm64-v8a/libdansheng_ffi.so','jni/x86_64/libdansheng_ffi.so')){
        $bytes=[Text.Encoding]::UTF8.GetBytes("Synthetic container fixture, not executable: $name")
        $entry=$archive.CreateEntry($name);$stream=$entry.Open();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
        $hasher=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
        [pscustomobject]@{entry=$name;bytes=$bytes.Length;sha256=$hash;staging_sha256=$hash}
    });$archive.Dispose()
    $resources=@(foreach($name in (Get-DsCoreResourcePaths)){
        $path=Join-Path $sdkRoot "resources/$name";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path,"Synthetic runtime fixture: $name")
        [pscustomobject]@{path=$name;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
    })
    $script:sdkLock=[pscustomobject]@{format='dansheng-core-lock-v1';mode='native-sdk';state='development_snapshot';core=[pscustomobject]@{version='0.1.0';commit=$null;source_sha256=('1'*64);adapter_source_sha256=('2'*64);rust_toolchain='1.99.1';api_version=1;abi_version=1};binding=[pscustomobject]@{kind='pigeon-jni';generator_version='29.1.1';pubspec_lock_sha256=('3'*64)};artifact=[pscustomobject]@{name='fixture.aar';format='aar';platform='android';abis=@('arm64-v8a','x86_64');bytes=(Get-Item -LiteralPath $sdkFile).Length;sha256=(Get-FileHash -LiteralPath $sdkFile).Hash.ToLowerInvariant();native_entries=$entries;packaged_receipt_complete=$true;acquisition_uri=$null};resources=$resources}
    $script:sdkLockFile=Join-Path $sdkRoot 'core.lock.json';Write-DsJson $sdkLockFile $sdkLock
    $verified=& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot | ConvertFrom-Json
    Assert $verified.verified 'Synthetic SDK container did not verify.'
}
Case 'SDK lock refuses missing or duplicated required resources' {
    $original=$sdkLock.resources
    try{
        $sdkLock.resources=@($original|Select-Object -Skip 1);Write-DsJson $sdkLockFile $sdkLock -ReplaceOwned
        Throws {& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot} 'complete unique runtime'
        $sdkLock.resources=@($original[0])+$original[0..5];Write-DsJson $sdkLockFile $sdkLock -ReplaceOwned
        Throws {& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot} 'complete unique runtime'
    }finally{$sdkLock.resources=$original;Write-DsJson $sdkLockFile $sdkLock -ReplaceOwned}
}
Case 'SDK lock refuses resource byte changes before a build' {
    $path=Join-Path $sdkRoot "resources/$($sdkLock.resources[0].path)"
    $bytes=[IO.File]::ReadAllBytes($path)
    try{[IO.File]::AppendAllText($path,'Synthetic changed bytes.');Throws {& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot} 'runtime resource differs'}
    finally{[IO.File]::WriteAllBytes($path,$bytes)}
}
Case 'Android adapter fingerprint changes with platform host source' {
    $root=Join-Path $fixture 'synthetic-adapter'
    foreach($name in @('build.gradle.kts','settings.gradle.kts','gradle.properties','adapter/build.gradle.kts','adapter/src/main/Host.kt')){
        $path=Join-Path $root "platform/android/$name";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,"Synthetic adapter fixture: $name")
    }
    $before=Get-DsAdapterSourceHash $root
    [IO.File]::AppendAllText((Join-Path $root 'platform/android/adapter/src/main/Host.kt'),'Changed platform host.')
    Assert ($before -match '^[a-f0-9]{64}$' -and (Get-DsAdapterSourceHash $root) -ne $before) 'Adapter changes did not alter identity.'
}
Case 'development snapshot is refused as a stable release dependency' {
    Throws {& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot -ForRelease} 'stable release dependency'
}
Case 'string false cannot impersonate a packaged receipt boolean' {
    $original=$sdkLock.artifact.packaged_receipt_complete
    try{
        $sdkLock.artifact.packaged_receipt_complete='false';Write-DsJson $sdkLockFile $sdkLock -ReplaceOwned
        Throws {& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot -ForRelease} 'JSON boolean'
    }finally{$sdkLock.artifact.packaged_receipt_complete=$original;Write-DsJson $sdkLockFile $sdkLock -ReplaceOwned}
}
Case 'SDK payload/size tampering is refused before a build' {
    [IO.File]::AppendAllText($sdkFile,'Synthetic tampering.')
    Throws {& (Join-Path $PSScriptRoot '../Test-DanshengCoreDependency.ps1') -LockFile $sdkLockFile -ArtifactDirectory $sdkRoot} 'SHA256/size'
}
$proof=New-DsTask @newArgs -TaskId DS-810 -Slug real-agent-a -Scope Core -Apply
$proofB=New-DsTask @newArgs -TaskId DS-811 -Slug real-agent-b -Scope Core -Apply
$report=[pscustomobject]@{format='dansheng-workflow-fixtures-v1';generated_utc=[DateTime]::UtcNow.ToString('o');passed=@($results|Where-Object passed).Count;failed=@($results|Where-Object{-not $_.passed}).Count;fixture_root=$fixture;workspace=$workspace;core_repository=$core;app_repository=$app;tests=@($results);real_agent_probe_a=$proof.status.worktrees[0].path;real_agent_probe_b=$proofB.status.worktrees[0].path;product_repositories_modified=$false;note='Synthetic local Git repositories and process-concurrency tests; this report alone is not evidence of two AI agents or remote CI.'}
Write-DsJson (Join-Path $fixture 'results.json') $report
$report|Select-Object -ExcludeProperty tests|ConvertTo-Json -Depth 5
