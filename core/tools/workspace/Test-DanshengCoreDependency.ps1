#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$LockFile,[Parameter(Mandatory)][string]$ArtifactDirectory,[string]$CoreRoot,[string]$AppRoot,[switch]$ForRelease)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
$taskLock=Get-Content -Raw -LiteralPath (Get-DsPath $LockFile)|ConvertFrom-Json
$taskHashFormat=Get-DsSourceHashFormat $taskLock.core
$taskSourceSubdirectory=if($taskLock.core.PSObject.Properties['source_subdirectory']){$taskLock.core.source_subdirectory}else{'.'}
if($taskSourceSubdirectory -cnotin @('.','core')){throw 'Unsupported Core source_subdirectory.'}
foreach($taskIdentity in @($taskLock.format,$taskLock.mode,$taskLock.state,$taskLock.core.version,$taskLock.core.source_sha256,$taskLock.core.adapter_source_sha256,$taskLock.core.rust_toolchain,$taskLock.binding.kind,$taskLock.binding.generator_version,$taskLock.binding.pubspec_lock_sha256,$taskLock.artifact.name,$taskLock.artifact.format,$taskLock.artifact.platform,$taskLock.artifact.sha256)){
    if($taskIdentity -isnot [string] -or [string]::IsNullOrWhiteSpace($taskIdentity)){throw 'Core lock identity fields must be nonempty strings.'}
}
if($taskLock.artifact.packaged_receipt_complete -isnot [bool]){throw 'Packaged receipt completeness must be a JSON boolean.'}
if($taskLock.state -notin @('release','development_snapshot') -or ($null -ne $taskLock.core.commit -and ($taskLock.core.commit -isnot [string] -or $taskLock.core.commit -notmatch '^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$'))){throw 'Invalid Core revision or dependency state.'}
if($taskLock.state -eq 'release' -and -not $taskLock.core.commit){throw 'A release source requires a committed Core revision; unversioned sources are development snapshots only.'}
if($taskLock.format -ne 'dansheng-core-lock-v1' -or $taskLock.mode -ne 'native-sdk'){throw 'Unsupported Core lock format/mode.'}
if($taskLock.artifact.format -ne 'aar' -or $taskLock.artifact.platform -ne 'android' -or @($taskLock.artifact.abis).Count -ne 2 -or @($taskLock.artifact.abis|Select-Object -Unique).Count -ne 2 -or @($taskLock.artifact.abis|Where-Object {$_ -cnotin @('arm64-v8a','x86_64')}).Count -or $taskLock.binding.kind -ne 'pigeon-jni' -or $taskLock.binding.generator_version -notmatch '^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$' -or $taskLock.binding.pubspec_lock_sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Missing Android platform, ABI or binding identities.'}
if($taskLock.core.source_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $taskLock.core.adapter_source_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $taskLock.core.abi_version -ne 1 -or $taskLock.core.api_version -ne 1){throw 'Missing source/protocol identities.'}
if(-not $taskLock.artifact.name -or $taskLock.artifact.name -match '[/\\:]' -or $taskLock.artifact.name -in @('.','..') -or $taskLock.artifact.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid artifact identity or relative name.'}
$taskExpectedResources=@(Get-DsCoreResourcePaths)
$taskResourceNames=@($taskLock.resources|ForEach-Object path)
if($taskResourceNames.Count -ne $taskExpectedResources.Count -or @($taskResourceNames|Select-Object -Unique).Count -ne $taskExpectedResources.Count -or @($taskResourceNames|Where-Object {$_ -cnotin $taskExpectedResources}).Count){throw 'Core resource lock must contain the complete unique runtime resource set.'}
$taskArtifacts=Get-DsPath $ArtifactDirectory
$taskArtifact=Get-DsPath (Join-Path $taskArtifacts $taskLock.artifact.name)
if(-not (Test-DsWithin $taskArtifacts $taskArtifact) -or -not (Test-Path -LiteralPath $taskArtifact -PathType Leaf)){throw 'Locked artifact is missing.'}
if((Get-Item -LiteralPath $taskArtifact).Length -ne $taskLock.artifact.bytes -or (Get-FileHash -LiteralPath $taskArtifact).Hash -ne $taskLock.artifact.sha256){throw 'Artifact SHA256/size does not match the lock; no build is permitted.'}
if(@($taskLock.artifact.native_entries).Count -ne 2 -or @($taskLock.artifact.native_entries.entry|Select-Object -Unique).Count -ne 2){throw 'Both distinct Android native entries must be locked.'}
$taskArchive=[IO.Compression.ZipFile]::OpenRead($taskArtifact)
try {
    foreach($taskNative in $taskLock.artifact.native_entries){
        if($taskNative.entry -notin @('jni/arm64-v8a/libdansheng_ffi.so','jni/x86_64/libdansheng_ffi.so') -or $taskNative.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid locked native entry.'}
        $taskMatches=@($taskArchive.Entries|Where-Object FullName -CEQ $taskNative.entry)
        if($taskMatches.Count -ne 1 -or $taskMatches[0].Length -ne $taskNative.bytes -or $taskMatches[0].Length -gt 512MB){throw 'Locked native entry is missing, duplicated or changed.'}
        $taskEntry=$taskMatches[0]
        $taskStream=$taskEntry.Open(); $taskHasher=[Security.Cryptography.SHA256]::Create()
        try {$taskHash=[BitConverter]::ToString($taskHasher.ComputeHash($taskStream)).Replace('-','')} finally {$taskStream.Dispose();$taskHasher.Dispose()}
        if($taskHash -ne $taskNative.sha256){throw 'Locked native entry SHA256 differs.'}
    }
} finally {$taskArchive.Dispose()}
if($CoreRoot){
    $taskCore=Get-DsNativeRepository -Path $CoreRoot -Component core
    . (Join-Path $taskCore.path 'scripts/release-common.ps1')
    $taskSource=Invoke-DsWithCleanGitEnvironment -Action {param($Root) Get-DanshengBuildSource -Root $Root} -Arguments @($taskCore.path)
    if($taskHashFormat -cne $taskSource.source_hash_format -or $taskSourceSubdirectory -cne $taskSource.source_subdirectory){throw 'Core source identity format or module differs from the lock.'}
    if($taskSource.sha256 -ne $taskLock.core.source_sha256){throw 'Core source snapshot differs from the lock.'}
    if((Get-DsAdapterSourceHash $taskCore.path) -ne $taskLock.core.adapter_source_sha256){throw 'Core Android adapter source snapshot differs from the lock.'}
    if($taskLock.core.commit -and $taskCore.head -ne $taskLock.core.commit){
        # An App/lock-only commit advances the shared HEAD without changing Core.
        # Keep exact source/adapter/resource hashes, reachable provenance and the
        # complete committed Core tree. A base SHA never relabels new Core commits.
        if(-not $taskCore.module -or (Invoke-DsGit $taskCore.checkout_root @('merge-base','--is-ancestor',$taskLock.core.commit,'HEAD') @(0,1,128)).exit_code -ne 0){throw 'Core checkout is not the locked commit or its monorepo descendant.'}
        if((Invoke-DsGit $taskCore.checkout_root @('diff','--quiet',$taskLock.core.commit,'HEAD','--','core/') @(0,1)).exit_code -ne 0){throw 'Committed Core tree differs from the locked commit; rebuild or explicitly regenerate its dependency lock.'}
    }
    if($ForRelease -and (Invoke-DsGit $taskCore.path @('status','--porcelain=v1','--untracked-files=all')).text){throw 'Stable Core checkout has uncommitted inputs.'}
}
$taskResourceRoot=if($CoreRoot){Get-DsPath $CoreRoot}else{Get-DsPath (Join-Path $taskArtifacts 'resources')}
foreach($taskResource in $taskLock.resources){
    if([IO.Path]::IsPathRooted($taskResource.path) -or $taskResource.path -match '(^|[/\\])\.\.([/\\]|$)' -or $taskResource.sha256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid locked resource path/hash.'}
    $taskResourcePath=Get-DsPath (Join-Path $taskResourceRoot $taskResource.path)
    if(-not (Test-DsWithin $taskResourceRoot $taskResourcePath) -or -not (Test-Path -LiteralPath $taskResourcePath -PathType Leaf) -or (Get-FileHash -LiteralPath $taskResourcePath).Hash -ne $taskResource.sha256){throw 'Core runtime resource differs from the lock.'}
}
if($AppRoot){
    $taskApp=Get-DsNativeRepository -Path $AppRoot -Component app
    if($CoreRoot){Assert-DsNativePair -Core $taskCore -App $taskApp}
    if((Get-FileHash -LiteralPath (Join-Path $taskApp.path 'pubspec.lock')).Hash -ne $taskLock.binding.pubspec_lock_sha256){throw 'Flutter/Pigeon dependency lock differs.'}
    if($ForRelease -and (Test-Path -LiteralPath (Join-Path $taskApp.path 'pubspec_overrides.yaml'))){throw 'A local Pub override is still active.'}
}
if($ForRelease){
    if($taskLock.state -ne 'release' -or $taskLock.core.commit -isnot [string] -or $taskLock.core.commit -notmatch '^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$' -or $taskLock.artifact.acquisition_uri -isnot [string] -or -not $taskLock.artifact.acquisition_uri -or $taskLock.artifact.packaged_receipt_complete -ne $true){throw 'Unversioned/development snapshot or incomplete packaged receipt cannot be a stable release dependency.'}
    $taskUri=[Uri]$taskLock.artifact.acquisition_uri
    if(-not $taskUri.IsAbsoluteUri -or $taskUri.Scheme -ne 'https' -or $taskUri.UserInfo -or $taskUri.Query -or $taskUri.Fragment){throw 'Published SDK acquisition is not credential-free HTTPS.'}
}
[pscustomobject]@{verified=$true;state=$taskLock.state;core_commit=$taskLock.core.commit;source_hash_format=$taskHashFormat;source_subdirectory=$taskSourceSubdirectory;source_sha256=$taskLock.core.source_sha256;artifact_sha256=$taskLock.artifact.sha256;resource_files=@($taskLock.resources).Count;packaged_receipt_complete=$taskLock.artifact.packaged_receipt_complete;stable_release_verified=[bool]$ForRelease}|ConvertTo-Json -Depth 5
