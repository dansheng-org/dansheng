param([string]$CoreRoot=(Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'dansheng'))
$ErrorActionPreference='Stop'
$app=(Resolve-Path (Split-Path $PSScriptRoot)).Path
$CoreRoot=(Resolve-Path $CoreRoot).Path
. (Join-Path $CoreRoot 'scripts/release-common.ps1')
. (Join-Path $PSScriptRoot 'adapter-source.ps1')
$receipt = Get-Content (Join-Path $app '.local/native/receipt.json') -Raw | ConvertFrom-Json
if ($receipt.core_source_sha256 -ne (Get-DanshengBuildSource -Root $CoreRoot).sha256 -or
    $receipt.adapter_source_sha256 -ne (Get-AdapterSourceHash $CoreRoot) -or
    $receipt.features -notcontains 'card-login' -or
    $receipt.aar_sha256 -ne (Get-FileHash (Join-Path $app '.local/native/dansheng-android-0.1.0.aar')).Hash) {
    throw 'Run prepare-native.ps1 with the current core source first.'
}
# A local internal-distribution key; never reuse a user's Play or production key.
$keyDir=New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'dansheng-build/android-beta')
$key=Join-Path $keyDir.FullName 'internal.p12'
$protected=Join-Path $keyDir.FullName 'password.dpapi'
if((Test-Path $key) -ne (Test-Path $protected)){throw 'Incomplete internal signing identity; existing files retained.'}
$savedPass=$env:DANSHENG_BETA_PASSWORD; $savedStore=$env:DANSHENG_BETA_STORE
Push-Location $app
try {
    if(!(Test-Path $key)){
        $secret=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
        $env:DANSHENG_BETA_PASSWORD=$secret
        & (Join-Path $env:JAVA_HOME 'bin/keytool.exe') -genkeypair -alias dansheng-beta -keyalg RSA -keysize 3072 -validity 3650 -storetype PKCS12 -keystore $key -storepass:env DANSHENG_BETA_PASSWORD -dname 'CN=Dansheng Internal Beta'
        if($LASTEXITCODE -ne 0){throw 'Cannot initialize internal signing key'}
        ConvertTo-SecureString $secret -AsPlainText -Force | ConvertFrom-SecureString | Set-Content $protected
    } else {
        $env:DANSHENG_BETA_PASSWORD=[Net.NetworkCredential]::new('',((Get-Content $protected -Raw).Trim() | ConvertTo-SecureString)).Password
    }
    $env:DANSHENG_BETA_STORE=$key
    flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub
    if($LASTEXITCODE -ne 0){throw 'Release build failed'}
    $out=New-Item -ItemType Directory -Force -Path (Join-Path $app 'dist')
    Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk' -Destination (Join-Path $out.FullName 'dansheng-android-arm64-beta.apk')
} finally { Pop-Location; $env:DANSHENG_BETA_STORE=$savedStore; $env:DANSHENG_BETA_PASSWORD=$savedPass }
