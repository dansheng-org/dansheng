param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')][string]$Name,
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string[]]$Scope,
    [string]$ConversationId,
    [string]$AgyPath,
    [ValidateSet('UserEnvironment','Inherit')][string]$ProxyMode = 'UserEnvironment',
    [string]$RuntimeRoot
)
$ErrorActionPreference='Stop'
if(-not $AgyPath){$AgyPath=(Get-Command agy -CommandType Application -ErrorAction Stop).Source}
$WorkerProjectRoot=(Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
. "$PSScriptRoot/runtime-common.ps1"
$WorkerRuntime=Resolve-DanshengRuntimeRoot -Root $WorkerProjectRoot -RuntimeRoot $RuntimeRoot
$WorkerOutputRoot=Get-DanshengRuntimeOutput -RuntimeRoot $WorkerRuntime -Path (Join-Path $WorkerRuntime 'workers')
New-Item -ItemType Directory -Force -Path $WorkerOutputRoot | Out-Null
$WorkerPrompt=Get-Content -Raw -LiteralPath $PromptFile
$WorkerLockName=if($ConversationId){[guid]::Parse($ConversationId).ToString()}else{$Name}
$WorkerLockPath=Join-Path $WorkerOutputRoot "$WorkerLockName.lock"
$WorkerLock=[IO.File]::Open($WorkerLockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $prefix=Join-Path $WorkerOutputRoot "$Name-$stamp"
    $WorkerArguments=@('--add-dir',$WorkerProjectRoot,'--dangerously-skip-permissions','--output-format','json','--print-timeout','30m','--model','gemini-3.8-flash-high','--effort','high')
    if($ConversationId){$WorkerArguments+=@('--conversation',$ConversationId)}
    $WorkerArguments+=@('--print',$WorkerPrompt)
    # Codex can supply process-only proxies that differ from a regular terminal.
    # Match persisted user/machine proxy settings for this invocation only; retain
    # system/TUN routing and restore the caller's environment even on failure.
    $ProxyNames=@('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','WS_PROXY','WSS_PROXY')
    $SavedProxyValues=@{}
    Push-Location -LiteralPath $WorkerProjectRoot
    try {
        if($ProxyMode -eq 'UserEnvironment'){
            foreach($ProxyName in $ProxyNames){
                $SavedProxyValues[$ProxyName]=[Environment]::GetEnvironmentVariable($ProxyName,'Process')
                $UserProxyValue=[Environment]::GetEnvironmentVariable($ProxyName,'User')
                if([string]::IsNullOrEmpty($UserProxyValue)){$UserProxyValue=[Environment]::GetEnvironmentVariable($ProxyName,'Machine')}
                [Environment]::SetEnvironmentVariable($ProxyName,$UserProxyValue,'Process')
            }
        }
        & $AgyPath @WorkerArguments > "$prefix.json" 2> "$prefix.stderr.log"
        $WorkerExit=$LASTEXITCODE
    }
    finally {
        foreach($ProxyName in $SavedProxyValues.Keys){[Environment]::SetEnvironmentVariable($ProxyName,$SavedProxyValues[$ProxyName],'Process')}
        Pop-Location
    }
    $WorkerResult=Get-Content -Raw -LiteralPath "$prefix.json" | ConvertFrom-Json
    if(-not $WorkerResult.conversation_id){throw "Missing conversation_id; inspect $prefix.json"}
    $WorkerMatched=(!$ConversationId -or $WorkerResult.conversation_id -ceq $ConversationId)
    $WorkerRecord=[ordered]@{name=$Name;cwd=$WorkerProjectRoot;executable=$AgyPath;proxy_mode=$ProxyMode;scope=$Scope;requested_conversation_id=$ConversationId;conversation_id=$WorkerResult.conversation_id;conversation_id_matches=$WorkerMatched;exit_code=$WorkerExit;status=$WorkerResult.status;output="$prefix.json";stderr="$prefix.stderr.log";independently_verified=$false}
    $WorkerRecord | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $WorkerOutputRoot "$Name-session.json") -Encoding utf8
    $WorkerRecord | ConvertTo-Json -Depth 6
    if(-not $WorkerMatched){throw 'Exact continuation returned a different conversation_id'}
    if($WorkerExit -ne 0){throw "agy worker exited $WorkerExit; saved its conversation and output"}
    if($WorkerResult.status -eq 'ERROR' -or $WorkerResult.error){throw "agy reports an error despite exit code 0; inspect saved output: $prefix.json"}
} finally { $WorkerLock.Dispose() }
