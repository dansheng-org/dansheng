#Requires -Version 7.0
# Isolated synthetic cache data only. No runner, environment dump or credentials.
$ErrorActionPreference = 'Stop'
$cacheScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Public-Caches.ps1'
. $cacheScript
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng public caches ' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Put([string]$Path, [string]$Value = 'synthetic public bytes') {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Value)
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert ($message -match $Pattern) "Expected $Pattern; got: $message"
}
function Link([string]$Path, [string]$Target) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $kind -Path $Path -Target $Target | Out-Null
}
$cache = Join-Path $fixture 'cache'
$runtime = Join-Path $fixture 'runtime'
$parts = @(
    @('cargo-home/registry/cache','cargo-home/registry/cache'), @('cargo-home/registry/index','cargo-home/registry/index'),
    @('cargo-home/git/db','cargo-home/git/db'), @('cargo-home/git/checkouts','cargo-home/git/checkouts'),
    @('pub/hosted','pub-cache/hosted'), @('pub/hosted-hashes','pub-cache/hosted-hashes'), @('pub/git','pub-cache/git'),
    @('gradle/caches','gradle-cache/caches'), @('gradle/wrapper','gradle-cache/wrapper'), @('gradle/native','gradle-cache/native')
)
foreach ($part in $parts) { Put (Join-Path $cache ($part[0] + '/nested/package.bin')) $part[0] }
$forbidden = @('credentials','CREDENTIALS.json','credentials.toml','config.toml','.npmrc','.gitconfig','.git-credentials',
    'auth.json','service.json','gradle.properties','init.gradle','INIT.GRADLE.KTS','artifact.lock','artifact.LCK','artifact.ci-tmp')
foreach ($name in $forbidden) { Put (Join-Path $cache "pub/hosted/nested/$name") 'synthetic excluded bytes' }
Put (Join-Path $cache 'cargo-home/config.toml') 'synthetic excluded bytes'
Put (Join-Path $cache 'signing/not-public.bin')
Put (Join-Path $cache 'cargo-target/not-public.bin')
Put (Join-Path $cache 'pub/hosted/nested/config.json') 'public registry metadata'
Put (Join-Path $cache 'pub/hosted/nested/.hidden-package') 'public hidden package'
Sync-CiPublicDependencies $cache $runtime -Direction cachetoruntime
foreach ($part in $parts) {
    Assert ([IO.File]::ReadAllText((Join-Path $runtime ($part[1] + '/nested/package.bin'))) -ceq $part[0]) 'Allowlist mapping lost bytes.'
}
foreach ($name in $forbidden) { Assert (-not (Test-Path -LiteralPath (Join-Path $runtime "pub-cache/hosted/nested/$name"))) "Copied excluded $name" }
Assert (Test-Path -LiteralPath (Join-Path $runtime 'pub-cache/hosted/nested/.hidden-package')) 'Hidden public data was lost.'
Assert (Test-Path -LiteralPath (Join-Path $runtime 'pub-cache/hosted/nested/config.json')) 'Public registry config.json was excluded.'
Assert (-not (Test-Path -LiteralPath (Join-Path $runtime 'cargo-home/config.toml'))) 'Copied configuration outside allowlist.'
Assert (-not (Test-Path -LiteralPath (Join-Path $runtime 'signing'))) 'Copied signing tree.'
Assert (-not (Test-Path -LiteralPath (Join-Path $runtime 'cargo-target'))) 'Copied compiled output.'
Put (Join-Path $runtime 'pub-cache/hosted/nested/package.bin') 'preserve existing runtime'
Sync-CiPublicDependencies $cache $runtime -Direction CacheToRuntime
Assert ([IO.File]::ReadAllText((Join-Path $runtime 'pub-cache/hosted/nested/package.bin')) -ceq 'preserve existing runtime') 'Overwrote existing runtime bytes.'
$reverse = Join-Path $fixture 'reverse'
Sync-CiPublicDependencies $runtime $reverse -Direction RuntimeToCache
foreach ($part in $parts) { Assert (Test-Path -LiteralPath (Join-Path $reverse ($part[0] + '/nested/package.bin'))) 'Reverse allowlist mapping failed.' }
Put (Join-Path $reverse 'pub/hosted/nested/package.bin') 'preserve existing cache'
Sync-CiPublicDependencies $runtime $reverse -Direction RuntimeToCache
Assert ([IO.File]::ReadAllText((Join-Path $reverse 'pub/hosted/nested/package.bin')) -ceq 'preserve existing cache') 'Overwrote existing cache bytes.'

# Seed import permits a lane below the root, but only four fixed public trees.
foreach ($name in @('.git','.ssh','.dart_tool')) { Put (Join-Path $cache "pub/hosted/nested/$name/private-marker") }
Put (Join-Path $cache 'main/other-job/pub/hosted/private-marker')
$seed = Join-Path $cache 'checks/new-job'
Sync-CiPublicDependencies $cache $seed -Direction SeedToCache
foreach ($part in $parts) {
    $allowed = $part[0] -in @('cargo-home/registry/cache','cargo-home/registry/index','pub/hosted','pub/hosted-hashes')
    Assert ((Test-Path -LiteralPath (Join-Path $seed ($part[0] + '/nested/package.bin'))) -eq $allowed) 'Seed allowlist widened or lost data.'
}
foreach ($name in @('.git','.ssh','.dart_tool')) { Assert (-not (Test-Path -LiteralPath (Join-Path $seed "pub/hosted/nested/$name"))) 'Seed copied a private/tool directory.' }
Assert (-not (Test-Path -LiteralPath (Join-Path $seed 'main'))) 'Seed recursed into a lane.'
$pubOnly = Join-Path $fixture 'pub-only'
Sync-CiPublicDependencies $cache $pubOnly -Direction seedtocache -SeedKinds pub
Assert ((Test-Path -LiteralPath (Join-Path $pubOnly 'pub/hosted/nested/package.bin')) -and -not (Test-Path -LiteralPath (Join-Path $pubOnly 'cargo-home'))) 'Pub-only seed widened.'
$cargoOnly = Join-Path $fixture 'cargo-only'
Sync-CiPublicDependencies $cache $cargoOnly -Direction SeedToCache -SeedKinds Cargo
Assert ((Test-Path -LiteralPath (Join-Path $cargoOnly 'cargo-home/registry/cache/nested/package.bin')) -and -not (Test-Path -LiteralPath (Join-Path $cargoOnly 'pub'))) 'Cargo-only seed widened.'
$emptySeed = Join-Path $fixture 'empty-seed'
Sync-CiPublicDependencies $cache $emptySeed -Direction SeedToCache -SeedKinds @()
Assert (-not (Test-Path -LiteralPath $emptySeed)) 'Empty seed selection copied data.'
Reject { Sync-CiPublicDependencies $cache $cache -Direction CacheToRuntime } 'overlap'
Reject { Sync-CiPublicDependencies $cache (Join-Path $cache 'child') -Direction CacheToRuntime } 'overlap'
Reject { Sync-CiPublicDependencies (Join-Path $cache 'child') $cache -Direction RuntimeToCache } 'overlap'
Reject { Sync-CiPublicDependencies $cache (Join-Path $cache 'pub/hosted/child') -Direction SeedToCache } 'trees overlap'
Reject { Sync-CiPublicDependencies '.' $runtime -Direction CacheToRuntime } 'absolute'
Reject { Sync-CiPublicDependencies ([IO.Path]::GetPathRoot($fixture)) $runtime -Direction CacheToRuntime } 'filesystem root'

$outside = Join-Path $fixture 'outside'
Put (Join-Path $outside 'untouched-marker') 'outside bytes'
Link (Join-Path $cache 'pub/hosted/linked') $outside
Sync-CiPublicDependencies $cache (Join-Path $fixture 'skip-linked-source') -Direction CacheToRuntime
Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'skip-linked-source/pub-cache/hosted/linked'))) 'Followed source directory link.'
$linkedRoot = Join-Path $fixture 'linked-root'
Link $linkedRoot $outside
Reject { Sync-CiPublicDependencies $linkedRoot $runtime -Direction CacheToRuntime } 'links'
Reject { Sync-CiPublicDependencies $cache (Join-Path $linkedRoot 'not-created') -Direction CacheToRuntime } 'links'
$linkedDestination = Join-Path $fixture 'linked-destination'
Link (Join-Path $linkedDestination 'pub-cache/hosted/nested') $outside
Reject { Sync-CiPublicDependencies $cache $linkedDestination -Direction CacheToRuntime } 'links'
Assert (-not (Test-Path -LiteralPath (Join-Path $outside 'package.bin'))) 'Destination ancestor link redirected a write.'
$linkedPart = Join-Path $fixture 'linked-part'
Link (Join-Path $linkedPart 'pub/hosted') $outside
Reject { Sync-CiPublicDependencies $linkedPart $runtime -Direction CacheToRuntime } 'links'
$excludedDestination = Join-Path $fixture 'excluded-destination'
Link (Join-Path $excludedDestination 'pub/hosted/nested/.git') $outside
Reject { Sync-CiPublicDependencies $cache $excludedDestination -Direction SeedToCache } 'links'
if (-not $IsWindows) {
    New-Item -ItemType SymbolicLink -Path (Join-Path $cache 'pub/hosted/file-link') -Target (Join-Path $outside 'untouched-marker') | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $cache 'pub/hosted/broken-link') -Target (Join-Path $outside 'absent') | Out-Null
    $fileLinkTarget = Join-Path $fixture 'file-links'
    Sync-CiPublicDependencies $cache $fileLinkTarget -Direction CacheToRuntime
    Assert (-not (Test-Path -LiteralPath (Join-Path $fileLinkTarget 'pub-cache/hosted/file-link'))) 'Followed source file link.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fileLinkTarget 'pub-cache/hosted/broken-link'))) 'Copied broken source link.'
    $fileLinkDestination = Join-Path $fixture 'destination-file-link'
    [void][IO.Directory]::CreateDirectory((Join-Path $fileLinkDestination 'pub-cache/hosted/nested'))
    New-Item -ItemType SymbolicLink -Path (Join-Path $fileLinkDestination 'pub-cache/hosted/nested/package.bin') -Target (Join-Path $outside 'untouched-marker') | Out-Null
    Reject { Sync-CiPublicDependencies $cache $fileLinkDestination -Direction CacheToRuntime } 'links'
}
Assert ([IO.File]::ReadAllText((Join-Path $outside 'untouched-marker')) -ceq 'outside bytes') 'Outside bytes changed.'

# Two independent publishers race for one immutable file. It must appear whole,
# contain exactly one producer's bytes, and leave neither writer's temporary file.
$child = Join-Path $fixture 'publish.ps1'
@'
param($CacheScript,$Source,$Destination,$Ready,$Start)
$ErrorActionPreference='Stop'
. $CacheScript
[IO.File]::WriteAllText($Ready,'ready')
$timer=[Diagnostics.Stopwatch]::StartNew()
while(-not[IO.File]::Exists($Start)) { if($timer.Elapsed.TotalSeconds-gt30){throw 'Start barrier timed out'}; Start-Sleep -Milliseconds 20 }
Sync-CiPublicDependencies $Source $Destination -Direction CacheToRuntime
'@ | Set-Content -LiteralPath $child
$publishers = [Collections.Generic.List[Diagnostics.Process]]::new()
$destination = Join-Path $fixture 'race-result'
$published = Join-Path $destination 'gradle-cache/caches/race/large.jar'
$start = Join-Path $fixture 'start'
$expectedHashes = @()
try {
    foreach ($number in 1..2) {
        $source = Join-Path $fixture "publisher-$number"
        $file = Join-Path $source 'gradle/caches/race/large.jar'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
        $bytes = [byte[]]::new(16MB)
        [Array]::Fill[byte]($bytes, [byte]$number)
        [IO.File]::WriteAllBytes($file,$bytes)
        $expectedHashes += (Get-FileHash -LiteralPath $file).Hash
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        foreach ($argument in @('-NoLogo','-NoProfile','-File',$child,$cacheScript,$source,$destination,(Join-Path $fixture "ready-$number"),$start)) { $info.ArgumentList.Add($argument) }
        $publishers.Add([Diagnostics.Process]::Start($info))
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not ([IO.File]::Exists((Join-Path $fixture 'ready-1')) -and [IO.File]::Exists((Join-Path $fixture 'ready-2')))) {
        if ($timer.Elapsed.TotalSeconds -gt 30) { throw 'Publishers did not reach barrier.' }
        Start-Sleep -Milliseconds 20
    }
    [IO.File]::WriteAllText($start,'go')
    $sawPartial = $false
    while (@($publishers | Where-Object { -not $_.HasExited }).Count) {
        if ([IO.File]::Exists($published) -and (Get-Item -LiteralPath $published).Length -ne 16MB) { $sawPartial = $true }
        if ($timer.Elapsed.TotalSeconds -gt 60) { throw 'Concurrent publishers timed out.' }
        Start-Sleep -Milliseconds 20
    }
    foreach ($process in $publishers) {
        $errorText = $process.StandardError.ReadToEnd()
        Assert ($process.ExitCode -eq 0) "Concurrent publisher failed: $errorText"
    }
    Assert (-not $sawPartial) 'Destination exposed a partially copied dependency.'
    Assert ((Get-FileHash -LiteralPath $published).Hash -in $expectedHashes) 'Concurrent publication mixed or lost producer bytes.'
    $before = (Get-FileHash -LiteralPath $published).Hash
    Sync-CiPublicDependencies (Join-Path $fixture 'publisher-1') $destination -Direction CacheToRuntime
    Assert ((Get-FileHash -LiteralPath $published).Hash -ceq $before) 'Repeat publication overwrote the winner.'
    Assert (@(Get-ChildItem -LiteralPath $destination -Filter '*.ci-tmp' -Recurse -Force).Count -eq 0) 'Publication left temporary files.'
} finally {
    foreach ($process in $publishers) { if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
}
[pscustomobject]@{passed=$checks;fixture=$fixture;synthetic_only=$true;credentials_read=$false}|ConvertTo-Json
