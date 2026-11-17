#Requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'core-dependency.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-app-workflow-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $fixture 'app'
foreach($name in @('app','dansheng','explicit-core','env-core')){
    $dir=Join-Path $fixture $name
    [void][IO.Directory]::CreateDirectory((Join-Path $dir 'include'))
    [IO.File]::WriteAllText((Join-Path $dir 'Cargo.toml'),'[workspace]')
    [IO.File]::WriteAllText((Join-Path $dir 'include/dansheng.h'),'/* synthetic ABI */')
}
$checks=[Collections.Generic.List[string]]::new()
& git --no-optional-locks -C $app init --initial-branch=main|Out-Null
if($LASTEXITCODE-ne0){throw 'Cannot initialize the synthetic App path fixture'}
$savedCore=$env:DANSHENG_CORE_ROOT;$savedSdk=$env:DANSHENG_CORE_SDK_DIR;$savedLock=$env:DANSHENG_CORE_LOCK_FILE;$savedRuntime=$env:DANSHENG_TASK_RUNTIME
function Assert-Equal($actual,$expected,[string]$label){if($actual-cne$expected){throw "$label failed"};$checks.Add($label)}
function Assert-Rejected([scriptblock]$action,[string]$label){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};if(-not$failed){throw "$label did not reject"};$checks.Add($label)}
try{
    $env:DANSHENG_CORE_ROOT=$null;$env:DANSHENG_CORE_SDK_DIR=$null;$env:DANSHENG_CORE_LOCK_FILE=$null;$env:DANSHENG_TASK_RUNTIME=$null
    Assert-Equal (Resolve-DanshengCoreRoot -AppRoot $app) (Join-Path $fixture 'dansheng') 'legacy Core sibling default'
    foreach($name in @('dansheng-core','core')){
        $dir=Join-Path $fixture $name
        [void][IO.Directory]::CreateDirectory((Join-Path $dir 'include'))
        [IO.File]::WriteAllText((Join-Path $dir 'Cargo.toml'),'[workspace]')
        [IO.File]::WriteAllText((Join-Path $dir 'include/dansheng.h'),'/* synthetic ABI */')
        $expected=if($name-eq'core'){Join-Path $fixture 'core'}else{Join-Path $fixture 'dansheng-core'}
        Assert-Equal (Resolve-DanshengCoreRoot -AppRoot $app) $expected ($name+' default takes precedence')
    }
    Assert-Equal (Resolve-DanshengCoreRoot -AppRoot (Join-Path $fixture 'dansheng-app')) (Join-Path $fixture 'dansheng-core') 'ordinary App selects named Core rather than unrelated core sibling'
    $env:DANSHENG_CORE_ROOT=Join-Path $fixture 'env-core'
    Assert-Equal (Resolve-DanshengCoreRoot -AppRoot $app) $env:DANSHENG_CORE_ROOT 'Core environment override'
    Assert-Equal (Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot '../explicit-core') (Join-Path $fixture 'explicit-core') 'explicit relative Core wins over env'
    Assert-Rejected {Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot 'missing-core'} 'missing Core rejects'
    Assert-Rejected {Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot (Join-Path $fixture 'dansheng') -ArtifactDirectory (Join-Path $fixture 'dansheng')} 'artifact output rejects exact Core root'
    Assert-Rejected {Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot (Join-Path $fixture 'dansheng') -ArtifactDirectory (Join-Path $fixture 'dansheng/generated')} 'artifact output rejects Core descendant'
    $syntheticRepo=Join-Path $fixture 'app-git-repo'
    [void][IO.Directory]::CreateDirectory($syntheticRepo)
    & git --no-optional-locks -C $syntheticRepo init --initial-branch=main | Out-Null
    if($LASTEXITCODE-ne0){throw 'Cannot create synthetic Git fixture'}
    & git --no-optional-locks -C $syntheticRepo -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c "core.hooksPath=$fixture/no-hooks" commit --allow-empty -m 'Synthetic workflow test baseline' | Out-Null
    if($LASTEXITCODE-ne0){throw 'Cannot seed synthetic Git fixture'}
    $syntheticTask=Join-Path $fixture 'app-linked-task'
    & git --no-optional-locks -C $syntheticRepo worktree add -b chore/DS-900-fixture $syntheticTask main 2>&1 | Out-Null
    if($LASTEXITCODE-ne0){throw 'Cannot register synthetic App worktree'}
    Assert-Rejected {Assert-DanshengTaskArtifactWrite -AppRoot $syntheticTask -CoreRoot (Join-Path $fixture 'dansheng') -ArtifactDirectory (Join-Path $syntheticRepo '.local/native')} 'task worktree cannot overwrite original App artifacts'
    $defaultRuntime=Resolve-DanshengAppRuntimeRoot -AppRoot $app
    $runtimeBase=if($IsWindows){[IO.Path]::GetFullPath('D:/DevCache/dansheng/runtime')}else{Join-Path ([IO.Path]::GetTempPath()) 'dansheng-runtime'}
    if((Split-Path -Parent $defaultRuntime)-cne$runtimeBase-or
       (Split-Path -Leaf $defaultRuntime)-notmatch'^[0-9a-f]{12}$'){throw 'Default runtime must match the external checkout entrypoint layout.'}
    Assert-Equal (Resolve-DanshengCoreArtifactDirectory -AppRoot $app) (Join-Path $defaultRuntime 'native-sdk') 'SDK is outside the source worktree'
    $env:DANSHENG_CORE_SDK_DIR='sdk-input'
    Assert-Equal (Resolve-DanshengCoreArtifactDirectory -AppRoot $app) (Join-Path $app 'sdk-input') 'relative SDK environment'
    Assert-Equal (Resolve-DanshengCoreArtifactDirectory -AppRoot $app -ArtifactDirectory 'another-sdk') (Join-Path $app 'another-sdk') 'SDK parameter precedence'
    Assert-Equal (Resolve-DanshengAppCoreLock -AppRoot $app) (Join-Path $app 'core.lock.json') 'App lock default'
    $env:DANSHENG_CORE_LOCK_FILE='locks/core.lock.json'
    Assert-Equal (Resolve-DanshengAppCoreLock -AppRoot $app) (Join-Path $app 'locks/core.lock.json') 'relative lock environment'
    Assert-Equal (Resolve-DanshengAppCoreLock -AppRoot $app -LockFile '../reviewed.lock.json') (Join-Path $fixture 'reviewed.lock.json') 'lock parameter precedence'
    $env:DANSHENG_CORE_LOCK_FILE=$null
    Assert-Equal (Resolve-DanshengAppRuntimeRoot -AppRoot $app) $defaultRuntime 'native runtime is outside source'
    $env:DANSHENG_TASK_RUNTIME='runtime-cache'
    Assert-Equal (Resolve-DanshengAppRuntimeRoot -AppRoot $app) (Join-Path $app 'runtime-cache') 'relative runtime environment'
    Assert-Equal (Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot '../external-runtime') (Join-Path $fixture 'external-runtime') 'runtime parameter precedence'
    $outputRuntime=Join-Path $fixture 'runtime-outputs'
    Assert-Equal (Get-DanshengAppRuntimeOutput -RuntimeRoot $outputRuntime -Path (Join-Path $outputRuntime 'signing/android-beta')) (Join-Path $outputRuntime 'signing/android-beta') 'signing output validates without Core runtime helpers'
    Assert-Rejected {Get-DanshengAppRuntimeOutput -RuntimeRoot $outputRuntime -Path $outputRuntime} 'signing directory rejects runtime root'
    Assert-Rejected {Get-DanshengAppRuntimeOutput -RuntimeRoot $outputRuntime -Path (Join-Path $fixture 'outside-signing')} 'signing directory rejects external output'
    [void][IO.Directory]::CreateDirectory($outputRuntime)
    $link=Join-Path $outputRuntime 'linked-signing'
    $outside=Join-Path $fixture 'outside-signing'
    [void][IO.Directory]::CreateDirectory($outside)
    $linkKind=if($IsWindows){'Junction'}else{'SymbolicLink'}
    [void](New-Item -ItemType $linkKind -Path $link -Target $outside)
    Assert-Rejected {Get-DanshengAppRuntimeOutput -RuntimeRoot $outputRuntime -Path (Join-Path $link 'new-key')} 'signing directory rejects a linked descendant before writing'
    Assert-Equal @(Get-ChildItem -LiteralPath $outside -Force).Count 0 'linked target remains untouched'
    $legacy=Test-DanshengAppCoreDependency -AppRoot $app -CoreRoot (Join-Path $fixture 'dansheng') -ArtifactDirectory (Join-Path $app 'sdk')
    Assert-Equal $legacy.state 'legacy_native_receipt' 'legacy mode explicitly unverified'
    Assert-Rejected {Test-DanshengAppCoreDependency -AppRoot $app -CoreRoot (Join-Path $fixture 'dansheng') -ArtifactDirectory (Join-Path $app 'sdk') -ForRelease} 'stable mode needs lock'
    $lock=Join-Path $app 'core.lock.json'
    [IO.File]::WriteAllText($lock,'{"format":"dansheng-core-lock-v1","mode":"native-sdk","artifact":{"name":"../unsafe.aar"}}')
    Assert-Rejected {Get-DanshengAppAarPath -AppRoot $app -ArtifactDirectory (Join-Path $app 'sdk')} 'locked name traversal rejects'
    [IO.File]::WriteAllText($lock,'{"format":"dansheng-core-lock-v1","mode":"native-sdk","artifact":{"name":"actual-core.aar"}}')
    Assert-Equal (Get-DanshengAppAarPath -AppRoot $app -ArtifactDirectory (Join-Path $app 'sdk')) (Join-Path $app 'sdk/actual-core.aar') 'locked artifact name'
    $aar=Join-Path $fixture 'synthetic.aar'
    $stream=[IO.File]::Open($aar,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {foreach($abi in @('arm64-v8a','x86_64')){$entry=$zip.CreateEntry("jni/$abi/libdansheng_ffi.so");$body=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('synthetic-'+$abi);$body.Write($bytes)}finally{$body.Dispose()}}}finally{$zip.Dispose();$stream.Dispose()}
    $hashes=Get-DanshengPackagedNativeHashes -AarPath $aar
    foreach($item in @(@{abi='arm64-v8a';field='packaged_arm64_sha256'},@{abi='x86_64';field='packaged_x86_64_sha256'})){
        $expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('synthetic-'+$item.abi))).ToLowerInvariant()
        Assert-Equal $hashes[$item.field] $expected ('packaged '+$item.abi+' hashes actual entry')
    }
    [pscustomobject]@{passed=$checks.Count;checks=@($checks.ToArray());fixture=$fixture;native_builds=0;credentials_read=$false}|ConvertTo-Json -Depth 5
}finally{$env:DANSHENG_CORE_ROOT=$savedCore;$env:DANSHENG_CORE_SDK_DIR=$savedSdk;$env:DANSHENG_CORE_LOCK_FILE=$savedLock;$env:DANSHENG_TASK_RUNTIME=$savedRuntime}
