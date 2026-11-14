#Requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'core-dependency.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-tools-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$source=Join-Path $fixture 'source-core';$toolsTree=Join-Path $fixture 'tools-core';$foreign=Join-Path $fixture 'foreign-core';$app=Join-Path $fixture 'app'
foreach($path in @($source,$foreign,$app)){[void][IO.Directory]::CreateDirectory($path);& git --no-optional-locks -C $path init --initial-branch=main|Out-Null;if($LASTEXITCODE-ne0){throw 'Fixture Git init failed'}}
& git --no-optional-locks -C $source -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c "core.hooksPath=$fixture/no-hooks" commit --allow-empty -m 'Synthetic source identity'|Out-Null
& git --no-optional-locks -C $source worktree add --detach $toolsTree main 2>&1|Out-Null
if($LASTEXITCODE-ne0){throw 'Cannot register tools fixture'}
$stub=@'
param($CoreRoot,$AppRoot,$LockFile,$ArtifactDirectory,[switch]$ForRelease)
[pscustomobject]@{verified=$true;source_root=$CoreRoot;tool_root=$PSScriptRoot}|ConvertTo-Json
'@
foreach($path in @($toolsTree,$foreign)){$directory=Join-Path $path 'tools/workspace';[void][IO.Directory]::CreateDirectory($directory);[IO.File]::WriteAllText((Join-Path $directory 'Test-DanshengCoreDependency.ps1'),$stub)}
$tools=Join-Path $toolsTree 'tools/workspace';$checks=[Collections.Generic.List[string]]::new()
function Check($actual,$expected,$name){if($actual-cne$expected){throw $name};$checks.Add($name)}
Check (Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $source -CoreToolsRoot $tools) $tools 'explicit tools directory is accepted from same common repository'
Check (Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $source -CoreToolsRoot $toolsTree) $tools 'tools checkout path is accepted'
$savedTools=$env:DANSHENG_CORE_TOOLS_ROOT
try{$env:DANSHENG_CORE_TOOLS_ROOT=$tools;Check (Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $source) $tools 'tools environment override'}finally{$env:DANSHENG_CORE_TOOLS_ROOT=$savedTools}
$rejected=$false
try{Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $source -CoreToolsRoot $foreign|Out-Null}catch{$rejected=$_.Exception.Message-match'different Git repository'}
if(-not$rejected){throw 'Foreign tooling repository accepted'};$checks.Add('foreign common Git directory rejected')
$missing=$false
try{Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $source -CoreToolsRoot (Join-Path $fixture 'missing')|Out-Null}catch{$missing=$true}
if(-not$missing){throw 'Missing explicit tools accepted'};$checks.Add('missing explicit tooling rejected')
[IO.File]::WriteAllText((Join-Path $app 'core.lock.json'),'{}')
$result=Test-DanshengAppCoreDependency -AppRoot $app -CoreRoot $source -ArtifactDirectory (Join-Path $fixture 'sdk') -CoreToolsRoot $tools
Check $result.source_root $source 'validator receives original SDK source rather than tools worktree'
$gitDirPresent=Test-Path -LiteralPath Env:GIT_DIR;$savedGitDir=$env:GIT_DIR
try{$env:GIT_DIR=Join-Path $foreign '.git';Check (Get-DanshengGitCommonDirectory -Root $source) (Join-Path $source '.git') 'repository identity ignores inherited GIT_DIR';Check $env:GIT_DIR (Join-Path $foreign '.git') 'inherited GIT_DIR restored'}finally{if($gitDirPresent){$env:GIT_DIR=$savedGitDir}else{Remove-Item -LiteralPath Env:GIT_DIR -ErrorAction SilentlyContinue}}
[pscustomobject]@{passed=$checks.Count;checks=@($checks);fixture=$fixture;source_sdk_replaced=$false;real_repositories_created=$false}|ConvertTo-Json -Depth 5
