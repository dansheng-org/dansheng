# Offline Git/ZIP fixtures only. No product commits, builds, accounts or devices.
# Retain all fixture repositories and results outside source for inspection.
#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$toolsRoot=Split-Path -Parent $PSScriptRoot
$coreScripts=Join-Path $toolsRoot '../../scripts'
Import-Module (Join-Path $toolsRoot 'Dansheng.Workspace.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $toolsRoot 'Dansheng.Environment.psm1') -Force -DisableNameChecking
. (Join-Path $coreScripts 'release-common.ps1')
$fixture=Get-DsPath $OutputDirectory
if(Test-Path -LiteralPath $fixture){throw 'Choose a new fixture directory; existing evidence is retained.'}
[void][IO.Directory]::CreateDirectory($fixture)
$results=[Collections.Generic.List[object]]::new()
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Body,[string]$Pattern){
    $message=$null;try{& $Body|Out-Null}catch{$message=$_.Exception.Message}
    Assert ([bool]$message -and $message -match $Pattern) "Expected $Pattern; received: $message"
}
function Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add([pscustomobject]@{name=$Name;passed=$true})}
    catch{$results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message});throw}
}
function Put([string]$Path,[string]$Text){
    Assert (Test-DsWithin $fixture $Path) 'Fixture write escaped its output directory.'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Commit-Fixture([string]$Root){
    [void](Invoke-DsGit $Root @('add','--all'))
    [void](Invoke-DsGit $Root @('-c','user.name=Module fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','-c',('core.hooksPath='+ (Join-Path $fixture 'no-hooks')),'commit','-m','Synthetic module fixture'))
}
function Init-Fixture([string]$Root){
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-DsGit $Root @('init','--initial-branch=main'))
    [void](Invoke-DsGit $Root @('config','core.autocrlf','false'))
}
function Seed-Core([string]$Root){
    Put (Join-Path $Root 'Cargo.toml') "[workspace.package]`nversion = `"0.1.0`"`n"
    Put (Join-Path $Root 'Cargo.lock') "version = 4`n"
    Put (Join-Path $Root 'rust-toolchain.toml') "[toolchain]`nchannel = `"1.99.1`"`n"
    Put (Join-Path $Root 'include/dansheng.h') "/* ABI v1 */ void dansheng_open(); void dansheng_request();`n"
    Put (Join-Path $Root 'crates/fixture/Cargo.toml') "[package]`nname = `"fixture`"`nversion = `"0.1.0`"`n"
    Put (Join-Path $Root 'crates/fixture/src/lib.rs') "pub fn fixture() -> u8 { 1 }`n"
    foreach($name in @('build.gradle.kts','settings.gradle.kts','gradle.properties','adapter/build.gradle.kts','adapter/src/main/fixture.kt')){Put (Join-Path $Root "platform/android/$name") "Synthetic adapter: $name`n"}
    foreach($name in Get-DsCoreResourcePaths){Put (Join-Path $Root $name) "Synthetic resource: $name`n"}
    foreach($name in @('release-common.ps1','runtime-common.ps1')){Put (Join-Path $Root "scripts/$name") ([IO.File]::ReadAllText((Join-Path $coreScripts $name)))}
    foreach($name in @('Dansheng.Workspace.psm1','Test-DanshengCoreDependency.ps1')){Put (Join-Path $Root "tools/workspace/$name") ([IO.File]::ReadAllText((Join-Path $toolsRoot $name)))}
}
function Seed-App([string]$Root){
    Put (Join-Path $Root 'pubspec.yaml') "name: synthetic_fixture`n"
    Put (Join-Path $Root 'pubspec.lock') "packages:`n  pigeon:`n    version: `"29.1.1`"`n"
}
$legacy=Join-Path $fixture 'legacy-core';Init-Fixture $legacy;Seed-Core $legacy;Commit-Fixture $legacy
$mono=Join-Path $fixture 'mono';Init-Fixture $mono
$core=Join-Path $mono 'core';$app=Join-Path $mono 'apps/dansheng_app'
Seed-Core $core;Seed-App $app;Commit-Fixture $mono
$linked=Join-Path $fixture 'registered checkout'
[void](Invoke-DsGit $mono @('worktree','add','-b','fixture/linked',$linked,'HEAD'))
$runtime=Join-Path $fixture 'runtime'
$savedRuntime=$env:DANSHENG_TASK_RUNTIME
$env:DANSHENG_TASK_RUNTIME=$null
try{
    Case 'exact modules report the registered shared checkout and Git identity' {
        $c=Get-DsNativeRepository $core core;$a=Get-DsNativeRepository $app app
        Assert-DsNativePair $c $a
        Assert ($c.module -eq 'core' -and $a.module -eq 'app' -and $c.checkout_root -eq (Get-DsPath $mono) -and $c.common_dir -eq $a.common_dir) 'Module identity changed.'
        Assert ((Get-DsRepository $mono).module -eq $null) 'Checkout root was mistaken for a module.'
    }
    Case 'arbitrary subdirectories and wrong module kinds remain rejected' {
        Reject {Get-DsRepository (Join-Path $core 'crates')} 'arbitrary subdirectory'
        Reject {Get-DsNativeRepository $app core} 'exact core module'
        Reject {Get-DsNativeRepository $mono core} 'exact core module'
        Put (Join-Path $mono 'other/core/Cargo.toml') 'fixture'
        Reject {Get-DsRepository (Join-Path $mono 'other/core')} 'arbitrary subdirectory'
    }
    Case 'module-like names do not authorize an incomplete checkout layout' {
        $incomplete=Join-Path $fixture 'incomplete';Init-Fixture $incomplete
        Put (Join-Path $incomplete 'core/Cargo.toml') 'fixture'
        Reject {Get-DsRepository (Join-Path $incomplete 'core')} 'complete core/'
    }
    Case 'copied Git pointers do not authorize an unregistered module checkout' {
        $copy=Join-Path $fixture 'unregistered-copy'
        Put (Join-Path $copy 'core/Cargo.toml') 'fixture'
        Seed-App (Join-Path $copy 'apps/dansheng_app')
        Put (Join-Path $copy '.git') ([IO.File]::ReadAllText((Join-Path $linked '.git')))
        Reject {Get-DsRepository (Join-Path $copy 'core')} 'Git-registered checkout'
    }
    Case 'nested Git repositories cannot masquerade as shared checkout modules' {
        $nested=Join-Path $fixture 'nested';Init-Fixture $nested
        Put (Join-Path $nested 'core/Cargo.toml') 'fixture'
        $nestedApp=Join-Path $nested 'apps/dansheng_app';Init-Fixture $nestedApp;Seed-App $nestedApp
        Reject {Get-DsRepository (Join-Path $nested 'core')} 'nested repositories'
    }
    Case 'same Git object store does not allow modules from different worktrees' {
        Reject {Assert-DsNativePair (Get-DsNativeRepository $core core) (Get-DsNativeRepository (Join-Path $linked 'apps/dansheng_app') app)} 'same registered Git checkout'
        Reject {Assert-DsNativePair (Get-DsNativeRepository $legacy core) (Get-DsNativeRepository $app app)} 'same registered Git checkout'
    }
    Case 'source v1 and adapter hashes survive relocation and linked checkout' {
        $old=Get-DanshengBuildSource $legacy;$new=Get-DanshengBuildSource $core;$copy=Get-DanshengBuildSource (Join-Path $linked 'core')
        Assert ($old.sha256 -ceq $new.sha256 -and $new.sha256 -ceq $copy.sha256 -and $new.files.Count -eq 6) 'Relocation changed the source digest or input set.'
        Assert ($new.source_hash_format -ceq 'dansheng-core-source-v1' -and $new.source_subdirectory -ceq 'core' -and $old.source_subdirectory -ceq '.') 'Versioned source identity missing.'
        Assert ((Get-DsAdapterSourceHash $legacy) -ceq (Get-DsAdapterSourceHash $core)) 'Adapter relocation changed the digest.'
    }
    Case 'source enumeration ignores injected Git environment and restores caller values' {
        $before=(Get-DanshengBuildSource $core).sha256
        $names=@('GIT_DIR','GIT_WORK_TREE','GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0');$saved=@{}
        foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        try{
            $env:GIT_DIR=Join-Path $legacy '.git';$env:GIT_WORK_TREE=$legacy;$env:GIT_CONFIG_COUNT='1';$env:GIT_CONFIG_KEY_0='core.worktree';$env:GIT_CONFIG_VALUE_0=$legacy
            Assert ((Get-DanshengBuildSource $core).sha256 -ceq $before) 'Source hashing was redirected to another repository.'
            Assert ($env:GIT_WORK_TREE -ceq $legacy -and $env:GIT_CONFIG_COUNT -ceq '1') 'Caller Git environment was changed.'
        }finally{foreach($name in $names){Set-DsProcessEnvironmentValue $name $saved[$name]}}
    }
    Case 'App and root files are excluded while Rust source bytes change the digest' {
        $before=(Get-DanshengBuildSource $core).sha256
        Put (Join-Path $app 'lib/example.dart') '// unrelated App input'
        Put (Join-Path $mono 'README.md') 'unrelated root input'
        Assert ((Get-DanshengBuildSource $core).sha256 -ceq $before) 'App edits contaminated Core hashing.'
        $file=Join-Path $core 'crates/fixture/src/lib.rs';$original=[IO.File]::ReadAllText($file)
        try{Put $file "pub fn fixture() -> u8 { 2 }`n";Assert ((Get-DanshengBuildSource $core).sha256 -cne $before) 'Rust source edit was not detected.'}
        finally{Put $file $original}
    }
    Case 'linked source ancestors are rejected before hashing' {
        $link=Join-Path $fixture 'linked-core'
        [void](New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $core)
        Reject {Get-DanshengBuildSource $link} 'Linked path'
    }
    Case 'runtime resolution uses the whole checkout boundary and original main' {
        $linkedCore=Join-Path $linked 'core'
        Assert ((Resolve-DanshengRuntimeRoot $linkedCore -RuntimeRoot $runtime) -eq (Get-DsPath $runtime)) 'Explicit runtime changed.'
        Reject {Resolve-DanshengRuntimeRoot $linkedCore} 'scripts/Enter-Dansheng.ps1'
        Reject {Resolve-DanshengRuntimeRoot $linkedCore -RuntimeRoot (Join-Path $linked 'apps/cache')} 'outside the source'
        Reject {Resolve-DanshengRuntimeRoot $linkedCore -RuntimeRoot (Join-Path $mono 'runtime')} 'primary repository'
        Reject {Resolve-DanshengRuntimeRoot $linkedCore -RuntimeRoot $fixture} 'cannot contain'
        Reject {Resolve-DanshengLabProfile $linkedCore -Profile (Join-Path $linked 'apps/profile')} 'outside the source'
        Reject {Resolve-DanshengRuntimeRoot $core} 'scripts/Enter-Dansheng.ps1'
    }
    Case 'environment preparation accepts Core modules but refuses sibling source caches' {
        $values=Get-DsRuntimeEnvironment -RuntimeRoot $runtime -CoreRoot (Join-Path $linked 'core') -CoreRepository $mono -CoreToolsRoot $toolsRoot -ToolchainRoot (Join-Path $fixture 'unused-tools')
        Assert ($values.values.DANSHENG_CORE_ROOT -eq (Get-DsPath (Join-Path $linked 'core'))) 'Environment lost module selection.'
        Reject {Get-DsRuntimeEnvironment -RuntimeRoot (Join-Path $linked 'apps/cache') -CoreRoot (Join-Path $linked 'core') -CoreRepository $mono -CoreToolsRoot $toolsRoot} 'outside source'
    }
    Case 'historical paired manager rejects monorepo roots and modules with entry guidance' {
        Reject {Get-DsLayout $core $app (Join-Path $fixture 'manager')} 'scripts/Enter-Dansheng.ps1'
        Reject {Get-DsLayout $mono $mono (Join-Path $fixture 'manager')} 'scripts/Enter-Dansheng.ps1'
        Reject {Read-DsTask $mono 'DS-901-fixture'} 'scripts/Enter-Dansheng.ps1'
        Reject {& (Join-Path $toolsRoot 'Invoke-DanshengPairChecks.ps1') -CoreWorktree $core -AppWorktree $app -RuntimeRoot $runtime -LockFile unused -ArtifactDirectory unused} 'scripts/Enter-Dansheng.ps1'
    }
    # Keep producer/consumer fixtures clean before constructing the exact dependency.
    Commit-Fixture $mono
    $artifact=Join-Path $runtime 'native-sdk';[void][IO.Directory]::CreateDirectory($artifact)
    $aar=Join-Path $artifact 'fixture.aar'
    $zip=[IO.Compression.ZipFile]::Open($aar,[IO.Compression.ZipArchiveMode]::Create)
    $nativeHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('synthetic native payload'))).ToLowerInvariant()
    try{foreach($abi in @('arm64-v8a','x86_64')){$stream=$zip.CreateEntry("jni/$abi/libdansheng_ffi.so").Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('synthetic native payload');$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}}finally{$zip.Dispose()}
    $receipt=[pscustomobject]@{version='0.1.0';source_hash_format='dansheng-core-source-v1';core_source_sha256=(Get-DanshengBuildSource $core).sha256;adapter_source_sha256=Get-DsAdapterSourceHash $core;aar_sha256=(Get-FileHash $aar).Hash;arm64_sha256=$nativeHash;x86_64_sha256=$nativeHash;packaged_arm64_sha256=$nativeHash;packaged_x86_64_sha256=$nativeHash;features=@('synthetic')}
    $receiptPath=Join-Path $artifact 'receipt.json';Write-DsJson $receiptPath $receipt
    $lockPath=Join-Path $artifact 'core.lock.json'
    $lock=$null
    Case 'native lock creation and full source plus packaged resource validation succeed' {
        $plan=& (Join-Path $toolsRoot 'New-DanshengCoreLock.ps1') -CoreRoot $core -AppRoot $app -ReceiptFile $receiptPath -AarPath $aar -Destination $lockPath | ConvertFrom-Json
        Assert (-not $plan.applied -and -not(Test-Path -LiteralPath $lockPath)) 'Dry-run wrote a lock.'
        $script:lock=$plan.lock
        Assert ($lock.core.source_hash_format -eq 'dansheng-core-source-v1' -and $lock.core.source_subdirectory -eq 'core') 'Lock omitted source identity metadata.'
        Write-DsJson $lockPath $lock
        $verified=& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core -AppRoot $app | ConvertFrom-Json
        Assert ($verified.verified -and $verified.resource_files -eq 7 -and $verified.packaged_receipt_complete) 'Native dependency verification did not complete.'
    }
    Case 'App-only descendant commit keeps locked Core provenance valid' {
        Put (Join-Path $mono 'README.md') 'App-only descendant fixture';Commit-Fixture $mono
        $verified=& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core -AppRoot $app | ConvertFrom-Json
        Assert $verified.verified 'App-only commit invalidated identical Core inputs.'
    }
    Case 'lock rejects unrelated provenance, unknown hashing and wrong module metadata' {
        $original=$lock.core.commit
        try{$lock.core.commit=('f'*40);Write-DsJson $lockPath $lock -ReplaceOwned;Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core} 'locked commit'}finally{$lock.core.commit=$original}
        try{$lock.core.source_hash_format='unknown-v99';Write-DsJson $lockPath $lock -ReplaceOwned;Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact} 'source_hash_format'}finally{$lock.core.source_hash_format='dansheng-core-source-v1'}
        try{$lock.core.source_subdirectory='.';Write-DsJson $lockPath $lock -ReplaceOwned;Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core} 'module differs'}finally{$lock.core.source_subdirectory='core';Write-DsJson $lockPath $lock -ReplaceOwned}
    }
    Case 'native validator still rejects changed Core, adapter, resources and cross-checkout App' {
        foreach($spec in @(@('crates/fixture/src/lib.rs','source snapshot'),@('platform/android/adapter/src/main/fixture.kt','adapter source'),@('plugins/builtin/fudan-venues/main.mjs','runtime resource'))){
            $file=Join-Path $core $spec[0];$original=[IO.File]::ReadAllText($file)
            try{Put $file ($original+'changed');Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core} $spec[1]}finally{Put $file $original}
        }
        Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core -AppRoot (Join-Path $linked 'apps/dansheng_app')} 'same registered Git checkout'
    }
    Case 'legacy unlabelled v1 locks remain supported with SDK-only verification' {
        $legacyLock=$lock|ConvertTo-Json -Depth 12|ConvertFrom-Json
        $legacyLock.core.PSObject.Properties.Remove('source_hash_format');$legacyLock.core.PSObject.Properties.Remove('source_subdirectory')
        foreach($resource in $legacyLock.resources){Put (Join-Path $artifact "resources/$($resource.path)") ([IO.File]::ReadAllText((Join-Path $core $resource.path)))}
        $legacyLockPath=Join-Path $artifact 'legacy.lock.json';Write-DsJson $legacyLockPath $legacyLock
        $verified=& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $legacyLockPath -ArtifactDirectory $artifact | ConvertFrom-Json
        Assert ($verified.verified -and $verified.source_hash_format -eq 'dansheng-core-source-v1' -and $verified.source_subdirectory -eq '.') 'Legacy SDK-only lock broke.'
    }
    Case 'unversioned producer requires explicit opt-in and cannot claim a release' {
        $unborn=Join-Path $fixture 'unborn-mono';Init-Fixture $unborn
        $unbornCore=Join-Path $unborn 'core';$unbornApp=Join-Path $unborn 'apps/dansheng_app'
        Seed-Core $unbornCore;Seed-App $unbornApp
        $unbornArguments=@{CoreRoot=$unbornCore;AppRoot=$unbornApp;ReceiptFile=$receiptPath;AarPath=$aar;Destination=(Join-Path $artifact 'unborn.lock.json')}
        Reject {& (Join-Path $toolsRoot 'New-DanshengCoreLock.ps1') @unbornArguments} 'NeedsInitialCommit'
        $plan=& (Join-Path $toolsRoot 'New-DanshengCoreLock.ps1') @unbornArguments -AllowUnversioned | ConvertFrom-Json
        Assert ($null -eq $plan.lock.core.commit -and $plan.lock.state -eq 'development_snapshot') 'Unborn producer invented a source commit.'
        Reject {& (Join-Path $toolsRoot 'New-DanshengCoreLock.ps1') @unbornArguments -AllowUnversioned -ForRelease -AcquisitionUri 'https://example.invalid/fixture.aar'} 'exact Core/App commits'
        $invalid=$plan.lock;$invalid.state='release';$path=Join-Path $artifact 'invalid-release.lock.json';Write-DsJson $path $invalid
        Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $path -ArtifactDirectory $artifact} 'committed Core revision'
    }
    Case 'committed Core changes cannot retain an older lock even when binary source hashes match' {
        Put (Join-Path $core 'scripts/new-fixture.ps1') '# Synthetic tooling change outside the v1 binary input set'
        Commit-Fixture $mono
        Assert ((Get-DanshengBuildSource $core).sha256 -eq $lock.core.source_sha256) 'Fixture accidentally changed binary inputs.'
        Reject {& (Join-Path $toolsRoot 'Test-DanshengCoreDependency.ps1') -LockFile $lockPath -ArtifactDirectory $artifact -CoreRoot $core -AppRoot $app} 'Committed Core tree differs'
    }
}finally{
    $env:DANSHENG_TASK_RUNTIME=$savedRuntime
    $report=[pscustomobject]@{passed=(@($results|Where-Object {-not $_.passed}).Count -eq 0);cases=$results.Count;results=@($results);fixture=$fixture;native_build=$false;fixture_retained=$true}
    Write-DsJson (Join-Path $fixture 'result.json') $report
    $report|ConvertTo-Json -Depth 6
}
