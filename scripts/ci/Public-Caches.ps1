#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'Common.ps1')

function Sync-CiPublicDependencies(
    [string]$SourceRoot, [string]$DestinationRoot,
    [ValidateSet('CacheToRuntime','RuntimeToCache','SeedToCache')][string]$Direction,
    [ValidateSet('Cargo','Pub')][string[]]$SeedKinds = @('Cargo','Pub')
) {
    $source = Assert-CiPlainPath $SourceRoot
    $destination = Assert-CiPlainPath $DestinationRoot
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($source.Equals($destination, $comparison) -or $source.StartsWith($destination + [IO.Path]::DirectorySeparatorChar, $comparison) -or ($Direction -ne 'SeedToCache' -and $destination.StartsWith($source + [IO.Path]::DirectorySeparatorChar, $comparison))) {
        throw 'Public cache source/destination overlap.'
    }
    # Fixed dependency-data allowlist. No home/config/profile, signing, daemon,
    # compiled Cargo target, Gradle init scripts or credentials are synchronized.
    $parts = @(
        @('cargo-home/registry/cache','cargo-home/registry/cache'), @('cargo-home/registry/index','cargo-home/registry/index'),
        @('cargo-home/git/db','cargo-home/git/db'), @('cargo-home/git/checkouts','cargo-home/git/checkouts'),
        @('pub/hosted','pub-cache/hosted'), @('pub/hosted-hashes','pub-cache/hosted-hashes'), @('pub/git','pub-cache/git'),
        @('gradle/caches','gradle-cache/caches'), @('gradle/wrapper','gradle-cache/wrapper'), @('gradle/native','gradle-cache/native')
    )
    $copied = 0
    foreach ($part in $parts) {
        if ($Direction -eq 'SeedToCache') {
            # The public seed root is the parent of lane/job caches. Enumerate
            # only these fixed, disjoint data trees; never recurse into lanes.
            $allowed = ($SeedKinds -contains 'Cargo' -and $part[0] -in @('cargo-home/registry/cache','cargo-home/registry/index')) -or
                ($SeedKinds -contains 'Pub' -and $part[0] -in @('pub/hosted','pub/hosted-hashes'))
            if (-not $allowed) { continue }
            $sourcePart = $destinationPart = $part[0]
        } else {
            $sourcePart, $destinationPart = if ($Direction -eq 'CacheToRuntime') { $part[0], $part[1] } else { $part[1], $part[0] }
        }
        $from = Assert-CiPlainPath (Join-Path $source $sourcePart)
        $toRoot = Assert-CiPlainPath (Join-Path $destination $destinationPart)
        if ($from.Equals($toRoot, $comparison) -or $from.StartsWith($toRoot + [IO.Path]::DirectorySeparatorChar, $comparison) -or $toRoot.StartsWith($from + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'Public dependency trees overlap.'
        }
        if (-not (Test-Path -LiteralPath $from -PathType Container)) { continue }
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($from)
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $relative = [IO.Path]::GetRelativePath($from, $item.FullName)
                $to = Assert-CiPlainPath (Join-Path $toRoot $relative)
                if ($item.PSIsContainer) {
                    if ($Direction -eq 'SeedToCache' -and $item.Name -in @('.git','.ssh','.dart_tool')) { continue }
                    $pending.Push($item.FullName)
                    continue
                }
                if ($item.Name -match '^(credentials(?:\..*)?|config\.toml|\.npmrc|\.gitconfig|\.git-credentials|auth\.json|service\.json|gradle\.properties|init\.gradle(?:\.kts)?|.*\.(?:lock|lck|ci-tmp))$') { continue }
                if (Test-Path -LiteralPath $to) { continue }
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $to))
                $temporary = $to + '.' + [guid]::NewGuid().ToString('N') + '.ci-tmp'
                try {
                    [IO.File]::Copy($item.FullName, $temporary, $false)
                    try { [IO.File]::Move($temporary, $to, $false); $copied++ }
                    catch [IO.IOException] {
                        # Another process may have finished the immutable dependency first.
                        if (-not (Test-Path -LiteralPath $to -PathType Leaf)) { throw }
                    }
                } finally {
                    if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) }
                }
            }
        }
    }
    Write-Host "Public dependency cache synchronization complete ($copied new files)."
}
