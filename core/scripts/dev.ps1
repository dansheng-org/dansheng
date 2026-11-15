# Dot-source this file to use the portable Windows tools or runner-provided tools.
param([string]$ToolchainRoot)
$DanshengRoot = Split-Path -Parent $PSScriptRoot
if(-not $ToolchainRoot){$ToolchainRoot=$env:DANSHENG_TOOLCHAIN_ROOT}
$DanshengTools = if($ToolchainRoot){[IO.Path]::GetFullPath($ToolchainRoot)}else{Join-Path $DanshengRoot '.local\toolchain'}
if($IsWindows -and -not $ToolchainRoot -and -not(Test-Path -LiteralPath (Join-Path $DanshengTools 'cargo/bin/cargo.exe'))){
    $DanshengWorkspaceModule=Join-Path $DanshengRoot 'tools/workspace/Dansheng.Workspace.psm1'
    if(Test-Path -LiteralPath $DanshengWorkspaceModule){
        Import-Module $DanshengWorkspaceModule -Force
        $DanshengPrimaryRoot=Split-Path -Parent (Get-DsRepository $DanshengRoot).common_dir
        $DanshengPrimaryModuleTools=Join-Path $DanshengPrimaryRoot 'core/.local/toolchain'
        $DanshengTools=if((Test-Path -LiteralPath (Join-Path $DanshengPrimaryRoot 'core/Cargo.toml')) -and (Test-Path -LiteralPath $DanshengPrimaryModuleTools -PathType Container)){$DanshengPrimaryModuleTools}else{Join-Path $DanshengPrimaryRoot '.local/toolchain'}
    }
}
if ($IsWindows -and (Test-Path -LiteralPath (Join-Path $DanshengTools 'cargo/bin/cargo.exe'))) {
    if(-not $env:CARGO_HOME){$env:CARGO_HOME=if($env:DANSHENG_TASK_RUNTIME){Join-Path $env:DANSHENG_TASK_RUNTIME 'cargo-home'}else{Join-Path $DanshengTools 'cargo'}}
    if(-not $env:RUSTUP_HOME){$env:RUSTUP_HOME = Join-Path $DanshengTools 'rustup'}
    $env:PATH = "$(Join-Path $DanshengTools 'cargo/bin')$([IO.Path]::PathSeparator)$env:PATH"
    # The portable stable installation is currently 1.99.1, matching rust-toolchain.toml.
    # Explicit selection prevents parallel rustup auto-installers racing on Windows.
    if(-not $env:RUSTUP_TOOLCHAIN){$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu'}
}
$DanshengGccBin = Join-Path $DanshengTools 'winlibs\mingw64\bin'
if ($IsWindows -and (Test-Path -LiteralPath (Join-Path $DanshengGccBin 'gcc.exe'))) {
    $env:PATH = "$DanshengGccBin$([IO.Path]::PathSeparator)$env:PATH"
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = Join-Path $DanshengGccBin 'gcc.exe'
    $env:CC_x86_64_pc_windows_gnu = Join-Path $DanshengGccBin 'gcc.exe'
    $env:AR_x86_64_pc_windows_gnu = Join-Path $DanshengGccBin 'ar.exe'
}
$DanshengMingw = if($IsWindows){Get-ChildItem -LiteralPath $DanshengTools -Directory -Filter 'llvm-mingw-*-ucrt-x86_64' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1}
if ($DanshengMingw) {
    $DanshengMingwBin = Join-Path $DanshengMingw.FullName 'bin'
    $env:PATH = "$env:PATH$([IO.Path]::PathSeparator)$DanshengMingwBin"
    $env:LIBCLANG_PATH = $DanshengMingwBin
}
$DanshengUserHome=if($env:HOME){$env:HOME}else{[Environment]::GetFolderPath('UserProfile')}
$DanshengAndroidSdk=if($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}elseif($env:ANDROID_HOME){$env:ANDROID_HOME}elseif($IsWindows){'C:/Android/Sdk'}elseif($DanshengUserHome){Join-Path $DanshengUserHome 'Android/Sdk'}
if($DanshengAndroidSdk){
    $DanshengNdkHost=if($IsWindows){'windows-x86_64'}elseif($IsLinux){'linux-x86_64'}else{$null}
    if($DanshengNdkHost){
        $DanshengNdk = Join-Path $DanshengAndroidSdk "ndk/30.0.16138531/toolchains/llvm/prebuilt/$DanshengNdkHost"
        $DanshengClangDir=Join-Path $DanshengNdk $(if($IsWindows){'bin'}else{'lib'})
        if (Test-Path -LiteralPath (Join-Path $DanshengClangDir $(if($IsWindows){'libclang.dll'}else{'libclang.so'}))) { $env:LIBCLANG_PATH = $DanshengClangDir }
    }
}
