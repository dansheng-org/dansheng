#requires -Version 7.0
<#
Read-only host probes; optional source-only snapshot and disposable WSLC probe.
Host probes and source-only snapshot. Native execution is opt-in and uses only
a new or identity-verified retained owned distro. First-import automatic default is allowed by the parent
agent's scope adjustment after confirming there were no existing distros.
Never enables Windows features, elevates, or changes existing user distros/settings.
#>
[CmdletBinding()]
param(
    [switch]$PrepareSnapshot,
    [switch]$ProbeTemporarySession,
    [switch]$ExecuteNative,
    [switch]$ClippyOnly,
    [switch]$M5TargetsOnly,
    [switch]$HostFollowupOnly,
    [switch]$CoreHostFfiOnly,
    [switch]$KeepDistribution = $true,
    [string]$SnapshotDirectory,
    [string]$CachedRootfs,
    [string]$EnvironmentDirectory,
    [string]$CleanupEnvironment,
    [string]$RuntimeRoot
)
$ErrorActionPreference = 'Stop'
if (@($ClippyOnly, $M5TargetsOnly, $HostFollowupOnly, $CoreHostFfiOnly | Where-Object { $_ }).Count -gt 1) { throw 'Choose only one focused validation mode' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. "$PSScriptRoot/runtime-common.ps1"
$validationRuntime = Resolve-DanshengRuntimeRoot -Root $repo -RuntimeRoot $RuntimeRoot
$outputRoot = Get-DanshengRuntimeOutput -RuntimeRoot $validationRuntime -Path (Join-Path $validationRuntime 'linux-validation')

function Assert-SafePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne $outputRoot -and -not $full.StartsWith($outputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output escapes selected runtime/linux-validation: $full"
    }
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -Force -LiteralPath $part).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a reparse-point path: $part"
        }
    }
    return $full
}
function Write-Artifact([string]$Path, [string]$Content) {
    $full = Assert-SafePath $Path
    [IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function Invoke-Captured([string]$Exe, [string[]]$Arguments, [string]$Encoding = 'utf-8', [string]$InputText = '', [int]$TimeoutSeconds = 30) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.WorkingDirectory = $repo
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = [Text.Encoding]::GetEncoding($Encoding)
    $info.StandardErrorEncoding = [Text.Encoding]::GetEncoding($Encoding)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    # WSL management messages are UTF-16 on this host, while actual Linux
    # stdout is UTF-8. Preserve bytes until the command has completed.
    $outBuffer = [IO.MemoryStream]::new()
    $errBuffer = [IO.MemoryStream]::new()
    $stdout = $process.StandardOutput.BaseStream.CopyToAsync($outBuffer)
    $stderr = $process.StandardError.BaseStream.CopyToAsync($errBuffer)
    if ($InputText) { $process.StandardInput.WriteLine($InputText) }
    $process.StandardInput.Close()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    while (-not $process.WaitForExit(1000)) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            # Only the exact process started above, never WSL services/user instances.
            $process.Kill()
            $timedOut = $true
            break
        }
        if ([int]$timer.Elapsed.TotalSeconds % 20 -eq 0) { Write-Host "Waiting: $Exe ($([int]$timer.Elapsed.TotalSeconds)s)" }
    }
    $process.WaitForExit()
    $stdout.GetAwaiter().GetResult()
    $stderr.GetAwaiter().GetResult()
    $outBytes = $outBuffer.ToArray()
    $errBytes = $errBuffer.ToArray()
    $outDecoder = if ($Encoding -eq 'utf-16' -and $outBytes.Contains([byte]0)) { [Text.Encoding]::Unicode } else { [Text.Encoding]::UTF8 }
    $errDecoder = if ($Encoding -eq 'utf-16' -and $errBytes.Contains([byte]0)) { [Text.Encoding]::Unicode } else { [Text.Encoding]::UTF8 }
    $result = [ordered]@{ executable = $Exe; arguments = $Arguments; exit_code = $process.ExitCode; timed_out = $timedOut; stdout = $outDecoder.GetString($outBytes).TrimStart([char]0xFEFF); stderr = $errDecoder.GetString($errBytes).TrimStart([char]0xFEFF) }
    $outBuffer.Dispose()
    $errBuffer.Dispose()
    $process.Dispose()
    return $result
}
function Read-Registrations {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $default = $null
    $instances = @()
    if (Test-Path $key) {
        $default = (Get-ItemProperty $key).DefaultDistribution
        $instances = @(Get-ChildItem $key | ForEach-Object {
            $item = Get-ItemProperty $_.PSPath
            [ordered]@{ id = $_.PSChildName; name = $item.DistributionName; version = $item.Version; base_path = $item.BasePath }
        })
    }
    return [ordered]@{ default_distribution = $default; distributions = $instances }
}
function Source-Inventory {
    $listed = Invoke-Captured 'git' @('ls-files', '--cached', '--others', '--exclude-standard', '-z')
    if ($listed.exit_code -ne 0) { throw 'Cannot collect Git source inventory' }
    $selected = @($listed.stdout.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Where-Object {
        $p = $_
        $p -notmatch '(^|/)(\.git|\.local|target|dist|reference|node_modules|profiles?|logs?|vault|credentials?|test-harness)(/|$)' -and (
            $p -match '^(Cargo\.(toml|lock)|rust-toolchain\.toml|LICENSE|README\.md)$' -or
            $p -match '^(crates/(dansheng-core|dansheng-connectors|dansheng-host|dansheng-ffi)|tools/dansheng-lab)/(Cargo\.toml|LICENSE|NOTICE\.md|README\.md)$' -or
            $p -match '^crates/dansheng-connectors/src/login-NOTICE\.md$' -or
            $p -match '^(crates/(dansheng-core|dansheng-connectors|dansheng-host|dansheng-ffi)|tools/dansheng-lab)/(src|tests)/.*\.(rs|c)$' -or
            $p -match '^crates/dansheng-connectors/(tests/fixtures|fixtures)/.+\.(json|html|xml|txt|md)$' -or
            $p -match '^include/[^/]+\.h$' -or
            $p -match '^plugins/(examples|fudan-sports|fixtures/closed-loop)/.*(\.(mjs|js|json|ts|rs|md)|/LICENSE)$' -or
            $p -match '^tools/dansheng-lab/static/[^/]+\.(html|js|css)$'
        )
    })
    [Array]::Sort($selected, [StringComparer]::Ordinal)
    return $selected
}

function Verify-ProductionSnapshot([string]$Directory) {
    $directory = Assert-SafePath $Directory
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $directory 'snapshot.json') | ConvertFrom-Json
    $recorded = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in Get-Content -LiteralPath (Join-Path $directory 'source-manifest.sha256')) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid source manifest entry' }
        $recorded.Add($Matches[2], $Matches[1])
    }
    $current = @(Source-Inventory)
    $changed = @()
    $added = @()
    $removed = @($recorded.Keys | Where-Object { $_ -cnotin $current })
    $lines = foreach ($relative in $current) {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repo $relative)).Hash.ToLowerInvariant()
        if (-not $recorded.ContainsKey($relative)) { $added += $relative }
        elseif ($recorded[$relative] -cne $hash) { $changed += $relative }
        "$hash  $relative"
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n") + "`n")
    $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $proof = [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o'); files = $current.Count
        snapshot_manifest_sha256 = $metadata.manifest_sha256; current_manifest_sha256 = $currentHash
        changed = $changed; added = $added; removed = $removed
        unchanged = $currentHash -ceq $metadata.manifest_sha256 -and $changed.Count -eq 0 -and $added.Count -eq 0 -and $removed.Count -eq 0
    }
    Write-Artifact (Join-Path $directory 'production-source-proof.json') ($proof | ConvertTo-Json -Depth 6)
    if (-not $proof.unchanged) { throw 'Production source drift detected; this run is not accepted' }
}

function Remove-OwnedDistro([string]$Directory) {
    $directory = Assert-SafePath $Directory
    $owner = Get-Content -Raw -LiteralPath (Join-Path $directory 'ownership.json') | ConvertFrom-Json
    $installPath = Assert-SafePath $owner.install_path
    if ($owner.name -notmatch '^dansheng-validation-[a-f0-9]{8}$' -or -not $owner.registration_id) { throw 'Missing exact owned registration identity' }
    $state = Read-Registrations
    Write-Artifact (Join-Path $directory 'pre-cleanup.json') ($state | ConvertTo-Json -Depth 8)
    $owned = @($state.distributions | Where-Object { $_.id -eq $owner.registration_id -and $_.name -eq $owner.name })
    if ($owned.Count -ne 1 -or [IO.Path]::GetFullPath($owned[0].base_path) -ne $installPath) { throw 'Refusing cleanup: name/ID/base path do not match the owned instance' }
    $others = @($state.distributions | Where-Object id -ne $owner.registration_id)
    if ($others.Count -gt 0 -and $state.default_distribution -eq $owner.registration_id) {
        Write-Artifact (Join-Path $directory 'cleanup-deferred.json') '{"reason":"New user distro exists; do not let unregister automatically choose its default."}'
        throw 'Cleanup deferred because new user distributions appeared while the owned distro is default'
    }
    # wsl unregister deletes ONLY this verified name's VHD; never use a wildcard,
    # global shutdown, a path-based recursive delete, or set-default.
    $result = Invoke-Captured 'wsl.exe' @('--unregister', $owner.name) 'utf-16' '' 180
    Write-Artifact (Join-Path $directory 'unregister.json') ($result | ConvertTo-Json -Depth 6)
    $afterCleanup = Read-Registrations
    $remainingOthers = @($afterCleanup.distributions | Where-Object id -ne $owner.registration_id)
    $proof = [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o'); name = $owner.name; registration_id = $owner.registration_id; install_path = $installPath
        unregister_exit = $result.exit_code; registrations = $afterCleanup
        owned_registration_absent = @($afterCleanup.distributions | Where-Object id -eq $owner.registration_id).Count -eq 0
        owned_vhd_absent = -not (Test-Path -LiteralPath (Join-Path $installPath 'ext4.vhdx'))
        other_registrations_unchanged = ($others | ConvertTo-Json -Depth 6 -Compress) -ceq ($remainingOthers | ConvertTo-Json -Depth 6 -Compress)
        unconfigured_state_restored = $afterCleanup.distributions.Count -eq 0 -and -not $afterCleanup.default_distribution
    }
    Write-Artifact (Join-Path $directory 'cleanup-proof.json') ($proof | ConvertTo-Json -Depth 8)
    if ($result.exit_code -ne 0 -or -not $proof.owned_registration_absent -or -not $proof.other_registrations_unchanged) { throw 'Owned cleanup verification failed; inspect cleanup-proof.json' }
    Write-Host "Unregistered owned distro: $($owner.name). Proof: $directory/cleanup-proof.json"
}

function Invoke-NativeVerification([string]$Directory) {
    $directory = Assert-SafePath $Directory
    $name = 'dansheng-validation-' + (Split-Path $directory -Leaf).Split('-')[-1]
    $installPath = Assert-SafePath (Join-Path $directory 'distro')
    $baseline = Read-Registrations
    if ($baseline.distributions.Count -ne 0 -or $baseline.default_distribution) {
        throw 'New user distribution detected: this first-import flow requires re-evaluation and will not touch it'
    }
    if (Test-Path -LiteralPath $installPath) { throw 'Import requires a fresh owned install directory' }
    $owner = [ordered]@{ name = $name; install_path = $installPath; baseline = $baseline; first_automatic_default_authorized = $true; registration_id = $null }
    Write-Artifact (Join-Path $directory 'ownership.json') ($owner | ConvertTo-Json -Depth 8)
    $downloads = Assert-SafePath (Join-Path $directory 'downloads')
    New-Item -ItemType Directory -Path $downloads | Out-Null
    $url = 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/'
    $image = 'ubuntu-base-24.04.5-base-amd64.tar.gz'
    if ($CachedRootfs) {
        $cache = Assert-SafePath $CachedRootfs
        if ((Split-Path $cache -Leaf) -ne $image) { throw 'Cache must be the recorded official Ubuntu rootfs filename' }
        $sums = Assert-SafePath (Join-Path (Split-Path $cache -Parent) 'SHA256SUMS')
        Copy-Item -LiteralPath $cache -Destination (Join-Path $downloads $image)
        Copy-Item -LiteralPath $sums -Destination (Join-Path $downloads 'SHA256SUMS')
        Write-Artifact (Join-Path $directory 'rootfs-cache.json') ([ordered]@{ cache_path = $cache; original_source = $url + $image; verification = 'Rechecked against retained official SHA256SUMS before import' } | ConvertTo-Json)
    }
    else {
        foreach ($file in @('SHA256SUMS', $image)) {
            Write-Host "Downloading official Ubuntu artifact: $file"
            $download = Invoke-Captured 'curl.exe' @('--fail', '--location', '--proto', '=https', '--connect-timeout', '20', '--max-time', '600', '--retry', '2', '--output', (Join-Path $downloads $file), ($url + $file)) 'utf-8' '' 650
            Write-Artifact (Join-Path $directory ($file + '.download.json')) ($download | ConvertTo-Json -Depth 5)
            if ($download.exit_code -ne 0) { throw "Official download failed: $file" }
        }
    }
    $checksumLine = @(Get-Content -LiteralPath (Join-Path $downloads 'SHA256SUMS') | Where-Object { $_ -match '\*?ubuntu-base-24\.04\.5-base-amd64\.tar\.gz$' })
    if ($checksumLine.Count -ne 1) { throw 'Missing or ambiguous official image checksum' }
    $expected = ($checksumLine[0] -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $downloads $image)).Hash.ToLowerInvariant()
    Write-Artifact (Join-Path $directory 'rootfs-verification.json') ([ordered]@{ source = $url + $image; checksums_source = $url + 'SHA256SUMS'; expected_sha256 = $expected; actual_sha256 = $actual; verified = $expected -ceq $actual } | ConvertTo-Json)
    if ($expected -cne $actual) { throw 'Official rootfs checksum mismatch' }
    $immediate = Read-Registrations
    Write-Artifact (Join-Path $directory 'pre-import.json') ($immediate | ConvertTo-Json -Depth 8)
    if ($immediate.distributions.Count -ne 0 -or $immediate.default_distribution) { throw 'New user distro appeared during download; import cancelled' }
    $import = Invoke-Captured 'wsl.exe' @('--import', $name, $installPath, (Join-Path $downloads $image), '--version', '2') 'utf-16' '' 180
    Write-Artifact (Join-Path $directory 'import.json') ($import | ConvertTo-Json -Depth 6)
    $imported = Read-Registrations
    Write-Artifact (Join-Path $directory 'post-import.json') ($imported | ConvertTo-Json -Depth 8)
    $owned = @($imported.distributions | Where-Object name -eq $name)
    if ($owned.Count -eq 1 -and [IO.Path]::GetFullPath($owned[0].base_path) -eq $installPath) {
        $owner.registration_id = $owned[0].id
        Write-Artifact (Join-Path $directory 'ownership.json') ($owner | ConvertTo-Json -Depth 8)
    }
    if ($import.exit_code -ne 0 -or -not $owner.registration_id) {
        if ($owner.registration_id) { Remove-OwnedDistro $directory }
        throw 'WSL import failed: inspect import.json; no Windows feature or privilege changes attempted'
    }
    try {
        $nativePath = '/mnt/' + $directory.Substring(0, 1).ToLowerInvariant() + $directory.Substring(2).Replace('\', '/')
        Write-Host "Running native Linux validation in $name"
        $validationMode = if ($CoreHostFfiOnly) { 'core-host-ffi' } elseif ($HostFollowupOnly) { 'host-followup' } elseif ($M5TargetsOnly) { 'm5-targets' } elseif ($ClippyOnly) { 'clippy' } else { 'full' }
        & wsl.exe --distribution $name --user root --exec /usr/bin/env -u BASH_ENV -u ENV DANSHENG_DISPOSABLE_LINUX=1 "DANSHENG_VALIDATION_MODE=$validationMode" /bin/bash --noprofile --norc "$nativePath/bootstrap-linux.sh" 2>&1 |
            Tee-Object -FilePath (Join-Path $directory 'native-console.log') | Out-Host
        $nativeExit = $LASTEXITCODE
        Write-Artifact (Join-Path $directory 'native-process-result.json') ([ordered]@{ exit_code = $nativeExit; utc = [DateTime]::UtcNow.ToString('o'); native_validation_attempted = $true; validation_mode = $validationMode; note = 'Inspect stage logs: a source compile/test failure is not an environment blocker.' } | ConvertTo-Json)
        $guest = '/opt/dansheng-validation-' + $name.Split('-')[-1]
        $export = Invoke-Captured 'wsl.exe' @('--distribution', $name, '--user', 'root', '--exec', '/bin/tar', '-cf', "$nativePath/linux-results.tar", '-C', $guest, 'results') 'utf-8' '' 60
        Write-Artifact (Join-Path $directory 'results-export.json') ($export | ConvertTo-Json -Depth 5)
        if ($export.exit_code -eq 0) {
            $extract = Assert-SafePath (Join-Path $directory 'linux-results')
            New-Item -ItemType Directory -Path $extract | Out-Null
            & tar.exe -xf (Join-Path $directory 'linux-results.tar') -C $extract
            if ($LASTEXITCODE -ne 0) { throw 'Result archive extraction failed' }
        }
        if ($nativeExit -ne 0) { throw 'Native validation returned failure; inspect source/test/toolchain stage evidence' }
    }
    finally {
        if ($KeepDistribution) { Write-Host "Owned distro retained by -KeepDistribution. Cleanup: ./scripts/verify-linux.ps1 -CleanupEnvironment '$directory'" }
        else { Remove-OwnedDistro $directory }
    }
}

function Invoke-ReusedNativeVerification([string]$Directory, [string]$Environment) {
    $directory = Assert-SafePath $Directory
    $environment = Assert-SafePath $Environment
    $owner = Get-Content -Raw -LiteralPath (Join-Path $environment 'ownership.json') | ConvertFrom-Json
    $installPath = Assert-SafePath $owner.install_path
    if ($owner.name -notmatch '^dansheng-validation-[a-f0-9]{8}$' -or -not $owner.registration_id) { throw 'Invalid owned environment identity' }
    $state = Read-Registrations
    $owned = @($state.distributions | Where-Object { $_.id -eq $owner.registration_id -and $_.name -eq $owner.name })
    if ($owned.Count -ne 1 -or [IO.Path]::GetFullPath($owned[0].base_path) -ne $installPath) { throw 'Retained environment name/ID/base path do not match; no user distro will be used' }
    if (Test-Path -LiteralPath (Join-Path $directory 'native-process-result.json')) { throw 'Snapshot already executed; capture a fresh snapshot for an independent run' }
    $suffix = (Split-Path $directory -Leaf).Split('-')[-1]
    if ($suffix -notmatch '^[a-f0-9]{8}$') { throw 'Invalid snapshot suffix' }
    $guest = '/opt/dansheng-validation-' + $suffix
    $toolchain = '/opt/' + $owner.name
    $nativePath = '/mnt/' + $directory.Substring(0, 1).ToLowerInvariant() + $directory.Substring(2).Replace('\', '/')
    Write-Artifact (Join-Path $directory 'reused-environment.json') ([ordered]@{ environment_directory = $environment; name = $owner.name; registration_id = $owner.registration_id; install_path = $installPath; guest_work = $guest; toolchain = $toolchain; retained = $true; registrations_before = $state } | ConvertTo-Json -Depth 8)
    # Pass all paths as positional arguments; shell text is fixed. This only
    # creates a fresh work directory inside our verified retained distro.
    $validationMode = if ($CoreHostFfiOnly) { 'core-host-ffi' } elseif ($HostFollowupOnly) { 'host-followup' } elseif ($M5TargetsOnly) { 'm5-targets' } elseif ($ClippyOnly) { 'clippy' } else { 'full' }
    $launch = 'set -eu; base=$1; cache=$2; runner=$3; mode=$4; test -f "$cache/ownership-marker"; test ! -e "$base"; mkdir -m 700 "$base"; printf "dansheng-linux-validation\n" > "$base/ownership-marker"; exec env -u BASH_ENV -u ENV DANSHENG_TOOLCHAIN_BASE="$cache" DANSHENG_VALIDATION_MODE="$mode" bash --noprofile --norc "$runner" "$base"'
    $arguments = @('--distribution', $owner.name, '--user', 'root', '--exec', '/usr/bin/env', '-u', 'BASH_ENV', '-u', 'ENV', '/bin/bash', '--noprofile', '--norc', '-c', $launch, 'dansheng-reuse', $guest, $toolchain, "$nativePath/native-verify.sh", $validationMode)
    & wsl.exe @arguments 2>&1 | Tee-Object -FilePath (Join-Path $directory 'native-console.log') | Out-Host
    $nativeExit = $LASTEXITCODE
    Write-Artifact (Join-Path $directory 'native-process-result.json') ([ordered]@{ exit_code = $nativeExit; utc = [DateTime]::UtcNow.ToString('o'); native_validation_attempted = $true; validation_mode = $validationMode; cache_reused = $true; environment_retained = $true } | ConvertTo-Json)
    $export = Invoke-Captured 'wsl.exe' @('--distribution', $owner.name, '--user', 'root', '--exec', '/bin/tar', '-cf', "$nativePath/linux-results.tar", '-C', $guest, 'results') 'utf-8' '' 60
    Write-Artifact (Join-Path $directory 'results-export.json') ($export | ConvertTo-Json -Depth 5)
    if ($export.exit_code -eq 0) {
        $extract = Assert-SafePath (Join-Path $directory 'linux-results')
        New-Item -ItemType Directory -Path $extract | Out-Null
        & tar.exe -xf (Join-Path $directory 'linux-results.tar') -C $extract
        if ($LASTEXITCODE -ne 0) { throw 'Reused result archive extraction failed' }
    }
    Write-Artifact (Join-Path $directory 'registrations-after.json') ((Read-Registrations) | ConvertTo-Json -Depth 8)
    Write-Host "Owned distro and toolchain/target caches retained: $($owner.name)"
    if ($nativeExit -ne 0) { throw 'Native incremental verification failed; inspect stage evidence. Retained environment was not removed.' }
}

if ($CleanupEnvironment) { Remove-OwnedDistro $CleanupEnvironment; return }
if ($EnvironmentDirectory -and -not $ExecuteNative) { throw 'EnvironmentDirectory requires ExecuteNative' }
if ($SnapshotDirectory) {
    $frozen = Assert-SafePath $SnapshotDirectory
    if (-not $ExecuteNative) { throw 'SnapshotDirectory requires ExecuteNative' }
    $metadata = Get-Content -Raw -LiteralPath (Join-Path $frozen 'snapshot.json') | ConvertFrom-Json
    $manifestPath = Assert-SafePath (Join-Path $frozen 'source-manifest.sha256')
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $metadata.manifest_sha256) { throw 'Frozen snapshot manifest changed' }
    $sourceRoot = Assert-SafePath (Join-Path $frozen 'source')
    $lines = @(Get-Content -LiteralPath $manifestPath)
    if ($lines.Count -ne $metadata.files) { throw 'Frozen snapshot file count mismatch' }
    foreach ($line in $lines) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid manifest entry' }
        $hash, $relative = $Matches[1], $Matches[2]
        $file = Assert-SafePath (Join-Path $sourceRoot $relative)
        if (-not $file.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot entry escapes source root' }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw "Frozen source changed: $relative" }
    }
    Verify-ProductionSnapshot $frozen
    try {
        if ($EnvironmentDirectory) { Invoke-ReusedNativeVerification $frozen $EnvironmentDirectory }
        else { Invoke-NativeVerification $frozen }
    }
    finally { Verify-ProductionSnapshot $frozen }
    return
}
if ($ExecuteNative) { $PrepareSnapshot = $true }

$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$run = Assert-SafePath (Join-Path $outputRoot $runId)
if (Test-Path -LiteralPath $run) { throw 'Run directory already exists' }
New-Item -ItemType Directory -Path $run | Out-Null
$before = Read-Registrations
$probes = [ordered]@{}
foreach ($probe in @(
    @{ name = 'version'; arguments = @('--version') },
    @{ name = 'status'; arguments = @('--status') },
    @{ name = 'list'; arguments = @('--list', '--verbose') },
    @{ name = 'system_uname'; arguments = @('--system', '--exec', '/bin/uname', '-a') },
    @{ name = 'debug_shell'; arguments = @('--debug-shell') }
)) {
    Write-Host "Probe: wsl $($probe.arguments -join ' ')"
    $probes[$probe.name] = Invoke-Captured 'wsl.exe' $probe.arguments 'utf-16' "uname -a`nexit"
}
$features = @(Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform' OR Name='Microsoft-Windows-Subsystem-Linux' OR Name='HypervisorPlatform' OR Name='Microsoft-Hyper-V-All'" | Select-Object Name, InstallState)
$computer = Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, HypervisorPresent
$cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, VirtualizationFirmwareEnabled, VMMonitorModeExtensions, SecondLevelAddressTranslationExtensions)
$os = Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture
$services = @(Get-Service WslService, LxssManager, vmcompute, hns -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{ name = $_.Name; status = $_.Status.ToString(); start_type = $_.StartType.ToString() }
})
$commands = @(Get-Command wsl.exe, bash.exe, docker.exe, podman.exe, nerdctl.exe, qemu-system-x86_64.exe, multipass.exe -ErrorAction SilentlyContinue | Select-Object Name, Source)
$knownPaths = @('C:\Program Files\Docker\Docker\resources\bin\docker.exe', 'C:\Program Files\RedHat\Podman\podman.exe', 'C:\Program Files\qemu\qemu-system-x86_64.exe', 'C:\Program Files\Multipass\bin\multipass.exe')
$knownTools = @(foreach ($path in $knownPaths) { [ordered]@{ path = $path; exists = Test-Path -LiteralPath $path } })
$wslc = Join-Path $env:ProgramFiles 'WSL/wslc.exe'
$sessionProbe = $null
if (Test-Path -LiteralPath $wslc) {
    $probes.wslc_version = Invoke-Captured $wslc @('--version')
    $probes.wslc_sessions_before = Invoke-Captured $wslc @('system', 'session', 'list', '--verbose')
    $probes.wslc_enter_help = Invoke-Captured $wslc @('system', 'session', 'enter', '--help')
    if ($ProbeTemporarySession) {
        $name = 'dansheng-validation-' + $runId.Split('-')[-1]
        if ($before.distributions.name -contains $name -or $probes.wslc_sessions_before.exit_code -ne 0 -or $probes.wslc_sessions_before.stdout.Contains($name)) {
            throw 'Cannot prove the temporary name is unused'
        }
        $storage = Assert-SafePath (Join-Path $run 'session-storage')
        New-Item -ItemType Directory -Path $storage | Out-Null
        Write-Artifact (Join-Path $run 'session-ownership.json') ([ordered]@{ name = $name; storage = $storage; existing_name_checked = $true; purpose = 'isolated-readonly-linux-probe' } | ConvertTo-Json)
        Write-Host "Probe: isolated WSLC session $name"
        $sessionProbe = Invoke-Captured $wslc @('system', 'session', 'enter', '--name', $name, $storage) 'utf-8' "uname -a`ncat /etc/os-release`nexit" 90
        $probes.wslc_sessions_after = Invoke-Captured $wslc @('system', 'session', 'list', '--verbose')
    }
}
$after = Read-Registrations
$unchanged = ($before | ConvertTo-Json -Depth 8 -Compress) -ceq ($after | ConvertTo-Json -Depth 8 -Compress)
$blockers = @()
# The parent agent's scope adjustment allows first import to become the sole
# default. Do not classify that automatic effect as an environment blocker.
if ($sessionProbe -and $sessionProbe.exit_code -ne 0) { $blockers += 'WSLC_SESSION_PROBE_FAILED: see temporary_session for the actual error; no SDK/session provisioning or user settings changes attempted.' }
if (-not $unchanged) { $blockers += 'REGISTRATIONS_CHANGED_DURING_PROBE: inspect before/after; no automatic remediation performed.' }
$evidence = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); run_id = $runId
    elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    os = $os; computer = $computer; cpu = $cpu; optional_features = $features; services = $services
    commands = $commands; known_tool_paths = $knownTools; registrations_before = $before; registrations_after = $after
    registrations_unchanged = $unchanged; probes = $probes; temporary_session = $sessionProbe; blockers = $blockers
    policy_source = 'https://github.com/microsoft/WSL/blob/3.0.3/src/windows/service/exe/LxssUserSession.cpp#L3334-L3345'
    native_execution = 'NOT_RUN'; cross_compilation = 'NOT_RUN'; emulator_tests = 'NOT_RUN'; real_service_tests = 'NOT_RUN'; secret_service_success = 'NOT_RUN'
}
Write-Artifact (Join-Path $run 'probe.json') ($evidence | ConvertTo-Json -Depth 12)

if ($PrepareSnapshot) {
    Write-Host 'Preparing allowlisted source snapshot (no build outputs or profiles)'
    $source = Assert-SafePath (Join-Path $run 'source')
    New-Item -ItemType Directory -Path $source | Out-Null
    $started = [DateTime]::UtcNow.ToString('o')
    $inventory = @(Source-Inventory)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($relative in $inventory) {
        $original = Join-Path $repo $relative
        # Check each source ancestor; never follow a link out of the repo.
        for ($ancestor = $original; $ancestor -and $ancestor -ne $repo; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
            if ((Get-Item -Force -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing source link: $relative" }
        }
        $bytes = [IO.File]::ReadAllBytes($original)
        $destination = Assert-SafePath (Join-Path $source $relative)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        [IO.File]::WriteAllBytes($destination, $bytes)
        $rows.Add([ordered]@{ path = $relative; bytes = $bytes.Length; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() })
    }
    $manifest = (($rows | ForEach-Object { "$($_.sha256)  $($_.path)" }) -join "`n") + "`n"
    Write-Artifact (Join-Path $run 'source-manifest.sha256') $manifest
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $run 'source-manifest.sha256') -Algorithm SHA256).Hash.ToLowerInvariant()
    $drift = @($rows | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repo $_.path)) -or (Get-FileHash -LiteralPath (Join-Path $repo $_.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $_.sha256 } | ForEach-Object { $_.path })
    $inventoryAfter = @(Source-Inventory)
    $head = Invoke-Captured 'git' @('rev-parse', '--verify', 'HEAD')
    $metadata = [ordered]@{
        started_utc = $started; completed_utc = [DateTime]::UtcNow.ToString('o'); files = $rows.Count
        manifest_sha256 = $manifestHash; cargo_lock_sha256 = ($rows | Where-Object path -eq 'Cargo.lock').sha256
        git_head = $(if ($head.exit_code -eq 0) { $head.stdout.Trim() } else { $null })
        git_head_note = $(if ($head.exit_code -eq 0) { 'Worktree content, not just HEAD, was captured.' } else { 'Unborn repository: no HEAD commit. Content manifest identifies this snapshot.' })
        source_changed_after_capture = $drift; inventory_changed = (($inventory -join "`n") -cne ($inventoryAfter -join "`n"))
        consistency = 'Per-file content capture over an interval, not an atomic repository snapshot. Hashes identify precisely the copied bytes.'
        scope = 'Four core crates plus required lab workspace member, manifests/lock, headers, synthetic connector fixtures and plugin sources. No reference checkouts, .git, .local, target, dist, node_modules, real profiles/logs/vaults.'
    }
    Write-Artifact (Join-Path $run 'snapshot.json') ($metadata | ConvertTo-Json -Depth 6)
    if ($drift.Count -ne 0 -or $metadata.inventory_changed) {
        throw 'Source changed during capture; this snapshot will not be executed or accepted'
    }

    $bootstrap = @'
#!/usr/bin/env bash
# PREPARED ONLY. Run solely inside a fresh disposable Ubuntu/Debian Linux guest.
set -euo pipefail
[[ ${DANSHENG_DISPOSABLE_LINUX:-} == 1 ]] || { echo 'Requires an explicitly disposable guest'; exit 2; }
[[ $(id -u) == 0 ]] || { echo 'Guest root required; never elevate Windows'; exit 2; }
. /etc/os-release
[[ $ID == ubuntu || $ID == debian ]] || { echo 'Only official Ubuntu/Debian images supported'; exit 2; }
artifact=$(cd -- "$(dirname -- "$0")" && pwd)
base=${DANSHENG_LINUX_WORK:-/opt/dansheng-validation-__SUFFIX__}
[[ $base =~ ^/opt/dansheng-validation-[a-f0-9]{8}$ && ! -e $base ]] || { echo 'Requires a fresh dedicated /opt/dansheng-validation-<8 hex> directory'; exit 2; }
mkdir -m 700 "$base"
printf 'dansheng-linux-validation\n' > "$base/ownership-marker"
export CARGO_HOME="$base/cargo" RUSTUP_HOME="$base/rustup"
export TMPDIR="$base/tmp" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" XDG_CACHE_HOME="$base/cache"
mkdir -p "$CARGO_HOME" "$RUSTUP_HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$base/downloads"
# These package operations affect only the fresh guest. Keep official image APT sources.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential pkg-config ca-certificates curl xz-utils file binutils
case $(uname -m) in x86_64) triple=x86_64-unknown-linux-gnu;; aarch64) triple=aarch64-unknown-linux-gnu;; *) exit 2;; esac
cd "$base/downloads"
curl --fail --location --proto '=https' --tlsv1.2 "https://static.rust-lang.org/rustup/dist/$triple/rustup-init" -o rustup-init
curl --fail --location --proto '=https' --tlsv1.2 "https://static.rust-lang.org/rustup/dist/$triple/rustup-init.sha256" -o rustup-init.sha256
printf '%s  rustup-init\n' "$(awk '{print $1}' rustup-init.sha256)" | sha256sum -c -
chmod 700 rustup-init
./rustup-init -y --no-modify-path --profile minimal --default-toolchain 1.99.1 --component clippy --component rustfmt
export PATH="$CARGO_HOME/bin:/usr/sbin:/usr/bin:/sbin:/bin"
exec bash "$artifact/native-verify.sh" "$base"
'@
    $runner = @'
#!/usr/bin/env bash
# PREPARED ONLY. This script itself is not evidence of an executed test.
set -euo pipefail
artifact=$(cd -- "$(dirname -- "$0")" && pwd)
base=${1:?Pass the disposable Linux work directory created by bootstrap-linux.sh}
[[ $base =~ ^/opt/dansheng-validation-[a-f0-9]{8}$ && -f $base/ownership-marker && ! -e $base/source ]] || exit 2
[[ $(uname -s) == Linux ]] || exit 2
toolchain=${DANSHENG_TOOLCHAIN_BASE:-$base}
[[ $toolchain =~ ^/opt/dansheng-validation-[a-f0-9]{8}$ && -f $toolchain/ownership-marker ]] || exit 2
export CARGO_HOME="$toolchain/cargo" RUSTUP_HOME="$toolchain/rustup" CARGO_TARGET_DIR="$toolchain/target"
export PATH="$CARGO_HOME/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TMPDIR="$base/tmp" XDG_CONFIG_HOME="$base/config" XDG_DATA_HOME="$base/data" XDG_CACHE_HOME="$base/cache" XDG_RUNTIME_DIR="$base/runtime" CARGO_TERM_COLOR=never
# Resource limits apply only to this Linux validation process and its children.
export CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2
mkdir -p "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$base/results"
chmod 700 "$XDG_RUNTIME_DIR"
# Never connect to an inherited desktop D-Bus/keyring or log an environment dump.
unset DBUS_SESSION_BUS_ADDRESS DBUS_STARTER_ADDRESS DBUS_STARTER_BUS_TYPE BASH_ENV ENV
umask 077
cp -a "$artifact/source" "$base/source"
cd "$base/source"
sha256sum -c "$artifact/source-manifest.sha256" > "$base/results/source-before.log"
{ uname -a; cat /etc/os-release; rustc +1.99.1 -vV; cargo +1.99.1 --version; cc --version; printf 'CARGO_BUILD_JOBS=%s\nRUST_TEST_THREADS=%s\n' "$CARGO_BUILD_JOBS" "$RUST_TEST_THREADS"; } > "$base/results/environment.log"
[[ $(rustc +1.99.1 -vV | sed -n 's/^host: //p') == *-unknown-linux-gnu ]] || exit 2
[[ $(rustc +1.99.1 --version) == 'rustc 1.99.1 '* ]] || exit 2
failures=0
: > "$base/results/stages.tsv"
step() {
    local name=$1 rc
    shift
    printf '\nSTAGE: %s\n' "$name"
    set +e
    "$@" 2>&1 | tee "$base/results/$name.log"
    rc=${PIPESTATUS[0]}
    set -e
    printf '%s\t%s\n' "$name" "$rc" >> "$base/results/stages.tsv"
    if (( rc != 0 )); then failures=$((failures + 1)); fi
    last_rc=$rc
}
step fetch cargo +1.99.1 fetch --locked
if (( last_rc != 0 )); then exit 1; fi
mode=${DANSHENG_VALIDATION_MODE:-full}
[[ $mode == full || $mode == clippy || $mode == m5-targets || $mode == host-followup || $mode == core-host-ffi ]] || { echo 'Invalid validation mode'; exit 2; }
printf '%s\n' "$mode" > "$base/results/mode.txt"
if [[ $mode == clippy ]]; then
    step clippy cargo +1.99.1 clippy --workspace --all-features --all-targets --locked --offline -- -D warnings
    step source-unchanged sha256sum -c "$artifact/source-manifest.sha256"
    printf 'failures=%s\n' "$failures" | tee "$base/results/result.txt"
    exit "$((failures > 0))"
fi
if [[ $mode == m5-targets ]]; then
    step fmt cargo +1.99.1 fmt --all -- --check
    step test-plugin-storage cargo +1.99.1 test -p dansheng-core --test integration --all-features --locked --offline plugin_storage::
    step test-native-scheduler cargo +1.99.1 test -p dansheng-host --test native_scheduler --all-features --locked --offline
    step clippy cargo +1.99.1 clippy --workspace --all-features --all-targets --locked --offline -- -D warnings
    step source-unchanged sha256sum -c "$artifact/source-manifest.sha256"
    printf 'failures=%s\n' "$failures" | tee "$base/results/result.txt"
    exit "$((failures > 0))"
fi
if [[ $mode == host-followup ]]; then
    step fmt cargo +1.99.1 fmt --all -- --check
    step test-dansheng-host cargo +1.99.1 test -p dansheng-host --all-features --all-targets --locked --offline
    if (( last_rc != 0 )); then
        step test-dansheng-host-contract cargo +1.99.1 test -p dansheng-host --test contract --all-features --locked --offline
        step test-dansheng-host-remaining cargo +1.99.1 test -p dansheng-host --bin dansheng-host --test native_scheduler --all-features --locked --offline
    fi
    step clippy cargo +1.99.1 clippy --workspace --all-features --all-targets --locked --offline -- -D warnings
    step source-unchanged sha256sum -c "$artifact/source-manifest.sha256"
    printf 'failures=%s\n' "$failures" | tee "$base/results/result.txt"
    exit "$((failures > 0))"
fi
step fmt cargo +1.99.1 fmt --all -- --check
crates=(dansheng-core dansheng-connectors dansheng-host dansheng-ffi dansheng-lab)
if [[ $mode == core-host-ffi ]]; then crates=(dansheng-core dansheng-host dansheng-ffi); fi
for crate in "${crates[@]}"; do
    step "test-$crate" cargo +1.99.1 test -p "$crate" --all-features --all-targets --locked --offline
    if [[ $crate == dansheng-host ]] && (( last_rc != 0 )); then
        # Cargo stops after a failed lib test. Still execute the independent
        # Unix-socket/stdio-MCP integration target and retain both outcomes.
        step test-dansheng-host-contract cargo +1.99.1 test -p dansheng-host --test contract --all-features --locked --offline
        step test-dansheng-host-remaining cargo +1.99.1 test -p dansheng-host --bin dansheng-host --test native_scheduler --all-features --locked --offline
    fi
done
step clippy cargo +1.99.1 clippy --workspace --all-features --all-targets --locked --offline -- -D warnings
step ffi-build cargo +1.99.1 build -p dansheng-ffi --all-features --locked --offline
if (( last_rc == 0 )); then
    step ffi-elf file "$CARGO_TARGET_DIR/debug/libdansheng_ffi.so"
    step ffi-link cc -std=c11 -Wall -Wextra -Werror -I include crates/dansheng-ffi/tests/smoke.c -L "$CARGO_TARGET_DIR/debug" -ldansheng_ffi "-Wl,-rpath,$CARGO_TARGET_DIR/debug" -o "$base/ffi-smoke"
    if (( last_rc == 0 )); then step ffi-native "$base/ffi-smoke" "$base/ffi-fixture"; fi
fi
step source-unchanged sha256sum -c "$artifact/source-manifest.sha256"
printf 'NOT_VERIFIED: real Secret Service set/get/delete/restart. TestVault fixtures are not a native vault success.\n' > "$base/results/secret-service-status.txt"
printf 'failures=%s\n' "$failures" | tee "$base/results/result.txt"
exit "$((failures > 0))"
'@
    Write-Artifact (Join-Path $run 'bootstrap-linux.sh') ($bootstrap.Replace('__SUFFIX__', $runId.Split('-')[-1]) + "`n")
    Write-Artifact (Join-Path $run 'native-verify.sh') ($runner + "`n")
    $archive = Assert-SafePath (Join-Path $run 'source.tar')
    $tar = Invoke-Captured 'tar.exe' @('-cf', $archive, '-C', $source, '.') 'utf-8' '' 120
    Write-Artifact (Join-Path $run 'archive.json') ($tar | ConvertTo-Json -Depth 4)
    if ($tar.exit_code -ne 0) { throw 'Source archive failed; inspect archive.json' }
    Write-Host "Snapshot: $($rows.Count) files; manifest SHA256 $manifestHash"
}
Write-Host "Evidence: $run"
if ($ExecuteNative) {
    Verify-ProductionSnapshot $run
    try {
        if ($EnvironmentDirectory) { Invoke-ReusedNativeVerification $run $EnvironmentDirectory }
        else { Invoke-NativeVerification $run }
    }
    finally { Verify-ProductionSnapshot $run }
}
else { Write-Host 'This invocation collected/prepared evidence only; it did not install a distro or run the native test suite.' }
foreach ($blocker in $blockers) { Write-Host $blocker }
