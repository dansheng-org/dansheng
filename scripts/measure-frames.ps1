param([Parameter(Mandatory)][string]$Device)
$ErrorActionPreference='Stop'
$adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$abi=((& $adb -s $Device shell getprop ro.product.cpu.abi) -join '').Trim()
$emulated=((& $adb -s $Device shell getprop ro.kernel.qemu) -join '').Trim()
if($abi -ne 'arm64-v8a' -or $emulated -eq '1' -or $Device -like 'emulator-*'){throw 'Use an explicitly selected physical ARM64 test phone set to 60 Hz.'}
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
Push-Location $app
try{
    $out=New-Item -ItemType Directory -Force -Path .local/performance
    @{model=((& $adb -s $Device shell getprop ro.product.model)-join '').Trim();api=((& $adb -s $Device shell getprop ro.build.version.sdk)-join '').Trim();abi=$abi;build='profile';dataset='80 synthetic classrooms'} |
        ConvertTo-Json | Set-Content (Join-Path $out.FullName 'device.json')
    $bench=Join-Path $app '.local/frames-app'
    if(!(Test-Path $bench)){flutter create --empty --no-pub --platforms=android --org org.dansheng.bench --project-name dansheng_frames $bench; if($LASTEXITCODE -ne 0){throw 'Benchmark scaffold failed'}}
    $pubspec=[IO.File]::ReadAllText((Join-Path $app 'bench/pubspec.yaml')).Replace('path: ..',"path: '$($app.Replace('\','/'))'")
    [IO.File]::WriteAllText((Join-Path $bench 'pubspec.yaml'),$pubspec)
    foreach($dir in @('integration_test','test_driver')){
        $dest=New-Item -ItemType Directory -Force -Path (Join-Path $bench $dir)
        Get-ChildItem -LiteralPath (Join-Path $app "bench/$dir") -File |Copy-Item -Destination $dest.FullName
    }
    $env:DANSHENG_FRAMES_OUT=Join-Path $out.FullName 'frames.json'
    Set-Location $bench
    flutter pub get
    if($LASTEXITCODE -ne 0){throw 'Benchmark dependencies failed'}
    flutter drive --profile -d $Device --driver test_driver/frames.dart --target integration_test/frame_budget_test.dart
    if($LASTEXITCODE -ne 0){throw 'Frame benchmark did not pass'}
}finally{Remove-Item Env:DANSHENG_FRAMES_OUT -ErrorAction SilentlyContinue; Pop-Location}
