# MinGW import sections can depend on the input-library path ordering. Reproduce
# the declared build layout from an empty release cache, retaining the first run.
param([string]$RuntimeRoot,[string]$TargetDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/dev.ps1"
. "$PSScriptRoot/release-common.ps1"
$RebuildRuntime=Resolve-DanshengRuntimeRoot -Root $DanshengRoot -RuntimeRoot $RuntimeRoot
if(-not $TargetDirectory){$TargetDirectory=if($env:CARGO_TARGET_DIR){$env:CARGO_TARGET_DIR}else{Join-Path $RebuildRuntime 'cargo-target'}}
$TargetDirectory=Get-DanshengRuntimeOutput -RuntimeRoot $RebuildRuntime -Path $TargetDirectory
$RebuildFirstPath=Join-Path $RebuildRuntime 'release-current/windows-receipt.json'
& "$PSScriptRoot/build-windows-release.ps1" -RuntimeRoot $RebuildRuntime -TargetDirectory $TargetDirectory -Receipt $RebuildFirstPath
$RebuildFirst=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $RebuildFirstPath -Target windows-x64 -RuntimeRoot $RebuildRuntime
$RebuildSource=Get-DanshengBuildSource -Root $DanshengRoot
$RebuildCache=Get-DanshengRuntimeOutput -RuntimeRoot $RebuildRuntime -Path (Join-Path $TargetDirectory 'release')
$RebuildArchive=Get-DanshengRuntimeOutput -RuntimeRoot $RebuildRuntime -Path (Join-Path $RebuildRuntime ('windows-reproduction/'+[guid]::NewGuid().ToString('N')))
$RebuildSavedCache=Join-Path $RebuildArchive 'release'
# Both fully resolved move endpoints stay in this workspace; only this task's
# release cache moves. Debug tools and all profiles remain in place. No deletion.
foreach($RebuildPath in @($RebuildCache,$RebuildArchive,$RebuildSavedCache)){
    $null=Get-DanshengRuntimeOutput -RuntimeRoot $RebuildRuntime -Path $RebuildPath
}
if($RebuildFirst.artifact_path -cne (Join-Path $RebuildCache 'dansheng-host.exe')){throw 'Unexpected primary Windows artifact path'}
if(Test-Path -LiteralPath $RebuildSavedCache){throw 'Rebuild archive already exists'}
New-Item -ItemType Directory -Path $RebuildArchive | Out-Null
$RebuildWrapper=![string]::IsNullOrEmpty($env:RUSTC_WRAPPER) -or ![string]::IsNullOrEmpty($env:RUSTC_WORKSPACE_WRAPPER)
if($RebuildWrapper){throw 'Independent rebuild must not use a shared compiler wrapper cache'}
Move-Item -LiteralPath $RebuildCache -Destination $RebuildSavedCache
if(Test-Path -LiteralPath $RebuildCache){throw 'Release cache was not emptied'}
$RebuildFirst.artifact_path=Join-Path $RebuildSavedCache 'dansheng-host.exe'
$RebuildFirst|Add-Member -NotePropertyName build_target_directory -NotePropertyValue $TargetDirectory -Force
$RebuildFirst|Add-Member -NotePropertyName relocated_after_build -NotePropertyValue $true -Force
$RebuildIndependent=Get-DanshengRuntimeOutput -RuntimeRoot $RebuildRuntime -Path (Join-Path $RebuildRuntime 'release-current/windows-independent.json')
[IO.File]::WriteAllText($RebuildIndependent,($RebuildFirst|ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
$null=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $RebuildIndependent -Target windows-x64 -RuntimeRoot $RebuildRuntime
& "$PSScriptRoot/build-windows-release.ps1" -RuntimeRoot $RebuildRuntime -TargetDirectory $TargetDirectory -Receipt $RebuildFirstPath
$RebuildSecond=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $RebuildFirstPath -Target windows-x64 -RuntimeRoot $RebuildRuntime
if((Get-DanshengBuildSource -Root $DanshengRoot).sha256 -cne $RebuildSource.sha256){throw 'Source changed during independent rebuild'}
$RebuildMatches=$RebuildFirst.artifact_sha256 -ceq $RebuildSecond.artifact_sha256
$RebuildEvidence=[ordered]@{match=$RebuildMatches;source_sha256=$RebuildSource.sha256;first_sha256=$RebuildFirst.artifact_sha256;second_sha256=$RebuildSecond.artifact_sha256;first_cache=$RebuildSavedCache;second_cache=$RebuildCache;release_cache_empty_before_second=$true;shared_compiled_cache=$false;build_layout='same compile-time target path, distinct independently compiled release directories';linker=$RebuildSecond.linker}
$RebuildEvidence|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $RebuildRuntime 'release-current/windows-reproduction.json') -Encoding utf8
$RebuildEvidence|ConvertTo-Json -Depth 5
if(-not $RebuildMatches){throw 'Independent Windows rebuild differs; do not publish'}
