#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DsComparison { if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal } }
function Get-DsGitLocalEnvironmentNames {
    @('GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_CONFIG','GIT_CONFIG_PARAMETERS','GIT_CONFIG_COUNT','GIT_OBJECT_DIRECTORY','GIT_DIR','GIT_WORK_TREE','GIT_IMPLICIT_WORK_TREE','GIT_GRAFT_FILE','GIT_INDEX_FILE','GIT_NO_REPLACE_OBJECTS','GIT_REPLACE_REF_BASE','GIT_PREFIX','GIT_INTERNAL_SUPER_PREFIX','GIT_SHALLOW_FILE','GIT_COMMON_DIR')
}
function Set-DsProcessEnvironmentValue([string]$Name,[object]$Value) {
    if($Name -notmatch '^[a-zA-Z_][a-zA-Z0-9_]*$'){throw 'Invalid process environment variable name.'}
    if($null -eq $Value){Remove-Item -LiteralPath ("Env:"+$Name) -ErrorAction SilentlyContinue}
    else{[Environment]::SetEnvironmentVariable($Name,[string]$Value,'Process')}
}
function Clear-DsGitLocalEnvironment {
    $names=@(Get-DsGitLocalEnvironmentNames)+@([Environment]::GetEnvironmentVariables('Process').Keys|Where-Object {$_ -match '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$'})
    foreach($name in $names){Set-DsProcessEnvironmentValue $name $null}
}
function Invoke-DsWithCleanGitEnvironment {
    param([Parameter(Mandatory)][scriptblock]$Action,[object[]]$Arguments=@())
    $names=@(Get-DsGitLocalEnvironmentNames)+@([Environment]::GetEnvironmentVariables('Process').Keys|Where-Object {$_ -match '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$'})
    $saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try{Clear-DsGitLocalEnvironment;& $Action @Arguments}
    finally{foreach($name in $saved.Keys){Set-DsProcessEnvironmentValue $name $saved[$name]}}
}
function Get-DsPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An explicit path is required.' }
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolved -or $resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar)) { throw 'A drive/filesystem root is not a workspace.' }
    $cursor = $resolved
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path refused: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $resolved
}
function Test-DsWithin([string]$Parent,[string]$Child) {
    $parentPath = Get-DsPath $Parent; $childPath = Get-DsPath $Child
    $childPath.Equals($parentPath,(Get-DsComparison)) -or $childPath.StartsWith($parentPath+[IO.Path]::DirectorySeparatorChar,(Get-DsComparison))
}
function Get-DsCoreResourcePaths {
    'plugins/builtin/fudan-venues/manifest.json'
    'plugins/builtin/fudan-venues/host-policy.json'
    'plugins/builtin/fudan-venues/main.mjs'
    'plugins/builtin/fudan-venues/api.mjs'
    'plugins/builtin/fudan-venues/policy.mjs'
    'plugins/builtin/fudan-venues/NOTICE.md'
    'LICENSE'
}
function Get-DsAdapterSourceHash([string]$CoreRoot) {
    $base=Get-DsPath (Join-Path (Get-DsPath $CoreRoot) 'platform/android')
    Assert-DsNoLinkedDescendants (Join-Path $base 'adapter/src/main')
    $names=@('build.gradle.kts','settings.gradle.kts','gradle.properties','adapter/build.gradle.kts')
    $names+=@(Get-ChildItem -LiteralPath (Get-DsPath (Join-Path $base 'adapter/src/main')) -Recurse -File | ForEach-Object {
        [void](Get-DsPath $_.FullName)
        [IO.Path]::GetRelativePath($base,$_.FullName).Replace('\','/')
    })
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $manifest=($names|ForEach-Object { "$((Get-FileHash -LiteralPath (Get-DsPath (Join-Path $base $_))).Hash.ToLowerInvariant())  $_" }) -join "`n"
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
}
function Assert-DsNoLinkedDescendants([string]$Path) {
    $root=Get-DsPath $Path
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push($root)
    while($pending.Count){
        foreach($item in Get-ChildItem -LiteralPath $pending.Pop() -Force){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked worktree content is retained; recursive traversal/removal refused.'}
            if($item.PSIsContainer){$pending.Push($item.FullName)}
        }
    }
}
function Invoke-DsGit {
    param([string]$Repository,[string[]]$Arguments,[int[]]$AllowedExitCodes=@(0))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $localNames=@(Get-DsGitLocalEnvironmentNames)+@($start.Environment.Keys|Where-Object {$_ -match '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$'})
    foreach ($name in $localNames) { [void]$start.Environment.Remove($name) }
    $start.Environment['GIT_OPTIONAL_LOCKS']='0'
    foreach ($argument in (@('-C',$Repository)+$Arguments)) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit(); $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -notin $AllowedExitCodes) { throw "Git failed ($($process.ExitCode)): $($err.Trim())" }
        [pscustomobject]@{exit_code=$process.ExitCode;text=$out.TrimEnd("`r","`n")}
    } finally { $process.Dispose() }
}
function Get-DsRepository([string]$Path) {
    $root=Get-DsPath $Path
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Repository missing: $root" }
    $top=Get-DsPath (Invoke-DsGit $root @('rev-parse','--show-toplevel')).text
    if (-not $top.Equals($root,(Get-DsComparison))) { throw 'Supply the actual repository/worktree root, not its parent or a subdirectory.' }
    $common=Get-DsPath (Invoke-DsGit $root @('rev-parse','--path-format=absolute','--git-common-dir')).text
    $head=Invoke-DsGit $root @('rev-parse','--verify','HEAD^{commit}') @(0,128)
    $branch=Invoke-DsGit $root @('symbolic-ref','--quiet','--short','HEAD') @(0,1)
    [pscustomobject]@{path=$root;common_dir=$common;head=if ($head.exit_code -eq 0) {$head.text} else {$null};branch=if($branch.exit_code -eq 0){$branch.text}else{$null}}
}
function Get-DsLayout([string]$CoreRepo,[string]$AppRepo,[string]$WorkspaceRoot,[string]$WorktreeRoot) {
    $core=Get-DsRepository $CoreRepo; $app=Get-DsRepository $AppRepo
    if ($core.common_dir.Equals($app.common_dir,(Get-DsComparison))) { throw 'Core and App must be TWO independent Git repositories.' }
    foreach($repo in @($core,$app)){
        if(-not(Test-Path -LiteralPath (Join-Path $repo.path '.git') -PathType Container) -or -not $repo.path.Equals((Get-DsPath (Split-Path -Parent $repo.common_dir)),(Get-DsComparison))){throw 'Supply the primary Core/App repository roots as task sources, not another task worktree.'}
    }
    $workspace=Get-DsPath $WorkspaceRoot
    $trees=if($WorktreeRoot){Get-DsPath $WorktreeRoot}else{Get-DsPath (Join-Path $workspace 'worktrees')}
    foreach ($repo in @($core,$app)) { if ((Test-DsWithin $repo.path $trees) -or (Test-DsWithin $trees $repo.path)) { throw 'Worktrees must stay outside both product repositories.' } }
    $ancestor=$workspace
    while (-not (Test-Path -LiteralPath $ancestor -PathType Container)) { $ancestor=[IO.Path]::GetDirectoryName($ancestor) }
    $inside=Invoke-DsGit $ancestor @('rev-parse','--is-inside-work-tree') @(0,128)
    if ($inside.exit_code -eq 0 -and $inside.text -eq 'true') { throw 'The parent workspace must not be a Git repository.' }
    $treeAncestor=$trees
    while(-not(Test-Path -LiteralPath $treeAncestor -PathType Container)){$treeAncestor=[IO.Path]::GetDirectoryName($treeAncestor)}
    $treeInside=Invoke-DsGit $treeAncestor @('rev-parse','--is-inside-work-tree') @(0,128)
    if($treeInside.exit_code -eq 0 -and $treeInside.text -eq 'true'){throw 'The worktree parent must not be a Git repository.'}
    [pscustomobject]@{workspace=$workspace;trees=$trees;local=(Get-DsPath (Join-Path $workspace 'local'));core=$core;app=$app}
}
function Get-DsRecordedWorktreeRoot([object]$Record) {
    if($Record.PSObject.Properties['worktrees_root']){Get-DsPath $Record.worktrees_root}
    else{Get-DsPath (Join-Path $Record.workspace 'worktrees')}
}
function Get-DsTaskKey([string]$TaskId,[string]$Slug) {
    if ($TaskId -cnotmatch '^DS-[0-9]{3,8}$' -or $Slug -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $Slug.Length -gt 64) { throw 'Use DS-001 and a lowercase task slug; path/ref metacharacters are refused.' }
    "$TaskId-$Slug"
}
function Write-DsJson([string]$Path,[object]$Value,[switch]$ReplaceOwned) {
    $path=Get-DsPath $Path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    if ((Test-Path -LiteralPath $path) -and -not $ReplaceOwned) { throw 'Refusing to overwrite an existing task record.' }
    $temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12)+"`n")
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    [IO.File]::Move($temporary,$path,[bool]$ReplaceOwned)
}
function Read-DsTask([string]$WorkspaceRoot,[string]$TaskKey) {
    if ($TaskKey -cnotmatch '^DS-[0-9]{3,8}-[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Invalid task key.' }
    $root=Get-DsPath $WorkspaceRoot
    $path=Get-DsPath (Join-Path $root "local/tasks/$TaskKey.json")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Task is not registered.' }
    $record=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
    if ($record.format -ne 'dansheng-task-v1' -or $record.key -ne $TaskKey -or -not (Get-DsPath $record.workspace).Equals($root,(Get-DsComparison))) { throw 'Task record does not match its workspace identity.' }
    $treeRoot=Get-DsRecordedWorktreeRoot $record
    foreach($name in @('core','app')){
        $sourceRoot=Get-DsPath $record.($name+'_repository')
        if((Test-DsWithin $sourceRoot $treeRoot) -or (Test-DsWithin $treeRoot $sourceRoot)){throw 'Registered worktree parent overlaps a product source repository.'}
    }
    $runtime=Get-DsPath (Join-Path $root "local/runtime/$TaskKey")
    if (-not (Get-DsPath $record.runtime_root).Equals($runtime,(Get-DsComparison))) { throw 'Task runtime directory differs from its registered task identity.' }
    foreach($folder in @('cargo-target','cargo-home','pub-cache','gradle-cache','npm-cache','tmp','profiles/core','browser','android-user/avds','artifacts','logs')) { [void](Get-DsPath (Join-Path $runtime $folder)) }
    $record
}
function Open-DsWorkspaceLock([string]$Path) {
    $checked=Get-DsPath $Path
    for($attempt=0;$attempt -lt 100;$attempt++){
        try { return [IO.File]::Open($checked,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
    }
    throw 'Workspace is busy; no task changes were applied.'
}
function Get-DsWorktreeState([object]$Record,[object]$Component) {
    $expected=Get-DsPath (Join-Path (Get-DsRecordedWorktreeRoot $Record) "$($Record.key)/$($Component.name)")
    $path=Get-DsPath $Component.path
    if (-not $path.Equals($expected,(Get-DsComparison))) { throw 'Task record points outside the registered task tree.' }
    if($Component.name -notin @('core','app') -or (Test-Path -LiteralPath (Join-Path $path '.git') -PathType Container)){throw 'A task must be a linked Git worktree, not a standalone clone/main directory.'}
    $expectedCommon=Get-DsPath $Record.($Component.name+'_common_dir')
    if(-not (Get-DsPath $Component.common_dir).Equals($expectedCommon,(Get-DsComparison))){throw 'Component Git identity differs from task registration.'}
    if(-not (Get-DsPath $Component.repository).Equals((Get-DsPath $Record.($Component.name+'_repository')),(Get-DsComparison))){throw 'Component source repository differs from task registration.'}
    $repository=Get-DsRepository $Component.repository
    if(-not $repository.common_dir.Equals($expectedCommon,(Get-DsComparison))){throw 'Component source repository differs from its registered Git identity.'}
    if(-not(Test-Path -LiteralPath (Join-Path $repository.path '.git') -PathType Container) -or -not $repository.path.Equals((Get-DsPath (Split-Path -Parent $expectedCommon)),(Get-DsComparison))){throw 'Component source must remain its primary repository root.'}
    $actual=Get-DsRepository $path
    if (-not $actual.common_dir.Equals((Get-DsPath $Component.common_dir),(Get-DsComparison)) -or $actual.branch -ne $Record.branch) { throw 'Task branch or Git common directory changed; no mutation permitted.' }
    $listed=(Invoke-DsGit $path @('worktree','list','--porcelain')).text
    if (-not ($listed.Replace('\','/') -split "`n" | Where-Object { $_ -eq ('worktree '+$path.Replace('\','/')) })) { throw 'Directory is not a Git-registered worktree.' }
    $changes=(Invoke-DsGit $path @('-c','core.quotePath=false','status','--porcelain=v1','--untracked-files=all')).text
    $ignored=(Invoke-DsGit $path @('-c','core.quotePath=false','ls-files','--others','--ignored','--exclude-standard')).text
    [pscustomobject]@{name=$Component.name;path=$path;head=$actual.head;branch=$actual.branch;dirty=[bool]$changes;changes=@($changes -split "`n"|Where-Object{$_});ignored_files=@($ignored -split "`n"|Where-Object{$_})}
}
function Get-DsTaskStatus {
    param([string]$WorkspaceRoot,[string]$TaskKey)
    $record=Read-DsTask $WorkspaceRoot $TaskKey
    $states=@(foreach ($component in $record.components) {
        if ($record.state -in @('closed','partial','close_partial') -and -not (Test-Path -LiteralPath $component.path)) { [pscustomobject]@{name=$component.name;path=$component.path;missing=$true;state=$record.state} }
        else { Get-DsWorktreeState $record $component }
    })
    [pscustomobject]@{task=$record.key;owner=$record.owner;branch=$record.branch;state=$record.state;worktrees=$states;runtime_root=$record.runtime_root;exact_bases=$record.components|Select-Object name,base_sha}
}
function New-DsTask {
    param([string]$CoreRepo,[string]$AppRepo,[string]$WorkspaceRoot,[string]$TaskId,[string]$Slug,[ValidateSet('feat','fix','refactor','chore')][string]$Kind='feat',[ValidateSet('Core','App','Both')][string]$Scope='Both',[string]$Owner,[string]$BaseRef='main',[string]$WorktreeRoot,[switch]$Apply)
    $layout=Get-DsLayout $CoreRepo $AppRepo $WorkspaceRoot $WorktreeRoot
    $key=Get-DsTaskKey $TaskId $Slug
    if ([string]::IsNullOrWhiteSpace($Owner) -or $Owner.Length -gt 80 -or $Owner -match '[\r\n]') { throw 'An explicit task owner is required.' }
    $branch="$Kind/$key"; [void](Invoke-DsGit $layout.core.path @('check-ref-format','--branch',$branch))
    $recordPath=Get-DsPath (Join-Path $layout.local "tasks/$key.json")
    if (Test-Path -LiteralPath $recordPath) {
        $existing=Read-DsTask $WorkspaceRoot $key
        if(-not (Get-DsRecordedWorktreeRoot $existing).Equals($layout.trees,(Get-DsComparison))){throw 'Task already belongs to another worktree parent.'}
        if ($existing.owner -ne $Owner -or $existing.branch -ne $branch -or $existing.scope -ne $Scope -or $existing.core_common_dir -ne $layout.core.common_dir -or $existing.app_common_dir -ne $layout.app.common_dir -or $existing.state -ne 'ready') { throw 'Task already exists with another identity or an incomplete/closed state.' }
        $status=Get-DsTaskStatus $WorkspaceRoot $key
        [pscustomobject]@{applied=$false;idempotent=$true;status=$status}; return
    }
    $pair=Get-DsPath (Join-Path $layout.trees $key)
    if (Test-Path -LiteralPath $pair) { throw 'Task directory already exists without a matching record; nothing will be overwritten.' }
    $runtime=Get-DsPath (Join-Path $layout.local "runtime/$key")
    if(Test-Path -LiteralPath $runtime){throw 'Task runtime directory already exists without a matching record; preserve and review it.'}
    $runtimeFolders=@('cargo-target','cargo-home','pub-cache','gradle-cache','npm-cache','tmp','profiles/core','browser','android-user/avds','artifacts','logs')
    foreach($folder in $runtimeFolders){[void](Get-DsPath (Join-Path $runtime $folder))}
    $components=@(foreach ($name in @('core','app')) {
        if (($Scope -eq 'Core' -and $name -eq 'app') -or ($Scope -eq 'App' -and $name -eq 'core')) { continue }
        $repo=$layout.$name
        if (-not $repo.head) { throw "NeedsInitialCommit: $name has no committed baseline. Do not initialize/reset or seed production branches automatically." }
        $dirty=(Invoke-DsGit $repo.path @('status','--porcelain=v1','--untracked-files=all')).text
        if ($dirty) { throw "Source repository $name has uncommitted content; preserve it and resolve the baseline explicitly." }
        $base=(Invoke-DsGit $repo.path @('rev-parse','--verify',"$BaseRef^{commit}")).text
        $exists=Invoke-DsGit $repo.path @('show-ref','--verify','--quiet',"refs/heads/$branch") @(0,1)
        $claimed=(Invoke-DsGit $repo.path @('worktree','list','--porcelain')).text -split "`n" | Where-Object { $_ -eq "branch refs/heads/$branch" }
        if ($exists.exit_code -eq 0 -or $claimed) { throw 'Branch is already present/claimed; never use -B or --force.' }
        [pscustomobject]@{name=$name;repository=$repo.path;common_dir=$repo.common_dir;path=(Get-DsPath (Join-Path $pair $name));base_sha=$base}
    })
    $record=[pscustomobject]@{format='dansheng-task-v1';key=$key;task_id=$TaskId;slug=$Slug;scope=$Scope;owner=$Owner;branch=$branch;workspace=$layout.workspace;worktrees_root=$layout.trees;core_repository=$layout.core.path;app_repository=$layout.app.path;core_common_dir=$layout.core.common_dir;app_common_dir=$layout.app.common_dir;runtime_root=$runtime;state='provisioning';created_utc=[DateTime]::UtcNow.ToString('o');components=$components;created_components=@()}
    if (-not $Apply) { [pscustomobject]@{applied=$false;plan=$record}; return }
    [void][IO.Directory]::CreateDirectory($layout.local)
    $lock=Open-DsWorkspaceLock (Join-Path $layout.local 'workspace.lock')
    try {
        if ((Test-Path -LiteralPath $recordPath) -or (Test-Path -LiteralPath $pair)) { throw 'Another creator reserved this task; no directory or branch will be overwritten.' }
        if(Test-Path -LiteralPath (Get-DsPath $runtime)){throw 'Task runtime appeared concurrently; no existing runtime is reused.'}
        foreach($folder in $runtimeFolders){[void](Get-DsPath (Join-Path $runtime $folder))}
        foreach ($component in $components) {
            if ((Invoke-DsGit $component.repository @('show-ref','--verify','--quiet',"refs/heads/$branch") @(0,1)).exit_code -eq 0) { throw 'Branch appeared concurrently.' }
            $fresh=Get-DsRepository $component.repository
            if ($fresh.head -ne $layout.($component.name).head -or (Invoke-DsGit $component.repository @('status','--porcelain=v1','--untracked-files=all')).text) { throw 'Source repository changed before task creation; preserve and review its new content.' }
            if ((Invoke-DsGit $component.repository @('worktree','list','--porcelain')).text -split "`n" | Where-Object { $_ -eq "branch refs/heads/$branch" }) { throw 'Branch appeared concurrently in another worktree.' }
        }
        Write-DsJson $recordPath $record
        [void][IO.Directory]::CreateDirectory($pair)
        foreach ($component in $components) {
            [void](Invoke-DsGit $component.repository @('worktree','add','-b',$branch,$component.path,$component.base_sha))
            [void](Get-DsWorktreeState $record $component)
            $record.created_components=@($record.created_components)+$component.name
            Write-DsJson $recordPath $record -ReplaceOwned
        }
        foreach ($folder in $runtimeFolders) { [void][IO.Directory]::CreateDirectory((Get-DsPath (Join-Path $record.runtime_root $folder))) }
        $note=Join-Path $pair 'TASK.md'
        $text="# $key`n`nOwner: $Owner`nBranch: $branch`nWrite only the assigned component worktree. Original repositories are read-only.`nExact bases are recorded in $recordPath.`nDo not commit/merge/publish or run remote writes without the required authorization.`n"
        [IO.File]::WriteAllText($note,$text,[Text.UTF8Encoding]::new($false))
        $record.state='ready'; Write-DsJson $recordPath $record -ReplaceOwned
        [pscustomobject]@{applied=$true;status=(Get-DsTaskStatus $WorkspaceRoot $key)}
    } catch {
        if (Test-Path -LiteralPath $recordPath) { $record.state='partial'; Write-DsJson $recordPath $record -ReplaceOwned }
        throw
    } finally { $lock.Dispose() }
}
function Close-DsTask {
    param([string]$WorkspaceRoot,[string]$TaskKey,[string]$Owner,[switch]$Apply,[switch]$ConfirmRemoval)
    $record=Read-DsTask $WorkspaceRoot $TaskKey
    if ($record.owner -ne $Owner) { throw 'Only the registered owner may request closure.' }
    if ($record.state -eq 'closed') { Get-DsTaskStatus $WorkspaceRoot $TaskKey; return }
    if ($record.state -ne 'ready') { throw 'An incomplete task requires manual review; automatic cleanup is refused.' }
    $states=@(foreach ($component in $record.components) { Get-DsWorktreeState $record $component })
    $eligible=-not @($states|Where-Object{$_.dirty -or $_.ignored_files.Count}).Count
    $plan=[pscustomobject]@{applied=$false;eligible=$eligible;task=$record.key;paths=@($states|ForEach-Object path);branches_retained=$true;runtime_retained=$record.runtime_root;worktrees=$states}
    if (-not $Apply) { $plan; return }
    if (-not $ConfirmRemoval) { throw 'Explicit -ConfirmRemoval is required after reviewing the affected paths.' }
    if (-not $eligible) { throw 'Dirty/untracked/ignored files are retained; closure refused.' }
    $local=Get-DsPath (Join-Path $record.workspace 'local')
    $lock=Open-DsWorkspaceLock (Join-Path $local 'workspace.lock')
    try {
        foreach ($component in $record.components) {
            $fresh=Get-DsWorktreeState $record $component
            if ($fresh.dirty -or $fresh.ignored_files.Count) { throw 'Worktree changed before closure.' }
            Assert-DsNoLinkedDescendants $fresh.path
        }
        foreach ($component in $record.components) {
            $path=Get-DsPath $component.path
            if (-not (Test-DsWithin (Get-DsRecordedWorktreeRoot $record) $path) -or $path.Equals((Get-DsPath $component.repository),(Get-DsComparison))) { throw 'Final cleanup path is not a task worktree.' }
            [void](Invoke-DsGit $component.repository @('worktree','remove',$path))
        }
        $record.state='closed'; Write-DsJson (Join-Path $local "tasks/$TaskKey.json") $record -ReplaceOwned
        Get-DsTaskStatus $WorkspaceRoot $TaskKey
    } catch {
        $record.state='close_partial'
        Write-DsJson (Join-Path $local "tasks/$TaskKey.json") $record -ReplaceOwned
        throw
    } finally { $lock.Dispose() }
}
Export-ModuleMember -Function Get-DsPath,Test-DsWithin,Invoke-DsGit,Get-DsRepository,Get-DsLayout,Get-DsRecordedWorktreeRoot,Get-DsTaskKey,Read-DsTask,Get-DsTaskStatus,New-DsTask,Close-DsTask,Write-DsJson,Get-DsCoreResourcePaths,Get-DsAdapterSourceHash,Get-DsGitLocalEnvironmentNames,Clear-DsGitLocalEnvironment,Set-DsProcessEnvironmentValue,Invoke-DsWithCleanGitEnvironment
