param([string]$CoreRoot,[string]$CoreToolsRoot,[string]$ArtifactDirectory,[string]$RuntimeRoot,[string]$LockFile,[switch]$UpdateLock)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'build-parallelism.ps1')
$nativeParallelism = Get-DanshengBuildParallelism
Write-Host "Native build concurrency: Cargo $($nativeParallelism.cargo), Gradle $($nativeParallelism.gradle)."
$app = (Resolve-Path -LiteralPath (Split-Path $PSScriptRoot)).Path
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
$CoreRoot=Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot $CoreRoot
$RuntimeRoot=Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot $RuntimeRoot
$ArtifactDirectory=Resolve-DanshengCoreArtifactDirectory -AppRoot $app -ArtifactDirectory $ArtifactDirectory -RuntimeRoot $RuntimeRoot
$ArtifactDirectory=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $ArtifactDirectory
Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $ArtifactDirectory
Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $RuntimeRoot
$nativeCargoHome=Join-Path $RuntimeRoot 'cargo-home'
if(-not(Test-Path -LiteralPath (Join-Path $nativeCargoHome 'registry') -PathType Container)){
    throw 'Offline Cargo cache is not initialized. Run Core tools/workspace/Initialize-DanshengTask.ps1 -Apply before prepare-native.'
}
[void][IO.Directory]::CreateDirectory($ArtifactDirectory)
[void][IO.Directory]::CreateDirectory($RuntimeRoot)
$nativeEnvNames=@('CARGO_HOME','CARGO_TARGET_DIR','DANSHENG_CORE_ROOT','DANSHENG_TASK_RUNTIME','PATH','RUSTUP_HOME','RUSTUP_TOOLCHAIN','SOURCE_DATE_EPOCH','CC_SHELL_ESCAPED_FLAGS','LIBCLANG_PATH','GRADLE_USER_HOME','CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER','CC_x86_64_pc_windows_gnu','AR_x86_64_pc_windows_gnu')
foreach($architecture in @('aarch64','x86_64')){
    $key=$architecture+'_linux_android'
    $nativeEnvNames+=@("CC_$key","AR_$key","CFLAGS_$key","BINDGEN_EXTRA_CLANG_ARGS_$key",('CARGO_TARGET_'+$key.ToUpperInvariant()+'_LINKER'))
}
$nativeSavedEnv=@{};$nativePresentEnv=@{}
foreach($name in $nativeEnvNames){$nativePresentEnv[$name]=Test-Path -LiteralPath ('Env:'+$name);$nativeSavedEnv[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
$env:CARGO_HOME=$nativeCargoHome
# Copied Gradle inputs still load build helpers from the selected producer.
# Explicit source/runtime parameters take precedence over any inherited task.
$env:DANSHENG_CORE_ROOT=$CoreRoot
$env:DANSHENG_TASK_RUNTIME=$RuntimeRoot
. (Join-Path $CoreRoot 'scripts/release-common.ps1')
. (Join-Path $PSScriptRoot 'adapter-source.ps1')
$adapterHash=Get-AdapterSourceHash $CoreRoot
$fingerprint = (Get-DanshengBuildSource -Root $CoreRoot).sha256
$jni = Join-Path $ArtifactDirectory 'jni'
$short = 'x86_64'
$staging = New-Item -ItemType Directory -Force -Path (Join-Path $jni $short)
$armDir = New-Item -ItemType Directory -Force -Path (Join-Path $jni 'arm64-v8a')
# CI checks may keep the cross-compiled Rust outputs across runs
# (DANSHENG_CI_NATIVE_TARGET_ROOT, set only for the SDK check); release builds
# and local tasks compile under their own runtime.
$nativeTargetRoot=if($env:DANSHENG_CI_NATIVE_TARGET_ROOT){$env:DANSHENG_CI_NATIVE_TARGET_ROOT}else{$RuntimeRoot}
$coreGradleOutput=Join-Path $RuntimeRoot 'core-android-build'
$coreCmakeOutput=Join-Path $RuntimeRoot 'core-cmake'
$coreBuildWorkspace=Join-Path $RuntimeRoot 'core-android-project'
$coreBuildProject=Join-Path $coreBuildWorkspace 'platform/android'
# AGP writes tool metadata as well as build output. Give it its own copy of
# the public Android build inputs, while receipts continue to name CoreRoot.
$nativeInputPaths=@(& git --no-optional-locks -c core.quotepath=false -C $CoreRoot ls-files --cached --others --exclude-standard -- 'platform/android' 'include/dansheng.h')
if($LASTEXITCODE-ne0){throw 'Cannot enumerate native SDK build inputs.'}
foreach($nativeInput in $nativeInputPaths){
    if($nativeInput-match '(^|/)(build|\.cxx|\.gradle)/'){continue}
    $nativeFrom=Get-DanshengAppCheckedPath (Join-Path $CoreRoot $nativeInput)
    $nativeTo=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path (Join-Path $coreBuildWorkspace $nativeInput)
    $nativeBytes=[IO.File]::ReadAllBytes($nativeFrom)
    $nativeHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($nativeBytes))
    if(Test-Path -LiteralPath $nativeTo -PathType Leaf){
        if((Get-FileHash -LiteralPath $nativeTo).Hash-cne$nativeHash){throw 'Native build workspace differs from current source; select a new runtime instead of overwriting it.'}
    }else{
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $nativeTo))
        [IO.File]::WriteAllBytes($nativeTo,$nativeBytes)
    }
}
$coreGradleInit=Join-Path $ArtifactDirectory 'core-output.init.gradle'
$gradleOutputLiteral=ConvertTo-Json -InputObject $coreGradleOutput.Replace('\','/') -Compress
$cmakeOutputLiteral=ConvertTo-Json -InputObject $coreCmakeOutput.Replace('\','/') -Compress
$initScript="allprojects { p ->`n  def component = p.path == ':' ? 'root' : p.path.replace(':', '/').replaceFirst('^/', '')`n  p.layout.buildDirectory.set(new File($gradleOutputLiteral, component))`n  p.plugins.withId('com.android.library') { p.extensions.getByName('android').externalNativeBuild.cmake.buildStagingDirectory = new File($cmakeOutputLiteral, component) }`n}`n"
[IO.File]::WriteAllText($coreGradleInit,$initScript,[Text.UTF8Encoding]::new($false))
$savedGradleHome=$env:GRADLE_USER_HOME
$env:GRADLE_USER_HOME=Join-Path $RuntimeRoot 'gradle-cache'
Push-Location $CoreRoot
try {
    # Build product-specific feature sets in separate caches, retaining the historical Core receipts.
    . ./scripts/android-env.ps1 -Architecture aarch64
    $env:CARGO_HOME=$nativeCargoHome
    $env:CARGO_TARGET_DIR = Join-Path $nativeTargetRoot 'cargo-arm64'
    $env:SOURCE_DATE_EPOCH = '0'
    $env:CFLAGS_aarch64_linux_android = Get-DanshengNativePrefixFlags -TargetDirectory $env:CARGO_TARGET_DIR
    $env:CC_SHELL_ESCAPED_FLAGS = '1'
    cargo build -p dansheng-ffi --target aarch64-linux-android --release --features campus-webvpn --locked --offline -j $nativeParallelism.cargo
    if($LASTEXITCODE -ne 0){throw 'Rust ARM64 build failed'}
    $armSo = Join-Path $armDir.FullName 'libdansheng_ffi.so'
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'aarch64-linux-android/release/libdansheng_ffi.so') -Destination $armSo
    . ./scripts/android-env.ps1 -Architecture x86_64
    $env:CARGO_HOME=$nativeCargoHome
    $env:CARGO_TARGET_DIR = Join-Path $nativeTargetRoot 'cargo-x86'
    cargo build -p dansheng-ffi --target x86_64-linux-android --features campus-webvpn --locked --offline -j $nativeParallelism.cargo
    if($LASTEXITCODE -ne 0){throw 'Rust x86_64 build failed'}
    $debug = Join-Path $env:CARGO_TARGET_DIR 'x86_64-linux-android/debug/libdansheng_ffi.so'
    $target = Join-Path $staging.FullName 'libdansheng_ffi.so'
    & $DanshengAndroidStrip --strip-debug -o $target $debug
    if($LASTEXITCODE -ne 0){throw 'Cannot stage emulator library'}
    # The Core launcher supplies its checked task project-cache directory.
    # Older launchers keep their .gradle metadata in this runtime-owned copy.
    $gradleArguments=@('--init-script',$coreGradleInit,'-PandroidAbis=arm64-v8a,x86_64',"-PrustJniDir=$($jni.Replace('\','/'))",':adapter:assembleRelease','--offline',"--max-workers=$($nativeParallelism.gradle)",'--parallel','--console=plain')
    & (Join-Path $coreBuildProject 'gradlew.ps1') -GradleArguments $gradleArguments
    if($LASTEXITCODE -ne 0){throw 'Adapter build failed'}
    if((Get-DanshengBuildSource -Root $CoreRoot).sha256 -ne $fingerprint){throw 'Core inputs changed during build'}
    if((Get-AdapterSourceHash $CoreRoot) -ne $adapterHash){throw 'Adapter inputs changed during build'}
} finally { Pop-Location;$env:GRADLE_USER_HOME=$savedGradleHome }
$aar = Join-Path $ArtifactDirectory 'dansheng-android-0.1.0.aar'
Copy-Item -LiteralPath (Join-Path $coreGradleOutput 'adapter/outputs/aar/adapter-release.aar') -Destination $aar
$metadata = [ordered]@{version='0.1.0';core_source_sha256=$fingerprint;features=@('services','card-login','campus-webvpn');aar_sha256=(Get-FileHash $aar).Hash;arm64_sha256=(Get-FileHash $armSo).Hash;x86_64_sha256=(Get-FileHash $target).Hash}
$metadata.adapter_source_sha256=$adapterHash
$packaged=Get-DanshengPackagedNativeHashes -AarPath $aar
foreach($field in $packaged.Keys){$metadata[$field]=$packaged[$field]}
$coreHead=@(& git --no-optional-locks -C $CoreRoot rev-parse --verify HEAD 2>$null)
$metadata.core_commit=if($LASTEXITCODE-eq0){$coreHead-join''}else{$null}
$metadata.producer_state=if($metadata.core_commit){'commit_with_source_snapshot'}else{'development_snapshot'}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'receipt.json') -Encoding utf8
& (Join-Path $PSScriptRoot 'native-notices.ps1') -CoreRoot $CoreRoot -Destination (Join-Path $ArtifactDirectory 'legal')
$null=New-DanshengAppCoreLock -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $ArtifactDirectory -CoreToolsRoot $CoreToolsRoot -RuntimeRoot $RuntimeRoot -LockFile $LockFile -UpdateLock:$UpdateLock
# A locked SDK-only consumer also needs the exact public module/licence inputs.
# The authoritative dependency validator has already checked this resource list.
$nativeLock=Get-Content -LiteralPath (Resolve-DanshengAppCoreLock -AppRoot $app -LockFile $LockFile) -Raw | ConvertFrom-Json
foreach($resource in $nativeLock.resources){
    $resourceSource=Get-DanshengAppCheckedPath (Join-Path $CoreRoot $resource.path)
    $resourceTarget=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path (Join-Path (Join-Path $ArtifactDirectory 'resources') $resource.path)
    $resourceBytes=[IO.File]::ReadAllBytes($resourceSource)
    $resourceHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($resourceBytes)).ToLowerInvariant()
    if($resourceHash-cne$resource.sha256){throw 'SDK resource changed after dependency validation.'}
    if(Test-Path -LiteralPath $resourceTarget){
        if((Get-FileHash -LiteralPath $resourceTarget).Hash.ToLowerInvariant()-cne$resourceHash){throw 'Existing SDK resource differs; select a new artifact directory instead of overwriting it.'}
    }else{
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $resourceTarget))
        [IO.File]::WriteAllBytes($resourceTarget,$resourceBytes)
    }
}
$global:LASTEXITCODE=0
Write-Output $aar
} finally {
    foreach($name in $nativeEnvNames){
        if($nativePresentEnv[$name]){[Environment]::SetEnvironmentVariable($name,$nativeSavedEnv[$name],'Process')}
        else{Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
    }
}
