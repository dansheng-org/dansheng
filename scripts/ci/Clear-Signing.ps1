#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'Common.ps1')
# Initialization may have failed before any task-owned signing files existed.
if (-not $env:DANSHENG_TASK_RUNTIME) { return }
$layout = Get-DanshengCiLayout
Assert-DanshengCiRuntime $layout
$directory = Assert-CiPlainPath (Join-Path $layout.runtime 'signing')
if (-not (Test-Path -LiteralPath $directory)) { return }
# Check every descendant before a recursive delete. Never traverse links.
foreach ($item in Get-ChildItem -LiteralPath $directory -Force -Recurse) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Signing cleanup refused a linked descendant.' }
}
Remove-Item -LiteralPath $directory -Recurse -Force
Write-Host 'Removed this run/job/attempt signing directory.'
