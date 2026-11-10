param(
    [ValidateSet('status','core','public_notices','academic_semesters','academic_diagnostics','canvas_diagnostics','canvas_courses','canvas_content','native_job','network_routes','ecard_balance','rooms','rooms_diagnostics','library_occupancy','bus','cache')][string]$Probe='status',
    [ValidateRange(0,50000)][int]$CourseIndex=0,
    [string]$Profile=(Join-Path $env:LOCALAPPDATA 'dansheng-lab\profiles\manual')
)
$ErrorActionPreference='Stop'
$LabControl=Get-Content -Raw -LiteralPath (Join-Path $Profile 'lab-control.json') | ConvertFrom-Json
$LabBase=[uri]$LabControl.base_url
if($LabBase.Scheme -ne 'http' -or $LabBase.Host -ne '127.0.0.1'){throw 'Invalid local lab endpoint'}
$LabHandler=[Net.Http.HttpClientHandler]::new();$LabHandler.UseProxy=$false
$LabClient=[Net.Http.HttpClient]::new($LabHandler);$LabClient.Timeout=[TimeSpan]::FromSeconds(65)
$LabMethod=if($Probe -eq 'status'){[Net.Http.HttpMethod]::Get}else{[Net.Http.HttpMethod]::Post}
$LabEndpoint=if($Probe -eq 'status'){'status'}elseif($Probe -eq 'academic_diagnostics'){'diagnostic/academic'}elseif($Probe -eq 'rooms_diagnostics'){'diagnostic/rooms'}elseif($Probe -eq 'canvas_diagnostics'){'diagnostic/canvas'}else{'probe'}
$LabRequest=[Net.Http.HttpRequestMessage]::new($LabMethod,"$($LabControl.base_url)/api/$LabEndpoint")
$LabRequest.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$LabControl.control_token)
if($Probe -ne 'status'){$LabRequest.Content=[Net.Http.StringContent]::new((@{probe=$Probe;course_index=$CourseIndex}|ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')}
try {
    $LabResponse=$LabClient.SendAsync($LabRequest).GetAwaiter().GetResult()
    $LabResult=$LabResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    # Only non-sensitive status/summary leaves the HTTP client; no personal result dump.
    if(-not $LabResponse.IsSuccessStatusCode){[ordered]@{ok=$false;code=$LabResult.error.code;message=$LabResult.error.message}|ConvertTo-Json;exit 1}
    if($Probe -eq 'status'){
        [ordered]@{ok=$true;credentials_stored=$LabResult.credentials.stored;session_loaded=$LabResult.session.authenticated;verification=$LabResult.session.verification;last_login=$LabResult.last_login}|ConvertTo-Json -Depth 4
    }elseif($Probe -in @('academic_diagnostics','rooms_diagnostics','canvas_diagnostics')){
        $LabResult | ConvertTo-Json -Depth 6
    }elseif($Probe -in @('canvas_content','native_job')){
        $LabResult | ConvertTo-Json -Depth 6
    }else{
        [ordered]@{ok=$LabResult.ok;probe=$LabResult.probe;elapsed_ms=$LabResult.elapsed_ms;summary=$LabResult.summary}|ConvertTo-Json -Depth 4
    }
}finally{$LabRequest.Dispose();$LabClient.Dispose();$LabHandler.Dispose();if($LabResponse){$LabResponse.Dispose()}}
if($LabResult.ok -eq $false){exit 1}
exit 0
