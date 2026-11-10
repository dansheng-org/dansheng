param([string]$Serial='emulator-5592')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Split-Path $PSScriptRoot)).Path
$a=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$avd=((& $a -s $Serial emu avd name)|Select-Object -First 1).Trim()
if($avd -notin @('dansheng-app-api28','dansheng-app-api36','dansheng-core-api36')){throw 'Dedicated dansheng QA AVD required'}
$out=New-Item -ItemType Directory -Force (Join-Path $root ".local/workbench-acceptance/$Serial")
Push-Location $root
try{
    $app='dist/dansheng-android-x86_64-debug.apk';$test='build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk';$package='dist/official.fudan-sports-0.2.0.dspack'
    $appHash=(Get-FileHash $app).Hash;$testHash=(Get-FileHash $test).Hash;$pluginHash=(Get-FileHash $package).Hash
    $zip=[IO.Compression.ZipFile]::OpenRead((Resolve-Path $test))
    try{$entry=$zip.GetEntry('assets/'+[IO.Path]::GetFileName($package));if(!$entry){throw 'Test lacks external plugin'}
        $stream=$entry.Open();try{$embedded=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
        if($embedded -ne $pluginHash){throw 'Rebuild the test package for this external plugin.'}
    }finally{$zip.Dispose()}
    foreach($f in @($app,$test)){& $a -s $Serial install -r $f;if($LASTEXITCODE -ne 0){throw 'Install failed'}}
    & $a -s $Serial shell input keyevent KEYCODE_WAKEUP; & $a -s $Serial shell wm dismiss-keyguard
    $api=((& $a -s $Serial shell getprop ro.build.version.sdk)-join '').Trim()
    $old=(& $a -s $Serial shell cmd appops get org.dansheng.app SCHEDULE_EXACT_ALARM) -join ' '
    $mode=if($old -match 'SCHEDULE_EXACT_ALARM:\s*(allow|deny|ignore|default)'){$Matches[1]}else{'default'}
    if([int]$api -ge 31){ & $a -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM allow }
    # The manual journey removes its synthetic scheduling package on exit, leaving
    # the subsequent UI verification in the ordinary campus-only configuration.
    try{foreach($phase in @('agentProbe','campusData','sports','coldVenueSeed','coldVenueRestore','workbench')){
        $lines=& $a -s $Serial shell am instrument -w -e phase $phase org.dansheng.app.test/org.dansheng.app.checks.ProductRunner
        $lines | Set-Content (Join-Path $out "$phase.log")
        if(!( $lines -match 'INSTRUMENTATION_RESULT: result=passed')){throw "$phase failed: $($lines[-7..-1] -join ' ')"}
        Write-Output "$phase passed"
    }}finally{if([int]$api -ge 31){ & $a -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM $mode }}
    if($appHash -ne (Get-FileHash $app).Hash -or $testHash -ne (Get-FileHash $test).Hash -or $pluginHash -ne (Get-FileHash $package).Hash){throw 'Artifact changed during validation'}
    @{app_sha256=$appHash;test_apk_sha256=$testHash;plugin_sha256=$pluginHash;api=$api;abi=((& $a -s $Serial shell getprop ro.product.cpu.abi)-join '').Trim();avd=$avd;utc=[DateTime]::UtcNow.ToString('o');campus_writes=0} |
        ConvertTo-Json |Set-Content (Join-Path $out 'receipt.json')
}finally{Pop-Location}
