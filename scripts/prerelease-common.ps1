#Requires -Version 7.0
# App release orchestration; Core's pinned tools remain the dependency authority.
function Test-DanshengPrereleaseSdk {
    param([string]$AppRoot, [string]$ArtifactDirectory, [string]$CoreToolsRoot)
    $lock = Get-Content -LiteralPath (Join-Path $AppRoot 'core.lock.json') -Raw | ConvertFrom-Json
    if ($lock.core.commit -notmatch '^[a-f0-9]{40}$') { throw 'Pre-release requires a real locked Core commit.' }
    $acquisition = Get-Content -LiteralPath (Join-Path $AppRoot '.github/prerelease-sdk.json') -Raw | ConvertFrom-Json
    if ($acquisition.validator.core_commit -cne $lock.core.commit -or
        @($acquisition.validator.files).Count -ne 2 -or
        @($acquisition.validator.files.name | Sort-Object -Unique).Count -ne 2) { throw 'Validation tool provenance differs from the exact locked Core commit.' }
    foreach ($tool in $acquisition.validator.files) {
        if ($tool.name -cnotin @('Test-DanshengCoreDependency.ps1','Dansheng.Workspace.psm1') -or
            $tool.sha256 -notmatch '^[a-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath (Join-Path $CoreToolsRoot $tool.name)).Hash -ine $tool.sha256) {
            throw 'Validation tool bytes differ from the pinned Core export.'
        }
    }
    $validator = Join-Path $CoreToolsRoot 'Test-DanshengCoreDependency.ps1'
    # SDK-only consumption: do not substitute a different source snapshot for this SDK.
    $validation = (& $validator -LockFile (Join-Path $AppRoot 'core.lock.json') -ArtifactDirectory $ArtifactDirectory -AppRoot $AppRoot | Out-String) | ConvertFrom-Json
    if (-not $validation.verified) { throw 'Core SDK validation failed.' }
    $receipt = Get-Content -LiteralPath (Join-Path $ArtifactDirectory 'receipt.json') -Raw | ConvertFrom-Json
    if ($receipt.aar_sha256 -ine $lock.artifact.sha256 -or
        $receipt.core_source_sha256 -ine $lock.core.source_sha256 -or
        $receipt.adapter_source_sha256 -ine $lock.core.adapter_source_sha256 -or
        $receipt.core_commit -cne $lock.core.commit) { throw 'SDK producer receipt differs from core.lock.json.' }
    if ((Get-FileHash -LiteralPath (Join-Path $ArtifactDirectory 'legal/COPYING.txt')).Hash -ine
        ($lock.resources | Where-Object path -CEQ 'LICENSE').sha256 -or
        (Get-Item -LiteralPath (Join-Path $ArtifactDirectory 'legal/NATIVE-NOTICES.txt')).Length -eq 0) {
        throw 'SDK licensing payload is missing or differs from the lock.'
    }
    $validation
}

function Get-DanshengPrereleaseFiles {
    param([object]$Lock)
    $files = @($Lock.artifact.name; 'receipt.json'; 'legal/COPYING.txt'; 'legal/NATIVE-NOTICES.txt'
               'validation-tools/Test-DanshengCoreDependency.ps1'; 'validation-tools/Dansheng.Workspace.psm1'
               $Lock.resources | ForEach-Object { 'resources/' + $_.path })
    foreach ($name in $files) {
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]+$' -or $name -match '(^|/)\.{1,2}(/|$)|//') {
            throw 'Unsafe SDK path in lock; no archive operation is permitted.'
        }
    }
    $files
}

function Get-DanshengPrereleaseIdentity {
    param([string]$AppRoot, [string]$Commit)
    $version = [regex]::Match((Get-Content -LiteralPath (Join-Path $AppRoot 'pubspec.yaml') -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $version.Success -or $Commit -notmatch '^[a-f0-9]{40}$') { throw 'Expected a version+build and an exact App Git commit.' }
    $name = $version.Groups[1].Value
    $build = $version.Groups[2].Value
    [pscustomobject]@{
        version = "$name+$build"; version_name = $name; build_number = $build
        commit = $Commit; tag = "prerelease-v$name-build.$build-$($Commit.Substring(0,12))"
        apk_name = "dansheng-$name+$build-arm64-prerelease.apk"
    }
}
