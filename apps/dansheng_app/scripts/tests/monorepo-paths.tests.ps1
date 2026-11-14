#Requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'core-dependency.ps1')
. (Join-Path $scripts 'prerelease-common.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-monorepo-'+[guid]::NewGuid().ToString('N'))
$first=Join-Path $fixture 'first/checkout'
$second=Join-Path $fixture 'second/checkout'
$checks=[Collections.Generic.List[string]]::new()
function Check($Actual,$Expected,[string]$Name){if($Actual-cne$Expected){throw "$Name failed: $Actual != $Expected"};$checks.Add($Name)}
function Invoke-FixtureGit([string]$Root,[string[]]$Arguments){
    & git --no-optional-locks -C $Root @Arguments 2>&1|Out-Null
    if($LASTEXITCODE-ne0){throw 'Synthetic Git fixture setup failed.'}
}
function Core([string]$Root){
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'include'))
    [IO.File]::WriteAllText((Join-Path $Root 'Cargo.toml'),'[workspace]')
    [IO.File]::WriteAllText((Join-Path $Root 'include/dansheng.h'),'/* synthetic ABI */')
}
$names=@('DANSHENG_CORE_ROOT','DANSHENG_CORE_TOOLS_ROOT','DANSHENG_TASK_RUNTIME','DANSHENG_WORKSPACE_ROOT')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$null)}
try{
    [void][IO.Directory]::CreateDirectory($first)
    Invoke-FixtureGit $first @('init','--initial-branch=main')
    Invoke-FixtureGit $first @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','-c',"core.hooksPath=$fixture/no-hooks",'commit','--allow-empty','-m','Synthetic monorepo baseline')
    Invoke-FixtureGit $first @('worktree','add','--detach',$second,'HEAD')
    $app=Join-Path $first 'apps/dansheng_app'
    $otherApp=Join-Path $second 'apps/dansheng_app'
    foreach($path in @($app,$otherApp)){[void][IO.Directory]::CreateDirectory($path)}
    $core=Join-Path $first 'core'
    Core $core
    Core (Join-Path $first 'apps/dansheng-core')
    Core (Join-Path $second 'core')
    Check (Resolve-DanshengCoreRoot -AppRoot $app) $core 'monorepo core wins over legacy sibling'
    $env:DANSHENG_CORE_ROOT='../../core'
    Check (Resolve-DanshengCoreRoot -AppRoot $otherApp) (Join-Path $second 'core') 'relative Core override follows the App root'
    $env:DANSHENG_CORE_ROOT=Join-Path $first 'apps/dansheng-core'
    Check (Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot '../../core') $core 'explicit Core source still wins over environment'
    $env:DANSHENG_CORE_ROOT=$null
    $runtime=Resolve-DanshengAppRuntimeRoot -AppRoot $app
    $otherRuntime=Resolve-DanshengAppRuntimeRoot -AppRoot $otherApp
    Check ($runtime-ne$otherRuntime) $true 'linked checkouts with identical leaf names have distinct runtimes'
    Check (Resolve-DanshengAppRuntimeRoot -AppRoot $app) $runtime 'runtime identity is deterministic'
    Check (Resolve-DanshengAppRuntimeRoot -AppRoot $app.Replace('\','/')) $runtime 'runtime identity normalizes path separators'
    if($IsWindows){Check (Resolve-DanshengAppRuntimeRoot -AppRoot $app.ToUpperInvariant()) $runtime 'Windows runtime identity ignores path case'}
    Check ($runtime.StartsWith($first+[IO.Path]::DirectorySeparatorChar)) $false 'default runtime is outside the checkout'
    Check (Resolve-DanshengAppRuntimeRoot -AppRoot $first) $runtime 'runtime is keyed by checkout root rather than component'
    Check (Get-DanshengGitCommonDirectory $app) (Get-DanshengGitCommonDirectory $otherApp) 'runtime uniqueness does not rely on common Git directory'
    $tools=Join-Path $second 'core/tools/workspace'
    [void][IO.Directory]::CreateDirectory($tools)
    [IO.File]::WriteAllText((Join-Path $tools 'Test-DanshengCoreDependency.ps1'),'# synthetic path fixture; never executed')
    Check (Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $core) $tools 'tool discovery finds core under another registered monorepo worktree'
    Check (Resolve-DanshengPrereleaseManifest $app) (Join-Path $first '.github/prerelease-sdk.json') 'monorepo manifest belongs to repository root'
    Check (Resolve-DanshengPrereleaseManifest (Join-Path $fixture 'standalone')) (Join-Path $fixture 'standalone/.github/prerelease-sdk.json') 'standalone manifest remains compatible'
    # Pinned legacy validators require a Git root for AppRoot. The compatibility
    # wrapper must omit AppRoot and preserve the exact Pub lock check itself.
    $sdk=Join-Path $fixture 'sdk'
    $validationTools=Join-Path $sdk 'validation-tools'
    foreach($path in @($validationTools,(Join-Path $sdk 'legal'),(Join-Path $first '.github'))){[void][IO.Directory]::CreateDirectory($path)}
    $validator=Join-Path $validationTools 'Test-DanshengCoreDependency.ps1'
    [IO.File]::WriteAllText($validator,@'
param($LockFile,$ArtifactDirectory,$AppRoot,$CoreRoot)
if($AppRoot-or$CoreRoot){throw 'SDK-only must not relabel the SDK source or pass a nested App to the legacy validator.'}
'{"verified":true,"state":"development_snapshot"}'
'@)
    [IO.File]::WriteAllText((Join-Path $validationTools 'Dansheng.Workspace.psm1'),'# synthetic pinned module')
    [IO.File]::WriteAllText((Join-Path $app 'pubspec.lock'),'synthetic Pub lock')
    [IO.File]::WriteAllText((Join-Path $sdk 'legal/COPYING.txt'),'synthetic license')
    [IO.File]::WriteAllText((Join-Path $sdk 'legal/NATIVE-NOTICES.txt'),'synthetic notices')
    $lock=@{core=@{commit=('a'*40);source_sha256=('b'*64);adapter_source_sha256=('c'*64)};artifact=@{sha256=('d'*64)};binding=@{pubspec_lock_sha256=(Get-FileHash (Join-Path $app 'pubspec.lock')).Hash};resources=@(@{path='LICENSE';sha256=(Get-FileHash (Join-Path $sdk 'legal/COPYING.txt')).Hash})}
    $lock|ConvertTo-Json -Depth 5|Set-Content (Join-Path $app 'core.lock.json')
    @{core_commit=$lock.core.commit;core_source_sha256=$lock.core.source_sha256;adapter_source_sha256=$lock.core.adapter_source_sha256;aar_sha256=$lock.artifact.sha256}|ConvertTo-Json|Set-Content (Join-Path $sdk 'receipt.json')
    $manifest=@{validator=@{core_commit=$lock.core.commit;files=@(foreach($name in @('Test-DanshengCoreDependency.ps1','Dansheng.Workspace.psm1')){@{name=$name;sha256=(Get-FileHash (Join-Path $validationTools $name)).Hash.ToLowerInvariant()}})}}
    $manifest|ConvertTo-Json -Depth 5|Set-Content (Resolve-DanshengPrereleaseManifest $app)
    Check (Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $validationTools).verified $true 'SDK-only compatibility supports nested App without changing the validator'
    [IO.File]::WriteAllText((Join-Path $app 'pubspec.lock'),'changed Pub lock')
    $rejected=$false
    try{Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $validationTools|Out-Null}catch{if($_.Exception.Message-ne'Flutter/Pigeon dependency lock differs.'){throw};$rejected=$true}
    Check $rejected $true 'SDK-only compatibility rejects changed Pub lock'
    [IO.File]::WriteAllText((Join-Path $app 'pubspec.lock'),'synthetic Pub lock')
    [IO.File]::WriteAllText((Join-Path $app 'pubspec_overrides.yaml'),'dependency_overrides: {}')
    $rejected=$false
    try{Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $validationTools|Out-Null}catch{if($_.Exception.Message-ne'Pre-release does not accept local Pub overrides.'){throw};$rejected=$true}
    Check $rejected $true 'SDK-only compatibility rejects local Pub overrides'
    # Remove only the file created above in this test-owned directory.
    [IO.File]::Delete((Join-Path $app 'pubspec_overrides.yaml'))
    $receiptPath=Join-Path $sdk 'receipt.json'
    $receiptText=[IO.File]::ReadAllText($receiptPath)
    $receipt=$receiptText|ConvertFrom-Json
    $receipt.core_commit='e'*40
    $receipt|ConvertTo-Json|Set-Content $receiptPath
    $rejected=$false
    try{Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $validationTools|Out-Null}catch{if($_.Exception.Message-ne'SDK producer receipt differs from core.lock.json.'){throw};$rejected=$true}
    Check $rejected $true 'SDK-only compatibility rejects a relabelled producer receipt'
    [IO.File]::WriteAllText($receiptPath,$receiptText)
    Add-Content -LiteralPath $validator -Value '# modified validator'
    $rejected=$false
    try{Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $validationTools|Out-Null}catch{if($_.Exception.Message-ne'Validation tool bytes differ from the pinned Core export.'){throw};$rejected=$true}
    Check $rejected $true 'SDK-only compatibility rejects modified validator'
    [pscustomobject]@{passed=$checks.Count;checks=@($checks);fixture=$fixture}|ConvertTo-Json -Depth 4
}finally{foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
$global:LASTEXITCODE=0
