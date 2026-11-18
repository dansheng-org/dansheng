#Requires -Version 7.0
# Final always() step of every job. Keeps this run/job/attempt runtime as the
# job's most recent one (marked finished) and removes the job's earlier finished
# runtimes. With -Checkout it also removes the checkout's untracked build
# outputs. Kept build and dependency caches live outside the runtime.
[CmdletBinding()]
param([string]$Checkout)
$ErrorActionPreference = 'Stop'
if ($Checkout -and (-not [IO.Path]::IsPathFullyQualified($Checkout) -or -not (Test-Path -LiteralPath (Join-Path $Checkout '.git')))) {
    throw 'Checkout cleanup needs an absolute Git checkout.'
}

# Initialization may fail before it exports an owned runtime; the stale sweep
# in Initialize-Runner.ps1 removes anything such a job left behind.
if ($env:DANSHENG_TASK_RUNTIME) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $layout = Get-DanshengCiLayout
    if ((Assert-CiPlainPath $env:DANSHENG_TASK_RUNTIME) -cne $layout.runtime) {
        throw 'Refusing a runtime outside this exact CI run/job/attempt.'
    }
    if ([IO.Directory]::Exists($layout.runtime)) {
        # Common validates the runtime's ancestors; the markers themselves must also be plain.
        $null = Assert-CiPlainPath (Join-Path $layout.runtime '.ci-owned')
        Assert-DanshengCiRuntime $layout
        $finished = Assert-CiPlainPath (Join-Path $layout.runtime '.ci-finished')
        [IO.File]::WriteAllText($finished, $layout.identity)
    }
    Clear-DanshengCiRuntimes $layout -Superseded
}

# actions/checkout cleans the checkout before the next job anyway; clean it now
# so Flutter/Gradle build trees do not occupy the disk while the runner idles.
# Opt-in only: fixtures run this script from inside a real CI checkout.
if ($Checkout) {
    & git -C $Checkout clean -ffdxq
    if ($LASTEXITCODE -ne 0) { Write-Host '::warning::Checkout build outputs were not fully removed.' }
}
