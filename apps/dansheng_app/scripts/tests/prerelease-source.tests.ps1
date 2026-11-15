#Requires -Version 7.0
# Isolated Git/ZIP fixtures exercise the real lock producer and validator.
# Fixture bytes are not a compiled SDK and are never used by product builds.
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $scripts '../../..'))
$sourceCore = Join-Path $repo 'core'
. (Join-Path $scripts 'prerelease-common.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng-prerelease-source-' + [guid]::NewGuid().ToString('N'))
$mono = Join-Path $fixture 'checkout'
$app = Join-Path $mono 'apps/dansheng_app'
$core = Join-Path $mono 'core'
$sdk = Join-Path $fixture 'runtime/native-sdk'
$toolsRoot = Join-Path $core 'tools/workspace'
$checks = [Collections.Generic.List[string]]::new()
function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Reject([scriptblock]$Body, [string]$Pattern, [string]$Name) {
    $message = $null
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $Pattern) { throw "Expected $Name ($Pattern); received: $message" }
    $checks.Add($Name)
}
Put (Join-Path $core 'Cargo.toml') "[workspace.package]`nversion = `"0.1.0`"`n"
Put (Join-Path $core 'Cargo.lock') "version = 4`n"
Put (Join-Path $core 'rust-toolchain.toml') "[toolchain]`nchannel = `"1.99.1`"`n"
Put (Join-Path $core 'include/dansheng.h') "/* ABI v1 */ void dansheng_open(); void dansheng_request();`n"
Put (Join-Path $core 'crates/fixture/src/lib.rs') 'pub fn fixture() {}'
foreach ($name in @('build.gradle.kts','settings.gradle.kts','gradle.properties','adapter/build.gradle.kts','adapter/src/main/fixture.kt')) {
    Put (Join-Path $core "platform/android/$name") "Synthetic adapter $name"
}
foreach ($name in @('release-common.ps1','runtime-common.ps1')) {
    Put (Join-Path $core "scripts/$name") ([IO.File]::ReadAllText((Join-Path $sourceCore "scripts/$name")))
}
foreach ($name in @('Dansheng.Workspace.psm1','Test-DanshengCoreDependency.ps1','New-DanshengCoreLock.ps1')) {
    Put (Join-Path $toolsRoot $name) ([IO.File]::ReadAllText((Join-Path $sourceCore "tools/workspace/$name")))
}
Import-Module (Join-Path $toolsRoot 'Dansheng.Workspace.psm1') -Force -DisableNameChecking
foreach ($name in Get-DsCoreResourcePaths) { Put (Join-Path $core $name) "Synthetic resource $name" }
Put (Join-Path $app 'pubspec.yaml') "name: fixture`nversion: 0.1.0+1`n"
Put (Join-Path $app 'pubspec.lock') "packages:`n  pigeon:`n    version: `"29.1.1`"`n"
# A deliberately unusable tracked lock proves the runtime lock is selected.
Put (Join-Path $app 'core.lock.json') '{}'
foreach ($name in @('prerelease-source-sdk.ps1','prerelease-common.ps1','core-dependency.ps1')) {
    Put (Join-Path $app "scripts/$name") ([IO.File]::ReadAllText((Join-Path $scripts $name)))
}
[void](Invoke-DsGit $mono @('init','--initial-branch=main'))
[void](Invoke-DsGit $mono @('config','core.autocrlf','false'))
[void](Invoke-DsGit $mono @('add','--all'))
[void](Invoke-DsGit $mono @('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','-c',"core.hooksPath=$fixture/no-hooks",'commit','-m','Synthetic source fixture'))
$commit = (Invoke-DsGit $mono @('rev-parse','HEAD')).text.Trim()
Assert-DanshengPrereleaseCheckout -AppRoot $app -CoreRoot $core -Commit $commit -RequireClean
$checks.Add('exact clean checkout accepted')
Reject { Assert-DanshengPrereleaseCheckout -AppRoot $app -CoreRoot $core -Commit ('a'*40) } 'exact checkout commit' 'wrong checkout SHA rejected'
Reject { Assert-DanshengPrereleaseCheckout -AppRoot $app -CoreRoot $sourceCore -Commit $commit } 'same monorepo checkout' 'foreign Core checkout rejected'
Reject { & (Join-Path $app 'scripts/prerelease-source-sdk.ps1') -RuntimeRoot (Join-Path $fixture 'not-created') -Commit ('a'*40) } 'exact checkout commit' 'bootstrap refuses wrong SHA before acquiring dependencies'
if (Test-Path (Join-Path $fixture 'not-created')) { throw 'Rejected bootstrap wrote runtime outputs.' }
. (Join-Path $core 'scripts/release-common.ps1')
[void][IO.Directory]::CreateDirectory($sdk)
$aar = Join-Path $sdk 'fixture.aar'
$payload = [Text.Encoding]::UTF8.GetBytes('Synthetic native fixture, not executable')
$nativeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
$zip = [IO.Compression.ZipFile]::Open($aar, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($abi in @('arm64-v8a','x86_64')) {
        $stream = $zip.CreateEntry("jni/$abi/libdansheng_ffi.so").Open()
        try { $stream.Write($payload) } finally { $stream.Dispose() }
    }
} finally { $zip.Dispose() }
$receipt = [ordered]@{
    version='0.1.0'; core_commit=$commit; source_hash_format='dansheng-core-source-v1'
    core_source_sha256=(Get-DanshengBuildSource $core).sha256; adapter_source_sha256=(Get-DsAdapterSourceHash $core)
    aar_sha256=(Get-FileHash $aar).Hash; arm64_sha256=$nativeHash; x86_64_sha256=$nativeHash
    packaged_arm64_sha256=$nativeHash; packaged_x86_64_sha256=$nativeHash; features=@('fixture')
}
$receiptPath = Join-Path $sdk 'receipt.json'
Put $receiptPath ($receipt | ConvertTo-Json)
$lockPath = Join-Path $sdk 'core.lock.json'
$null = & (Join-Path $toolsRoot 'New-DanshengCoreLock.ps1') -CoreRoot $core -AppRoot $app -ReceiptFile $receiptPath -AarPath $aar -Destination $lockPath -Apply
Put (Join-Path $sdk 'legal/COPYING.txt') ([IO.File]::ReadAllText((Join-Path $core 'LICENSE')))
Put (Join-Path $sdk 'legal/NATIVE-NOTICES.txt') 'Synthetic license notice'
$argsForSdk = @{AppRoot=$app; CoreRoot=$core; CoreToolsRoot=$toolsRoot; ArtifactDirectory=$sdk; LockFile=$lockPath}
$savedActions = $env:GITHUB_ACTIONS
try {
    $env:GITHUB_ACTIONS = 'true'
    if (-not (Test-DanshengPrereleaseSdk @argsForSdk).verified) { throw 'Source SDK fixture failed.' }
    $checks.Add('CI validates generated runtime lock with actual Core tooling')
    Put (Join-Path $app 'uncommitted.txt') 'dirty fixture'
    Reject { Test-DanshengPrereleaseSdk @argsForSdk } 'clean committed source' 'CI refuses dirty source'
    # Local source validation must also catch changed bytes without the CI gate.
    $env:GITHUB_ACTIONS = $null
    foreach ($case in @(@('crates/fixture/src/lib.rs','Core source snapshot'),@('platform/android/adapter/src/main/fixture.kt','adapter source snapshot'),@('LICENSE','runtime resource'))) {
        $path = Join-Path $core $case[0]
        $before = [IO.File]::ReadAllText($path)
        try { Put $path ($before+'changed'); Reject { Test-DanshengPrereleaseSdk @argsForSdk } $case[1] "changed $($case[0]) rejected" }
        finally { Put $path $before }
    }
    $wrongTools = @{} + $argsForSdk; $wrongTools.CoreToolsRoot = Join-Path $fixture 'other-tools'
    Reject { Test-DanshengPrereleaseSdk @wrongTools } 'tools from the exact Core checkout' 'unrelated validator rejected'
    $beforeLock = [IO.File]::ReadAllText($lockPath)
    $wrongLock = $beforeLock | ConvertFrom-Json
    $wrongLock.core.commit = 'b'*40
    try { Put $lockPath ($wrongLock | ConvertTo-Json -Depth 10); Reject { Test-DanshengPrereleaseSdk @argsForSdk } 'exact checkout commit' 'older SDK lock rejected even with identical payload' }
    finally { Put $lockPath $beforeLock }
    $receipt.core_commit = 'c'*40
    try { Put $receiptPath ($receipt | ConvertTo-Json); Reject { Test-DanshengPrereleaseSdk @argsForSdk } 'producer receipt differs' 'receipt provenance mismatch rejected' }
    finally { $receipt.core_commit=$commit; Put $receiptPath ($receipt | ConvertTo-Json) }
    $beforePub = [IO.File]::ReadAllText((Join-Path $app 'pubspec.lock'))
    try { Put (Join-Path $app 'pubspec.lock') 'changed'; Reject { Test-DanshengPrereleaseSdk @argsForSdk } 'Pigeon dependency lock differs' 'different Pub lock rejected' }
    finally { Put (Join-Path $app 'pubspec.lock') $beforePub }
    # Historical SDK-only flow still uses the pinned validator export and resources.
    foreach ($resource in ($beforeLock | ConvertFrom-Json).resources) {
        Put (Join-Path $sdk "resources/$($resource.path)") ([IO.File]::ReadAllText((Join-Path $core $resource.path)))
    }
    $manifest = @{validator=@{core_commit=$commit;files=@(foreach ($name in @('Test-DanshengCoreDependency.ps1','Dansheng.Workspace.psm1')) {
        @{name=$name;sha256=(Get-FileHash (Join-Path $toolsRoot $name)).Hash.ToLowerInvariant()}
    })}}
    Put (Join-Path $mono '.github/prerelease-sdk.json') ($manifest | ConvertTo-Json -Depth 6)
    Put (Join-Path $app 'core.lock.json') $beforeLock
    if (-not (Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $toolsRoot).verified) { throw 'SDK-only mode regressed.' }
    $checks.Add('historical pinned SDK-only validation remains available')
    $manifest.validator.files[0].sha256 = '0'*64
    Put (Join-Path $mono '.github/prerelease-sdk.json') ($manifest | ConvertTo-Json -Depth 6)
    Reject { Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $sdk -CoreToolsRoot $toolsRoot } 'bytes differ from the pinned' 'SDK-only validator hash remains enforced'
} finally { $env:GITHUB_ACTIONS = $savedActions }
[pscustomobject]@{passed=$checks.Count;checks=@($checks);fixture=$fixture;native_build=$false} | ConvertTo-Json -Depth 5
$global:LASTEXITCODE = 0
