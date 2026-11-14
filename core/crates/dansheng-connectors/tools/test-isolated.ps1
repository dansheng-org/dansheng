param([string]$Cargo = 'cargo', [switch]$Clippy)
$ErrorActionPreference = 'Stop'
# Snapshot only this owned crate and workspace dependency declarations. Do not
# create/change the shared root Cargo.lock, manifests, or another worker's files.
$crate = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $crate '../..'))
$validationRoot = Join-Path ([IO.Path]::GetTempPath()) ('dansheng-connectors-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $validationRoot | Out-Null
$copy = Join-Path $validationRoot 'connectors'
New-Item -ItemType Directory -Path $copy | Out-Null
Copy-Item -LiteralPath (Join-Path $crate 'Cargo.toml') -Destination $copy
Copy-Item -LiteralPath (Join-Path $crate 'src') -Destination $copy -Recurse
Copy-Item -LiteralPath (Join-Path $crate 'tests') -Destination $copy -Recurse
$rootManifest = [IO.File]::ReadAllText((Join-Path $repo 'Cargo.toml'))
$package = [regex]::Match($rootManifest, '(?ms)^\[workspace\.package\]\s*\r?\n.*?(?=^\[|\z)').Value
$dependencies = [regex]::Match($rootManifest, '(?ms)^\[workspace\.dependencies\]\s*\r?\n.*?(?=^\[|\z)').Value
if (!$package -or !$dependencies) { throw 'Workspace dependency declarations not found' }
[IO.File]::WriteAllText((Join-Path $validationRoot 'Cargo.toml'), "[workspace]`nmembers = [`"connectors`"]`nresolver = `"2`"`n`n" + $package + "`n" + $dependencies)
Write-Output "Isolated validation snapshot: $validationRoot"
if ($Clippy) {
    & $Cargo clippy --manifest-path (Join-Path $validationRoot 'Cargo.toml') -p dansheng-connectors --all-targets -- -D warnings
} else {
    & $Cargo test --manifest-path (Join-Path $validationRoot 'Cargo.toml') -p dansheng-connectors
}
exit $LASTEXITCODE
