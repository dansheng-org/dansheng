param([string]$WindowsReceipt,[string]$AndroidReceipt,[string]$WindowsIndependentReceipt,[string]$AndroidIndependentReceipt,[string]$OutputDirectory,[string]$RuntimeRoot,[string]$ValidationDocument)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/dev.ps1"
. "$PSScriptRoot/release-common.ps1"
$PackageRuntime=Resolve-DanshengRuntimeRoot -Root $DanshengRoot -RuntimeRoot $RuntimeRoot
if(-not $WindowsReceipt){$WindowsReceipt=Join-Path $PackageRuntime 'release-current/windows-receipt.json'}
if(-not $AndroidReceipt){$AndroidReceipt=Join-Path $PackageRuntime 'android-current/arm64-receipt.json'}
if(-not $WindowsIndependentReceipt){$WindowsIndependentReceipt=Join-Path $PackageRuntime 'release-current/windows-independent.json'}
if(-not $AndroidIndependentReceipt){$AndroidIndependentReceipt=Join-Path $PackageRuntime 'android-current/arm64-independent-final-receipt.json'}
$WindowsProof=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $WindowsReceipt -Target windows-x64 -RuntimeRoot $PackageRuntime
$AndroidProof=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $AndroidReceipt -Target android-arm64 -RuntimeRoot $PackageRuntime
$WindowsRepeat=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $WindowsIndependentReceipt -Target windows-x64 -RuntimeRoot $PackageRuntime
$AndroidRepeat=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $AndroidIndependentReceipt -Target android-arm64 -RuntimeRoot $PackageRuntime
foreach($pair in @(@{first=$WindowsProof;second=$WindowsRepeat},@{first=$AndroidProof;second=$AndroidRepeat})){
    if($pair.first.artifact_sha256 -cne $pair.second.artifact_sha256 -or $pair.first.artifact_path -eq $pair.second.artifact_path){throw 'Release requires matching binaries from distinct build output paths'}
}
if($WindowsProof.rustc -cne $AndroidProof.rustc){throw 'Platform releases use different Rust compiler versions'}
$BuildSource=Get-DanshengBuildSource -Root $DanshengRoot
$PackageValidation=if($ValidationDocument){[IO.Path]::GetFullPath($ValidationDocument)}else{Join-Path $DanshengRoot 'docs\validation.md'}
$PackageSourceBoundary=[IO.Path]::GetFullPath($DanshengRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
if(-not $PackageValidation.StartsWith($PackageSourceBoundary,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $PackageValidation -PathType Leaf)){throw 'Validation document must be an existing workspace source file'}
if((Get-Item -LiteralPath $PackageValidation).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked validation document refused'}
$PackageValidationAncestor=Split-Path -Parent $PackageValidation
while($PackageValidationAncestor.StartsWith($PackageSourceBoundary,[StringComparison]::OrdinalIgnoreCase) -or $PackageValidationAncestor -eq $DanshengRoot){
    if((Get-Item -LiteralPath $PackageValidationAncestor).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked validation document ancestor refused'}
    if($PackageValidationAncestor -eq $DanshengRoot){break}
    $PackageValidationAncestor=Split-Path -Parent $PackageValidationAncestor
}
$PackageValidationHash=(Get-FileHash -LiteralPath $PackageValidation -Algorithm SHA256).Hash.ToLowerInvariant()
$PackageValidationRelative=[IO.Path]::GetRelativePath($DanshengRoot,$PackageValidation).Replace('\','/')
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PackageRuntime 'dist/dansheng-core-0.1.0'}
$PackageDestination=Get-DanshengRuntimeOutput -RuntimeRoot $PackageRuntime -Path $OutputDirectory
$PackageBoundary=(Get-DanshengRuntimeOutput -RuntimeRoot $PackageRuntime -Path (Join-Path $PackageRuntime 'dist'))+[IO.Path]::DirectorySeparatorChar
if([IO.Path]::GetDirectoryName($PackageDestination).TrimEnd('\','/') -cne $PackageBoundary.TrimEnd('\','/')){throw 'Package output must be a direct child directory under runtime/dist'}
New-Item -ItemType Directory -Force -Path $PackageBoundary | Out-Null
if((Get-Item -LiteralPath $PackageBoundary).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked package directory refused'}
$PackageRoot=Join-Path $PackageBoundary ('.staging-'+[guid]::NewGuid().ToString('N'))
$WindowsBundle=Join-Path $PackageRoot 'windows-x64'
$AndroidBundle=Join-Path $PackageRoot 'android-arm64'
New-Item -ItemType Directory -Force -Path $WindowsBundle,$AndroidBundle | Out-Null
$WindowsBinary=$WindowsProof.artifact_path
$AndroidBinary=$AndroidProof.artifact_path
foreach($inputFile in @($WindowsBinary,$AndroidBinary)){if(-not(Test-Path -LiteralPath $inputFile)){throw "Build the release artifact first: $inputFile"}}
Copy-Item -LiteralPath $WindowsBinary -Destination (Join-Path $WindowsBundle 'dansheng-host.exe') -Force
Copy-Item -LiteralPath $AndroidBinary -Destination (Join-Path $AndroidBundle 'libdansheng_ffi.so') -Force
Copy-Item -LiteralPath (Join-Path $DanshengRoot 'include\dansheng.h') -Destination $AndroidBundle -Force
foreach($bundle in @($WindowsBundle,$AndroidBundle)){Copy-Item -LiteralPath (Join-Path $DanshengRoot 'LICENSE') -Destination $bundle -Force}

$PackageMetadata=(& cargo metadata --manifest-path (Join-Path $DanshengRoot 'Cargo.toml') --locked --offline --all-features --format-version 1 | ConvertFrom-Json)
if($LASTEXITCODE -ne 0){throw 'Cannot collect dependency license metadata'}
$LicenseRows=@($PackageMetadata.packages | Sort-Object name,version | ForEach-Object { [ordered]@{name=$_.name;version=$_.version;license=$_.license;repository=$_.repository} })
$LicenseRows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PackageRoot 'dependency-licenses.json') -Encoding utf8
$Notices=[Text.StringBuilder]::new()
[void]$Notices.AppendLine('dansheng-core dependency notices (superset of platform and development dependencies)')
foreach($package in $PackageMetadata.packages | Sort-Object name,version){
    [void]$Notices.AppendLine("`n--- $($package.name) $($package.version) | $($package.license) ---")
    $sourceDirectory=Split-Path -Parent $package.manifest_path
    $licenseFiles=@(Get-ChildItem -LiteralPath $sourceDirectory -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE)' })
    foreach($subdirectory in @('quickjs','sqlite3','vendor')){
        $candidate=Join-Path $sourceDirectory $subdirectory
        if(Test-Path -LiteralPath $candidate){$licenseFiles+=@(Get-ChildItem -LiteralPath $candidate -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING|NOTICE)' })}
    }
    if($package.license_file){$candidate=[IO.Path]::GetFullPath((Join-Path $sourceDirectory $package.license_file));if($candidate.StartsWith([IO.Path]::GetFullPath($sourceDirectory)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-and(Test-Path -LiteralPath $candidate)){$licenseFiles+=Get-Item -LiteralPath $candidate}}
    foreach($licenseFile in $licenseFiles | Sort-Object FullName -Unique){
        if($licenseFile.Length -le 524288 -and -not($licenseFile.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            [void]$Notices.AppendLine("[$($licenseFile.Name)]")
            [void]$Notices.AppendLine([IO.File]::ReadAllText($licenseFile.FullName))
        }
    }
}
[IO.File]::WriteAllText((Join-Path $PackageRoot 'THIRD-PARTY-NOTICES.txt'),$Notices.ToString(),[Text.UTF8Encoding]::new($false))
foreach($bundle in @($WindowsBundle,$AndroidBundle)){Copy-Item -LiteralPath (Join-Path $PackageRoot 'THIRD-PARTY-NOTICES.txt') -Destination $bundle -Force}

@'
dansheng-core 0.1.0 development release

Start the local service: dansheng-host.exe serve
Use another terminal: dansheng-host.exe call core.info
MCP stdio: dansheng-host.exe mcp (requires the running service)

Default data directory: %LOCALAPPDATA%\dansheng
MCP starts without data grants. Use the trusted UI/owner CLI to authorize it.
Campus account login and production UI are integration responsibilities.
See the bundled VALIDATION.md for this build's test boundaries.
'@ | Set-Content -LiteralPath (Join-Path $WindowsBundle 'README.txt') -Encoding utf8
@'
Android arm64-v8a Rust shared library, built with NDK API 24.
The separate Android adapter/verification host currently requires API 28+.
This package is a core library, not a complete Android application.
Use include/dansheng.h plus platform/android for the platform queue and JNI adapter.
ARM64 was cross-compiled; runtime checks use an x86_64 Android API 36 emulator.
'@ | Set-Content -LiteralPath (Join-Path $AndroidBundle 'README.txt') -Encoding utf8
$Artifacts=@($WindowsBinary,$AndroidBinary) | ForEach-Object{[ordered]@{name=(Split-Path -Leaf $_);bytes=(Get-Item -LiteralPath $_).Length;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()}}
$BuildInfo=[ordered]@{version='0.1.0';rustc=(& rustc --version);windows_features=$WindowsProof.features;android_features=$AndroidProof.features;binary_source_sha256=$BuildSource.sha256;windows_build_arguments=$WindowsProof.build_arguments;android_build_arguments=$AndroidProof.build_arguments;windows_source_date_epoch=$WindowsProof.source_date_epoch;android_source_date_epoch=$AndroidProof.source_date_epoch;native_source_prefix='/dansheng-build';zip_timestamp='1980-01-01T00:00:00Z';zip_runtime=[Environment]::Version.ToString();cargo_lock_sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $DanshengRoot 'Cargo.lock')).Hash.ToLowerInvariant();validation_document=[ordered]@{path=$PackageValidationRelative;sha256=$PackageValidationHash};artifacts=$Artifacts}
$BuildInfo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PackageRoot 'build-info.json') -Encoding utf8
$SourceFiles=@(& git -C $DanshengRoot -c core.quotePath=false ls-files --cached --others --exclude-standard | Select-Object -Unique | Where-Object {
    ($_ -in @('.gitattributes','.gitignore','AGENTS.md','CLAUDE.md','Cargo.toml','Cargo.lock','LICENSE','README.md','rust-toolchain.toml','reference/manifest.json') -or $_ -match '^(\.github|contracts|crates|docs|include|platform/android|plugins|sdk|scripts|tools/dansheng-lab|tools/workspace)/') -and
    $_ -notmatch '(^|/)(\.git|target|build|node_modules|\.gradle|\.local|dist|profiles|vault|logs)(/|$)' -and
    $_ -notmatch '(^|/)(credentials\.txt|\.env(?:\..*)?|local\.properties|key\.properties|[^/]+\.(?:jks|keystore))$'
})
if($LASTEXITCODE -ne 0){throw 'Cannot collect source inventory'}
[Array]::Sort($SourceFiles,[StringComparer]::Ordinal)
if($SourceFiles -cnotcontains $PackageValidationRelative){throw 'Validation document is not included in the source archive'}
$SourceArchiveFiles=[ordered]@{}
$SourceHashes=@(foreach($relativePath in $SourceFiles){
    $sourcePath=Join-Path $DanshengRoot $relativePath
    if(Test-Path -LiteralPath $sourcePath -PathType Leaf){
        if((Get-Item -LiteralPath $sourcePath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Source link cannot be packaged: $relativePath"}
        $SourceArchiveFiles[$relativePath]=$sourcePath
        "$((Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant())  $relativePath"
    }
})
$SourceHashes | Set-Content -LiteralPath (Join-Path $PackageRoot 'source-manifest.sha256') -Encoding utf8
[IO.File]::WriteAllText((Join-Path $PackageRoot 'binary-source-manifest.sha256'),$BuildSource.manifest,[Text.UTF8Encoding]::new($false))
foreach($bundle in @($WindowsBundle,$AndroidBundle)){
    foreach($metadataFile in @('build-info.json','source-manifest.sha256','binary-source-manifest.sha256','dependency-licenses.json')){Copy-Item -LiteralPath (Join-Path $PackageRoot $metadataFile) -Destination $bundle -Force}
    Copy-Item -LiteralPath $PackageValidation -Destination (Join-Path $bundle 'VALIDATION.md') -Force
}
$CommonBundleFiles=@('LICENSE','README.txt','THIRD-PARTY-NOTICES.txt','build-info.json','source-manifest.sha256','binary-source-manifest.sha256','dependency-licenses.json','VALIDATION.md')
foreach($entry in @(@{root=$WindowsBundle;target='windows-x64';files=@('dansheng-host.exe')},@{root=$AndroidBundle;target='android-arm64';files=@('libdansheng_ffi.so','dansheng.h')})){
    $BundleFiles=[ordered]@{}
    foreach($name in @($CommonBundleFiles)+@($entry.files)){$BundleFiles[$name]=Join-Path $entry.root $name}
    Write-DanshengDeterministicZip -Destination (Join-Path $PackageRoot "dansheng-core-0.1.0-$($entry.target).zip") -Files $BundleFiles
}
Write-DanshengDeterministicZip -Destination (Join-Path $PackageRoot 'dansheng-core-0.1.0-source.zip') -Files $SourceArchiveFiles
# Packaging must never attach today's manifest to yesterday's binary, or mix
# source files edited during archive creation. Only explicit bundle entries ship.
foreach($SourceLine in $SourceHashes){
    $SourceExpected=$SourceLine.Substring(0,64);$SourceRelative=$SourceLine.Substring(66)
    if((Get-FileHash -LiteralPath (Join-Path $DanshengRoot $SourceRelative) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SourceExpected){throw 'Source changed while packaging; discard this incomplete package run'}
}
if((Get-FileHash -LiteralPath $PackageValidation -Algorithm SHA256).Hash.ToLowerInvariant() -cne $PackageValidationHash){throw 'Validation document changed while packaging'}
$null=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $WindowsReceipt -Target windows-x64 -RuntimeRoot $PackageRuntime
$null=Assert-DanshengBuildReceipt -Root $DanshengRoot -Receipt $AndroidReceipt -Target android-arm64 -RuntimeRoot $PackageRuntime
$PackageArchives=@('dansheng-core-0.1.0-android-arm64.zip','dansheng-core-0.1.0-source.zip','dansheng-core-0.1.0-windows-x64.zip')
$PackageSums=@(foreach($name in $PackageArchives){"$((Get-FileHash -LiteralPath (Join-Path $PackageRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant())  $name"})
[IO.File]::WriteAllText((Join-Path $PackageRoot 'SHA256SUMS'),($PackageSums -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
$PackagePrevious=Join-Path $PackageBoundary ('.previous-'+[guid]::NewGuid().ToString('N'))
# Verify resolved absolute move endpoints before any directory move. No cleanup
# deletes old releases: a previous package remains available for rollback.
foreach($PackageMovePath in @($PackageRoot,$PackageDestination,$PackagePrevious)){
    $PackageResolved=Get-DanshengRuntimeOutput -RuntimeRoot $PackageRuntime -Path $PackageMovePath
    if(-not $PackageResolved.StartsWith($PackageBoundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($PackageResolved).TrimEnd('\','/') -cne $PackageBoundary.TrimEnd('\','/')){throw 'Package move escaped its output boundary'}
    if((Test-Path -LiteralPath $PackageResolved) -and ((Get-Item -LiteralPath $PackageResolved).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked package move refused'}
}
$PackageHadPrevious=Test-Path -LiteralPath $PackageDestination
if($PackageHadPrevious){Move-Item -LiteralPath $PackageDestination -Destination $PackagePrevious}
try {Move-Item -LiteralPath $PackageRoot -Destination $PackageDestination}
catch {if($PackageHadPrevious -and -not(Test-Path -LiteralPath $PackageDestination)){Move-Item -LiteralPath $PackagePrevious -Destination $PackageDestination};throw}
foreach($name in $PackageArchives){Get-Item -LiteralPath (Join-Path $PackageDestination $name) | Select-Object Name,Length}
