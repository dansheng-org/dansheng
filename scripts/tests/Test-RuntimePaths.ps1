# Offline boundary tests; optional native smoke uses supplied existing D binaries.
# Retains its new fixture/profile/logs for inspection. Never uses user accounts.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$FixtureRoot,[string]$BinaryDirectory)
$ErrorActionPreference='Stop'
$source=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $source 'scripts/runtime-common.ps1')
$fixture=Get-DanshengCheckedPath $FixtureRoot
if(Test-Path -LiteralPath $fixture){throw 'Choose a new fixture directory; existing evidence is preserved'}
[void][IO.Directory]::CreateDirectory($fixture)
$runtime=Join-Path $fixture 'runtime with spaces'
[void][IO.Directory]::CreateDirectory($runtime)
$checks=[Collections.Generic.List[string]]::new()
function Expect-Rejected([string]$Name,[scriptblock]$Operation,[string]$Message){
    $rejected=$false
    try{& $Operation|Out-Null}catch{if($_.Exception.Message -notlike "*$Message*"){throw};$rejected=$true}
    if(-not $rejected){throw "Expected rejection: $Name"}
    $checks.Add($Name)
}
$saved=@{}
foreach($name in @('DANSHENG_TASK_RUNTIME','DANSHENG_PROFILE','DANSHENG_LAB_PROFILE','DANSHENG_LAB_LOG_DIR','CARGO_TARGET_DIR','CARGO_HOME','PATH','RUSTUP_HOME','RUSTUP_TOOLCHAIN')){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$hostProcess=$null;$mcpProcess=$null;$labProcess=$null;$labStarted=$false
try{
    $env:DANSHENG_TASK_RUNTIME=$null;$env:DANSHENG_PROFILE=$null;$env:DANSHENG_LAB_PROFILE=$null;$env:DANSHENG_LAB_LOG_DIR=$null;$env:CARGO_TARGET_DIR=$null
    $resolved=Resolve-DanshengRuntimeRoot -Root $source -RuntimeRoot $runtime
    if(-not(Test-DanshengPathWithin $runtime $resolved -AllowEqual)){throw 'Runtime resolution changed identity'}
    $checks.Add('independent runtime with spaces')
    Expect-Rejected 'relative runtime' {Resolve-DanshengRuntimeRoot -Root $source -RuntimeRoot './relative'} 'fully qualified'
    Expect-Rejected 'drive root runtime' {Get-DanshengCheckedPath ([IO.Path]::GetPathRoot($fixture))} 'filesystem root'
    Expect-Rejected 'source runtime' {Resolve-DanshengRuntimeRoot -Root $source -RuntimeRoot (Join-Path $source 'target')} 'outside the source'
    Expect-Rejected 'missing task runtime' {Resolve-DanshengRuntimeRoot -Root $source} 'Enter the registered task'
    Expect-Rejected 'no implicit legacy user profile' {Resolve-DanshengLabProfile -Root (Join-Path $fixture 'plain-source')} 'explicit -Profile'
    Expect-Rejected 'parent output traversal' {Get-DanshengRuntimeOutput -RuntimeRoot $runtime -Path (Join-Path $runtime '../escaped')} 'child of the selected runtime'
    Expect-Rejected 'lookalike output prefix' {Get-DanshengRuntimeOutput -RuntimeRoot $runtime -Path ($runtime+'-other/file')} 'child of the selected runtime'
    Expect-Rejected 'runtime root as output' {Get-DanshengRuntimeOutput -RuntimeRoot $runtime -Path $runtime} 'child of the selected runtime'
    $env:DANSHENG_TASK_RUNTIME=$runtime
    Expect-Rejected 'entered task runtime mismatch' {Resolve-DanshengRuntimeRoot -Root $source -RuntimeRoot (Join-Path $fixture 'other')} 'differs from the entered task'
    $profile=Resolve-DanshengLabProfile -Root $source
    if(-not(Test-DanshengPathWithin (Join-Path $runtime 'profiles/lab') $profile -AllowEqual)){throw 'Task lab did not select its own profile'}
    $checks.Add('task lab profile without legacy user data')
    Expect-Rejected 'lab profile outside task' {Resolve-DanshengLabProfile -Root $source -Profile (Join-Path $fixture 'outside-profile')} 'selected task runtime'
    Expect-Rejected 'Windows release output escape before build' {& (Join-Path $source 'scripts/build-windows-release.ps1') -RuntimeRoot $runtime -TargetDirectory (Join-Path $fixture 'outside-target')} 'child of the selected runtime'
    Expect-Rejected 'Android release output escape before build' {& (Join-Path $source 'scripts/build-android-release.ps1') -RuntimeRoot $runtime -TargetDirectory (Join-Path $fixture 'outside-target')} 'child of the selected runtime'
    $existingTarget=Join-Path $runtime 'existing-target';[void][IO.Directory]::CreateDirectory($existingTarget)
    Expect-Rejected 'independent build preserves existing cache' {& (Join-Path $source 'scripts/build-windows-release.ps1') -RuntimeRoot $runtime -TargetDirectory $existingTarget -Independent} 'new, empty target'
    Expect-Rejected 'lab missing binary is task target' {& (Join-Path $source 'scripts/start-lab.ps1') -RuntimeRoot $runtime -SkipBuild -NoBrowser} 'Build dansheng-lab'
    Expect-Rejected 'MCP background rejected' {& (Join-Path $source 'scripts/start-local.ps1') -RuntimeRoot $runtime -Action mcp -Background -SkipBuild} 'only supported for serve'
    Expect-Rejected 'Host missing binary is task target' {& (Join-Path $source 'scripts/start-local.ps1') -RuntimeRoot $runtime -SkipBuild} 'Build dansheng-host'
    if($IsWindows){
        $link=Join-Path $fixture 'linked-runtime'
        [void](New-Item -ItemType Junction -Path $link -Target $runtime)
        Expect-Rejected 'linked runtime rejected' {Resolve-DanshengRuntimeRoot -Root $source -RuntimeRoot $link} 'Linked runtime paths'
        Expect-Rejected 'linked ancestor rejected' {Get-DanshengCheckedPath (Join-Path $link 'new/file')} 'Linked runtime paths'
    }
    if($BinaryDirectory){
        $target=Join-Path $runtime 'cargo-target';$debug=Join-Path $target 'debug'
        [void][IO.Directory]::CreateDirectory($debug)
        foreach($file in @('dansheng-host.exe','dansheng-lab.exe')){
            $binaryInput=Get-DanshengCheckedPath (Join-Path $BinaryDirectory $file)
            Copy-Item -LiteralPath $binaryInput -Destination (Join-Path $debug $file)
        }
        $env:CARGO_TARGET_DIR=$target;$env:CARGO_HOME=Join-Path $runtime 'cargo-home'
        . (Join-Path $source 'scripts/dev.ps1')
        $hostStart=& (Join-Path $source 'scripts/start-local.ps1') -RuntimeRoot $runtime -Background -SkipBuild|ConvertFrom-Json
        $hostProcess=[Diagnostics.Process]::GetProcessById($hostStart.pid)
        $ready=$false;$deadline=[DateTime]::UtcNow.AddSeconds(25)
        do{
            if($hostProcess.HasExited){throw 'Owned host exited during startup'}
            try{$info=& (Join-Path $source 'scripts/start-local.ps1') -RuntimeRoot $runtime -Action call -Method core.info -SkipBuild|ConvertFrom-Json;$ready=$info.result.name -eq 'dansheng-core'}catch{}
            if(-not $ready){Start-Sleep -Milliseconds 100}
        }while(-not $ready -and [DateTime]::UtcNow -lt $deadline)
        if(-not $ready){throw 'Owned host did not become ready'}
        $checks.Add('actual native Host launcher and authenticated core.info')
        $mcpStart=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application|Select-Object -First 1).Source)
        $mcpStart.UseShellExecute=$false;$mcpStart.CreateNoWindow=$true
        $mcpStart.RedirectStandardInput=$true;$mcpStart.RedirectStandardOutput=$true;$mcpStart.RedirectStandardError=$true
        foreach($arg in @('-NoLogo','-NoProfile','-File',(Join-Path $source 'scripts/start-local.ps1'),'-RuntimeRoot',$runtime,'-Action','mcp','-SkipBuild')){$mcpStart.ArgumentList.Add($arg)}
        $mcpProcess=[Diagnostics.Process]::Start($mcpStart)
        function Read-McpReply([int]$Id){
            for($lineIndex=0;$lineIndex -lt 10;$lineIndex++){
                $lineTask=$mcpProcess.StandardOutput.ReadLineAsync()
                if(-not $lineTask.Wait(15000)){throw 'MCP response timed out'}
                if($null -eq $lineTask.Result){throw 'MCP exited before its response'}
                $reply=$lineTask.Result|ConvertFrom-Json
                if($reply.id -eq $Id){if($reply.error){throw 'MCP returned an error'};return $reply}
            }
            throw 'MCP did not return the matching response'
        }
        $mcpProcess.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"owned-path-smoke","version":"1"}}}')
        $initialized=Read-McpReply 1
        if($initialized.result.serverInfo.name -ne 'dansheng-host'){throw 'Unexpected MCP server'}
        $mcpProcess.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $mcpProcess.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
        $listed=Read-McpReply 2
        if(-not @($listed.result.tools|Where-Object name -eq 'core_call').Count){throw 'MCP core tool missing'}
        $checks.Add('actual MCP launcher initialize and tools/list')
        $lab=& (Join-Path $source 'scripts/start-lab.ps1') -RuntimeRoot $runtime -SkipBuild -NoBrowser|ConvertFrom-Json
        $labStarted=$true
        $labProcess=[Diagnostics.Process]::GetProcessById($lab.pid)
        if(([uri]$lab.url).Port -eq 19764 -or $lab.profile -eq (Join-Path $runtime 'profiles/core')){throw 'Lab did not isolate profile/port'}
        $status=& (Join-Path $source 'scripts/probe-lab.ps1') -RuntimeRoot $runtime -Probe status|ConvertFrom-Json
        if(-not $status.ok -or $status.credentials_stored){throw 'Fresh lab status was not credential-free'}
        $checks.Add('actual lab launcher Port0 and independent empty profile status')
        $labAgain=& (Join-Path $source 'scripts/start-lab.ps1') -RuntimeRoot $runtime -SkipBuild -NoBrowser|ConvertFrom-Json
        if($labAgain.pid -ne $lab.pid){throw 'Own lab profile did not reuse its instance'}
        $checks.Add('same owned lab reuse without starting another process')
        $stopped=& (Join-Path $source 'scripts/stop-lab.ps1') -RuntimeRoot $runtime|ConvertFrom-Json
        if(-not $stopped.stopping){throw 'Owned lab stop did not acknowledge'}
        if(-not $labProcess.WaitForExit(10000)){throw 'Owned lab did not exit after shutdown'}
        $labStarted=$false;$checks.Add('owned lab stop via local control channel')
    }
    $result=[ordered]@{passed=$true;checks=$checks.Count;names=@($checks);fixture=$fixture;native_smoke=[bool]$BinaryDirectory;binary_origin='Optional launcher smoke reuses supplied existing D binaries; this is not a new compile or SDK receipt';school_requests=$false;original_profiles_read=$false;fixture_retained=$true}
    [IO.File]::WriteAllText((Join-Path $fixture 'result.json'),($result|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
    $result|ConvertTo-Json -Depth 5
}finally{
    if($labStarted){try{& (Join-Path $source 'scripts/stop-lab.ps1') -RuntimeRoot $runtime|Out-Null}catch{}}
    foreach($process in @($mcpProcess,$hostProcess,$labProcess)){if($process -and -not $process.HasExited){$process.Kill();$process.WaitForExit(10000)|Out-Null}}
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
}
