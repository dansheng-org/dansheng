#Requires -Version 7.0
# Runs the worktree workflow fixture suites side by side. They share nothing:
# each creates its own synthetic Git repositories under its own output
# directory and runs in its own process, so environment changes made by one
# suite never reach the other. On Windows both spend minutes launching git
# (~1,100 calls at ~50-80 ms each); in sequence they took ~3 min.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CoreRoot,
    [Parameter(Mandatory)][string]$OutputRoot
)
$ErrorActionPreference = 'Stop'
# Resolve against PowerShell's location; .NET's process directory can differ.
$tests = Join-Path (Resolve-Path -LiteralPath $CoreRoot).Path 'tools/workspace/tests'
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$pwsh = (Get-Process -Id $PID).Path
$runs = foreach ($name in @('Workspace', 'Monorepo')) {
    $output = Join-Path $OutputRoot "$($name.ToLowerInvariant())-fixtures"
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $tests "Test-$name.ps1"), '-OutputDirectory', $output)) {
        $start.ArgumentList.Add($argument)
    }
    $start.WorkingDirectory = (Get-Location).Path
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    [pscustomobject]@{
        name = "Test-$name"
        process = $process
        stdout = $process.StandardOutput.ReadToEndAsync()
        stderr = $process.StandardError.ReadToEndAsync()
        seconds = $null
    }
}
# Note each suite's own duration as it finishes (Process.ExitTime is not
# available on every platform).
$clock = [Diagnostics.Stopwatch]::StartNew()
while (@($runs | Where-Object { $null -eq $_.seconds }).Count) {
    foreach ($run in $runs) {
        if ($null -eq $run.seconds -and $run.process.HasExited) { $run.seconds = $clock.Elapsed.TotalSeconds }
    }
    Start-Sleep -Milliseconds 200
}
$failed = @()
foreach ($run in $runs) {
    $run.process.WaitForExit()
    $seconds = $run.seconds
    $exit = $run.process.ExitCode
    Write-Host "::group::$($run.name) (exit $exit, $([math]::Round($seconds))s)"
    Write-Host $run.stdout.GetAwaiter().GetResult()
    $err = $run.stderr.GetAwaiter().GetResult()
    if ($err.Trim()) { Write-Host $err }
    Write-Host '::endgroup::'
    if ($exit -ne 0) { $failed += $run.name }
    $run.process.Dispose()
}
if ($failed) { throw "Fixture suites failed: $($failed -join ', ')" }
