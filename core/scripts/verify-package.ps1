param([string]$Directory,[string]$RuntimeRoot)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/runtime-common.ps1"
if(-not $Directory){
    $PackageRuntime=Resolve-DanshengRuntimeRoot -Root (Split-Path -Parent $PSScriptRoot) -RuntimeRoot $RuntimeRoot
    $Directory=Join-Path $PackageRuntime 'dist/dansheng-core-0.1.0'
}
$Directory=Get-DanshengCheckedPath $Directory
if($RuntimeRoot -or $env:DANSHENG_TASK_RUNTIME){
    $PackageRuntime=Resolve-DanshengRuntimeRoot -Root (Split-Path -Parent $PSScriptRoot) -RuntimeRoot $RuntimeRoot
    $Directory=Get-DanshengRuntimeOutput -RuntimeRoot $PackageRuntime -Path $Directory
}
$PackageProof=Get-Content -Raw -LiteralPath (Join-Path $Directory 'build-info.json') | ConvertFrom-Json
$PackageChecks=[Collections.Generic.List[object]]::new()
function Get-EntryHash([IO.Compression.ZipArchiveEntry]$Entry){
    $PackageStream=$Entry.Open()
    try {[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($PackageStream)).ToLowerInvariant()}
    finally {$PackageStream.Dispose()}
}
function Get-EntryText([IO.Compression.ZipArchiveEntry]$Entry){
    $PackageReader=[IO.StreamReader]::new($Entry.Open(),[Text.Encoding]::UTF8)
    try {$PackageReader.ReadToEnd()} finally {$PackageReader.Dispose()}
}
$PackageExpected=@('dansheng-core-0.1.0-android-arm64.zip','dansheng-core-0.1.0-source.zip','dansheng-core-0.1.0-windows-x64.zip')
$PackageSums=@(Get-Content -LiteralPath (Join-Path $Directory 'SHA256SUMS'))
if($PackageSums.Count -ne 3){throw 'Unexpected release checksum inventory'}
foreach($PackageSum in $PackageSums){
    if($PackageSum -notmatch '^([a-f0-9]{64})  (dansheng-core-0\.1\.0-(android-arm64|source|windows-x64)\.zip)$'){throw 'Invalid release checksum entry'}
    $PackageHash=$Matches[1];$PackageName=$Matches[2]
    if($PackageExpected -notcontains $PackageName){throw 'Duplicate or unknown release archive'}
    $PackageExpected=@($PackageExpected | Where-Object {$_ -cne $PackageName})
    $PackagePath=Join-Path $Directory $PackageName
    if((Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $PackageHash){throw 'Release archive checksum mismatch'}
    $PackageArchive=[IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $PackageEntries=[Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        foreach($PackageEntry in $PackageArchive.Entries){
            if($PackageEntry.FullName.StartsWith('/') -or $PackageEntry.FullName.Contains('\') -or $PackageEntry.FullName.Split('/') -contains '..'){throw 'Unsafe release archive path'}
            if($PackageEntry.LastWriteTime.Year -ne 1980 -or $PackageEntry.LastWriteTime.Month -ne 1 -or $PackageEntry.LastWriteTime.Day -ne 1 -or $PackageEntry.LastWriteTime.TimeOfDay -ne [TimeSpan]::Zero){throw 'Archive timestamp is not fixed'}
            $PackageEntries.Add($PackageEntry.FullName,$PackageEntry)
        }
        if($PackageName.EndsWith('-source.zip')){
            $PackageSourceHashes=Get-Content -LiteralPath (Join-Path $Directory 'source-manifest.sha256')
            if($PackageSourceHashes.Count -ne $PackageEntries.Count){throw 'Source archive differs from its source inventory'}
            foreach($PackageSourceLine in $PackageSourceHashes){
                if($PackageSourceLine -notmatch '^([a-f0-9]{64})  (.+)$'){throw 'Invalid source hash entry'}
                $PackageSourceHash=$Matches[1];$PackageSourceName=$Matches[2]
                if(-not $PackageEntries.ContainsKey($PackageSourceName) -or (Get-EntryHash $PackageEntries[$PackageSourceName]) -cne $PackageSourceHash){throw 'Source archive content hash mismatch'}
                if($PackageSourceName -match '(^|/)(\.git|\.local|target|build|node_modules|\.gradle|vault|profiles|logs|dist)(/|$)' -or $PackageSourceName -match '(^|/)(credentials\.txt|\.env(?:\..*)?|local\.properties|key\.properties|[^/]+\.(?:jks|keystore))$'){throw 'Generated or private files found in source archive'}
            }
            if($PackageProof.validation_document){
                $PackageValidationName=$PackageProof.validation_document.path
                $PackageValidationHash=$PackageProof.validation_document.sha256
                if($PackageValidationName -isnot [string] -or $PackageValidationHash -notmatch '^[a-f0-9]{64}$' -or -not $PackageEntries.ContainsKey($PackageValidationName)){throw 'Declared validation document is missing from the source archive'}
                if((Get-EntryHash $PackageEntries[$PackageValidationName]) -cne $PackageValidationHash){throw 'Source validation document differs from its build metadata'}
            }
        } else {
            $PackageBinaryName=if($PackageName.EndsWith('-windows-x64.zip')){'dansheng-host.exe'}else{'libdansheng_ffi.so'}
            $PackageExpectedEntries=@('LICENSE','README.txt','THIRD-PARTY-NOTICES.txt','build-info.json','source-manifest.sha256','binary-source-manifest.sha256','dependency-licenses.json','VALIDATION.md',$PackageBinaryName)
            if($PackageBinaryName -eq 'libdansheng_ffi.so'){$PackageExpectedEntries+=@('dansheng.h')}
            if($PackageEntries.Count -ne $PackageExpectedEntries.Count -or @($PackageExpectedEntries | Where-Object {-not $PackageEntries.ContainsKey($_)}).Count){throw 'Binary bundle has unexpected files or lacks required files'}
            $PackageArtifact=@($PackageProof.artifacts | Where-Object {$_.name -ceq $PackageBinaryName})
            if($PackageArtifact.Count -ne 1 -or (Get-EntryHash $PackageEntries[$PackageBinaryName]) -cne $PackageArtifact[0].sha256 -or $PackageEntries[$PackageBinaryName].Length -ne $PackageArtifact[0].bytes){throw 'Packaged binary differs from its build receipt'}
            foreach($PackageMetadataName in @('build-info.json','source-manifest.sha256','binary-source-manifest.sha256','dependency-licenses.json')){
                if((Get-EntryHash $PackageEntries[$PackageMetadataName]) -cne (Get-FileHash -LiteralPath (Join-Path $Directory $PackageMetadataName) -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Bundled metadata mismatch'}
            }
            if($PackageProof.validation_document -and (Get-EntryHash $PackageEntries['VALIDATION.md']) -cne $PackageProof.validation_document.sha256){throw 'Bundled validation document differs from its build metadata'}
            if((Get-EntryText $PackageEntries['LICENSE']).Length -lt 100 -or (Get-EntryText $PackageEntries['THIRD-PARTY-NOTICES.txt']).Length -lt 100){throw 'Missing license text'}
        }
        $PackageChecks.Add([ordered]@{archive=$PackageName;entries=$PackageEntries.Count;sha256=$PackageHash;verified=$true})
    } finally {$PackageArchive.Dispose()}
}
[ordered]@{verified=$true;binary_source_sha256=$PackageProof.binary_source_sha256;archives=@($PackageChecks.ToArray())}|ConvertTo-Json -Depth 5
