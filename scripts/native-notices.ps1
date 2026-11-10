param([Parameter(Mandatory)][string]$CoreRoot,[Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
$target=New-Item -ItemType Directory -Path $Destination -Force
Copy-Item -LiteralPath (Join-Path $CoreRoot 'LICENSE') -Destination (Join-Path $target.FullName 'COPYING.txt')
Push-Location $CoreRoot
try {
    . ./scripts/dev.ps1
    $tree=& cargo tree -p dansheng-ffi --features card-login --target aarch64-linux-android --edges normal,build --prefix none --format '{p}' --locked --offline
    if($LASTEXITCODE -ne 0){throw 'Native dependency inventory failed'}
    $pkgs=@{}; foreach($line in $tree){ if($line -match '^([^ ]+) v([^ ]+)'){ $pkgs[$Matches[1]+' '+$Matches[2]]=$true } }
    $meta=(& cargo metadata --format-version 1 --locked --offline) | ConvertFrom-Json
    if($LASTEXITCODE -ne 0){throw 'Cannot resolve locked dependency licenses'}
} finally {Pop-Location}
$out=[Text.StringBuilder]::new()
foreach($pkg in ($meta.packages|Sort-Object name,version)){
    if(!$pkgs.ContainsKey($pkg.name+' '+$pkg.version)){continue}
    [void]$out.AppendLine(("--- {0} {1} | {2} | {3}" -f $pkg.name,$pkg.version,$pkg.license,$pkg.repository))
    $dir=Split-Path -Parent $pkg.manifest_path
    $files=@(Get-ChildItem -LiteralPath $dir -File | Where-Object Name -match '^(LICENSE|LICENCE|NOTICE|COPYING)')
    foreach($sub in @('LICENSES','licenses')){
        $licenses=Join-Path $dir $sub
        if(Test-Path -LiteralPath $licenses -PathType Container){$files+=@(Get-ChildItem -LiteralPath $licenses -File)}
    }
    if($pkg.license_file){
        $declared=[IO.Path]::GetFullPath((Join-Path $dir $pkg.license_file))
        if($declared.StartsWith([IO.Path]::GetFullPath($dir)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $declared -PathType Leaf)){$files+=Get-Item -LiteralPath $declared}
    }
    foreach($f in ($files|Sort-Object FullName -Unique)){
        if($f.Length -le 524288 -and -not($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){[void]$out.AppendLine([IO.File]::ReadAllText($f.FullName))}
    }
    [void]$out.AppendLine()
}
[IO.File]::WriteAllText((Join-Path $target.FullName 'NATIVE-NOTICES.txt'),$out.ToString(),[Text.UTF8Encoding]::new($false))
