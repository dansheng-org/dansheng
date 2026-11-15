param([ValidateSet('x86_64','aarch64')][string]$Architecture='x86_64')
. "$PSScriptRoot/dev.ps1"
$DanshengSdk = $DanshengAndroidSdk
if(-not $DanshengSdk){throw 'Set ANDROID_SDK_ROOT or ANDROID_HOME to the Android SDK installation.'}
if(-not $DanshengNdkHost){throw 'Android builds require a Windows or Linux x86_64 host.'}
$DanshengNdkRoot = Join-Path $DanshengSdk "ndk/30.0.16138531/toolchains/llvm/prebuilt/$DanshengNdkHost"
if(-not(Test-Path -LiteralPath $DanshengNdkRoot)){throw 'Android NDK 30.0.16138531 is required'}
$DanshengAndroidTarget = "$Architecture-linux-android"
$DanshengAndroidCompiler = Join-Path $DanshengNdkRoot "bin/${Architecture}-linux-android24-clang$(if($IsWindows){'.cmd'})"
$DanshengAndroidAr = Join-Path $DanshengNdkRoot "bin/llvm-ar$(if($IsWindows){'.exe'})"
$DanshengAndroidStrip = Join-Path $DanshengNdkRoot "bin/llvm-strip$(if($IsWindows){'.exe'})"
foreach($DanshengAndroidTool in @($DanshengAndroidCompiler,$DanshengAndroidAr,$DanshengAndroidStrip)){
    if(-not(Test-Path -LiteralPath $DanshengAndroidTool -PathType Leaf)){throw 'Android NDK 30.0.16138531 is missing required compiler/binutils for this host.'}
}
$DanshengTargetKey = $DanshengAndroidTarget.Replace('-','_')
Set-Item -Path "Env:CC_$DanshengTargetKey" -Value $DanshengAndroidCompiler
Set-Item -Path "Env:AR_$DanshengTargetKey" -Value $DanshengAndroidAr
Set-Item -Path "Env:CARGO_TARGET_$($DanshengTargetKey.ToUpperInvariant())_LINKER" -Value $DanshengAndroidCompiler
$DanshengNdkPosix=$DanshengNdkRoot.Replace('\','/')
Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$DanshengTargetKey" -Value "--target=${Architecture}-linux-android24 --sysroot=$DanshengNdkPosix/sysroot"
$env:LIBCLANG_PATH=Join-Path $DanshengNdkRoot $(if($IsWindows){'bin'}else{'lib'})
$env:PATH="$(Join-Path $DanshengNdkRoot 'bin')$([IO.Path]::PathSeparator)$env:PATH"
