#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$TaskKey,
    [Parameter(Mandatory)][string]$Owner,
    [string]$CacheRoot,
    [string]$ToolchainRoot,
    [switch]$ValidateDependencies,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Environment.psm1') -Force -DisableNameChecking
$record = Read-DsTask $WorkspaceRoot $TaskKey
$status = Get-DsTaskStatus $WorkspaceRoot $TaskKey
if ($record.owner -cne $Owner -or $status.state -ne 'ready') { throw 'Initialization requires the ready task and its registered owner.' }
if (-not $CacheRoot) { $CacheRoot = if ($env:DANSHENG_CACHE_ROOT) { $env:DANSHENG_CACHE_ROOT } elseif ($IsWindows) { 'D:/DevCache' } else { Join-Path $WorkspaceRoot 'local/dependency-cache' } }
$coreComponent = @($record.components | Where-Object name -eq 'core')
$coreRoot = if ($coreComponent.Count) { $coreComponent[0].path } else { $record.core_repository }
$environment = Get-DsRuntimeEnvironment -RuntimeRoot $record.runtime_root -CoreRoot $coreRoot -CoreRepository $record.core_repository -ToolchainRoot $ToolchainRoot -CoreToolsRoot $PSScriptRoot
$plan = Get-DsDependencyCachePlan -Record $record -CacheRoot $CacheRoot -ToolchainRoot $ToolchainRoot
if (-not $Apply) {
    [pscustomobject]@{applied=$false;task=$TaskKey;owner=$Owner;toolchain_available=$environment.toolchain.available;toolchain_root=$environment.toolchain.root;dependency_validation_requested=[bool]$ValidateDependencies;plan=$plan} | ConvertTo-Json -Depth 9
    $global:LASTEXITCODE = 0
    return
}
if (@($record.components | Where-Object name -eq 'core').Count -and -not $environment.toolchain.available) { throw 'Initialize the existing pinned toolchain with -ToolchainRoot before seeding this Core task.' }
$logRoot = Get-DsPath (Join-Path $record.runtime_root ('logs/initialize-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')))
[void][IO.Directory]::CreateDirectory($logRoot)
$copies = @()
foreach ($copy in $plan.copies) { $copies += Copy-DsDependencyCache -Copy $copy -RuntimeRoot $record.runtime_root -Log (Join-Path $logRoot ($copies.Count.ToString() + '-' + $copy.kind + '.log')) }
$validations = @()
if ($ValidateDependencies) {
    $saved = @{}
    foreach ($name in $environment.values.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    try {
        foreach ($name in $environment.values.Keys) { Set-DsProcessEnvironmentValue $name $environment.values[$name] }
        if ($coreComponent.Count) {
            $arguments = @('metadata','--manifest-path',(Join-Path $coreRoot 'Cargo.toml'),'--locked','--offline','--all-features','--format-version','1')
            if ($IsWindows) { $arguments += @('--filter-platform','x86_64-pc-windows-gnu') }
            $metadata = @(& $environment.toolchain.cargo @arguments 2> (Join-Path $logRoot 'cargo-metadata.stderr.log'))
            if ($LASTEXITCODE -ne 0) { throw 'Task Cargo dependency resolution failed; inspect the initialization log without deleting the task cache.' }
            $packages = (($metadata -join "`n") | ConvertFrom-Json).packages.Count
            $validations += [pscustomobject]@{kind='cargo';offline=$true;packages=$packages;exit_code=0}
        }
        $appComponent = @($record.components | Where-Object name -eq 'app')
        if ($appComponent.Count) {
            $lockFile = Join-Path $appComponent[0].path 'pubspec.lock'
            $lockBefore = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash
            Push-Location -LiteralPath $appComponent[0].path
            try {
                & flutter pub get --offline 2>&1 | Tee-Object -FilePath (Join-Path $logRoot 'flutter-pub-get.log')
                if ($LASTEXITCODE -ne 0) { throw 'Task Pub dependency resolution failed; existing files are retained.' }
            } finally { Pop-Location }
            if ((Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash -cne $lockBefore) { throw 'Pub dependency resolution changed its lock; review it before proceeding.' }
            $validations += [pscustomobject]@{kind='pub';offline=$true;lock_unchanged=$true;exit_code=0}
        }
    } finally { foreach ($name in $saved.Keys) { Set-DsProcessEnvironmentValue $name $saved[$name] } }
}
$result = [pscustomobject]@{applied=$true;task=$TaskKey;owner=$Owner;runtime_root=$record.runtime_root;toolchain_root=$environment.toolchain.root;copies=$copies;validations=$validations;log_root=$logRoot;credentials_or_user_profiles_imported=$false;existing_task_data_preserved=$true;sdk_built=$false}
Write-DsJson (Join-Path $logRoot 'result.json') $result
$result | ConvertTo-Json -Depth 8
$global:LASTEXITCODE = 0
