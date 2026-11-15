param([string]$CoreRoot,[string]$CoreToolsRoot,[string]$ArtifactDirectory,[string]$RuntimeRoot,[string]$OutputDirectory,[string]$LockFile,[string]$SigningDirectory,[switch]$ForRelease)
$ErrorActionPreference='Stop'
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
. (Join-Path $PSScriptRoot 'core-dependency.ps1')
$CoreRoot=Resolve-DanshengCoreRoot -AppRoot $app -CoreRoot $CoreRoot
$RuntimeRoot=Resolve-DanshengAppRuntimeRoot -AppRoot $app -RuntimeRoot $RuntimeRoot
$ArtifactDirectory=Resolve-DanshengCoreArtifactDirectory -AppRoot $app -ArtifactDirectory $ArtifactDirectory -RuntimeRoot $RuntimeRoot
$OutputDirectory=Resolve-DanshengAppArtifactRoot -AppRoot $app -OutputDirectory $OutputDirectory -RuntimeRoot $RuntimeRoot
$OutputDirectory=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $OutputDirectory
Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $OutputDirectory
$dependency=Test-DanshengAppCoreDependency -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $ArtifactDirectory -CoreToolsRoot $CoreToolsRoot -LockFile $LockFile -ForRelease:$ForRelease
$aar=Get-DanshengAppAarPath -AppRoot $app -ArtifactDirectory $ArtifactDirectory -LockFile $LockFile
. (Join-Path $CoreRoot 'scripts/release-common.ps1')
. (Join-Path $PSScriptRoot 'adapter-source.ps1')
if(-not $dependency.verified){
$receipt = Get-Content -LiteralPath (Join-Path $ArtifactDirectory 'receipt.json') -Raw | ConvertFrom-Json
if ($receipt.core_source_sha256 -ne (Get-DanshengBuildSource -Root $CoreRoot).sha256 -or
    $receipt.adapter_source_sha256 -ne (Get-AdapterSourceHash $CoreRoot) -or
    $receipt.features -notcontains 'card-login' -or
    $receipt.aar_sha256 -ne (Get-FileHash -LiteralPath $aar).Hash) {
    throw 'Run prepare-native.ps1 with the current core source first.'
}
}
# A task-owned internal test identity. Existing C-drive signing identities are
# preserved and never implicitly opened or replaced by a migrated task build.
$providedSigning=-not $SigningDirectory -and [bool]($env:DANSHENG_BETA_STORE -or $env:DANSHENG_BETA_PASSWORD)
if($providedSigning){
    if(-not $env:DANSHENG_BETA_STORE -or -not $env:DANSHENG_BETA_PASSWORD -or -not(Test-Path -LiteralPath $env:DANSHENG_BETA_STORE -PathType Leaf)){
        throw 'Supply both DANSHENG_BETA_STORE and DANSHENG_BETA_PASSWORD for a persistent signing identity.'
    }
    $key=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $env:DANSHENG_BETA_STORE
    Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $key
}else{
    if(-not $IsWindows){throw 'Local signing identity creation requires Windows DPAPI. On Linux supply DANSHENG_BETA_STORE and DANSHENG_BETA_PASSWORD within the task runtime.'}
    if(-not$SigningDirectory){$SigningDirectory=Join-Path $RuntimeRoot 'signing/android-beta'}
    $SigningDirectory=Get-DanshengAppRuntimeOutput -RuntimeRoot $RuntimeRoot -Path $SigningDirectory
    Assert-DanshengTaskArtifactWrite -AppRoot $app -CoreRoot $CoreRoot -ArtifactDirectory $SigningDirectory
    $keyDir=New-Item -ItemType Directory -Force -Path $SigningDirectory
    $key=Join-Path $keyDir.FullName 'internal.p12'
    $protected=Join-Path $keyDir.FullName 'password.dpapi'
    if((Test-Path $key) -ne (Test-Path $protected)){throw 'Incomplete internal signing identity; existing files retained.'}
}
$savedPass=$env:DANSHENG_BETA_PASSWORD; $savedStore=$env:DANSHENG_BETA_STORE
$savedCore=$env:DANSHENG_CORE_ROOT; $savedSdk=$env:DANSHENG_CORE_SDK_DIR
$savedLock=$env:DANSHENG_CORE_LOCK_FILE
$savedStable=$env:ORG_GRADLE_PROJECT_danshengStableRelease
Push-Location $app
try {
    $env:DANSHENG_CORE_ROOT=$CoreRoot
    $env:DANSHENG_CORE_SDK_DIR=$ArtifactDirectory
    $env:DANSHENG_CORE_LOCK_FILE=Resolve-DanshengAppCoreLock -AppRoot $app -LockFile $LockFile
    if($ForRelease){$env:ORG_GRADLE_PROJECT_danshengStableRelease='true'}
    if(-not $providedSigning){
        if(!(Test-Path $key)){
            $secret=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
            $env:DANSHENG_BETA_PASSWORD=$secret
            & (Join-Path $env:JAVA_HOME "bin/keytool$(if($IsWindows){'.exe'})") -genkeypair -alias dansheng-beta -keyalg RSA -keysize 3072 -validity 3650 -storetype PKCS12 -keystore $key -storepass:env DANSHENG_BETA_PASSWORD -dname 'CN=Dansheng Internal Beta'
            if($LASTEXITCODE -ne 0){throw 'Cannot initialize internal signing key'}
            ConvertTo-SecureString $secret -AsPlainText -Force | ConvertFrom-SecureString | Set-Content $protected
        } else {
            $env:DANSHENG_BETA_PASSWORD=[Net.NetworkCredential]::new('',((Get-Content $protected -Raw).Trim() | ConvertTo-SecureString)).Password
        }
    }
    $env:DANSHENG_BETA_STORE=$key
    flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
    if($LASTEXITCODE -ne 0){throw 'Release build failed'}
    $out=New-Item -ItemType Directory -Force -Path $OutputDirectory
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk' -Destination (Join-Path $out.FullName 'dansheng-android-arm64-beta.apk')
} finally { Pop-Location; $env:DANSHENG_BETA_STORE=$savedStore; $env:DANSHENG_BETA_PASSWORD=$savedPass; $env:DANSHENG_CORE_ROOT=$savedCore; $env:DANSHENG_CORE_SDK_DIR=$savedSdk; $env:DANSHENG_CORE_LOCK_FILE=$savedLock; $env:ORG_GRADLE_PROJECT_danshengStableRelease=$savedStable }
