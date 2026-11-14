#Requires -Version 7.0
[CmdletBinding()]
param(
    [Alias('Output')][string]$OutputRoot,
    [string]$EnvironmentModule=(Join-Path (Split-Path -Parent $PSScriptRoot) 'Dansheng.Environment.psm1')
)
$ErrorActionPreference='Stop'
if(-not$IsWindows){throw 'This regression suite exercises Windows Robocopy and junction handling.'}
if(-not(Get-Command robocopy.exe -CommandType Application -ErrorAction SilentlyContinue)){throw 'Windows Robocopy is required.'}
if(-not$OutputRoot){$OutputRoot=Join-Path ([IO.Path]::GetTempPath()) ('dansheng-environment-'+[guid]::NewGuid().ToString('N'))}
$fixture=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $fixture){throw 'Refusing to overwrite or reuse an existing environment fixture.'}
if(-not(Test-Path -LiteralPath $EnvironmentModule -PathType Leaf)){throw 'Dansheng.Environment.psm1 is unavailable; use -EnvironmentModule when running this draft outside its repository.'}
$modulePath=[IO.Path]::GetFullPath($EnvironmentModule)
$moduleHash=(Get-FileHash -LiteralPath $modulePath).Hash
Import-Module $modulePath -Force -DisableNameChecking
[void][IO.Directory]::CreateDirectory($fixture)
$cases=[Collections.Generic.List[object]]::new()
function New-SyntheticFile([string]$Path,[string]$Text='synthetic-string'){
    $full=[IO.Path]::GetFullPath($Path)
    if(-not$full.StartsWith($fixture+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Synthetic file escaped its fixture.'}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
    if(Test-Path -LiteralPath $full){throw 'Fixture setup refuses to overwrite a file.'}
    [IO.File]::WriteAllText($full,$Text,[Text.UTF8Encoding]::new($false))
}
function New-Case([string]$Name){
    $root=Join-Path $fixture $Name
    [void][IO.Directory]::CreateDirectory($root)
    [pscustomobject]@{root=$root;source=Join-Path $root 'source';runtime=Join-Path $root 'runtime';destination=Join-Path $root 'runtime/cache';log=Join-Path $root 'runtime/logs/copy.log'}
}
function Snapshot-SyntheticTree([string]$Root){
    if(-not(Test-Path -LiteralPath $Root)){return [pscustomobject]@{root=$Root;exists=$false;entries=@()}}
    $entries=[Collections.Generic.List[object]]::new()
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Root))
    while($pending.Count){
        foreach($item in Get-ChildItem -LiteralPath $pending.Pop() -Force|Sort-Object FullName){
            $relative=[IO.Path]::GetRelativePath($Root,$item.FullName).Replace('\','/')
            if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){
                $entries.Add([pscustomobject]@{path=$relative;kind='link';target=@($item.Target);attributes=[int]$item.Attributes})
                continue
            }
            # ReFS can publish directory mtimes after fixture creation has returned.
            # Structure, link targets and file hashes prove that preflight wrote nothing.
            if($item.PSIsContainer){$entries.Add([pscustomobject]@{path=$relative;kind='directory'});$pending.Push($item.FullName)}
            else{$entries.Add([pscustomobject]@{path=$relative;kind='file';bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName).Hash;last_write_utc=$item.LastWriteTimeUtc.ToString('o')})}
        }
    }
    [pscustomobject]@{root=$Root;exists=$true;entries=@($entries|Sort-Object path)}
}
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Expect-Rejected([string]$Name,[string]$CaseRoot,[scriptblock]$Action,[string]$Reason){
    $before=Snapshot-SyntheticTree $CaseRoot
    $rejected=$false;$message=$null
    try{& $Action|Out-Null}catch{$rejected=$true;$message=$_.Exception.Message}
    Assert-True $rejected "$Name did not reject"
    if($Reason){Assert-True ([bool]($message-match$Reason)) "$Name rejected for an unexpected reason: $message"}
    $after=Snapshot-SyntheticTree $CaseRoot
    if(($before|ConvertTo-Json -Depth 10 -Compress)-cne($after|ConvertTo-Json -Depth 10 -Compress)){
        $diagnostic='snapshot-'+($Name-replace'[^A-Za-z0-9-]','-')
        $before|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $fixture ($diagnostic+'-before.json')) -Encoding utf8
        $after|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $fixture ($diagnostic+'-after.json')) -Encoding utf8
    }
    Assert-True (($before|ConvertTo-Json -Depth 10 -Compress)-ceq($after|ConvertTo-Json -Depth 10 -Compress)) "$Name changed target, log, source or outside sentinel before rejection"
    [pscustomobject]@{name=$Name;rejected=$true;message=$message;all_fixture_bytes_and_directory_state_unchanged=$true}
}

# 1. Public missing files copy, existing task bytes survive, user files do not copy.
$case=New-Case '01-public-cache-preserves-existing'
New-SyntheticFile (Join-Path $case.source 'existing.bin') 'synthetic-seed-version'
New-SyntheticFile (Join-Path $case.source 'nested/new.bin') 'synthetic-public-missing'
New-SyntheticFile (Join-Path $case.destination 'existing.bin') 'synthetic-task-existing-version'
$protected=@('credentials','credentials.toml','credentials.json','config.toml','.npmrc','.gitconfig','.git-credentials','.yarnrc.yml','.env','.env.local','auth.json','service.json','gradle.properties','init.gradle','init.gradle.kts','cache.lock','cache.lck','nested/config.toml')
foreach($name in $protected){New-SyntheticFile (Join-Path $case.source $name)}
$preserved=(Get-FileHash -LiteralPath (Join-Path $case.destination 'existing.bin')).Hash
$sourceBefore=Snapshot-SyntheticTree $case.source
$result=Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$case.source;destination=$case.destination}) -RuntimeRoot $case.runtime -Log $case.log
Assert-True ((Get-FileHash -LiteralPath (Join-Path $case.destination 'existing.bin')).Hash-ceq$preserved) 'Existing cache bytes were replaced'
Assert-True ([IO.File]::ReadAllText((Join-Path $case.destination 'nested/new.bin'))-ceq'synthetic-public-missing') 'Missing public file was not copied'
foreach($name in $protected){Assert-True (-not(Test-Path -LiteralPath (Join-Path $case.destination $name))) "Protected user/config file was copied: $name"}
$sourceAfter=Snapshot-SyntheticTree $case.source
$sourceBefore|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $case.root 'source-before.json') -Encoding utf8
$sourceAfter|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $case.root 'source-after.json') -Encoding utf8
$beforeFiles=@($sourceBefore.entries|Where-Object kind -eq 'file'|Select-Object path,bytes,sha256)
$afterFiles=@($sourceAfter.entries|Where-Object kind -eq 'file'|Select-Object path,bytes,sha256)
Assert-True (($beforeFiles|ConvertTo-Json -Depth 10 -Compress)-ceq($afterFiles|ConvertTo-Json -Depth 10 -Compress)) 'Public cache source bytes changed'
Assert-True (Test-Path -LiteralPath $case.log -PathType Leaf) 'Successful copy did not create its task-owned log'
$cases.Add([pscustomobject]@{name='public missing files only';passed=$true;existing_file_sha256=$preserved;protected_filenames_not_copied=$protected;robocopy_exit=$result.exit_code;log=$case.log})

# 2. A junction below an existing destination is refused before all writes.
$case=New-Case '02-destination-descendant-link'
New-SyntheticFile (Join-Path $case.source 'linked/new.bin')
New-SyntheticFile (Join-Path $case.destination 'keep.bin')
New-SyntheticFile $case.log
$outside=Join-Path $case.root 'outside'
New-SyntheticFile (Join-Path $outside 'keep.bin')
New-Item -ItemType Junction -Path (Join-Path $case.destination 'linked') -Target $outside|Out-Null
$check=Expect-Rejected 'destination descendant junction' $case.root {
    Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$case.source;destination=$case.destination}) -RuntimeRoot $case.runtime -Log $case.log
} 'Cache destination contains a link'
$cases.Add($check)

# 3. A linked source subtree is refused; absent destination stays absent.
$case=New-Case '03-source-link'
New-SyntheticFile (Join-Path $case.source 'public.bin')
New-SyntheticFile $case.log
$outside=Join-Path $case.root 'outside'
New-SyntheticFile (Join-Path $outside 'keep.bin')
New-Item -ItemType Junction -Path (Join-Path $case.source 'linked') -Target $outside|Out-Null
$check=Expect-Rejected 'source subtree link' $case.root {
    Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$case.source;destination=$case.destination}) -RuntimeRoot $case.runtime -Log $case.log
} 'Cache seed contains a link'
Assert-True (-not(Test-Path -LiteralPath $case.destination)) 'Source-link rejection created the destination directory'
$cases.Add($check)

# 4. Destination cannot escape the selected runtime.
$case=New-Case '04-outside-runtime-destination'
New-SyntheticFile (Join-Path $case.source 'public.bin')
New-SyntheticFile $case.log
$destination=Join-Path $case.root 'outside-cache'
New-SyntheticFile (Join-Path $destination 'keep.bin')
$check=Expect-Rejected 'outside runtime destination' $case.root {
    Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$case.source;destination=$destination}) -RuntimeRoot $case.runtime -Log $case.log
} 'escapes its task or overlaps'
$cases.Add($check)

# 5. A log outside the runtime is refused before destination/log creation.
$case=New-Case '05-outside-runtime-log'
New-SyntheticFile (Join-Path $case.source 'public.bin')
[void][IO.Directory]::CreateDirectory($case.runtime)
$outsideLog=Join-Path $case.root 'outside.log'
New-SyntheticFile $outsideLog
$check=Expect-Rejected 'outside runtime log' $case.root {
    Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$case.source;destination=$case.destination}) -RuntimeRoot $case.runtime -Log $outsideLog
} 'Dependency logs must stay'
Assert-True (-not(Test-Path -LiteralPath $case.destination)) 'Outside-log rejection created a destination'
$cases.Add($check)

# 6. Reject both source/destination overlap directions.
$case=New-Case '06-overlap'
$sourceParent=Join-Path $case.runtime 'source-parent'
New-SyntheticFile (Join-Path $sourceParent 'public.bin')
New-SyntheticFile $case.log
$first=Expect-Rejected 'destination inside source' $case.root {
    Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$sourceParent;destination=Join-Path $sourceParent 'destination'}) -RuntimeRoot $case.runtime -Log $case.log
} 'escapes its task or overlaps'
$destinationParent=Join-Path $case.runtime 'destination-parent'
$sourceChild=Join-Path $destinationParent 'source'
New-SyntheticFile (Join-Path $sourceChild 'public.bin')
$second=Expect-Rejected 'source inside destination' $case.root {
    Copy-DsDependencyCache -Copy ([pscustomobject]@{kind='synthetic';source=$sourceChild;destination=$destinationParent}) -RuntimeRoot $case.runtime -Log $case.log
} 'escapes its task or overlaps'
$cases.Add([pscustomobject]@{name='overlapping cache trees';passed=$true;directions=@($first,$second)})

Assert-True ((Get-FileHash -LiteralPath $modulePath).Hash-ceq$moduleHash) 'Source environment module changed during the test'
$report=[ordered]@{passed=$cases.Count;cases=@($cases);output_root=$fixture;environment_module=$modulePath;module_sha256=$moduleHash;synthetic_data_only=$true;real_caches_or_credentials_used=$false;fixtures_preserved=$true;created_at_utc=[DateTime]::UtcNow.ToString('o')}
$reportPath=Join-Path $fixture 'environment-results.json'
$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $reportPath -Encoding utf8
[pscustomobject]@{passed=$cases.Count;report=$reportPath;output_root=$fixture;fixtures_preserved=$true}|ConvertTo-Json -Depth 4
$global:LASTEXITCODE=0
