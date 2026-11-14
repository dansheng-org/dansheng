#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Dansheng.Workspace.psm1') -DisableNameChecking

function Get-DsPortableToolchain {
    param([Parameter(Mandatory)][string]$CoreRepository, [string]$ToolchainRoot, [switch]$Require)
    $primary = Get-DsRepository $CoreRepository
    if (-not $ToolchainRoot) { $ToolchainRoot = $env:DANSHENG_TOOLCHAIN_ROOT }
    if (-not $ToolchainRoot) {
        $primaryRoot=Split-Path -Parent $primary.common_dir
        $moduleTools=Join-Path $primaryRoot 'core/.local/toolchain'
        $ToolchainRoot=if((Test-Path -LiteralPath (Join-Path $primaryRoot 'core/Cargo.toml')) -and (Test-Path -LiteralPath $moduleTools -PathType Container)){$moduleTools}else{Join-Path $primaryRoot '.local/toolchain'}
    }
    $root = Get-DsPath $ToolchainRoot
    $environment = @{}
    if (-not $IsWindows) {
        $cargo = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($Require -and -not $cargo) { throw 'Cargo is unavailable. Install the project toolchain before initializing this task.' }
        return [pscustomobject]@{root=$root;available=[bool]$cargo;cargo=if($cargo){$cargo.Source}else{$null};environment=$environment}
    }
    $bin = Join-Path $root 'rustup/toolchains/stable-x86_64-pc-windows-gnu/bin'
    $cargoPath = Join-Path $bin 'cargo.exe'
    $gcc = Join-Path $root 'winlibs/mingw64/bin'
    $available = (Test-Path -LiteralPath $cargoPath -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $bin 'rustc.exe') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $gcc 'gcc.exe') -PathType Leaf)
    if (-not $available) {
        if ($Require) { throw "Pinned Rust/GNU tools are unavailable at $root. Supply the existing installation with -ToolchainRoot; this command does not install tools." }
        return [pscustomobject]@{root=$root;available=$false;cargo=$null;environment=$environment}
    }
    [void](Get-DsPath $bin); [void](Get-DsPath $gcc)
    $environment.RUSTUP_HOME = Join-Path $root 'rustup'
    $environment.RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-gnu'
    $environment.RUSTC = Join-Path $bin 'rustc.exe'
    $environment.RUSTDOC = Join-Path $bin 'rustdoc.exe'
    $environment.RUSTFMT = Join-Path $bin 'rustfmt.exe'
    $environment.PATH = "$bin;$gcc;$env:PATH"
    $environment.CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = Join-Path $gcc 'gcc.exe'
    $environment.CC_x86_64_pc_windows_gnu = Join-Path $gcc 'gcc.exe'
    $environment.AR_x86_64_pc_windows_gnu = Join-Path $gcc 'ar.exe'
    $clangInstall = Get-ChildItem -LiteralPath $root -Directory -Filter 'llvm-mingw-*-ucrt-x86_64' | Sort-Object Name -Descending | Select-Object -First 1
    if ($clangInstall) {
        $clang = Get-DsPath (Join-Path $clangInstall.FullName 'bin')
        if (Test-Path -LiteralPath (Join-Path $clang 'libclang.dll') -PathType Leaf) { $environment.LIBCLANG_PATH = $clang }
    }
    [pscustomobject]@{root=$root;available=$true;cargo=$cargoPath;environment=$environment}
}

function Get-DsRuntimeEnvironment {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$CoreRoot,
        [Parameter(Mandatory)][string]$CoreRepository,
        [string]$CoreToolsRoot = $PSScriptRoot,
        [string]$ToolchainRoot,
        [string]$ArtifactDirectory,
        [string]$LockFile,
        [switch]$RequireToolchain
    )
    $runtime = Get-DsPath $RuntimeRoot
    $core = Get-DsNativeRepository -Path $CoreRoot -Component core
    $primary = Get-DsRepository $CoreRepository
    if (-not $core.common_dir.Equals($primary.common_dir, [StringComparison]::OrdinalIgnoreCase)) { throw 'Task Core source belongs to another repository.' }
    foreach($sourceBoundary in @($core.checkout_root,(Split-Path -Parent $primary.common_dir))){
        if((Test-DsWithin $sourceBoundary $runtime) -or (Test-DsWithin $runtime $sourceBoundary)){throw 'Task runtime must stay outside source directories and cannot contain a checkout.'}
    }
    if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $runtime 'native-sdk' }
    $tools = Get-DsPath $CoreToolsRoot
    if (-not (Test-Path -LiteralPath (Join-Path $tools 'Test-DanshengCoreDependency.ps1') -PathType Leaf)) { throw 'Select the authoritative Core workspace tools directory.' }
    $toolchain = Get-DsPortableToolchain -CoreRepository $CoreRepository -ToolchainRoot $ToolchainRoot -Require:$RequireToolchain
    $values = @{
        CARGO_TARGET_DIR = (Get-DsPath (Join-Path $runtime 'cargo-target'))
        CARGO_HOME = (Get-DsPath (Join-Path $runtime 'cargo-home'))
        PUB_CACHE = (Get-DsPath (Join-Path $runtime 'pub-cache'))
        GRADLE_USER_HOME = (Get-DsPath (Join-Path $runtime 'gradle-cache'))
        npm_config_cache = (Get-DsPath (Join-Path $runtime 'npm-cache'))
        ANDROID_USER_HOME = (Get-DsPath (Join-Path $runtime 'android-user'))
        ANDROID_AVD_HOME = (Get-DsPath (Join-Path $runtime 'android-user/avds'))
        TEMP = (Get-DsPath (Join-Path $runtime 'tmp'))
        TMP = (Get-DsPath (Join-Path $runtime 'tmp'))
        DANSHENG_TASK_RUNTIME = $runtime
        DANSHENG_PROFILE = (Get-DsPath (Join-Path $runtime 'profiles/core'))
        DANSHENG_LAB_PROFILE = (Get-DsPath (Join-Path $runtime 'profiles/lab'))
        DANSHENG_BROWSER_PROFILE = (Get-DsPath (Join-Path $runtime 'browser'))
        DANSHENG_CORE_ROOT = $core.path
        DANSHENG_CORE_TOOLS_ROOT = $tools
        DANSHENG_CORE_SDK_DIR = (Get-DsPath $ArtifactDirectory)
        DANSHENG_CORE_LOCK_FILE = $null
        DANSHENG_TOOLCHAIN_ROOT = $toolchain.root
    }
    if ($LockFile) { $values.DANSHENG_CORE_LOCK_FILE = Get-DsPath $LockFile }
    foreach ($key in $toolchain.environment.Keys) { $values[$key] = $toolchain.environment[$key] }
    [pscustomobject]@{runtime_root=$runtime;core_root=$core.path;tools_root=$tools;toolchain=$toolchain;values=$values}
}

function Get-DsDependencyCachePlan {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][string]$CacheRoot, [string]$ToolchainRoot)
    $cache = Get-DsPath $CacheRoot
    $runtime = Get-DsPath $Record.runtime_root
    $toolchain = Get-DsPortableToolchain -CoreRepository $Record.core_repository -ToolchainRoot $ToolchainRoot
    $cargoSeed = Join-Path $cache 'cargo'
    if (-not (Test-Path -LiteralPath (Join-Path $cargoSeed 'registry/cache') -PathType Container)) { $cargoSeed = Join-Path $toolchain.root 'cargo' }
    $copies = [Collections.Generic.List[object]]::new()
    # App-only native SDK preparation also needs Rust; Core-only Android builds
    # need Gradle. Seed public dependency data without importing user settings.
    foreach ($part in @('registry/cache','registry/index','git/db','git/checkouts')) {
        $from = Join-Path $cargoSeed $part
        if (Test-Path -LiteralPath $from -PathType Container) { $copies.Add([pscustomobject]@{kind='cargo';source=(Get-DsPath $from);destination=(Get-DsPath (Join-Path $runtime "cargo-home/$part"))}) }
    }
    $from = Join-Path $cache 'npm/_cacache'
    if (Test-Path -LiteralPath $from -PathType Container) { $copies.Add([pscustomobject]@{kind='npm';source=(Get-DsPath $from);destination=(Get-DsPath (Join-Path $runtime 'npm-cache/_cacache'))}) }
    if (@($Record.components | Where-Object name -eq 'app').Count) {
        foreach ($part in @('hosted','hosted-hashes','git')) {
            $from = Join-Path $cache "pub/$part"
            if (Test-Path -LiteralPath $from -PathType Container) { $copies.Add([pscustomobject]@{kind='pub';source=(Get-DsPath $from);destination=(Get-DsPath (Join-Path $runtime "pub-cache/$part"))}) }
        }
    }
    foreach ($part in @('wrapper','caches','native')) {
        $from = Join-Path $cache "gradle/$part"
        if (Test-Path -LiteralPath $from -PathType Container) { $copies.Add([pscustomobject]@{kind='gradle';source=(Get-DsPath $from);destination=(Get-DsPath (Join-Path $runtime "gradle-cache/$part"))}) }
    }
    foreach ($copy in $copies) {
        if (-not (Test-DsWithin $runtime $copy.destination) -or (Test-DsWithin $copy.source $copy.destination) -or (Test-DsWithin $copy.destination $copy.source)) { throw 'Cache seed source and task destination overlap.' }
    }
    [pscustomobject]@{cache_root=$cache;runtime_root=$runtime;copies=$copies.ToArray();copy_mode='missing files only';credentials_and_user_configuration_copied=$false;shared_build_targets=$false}
}

function Copy-DsDependencyCache {
    param([Parameter(Mandatory)]$Copy, [Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][string]$Log)
    $source = Get-DsPath $Copy.source
    $destination = Get-DsPath $Copy.destination
    $runtime = Get-DsPath $RuntimeRoot
    if (-not (Test-DsWithin $runtime $destination) -or (Test-DsWithin $source $destination) -or (Test-DsWithin $destination $source)) { throw 'Cache copy escapes its task or overlaps its source.' }
    if (-not (Test-DsWithin $runtime $Log)) { throw 'Dependency logs must stay in the task runtime.' }
    # Robocopy can follow a junction already present below its destination.
    # Inspect the entire existing destination before any directory or log write.
    if (Test-Path -LiteralPath $destination -PathType Container) {
        $existing = [Collections.Generic.Stack[string]]::new(); $existing.Push($destination)
        while ($existing.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $existing.Pop() -Force) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cache destination contains a link; no dependency files were copied.' }
                if ($item.PSIsContainer) { $existing.Push($item.FullName) }
            }
        }
    }
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($source)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cache seed contains a link; preserve it and review the source before copying.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    [void][IO.Directory]::CreateDirectory($destination)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Get-DsPath $Log)))
    # Exclude changed/newer/older files: existing task data is never replaced.
    $arguments = @($source,$destination,'/E','/XJ','/SL','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/MT:8','/NP','/XC','/XN','/XO',"/LOG:$Log",'/XF','*.lock','*.lck','credentials','credentials.*','config.toml','.npmrc','.gitconfig','.git-credentials','.yarnrc*','.env*','auth.json','service.json','gradle.properties','init.gradle','init.gradle.kts')
    & robocopy.exe @arguments | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "Dependency cache copy failed ($code); existing task data is retained. See $Log" }
    [pscustomobject]@{kind=$Copy.kind;source=$source;destination=$destination;exit_code=$code;log=$Log;existing_files_preserved=$true}
}

Export-ModuleMember -Function Get-DsPortableToolchain,Get-DsRuntimeEnvironment,Get-DsDependencyCachePlan,Copy-DsDependencyCache
