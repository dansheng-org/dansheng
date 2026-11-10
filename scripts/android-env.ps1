param([ValidateSet('x86_64','aarch64')][string]$Architecture='x86_64')
. "$PSScriptRoot/dev.ps1"
$DanshengSdk = if($env:ANDROID_SDK_ROOT){$env:ANDROID_SDK_ROOT}else{'C:\Android\Sdk'}
$DanshengNdkRoot = Join-Path $DanshengSdk 'ndk\30.0.16138531\toolchains\llvm\prebuilt\windows-x86_64'
if(-not(Test-Path -LiteralPath $DanshengNdkRoot)){throw 'Android NDK 30.0.16138531 is required'}
$DanshengAndroidTarget = "$Architecture-linux-android"
$DanshengAndroidCompiler = Join-Path $DanshengNdkRoot "bin\${Architecture}-linux-android24-clang.cmd"
$DanshengTargetKey = $DanshengAndroidTarget.Replace('-','_')
Set-Item -Path "Env:CC_$DanshengTargetKey" -Value $DanshengAndroidCompiler
Set-Item -Path "Env:AR_$DanshengTargetKey" -Value (Join-Path $DanshengNdkRoot 'bin\llvm-ar.exe')
Set-Item -Path "Env:CARGO_TARGET_$($DanshengTargetKey.ToUpperInvariant())_LINKER" -Value $DanshengAndroidCompiler
$DanshengNdkPosix=$DanshengNdkRoot.Replace('\','/')
Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$DanshengTargetKey" -Value "--target=${Architecture}-linux-android24 --sysroot=$DanshengNdkPosix/sysroot"
$env:LIBCLANG_PATH=Join-Path $DanshengNdkRoot 'bin'
$env:PATH="$DanshengNdkRoot\bin;$env:PATH"
