param(
    [string]$Profile = (Join-Path $env:LOCALAPPDATA 'dansheng-lab\profiles\manual'),
    [ValidateRange(0,65535)][int]$Port = 19764,
    [switch]$NoBrowser,
    [switch]$SkipBuild
)
$ErrorActionPreference='Stop'
$LabRoot=Split-Path -Parent $PSScriptRoot
$Profile=[IO.Path]::GetFullPath($Profile).TrimEnd([IO.Path]::DirectorySeparatorChar)
if($Profile.Contains('"')){throw 'Invalid profile path'}
$LabBinary=Join-Path $LabRoot 'target\debug\dansheng-lab.exe'
$LabControlPath=Join-Path $Profile 'lab-control.json'
$LabHandler=[System.Net.Http.HttpClientHandler]::new()
$LabHandler.UseProxy=$false
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
            Push-Location -LiteralPath $LabRoot
            try { & cargo build -p dansheng-lab --locked; if($LASTEXITCODE -ne 0){throw 'Lab build failed'} }
            finally { Pop-Location }
        }
        if(-not(Test-Path -LiteralPath $LabBinary)){throw 'Build dansheng-lab before using -SkipBuild'}
        $LabLogRoot=Join-Path $env:LOCALAPPDATA 'dansheng-lab\logs'
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
}finally{$LabClient.Dispose();$LabHandler.Dispose()}
