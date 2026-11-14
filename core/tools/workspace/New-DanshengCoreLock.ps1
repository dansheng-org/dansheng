#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CoreRoot,
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$ReceiptFile,
    [Parameter(Mandatory)][string]$AarPath,
    [Parameter(Mandatory)][string]$Destination,
    [string]$AcquisitionUri,
    [switch]$AllowUnversioned,
    [switch]$ForRelease,
    [switch]$Apply
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -Force
$taskCore=Get-DsNativeRepository -Path $CoreRoot -Component core
$taskApp=Get-DsNativeRepository -Path $AppRoot -Component app
Assert-DsNativePair -Core $taskCore -App $taskApp
if(-not $taskCore.head -and -not $AllowUnversioned){throw 'NeedsInitialCommit: use -AllowUnversioned only for an explicitly labelled development snapshot.'}
$taskAar=Get-DsPath $AarPath
$taskDestination=Get-DsPath $Destination
if(Test-Path -LiteralPath $taskDestination){throw 'Refusing to overwrite an existing dependency lock.'}
$taskReceipt=Get-Content -Raw -LiteralPath (Get-DsPath $ReceiptFile)|ConvertFrom-Json
[void](Get-DsSourceHashFormat $taskReceipt)
foreach($taskField in @('core_source_sha256','adapter_source_sha256','aar_sha256','arm64_sha256','x86_64_sha256')){
    if($taskReceipt.$taskField -notmatch '^[a-fA-F0-9]{64}$'){throw 'Native receipt is incomplete.'}
}
if((Get-FileHash -LiteralPath $taskAar).Hash -ne $taskReceipt.aar_sha256){throw 'AAR does not match the native build receipt.'}
. (Join-Path $taskCore.path 'scripts/release-common.ps1')
$taskSource=Invoke-DsWithCleanGitEnvironment -Action {param($Root) Get-DanshengBuildSource -Root $Root} -Arguments @($taskCore.path)
if($taskSource.sha256 -ne $taskReceipt.core_source_sha256 -or (Get-DsAdapterSourceHash $taskCore.path) -ne $taskReceipt.adapter_source_sha256){throw 'Native artifact was built from another Core/adapter snapshot.'}
$taskCargo=[IO.File]::ReadAllText((Join-Path $taskCore.path 'Cargo.toml'))
$taskVersion=[regex]::Match($taskCargo,'(?s)\[workspace\.package\].*?version\s*=\s*"([^"]+)"').Groups[1].Value
if(-not $taskVersion -or $taskVersion -ne $taskReceipt.version){throw 'Core version does not match native receipt.'}
$taskHeader=[IO.File]::ReadAllText((Join-Path $taskCore.path 'include/dansheng.h'))
if($taskHeader -notmatch 'ABI v1\b' -or $taskHeader -notmatch 'dansheng_open\(' -or $taskHeader -notmatch 'dansheng_request\('){throw 'This lock schema requires the audited ABI 1 C header contract.'}
$taskPubLock=Join-Path $taskApp.path 'pubspec.lock'
$taskPigeon=[regex]::Match([IO.File]::ReadAllText($taskPubLock),'(?ms)^  pigeon:\r?\n(?:(?!^  [a-zA-Z_]).)*?version:\s*"([^"]+)"').Groups[1].Value
if(-not $taskPigeon){throw 'Pigeon must be pinned in the Flutter application lockfile.'}
$taskResources=@(foreach($taskRelative in (Get-DsCoreResourcePaths)){
    [pscustomobject]@{path=$taskRelative;sha256=(Get-FileHash -LiteralPath (Get-DsPath (Join-Path $taskCore.path $taskRelative))).Hash.ToLowerInvariant()}
})
$taskNativeEntries=[Collections.Generic.List[object]]::new()
$taskPackagingComplete=$true
$taskArchive=[IO.Compression.ZipFile]::OpenRead($taskAar)
try {
    foreach($taskNative in @([pscustomobject]@{entry='jni/arm64-v8a/libdansheng_ffi.so';hash=$taskReceipt.arm64_sha256;packaged_field='packaged_arm64_sha256'},[pscustomobject]@{entry='jni/x86_64/libdansheng_ffi.so';hash=$taskReceipt.x86_64_sha256;packaged_field='packaged_x86_64_sha256'})){
        $taskMatches=@($taskArchive.Entries|Where-Object FullName -CEQ $taskNative.entry)
        if($taskMatches.Count -ne 1 -or $taskMatches[0].Length -gt 512MB){throw 'AAR native payload is missing, duplicated or exceeds its budget.'}
        $taskEntry=$taskMatches[0]
        $taskStream=$taskEntry.Open(); $taskHasher=[Security.Cryptography.SHA256]::Create()
        try {$taskHash=[BitConverter]::ToString($taskHasher.ComputeHash($taskStream)).Replace('-','')} finally {$taskStream.Dispose();$taskHasher.Dispose()}
        $taskPackaged=$taskReceipt.PSObject.Properties[$taskNative.packaged_field]
        if($taskPackaged){
            if($taskPackaged.Value -notmatch '^[a-fA-F0-9]{64}$' -or $taskHash -ne $taskPackaged.Value){throw 'Packaged AAR native library differs from the packaged producer receipt.'}
        } else {
            $taskPackagingComplete=$false
            if($ForRelease -or -not $AllowUnversioned){throw 'Legacy receipt describes staging SOs; an explicit development snapshot or a packaged-native receipt is required.'}
        }
        $taskNativeEntries.Add([pscustomobject]@{entry=$taskNative.entry;bytes=$taskEntry.Length;sha256=$taskHash.ToLowerInvariant();staging_sha256=$taskNative.hash.ToLowerInvariant()})
    }
} finally {$taskArchive.Dispose()}
if($AcquisitionUri){
    $taskUri=[Uri]$AcquisitionUri
    if(-not $taskUri.IsAbsoluteUri -or $taskUri.Scheme -ne 'https' -or $taskUri.UserInfo -or $taskUri.Query -or $taskUri.Fragment){throw 'Acquisition URI must be credential-free HTTPS without query/fragment.'}
}
if($ForRelease){
    if(-not $taskCore.head -or -not $taskApp.head -or -not $AcquisitionUri){throw 'Stable release requires exact Core/App commits and a published acquisition URI.'}
    foreach($taskRepo in @($taskCore,$taskApp)){if((Invoke-DsGit $taskRepo.path @('status','--porcelain=v1','--untracked-files=all')).text){throw 'Stable producer/consumer inputs must be committed and clean.'}}
    if(Test-Path -LiteralPath (Join-Path $taskApp.path 'pubspec_overrides.yaml')){throw 'Local Pub overrides are forbidden in a stable release.'}
}
$taskToolchain=[regex]::Match([IO.File]::ReadAllText((Join-Path $taskCore.path 'rust-toolchain.toml')),'channel\s*=\s*"([^"]+)"').Groups[1].Value
$taskLock=[pscustomobject]@{
    format='dansheng-core-lock-v1'
    mode='native-sdk'
    state=if($ForRelease){'release'}else{'development_snapshot'}
    core=[pscustomobject]@{version=$taskVersion;commit=$taskCore.head;source_hash_format=$taskSource.source_hash_format;source_subdirectory=$taskSource.source_subdirectory;source_sha256=$taskSource.sha256;adapter_source_sha256=$taskReceipt.adapter_source_sha256.ToLowerInvariant();api_version=1;abi_version=1;rust_toolchain=$taskToolchain;features=@($taskReceipt.features)}
    binding=[pscustomobject]@{kind='pigeon-jni';generator_version=$taskPigeon;pubspec_lock_sha256=(Get-FileHash -LiteralPath $taskPubLock).Hash.ToLowerInvariant()}
    artifact=[pscustomobject]@{name=[IO.Path]::GetFileName($taskAar);format='aar';platform='android';abis=@('arm64-v8a','x86_64');bytes=(Get-Item -LiteralPath $taskAar).Length;sha256=$taskReceipt.aar_sha256.ToLowerInvariant();native_entries=@($taskNativeEntries);packaged_receipt_complete=$taskPackagingComplete;acquisition_uri=if($AcquisitionUri){$AcquisitionUri}else{$null}}
    resources=$taskResources
}
if($Apply){Write-DsJson $taskDestination $taskLock}
[pscustomobject]@{applied=[bool]$Apply;destination=$taskDestination;lock=$taskLock}|ConvertTo-Json -Depth 10
$global:LASTEXITCODE=0
