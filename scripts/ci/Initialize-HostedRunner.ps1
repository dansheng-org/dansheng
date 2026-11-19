#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Workspace','Flutter','Native','Sdk','Android','AndroidSource')][string]$Role)

. (Join-Path $PSScriptRoot 'Common.ps1')
$PSNativeCommandUseErrorActionPreference = $true
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Expected a GitHub-hosted runner.' }
$env:DANSHENG_CI_ROOT = Assert-CiPlainPath (Join-Path $env:RUNNER_TEMP 'dansheng-ci')
$tools = Join-Path $env:DANSHENG_CI_ROOT 'tools'
[void][IO.Directory]::CreateDirectory($tools)
$env:CARGO_BUILD_JOBS = '2'
$env:DANSHENG_GRADLE_WORKERS = '2'

function Add-ToolPath([string]$Directory) {
    $env:PATH = "$Directory$([IO.Path]::PathSeparator)$env:PATH"
}

function Get-ToolArchive([string]$Uri, [string]$Algorithm, [string]$Digest) {
    $archive = Join-Path $tools ([IO.Path]::GetFileName($Uri))
    curl --fail --silent --show-error --location --retry 3 --output $archive $Uri
    if ((Get-FileHash -LiteralPath $archive -Algorithm $Algorithm).Hash -ne $Digest) {
        throw "Tool archive checksum differs: $([IO.Path]::GetFileName($archive))."
    }
    $archive
}

$needsNdk = $Role -in @('Android', 'AndroidSource')
if ($Role -eq 'Native' -or $needsNdk) {
    if (-not $env:RUSTUP_HOME) {
        $env:RUSTUP_HOME = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.rustup'
    }
    $hostTriple = if ($IsWindows) { 'x86_64-pc-windows-gnu' } else { 'x86_64-unknown-linux-gnu' }
    $env:RUSTUP_TOOLCHAIN = "1.99.1-$hostTriple"
    $rustArgs = @('toolchain', 'install', $env:RUSTUP_TOOLCHAIN, '--profile', 'minimal', '--no-self-update')
    if ($Role -eq 'Native') { $rustArgs += @('--component', 'rustfmt', '--component', 'clippy') }
    if ($needsNdk) { $rustArgs += @('--target', 'aarch64-linux-android', '--target', 'x86_64-linux-android') }
    rustup @rustArgs
    if ($IsWindows) {
        $gcc = (Get-Command gcc.exe -CommandType Application).Source
        if ((& $gcc -dumpmachine) -ne 'x86_64-w64-mingw32') { throw 'The runner GCC must target MinGW x64.' }
        $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = $gcc
        $env:CC_x86_64_pc_windows_gnu = $gcc
        $env:LIBCLANG_PATH = Split-Path -Parent (Get-Command clang.exe -CommandType Application).Source
    }
}

if ($needsNdk) {
    $env:JAVA_HOME = $env:JAVA_HOME_21_X64
    Add-ToolPath (Join-Path $env:JAVA_HOME 'bin')
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $sdk = $env:ANDROID_SDK_ROOT
    $ndkParent = Join-Path $sdk 'ndk'
    $ndk = Join-Path $ndkParent '30.0.16138531'
    if (-not (Test-Path -LiteralPath $ndk)) {
        # The official archive pins the prerelease even if sdkmanager lists a newer NDK.
        $archive = Get-ToolArchive 'https://dl.google.com/android/repository/android-ndk-r30-beta3-linux.zip' SHA1 'f66e852ac01a57f74bcf6fd96dcea04dda5ea392'
        unzip -q $archive -d $ndkParent
        Move-Item -LiteralPath (Join-Path $ndkParent 'android-ndk-r30-beta3') -Destination $ndk
        Remove-Item -LiteralPath $archive
    }
}

if ($Role -eq 'AndroidSource') {
    $manager = Join-Path $sdk 'cmdline-tools/latest/bin/sdkmanager'
    if (-not (Test-Path -LiteralPath $manager -PathType Leaf)) {
        $archive = Get-ToolArchive 'https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip' SHA1 'e025545c62a8e64c7559119566a569fb1dec5f60'
        unzip -q $archive -d $tools
        Move-Item -LiteralPath (Join-Path $tools 'cmdline-tools') -Destination (Join-Path $sdk 'cmdline-tools/latest')
        Remove-Item -LiteralPath $archive
    }
    & $manager "--sdk_root=$sdk" 'platform-tools' 'platforms;android-37.0' 'build-tools;36.0.0' 'build-tools;37.0.0' 'cmake;3.22.1'
    $archive = Get-ToolArchive 'https://services.gradle.org/distributions/gradle-9.7.1-bin.zip' SHA256 'acd53f1edaf02f1a8ff99879f8a34b302661a057d9b063ae9e35b552f804d20a'
    unzip -q $archive -d $tools
    Remove-Item -LiteralPath $archive
    $env:GRADLE_HOME = Join-Path $tools 'gradle-9.7.1'
    Add-ToolPath (Join-Path $env:GRADLE_HOME 'bin')
}

if ($Role -in @('Flutter', 'AndroidSource')) {
    $archive = Get-ToolArchive 'https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.7-stable.tar.xz' SHA256 'af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230'
    tar -xf $archive -C $tools
    Remove-Item -LiteralPath $archive
    Add-ToolPath (Join-Path $tools 'flutter/bin')
    flutter config --no-analytics
}

& (Join-Path $PSScriptRoot 'Initialize-Runner.ps1') -Role $Role
