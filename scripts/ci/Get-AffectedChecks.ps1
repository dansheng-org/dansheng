#Requires -Version 7.0
# Only schedules the two workspace fixture steps. Cargo checks keep their own policy.
[CmdletBinding()]
param(
    [string]$RepositoryRoot = $env:GITHUB_WORKSPACE,
    [string]$EventName = $env:GITHUB_EVENT_NAME,
    [string]$EventPath = $env:GITHUB_EVENT_PATH,
    [string]$ExpectedSha = $env:GITHUB_SHA,
    [string]$ExpectedRef = $env:GITHUB_REF,
    [string]$OutputPath = $env:GITHUB_OUTPUT
)
$ErrorActionPreference = 'Stop'

function Invoke-AffectedGit([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # Invalid UTF-8 must fail open, never silently turn a filename into a safe path.
    foreach ($name in @($start.Environment.Keys)) {
        if ($name.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase)) {
            [void]$start.Environment.Remove($name)
        }
    }
    $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $start.Environment['GIT_CONFIG_GLOBAL'] = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    $start.Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $start.Environment['GIT_NO_LAZY_FETCH'] = '1'
    $start.Environment['GIT_TERMINAL_PROMPT'] = '0'
    foreach ($argument in (@('--no-replace-objects', '-C', $RepositoryRoot) + $Arguments)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $buffer = [IO.MemoryStream]::new()
    try {
        [void]$process.Start()
        # Read bytes, not StreamReader text: automatic BOM detection could strip
        # a real U+FEFF at the start of the first filename and change its identity.
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [void]$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        # Do not echo Git stderr or filenames into workflow commands.
        if ($process.ExitCode -ne 0) { throw 'git-error' }
        return [Text.UTF8Encoding]::new($false, $true).GetString($buffer.ToArray())
    } finally { $buffer.Dispose(); $process.Dispose() }
}

function Test-AffectedSha([string]$Sha) {
    return $Sha -cmatch '^[0-9a-f]{40}$' -and $Sha -cne ('0' * 40)
}

function Test-ProductPath([string]$Path) {
    # Test-Workspace seeds its own Core/App repositories. Test-Monorepo's
    # Seed-Core/Seed-App synthesize product sources, manifests, resources and
    # Android inputs; only workspace tools and release/runtime-common are copied
    # from this checkout. Test-Environment loads the workspace modules and creates
    # its own cache data. None reads the original product sources/docs below.
    # Configuration stays full even when nested inside a product source tree.
    if ($Path -match '(?:\A|/)(?:\.cargo|\.github/workflows)(?:/|\z)' -or
        $Path -match '(?:\A|/)(?:Cargo\.(?:toml|lock)|rust-toolchain(?:\.toml)?|pubspec\.(?:yaml|lock)|package(?:-lock)?\.json|(?:settings|build)\.gradle(?:\.kts)?|gradle\.properties|build\.rs|CMakeLists\.txt|Makefile|[^/]*\.lock)\z') {
        return $false
    }
    $patterns = @(
        '\Acore/crates/[^/\r\n]+/(?:src|tests)/[^\r\n]+\.(?:rs|c|h|json|html|txt|md|csv|xml|png|jpg|jpeg|webp|svg|bin|eml)\z',
        '\Aapps/dansheng_app/(?:lib|test|pigeons)/[^\r\n]+\.(?:dart|json|html|txt|md|csv|xml|png|jpg|jpeg|webp|svg|bin)\z',
        '\Aapps/dansheng_app/android/app/src/[^\r\n]+\.(?:kt|java|xml|html|json|mjs|js|png|jpg|jpeg|webp|svg|txt)\z',
        '\A(?:core/)?docs/[^\r\n]+\.md\z',
        '\Acore/crates/[^/\r\n]+/README(?:\.[A-Za-z-]+)?\.md\z',
        '\A(?:core/|apps/dansheng_app/)?(?:README|CHANGELOG|CONTRIBUTING)(?:\.[A-Za-z-]+)?\.md\z'
    )
    foreach ($pattern in $patterns) {
        if ([regex]::IsMatch($Path, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { return $true }
    }
    return $false
}

function Test-PubspecVersionOnlyContent([string]$BeforeContent, [string]$AfterContent) {
    # Strict UTF-8 decoding above is reversible, so ordinal equality preserves
    # all bytes outside the version text, including BOM, CRLF and final newline.
    $pattern = '(?m)^version: [0-9]+\.[0-9]+\.[0-9]+\+[0-9]+(?=\r?$)'
    $beforeMatch = [regex]::Matches($BeforeContent, $pattern)
    $afterMatch = [regex]::Matches($AfterContent, $pattern)
    if ($beforeMatch.Count -ne 1 -or $afterMatch.Count -ne 1 -or
        [regex]::Matches($BeforeContent, '(?m)^version:').Count -ne 1 -or
        [regex]::Matches($AfterContent, '(?m)^version:').Count -ne 1) { return $false }
    if ($beforeMatch[0].Value -ceq $afterMatch[0].Value) { return $false }
    return $BeforeContent.Remove($beforeMatch[0].Index, $beforeMatch[0].Length) -ceq
        $AfterContent.Remove($afterMatch[0].Index, $afterMatch[0].Length)
}

function Test-PubspecVersionChange([string]$BeforeSha, [string]$AfterSha) {
    $beforeBlob = Invoke-AffectedGit @('cat-file', 'blob', "${BeforeSha}:apps/dansheng_app/pubspec.yaml")
    $afterBlob = Invoke-AffectedGit @('cat-file', 'blob', "${AfterSha}:apps/dansheng_app/pubspec.yaml")
    return Test-PubspecVersionOnlyContent $beforeBlob $afterBlob
}

$run = $true
$reason = 'comparison-unavailable'
$changedCount = 0
try {
    if ($EventName -eq 'workflow_dispatch') { $reason = 'manual-full' }
    elseif ($EventName -notin @('pull_request', 'push')) { $reason = 'unknown-event-full' }
    else {
        if (-not (Test-AffectedSha $ExpectedSha)) { throw 'invalid-checkout-sha' }
        $head = (Invoke-AffectedGit @('rev-parse', '--verify', 'HEAD')).Trim()
        if ($head -cne $ExpectedSha) { throw 'checkout-sha-mismatch' }
        $event = Get-Content -LiteralPath $EventPath -Raw | ConvertFrom-Json -AsHashtable
        $base = $null
        if ($EventName -eq 'pull_request') {
            # Use the actual checkout's raw commit parents: revision walking hides
            # parents at shallow boundaries. Never trust PR-supplied BASE_SHA env.
            if ($ExpectedRef -cnotmatch '^refs/pull/[0-9]+/merge$' -or
                $ExpectedRef -cne "refs/pull/$($event.number)/merge") { throw 'not-pr-merge-ref' }
            $prBase = [string]$event.pull_request.base.sha
            $prHead = [string]$event.pull_request.head.sha
            if (-not (Test-AffectedSha $prBase) -or -not (Test-AffectedSha $prHead)) { throw 'invalid-pr-payload' }
            $commit = Invoke-AffectedGit @('cat-file', 'commit', $head)
            $headers = ($commit -split "`n`n", 2)[0] -split "`n"
            $parents = @($headers | Where-Object { $_ -cmatch '^parent [0-9a-f]{40}$' } | ForEach-Object { $_.Substring(7) })
            if ($parents.Count -ne 2 -or $parents[0] -cne $prBase -or $parents[1] -cne $prHead) { throw 'pr-parents-mismatch' }
            $base = $parents[0]
        } else {
            if ($ExpectedRef -cnotmatch '^refs/heads/.+' -or $event.ref -cne $ExpectedRef -or
                $event.after -cne $head) { throw 'push-payload-mismatch' }
            $base = [string]$event.before
            if (-not (Test-AffectedSha $base)) { throw 'missing-push-before' }
        }
        # No network fetch: missing pre-push commits (including multi-commit pushes)
        # cost a full fixture run instead of falling back to HEAD^ and losing paths.
        [void](Invoke-AffectedGit @('cat-file', '-e', "${base}^{commit}"))
        $diff = Invoke-AffectedGit @('diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--name-only', '-z', $base, $head, '--')
        if ($diff.Length -eq 0) {
            $run = $false
            $reason = 'empty-diff'
        } else {
            if (-not $diff.EndsWith([string][char]0)) { throw 'invalid-diff-output' }
            # --no-renames emits both deleted old and added new paths. NUL framing
            # preserves whitespace, tabs, newlines, quotes and shell metacharacters.
            $paths = $diff.Substring(0, $diff.Length - 1).Split([char]0)
            $changedCount = $paths.Count
            $run = $false
            foreach ($path in $paths) {
                $safe = if ($path -ceq 'apps/dansheng_app/pubspec.yaml') {
                    Test-PubspecVersionChange $base $head
                } else { Test-ProductPath $path }
                if (-not $safe) { $run = $true; break }
            }
            $reason = if ($run) { 'dependency-or-unknown-path' } else { 'product-only' }
        }
    }
} catch {
    # Stable, single-line reasons; arbitrary event/Git text never becomes output.
    $known = @('git-error', 'invalid-checkout-sha', 'checkout-sha-mismatch', 'not-pr-merge-ref',
        'invalid-pr-payload', 'pr-parents-mismatch', 'push-payload-mismatch', 'missing-push-before', 'invalid-diff-output')
    $reason = if ($_.Exception.Message -in $known) { $_.Exception.Message } else { 'comparison-unavailable' }
    $run = $true
}
$value = $run.ToString().ToLowerInvariant()
$decision = if ($run) { 'RUN' } else { 'SKIP' }
Write-Host "Workspace fixtures: $decision ($reason; changed paths: $changedCount)."
if ($OutputPath) {
    [IO.File]::AppendAllText($OutputPath, "workspace_fixtures=$value`nreason=$reason`n", [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{ workspace_fixtures = $value; reason = $reason; changed_paths = $changedCount }
