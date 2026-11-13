#Requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'apk-archive.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-apk-entries-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$cases=@(
    @{name='AAPT2 resource names differing by case';entries=@('res/2F.xml','res/2f.xml');rejected=$false},
    @{name='exact duplicate ZIP names';entries=@('res/2F.xml','res/2F.xml');rejected=$true},
    @{name='ordinal punctuation in ZIP names';entries=@('assets/a-b.txt','assets/ab.txt');rejected=$false}
)
foreach($case in $cases){
    $file=Join-Path $fixture (([guid]::NewGuid().ToString('N'))+'.zip')
    $stream=[IO.File]::Open($file,[IO.FileMode]::CreateNew)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
    try{foreach($name in $case.entries){$entry=$zip.CreateEntry($name);$body=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('synthetic-entry');$body.Write($bytes)}finally{$body.Dispose()}}}finally{$zip.Dispose();$stream.Dispose()}
    $before=(Get-FileHash -LiteralPath $file).Hash
    $zip=[IO.Compression.ZipFile]::OpenRead($file)
    $rejected=$false;$names=@()
    try{try{$names=@(Get-DanshengApkEntryNames -Archive $zip)}catch{if($_.Exception.Message-cne'APK contains duplicate entries.'){throw};$rejected=$true}}finally{$zip.Dispose()}
    if($rejected-ne$case.rejected-or(-not$rejected-and$names.Count-ne$case.entries.Count)){throw $case.name}
    if((Get-FileHash -LiteralPath $file).Hash-cne$before){throw 'APK inventory check changed archive bytes'}
}
[pscustomobject]@{passed=$cases.Count;cases=@($cases.name);fixture=$fixture;synthetic_archives_only=$true}|ConvertTo-Json -Depth 4
$global:LASTEXITCODE=0
