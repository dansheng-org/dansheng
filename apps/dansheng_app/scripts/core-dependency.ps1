#Requires -Version 7.0
# Shared path resolution for build scripts. No credentials or builds run here.
function Get-DanshengAppCheckedPath {
    param([Parameter(Mandatory)][string]$Path)
    if(-not[IO.Path]::IsPathFullyQualified($Path)-or$Path-match'[\x00-\x1f"*?]'){throw 'Use an absolute application output path without control characters or wildcards.'}
    $absolute=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if($absolute-eq[IO.Path]::GetPathRoot($absolute).TrimEnd('\','/')){throw 'A filesystem root is not an application output directory.'}
    for($ancestor=$absolute;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){
        if((Test-Path -LiteralPath $ancestor)-and((Get-Item -LiteralPath $ancestor -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Linked application output paths or ancestors are refused.'}
    }
    $absolute
}

function Get-DanshengAppRuntimeOutput {
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$Path)
    $runtime=Get-DanshengAppCheckedPath $RuntimeRoot
    $output=Get-DanshengAppCheckedPath $Path
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not$output.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'Application output must stay inside the selected task runtime.'}
    $output
}

function Get-DanshengGitCommonDirectory {
    param([Parameter(Mandatory)][string]$Root)
    $names=@('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','GIT_NAMESPACE')
    $saved=@{};$present=@{}
    foreach($name in $names){$path='Env:'+$name;$present[$name]=Test-Path -LiteralPath $path;$saved[$name]=[Environment]::GetEnvironmentVariable($name);Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}
    $savedExit=$global:LASTEXITCODE
    try{
        $value=@(& git --no-optional-locks -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null)
        if($LASTEXITCODE-ne0-or$value.Count-ne1){throw 'Core tooling must belong to a registered Git checkout.'}
        [IO.Path]::GetFullPath($value[0].Trim()).TrimEnd('\','/')
    }finally{foreach($name in $names){$path='Env:'+$name;if($present[$name]){Set-Item -LiteralPath $path -Value $saved[$name]}else{Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}};$global:LASTEXITCODE=$savedExit}
}

function Resolve-DanshengCoreRoot {
    param([Parameter(Mandatory)][string]$AppRoot,[string]$CoreRoot)
    if($CoreRoot){$selected=$CoreRoot}
    elseif($env:DANSHENG_CORE_ROOT){$selected=$env:DANSHENG_CORE_ROOT}
    else{
        $appPath=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/')
        $parent=Split-Path -Parent $appPath
        $candidates=@(
            if((Split-Path -Leaf $appPath)-ieq'app'){Join-Path $parent 'core'}
            Join-Path $parent 'dansheng-core'
            Join-Path $parent 'dansheng'
        )
        $selected=@($candidates|Where-Object {
            (Test-Path -LiteralPath (Join-Path $_ 'Cargo.toml') -PathType Leaf)-and
            (Test-Path -LiteralPath (Join-Path $_ 'include/dansheng.h') -PathType Leaf)
        }|Select-Object -First 1)-join''
        if(-not$selected){$selected=Join-Path $parent 'dansheng-core'}
    }
    if(-not[IO.Path]::IsPathRooted($selected)){$selected=Join-Path $AppRoot $selected}
    $selected=[IO.Path]::GetFullPath($selected)
    if(-not(Test-Path -LiteralPath (Join-Path $selected 'Cargo.toml') -PathType Leaf)-or
       -not(Test-Path -LiteralPath (Join-Path $selected 'include/dansheng.h') -PathType Leaf)){
        throw 'Core checkout unavailable: set DANSHENG_CORE_ROOT or pass -CoreRoot for the authorized task checkout.'
    }
    $selected
}

function Resolve-DanshengCoreArtifactDirectory {
    param([Parameter(Mandatory)][string]$AppRoot,[string]$ArtifactDirectory,[string]$RuntimeRoot)
    $selected=if($ArtifactDirectory){$ArtifactDirectory}elseif($env:DANSHENG_CORE_SDK_DIR){$env:DANSHENG_CORE_SDK_DIR}else{Join-Path (Resolve-DanshengAppRuntimeRoot -AppRoot $AppRoot -RuntimeRoot $RuntimeRoot) 'native-sdk'}
    if(-not[IO.Path]::IsPathRooted($selected)){$selected=Join-Path $AppRoot $selected}
    [IO.Path]::GetFullPath($selected)
}

function Resolve-DanshengAppRuntimeRoot {
    param([Parameter(Mandatory)][string]$AppRoot,[string]$RuntimeRoot)
    if($RuntimeRoot){$selected=$RuntimeRoot}
    elseif($env:DANSHENG_TASK_RUNTIME){$selected=$env:DANSHENG_TASK_RUNTIME}
    else{
        $appPath=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/')
        $common=Get-DanshengGitCommonDirectory -Root $appPath
        $primary=[IO.Path]::GetDirectoryName($common)
        $workspace=if($env:DANSHENG_WORKSPACE_ROOT){$env:DANSHENG_WORKSPACE_ROOT}else{Join-Path (Split-Path -Parent $primary) 'dansheng-workspace'}
        $taskKey=Split-Path -Leaf (Split-Path -Parent $appPath)
        $taskFile=Join-Path $workspace "local/tasks/$taskKey.json"
        if((Split-Path -Leaf $appPath)-ieq'app'-and(Test-Path -LiteralPath $taskFile -PathType Leaf)){
            $task=Get-Content -LiteralPath $taskFile -Raw|ConvertFrom-Json
            $component=@($task.components|Where-Object name -CEQ 'app')
            if($component.Count-ne1-or[IO.Path]::GetFullPath($component[0].path).TrimEnd('\','/')-ine$appPath-or
               [IO.Path]::GetFullPath($task.app_common_dir).TrimEnd('\','/')-ine$common){throw 'Task runtime metadata does not describe this App worktree.'}
            $selected=[string]$task.runtime_root
        }else{$selected=Join-Path $workspace ('local/runtime/manual-'+(Split-Path -Leaf $appPath))}
    }
    if(-not[IO.Path]::IsPathRooted($selected)){$selected=Join-Path $AppRoot $selected}
    [IO.Path]::GetFullPath($selected)
}

function Resolve-DanshengCoreToolsRoot {
    param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$CoreRoot,[string]$CoreToolsRoot)
    $sourceCommon=Get-DanshengGitCommonDirectory -Root $CoreRoot
    function Get-VerifiedToolsDirectory([string]$Candidate){
        if(-not[IO.Path]::IsPathRooted($Candidate)){$Candidate=Join-Path $AppRoot $Candidate}
        $candidatePath=[IO.Path]::GetFullPath($Candidate)
        $tools=if(Test-Path -LiteralPath (Join-Path $candidatePath 'Test-DanshengCoreDependency.ps1') -PathType Leaf){$candidatePath}else{Join-Path $candidatePath 'tools/workspace'}
        if(-not(Test-Path -LiteralPath (Join-Path $tools 'Test-DanshengCoreDependency.ps1') -PathType Leaf)){return $null}
        if((Get-DanshengGitCommonDirectory -Root $tools)-ine$sourceCommon){throw 'Core validation tooling belongs to a different Git repository than the SDK source.'}
        $tools
    }
    $explicit=if($CoreToolsRoot){$CoreToolsRoot}else{$env:DANSHENG_CORE_TOOLS_ROOT}
    if($explicit){$tools=Get-VerifiedToolsDirectory $explicit;if(-not$tools){throw 'Selected CoreToolsRoot has no authoritative dependency validator.'};return $tools}
    foreach($candidate in @($CoreRoot,(Join-Path (Split-Path -Parent $AppRoot) 'core'))){$tools=Get-VerifiedToolsDirectory $candidate;if($tools){return $tools}}
    $toolDirectories=@()
    $trees=@(& git --no-optional-locks -C $CoreRoot worktree list --porcelain)
    foreach($line in $trees){if($line-match'^worktree (.+)$'){$tools=Get-VerifiedToolsDirectory $Matches[1];if($tools){$toolDirectories+=$tools}}}
    $toolDirectories=@($toolDirectories|Select-Object -Unique)
    if($toolDirectories.Count-eq1){return $toolDirectories[0]}
    throw 'Set -CoreToolsRoot or DANSHENG_CORE_TOOLS_ROOT to the authoritative tools directory; SDK CoreRoot is never replaced for tool discovery.'
}

function Resolve-DanshengAppArtifactRoot {
    param([Parameter(Mandatory)][string]$AppRoot,[string]$OutputDirectory,[string]$RuntimeRoot)
    $selected=if($OutputDirectory){$OutputDirectory}elseif($env:DANSHENG_ARTIFACT_DIR){$env:DANSHENG_ARTIFACT_DIR}else{Join-Path (Resolve-DanshengAppRuntimeRoot -AppRoot $AppRoot -RuntimeRoot $RuntimeRoot) 'artifacts'}
    if(-not[IO.Path]::IsPathRooted($selected)){$selected=Join-Path $AppRoot $selected}
    [IO.Path]::GetFullPath($selected)
}

function Get-DanshengAppAarPath {
    param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$ArtifactDirectory,[string]$LockFile)
    $lock=Resolve-DanshengAppCoreLock -AppRoot $AppRoot -LockFile $LockFile
    $name='dansheng-android-0.1.0.aar'
    if(Test-Path -LiteralPath $lock -PathType Leaf){
        $record=Get-Content -LiteralPath $lock -Raw|ConvertFrom-Json
        if($record.format-ne'dansheng-core-lock-v1'-or$record.mode-ne'native-sdk'){throw 'Unsupported App Core lock.'}
        $name=[string]$record.artifact.name
        if(-not$name-or$name-in@('.','..')-or$name.Contains('/')-or$name.Contains('\')){throw 'Unsafe locked AAR name.'}
    }
    Join-Path $ArtifactDirectory $name
}

function Test-DanshengAppCoreDependency {
    param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$CoreRoot,[Parameter(Mandatory)][string]$ArtifactDirectory,[string]$LockFile,[string]$CoreToolsRoot,[switch]$ForRelease)
    $lock=Resolve-DanshengAppCoreLock -AppRoot $AppRoot -LockFile $LockFile
    if(-not(Test-Path -LiteralPath $lock -PathType Leaf)){
        if($ForRelease){throw 'Stable dependency validation requires a real core.lock.json.'}
        return [pscustomobject]@{verified=$false;state='legacy_native_receipt';stable_release_verified=$false}
    }
    $tools=Resolve-DanshengCoreToolsRoot -AppRoot $AppRoot -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot
    $validator=Join-Path $tools 'Test-DanshengCoreDependency.ps1'
    $validatorArguments=@{LockFile=$lock;ArtifactDirectory=$ArtifactDirectory;CoreRoot=$CoreRoot;AppRoot=$AppRoot}
    if($ForRelease){$validatorArguments.ForRelease=$true}
    $savedExit=$global:LASTEXITCODE
    try { (& $validator @validatorArguments|Out-String)|ConvertFrom-Json }
    finally {$global:LASTEXITCODE=$savedExit}
}

function Resolve-DanshengAppCoreLock {
    param([Parameter(Mandatory)][string]$AppRoot,[string]$LockFile)
    $selected=if($LockFile){$LockFile}elseif($env:DANSHENG_CORE_LOCK_FILE){$env:DANSHENG_CORE_LOCK_FILE}else{Join-Path $AppRoot 'core.lock.json'}
    if(-not[IO.Path]::IsPathRooted($selected)){$selected=Join-Path $AppRoot $selected}
    [IO.Path]::GetFullPath($selected)
}

function New-DanshengAppCoreLock {
    param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$CoreRoot,[Parameter(Mandatory)][string]$ArtifactDirectory,
          [string]$CoreToolsRoot,[string]$RuntimeRoot,[string]$LockFile,[switch]$UpdateLock)
    $tools=Resolve-DanshengCoreToolsRoot -AppRoot $AppRoot -CoreRoot $CoreRoot -CoreToolsRoot $CoreToolsRoot
    $runtime=Resolve-DanshengAppRuntimeRoot -AppRoot $AppRoot -RuntimeRoot $RuntimeRoot
    $destination=Resolve-DanshengAppCoreLock -AppRoot $AppRoot -LockFile $LockFile
    $logs=Join-Path $runtime 'logs'
    [void][IO.Directory]::CreateDirectory($logs)
    $temporary=Join-Path $logs ('core-lock-'+[guid]::NewGuid().ToString('N')+'.json')
    $receipt=Join-Path $ArtifactDirectory 'receipt.json'
    & (Join-Path $tools 'New-DanshengCoreLock.ps1') -CoreRoot $CoreRoot -AppRoot $AppRoot -ReceiptFile $receipt -AarPath (Join-Path $ArtifactDirectory 'dansheng-android-0.1.0.aar') -Destination $temporary -Apply|Out-Null
    & (Join-Path $tools 'Test-DanshengCoreDependency.ps1') -LockFile $temporary -ArtifactDirectory $ArtifactDirectory -CoreRoot $CoreRoot -AppRoot $AppRoot|Out-Null
    if(Test-Path -LiteralPath $destination){
        if((Get-FileHash -LiteralPath $destination).Hash-eq(Get-FileHash -LiteralPath $temporary).Hash){return $destination}
        if(-not$UpdateLock){throw 'A different Core lock already exists. Review the new SDK and pass -UpdateLock to preserve a backup and replace the lock.'}
        [IO.File]::Copy($destination,(Join-Path $logs ('core-lock-before-'+[guid]::NewGuid().ToString('N')+'.json')),$false)
    }
    [IO.File]::Copy($temporary,$destination,[bool]$UpdateLock)
    $destination
}

function Get-DanshengPackagedNativeHashes {
    param([Parameter(Mandatory)][string]$AarPath)
    $archive=[IO.Compression.ZipFile]::OpenRead($AarPath)
    $hashes=[ordered]@{}
    try {
        foreach($item in @(@{abi='arm64-v8a';field='packaged_arm64_sha256'},@{abi='x86_64';field='packaged_x86_64_sha256'})){
            $name="jni/$($item.abi)/libdansheng_ffi.so"
            $entries=@($archive.Entries|Where-Object FullName -CEQ $name)
            if($entries.Count-ne1-or$entries[0].Length-gt512MB){throw 'AAR native entry is missing, duplicated or oversized'}
            $stream=$entries[0].Open()
            try {$hashes[$item.field]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()}
            finally {$stream.Dispose()}
        }
    } finally {$archive.Dispose()}
    $hashes
}

function Assert-DanshengTaskArtifactWrite {
    param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$CoreRoot,[Parameter(Mandatory)][string]$ArtifactDirectory)
    $destination=[IO.Path]::GetFullPath($ArtifactDirectory)
    $coreBoundary=[IO.Path]::GetFullPath($CoreRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if($destination.TrimEnd('\','/')-ieq$coreBoundary.TrimEnd('\','/')-or
       $destination.StartsWith($coreBoundary,[StringComparison]::OrdinalIgnoreCase)){
        throw 'App native outputs must not be written into the Core checkout.'
    }
    $savedExit=$global:LASTEXITCODE
    try {
        $common=@(& git --no-optional-locks -C $AppRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
        if($LASTEXITCODE-eq0){
            $primary=[IO.Path]::GetDirectoryName(($common-join'').TrimEnd('\','/'))
            $primaryBoundary=$primary.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if([IO.Path]::GetFullPath($AppRoot).TrimEnd('\','/')-ine$primary-and
               ($destination.TrimEnd('\','/')-ieq$primary-or$destination.StartsWith($primaryBoundary,[StringComparison]::OrdinalIgnoreCase))){
                throw 'A task worktree cannot overwrite the original App native artifacts.'
            }
        }
    } finally {$global:LASTEXITCODE=$savedExit}
    $directory=[IO.DirectoryInfo]::new($destination)
    while($directory){
        if($directory.Exists-and($directory.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Linked native output directory refused'}
        $directory=$directory.Parent
    }
}

function Assert-DanshengOwnedEmulator {
    param([Parameter(Mandatory)][string]$Serial,[Parameter(Mandatory)][string]$OwnershipFile,[string]$Adb)
    if($Serial-notmatch'^emulator-\d+$'){throw 'Only an explicitly owned disposable emulator is accepted.'}
    $owner=Get-Content -LiteralPath $OwnershipFile -Raw|ConvertFrom-Json
    if($owner.expected_serial-ne$Serial-or-not$owner.avd_home-or-not([IO.Path]::GetFullPath($owner.avd_home).StartsWith('D:\',[StringComparison]::OrdinalIgnoreCase))){throw 'Ownership record does not describe the selected D disposable AVD.'}
    $process=Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.launcher_pid)"
    if(-not$process-or$process.CommandLine-notmatch[regex]::Escape([string]$owner.avd_name)){throw 'Owned emulator PID is not running the recorded AVD.'}
    if(-not$Adb){$Adb=Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'}
    $actual=(@(& $Adb -P $owner.adb_server_port -s $Serial emu avd name)|Select-Object -First 1).Trim()
    if($actual-ne$owner.avd_name){throw 'Connected emulator name differs from the ownership record.'}
    $owner
}
