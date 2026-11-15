#Requires -Version 7.0
# Static tool fixtures exercise both host branches. No compiler, Gradle, Flutter,
# signing command, network access or private profile is used.
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
$repo = [IO.Path]::GetFullPath((Join-Path $scripts '../../..'))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dansheng-android-host-' + [guid]::NewGuid().ToString('N'))
$checks = [Collections.Generic.List[string]]::new()
function Put([string]$Path, [string]$Text = 'synthetic tool; never executed') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Check($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "Host fixture failed: $Name" }
    $checks.Add($Name)
}
function Reject([scriptblock]$Action, [string]$Message, [string]$Name) {
    $rejected = $false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notlike "*$Message*") { throw }; $rejected = $true }
    Check $rejected $true $Name
}
function Ast([string]$Path) {
    $parseErrors = $null
    $tree = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Invalid PowerShell syntax: $Path" }
    $tree
}
function Assignment([string]$Path, [string]$Variable) {
    $matches = @((Ast $Path).FindAll({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Variable
    }.GetNewClosure(), $true))
    if ($matches.Count -ne 1) { throw "Expected one assignment to $Variable" }
    $matches[0].Extent.Text
}
function HostText([string]$Text) {
    # Substitute only the automatic OS flags in test copies, never in product code.
    $Text.Replace('$IsWindows', '$FixtureWindows').Replace('$IsLinux', '$FixtureLinux')
}
$names = @('ANDROID_SDK_ROOT','ANDROID_HOME','HOME','USERPROFILE','DANSHENG_TOOLCHAIN_ROOT','DANSHENG_CORE_ROOT','DANSHENG_TASK_RUNTIME','DANSHENG_GRADLE_INSTALL_ROOT','DANSHENG_CACHE_ROOT','GRADLE_HOME','GRADLE_USER_HOME','CARGO_HOME','RUSTUP_HOME','RUSTUP_TOOLCHAIN','PATH','LIBCLANG_PATH','CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER','CC_x86_64_pc_windows_gnu','AR_x86_64_pc_windows_gnu','JAVA_HOME','DANSHENG_BETA_STORE','DANSHENG_BETA_PASSWORD','TEMP','TMP','TMPDIR')
foreach ($arch in @('aarch64','x86_64')) {
    $key = $arch + '_linux_android'
    $names += @("CC_$key", "AR_$key", "BINDGEN_EXTRA_CLANG_ARGS_$key", ('CARGO_TARGET_' + $key.ToUpperInvariant() + '_LINKER'))
}
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($relative in @('core/scripts/dev.ps1','core/scripts/android-env.ps1','core/platform/android/gradlew.ps1','apps/dansheng_app/scripts/prepare-native.ps1','apps/dansheng_app/scripts/prerelease-source-sdk.ps1','apps/dansheng_app/scripts/build-prerelease.ps1','apps/dansheng_app/scripts/build-beta.ps1')) {
        $null = Ast (Join-Path $repo $relative)
    }
    $checks.Add('all changed producer and APK scripts parse')
    . (Join-Path $scripts 'prerelease-common.ps1')
    . (Join-Path $repo 'core/scripts/runtime-common.ps1')
    foreach ($platform in @('windows','linux')) {
        $FixtureWindows = $platform -eq 'windows'
        $FixtureLinux = -not $FixtureWindows
        $root = Join-Path $fixture "$platform with spaces"
        $core = Join-Path $root 'core'
        foreach ($name in @('dev.ps1','android-env.ps1','runtime-common.ps1')) {
            Put (Join-Path $core "scripts/$name") (HostText ([IO.File]::ReadAllText((Join-Path $repo "core/scripts/$name"))))
        }
        $env:HOME = Join-Path $root 'home'
        $env:USERPROFILE = $null
        $sdk = Join-Path $env:HOME 'Android/Sdk'
        $env:ANDROID_SDK_ROOT = $sdk
        $env:ANDROID_HOME = Join-Path $root 'other-sdk'
        $env:DANSHENG_TOOLCHAIN_ROOT = Join-Path $root 'portable'
        # Even with Windows portable tools present, Linux must retain its runner tools.
        foreach ($tool in @('cargo/bin/cargo.exe','winlibs/mingw64/bin/gcc.exe','winlibs/mingw64/bin/ar.exe')) { Put (Join-Path $env:DANSHENG_TOOLCHAIN_ROOT $tool) }
        $env:CARGO_HOME = Join-Path $root 'public-cache/cargo-home'
        $env:RUSTUP_HOME = Join-Path $root 'tools/rustup'
        $toolchain = if ($FixtureWindows) { 'stable-x86_64-pc-windows-gnu' } else { '1.99.1-x86_64-unknown-linux-gnu' }
        $env:RUSTUP_TOOLCHAIN = $toolchain
        $env:DANSHENG_TASK_RUNTIME = $null
        $env:DANSHENG_CORE_ROOT = $core
        $beforePath = $env:PATH
        . (Join-Path $core 'scripts/dev.ps1')
        Check $env:RUSTUP_TOOLCHAIN $toolchain "$platform preserves explicit Rust toolchain"
        Check $env:RUSTUP_HOME (Join-Path $root 'tools/rustup') "$platform preserves explicit rustup home"
        Check $env:CARGO_HOME (Join-Path $root 'public-cache/cargo-home') "$platform preserves injected Cargo home"
        if ($FixtureLinux) { Check $env:PATH $beforePath 'Linux ignores portable Windows executables' }
        if ($FixtureWindows) {
            $env:RUSTUP_TOOLCHAIN = '1.99.1-x86_64-pc-windows-msvc'
            . (Join-Path $core 'scripts/dev.ps1')
            Check $env:RUSTUP_TOOLCHAIN '1.99.1-x86_64-pc-windows-msvc' 'Windows preserves explicit MSVC selection'
            $env:RUSTUP_TOOLCHAIN = $null
            . (Join-Path $core 'scripts/dev.ps1')
            Check $env:RUSTUP_TOOLCHAIN 'stable-x86_64-pc-windows-gnu' 'Windows portable GNU default remains available'
        }
        $hostTag = if ($FixtureWindows) { 'windows-x86_64' } else { 'linux-x86_64' }
        $ndk = Join-Path $sdk "ndk/30.0.16138531/toolchains/llvm/prebuilt/$hostTag"
        $exe = if ($FixtureWindows) { '.exe' } else { '' }
        $cmd = if ($FixtureWindows) { '.cmd' } else { '' }
        foreach ($arch in @('aarch64','x86_64')) { Put (Join-Path $ndk "bin/$arch-linux-android24-clang$cmd") }
        foreach ($tool in @('llvm-ar','llvm-strip')) { Put (Join-Path $ndk "bin/$tool$exe") }
        foreach ($arch in @('aarch64','x86_64')) {
            . (Join-Path $core 'scripts/android-env.ps1') -Architecture $arch
            $key = $arch + '_linux_android'
            $compiler = Join-Path $ndk "bin/$arch-linux-android24-clang$cmd"
            Check ([Environment]::GetEnvironmentVariable("CC_$key")) $compiler "$platform $arch selects NDK clang launcher"
            Check ([Environment]::GetEnvironmentVariable('CARGO_TARGET_' + $key.ToUpperInvariant() + '_LINKER')) $compiler "$platform $arch selects Cargo linker"
            Check ([Environment]::GetEnvironmentVariable("AR_$key")) (Join-Path $ndk "bin/llvm-ar$exe") "$platform $arch selects llvm-ar"
            Check $DanshengAndroidStrip (Join-Path $ndk "bin/llvm-strip$exe") "$platform $arch selects llvm-strip"
            Check $env:LIBCLANG_PATH (Join-Path $ndk $(if ($FixtureWindows) { 'bin' } else { 'lib' })) "$platform $arch selects libclang directory"
            Check ([Environment]::GetEnvironmentVariable("BINDGEN_EXTRA_CLANG_ARGS_$key")) "--target=$arch-linux-android24 --sysroot=$($ndk.Replace('\','/'))/sysroot" "$platform $arch retains bindgen target and sysroot"
            Check ($env:PATH.StartsWith((Join-Path $ndk 'bin') + [IO.Path]::PathSeparator)) $true "$platform PATH uses the process path separator"
        }
        $env:ANDROID_SDK_ROOT = $null
        $env:ANDROID_HOME = $sdk
        . (Join-Path $core 'scripts/android-env.ps1')
        Check $DanshengNdkRoot $ndk "$platform accepts ANDROID_HOME without SDK_ROOT"
        if ($FixtureLinux) {
            $env:ANDROID_HOME = $null
            . (Join-Path $core 'scripts/android-env.ps1')
            Check $DanshengNdkRoot $ndk 'Linux SDK fallback uses HOME without USERPROFILE'
        }
        [IO.File]::Delete((Join-Path $ndk "bin/llvm-strip$exe"))
        Reject { . (Join-Path $core 'scripts/android-env.ps1') } 'missing required compiler/binutils' "$platform rejects incomplete NDK before compiling"
        $gradleName = if ($FixtureWindows) { 'gradle.bat' } else { 'gradle' }
        $gradleFixtureHome = Join-Path $root 'tools/gradle-9.7.1'
        Put (Join-Path $gradleFixtureHome "bin/$gradleName")
        Put (Join-Path $gradleFixtureHome 'lib/gradle-launcher-9.7.1.jar')
        $env:GRADLE_HOME = $gradleFixtureHome
        $env:ANDROID_SDK_ROOT = $sdk
        $env:ANDROID_HOME = $null
        $gradleText = [IO.File]::ReadAllText((Join-Path $repo 'core/platform/android/gradlew.ps1'))
        # Execute the real selection and boundary checks, stopping before invocation.
        $prefix = $gradleText.Substring(0, $gradleText.IndexOf('Push-Location -LiteralPath $PSScriptRoot', [StringComparison]::Ordinal))
        $launcherFixture = Join-Path $core 'platform/android/gradlew.ps1'
        Put $launcherFixture (HostText $prefix)
        . $launcherFixture
        Check $DanshengGradle (Join-Path $gradleFixtureHome "bin/$gradleName") "$platform Core selects pinned Gradle launcher"
        Check $env:ANDROID_HOME $sdk "$platform Core uses SDK_ROOT for Android home"
        $sourceSdk = Join-Path $scripts 'prerelease-source-sdk.ps1'
        foreach ($variable in @('$gradleName','$gradlePath','$launcher')) { . ([scriptblock]::Create((HostText (Assignment $sourceSdk $variable)))) }
        Check $launcher (Join-Path $gradleFixtureHome "bin/$gradleName") "$platform source SDK reuses pinned Gradle validation"
        & {
            $env:GRADLE_HOME = $null
            # PATH discovery is mocked because Linux fixture launchers cannot run
            # on Windows. The selected path still uses the real JAR validator.
            function Get-Command {
                param($Name, $CommandType, $ErrorAction)
                Check $Name $gradleName "$platform PATH discovery requests only its native Gradle launcher"
                [pscustomobject]@{Source=(Join-Path $gradleFixtureHome "bin/$gradleName")}
            }
            foreach ($variable in @('$gradleName','$gradlePath','$launcher')) { . ([scriptblock]::Create((HostText (Assignment $sourceSdk $variable)))) }
            Check $launcher (Join-Path $gradleFixtureHome "bin/$gradleName") "$platform source SDK accepts PATH-only Gradle installation"
        }
        $env:GRADLE_HOME = $gradleFixtureHome
        [IO.File]::Delete((Join-Path $gradleFixtureHome 'lib/gradle-launcher-9.7.1.jar'))
        Reject { . $launcherFixture } 'must be version 9.7.1' "$platform Core rejects another Gradle version"
        Reject { Resolve-DanshengPrereleaseGradle -CommandPath $launcher } 'pinned Gradle 9.7.1' "$platform SDK rejects another Gradle version"
        Put (Join-Path $gradleFixtureHome 'lib/gradle-launcher-9.7.1.jar')
        $cacheHome = Join-Path $env:HOME '.gradle/wrapper/dists/gradle-9.7.1-bin/fixture/gradle-9.7.1'
        Put (Join-Path $cacheHome "bin/$gradleName")
        Put (Join-Path $cacheHome 'lib/gradle-launcher-9.7.1.jar')
        $env:GRADLE_HOME = $env:GRADLE_USER_HOME = $env:DANSHENG_CACHE_ROOT = $env:DANSHENG_GRADLE_INSTALL_ROOT = $null
        . $launcherFixture
        Check $DanshengGradle (Join-Path $cacheHome "bin/$gradleName") "$platform discovers HOME Gradle cache without USERPROFILE"
        $env:JAVA_HOME = Join-Path $root 'tools/java-21'
        foreach ($file in @('build-prerelease.ps1','build-beta.ps1')) {
            $command = (Ast (Join-Path $scripts $file)).Find({ param($n)
                $n -is [Management.Automation.Language.CommandAst] -and $n.CommandElements[0].Extent.Text -like '*bin/keytool*'
            }, $true)
            $selected = . ([scriptblock]::Create((HostText $command.CommandElements[0].Extent.Text)))
            Check $selected (Join-Path $env:JAVA_HOME "bin/keytool$exe") "$platform $file selects host keytool"
        }
        $prerelease = Join-Path $scripts 'build-prerelease.ps1'
        foreach ($variable in @('$androidSdk','$buildTools','$suffix','$signer')) { . ([scriptblock]::Create((HostText (Assignment $prerelease $variable)))) }
        Check $buildTools (Join-Path $sdk 'build-tools/37.0.0') "$platform APK tools accept SDK_ROOT without ANDROID_HOME"
        Check $signer (Join-Path $buildTools $(if ($FixtureWindows) { 'apksigner.bat' } else { 'apksigner' })) "$platform selects APK signature verifier"
    }
    $FixtureWindows = $false
    $FixtureLinux = $true
    $releaseText = [IO.File]::ReadAllText((Join-Path $scripts 'build-prerelease.ps1'))
    $reviewGate = $releaseText.Substring(0, $releaseText.IndexOf('$app =', [StringComparison]::Ordinal))
    Put (Join-Path $fixture 'review-gate.ps1') (HostText $reviewGate)
    Reject { & (Join-Path $fixture 'review-gate.ps1') -RuntimeRoot $fixture -ArtifactDirectory $fixture -CoreToolsRoot $fixture -ReviewSigning } 'requires Windows DPAPI' 'Linux review signing refuses plaintext password persistence before writing outputs'
    $RuntimeRoot = Join-Path $fixture 'runtime'
    . ([scriptblock]::Create((Assignment (Join-Path $scripts 'build-prerelease.ps1') '$env:TEMP')))
    Check $env:TMPDIR (Join-Path $RuntimeRoot 'tmp') 'APK build assigns Linux temporary directory inside runtime'
    . (Join-Path $scripts 'core-dependency.ps1')
    $app = Split-Path -Parent $scripts
    $CoreRoot = Join-Path $repo 'core'
    $SigningDirectory = $null
    $betaStatements = (Ast (Join-Path $scripts 'build-beta.ps1')).EndBlock.Statements
    $signingStatement = $betaStatements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$providedSigning'
    }
    $signingIndex = [Array]::IndexOf($betaStatements, $signingStatement)
    $signingGate = [scriptblock]::Create((HostText ($signingStatement.Extent.Text + "`n" + $betaStatements[$signingIndex + 1].Extent.Text)))
    $signingKey = Join-Path $RuntimeRoot 'signing/persistent.p12'
    Put $signingKey 'synthetic signing fixture, not a real key'
    $env:DANSHENG_BETA_STORE = $signingKey
    $env:DANSHENG_BETA_PASSWORD = 'synthetic fixture, not a secret'
    . $signingGate
    Check $key $signingKey 'Linux beta accepts injected persistent signing identity inside runtime'
    Check (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'signing/android-beta/password.dpapi')) $false 'Linux beta never persists an unencrypted signing password'
    $outsideKey = Join-Path $fixture 'outside-runtime.p12'
    Put $outsideKey 'synthetic signing fixture, not a real key'
    $env:DANSHENG_BETA_STORE = $outsideKey
    Reject { . $signingGate } 'inside the selected task runtime' 'Linux beta refuses signing identity outside runtime'
    $env:DANSHENG_BETA_STORE = $signingKey
    $env:DANSHENG_BETA_PASSWORD = $null
    Reject { . $signingGate } 'Supply both' 'Linux beta refuses incomplete signing environment'
    $env:DANSHENG_BETA_STORE = $null
    Reject { . $signingGate } 'requires Windows DPAPI' 'Linux beta requires injected signing instead of unsafe local persistence'
    [pscustomobject]@{passed=$checks.Count;checks=@($checks);fixture=$fixture;static_host_fixtures=$true;native_build=$false} | ConvertTo-Json -Depth 4
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
$global:LASTEXITCODE = 0
