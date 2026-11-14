param(
    [string]$Profile,
    [ValidateRange(0,65535)][int]$Port,
    [switch]$NoBrowser,
    [switch]$SkipBuild,
    [string]$RuntimeRoot,
    [string]$TargetDirectory,
    [string]$LogDirectory,
    [switch]$Offline
)
$ErrorActionPreference='Stop'
$LabRoot=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/runtime-common.ps1"
$LabRuntime=if($RuntimeRoot -or $env:DANSHENG_TASK_RUNTIME){Resolve-DanshengRuntimeRoot -Root $LabRoot -RuntimeRoot $RuntimeRoot}else{$null}
$Profile=Resolve-DanshengLabProfile -Root $LabRoot -Profile $Profile -RuntimeRoot $LabRuntime
if(-not $PSBoundParameters.ContainsKey('Port')){$Port=if($LabRuntime){0}else{19764}}
if(-not $TargetDirectory){$TargetDirectory=if($env:CARGO_TARGET_DIR){$env:CARGO_TARGET_DIR}elseif($LabRuntime){Join-Path $LabRuntime 'cargo-target'}else{Join-Path $LabRoot 'target'}}
$TargetDirectory=Get-DanshengCheckedPath $TargetDirectory
if($LabRuntime){$TargetDirectory=Get-DanshengRuntimeOutput -RuntimeRoot $LabRuntime -Path $TargetDirectory}
$LabBinary=Get-DanshengCheckedPath (Join-Path $TargetDirectory 'debug/dansheng-lab.exe')
if(-not $LogDirectory){$LogDirectory=if($env:DANSHENG_LAB_LOG_DIR){$env:DANSHENG_LAB_LOG_DIR}elseif($LabRuntime){Join-Path $LabRuntime 'logs/lab'}else{Join-Path $Profile 'logs'}}
$LabLogRoot=Get-DanshengCheckedPath $LogDirectory
if($LabRuntime){$LabLogRoot=Get-DanshengRuntimeOutput -RuntimeRoot $LabRuntime -Path $LabLogRoot}
$LabControlPath=Join-Path $Profile 'lab-control.json'
$LabHandler=[System.Net.Http.HttpClientHandler]::new()
$LabHandler.UseProxy=$false
$LabHandler.AllowAutoRedirect=$false
$LabClient=[System.Net.Http.HttpClient]::new($LabHandler)
$LabClient.Timeout=[TimeSpan]::FromSeconds(3)
function Get-LabOpenLink {
    if(-not(Test-Path -LiteralPath $LabControlPath)){return $null}
    $LabControl=Get-Content -Raw -LiteralPath $LabControlPath | ConvertFrom-Json
    $LabBase=[uri]$LabControl.base_url
    if($LabBase.Scheme -ne 'http' -or $LabBase.Host -ne '127.0.0.1'){throw 'Invalid local lab endpoint'}
    $LabRequest=[System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post,"$($LabControl.base_url)/api/open")
    $LabRequest.Headers.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$LabControl.control_token)
    $LabRequest.Content=[System.Net.Http.StringContent]::new('{}',[Text.Encoding]::UTF8,'application/json')
    try {
        $LabResponse=$LabClient.SendAsync($LabRequest).GetAwaiter().GetResult()
        try{
            if(-not $LabResponse.IsSuccessStatusCode){return $null}
            $LabLink=($LabResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).url
            $LabLinkUri=[uri]$LabLink
            if($LabLinkUri.GetLeftPart([UriPartial]::Authority) -ne $LabControl.base_url){throw 'Invalid browser link origin'}
            return [pscustomobject]@{BrowserUrl=$LabLink;BaseUrl=$LabControl.base_url;Pid=$LabControl.pid}
        }finally{$LabResponse.Dispose()}
    }catch [System.Net.Http.HttpRequestException]{return $null}
    catch [System.Threading.Tasks.TaskCanceledException]{return $null}
    finally{$LabRequest.Dispose()}
}
try {
    $LabOpen=Get-LabOpenLink
    if(-not $LabOpen){
        if(-not $SkipBuild){
            . "$PSScriptRoot/dev.ps1"
            $LabSavedTarget=$env:CARGO_TARGET_DIR
            $env:CARGO_TARGET_DIR=$TargetDirectory
            Push-Location -LiteralPath $LabRoot
            try {
                $LabBuildArgs=@('build','-p','dansheng-lab','--locked')
                if($Offline){$LabBuildArgs+='--offline'}
                & cargo @LabBuildArgs
                if($LASTEXITCODE -ne 0){throw 'Lab build failed'}
            }
            finally { Pop-Location; $env:CARGO_TARGET_DIR=$LabSavedTarget }
        }
        if(-not(Test-Path -LiteralPath $LabBinary)){throw 'Build dansheng-lab before using -SkipBuild'}
        New-Item -ItemType Directory -Force -Path $LabLogRoot | Out-Null
        $LabLogId=[guid]::NewGuid().ToString('N')
        $SavedProxies=@{}
        # Match the user's regular network configuration, preserving existing TUN.
        foreach($ProxyName in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','WS_PROXY','WSS_PROXY')){
            $SavedProxies[$ProxyName]=[Environment]::GetEnvironmentVariable($ProxyName,'Process')
            $ProxyValue=[Environment]::GetEnvironmentVariable($ProxyName,'User')
            if([string]::IsNullOrEmpty($ProxyValue)){$ProxyValue=[Environment]::GetEnvironmentVariable($ProxyName,'Machine')}
            [Environment]::SetEnvironmentVariable($ProxyName,$ProxyValue,'Process')
        }
        try {
            $LabProcess=Start-Process -FilePath $LabBinary -ArgumentList @('--profile',('"'+$Profile+'"'),'--port',"$Port") -WorkingDirectory $LabRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LabLogRoot "$LabLogId.stdout.log") -RedirectStandardError (Join-Path $LabLogRoot "$LabLogId.stderr.log")
        }finally{foreach($ProxyName in $SavedProxies.Keys){[Environment]::SetEnvironmentVariable($ProxyName,$SavedProxies[$ProxyName],'Process')}}
        $LabDeadline=[DateTime]::UtcNow.AddSeconds(25)
        do {
            Start-Sleep -Milliseconds 250
            if($LabProcess.HasExited){throw "Lab exited with code $($LabProcess.ExitCode); check profile ownership or port availability"}
            $LabOpen=Get-LabOpenLink
        }while(-not $LabOpen -and [DateTime]::UtcNow -lt $LabDeadline)
        if(-not $LabOpen){throw 'Lab startup timed out'}
    }
    if(-not $NoBrowser){Start-Process -FilePath $LabOpen.BrowserUrl | Out-Null}
    # Never print bootstrap/control tokens. The browser consumes its URL fragment.
    [ordered]@{url=$LabOpen.BaseUrl;pid=$LabOpen.Pid;profile=$Profile;browser_opened=(-not $NoBrowser)} | ConvertTo-Json
}catch{
    # This process object exists only when this invocation started the lab.
    # Never terminate an instance merely found through an existing profile.
    if($LabProcess -and -not $LabProcess.HasExited){$LabProcess.Kill()}
    throw
}finally{$LabClient.Dispose();$LabHandler.Dispose()}
