#Requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('app','core','all')][string]$Component='all',[switch]$Offline,[string]$RuntimeRoot,[string]$ToolchainRoot,[string]$ArtifactDirectory)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Enter-Dansheng.ps1" -RuntimeRoot $RuntimeRoot -ToolchainRoot $ToolchainRoot -ArtifactDirectory $ArtifactDirectory
function Invoke-Checked([scriptblock]$Command){& $Command;if($LASTEXITCODE -ne 0){throw "Check failed: $Command"}}
if($Component -in @('app','all')){
    Push-Location $app
    try{
        if($Offline){Invoke-Checked {flutter pub get --enforce-lockfile --offline}}else{Invoke-Checked {flutter pub get --enforce-lockfile}}
        Invoke-Checked {pwsh -NoProfile -File ./scripts/check-format.ps1}
        Invoke-Checked {flutter analyze}
        Invoke-Checked {flutter test}
        Invoke-Checked {dart run pigeon --input pigeons/dansheng.dart}
        Invoke-Checked {git diff --exit-code -- pubspec.lock lib/bridge.g.dart android/app/src/main/kotlin/org/dansheng/app/Bridge.g.kt}
    }finally{Pop-Location}
}
if($Component -in @('core','all')){
    Push-Location $core
    try{
        $offlineArgs=if($Offline){@('--offline')}else{@()}
        Invoke-Checked {cargo fmt --all -- --check}
        Invoke-Checked {cargo test --workspace --all-features --all-targets --locked @offlineArgs}
        Invoke-Checked {cargo clippy --workspace --all-features --all-targets --locked @offlineArgs -- -D warnings}
    }finally{Pop-Location}
}
Invoke-Checked {git -C $repo diff --check}
