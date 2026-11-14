param(
    [Parameter(Mandatory)][ValidateSet('login','webvpn')][string]$Action,
    [ValidateSet('academic','canvas','ecard','webvpn')][string]$Target='webvpn',
    [ValidateSet('direct','gateway','auto')][string]$Mode='auto',
    [string[]]$Origins,
    [string]$Profile,
    [string]$RuntimeRoot
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/runtime-common.ps1"
$Profile=Resolve-DanshengLabProfile -Root (Split-Path -Parent $PSScriptRoot) -Profile $Profile -RuntimeRoot $RuntimeRoot
$Control=Get-Content -Raw -LiteralPath (Join-Path $Profile 'lab-control.json') | ConvertFrom-Json
$Base=[uri]$Control.base_url
if($Base.Scheme -ne 'http' -or $Base.Host -ne '127.0.0.1'){throw 'Invalid local lab endpoint'}
$Handler=[Net.Http.HttpClientHandler]::new();$Handler.UseProxy=$false;$Handler.AllowAutoRedirect=$false
$Client=[Net.Http.HttpClient]::new($Handler);$Client.Timeout=[TimeSpan]::FromSeconds(65)
$Endpoint=if($Action -eq 'login'){'login'}else{'routes/webvpn'}
$Body=if($Action -eq 'login'){@{target=$Target}}else{@{mode=$Mode}}
if($Action -eq 'webvpn' -and $Origins){$Body.origins=$Origins}
$Request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,"$($Control.base_url)/api/$Endpoint")
$Request.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Control.control_token)
$Request.Content=[Net.Http.StringContent]::new(($Body|ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')
try {
    $Reply=$Client.SendAsync($Request).GetAwaiter().GetResult()
    $Result=$Reply.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    [ordered]@{ok=$Reply.IsSuccessStatusCode;action=$Action;state=$Result.state;target=$Result.target;mode=$Result.mode;origin_count=$Result.origin_count;error_code=$Result.error.code;progress=$Result.error.progress;message=if($Reply.IsSuccessStatusCode){$Result.message}else{$Result.error.message}} | ConvertTo-Json -Depth 4
    if(-not $Reply.IsSuccessStatusCode){exit 1}
}finally{$Request.Dispose();$Client.Dispose();$Handler.Dispose();if($Reply){$Reply.Dispose()}}
exit 0
