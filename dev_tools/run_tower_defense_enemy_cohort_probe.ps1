param(
    [string]$EnemyConfig = "res://resources/config/enemies/yuanshi_insect_basic.tres",

    [string]$WaveConfig = "",

    [ValidateSet("approach", "engagement", "burst", "boss")]
    [string]$Phase = "approach",

    [ValidateRange(1, 5000)]
    [int]$EnemyCount = 300,

    [ValidateRange(0, 10000)]
    [int]$FenceCount = 0,

    [bool]$FenceAbMetrics = $false,

    [ValidateRange(0, 3600)]
    [int]$WarmupFrames = 60,

    [ValidateRange(30, 36000)]
    [int]$SampleFrames = 240,

    [int]$Seed = 20260717,

    [ValidateRange(0, 1000)]
    [int]$CornCount = 0,

    [ValidateRange(0, 1000)]
    [int]$AgaveCount = 0,

    [ValidateRange(0, 1000)]
    [int]$MaxFps = 60,

    [bool]$Headless = $false,

    [ValidateRange(0, 240)]
    [int]$FixedFps = 0,

    [ValidateRange(0, 60)]
    [int]$NavigationInterval = 0,

    [bool]$NavigationRenderDedupe = $true,

    [bool]$NavigationRefreshBudget = $true,

    [bool]$CombatSenseThrottling = $true,

    [ValidateRange(0, 512)]
    [int]$NavigationRefreshCap = 0,

    [bool]$EnemyHotMetrics = $false,

    [bool]$GuardianOverlapMetrics = $false,

    [bool]$GuardianUnchangedDiffFastPath = $true,

    [ValidateRange(0.0, 1.0)]
    [double]$GuardianRefreshInterval = 0.0,

    [bool]$RuntimeCountScans = $false,

    [bool]$ProjectileWorldCertificate = $false,

    [bool]$ProjectileHotMetrics = $false,

    [bool]$BatchedProjectileMotion = $true,

    [bool]$AkAttackPhaseStagger = $true,

    [bool]$SmgShortRangeTargeting = $true,

    [bool]$SmgHitscanAttack = $true,

    [bool]$DisableSmgProjectiles = $false,

    [bool]$ExpandedProjectilePrewarm = $true,

    [bool]$EnemyAttackAudioLimiter = $true,

    [bool]$PooledMageImpactEffect = $true,

    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),

    [ValidateRange(100, 5000)]
    [int]$ExternalSampleIntervalMs = 250
)

$ErrorActionPreference = "Stop"
$probeScript = "res://dev_tools/tower_defense_enemy_cohort_performance_probe.gd"

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot console executable was not found: $GodotExe"
}
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Godot project root was not found: $ProjectRoot"
}

$resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$tempStem = "arc_nice_enemy_cohort_{0}" -f ([Guid]::NewGuid().ToString("N"))
$stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ($tempStem + ".out")
$stderrPath = Join-Path ([IO.Path]::GetTempPath()) ($tempStem + ".err")

$godotArguments = @()
if ($Headless) {
    $godotArguments += "--headless"
}
if ($FixedFps -gt 0) {
    $godotArguments += @("--fixed-fps", $FixedFps)
}
$godotArguments += @(
    "--path", $resolvedProjectRoot,
    "--script", $probeScript,
    "--",
    "--phase=$Phase",
    "--enemies=$EnemyCount",
    "--fences=$FenceCount",
    "--fence-ab-metrics=$($FenceAbMetrics.ToString().ToLowerInvariant())",
    "--warmup=$WarmupFrames",
    "--samples=$SampleFrames",
    "--seed=$Seed",
    "--corn=$CornCount",
    "--agave=$AgaveCount",
    "--max-fps=$MaxFps",
    "--navigation-interval=$NavigationInterval",
    "--navigation-render-dedupe=$($NavigationRenderDedupe.ToString().ToLowerInvariant())",
    "--navigation-refresh-budget=$($NavigationRefreshBudget.ToString().ToLowerInvariant())",
    "--combat-sense-throttling=$($CombatSenseThrottling.ToString().ToLowerInvariant())",
    "--navigation-refresh-cap=$NavigationRefreshCap",
    "--enemy-hot-metrics=$($EnemyHotMetrics.ToString().ToLowerInvariant())",
    "--guardian-overlap-metrics=$($GuardianOverlapMetrics.ToString().ToLowerInvariant())",
    "--guardian-unchanged-diff-fast-path=$($GuardianUnchangedDiffFastPath.ToString().ToLowerInvariant())",
    "--guardian-refresh-interval=$GuardianRefreshInterval",
    "--runtime-count-scans=$($RuntimeCountScans.ToString().ToLowerInvariant())",
    "--projectile-world-certificate=$($ProjectileWorldCertificate.ToString().ToLowerInvariant())",
    "--projectile-hot-metrics=$($ProjectileHotMetrics.ToString().ToLowerInvariant())",
    "--batched-projectile-motion=$($BatchedProjectileMotion.ToString().ToLowerInvariant())",
    "--ak-attack-phase-stagger=$($AkAttackPhaseStagger.ToString().ToLowerInvariant())",
    "--smg-short-range-targeting=$($SmgShortRangeTargeting.ToString().ToLowerInvariant())",
    "--smg-hitscan-attack=$($SmgHitscanAttack.ToString().ToLowerInvariant())",
    "--disable-smg-projectiles=$($DisableSmgProjectiles.ToString().ToLowerInvariant())",
    "--expanded-projectile-prewarm=$($ExpandedProjectilePrewarm.ToString().ToLowerInvariant())",
    "--enemy-attack-audio-limiter=$($EnemyAttackAudioLimiter.ToString().ToLowerInvariant())",
    "--pooled-mage-impact-effect=$($PooledMageImpactEffect.ToString().ToLowerInvariant())"
)
if ([string]::IsNullOrWhiteSpace($WaveConfig)) {
    $godotArguments += "--enemy=$EnemyConfig"
} else {
    $godotArguments += "--wave=$WaveConfig"
}

$launcher = $null
$launcherExitCode = -1
$enginePid = 0
$samples = [Collections.Generic.List[object]]::new()
$lastCpuSeconds = $null
$lastSampleUtc = [DateTime]::UtcNow

try {
    # Hide only the console helper. A non-headless Godot render window remains
    # visible so RenderingServer CPU/GPU timings are real.
    $launcher = Start-Process `
        -FilePath $GodotExe `
        -ArgumentList $godotArguments `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru

    $discoveryDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $discoveryDeadline -and $enginePid -eq 0) {
        $engineProcess = Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq "Godot.exe" -and
                $_.ProcessId -ne $PID -and
                $_.CommandLine -like "*$probeScript*"
            } |
            Sort-Object ProcessId -Descending |
            Select-Object -First 1
        if ($null -ne $engineProcess) {
            $enginePid = [int]$engineProcess.ProcessId
            break
        }
        if ($launcher.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 100
    }

    while ($enginePid -gt 0) {
        $engine = Get-Process -Id $enginePid -ErrorAction SilentlyContinue
        if ($null -eq $engine) {
            break
        }

        $nowUtc = [DateTime]::UtcNow
        $cpuSeconds = $engine.TotalProcessorTime.TotalSeconds
        if ($null -ne $lastCpuSeconds) {
            $wallSeconds = [Math]::Max(($nowUtc - $lastSampleUtc).TotalSeconds, 0.001)
            $wholeProcessCpuCoreEquivalentPercent = (
                [Math]::Max($cpuSeconds - $lastCpuSeconds, 0.0) / $wallSeconds
            ) * 100.0
            $wholeProcessCpuPercent = (
                $wholeProcessCpuCoreEquivalentPercent / [Environment]::ProcessorCount
            )
            $samples.Add([pscustomobject]@{
                WholeProcessCpuPercent = $wholeProcessCpuPercent
                WholeProcessCpuCoreEquivalentPercent = $wholeProcessCpuCoreEquivalentPercent
                WorkingMiB = $engine.WorkingSet64 / 1MB
                PrivateMiB = $engine.PrivateMemorySize64 / 1MB
                Threads = $engine.Threads.Count
                Handles = $engine.HandleCount
            })
        }
        $lastCpuSeconds = $cpuSeconds
        $lastSampleUtc = $nowUtc
        Start-Sleep -Milliseconds $ExternalSampleIntervalMs
    }

    if ($null -ne $launcher) {
        $launcher.WaitForExit()
        $launcher.Refresh()
        $launcherExitCode = [int]$launcher.ExitCode
    }

    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
    } else {
        ""
    }
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
    } else {
        ""
    }

    $resultMatch = [regex]::Match(
        $stdout,
        "(?m)^TOWER_DEFENSE_ENEMY_COHORT_RESULT (?<json>\{[^\r\n]+\})\r?$"
    )
    if (-not $resultMatch.Success) {
        Write-Output $stdout
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Error $stderr
        }
        throw "The Godot cohort probe did not emit a result payload."
    }

    $payload = $resultMatch.Groups["json"].Value | ConvertFrom-Json
    $external = [ordered]@{
        engine_pid = $enginePid
        sample_count = $samples.Count
        logical_processor_count = [Environment]::ProcessorCount
        cpu_measurement_scope = "whole_process"
        whole_process_cpu_average_percent = 0.0
        whole_process_cpu_max_percent = 0.0
        whole_process_cpu_core_equivalent_average_percent = 0.0
        whole_process_cpu_core_equivalent_max_percent = 0.0
        working_average_mib = 0.0
        working_max_mib = 0.0
        private_average_mib = 0.0
        private_max_mib = 0.0
        threads_max = 0
        handles_max = 0
    }
    if ($samples.Count -gt 0) {
        $wholeProcessCpu = (
            $samples | Measure-Object WholeProcessCpuPercent -Average -Maximum
        )
        $wholeProcessCpuCoreEquivalent = (
            $samples |
                Measure-Object WholeProcessCpuCoreEquivalentPercent -Average -Maximum
        )
        $working = $samples | Measure-Object WorkingMiB -Average -Maximum
        $private = $samples | Measure-Object PrivateMiB -Average -Maximum
        $threads = $samples | Measure-Object Threads -Maximum
        $handles = $samples | Measure-Object Handles -Maximum
        $external.whole_process_cpu_average_percent = [Math]::Round(
            $wholeProcessCpu.Average,
            3
        )
        $external.whole_process_cpu_max_percent = [Math]::Round(
            $wholeProcessCpu.Maximum,
            3
        )
        $external.whole_process_cpu_core_equivalent_average_percent = [Math]::Round(
            $wholeProcessCpuCoreEquivalent.Average,
            3
        )
        $external.whole_process_cpu_core_equivalent_max_percent = [Math]::Round(
            $wholeProcessCpuCoreEquivalent.Maximum,
            3
        )
        $external.working_average_mib = [Math]::Round($working.Average, 3)
        $external.working_max_mib = [Math]::Round($working.Maximum, 3)
        $external.private_average_mib = [Math]::Round($private.Average, 3)
        $external.private_max_mib = [Math]::Round($private.Maximum, 3)
        $external.threads_max = [int]$threads.Maximum
        $external.handles_max = [int]$handles.Maximum
    }

    $combined = [ordered]@{
        godot = $payload
        external_process = $external
        exit_code = $launcherExitCode
    }
    $combined | ConvertTo-Json -Depth 12 -Compress

    if ($launcherExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Error $stderr
        }
        exit $launcherExitCode
    }
}
finally {
    if ($enginePid -gt 0) {
        $remainingEngine = Get-Process -Id $enginePid -ErrorAction SilentlyContinue
        if ($null -ne $remainingEngine) {
            Stop-Process -Id $enginePid -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $launcher -and -not $launcher.HasExited) {
        Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($tempPath in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}
