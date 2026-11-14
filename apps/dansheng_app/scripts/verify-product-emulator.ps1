param([Parameter(Mandatory)][string]$Serial,[Parameter(Mandatory)][string]$OwnershipFile,[string]$AppApk,[string]$TestApk,[string]$PluginPackage,[string]$RuntimeRoot,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
$owner=Assert-DanshengOwnedEmulator -Serial $Serial -OwnershipFile $OwnershipFile -Adb $adb
$savedAdbSocket=$env:ADB_SERVER_SOCKET
$env:ADB_SERVER_SOCKET="tcp:localhost:$($owner.adb_server_port)"
$name=$owner.avd_name
$artifacts=Resolve-DanshengAppArtifactRoot -AppRoot $app -OutputDirectory $OutputDirectory -RuntimeRoot $RuntimeRoot
$runtime=Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot $RuntimeRoot
$out=New-Item -ItemType Directory -Force -Path (Join-Path $runtime "logs/acceptance-$Serial")
function RunPhase([string]$phase,[string[]]$Extras) {
    $lines=& $adb -s $Serial shell am instrument -w -e phase $phase @Extras org.dansheng.app.test/org.dansheng.app.checks.ProductRunner
    $lines | Set-Content (Join-Path $out "$phase.log")
    if(!($lines -match 'INSTRUMENTATION_RESULT: result=passed')){throw "$phase failed: $($lines[-6..-1] -join ' ')"}
    $lines
}
function ValueOf([string[]]$Lines,[string]$Key) {
    (($Lines | Select-String "INSTRUMENTATION_RESULT: $Key=" | Select-Object -Last 1).Line -split '=',2)[1]
}
Push-Location $app
try {
    $apk=if($AppApk){[IO.Path]::GetFullPath($AppApk)}else{Join-Path $artifacts 'dansheng-android-x86_64-debug.apk'}
    $testApk=if($TestApk){[IO.Path]::GetFullPath($TestApk)}else{Join-Path $artifacts 'dansheng-android-x86_64-androidTest.apk'}
    $plugin=if($PluginPackage){[IO.Path]::GetFullPath($PluginPackage)}else{Join-Path $artifacts 'official.fudan-sports-0.2.0.dspack'}
    $pluginHash=(Get-FileHash $plugin).Hash
    $zip=[IO.Compression.ZipFile]::OpenRead((Resolve-Path $testApk))
    try {
        $entry=$zip.GetEntry('assets/'+[IO.Path]::GetFileName($plugin))
        if(!$entry){throw 'Test APK is missing the external plugin package.'}
        $stream=$entry.Open()
        try{$embedded=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
        if($embedded -ne $pluginHash){throw 'Rebuild androidTest APK: embedded external package does not match distribution.'}
    }finally{$zip.Dispose()}
    $appHash=(Get-FileHash $apk).Hash;$testHash=(Get-FileHash $testApk).Hash
    foreach($f in @($apk,$testApk)){ & $adb -s $Serial install -r $f; if($LASTEXITCODE -ne 0){throw "Install failed: $f"} }
    $api=((& $adb -s $Serial shell getprop ro.build.version.sdk) -join '').Trim()
    $old=(& $adb -s $Serial shell cmd appops get org.dansheng.app SCHEDULE_EXACT_ALARM) -join ' '
    $mode=if($old -match 'SCHEDULE_EXACT_ALARM:\s*(allow|deny|ignore|default)'){$Matches[1]}else{'default'}
    if([int]$api -ge 31){ & $adb -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM allow }
    try {
        & $adb -s $Serial shell input keyevent KEYCODE_WAKEUP
        & $adb -s $Serial shell wm dismiss-keyguard
        RunPhase external @() | Out-Null
        Write-Output 'Verified disabled install, QuickJS action, disable and removal'
        $normal=RunPhase sports @()
        Write-Output "Verified normal synthetic reservation; POSTs=$(ValueOf $normal 'launch_posts')"
        $loss=RunPhase sportsLoss @()
        RunPhase verifyFence @('-e','job_id',(ValueOf $loss 'uncertain_job')) | Out-Null
        Write-Output 'Verified uncertain write across a process restart'
        $cold=RunPhase sportsCold @()
        $release=[int64](ValueOf $cold 'release_ms')
        while([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $release+4000){Start-Sleep -Seconds 2}
        RunPhase coldResult @('-e','job_id',(ValueOf $cold 'job_id'),'-e','claims_before',(ValueOf $cold 'claims_before')) | Out-Null
        Write-Output 'Verified expired page session, waiting for login and zero new writes'
        if($appHash -ne (Get-FileHash $apk).Hash -or $testHash -ne (Get-FileHash $testApk).Hash -or $pluginHash -ne (Get-FileHash $plugin).Hash){throw 'Build inputs changed during device verification'}
        @{apk_sha256=$appHash;test_apk_sha256=$testHash;plugin_sha256=$pluginHash;
          api=$api;abi=((& $adb -s $Serial shell getprop ro.product.cpu.abi)-join '').Trim();tested_utc=[DateTime]::UtcNow.ToString('o');campus_writes=0} |
          ConvertTo-Json | Set-Content (Join-Path $out 'receipt.json')
    }finally{if([int]$api -ge 31){ & $adb -s $Serial shell cmd appops set org.dansheng.app SCHEDULE_EXACT_ALARM $mode }}
}finally{Pop-Location;$env:ADB_SERVER_SOCKET=$savedAdbSocket}
