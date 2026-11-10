param([string]$Profile=(Join-Path $env:LOCALAPPDATA 'dansheng-lab\profiles\manual'))
$ErrorActionPreference='Stop'
$LabControl=Get-Content -Raw -LiteralPath (Join-Path $Profile 'lab-control.json') | ConvertFrom-Json
$LabBase=[uri]$LabControl.base_url
if($LabBase.Scheme -ne 'http' -or $LabBase.Host -ne '127.0.0.1'){throw 'Invalid local lab endpoint'}
$LabHandler=[Net.Http.HttpClientHandler]::new()
$LabHandler.UseProxy=$false
$LabClient=[Net.Http.HttpClient]::new($LabHandler)
$LabClient.Timeout=[TimeSpan]::FromSeconds(5)
$LabRequest=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,"$($LabControl.base_url)/api/stop")
$LabRequest.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$LabControl.control_token)
$LabRequest.Content=[Net.Http.StringContent]::new('{}',[Text.Encoding]::UTF8,'application/json')
try {
    $LabResponse=$LabClient.SendAsync($LabRequest).GetAwaiter().GetResult()
    if(-not $LabResponse.IsSuccessStatusCode){throw 'Lab shutdown was rejected'}
    [ordered]@{stopping=$true;url=$LabControl.base_url} | ConvertTo-Json
}finally{$LabRequest.Dispose();$LabClient.Dispose();$LabHandler.Dispose();if($LabResponse){$LabResponse.Dispose()}}
