# APK resource names use exact ZIP names, including case-sensitive AAPT2 names.
function Get-DanshengApkEntryNames {
    param([Parameter(Mandatory)][IO.Compression.ZipArchive]$Archive)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($entry in $Archive.Entries){
        if(-not$seen.Add($entry.FullName)){throw 'APK contains duplicate entries.'}
    }
    @($Archive.Entries.FullName)
}
