# Dot-source this file to use the portable, project-local Windows toolchain.
$DanshengRoot = Split-Path -Parent $PSScriptRoot
$DanshengTools = Join-Path $DanshengRoot '.local\toolchain'
if (Test-Path -LiteralPath (Join-Path $DanshengTools 'cargo\bin\cargo.exe')) {
    $env:CARGO_HOME = Join-Path $DanshengTools 'cargo'
    $env:RUSTUP_HOME = Join-Path $DanshengTools 'rustup'
    $env:PATH = "$env:CARGO_HOME\bin;$env:PATH"
    # The portable stable installation is currently 1.99.1, matching rust-toolchain.toml.
    # Explicit selection prevents parallel rustup auto-installers racing on Windows.
    $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu'
}
$DanshengGccBin = Join-Path $DanshengTools 'winlibs\mingw64\bin'
if (Test-Path -LiteralPath (Join-Path $DanshengGccBin 'gcc.exe')) {
    $env:PATH = "$DanshengGccBin;$env:PATH"
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = Join-Path $DanshengGccBin 'gcc.exe'
    $env:CC_x86_64_pc_windows_gnu = Join-Path $DanshengGccBin 'gcc.exe'
    $env:AR_x86_64_pc_windows_gnu = Join-Path $DanshengGccBin 'ar.exe'
}
$DanshengMingw = Get-ChildItem -LiteralPath $DanshengTools -Directory -Filter 'llvm-mingw-*-ucrt-x86_64' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($DanshengMingw) {
    $DanshengMingwBin = Join-Path $DanshengMingw.FullName 'bin'
    $env:PATH = "$env:PATH;$DanshengMingwBin"
    $env:LIBCLANG_PATH = $DanshengMingwBin
}
$DanshengNdk = 'C:\Android\Sdk\ndk\30.0.16138531\toolchains\llvm\prebuilt\windows-x86_64\bin'
if (Test-Path -LiteralPath (Join-Path $DanshengNdk 'libclang.dll')) { $env:LIBCLANG_PATH = $DanshengNdk }
