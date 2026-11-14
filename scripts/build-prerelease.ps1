#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$CoreToolsRoot,
    [string]$OutputDirectory,
    [switch]$ReviewSigning
)
$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
. (Join-Path $PSScriptRoot 'prerelease-common.ps1')
$RuntimeRoot = Get-DanshengAppCheckedPath $RuntimeRoot
$ArtifactDirectory = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $ArtifactDirectory
$out = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $(if ($OutputDirectory) { $OutputDirectory } else { Join-Path $RuntimeRoot 'artifacts/review' })
if (Test-Path -LiteralPath $out) { throw 'Review output already exists; choose a new runtime.' }
if (Test-Path -LiteralPath (Join-Path $app 'pubspec_overrides.yaml')) { throw 'Pre-release does not accept local Pub overrides.' }
$validation = Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $ArtifactDirectory -CoreToolsRoot $CoreToolsRoot
$commit = & git --no-optional-locks -C $app rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify App commit.' }
$identity = Get-DanshengPrereleaseIdentity -AppRoot $app -Commit $commit
$lock = Get-Content -LiteralPath (Join-Path $app 'core.lock.json') -Raw | ConvertFrom-Json
$saved = @{}
$names = @('DANSHENG_CORE_ROOT','DANSHENG_CORE_SDK_DIR','DANSHENG_CORE_LOCK_FILE','DANSHENG_BETA_STORE','DANSHENG_BETA_PASSWORD','ORG_GRADLE_PROJECT_danshengStableRelease','PUB_CACHE','GRADLE_USER_HOME','ANDROID_USER_HOME','TEMP','TMP')
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    foreach ($dir in @('pub-cache','gradle-cache','android-user','logs','tmp')) { [void][IO.Directory]::CreateDirectory((Join-Path $RuntimeRoot $dir)) }
    [void][IO.Directory]::CreateDirectory($out)
    $env:PUB_CACHE = Join-Path $RuntimeRoot 'pub-cache'
    $env:GRADLE_USER_HOME = Join-Path $RuntimeRoot 'gradle-cache'
    $env:ANDROID_USER_HOME = Join-Path $RuntimeRoot 'android-user'
    $env:TEMP = $env:TMP = Join-Path $RuntimeRoot 'tmp'
    $env:DANSHENG_CORE_ROOT = Join-Path $ArtifactDirectory 'resources'
    $env:DANSHENG_CORE_SDK_DIR = $ArtifactDirectory
    $env:DANSHENG_CORE_LOCK_FILE = Join-Path $app 'core.lock.json'
    Remove-Item Env:ORG_GRADLE_PROJECT_danshengStableRelease -ErrorAction SilentlyContinue
    if ($ReviewSigning) {
        if ($env:GITHUB_ACTIONS -eq 'true') { throw 'CI must use its persistent Pre-release signing secrets.' }
        $signing = Join-Path $RuntimeRoot 'signing/android-prerelease'
        [void][IO.Directory]::CreateDirectory($signing)
        $key = Join-Path $signing 'internal.p12'
        $passwordFile = Join-Path $signing 'password.dpapi'
        if ((Test-Path $key) -ne (Test-Path $passwordFile)) { throw 'Incomplete review signing identity; retained for inspection.' }
        if (-not (Test-Path $key)) {
            $env:DANSHENG_BETA_PASSWORD = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
            & (Join-Path $env:JAVA_HOME 'bin/keytool.exe') -genkeypair -alias dansheng-beta -keyalg RSA -keysize 3072 -validity 3650 -storetype PKCS12 -keystore $key -storepass:env DANSHENG_BETA_PASSWORD -dname 'CN=Dansheng Pre-release Review'
            if ($LASTEXITCODE -ne 0) { throw 'Cannot create review signing identity.' }
            ConvertTo-SecureString $env:DANSHENG_BETA_PASSWORD -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -LiteralPath $passwordFile
        } else {
            $env:DANSHENG_BETA_PASSWORD = [Net.NetworkCredential]::new('', ((Get-Content -LiteralPath $passwordFile -Raw).Trim() | ConvertTo-SecureString)).Password
        }
        $env:DANSHENG_BETA_STORE = $key
    }
    if (-not $env:DANSHENG_BETA_STORE -or -not $env:DANSHENG_BETA_PASSWORD -or -not (Test-Path -LiteralPath $env:DANSHENG_BETA_STORE)) {
        throw 'Persistent Pre-release signing identity is required; no debug or ephemeral CI signing fallback.'
    }
    $env:DANSHENG_BETA_STORE = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $env:DANSHENG_BETA_STORE
    Push-Location $app
    try {
        & flutter pub get --enforce-lockfile 2>&1 | Tee-Object -FilePath (Join-Path $RuntimeRoot 'logs/pub-get.log')
        if ($LASTEXITCODE -ne 0) { throw 'Locked Pub resolution failed.' }
        $null = Test-DanshengPrereleaseSdk -AppRoot $app -ArtifactDirectory $ArtifactDirectory -CoreToolsRoot $CoreToolsRoot
        & flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub 2>&1 | Tee-Object -FilePath (Join-Path $RuntimeRoot 'logs/build-release.log')
        if ($LASTEXITCODE -ne 0) { throw 'ARM64 release build failed.' }
    } finally { Pop-Location }
    $apk = Join-Path $out $identity.apk_name
    Copy-Item -LiteralPath (Join-Path $app 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk') -Destination $apk
    & (Join-Path $PSScriptRoot 'audit-apk.ps1') -Apk $apk -Abi arm64-v8a -Output (Join-Path $out 'apk-audit.json') -ArtifactDirectory $ArtifactDirectory -Release -SdkOnly
    $buildTools = Join-Path $env:ANDROID_HOME 'build-tools/37.0.0'
    $suffix = if ($IsWindows) { '.exe' } else { '' }
    & (Join-Path $buildTools "zipalign$suffix") -c -P 16 4 $apk 2>&1 | Tee-Object -FilePath (Join-Path $out 'zipalign.txt')
    if ($LASTEXITCODE -ne 0) { throw 'APK ZIP alignment validation failed.' }
    $signer = Join-Path $buildTools $(if ($IsWindows) { 'apksigner.bat' } else { 'apksigner' })
    & $signer verify --verbose --print-certs $apk 2>&1 | Tee-Object -FilePath (Join-Path $out 'signature.txt')
    if ($LASTEXITCODE -ne 0) { throw 'APK signature validation failed.' }
    $sha = (Get-FileHash -LiteralPath $apk).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS'), "$sha  $($identity.apk_name)`n")
    $dirty = @(& git --no-optional-locks -C $app status --porcelain).Count -gt 0
    if ($env:GITHUB_ACTIONS -eq 'true' -and $dirty) { throw 'CI source/lock changed during the build.' }
    [ordered]@{
        format='dansheng-app-prerelease-v1'; version=$identity.version; abi='arm64-v8a'; app_commit=$commit; app_worktree_dirty=$dirty
        core_commit=$lock.core.commit; core_state=$validation.state; core_source_sha256=$lock.core.source_sha256
        aar_sha256=$lock.artifact.sha256; apk=$identity.apk_name; apk_sha256=$sha; apk_bytes=(Get-Item $apk).Length
        flutter='3.47.7'; dart='3.13.5'; pigeon=$lock.binding.generator_version; github_run=$env:GITHUB_RUN_ID
        validation=@('core-sdk-lock','apk-payload','elf-16k','zipalign-16k','apksigner'); device_execution=$false; real_service_reads=$false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'build-info.json') -Encoding utf8
    $body = @"
Android ARM64 Pre-release $($identity.version).

Core dependency: **$($validation.state)**; this is a development review build.

- App: $commit
- Core: $($lock.core.commit)
- APK SHA-256: $sha
- Verified SDK lock, APK payload, native/ZIP 16 KiB alignment and APK signature.
- No emulator, physical-device or real-service execution is claimed by this build.

Download the APK and SHA256SUMS below. The signing identity is dedicated to Pre-release builds; switching from another identity requires a separate install/migration decision.
"@
    [IO.File]::WriteAllText((Join-Path $out 'release-notes.md'), $body.Replace("`r`n","`n")+"`n")
    [pscustomobject]@{ apk=$apk; version=$identity.version; abi='arm64-v8a'; sha256=$sha; tag=$identity.tag } | ConvertTo-Json
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
