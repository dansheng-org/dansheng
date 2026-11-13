param([string]$CoreRoot,[string]$CoreToolsRoot,[string]$Python,[switch]$UsePreparedNative,[string]$ArtifactDirectory,[string]$RuntimeRoot,[string]$OutputDirectory,[string]$LockFile,[string]$SigningDirectory,[switch]$UpdateLock,[switch]$IncludeBeta,[switch]$ForRelease)
$ErrorActionPreference='Stop'
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
$CoreRoot=Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot $CoreRoot
$RuntimeRoot=Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot $RuntimeRoot
$ArtifactDirectory=Resolve-DanshengCoreArtifactDirectory -AppRoot $app -ArtifactDirectory $ArtifactDirectory -RuntimeRoot $RuntimeRoot
$OutputDirectory=Resolve-DanshengAppArtifactRoot -AppRoot $app -OutputDirectory $OutputDirectory -RuntimeRoot $RuntimeRoot
$OutputDirectory=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $OutputDirectory
Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $OutputDirectory
$logs=Join-Path $RuntimeRoot 'logs'
[void][IO.Directory]::CreateDirectory($logs)
$CoreToolsRoot=Resolve-DanshengCoreToolsRoot -AppRoot $app -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot
$savedCore=$env:DANSHENG_CORE_ROOT; $savedSdk=$env:DANSHENG_CORE_SDK_DIR
$savedLock=$env:DANSHENG_CORE_LOCK_FILE
$savedArtifacts=$env:DANSHENG_ARTIFACT_DIR
Push-Location $app
try{
    $env:DANSHENG_CORE_ROOT=$CoreRoot
    $env:DANSHENG_CORE_SDK_DIR=$ArtifactDirectory
    $env:DANSHENG_CORE_LOCK_FILE=Resolve-DanshengAppCoreLock -AppRoot $app -LockFile $LockFile
    $env:DANSHENG_ARTIFACT_DIR=$OutputDirectory
    if(!$UsePreparedNative){& ./scripts/prepare-native.ps1 -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot -ArtifactDirectory $ArtifactDirectory -RuntimeRoot $RuntimeRoot -LockFile $LockFile -UpdateLock:$UpdateLock;if($LASTEXITCODE -ne 0){throw 'Native build failed'}}
    $null=Test-DanshengAppCoreDependency -AppRoot $app -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot -ArtifactDirectory $ArtifactDirectory -LockFile $LockFile -ForRelease:$ForRelease
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    node (Join-Path $CoreRoot 'plugins/fudan-sports/pack.mjs') (Join-Path $OutputDirectory 'official.fudan-sports-0.2.0.dspack')
    if($LASTEXITCODE -ne 0){throw 'External package build failed'}
    flutter build apk --debug --target-platform android-x64 --split-per-abi --no-pub
    if($LASTEXITCODE -ne 0){throw 'Emulator build failed'}
    Copy-Item -LiteralPath build/app/outputs/flutter-apk/app-x86_64-debug.apk -Destination (Join-Path $OutputDirectory 'dansheng-android-x86_64-debug.apk')
    Push-Location android
    try { ./gradlew.bat :app:assembleDebugAndroidTest :app:testDebugUnitTest -Ptarget-platform=android-x64 --max-workers=3 --console=plain
        if($LASTEXITCODE -ne 0){throw 'Product test build failed'}
    }finally{Pop-Location}
    Copy-Item -LiteralPath build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk -Destination (Join-Path $OutputDirectory 'dansheng-android-x86_64-androidTest.apk')
    if($IncludeBeta){& ./scripts/build-beta.ps1 -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot -ArtifactDirectory $ArtifactDirectory -RuntimeRoot $RuntimeRoot -OutputDirectory $OutputDirectory -LockFile $LockFile -SigningDirectory $SigningDirectory -ForRelease:$ForRelease
        if($LASTEXITCODE -ne 0){throw 'Internal beta build failed'}}
    $signed=@(@{file='dansheng-android-x86_64-debug';abi='x86_64';out='audit-debug';extra=@()})
    if($IncludeBeta){$signed+=@{file='dansheng-android-arm64-beta';abi='arm64-v8a';out='audit-release';extra=@('--release')}}
    foreach($item in $signed){
        $apk=Join-Path $OutputDirectory ($item.file+'.apk');$extra=$item.extra
        $lockArgs=if($LockFile){@('--lock-file',$LockFile)}else{@()}
        if($Python){& $Python scripts/audit-apk.py $apk --abi $item.abi @extra --core-root $CoreRoot --artifact-directory $ArtifactDirectory @lockArgs --output (Join-Path $logs ($item.out+'.json'))
            if($LASTEXITCODE -ne 0){throw 'Final APK payload differs from expected source/AAR'}}
        else{& ./scripts/audit-apk.ps1 -Apk $apk -Abi $item.abi -Release:($item.extra.Count-gt0) -CoreRoot $CoreRoot -ArtifactDirectory $ArtifactDirectory -LockFile $LockFile -Output (Join-Path $logs ($item.out+'.json'))}
        & (Join-Path $env:ANDROID_HOME 'build-tools/37.0.0/zipalign.exe') -c -P 16 4 $apk
        if($LASTEXITCODE -ne 0){throw 'APK is not correctly aligned'}
        & (Join-Path $env:ANDROID_HOME 'build-tools/37.0.0/apksigner.bat') verify --verbose --print-certs $apk > (Join-Path $logs ($item.file+'-signature.txt'))
        if($LASTEXITCODE -ne 0){throw 'APK signature invalid'}
    }
}finally{Pop-Location;$env:DANSHENG_CORE_ROOT=$savedCore;$env:DANSHENG_CORE_SDK_DIR=$savedSdk;$env:DANSHENG_CORE_LOCK_FILE=$savedLock;$env:DANSHENG_ARTIFACT_DIR=$savedArtifacts}
