#Requires -Version 7.0
# Run the real PowerShell tools' regression fixtures on Linux from a Bash job.
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location (Join-Path $repository 'apps/dansheng_app')
try {
    ./scripts/tests/core-dependency.tests.ps1
    ./scripts/tests/core-tools.tests.ps1
    ./scripts/tests/apk-archive.tests.ps1
    ./scripts/tests/prerelease.tests.ps1
    ./scripts/tests/android-host.tests.ps1
    ./scripts/tests/build-parallelism.tests.ps1
    ./scripts/tests/monorepo-paths.tests.ps1
    ../../scripts/ci/tests/Runner.Tests.ps1
    ../../scripts/ci/tests/PublicCaches.Tests.ps1
    ../../scripts/ci/tests/BuildOutputs.Tests.ps1
    ../../scripts/tests/Enter.Tests.ps1 -FixtureRoot (Join-Path $env:DANSHENG_TASK_RUNTIME 'entry-fixtures')
} finally {
    Pop-Location
}
