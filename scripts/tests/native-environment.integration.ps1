#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CoreRoot,
    [Parameter(Mandatory)][string]$CoreToolsRoot,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [string]$Output
)
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$app=Split-Path -Parent $scripts
. (Join-Path $scripts 'core-dependency.ps1')
$RuntimeRoot=Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot $RuntimeRoot
if(-not$Output){$Output=Join-Path $RuntimeRoot 'logs/native-environment-integration.json'}
$Output=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $Output
$lock=Join-Path $app 'core.lock.json'
$null=Test-DanshengAppCoreDependency -AppRoot $app -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot -ArtifactDirectory $ArtifactDirectory -LockFile $lock
$aar=Get-DanshengAppAarPath -AppRoot $app -ArtifactDirectory $ArtifactDirectory -LockFile $lock
$aarBefore=(Get-FileHash -LiteralPath $aar).Hash
$lockBefore=(Get-FileHash -LiteralPath $lock).Hash
$names=@('CARGO_HOME','CARGO_TARGET_DIR','DANSHENG_CORE_ROOT','DANSHENG_TASK_RUNTIME','PATH','RUSTUP_HOME','RUSTUP_TOOLCHAIN','SOURCE_DATE_EPOCH','CC_SHELL_ESCAPED_FLAGS','LIBCLANG_PATH','GRADLE_USER_HOME','CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER','CC_x86_64_pc_windows_gnu','AR_x86_64_pc_windows_gnu')
foreach($architecture in @('aarch64','x86_64')){
    $key=$architecture+'_linux_android'
    $names+=@("CC_$key","AR_$key","CFLAGS_$key","BINDGEN_EXTRA_CLANG_ARGS_$key",('CARGO_TARGET_'+$key.ToUpperInvariant()+'_LINKER'))
}
function Save-NativeEnvironment {
    $snapshot=@{}
    foreach($name in $names){$snapshot[$name]=[pscustomobject]@{present=(Test-Path -LiteralPath ('Env:'+$name));value=[Environment]::GetEnvironmentVariable($name,'Process')}}
    $snapshot
}
function Assert-NativeEnvironment($Expected) {
    foreach($name in $names){
        if((Test-Path -LiteralPath ('Env:'+$name))-ne$Expected[$name].present-or[Environment]::GetEnvironmentVariable($name,'Process')-cne$Expected[$name].value){throw "Native build did not restore environment variable $name"}
    }
}
$original=Save-NativeEnvironment
$results=[Collections.Generic.List[object]]::new()
try {
    foreach($case in @('no-inherited-task','different-inherited-task')){
        if($case-eq'no-inherited-task'){$env:DANSHENG_CORE_ROOT=$null;$env:DANSHENG_TASK_RUNTIME=$null}
        else{$env:DANSHENG_CORE_ROOT=Join-Path $RuntimeRoot 'unrelated-source';$env:DANSHENG_TASK_RUNTIME=Join-Path $RuntimeRoot 'unrelated-task'}
        $expected=Save-NativeEnvironment
        & (Join-Path $scripts 'prepare-native.ps1') -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot -ArtifactDirectory $ArtifactDirectory -RuntimeRoot $RuntimeRoot -LockFile $lock 2>&1 |
            Tee-Object -FilePath (Join-Path $RuntimeRoot "logs/native-environment-$case-final.log")
        if($LASTEXITCODE-ne0){throw 'Native parameter precedence build failed'}
        Assert-NativeEnvironment $expected
        if((Get-FileHash -LiteralPath $aar).Hash-cne$aarBefore-or(Get-FileHash -LiteralPath $lock).Hash-cne$lockBefore){throw 'Warmed SDK/lock bytes changed unexpectedly'}
        $results.Add([pscustomobject]@{case=$case;passed=$true;environment_names_restored=$names.Count;aar_and_lock_bytes_identical=$true})
    }
    $failureRuntime=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path (Join-Path $RuntimeRoot ('native-env-rejection-'+[guid]::NewGuid().ToString('N')))
    [void][IO.Directory]::CreateDirectory((Join-Path $failureRuntime 'cargo-home/registry'))
    $conflictingCopy=Join-Path $failureRuntime 'core-android-project/include/dansheng.h'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $conflictingCopy))
    [IO.File]::WriteAllText($conflictingCopy,'synthetic-conflicting-copy')
    $expected=Save-NativeEnvironment
    $rejected=$false
    try{& (Join-Path $scripts 'prepare-native.ps1') -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot -ArtifactDirectory (Join-Path $failureRuntime 'native-sdk') -RuntimeRoot $failureRuntime -LockFile $lock | Out-Null}
    catch{$rejected=$_.Exception.Message-match'Native build workspace differs'}
    if(-not$rejected-or[IO.File]::ReadAllText($conflictingCopy)-cne'synthetic-conflicting-copy'){throw 'Conflicting native copy was not rejected and preserved'}
    Assert-NativeEnvironment $expected
    $results.Add([pscustomobject]@{case='conflicting-copy-failure';passed=$true;environment_names_restored=$names.Count;conflicting_copy_preserved=$true;runtime=$failureRuntime})
    [pscustomobject]@{passed=$results.Count;checks=@($results);aar_sha256=$aarBefore;lock_sha256=$lockBefore;private_profiles_used=$false} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Output -Encoding utf8
    Get-Content -LiteralPath $Output -Raw
    $global:LASTEXITCODE=0
} finally {
    foreach($name in $names){
        if($original[$name].present){[Environment]::SetEnvironmentVariable($name,$original[$name].value,'Process')}
        else{Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
    }
}
