param(
    [int]$Runs = 5
)

$ErrorActionPreference = "Stop"
if ($Runs -lt 5) {
    throw "Runs must be at least 5 for an isolated A/B sample."
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$godot = "C:\Program Files\Godot\Godot.exe"
$probe = "res://dev_tools/tower_defense_player_roster_snapshot_ab_probe.gd"
$rows = @()

for ($run = 1; $run -le $Runs; $run++) {
    $armOrder = if ($run % 2 -eq 1) {
        @("baseline", "current")
    } else {
        @("current", "baseline")
    }
    foreach ($mode in $armOrder) {
        $logPath = [System.IO.Path]::GetTempFileName()
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $godot
        $startInfo.Arguments = (
            "--headless --path `"$projectRoot`" --log-file `"$logPath`" " +
            "--script $probe -- --probe-mode=$mode"
        )
        $startInfo.WorkingDirectory = $projectRoot
        $startInfo.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
            $peakWorkingSet = 0L
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not $process.HasExited) {
                if ([DateTime]::UtcNow -ge $deadline) {
                    $process.Kill($true)
                    throw "Probe timed out: mode=$mode run=$run"
                }
                try {
                    $peakWorkingSet = [Math]::Max(
                        $peakWorkingSet,
                        $process.PeakWorkingSet64
                    )
                } catch {
                    # The process may exit between HasExited and the metric read.
                }
                Start-Sleep -Milliseconds 15
            }
            $peakWorkingSet = [Math]::Max($peakWorkingSet, $process.PeakWorkingSet64)
            $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
            $markers = @(
                $log -split "`r?`n" |
                Where-Object { $_ -like "TOWER_PLAYER_ROSTER_AB_OK*" }
            )
            if (
                $process.ExitCode -ne 0 -or
                $markers.Count -ne 1 -or
                $log -match "(?m)^(ERROR|SCRIPT ERROR):"
            ) {
                throw "Probe failed: mode=$mode run=$run exit=$($process.ExitCode)`n$log"
            }
            $line = $markers[0]
            $rows += [pscustomobject]@{
                mode = $mode
                run = $run
                p50_ms = [double]([regex]::Match($line, "p50_ms=([0-9.]+)").Groups[1].Value)
                p95_ms = [double]([regex]::Match($line, "p95_ms=([0-9.]+)").Groups[1].Value)
                peak_mib = [Math]::Round($peakWorkingSet / 1MB, 2)
                cpu_ms = [Math]::Round($process.TotalProcessorTime.TotalMilliseconds, 2)
                trace_hash = [long]([regex]::Match($line, "trace_hash=(-?[0-9]+)").Groups[1].Value)
            }
        } finally {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-Median([double[]]$values) {
    $sorted = @($values | Sort-Object)
    return [double]$sorted[[Math]::Floor($sorted.Count / 2)]
}

$baseline = @($rows | Where-Object mode -eq "baseline")
$current = @($rows | Where-Object mode -eq "current")
$summary = [ordered]@{
    runs_per_arm = $Runs
    trace_hashes = @($rows.trace_hash | Select-Object -Unique)
    baseline_p50_ms = Get-Median @($baseline.p50_ms)
    current_p50_ms = Get-Median @($current.p50_ms)
    baseline_p95_ms = Get-Median @($baseline.p95_ms)
    current_p95_ms = Get-Median @($current.p95_ms)
    baseline_peak_mib = Get-Median @($baseline.peak_mib)
    current_peak_mib = Get-Median @($current.peak_mib)
    baseline_cpu_ms = Get-Median @($baseline.cpu_ms)
    current_cpu_ms = Get-Median @($current.cpu_ms)
    memory_scope = "Snapshot-path allocations only; the stage full-scene baseline covers static-node structural memory."
}
$p50Limit = $summary.baseline_p50_ms + [Math]::Max(
    $summary.baseline_p50_ms * 0.05,
    0.2
)
$p95Limit = $summary.baseline_p95_ms + [Math]::Max(
    $summary.baseline_p95_ms * 0.05,
    0.2
)
$memoryLimit = $summary.baseline_peak_mib + [Math]::Max(
    $summary.baseline_peak_mib * 0.05,
    16.0
)
$summary["p50_limit_ms"] = $p50Limit
$summary["p95_limit_ms"] = $p95Limit
$summary["peak_limit_mib"] = $memoryLimit
$summary["passed"] = (
    $summary.trace_hashes.Count -eq 1 -and
    $summary.current_p50_ms -le $p50Limit -and
    $summary.current_p95_ms -le $p95Limit -and
    $summary.current_peak_mib -le $memoryLimit
)

$rows | Format-Table -AutoSize
[pscustomobject]$summary | ConvertTo-Json -Depth 3
if (-not $summary.passed) {
    exit 1
}
