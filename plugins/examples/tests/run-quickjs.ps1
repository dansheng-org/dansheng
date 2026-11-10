param([string]$Cargo = 'cargo')
$ErrorActionPreference = 'Stop'
$examples = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $examples '../..'))
$validationRoot = Join-Path ([IO.Path]::GetTempPath()) ('dansheng-examples-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $validationRoot 'src'),(Join-Path $validationRoot 'tests'),(Join-Path $validationRoot 'examples') -Force | Out-Null
# Read-only snapshot of the actual plugin runtime; no core/manifest changes.
Copy-Item -LiteralPath (Join-Path $repo 'crates/dansheng-core/src/plugins') -Destination (Join-Path $validationRoot 'src') -Recurse
foreach ($package in @('http-monitor','canvas-courses','fudan-timetable')) {
    Copy-Item -LiteralPath (Join-Path $examples $package) -Destination (Join-Path $validationRoot 'examples') -Recurse
}
Copy-Item -LiteralPath (Join-Path $repo 'crates/dansheng-connectors/tests/fixtures') -Destination $validationRoot -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'quickjs.rs') -Destination (Join-Path $validationRoot 'tests/examples.rs')
[IO.File]::WriteAllText((Join-Path $validationRoot 'src/lib.rs'), "pub mod plugins;`n")
$rootManifest = [IO.File]::ReadAllText((Join-Path $repo 'Cargo.toml'))
$dependencies = [regex]::Match($rootManifest, '(?ms)^\[workspace\.dependencies\]\s*\r?\n.*?(?=^\[|\z)').Value
if (!$dependencies) { throw 'Workspace dependency declarations not found' }
$manifest = @'
[workspace]
resolver = "2"

[package]
name = "dansheng-examples-validation"
version = "0.1.0"
edition = "2024"
license = "GPL-3.0-or-later"

[dependencies]
async-trait.workspace = true
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true
url.workspace = true
uuid.workspace = true
tokio.workspace = true
rquickjs = { version = "0.14", default-features = false, features = ["std", "futures", "loader"] }

'@
[IO.File]::WriteAllText((Join-Path $validationRoot 'Cargo.toml'), $manifest + "`n" + $dependencies)
Write-Output "QuickJS validation snapshot: $validationRoot"
& $Cargo test --manifest-path (Join-Path $validationRoot 'Cargo.toml') --test examples
exit $LASTEXITCODE
