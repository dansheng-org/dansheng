#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$CoreToolsRoot,
    [string]$CoreRoot,
    [string]$LockFile,
    [string]$OutputDirectory,
    [switch]$ReviewSigning
)
$ErrorActionPreference = 'Stop'
if ($ReviewSigning -and -not $IsWindows) { throw 'ReviewSigning requires Windows DPAPI. On Linux supply DANSHENG_BETA_STORE and DANSHENG_BETA_PASSWORD for a persistent signing identity.' }
$app = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
. (Join-Path $PSScriptRoot 'prerelease-common.ps1')
$RuntimeRoot = Get-DanshengAppCheckedPath $RuntimeRoot
$ArtifactDirectory = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $ArtifactDirectory
$out = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $(if ($OutputDirectory) { $OutputDirectory } else { Join-Path $RuntimeRoot 'artifacts/review' })
if (Test-Path -LiteralPath $out) { throw 'Review output already exists; choose a new runtime.' }
if (Test-Path -LiteralPath (Join-Path $app 'pubspec_overrides.yaml')) { throw 'Pre-release does not accept local Pub overrides.' }
if ($env:GITHUB_ACTIONS -eq 'true' -and (-not $CoreRoot -or -not $LockFile)) {
    throw 'CI Pre-release requires an exact checkout SDK and its runtime lock.'
}
if (-not $LockFile) { $LockFile = Join-Path $app 'core.lock.json' }
$LockFile = Get-DanshengAppCheckedPath $LockFile
if ($CoreRoot) { $LockFile = Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $LockFile }
$sdkArguments = @{ AppRoot=$app; ArtifactDirectory=$ArtifactDirectory; CoreToolsRoot=$CoreToolsRoot; CoreRoot=$CoreRoot; LockFile=$LockFile }
$validation = Test-DanshengPrereleaseSdk @sdkArguments
$commit = & git --no-optional-locks -C $app rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify App commit.' }
$identity = Get-DanshengPrereleaseIdentity -AppRoot $app -Commit $commit
$lock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
$lockHash = (Get-FileHash -LiteralPath $LockFile).Hash
$saved = @{}
$names = @('DANSHENG_CORE_ROOT','DANSHENG_CORE_SDK_DIR','DANSHENG_CORE_LOCK_FILE','DANSHENG_BETA_STORE','DANSHENG_BETA_PASSWORD','ORG_GRADLE_PROJECT_danshengStableRelease','PUB_CACHE','GRADLE_USER_HOME','ANDROID_USER_HOME','TEMP','TMP','TMPDIR')
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    foreach ($dir in @('pub-cache','gradle-cache','android-user','logs','tmp')) { [void][IO.Directory]::CreateDirectory((Join-Path $RuntimeRoot $dir)) }
    [void][IO.Directory]::CreateDirectory($out)
    $env:PUB_CACHE = Join-Path $RuntimeRoot 'pub-cache'
    $env:GRADLE_USER_HOME = Join-Path $RuntimeRoot 'gradle-cache'
    $env:ANDROID_USER_HOME = Join-Path $RuntimeRoot 'android-user'
    $env:TEMP = $env:TMP = $env:TMPDIR = Join-Path $RuntimeRoot 'tmp'
    $env:DANSHENG_CORE_ROOT = Join-Path $ArtifactDirectory 'resources'
    $env:DANSHENG_CORE_SDK_DIR = $ArtifactDirectory
    $env:DANSHENG_CORE_LOCK_FILE = $LockFile
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
            & (Join-Path $env:JAVA_HOME "bin/keytool$(if($IsWindows){'.exe'})") -genkeypair -alias dansheng-beta -keyalg RSA -keysize 3072 -validity 3650 -storetype PKCS12 -keystore $key -storepass:env DANSHENG_BETA_PASSWORD -dname 'CN=Dansheng Pre-release Review'
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
        $null = Test-DanshengPrereleaseSdk @sdkArguments
        & flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub 2>&1 | Tee-Object -FilePath (Join-Path $RuntimeRoot 'logs/build-release.log')
        if ($LASTEXITCODE -ne 0) { throw 'ARM64 release build failed.' }
    } finally { Pop-Location }
    $apk = Join-Path $out $identity.apk_name
    Copy-Item -LiteralPath (Join-Path $app 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk') -Destination $apk
    & (Join-Path $PSScriptRoot 'audit-apk.ps1') -Apk $apk -Abi arm64-v8a -Output (Join-Path $out 'apk-audit.json') -ArtifactDirectory $ArtifactDirectory -LockFile $LockFile -Release -SdkOnly
    $androidSdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
    if (-not $androidSdk) { throw 'Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK installation.' }
    $buildTools = Join-Path $androidSdk 'build-tools/37.0.0'
    $suffix = if ($IsWindows) { '.exe' } else { '' }
    & (Join-Path $buildTools "zipalign$suffix") -c -P 16 4 $apk 2>&1 | Tee-Object -FilePath (Join-Path $out 'zipalign.txt')
    if ($LASTEXITCODE -ne 0) { throw 'APK ZIP alignment validation failed.' }
    Add-Content -LiteralPath (Join-Path $out 'zipalign.txt') -Value 'zipalign -c -P 16 4: passed (exit 0).'
    $signer = Join-Path $buildTools $(if ($IsWindows) { 'apksigner.bat' } else { 'apksigner' })
    & $signer verify --verbose --print-certs $apk 2>&1 | Tee-Object -FilePath (Join-Path $out 'signature.txt')
    if ($LASTEXITCODE -ne 0) { throw 'APK signature validation failed.' }
    $sha = (Get-FileHash -LiteralPath $apk).Hash.ToLowerInvariant()
    $null = Test-DanshengPrereleaseSdk @sdkArguments
    if ((Get-FileHash -LiteralPath $LockFile).Hash -cne $lockHash) { throw 'Selected SDK lock changed during the build.' }
    $dirty = @(& git --no-optional-locks -C $app status --porcelain).Count -gt 0
    if ($env:GITHUB_ACTIONS -eq 'true' -and $dirty) { throw 'CI source/lock changed during the build.' }
    [ordered]@{
        format='dansheng-app-prerelease-v1'; version=$identity.version; abi='arm64-v8a'; app_commit=$commit; app_worktree_dirty=$dirty
        core_commit=$lock.core.commit; core_state=$validation.state; core_source_sha256=$lock.core.source_sha256
        core_build_mode=$(if ($CoreRoot) { 'exact-checkout' } else { 'locked-sdk' }); core_lock_sha256=$lockHash.ToLowerInvariant()
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
    Copy-Item -LiteralPath $LockFile -Destination (Join-Path $out 'core.lock.json')
    Copy-Item -LiteralPath (Join-Path $ArtifactDirectory 'receipt.json') -Destination (Join-Path $out 'core-receipt.json')
    $assets = @($identity.apk_name,'build-info.json','apk-audit.json','signature.txt','zipalign.txt','release-notes.md','core.lock.json','core-receipt.json')
    $sums = foreach ($name in $assets) { "{0}  {1}" -f (Get-FileHash -LiteralPath (Join-Path $out $name)).Hash.ToLowerInvariant(), $name }
    [IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS'), ($sums -join "`n")+"`n")
    foreach ($name in @($assets + 'SHA256SUMS')) {
        if (-not (Test-Path -LiteralPath (Join-Path $out $name)) -or (Get-Item -LiteralPath (Join-Path $out $name)).Length -eq 0) { throw "Missing or empty release asset: $name" }
    }
    [pscustomobject]@{ apk=$apk; version=$identity.version; abi='arm64-v8a'; sha256=$sha; tag=$identity.tag } | ConvertTo-Json
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
