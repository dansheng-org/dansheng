# Interactive local entry only: no token argument, file, environment variable or log.
param([string]$Profile=(Join-Path $env:LOCALAPPDATA 'dansheng-lab/profiles/manual'))
$ErrorActionPreference='Stop'
$CanvasControl=Get-Content -Raw -LiteralPath (Join-Path $Profile 'lab-control.json') | ConvertFrom-Json
$CanvasBase=[uri]$CanvasControl.base_url
if($CanvasBase.Scheme -ne 'http' -or $CanvasBase.Host -ne '127.0.0.1' -or $CanvasBase.UserInfo -or $CanvasBase.Query -or $CanvasBase.Fragment -or $CanvasBase.AbsolutePath -ne '/'){
    throw 'Invalid local Lab endpoint'
}
$CanvasSecret=Read-Host 'Canvas access token (hidden)' -AsSecureString
$CanvasPointer=[IntPtr]::Zero
$CanvasHandler=[Net.Http.HttpClientHandler]::new();$CanvasHandler.UseProxy=$false;$CanvasHandler.AllowAutoRedirect=$false
$CanvasClient=[Net.Http.HttpClient]::new($CanvasHandler);$CanvasClient.Timeout=[TimeSpan]::FromSeconds(65)
$CanvasRequest=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,"$($CanvasControl.base_url)/api/canvas/token")
$CanvasRequest.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$CanvasControl.control_token)
try {
    $CanvasPointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($CanvasSecret)
    $CanvasPlain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($CanvasPointer)
    $CanvasRequest.Content=[Net.Http.StringContent]::new((@{token=$CanvasPlain}|ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')
    $CanvasResponse=$CanvasClient.SendAsync($CanvasRequest).GetAwaiter().GetResult()
    $CanvasResult=$CanvasResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json
    if(-not $CanvasResponse.IsSuccessStatusCode){throw "Token binding did not return a success receipt (local HTTP $([int]$CanvasResponse.StatusCode)); inspect local status before retrying"}
    [ordered]@{configured=$CanvasResult.configured;access=$CanvasResult.access;identity_verified=$CanvasResult.identity_verified;persisted=$CanvasResult.persisted}|ConvertTo-Json
} finally {
    $CanvasPlain=$null;$CanvasResult=$null
    if($CanvasPointer -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($CanvasPointer)}
    $CanvasSecret.Dispose();$CanvasRequest.Dispose();$CanvasClient.Dispose();$CanvasHandler.Dispose()
    if($CanvasResponse){$CanvasResponse.Dispose()}
}
