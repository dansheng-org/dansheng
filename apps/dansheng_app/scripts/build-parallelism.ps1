#Requires -Version 7.0
function Get-DanshengBuildParallelism {
    $settings = @{}
    foreach ($setting in @(
        @{ name='CARGO_BUILD_JOBS'; field='cargo'; fallback=3 },
        @{ name='DANSHENG_GRADLE_WORKERS'; field='gradle'; fallback=2 }
    )) {
        $value = [Environment]::GetEnvironmentVariable($setting.name)
        if ([string]::IsNullOrEmpty($value)) { $value = [string]$setting.fallback }
        if ($value -notmatch '^[1-9][0-9]{0,2}$' -or [int]$value -gt 256) {
            throw "$($setting.name) must be an integer from 1 to 256."
        }
        $settings[$setting.field] = [int]$value
    }
    [pscustomobject]$settings
}
