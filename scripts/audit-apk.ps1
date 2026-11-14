#Requires -Version 7.0
param([Parameter(Mandatory)][string]$Apk,[Parameter(Mandatory)][ValidateSet('arm64-v8a','x86_64')][string]$Abi,
      [Parameter(Mandatory)][string]$Output,[string]$CoreRoot,[string]$ArtifactDirectory,[string]$LockFile,[switch]$Release,[switch]$SdkOnly)
$ErrorActionPreference='Stop'
$app=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
. (Join-Path $PSScriptRoot 'apk-archive.ps1')
if(-not$SdkOnly){$CoreRoot=Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot $CoreRoot}
$ArtifactDirectory=Resolve-DanshengCoreArtifactDirectory -AppRoot $app -ArtifactDirectory $ArtifactDirectory
$aar=Get-DanshengAppAarPath -AppRoot $app -ArtifactDirectory $ArtifactDirectory -LockFile $LockFile
$lockPath=Resolve-DanshengAppCoreLock -AppRoot $app -LockFile $LockFile
$lock=if(Test-Path -LiteralPath $lockPath){Get-Content -LiteralPath $lockPath -Raw|ConvertFrom-Json}else{$null}
if($SdkOnly-and-not$lock){throw 'SDK-only APK audit requires core.lock.json.'}
$resourceRoot=if($SdkOnly){Join-Path $ArtifactDirectory 'resources'}else{$CoreRoot}
$receipt=Get-Content -LiteralPath (Join-Path $ArtifactDirectory 'receipt.json') -Raw|ConvertFrom-Json
$expected=if($lock){$lock.artifact.sha256}else{$receipt.aar_sha256}
if((Get-FileHash -LiteralPath $aar).Hash-ine$expected-or(Get-FileHash -LiteralPath $aar).Hash-ine$receipt.aar_sha256){throw 'Selected AAR differs from lock or producer receipt.'}
function Read-ZipBytes([IO.Compression.ZipArchive]$Archive,[string]$Name){
    $entries=@($Archive.Entries|Where-Object FullName -CEQ $Name)
    if($entries.Count-ne1){throw "Missing or duplicate archive entry: $Name"}
    $stream=$entries[0].Open();$buffer=[IO.MemoryStream]::new()
    try{$stream.CopyTo($buffer);return ,$buffer.ToArray()}finally{$stream.Dispose();$buffer.Dispose()}
}
function Hash-Bytes([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
$archive=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Apk))
$reference=[IO.Compression.ZipFile]::OpenRead($aar)
try{
    $names=@(Get-DanshengApkEntryNames -Archive $archive)
    foreach($legal in @('assets/COPYING.txt','assets/NATIVE-NOTICES.txt')){if($legal-notin$names){throw 'Native licenses missing from APK.'}}
    $builtin='assets/builtin-venues/'
    $modules=@('main.mjs','api.mjs','policy.mjs')
    foreach($name in $names){if($name-match'(?i)credentials\.txt$|\.(jks|p12|dspack)$|fudan-sports|closed-loop'-or($name.EndsWith('.mjs')-and$name-notin@($modules|ForEach-Object {$builtin+$_}))){throw 'APK contains private, test or external automation payload.'}}
    foreach($part in @('manifest.json','host-policy.json','main.mjs','api.mjs','policy.mjs','NOTICE.md')){
        if((Hash-Bytes (Read-ZipBytes $archive ($builtin+$part)))-ine(Get-FileHash -LiteralPath (Join-Path $resourceRoot ('plugins/builtin/fudan-venues/'+$part))).Hash){throw "Official component differs from source: $part"}
    }
    $libraries=@(foreach($name in @($names|Where-Object {$_-match'^lib/.+\.so$'})){
        $bytes=Read-ZipBytes $archive $name
        if($bytes.Length-lt64-or$bytes[0]-ne127-or$bytes[1]-ne69-or$bytes[2]-ne76-or$bytes[3]-ne70-or$bytes[4]-ne2-or$bytes[5]-ne1){throw 'APK requires little-endian ELF64 libraries.'}
        $offset=[BitConverter]::ToUInt64($bytes,32);$size=[BitConverter]::ToUInt16($bytes,54);$count=[BitConverter]::ToUInt16($bytes,56)
        if($offset+$size*$count-gt$bytes.Length-or$size-lt56){throw 'Invalid ELF program-header bounds.'}
        $alignments=@(for($i=0;$i-lt$count;$i++){$position=[int]($offset+$i*$size);if([BitConverter]::ToUInt32($bytes,$position)-eq1){[BitConverter]::ToUInt64($bytes,$position+48)}})
        if($alignments.Count-eq0-or@($alignments|Where-Object {$_-lt16384}).Count){throw "Library is not 16 KiB aligned: $name"}
        $hash=Hash-Bytes $bytes
        if($name-match'libdansheng_(ffi|android)\.so$'-and$hash-ne(Hash-Bytes (Read-ZipBytes $reference ('jni/'+$name.Substring(4))))){throw "APK native entry differs from AAR: $name"}
        [pscustomobject]@{entry=$name;bytes=$bytes.Length;sha256=$hash;minimum_load_alignment=($alignments|Measure-Object -Minimum).Minimum}
    })
    $required=@('libflutter.so','libdansheng_android.so','libdansheng_ffi.so')
    if($Release){$required+='libapp.so';if(@($libraries|Where-Object {($_.entry-split'/')[1]-ne$Abi}).Count){throw 'Release APK is not ABI-specific.'}}
    foreach($name in $required){if("lib/$Abi/$name"-notin$libraries.entry){throw "Missing required ABI library: $name"}}
    foreach($entry in @($names|Where-Object {$_-match'\.dex$|kernel_blob\.bin$'})){
        $text=[Text.Encoding]::ASCII.GetString((Read-ZipBytes $archive $entry))
        if($text.Contains('fixture.closed-loop')-or$text.Contains('org/dansheng/app/checks/ProductRunner')){throw 'Instrumentation/fixture code is present in the product APK.'}
    }
    $report=[ordered]@{apk=[IO.Path]::GetFullPath($Apk);sha256=(Get-FileHash -LiteralPath $Apk).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $Apk).Length;abi=$Abi;release=[bool]$Release;aar_sha256=(Get-FileHash -LiteralPath $aar).Hash.ToLowerInvariant();libraries=$libraries;official_assets_match=$true;native_licenses_present=$true}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent ([IO.Path]::GetFullPath($Output))))
    $report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $Output -Encoding utf8
    $global:LASTEXITCODE=0
    [pscustomobject]@{apk=$report.apk;abi=$Abi;libraries=$libraries.Count;sha256=$report.sha256;output=$Output}|ConvertTo-Json
}finally{$archive.Dispose();$reference.Dispose()}
