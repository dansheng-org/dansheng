#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SnapshotFile,[Parameter(Mandatory)][string]$WorkspaceRoot)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
$taskSnapshots=Get-Content -Raw -LiteralPath (Get-DsPath $SnapshotFile)|ConvertFrom-Json
$taskPlans=@(foreach($taskSnapshot in $taskSnapshots){
    $taskRepo=Get-DsRepository $taskSnapshot.original
    if($taskRepo.head -or $taskRepo.branch -ne 'main'){throw 'Bootstrap plan only applies to an unchanged unborn main; no action will be taken.'}
    $taskIndex=Join-Path $taskRepo.path '.git/index'
    $taskIndexHash=if(Test-Path -LiteralPath $taskIndex){(Get-FileHash -LiteralPath $taskIndex).Hash}else{$null}
    if($taskIndexHash -ne $taskSnapshot.original_index_sha256){throw 'Original index changed; review again instead of replacing it.'}
    foreach($taskFile in $taskSnapshot.files){
        $taskPath=Get-DsPath (Join-Path $taskRepo.path $taskFile.path)
        if(-not(Test-DsWithin $taskRepo.path $taskPath) -or (Get-FileHash -LiteralPath $taskPath).Hash -ne $taskFile.sha256){throw 'Source snapshot changed; bootstrap approval plan is stale.'}
    }
    $taskGenerated=@($taskSnapshot.files|Where-Object {$_.path -match '(^|/)(build|target|\.gradle|\.dart_tool|node_modules)(/|$)'})
    $taskSources=@($taskSnapshot.files|Where-Object {$_.path -notmatch '(^|/)(build|target|\.gradle|\.dart_tool|node_modules)(/|$)'})
    [pscustomobject]@{repository=$taskRepo.path;name=$taskSnapshot.name;snapshot_files=$taskSnapshot.files.Count;source_files=$taskSources.Count;existing_index_sha256=$taskIndexHash;source_paths=@($taskSources|ForEach-Object path);excluded_private_paths=@($taskSnapshot.excluded_private_paths);excluded_generated_paths=@($taskGenerated|ForEach-Object path);proposed_initial_branch='main';preparation_branch='chore/DS-001-repository-workflow';preparation_path=$taskSnapshot.worktree;effects=@('Stage only the explicitly reviewed source paths with real content; exclude generated snapshot files.','Create the first local main commit; no existing commits are rewritten.','Attach the previously unborn preparation branch to that exact baseline after verifying its independent review index; do not reuse the entire review index as the initial commit.','Keep source files, ignored data, credentials, signing identities and research recovery snapshots intact.');remote_operations=@()}
})
[pscustomobject]@{format='dansheng-bootstrap-approval-plan-v1';read_only=$true;requires_user_approval=$true;workspace=(Get-DsPath $WorkspaceRoot);product_repositories=$taskPlans;not_executed=@('git add in original main','initial product commits','branch activation','remote creation/change/push/PR/merge','research migration','deletion/cleanup');note='This script only validates and reports a concrete plan. It never initializes, stages, commits, resets, moves branches or publishes.'}|ConvertTo-Json -Depth 10
