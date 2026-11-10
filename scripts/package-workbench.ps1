param([string]$CoreRoot=(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dansheng'),[string]$Python='python',[switch]$UsePreparedNative)
$ErrorActionPreference='Stop'
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
$CoreRoot=(Resolve-Path $CoreRoot).Path
Push-Location $app
try{
    if(!$UsePreparedNative){& ./scripts/prepare-native.ps1 -CoreRoot $CoreRoot;if($LASTEXITCODE -ne 0){throw 'Native build failed'}}
    New-Item -ItemType Directory -Force dist|Out-Null
    node (Join-Path $CoreRoot 'plugins/fudan-sports/pack.mjs') (Join-Path $app 'dist/official.fudan-sports-0.2.0.dspack')
    if($LASTEXITCODE -ne 0){throw 'External package build failed'}
    flutter build apk --debug --target-platform android-x64 --split-per-abi --no-pub
    if($LASTEXITCODE -ne 0){throw 'Emulator build failed'}
    Copy-Item -LiteralPath build/app/outputs/flutter-apk/app-x86_64-debug.apk -Destination dist/dansheng-android-x86_64-debug.apk
    Push-Location android
    try { ./gradlew.bat :app:assembleDebugAndroidTest :app:testDebugUnitTest -Ptarget-platform=android-x64 --max-workers=3 --console=plain
        if($LASTEXITCODE -ne 0){throw 'Product test build failed'}
    }finally{Pop-Location}
    & ./scripts/build-beta.ps1 -CoreRoot $CoreRoot
    if($LASTEXITCODE -ne 0){throw 'Internal beta build failed'}
    $signed=@(@{file='dansheng-android-arm64-beta';abi='arm64-v8a';out='audit-release';extra=@('--release')},@{file='dansheng-android-x86_64-debug';abi='x86_64';out='audit-debug';extra=@()})
    foreach($item in $signed){
        $apk="dist/$($item.file).apk";$extra=$item.extra
        & $Python scripts/audit-apk.py $apk --abi $item.abi @extra --output ".local/$($item.out).json"
        if($LASTEXITCODE -ne 0){throw 'Final APK payload differs from expected source/AAR'}
        & (Join-Path $env:ANDROID_HOME 'build-tools/37.0.0/zipalign.exe') -c -P 16 4 $apk
        if($LASTEXITCODE -ne 0){throw 'APK is not correctly aligned'}
        & (Join-Path $env:ANDROID_HOME 'build-tools/37.0.0/apksigner.bat') verify --verbose --print-certs $apk > ".local/$($item.file)-signature.txt"
        if($LASTEXITCODE -ne 0){throw 'APK signature invalid'}
    }
}finally{Pop-Location}
