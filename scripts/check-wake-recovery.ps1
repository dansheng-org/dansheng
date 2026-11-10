param([Parameter(Mandatory)][ValidateSet('Permission','Reboot')][string]$Case,
      [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]+$')][string]$Serial,
      [string]$Adb=(Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'))
$ErrorActionPreference='Stop'
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
$evidence=New-Item -ItemType Directory -Force -Path (Join-Path $app ".local/wake-$Case")
$avd=(& $Adb -s $Serial emu avd name | Select-Object -First 1).Trim()
if($avd -notin @('dansheng-app-api28','dansheng-core-api36')) {throw "Expected a dedicated dansheng emulator"}
$clockKey='qa-'+[guid]::NewGuid().ToString('N')
$runner='org.dansheng.app.test/org.dansheng.app.checks.ProductRunner'
function Phase([string]$Name,[string[]]$Extras) {
    $lines=& $Adb -s $Serial shell am instrument -w -e phase $Name @Extras $runner
    $lines|Set-Content (Join-Path $evidence "$Name.log")
    if($LASTEXITCODE -ne 0 -or !($lines -match 'INSTRUMENTATION_RESULT: result=passed')){throw "$Name failed: $($lines -join ' ')"}
    $lines
}
function BootReady {
    $limit=[DateTimeOffset]::UtcNow.AddMinutes(4)
    do {
        $online=& $Adb devices | Where-Object {$_ -match "^$Serial\s+device$"}
        if($online -and ((& $Adb -s $Serial shell getprop sys.boot_completed) -join '').Trim() -eq '1'){return}
        Start-Sleep -Seconds 2
    } while([DateTimeOffset]::UtcNow -lt $limit)
    throw 'Emulator did not complete boot'
}
if($Case -eq 'Reboot' -and $avd -ne 'dansheng-app-api28'){throw 'Only reboot the dedicated product API 28 AVD.'}
Phase seedClock @() | Out-Null
if($Case -eq 'Permission'){
    $old=(& $Adb -s $Serial shell cmd appops get org.dansheng.app SCHEDULE_EXACT_ALARM) -join ' '
    $mode=if($old -match 'SCHEDULE_EXACT_ALARM:\s*(allow|deny|ignore|default)'){$Matches[1]}else{'default'}
    try {
        & $Adb -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM deny
        $scheduled=Phase armDenied @('-e','delay','180','-e','clock_key',$clockKey)
        $job=(($scheduled|Select-String 'RESULT: job_id=').Line -split 'job_id=')[1]
        & $Adb -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM allow
        & $Adb -s $Serial shell am start -n org.dansheng.app/.MainActivity
        $until=[DateTimeOffset]::UtcNow.AddSeconds(55); $seen=$false
        do {
            $alarm=(& $Adb -s $Serial shell dumpsys alarm | Select-String 'org.dansheng.app/org.dansheng.android.WakeReceiver')
            $record=((& $Adb -s $Serial shell run-as org.dansheng.app cat shared_prefs/dansheng-wake-v1.xml 2>$null) -join '')
            if($alarm -and $record.Contains($job)){$seen=$true; break}; Start-Sleep -Seconds 1
        } while([DateTimeOffset]::UtcNow -lt $until)
        if(!$seen){throw 'System alarm not observed after regrant'}
        Phase checkWake @('-e','job_id',$job)
        Phase disableClock @('-e','job_id',$job)
    } finally { & $Adb -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM $mode }
}else{
    $scheduled=Phase arm @('-e','delay','150','-e','clock_key',$clockKey)
    $job=(($scheduled|Select-String 'RESULT: job_id=').Line -split 'job_id=')[1]
    $when=[DateTimeOffset]::Parse((($scheduled|Select-String 'RESULT: run_at=').Line -split 'run_at=')[1])
    & $Adb -s $Serial reboot
    Start-Sleep -Seconds 4
    BootReady
    & $Adb -s $Serial shell input keyevent KEYCODE_WAKEUP
    & $Adb -s $Serial shell wm dismiss-keyguard
    # Read only system evidence until after delivery; don't open the app to help the restore.
    & $Adb -s $Serial shell dumpsys alarm | Select-String 'org.dansheng.app' | Out-File (Join-Path $evidence 'postboot-alarm.log')
    while([DateTimeOffset]::UtcNow -lt $when.AddSeconds(7)){ Start-Sleep -Seconds 2 }
    & $Adb -s $Serial logcat -d -s ActivityManager:I |Select-String 'org.dansheng.app' |Out-File (Join-Path $evidence 'postboot-process.log')
    Phase count @('-e','clock_key',$clockKey)
}
