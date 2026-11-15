#Requires -Version 7.0
# App release orchestration; Core's pinned tools remain the dependency authority.
function Resolve-DanshengPrereleaseGradle {
    param([string]$CommandPath, [string]$GradleHome)
    # Flutter's generated gradlew.bat is intentionally not a checkout input.
    # CI installs the pinned distribution before this script (setup-gradle).
    if (-not $CommandPath -and -not $GradleHome) {
        $command = Get-Command gradle.bat -ErrorAction SilentlyContinue
        if ($command) { $CommandPath = $command.Source }
        if (-not $CommandPath) { $GradleHome = $env:GRADLE_HOME }
    }
    if (-not $CommandPath -and $GradleHome) { $CommandPath = Join-Path $GradleHome 'bin/gradle.bat' }
    if (-not $CommandPath -or -not (Test-Path -LiteralPath $CommandPath -PathType Leaf)) {
        throw 'Install Gradle 9.7.1 on PATH or set GRADLE_HOME before building the source SDK.'
    }
    $CommandPath = [IO.Path]::GetFullPath($CommandPath)
    $homePath = Split-Path -Parent (Split-Path -Parent $CommandPath)
    if (-not (Test-Path -LiteralPath (Join-Path $homePath 'lib/gradle-launcher-9.7.1.jar') -PathType Leaf)) {
        throw 'Source SDK requires the pinned Gradle 9.7.1 installation.'
    }
    $CommandPath
}

function Resolve-DanshengPrereleaseManifest {
    param([Parameter(Mandatory)][string]$AppRoot)
    $appPath=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/')
    $parent=Split-Path -Parent $appPath
    $root=if((Split-Path -Leaf $appPath)-ieq'dansheng_app'-and(Split-Path -Leaf $parent)-ieq'apps'){
        Split-Path -Parent $parent
    }else{$appPath}
    Join-Path $root '.github/prerelease-sdk.json'
}

function Assert-DanshengPrereleaseCheckout {
    param([string]$AppRoot, [string]$CoreRoot, [string]$Commit, [switch]$RequireClean)
    $root = [IO.Path]::GetFullPath((Join-Path $AppRoot '../..')).TrimEnd('\','/')
    if ([IO.Path]::GetFullPath($CoreRoot).TrimEnd('\','/') -ine (Join-Path $root 'core')) {
        throw 'Pre-release Core must be the same monorepo checkout as App.'
    }
    $head = & git --no-optional-locks -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -cne $Commit -or $Commit -notmatch '^[a-f0-9]{40}$') {
        throw 'Pre-release requires the exact checkout commit.'
    }
    if ($RequireClean) {
        $changes = @(& git --no-optional-locks -C $root status --porcelain --untracked-files=all)
        if ($LASTEXITCODE -ne 0 -or $changes.Count) { throw 'Pre-release requires clean committed source inputs.' }
    }
}

function Test-DanshengPrereleaseSdk {
    param([string]$AppRoot, [string]$ArtifactDirectory, [string]$CoreToolsRoot, [string]$LockFile, [string]$CoreRoot)
    if (-not $LockFile) { $LockFile = Join-Path $AppRoot 'core.lock.json' }
    $lock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
    if ($lock.core.commit -notmatch '^[a-f0-9]{40}$') { throw 'Pre-release requires a real locked Core commit.' }
    $validatorArguments = @{ LockFile=$LockFile; ArtifactDirectory=$ArtifactDirectory }
    if ($CoreRoot) {
        Assert-DanshengPrereleaseCheckout -AppRoot $AppRoot -CoreRoot $CoreRoot -Commit $lock.core.commit -RequireClean:($env:GITHUB_ACTIONS -eq 'true')
        if ([IO.Path]::GetFullPath($CoreToolsRoot).TrimEnd('\','/') -ine [IO.Path]::GetFullPath((Join-Path $CoreRoot 'tools/workspace'))) {
            throw 'Source SDK validation must use tools from the exact Core checkout.'
        }
        $validatorArguments.CoreRoot = $CoreRoot
        $validatorArguments.AppRoot = $AppRoot
    } else {
        $acquisition = Get-Content -LiteralPath (Resolve-DanshengPrereleaseManifest -AppRoot $AppRoot) -Raw | ConvertFrom-Json
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
    }
    $validator = Join-Path $CoreToolsRoot 'Test-DanshengCoreDependency.ps1'
    # The immutable SDK validator predates nested App roots. Perform its App lock
    # check here, while leaving all SDK/ABI/resource checks with the pinned tool.
    if ((Get-FileHash -LiteralPath (Join-Path $AppRoot 'pubspec.lock')).Hash -ine $lock.binding.pubspec_lock_sha256) {
        throw 'Flutter/Pigeon dependency lock differs.'
    }
    if (Test-Path -LiteralPath (Join-Path $AppRoot 'pubspec_overrides.yaml')) { throw 'Pre-release does not accept local Pub overrides.' }
    # Source mode also checks actual Core/adapter/resource bytes, not just SDK self-consistency.
    $validation = (& $validator @validatorArguments | Out-String) | ConvertFrom-Json
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
