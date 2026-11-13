#Requires -Version 7.0
param([Parameter(Mandatory)][string]$Apk,[string]$RuntimeRoot,[string]$SdkRoot=$env:ANDROID_HOME,
      [ValidateSet('system-images;android-28;default;x86_64','system-images;android-36;default;x86_64')][string]$SystemImage='system-images;android-36;default;x86_64',
      [int]$ConsolePort=5588,[int]$AdbServerPort=15037,[switch]$Apply,[switch]$KeepAlive)
$ErrorActionPreference='Stop'
$app=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
$runtime=Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot $RuntimeRoot
$smoke=Join-Path $runtime ('ui-smoke-'+[guid]::NewGuid().ToString('N'))
if(-not[IO.Path]::GetFullPath($smoke).StartsWith('D:\',[StringComparison]::OrdinalIgnoreCase)){throw 'Disposable UI smoke requires a D-owned runtime directory.'}
if($ConsolePort%2-ne0){throw 'Emulator console port must be even.'}
$adb=Join-Path $SdkRoot 'platform-tools/adb.exe'
$emulator=Join-Path $SdkRoot 'emulator/emulator.exe'
$manager=Join-Path $SdkRoot 'cmdline-tools/latest/bin/avdmanager.bat'
$image=$SystemImage
$imagePath=Join-Path $SdkRoot ($image.Replace(';','/')+'/system.img')
foreach($path in @($adb,$emulator,$manager,$imagePath,$Apk)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required offline smoke input missing: $path"}}
$plan=[ordered]@{apk=[IO.Path]::GetFullPath($Apk);apk_sha256=(Get-FileHash -LiteralPath $Apk).Hash;runtime=$smoke;image=$image;console_port=$ConsolePort;adb_server_port=$AdbServerPort;network='disabled before app launch';physical_devices='not accepted';apply=[bool]$Apply}
if(-not$Apply){$plan|ConvertTo-Json;return}
if(@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue|Where-Object {$_.LocalPort-in@($ConsolePort,($ConsolePort+1),$AdbServerPort)}).Count){throw 'Disposable emulator or dedicated ADB ports are occupied.'}
$envNames=@('ANDROID_HOME','ANDROID_SDK_ROOT','ANDROID_USER_HOME','ANDROID_AVD_HOME','ANDROID_EMULATOR_HOME','TEMP','TMP','ANDROID_ADB_SERVER_PORT','ADB_SERVER_PORT','ADB_SERVER_SOCKET','ADB_VENDOR_KEYS')
$saved=@{};$present=@{}
foreach($name in $envNames){$present[$name]=Test-Path -LiteralPath ('Env:'+$name);$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$process=$null;$serverStarted=$false;$succeeded=$false
try{
    $env:ANDROID_HOME=$SdkRoot;$env:ANDROID_SDK_ROOT=$SdkRoot
    $env:ANDROID_USER_HOME=Join-Path $smoke 'android-user';$env:ANDROID_AVD_HOME=Join-Path $smoke 'avd';$env:ANDROID_EMULATOR_HOME=Join-Path $smoke 'emulator-home'
    $env:TEMP=Join-Path $smoke 'tmp';$env:TMP=$env:TEMP
    $env:ANDROID_ADB_SERVER_PORT=[string]$AdbServerPort;$env:ADB_SERVER_PORT=[string]$AdbServerPort;$env:ADB_SERVER_SOCKET="tcp:localhost:$AdbServerPort"
    Remove-Item -LiteralPath Env:ADB_VENDOR_KEYS -ErrorAction SilentlyContinue
    foreach($directory in @($smoke,$env:ANDROID_USER_HOME,$env:ANDROID_AVD_HOME,$env:ANDROID_EMULATOR_HOME,$env:TEMP)){[void][IO.Directory]::CreateDirectory($directory)}
    $avd='dansheng-offline-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    'no'|& $manager create avd -n $avd -k $image -p (Join-Path $env:ANDROID_AVD_HOME ($avd+'.avd')) *> (Join-Path $smoke 'create-avd.log')
    if($LASTEXITCODE-ne0){throw 'Disposable AVD creation failed.'}
    & $adb -P $AdbServerPort start-server *> (Join-Path $smoke 'adb-start.log')
    if($LASTEXITCODE-ne0){throw 'Dedicated ADB server startup failed.'}
    $serverStarted=$true
    $process=Start-Process -FilePath $emulator -ArgumentList @('-avd',$avd,'-port',[string]$ConsolePort,'-no-window','-no-audio','-no-boot-anim','-no-snapshot','-gpu','swiftshader') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $smoke 'emulator.stdout.log') -RedirectStandardError (Join-Path $smoke 'emulator.stderr.log')
    $serial="emulator-$ConsolePort"
    $owner=[ordered]@{root=$smoke;avd_name=$avd;expected_serial=$serial;avd_home=$env:ANDROID_AVD_HOME;launcher_pid=$process.Id;adb_server_port=$AdbServerPort;created_at_utc=[DateTime]::UtcNow.ToString('o')}
    $ownership=Join-Path $smoke 'ownership.json';$owner|ConvertTo-Json|Set-Content -LiteralPath $ownership -Encoding utf8
    $deadline=[DateTime]::UtcNow.AddMinutes(3)
    do{$boot=(@(& $adb -P $AdbServerPort -s $serial shell getprop sys.boot_completed 2>$null)-join'').Trim();if($boot-eq'1'){break};Start-Sleep -Seconds 2}while([DateTime]::UtcNow-lt$deadline)
    if($boot-ne'1'){throw 'Disposable emulator boot timed out.'}
    $null=Assert-DanshengOwnedEmulator -Serial $serial -OwnershipFile $ownership -Adb $adb
    & $adb -P $AdbServerPort -s $serial shell cmd connectivity airplane-mode enable
    & $adb -P $AdbServerPort -s $serial shell svc wifi disable
    & $adb -P $AdbServerPort -s $serial shell settings put global mobile_data 0
    & $adb -P $AdbServerPort -s $serial shell svc data disable
    $network=@(& $adb -P $AdbServerPort -s $serial shell dumpsys connectivity);$network|Set-Content -LiteralPath (Join-Path $smoke 'network-before.txt') -Encoding utf8
    if(@($network|Select-String 'Active default network:.*none').Count-eq0){throw 'App will not be launched while a default network is active.'}
    & $adb -P $AdbServerPort -s $serial install $Apk *> (Join-Path $smoke 'install.log')
    if($LASTEXITCODE-ne0){throw 'Installation on owned disposable AVD failed.'}
    & $adb -P $AdbServerPort -s $serial shell am start -W -n org.dansheng.app/.MainActivity *> (Join-Path $smoke 'launch.log')
    if($LASTEXITCODE-ne0){throw 'App startup failed.'}
    function Save-Ui([string]$Name){
        & $adb -P $AdbServerPort -s $serial shell uiautomator dump /sdcard/dansheng-ui.xml *> (Join-Path $smoke ($Name+'-dump.log'))
        & $adb -P $AdbServerPort -s $serial pull /sdcard/dansheng-ui.xml (Join-Path $smoke ($Name+'.xml')) *> (Join-Path $smoke ($Name+'-pull.log'))
        & $adb -P $AdbServerPort -s $serial exec-out screencap -p > (Join-Path $smoke ($Name+'.png'))
        [xml](Get-Content -LiteralPath (Join-Path $smoke ($Name+'.xml')) -Raw)
    }
    $homeXml=Save-Ui 'home'
    $settings=$homeXml.SelectSingleNode('//node[@content-desc="设置" and @clickable="true"]')
    if(-not$settings-or$settings.bounds-notmatch'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$'){throw 'eHall Settings control was not found in the actual UI.'}
    $x=[int](([int]$Matches[1]+[int]$Matches[3])/2);$y=[int](([int]$Matches[2]+[int]$Matches[4])/2)
    & $adb -P $AdbServerPort -s $serial shell input tap $x $y
    $top=Save-Ui 'settings-top'
    $screen=(@(& $adb -P $AdbServerPort -s $serial shell wm size)-join'')
    if($screen-notmatch'(\d+)x(\d+)'){throw 'Cannot determine emulator screen dimensions.'}
    $width=[int]$Matches[1];$height=[int]$Matches[2]
    $card=$null
    for($i=0;$i-lt3;$i++){
        & $adb -P $AdbServerPort -s $serial shell input swipe ([int]($width/2)) ([int]($height*0.90)) ([int]($width/2)) ([int]($height*0.25)) 600
        $xml=Save-Ui ('core-info-'+$i)
        $card=@($xml.SelectNodes('//node')|ForEach-Object {$_.GetAttribute('content-desc')}|Where-Object {$_-match'name\s+dansheng-core'})|Select-Object -First 1
        if($card-match'api_version\s+1'-and$card-match'version\s+0\.1\.0'){break}
    }
    if(-not$card-or$card-notmatch'api_version\s+1'-or$card-notmatch'version\s+0\.1\.0'){throw 'Dynamic core.info values were not rendered in the Flutter Settings page.'}
    $appPid=(@(& $adb -P $AdbServerPort -s $serial shell pidof org.dansheng.app)-join'').Trim()
    & $adb -P $AdbServerPort -s $serial logcat -d --pid=$appPid *> (Join-Path $smoke 'app-logcat.txt')
    $log=[IO.File]::ReadAllText((Join-Path $smoke 'app-logcat.txt'))
    foreach($bad in @('UnsatisfiedLinkError','NativeLibraryUnavailable','NativeCoreOpenTimeout','FATAL EXCEPTION')){if($log.Contains($bad)){throw 'Native/UI runtime error found in the owned application logs.'}}
    $network=@(& $adb -P $AdbServerPort -s $serial shell dumpsys connectivity);$network|Set-Content -LiteralPath (Join-Path $smoke 'network-after.txt') -Encoding utf8
    if(@($network|Select-String 'Active default network:.*none').Count-eq0){throw 'Network became active during offline UI smoke.'}
    $proof=[ordered]@{plan=$plan;ownership=$ownership;core_info_ui=$card;ui_chain='Dart -> Pigeon -> Kotlin -> JNI -> Rust';school_services_used=$false;personal_profiles_used=$false;physical_devices_used=$false;passed=$true}
    $proof|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $smoke 'proof.json') -Encoding utf8
    $succeeded=$true
    [pscustomobject]@{passed=$true;proof=Join-Path $smoke 'proof.json';ownership=$ownership;serial=$serial;kept_alive=[bool]$KeepAlive}|ConvertTo-Json
}finally{
    if($process-and(-not$KeepAlive-or-not$succeeded)){
        $current=Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
        if($current-and$current.CommandLine-match[regex]::Escape($avd)){
            & $adb -P $AdbServerPort -s $serial emu kill *> (Join-Path $smoke 'emulator-close.log')
        }
    }
    if($serverStarted-and(-not$KeepAlive-or-not$succeeded)){& $adb -P $AdbServerPort kill-server *> (Join-Path $smoke 'adb-close.log')}
    foreach($name in $envNames){if($present[$name]){Set-Item -LiteralPath ('Env:'+$name) -Value $saved[$name]}else{Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}}
}
