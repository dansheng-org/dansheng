. "$PSScriptRoot/runtime-common.ps1"

function Get-DanshengNativePrefixFlags {
    param([Parameter(Mandatory)][string]$TargetDirectory)
    $ReleaseNativePath=[IO.Path]::GetFullPath($TargetDirectory).Replace('\','/')
    if($ReleaseNativePath.Contains('"')){throw 'Unsupported quote in build path'}
    # cc-rs parses this as one flag even if the path contains spaces. GCC/Clang
    # map __FILE__ in copied QuickJS sources without editing generated binaries.
    '"-ffile-prefix-map='+$ReleaseNativePath+'=/dansheng-build"'
}

function Get-DanshengBuildSource {
    param([Parameter(Mandatory)][string]$Root)
    $ReleaseNames=@(& git -C $Root -c core.quotePath=false ls-files --cached --others --exclude-standard)
    if($LASTEXITCODE -ne 0){throw 'Cannot enumerate release source inputs'}
    $ReleaseNames=@($ReleaseNames | Where-Object {
        $_ -in @('Cargo.toml','Cargo.lock','rust-toolchain.toml','include/dansheng.h') -or
        $_ -match '^crates/[^/]+/Cargo\.toml$' -or
        ($_ -match '^crates/[^/]+/src/.*\.rs$' -and $_ -notmatch '/test-harness/')
    } | Select-Object -Unique)
    [Array]::Sort($ReleaseNames,[StringComparer]::Ordinal)
    $ReleaseFiles=@(foreach($ReleaseName in $ReleaseNames){
        $ReleaseFile=Get-Item -LiteralPath (Join-Path $Root $ReleaseName)
        if($ReleaseFile.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked release source refused: $ReleaseName"}
        [ordered]@{path=$ReleaseName;sha256=(Get-FileHash -LiteralPath $ReleaseFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $ReleaseText=(($ReleaseFiles | ForEach-Object {"$($_.sha256)  $($_.path)"}) -join "`n")+"`n"
    $ReleaseDigest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ReleaseText))).ToLowerInvariant()
    [pscustomobject]@{sha256=$ReleaseDigest;files=$ReleaseFiles;manifest=$ReleaseText}
}

function Get-DanshengBinaryKind {
    param([Parameter(Mandatory)][string]$Path)
    $ReleaseStream=[IO.File]::OpenRead($Path)
    $ReleaseReader=[IO.BinaryReader]::new($ReleaseStream)
    try {
        if($ReleaseStream.Length -lt 64){throw 'Invalid release binary'}
        $ReleaseMagic=$ReleaseReader.ReadUInt32()
        if($ReleaseMagic -eq 0x464c457f){
            $ReleaseClass=$ReleaseReader.ReadByte();$ReleaseOrder=$ReleaseReader.ReadByte()
            $ReleaseStream.Position=18;$ReleaseMachine=$ReleaseReader.ReadUInt16()
            if($ReleaseClass -ne 2 -or $ReleaseOrder -ne 1 -or $ReleaseMachine -ne 183){throw 'Expected ELF64 little-endian AArch64 library'}
            return 'android-arm64'
        }
        if(($ReleaseMagic -band 0xffff) -eq 0x5a4d){
            $ReleaseStream.Position=0x3c;$ReleaseOffset=$ReleaseReader.ReadUInt32()
            if($ReleaseOffset+12 -gt $ReleaseStream.Length){throw 'Invalid PE header'}
            $ReleaseStream.Position=$ReleaseOffset
            if($ReleaseReader.ReadUInt32() -ne 0x4550 -or $ReleaseReader.ReadUInt16() -ne 0x8664){throw 'Expected PE x64 executable'}
            $ReleaseStream.Position=$ReleaseOffset+8
            if($ReleaseReader.ReadUInt32() -ne 0){throw 'Windows release has a variable PE timestamp; use scripts/build-windows-release.ps1'}
            return 'windows-x64'
        }
        throw 'Unrecognized release binary'
    } finally {$ReleaseReader.Dispose();$ReleaseStream.Dispose()}
}

function Write-DanshengBuildReceipt {
    param([string]$Root,[object]$Before,[string]$Binary,[string]$Target,[string[]]$Features,[string]$Receipt,[string[]]$BuildArguments,[string]$LinkerVersion,[string]$RuntimeRoot)
    $ReleaseRuntime=Resolve-DanshengRuntimeRoot -Root $Root -RuntimeRoot $RuntimeRoot
    $Binary=Get-DanshengRuntimeOutput -RuntimeRoot $ReleaseRuntime -Path $Binary
    $Receipt=Get-DanshengRuntimeOutput -RuntimeRoot $ReleaseRuntime -Path $Receipt
    $ReleaseAfter=Get-DanshengBuildSource -Root $Root
    if($Before.sha256 -cne $ReleaseAfter.sha256){throw 'Release source changed during the build; no receipt written'}
    if((Get-DanshengBinaryKind -Path $Binary) -cne $Target){throw 'Release binary architecture mismatch'}
    $ReleaseTargetPath=Split-Path -Parent (Split-Path -Parent $Binary)
    $ReleaseNativeFlags=$env:CFLAGS_x86_64_pc_windows_gnu
    if($Target -ceq 'android-arm64'){$ReleaseTargetPath=Split-Path -Parent $ReleaseTargetPath;$ReleaseNativeFlags=$env:CFLAGS_aarch64_linux_android}
    $ReleaseNativePrefix=if($ReleaseNativeFlags -ceq (Get-DanshengNativePrefixFlags -TargetDirectory $ReleaseTargetPath) -and $env:CC_SHELL_ESCAPED_FLAGS -ceq '1'){'/dansheng-build'}else{$null}
    $ReleaseReceipt=[ordered]@{
        format='dansheng-build-v1';target=$Target;source_sha256=$Before.sha256
        source_files=$Before.files;artifact_path=[IO.Path]::GetFullPath($Binary)
        artifact_sha256=(Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
        artifact_bytes=(Get-Item -LiteralPath $Binary).Length;features=$Features
        rustc=(& rustc --version);source_date_epoch=$env:SOURCE_DATE_EPOCH;build_arguments=$BuildArguments
        native_source_prefix=$ReleaseNativePrefix
        linker=$LinkerVersion
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Receipt) | Out-Null
    [IO.File]::WriteAllText($Receipt,($ReleaseReceipt | ConvertTo-Json -Depth 8)+"`n",[Text.UTF8Encoding]::new($false))
    $ReleaseReceipt
}

function Assert-DanshengBuildReceipt {
    param([string]$Root,[string]$Receipt,[string]$Target,[string]$RuntimeRoot)
    $ReleaseRuntime=Resolve-DanshengRuntimeRoot -Root $Root -RuntimeRoot $RuntimeRoot
    $Receipt=Get-DanshengRuntimeOutput -RuntimeRoot $ReleaseRuntime -Path $Receipt
    $ReleaseProof=Get-Content -Raw -LiteralPath $Receipt | ConvertFrom-Json
    $ReleaseCurrent=Get-DanshengBuildSource -Root $Root
    if($ReleaseProof.format -cne 'dansheng-build-v1' -or $ReleaseProof.target -cne $Target -or $ReleaseProof.source_sha256 -cne $ReleaseCurrent.sha256){throw "Build receipt does not match current source or target: $Target"}
    if($ReleaseProof.rustc -notmatch '^rustc 1\.99\.1 '){throw 'Release receipt does not use the pinned Rust toolchain'}
    if($ReleaseProof.source_date_epoch -cne '0' -or $ReleaseProof.native_source_prefix -cne '/dansheng-build'){throw 'Release receipt lacks deterministic native compiler settings'}
    $ReleaseArtifact=Get-DanshengRuntimeOutput -RuntimeRoot $ReleaseRuntime -Path $ReleaseProof.artifact_path
    if((Get-DanshengBinaryKind $ReleaseArtifact) -cne $Target -or (Get-FileHash -LiteralPath $ReleaseArtifact -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ReleaseProof.artifact_sha256){throw "Artifact does not match its build receipt: $Target"}
    $ReleaseProof
}

function Write-DanshengDeterministicZip {
    param([Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][System.Collections.IDictionary]$Files)
    $ReleaseZipFile=[IO.File]::Open($Destination,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $ReleaseZip=[IO.Compression.ZipArchive]::new($ReleaseZipFile,[IO.Compression.ZipArchiveMode]::Create,$false,[Text.Encoding]::UTF8)
    try {
        $ReleaseEntries=[string[]]@($Files.Keys);[Array]::Sort($ReleaseEntries,[StringComparer]::Ordinal)
        foreach($ReleaseEntryName in $ReleaseEntries){
            if($ReleaseEntryName.StartsWith('/') -or $ReleaseEntryName.Contains('\') -or $ReleaseEntryName.Split('/') -contains '..'){throw 'Unsafe ZIP entry'}
            $ReleaseEntry=$ReleaseZip.CreateEntry($ReleaseEntryName,[IO.Compression.CompressionLevel]::Optimal)
            $ReleaseEntry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
            $ReleaseEntry.ExternalAttributes=0
            $ReleaseInput=[IO.File]::OpenRead($Files[$ReleaseEntryName]);$ReleaseOutput=$ReleaseEntry.Open()
            try {$ReleaseInput.CopyTo($ReleaseOutput)} finally {$ReleaseInput.Dispose();$ReleaseOutput.Dispose()}
        }
    } finally {$ReleaseZip.Dispose();$ReleaseZipFile.Dispose()}
}
