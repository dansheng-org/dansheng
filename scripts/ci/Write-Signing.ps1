#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'Common.ps1')
$layout = Get-DanshengCiLayout
Assert-DanshengCiRuntime $layout
if (-not $env:KEYSTORE -or -not $env:KEYSTORE_PASSWORD) { throw 'Configure both signing secrets referenced by this workflow.' }
$directory = Assert-CiPlainPath (Join-Path $layout.runtime 'signing')
if (Test-Path -LiteralPath $directory) { throw 'Signing directory already exists.' }
[void][IO.Directory]::CreateDirectory($directory)
if (-not $IsWindows) {
    & chmod 700 $directory
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict signing directory.' }
}
$key = Join-Path $directory 'prerelease.p12'
[IO.File]::WriteAllBytes($key, [Convert]::FromBase64String($env:KEYSTORE))
if (-not $IsWindows) {
    & chmod 600 $key
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict signing file.' }
}
Add-Content -LiteralPath $env:GITHUB_ENV -Value "DANSHENG_BETA_STORE=$key" -Encoding utf8
