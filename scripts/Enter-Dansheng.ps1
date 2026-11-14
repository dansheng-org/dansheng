#Requires -Version 7.0
[CmdletBinding()]
param([string]$RuntimeRoot,[string]$ToolchainRoot,[string]$ArtifactDirectory)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$top=(& git --no-optional-locks -C $repo rev-parse --show-toplevel)
if($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($top) -ne $repo){throw 'Run the entrypoint from a registered monorepo checkout.'}
# Public instructions are versioned in docs; local entrypoints contain no private data.
if(-not(Test-Path -LiteralPath (Join-Path $repo 'AGENTS.md'))){
    [IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'), "Read docs/AGENT_POLICY.md, docs/DEVELOPMENT_WORKFLOW.md and docs/CORE_COMPATIBILITY.md before work. One monorepo, one task worktree. Automatically run scripts/Enter-Dansheng.ps1 before builds. Local credentials and signing state must never enter source or prompts.`n")
}
if(-not(Test-Path -LiteralPath (Join-Path $repo 'CLAUDE.md'))){[IO.File]::WriteAllText((Join-Path $repo 'CLAUDE.md'), "@AGENTS.md`n")}
$app=Join-Path $repo 'apps/dansheng_app'
$core=Join-Path $repo 'core'
. (Join-Path $app 'scripts/core-dependency.ps1')
$common=Get-DanshengGitCommonDirectory $repo
$reuseEnteredRuntime=$false
if(-not $RuntimeRoot -and $env:DANSHENG_TASK_RUNTIME){
    $enteredOwner=Join-Path $env:DANSHENG_TASK_RUNTIME 'owner.json'
    if(Test-Path -LiteralPath $enteredOwner){
        $entered=Get-Content -LiteralPath $enteredOwner -Raw|ConvertFrom-Json
        if($entered.worktree -eq $repo -and $entered.common_dir -eq $common){$RuntimeRoot=$env:DANSHENG_TASK_RUNTIME;$reuseEnteredRuntime=$true}
    }
}
if(-not $RuntimeRoot){
    $identity=if($IsWindows){$repo.ToLowerInvariant()}else{$repo}
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).Substring(0,12).ToLowerInvariant()
    $base=if($IsWindows){'D:/DevCache/dansheng/runtime'}else{Join-Path ([IO.Path]::GetTempPath()) 'dansheng-runtime'}
    $RuntimeRoot=Join-Path $base $digest
}
$runtime=Get-DanshengAppCheckedPath $RuntimeRoot
$comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$treeLines=@(& git --no-optional-locks -C $repo worktree list --porcelain)
if($LASTEXITCODE -ne 0){throw 'Cannot verify registered source boundaries.'}
$sourceRoots=@($repo,(Split-Path -Parent $common)) + @($treeLines|Where-Object {$_ -like 'worktree *'}|ForEach-Object {[IO.Path]::GetFullPath($_.Substring(9)).TrimEnd('\','/')})
foreach($source in $sourceRoots){
    if($runtime.Equals($source,$comparison)-or $runtime.StartsWith($source+[IO.Path]::DirectorySeparatorChar,$comparison)-or $source.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'Runtime must stay separate from every registered source checkout.'}
}
$ownerFile=Join-Path $runtime 'owner.json'
if(Test-Path $ownerFile){
    $owner=Get-Content $ownerFile -Raw|ConvertFrom-Json
    if($owner.worktree -ne $repo -or $owner.common_dir -ne $common){throw 'Runtime belongs to another checkout; choose a fresh runtime.'}
}
[void][IO.Directory]::CreateDirectory($runtime)
if(-not(Test-Path $ownerFile)){[ordered]@{worktree=$repo;common_dir=$common}|ConvertTo-Json|Set-Content $ownerFile}
$env:DANSHENG_TASK_RUNTIME=$runtime
$env:DANSHENG_CORE_ROOT=$core
$env:DANSHENG_CORE_TOOLS_ROOT=Join-Path $core 'tools/workspace'
$env:DANSHENG_CORE_LOCK_FILE=Join-Path $app 'core.lock.json'
if(-not $env:PUB_HOSTED_URL){$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'}
$env:DANSHENG_CORE_SDK_DIR=if($ArtifactDirectory){[IO.Path]::GetFullPath($ArtifactDirectory)}elseif($reuseEnteredRuntime -and $env:DANSHENG_CORE_SDK_DIR){$env:DANSHENG_CORE_SDK_DIR}else{Join-Path $runtime 'native-sdk'}
$paths=@{CARGO_HOME='cargo-home';CARGO_TARGET_DIR='cargo-target';PUB_CACHE='pub-cache';GRADLE_USER_HOME='gradle-cache';npm_config_cache='npm-cache';ANDROID_USER_HOME='android-user';ANDROID_AVD_HOME='android-user/avds';TEMP='tmp';TMP='tmp';DANSHENG_PROFILE='profiles/core';DANSHENG_LAB_PROFILE='profiles/lab';DANSHENG_BROWSER_PROFILE='browser'}
foreach($name in $paths.Keys){$value=Join-Path $runtime $paths[$name];[void][IO.Directory]::CreateDirectory($value);[Environment]::SetEnvironmentVariable($name,$value,'Process')}
foreach($dir in @('logs','artifacts','signing')){[void][IO.Directory]::CreateDirectory((Join-Path $runtime $dir))}
if(-not $ToolchainRoot){$ToolchainRoot=$env:DANSHENG_TOOLCHAIN_ROOT}
if(-not $ToolchainRoot -and $IsWindows -and (Test-Path 'D:/DevTools/dansheng-rust')){$ToolchainRoot='D:/DevTools/dansheng-rust'}
if($ToolchainRoot){$env:DANSHENG_TOOLCHAIN_ROOT=[IO.Path]::GetFullPath($ToolchainRoot)}
. (Join-Path $core 'scripts/dev.ps1') -ToolchainRoot $ToolchainRoot
Write-Host "Dansheng worktree: $repo"
Write-Host "Runtime: $runtime"
Write-Host "SDK selection: $env:DANSHENG_CORE_SDK_DIR (must be verified before build)"
