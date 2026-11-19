#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$layout = Get-DanshengCiLayout
Assert-DanshengCiRuntime $layout
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$app = Join-Path $repo 'apps/dansheng_app'
$core = Join-Path $repo 'core'
$sdk = Join-Path $layout.runtime 'native-sdk'
$output = Join-Path $layout.runtime 'artifacts/release'
$lock = Join-Path $app 'core.lock.json'
if (Test-Path -LiteralPath $output) { throw 'Release output already exists.' }

Push-Location $app
try {
    . ./scripts/prerelease-common.ps1
    $commit = git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the tagged commit.' }
    $identity = Get-DanshengPrereleaseIdentity -AppRoot $app -Commit $commit
    if ($env:GITHUB_REF_NAME -cne "v$($identity.version_name)") { throw 'The checkout does not match the release tag.' }
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Locked Pub resolution failed.' }
    ./scripts/build-beta.ps1 -ForRelease -RuntimeRoot $layout.runtime -CoreRoot $core `
        -CoreToolsRoot (Join-Path $core 'tools/workspace') -ArtifactDirectory $sdk -LockFile $lock -OutputDirectory $output

    $apkName = "dansheng-$($identity.version)-arm64.apk"
    $apk = Join-Path $output $apkName
    Move-Item -LiteralPath (Join-Path $output 'dansheng-android-arm64-beta.apk') -Destination $apk
    ./scripts/audit-apk.ps1 -Apk $apk -Abi arm64-v8a -ArtifactDirectory $sdk -LockFile $lock `
        -Release -SdkOnly -Output (Join-Path $output 'apk-audit.json')
    $buildTools = Join-Path $env:ANDROID_SDK_ROOT 'build-tools/37.0.0'
    & (Join-Path $buildTools 'zipalign') -c -P 16 4 $apk
    if ($LASTEXITCODE -ne 0) { throw 'Release APK ZIP alignment validation failed.' }
    & (Join-Path $buildTools 'apksigner') verify --verbose --print-certs $apk |
        Tee-Object -FilePath (Join-Path $output 'signature.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Release APK signature validation failed.' }
    $sha = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    "$sha  $apkName" | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS') -Encoding utf8
} finally {
    Pop-Location
}
