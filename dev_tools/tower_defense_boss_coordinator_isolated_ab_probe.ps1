param(
    [Parameter(Mandatory = $true)]
    [string]$BaselinePath,
    [string]$CurrentPath = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(3, 5)]
    [int]$Rounds = 3
)

$ErrorActionPreference = "Stop"
$ExpectedBaseline = "b08bdeeb1a9faf2922d078f28c9dc01c3a368413"
$ProbePath = Join-Path $CurrentPath "dev_tools\tower_defense_boss_coordinator_ab_probe.gd"
$GodotPath = (Get-Command Godot.exe).Source

if (-not (Test-Path -LiteralPath $BaselinePath -PathType Container)) {
    throw "Baseline worktree does not exist: $BaselinePath"
}
if (-not (Test-Path -LiteralPath $ProbePath -PathType Leaf)) {
    throw "Boss A/B probe does not exist: $ProbePath"
}
$BaselineHead = (git -C $BaselinePath rev-parse HEAD).Trim()
if ($BaselineHead -ne $ExpectedBaseline) {
    throw "Unexpected baseline HEAD: $BaselineHead"
}

function Invoke-BossProbe {
    param(
        [string]$Label,
        [string]$ProjectPath
    )
    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $GodotPath
    $StartInfo.WorkingDirectory = $ProjectPath
    $StartInfo.UseShellExecute = $false
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.Arguments = (
        "--headless --path `"$ProjectPath`" --script `"$ProbePath`""
    )
    $Process = [System.Diagnostics.Process]::Start($StartInfo)
    try {
        $StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
        $StandardErrorTask = $Process.StandardError.ReadToEndAsync()
        $PeakWorkingSetBytes = 0L
        $CpuMilliseconds = 0.0
        $TimedOut = $false
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            while (
                -not $Process.HasExited -or
                -not $StandardOutputTask.IsCompleted -or
                -not $StandardErrorTask.IsCompleted
            ) {
                if (-not $Process.HasExited) {
                    $Process.Refresh()
                    $PeakWorkingSetBytes = [math]::Max(
                        $PeakWorkingSetBytes,
                        $Process.PeakWorkingSet64
                    )
                    $CpuMilliseconds = [math]::Max(
                        $CpuMilliseconds,
                        $Process.TotalProcessorTime.TotalMilliseconds
                    )
                }
                if ($Stopwatch.Elapsed.TotalSeconds -gt 45.0) {
                    $TimedOut = $true
                    break
                }
                Start-Sleep -Milliseconds 20
            }
        }
        finally {
            if (-not $Process.HasExited) {
                $Process.Kill()
                $Process.WaitForExit()
            }
        }
        $Process.WaitForExit()
        $StandardOutput = $StandardOutputTask.Result
        $StandardError = $StandardErrorTask.Result
        $CombinedOutput = $StandardOutput + "`n" + $StandardError
        if ($TimedOut) {
            throw "$Label probe exceeded the 45-second timeout."
        }
        if (
            $Process.ExitCode -ne 0 -or
            $CombinedOutput -match "SCRIPT ERROR|Parse Error|Failed to load script|(?m)^ERROR:" -or
            $CombinedOutput -notmatch "TOWER_DEFENSE_BOSS_COORDINATOR_AB_PROBE_OK"
        ) {
            throw "$Label probe failed with exit code $($Process.ExitCode):`n$CombinedOutput"
        }
        $HashMatch = [regex]::Match(
            $CombinedOutput,
            "TOWER_BOSS_AB_HASH=([0-9a-f]{64})"
        )
        if (-not $HashMatch.Success) {
            throw "$Label probe did not emit a trace hash."
        }
        return [pscustomobject]@{
            Label = $Label
            Hash = $HashMatch.Groups[1].Value
            CpuMs = [math]::Round($CpuMilliseconds, 3)
            PeakWorkingSetMiB = [math]::Round($PeakWorkingSetBytes / 1MB, 3)
            FixedRefCountedExitNoise = $CombinedOutput -match "ObjectDB instances leaked at exit"
        }
    }
    finally {
        if (-not $Process.HasExited) {
            $Process.Kill()
            $Process.WaitForExit()
        }
        $Process.Dispose()
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )
    $Sorted = @($Values | Sort-Object)
    $Index = [math]::Ceiling($Percentile * $Sorted.Count) - 1
    return $Sorted[[math]::Max(0, $Index)]
}

$BaselineResults = @()
$CurrentResults = @()
for ($Round = 1; $Round -le $Rounds; $Round++) {
    if ($Round % 2 -eq 1) {
        $BaselineResults += Invoke-BossProbe "baseline-$Round" $BaselinePath
        $CurrentResults += Invoke-BossProbe "current-$Round" $CurrentPath
    }
    else {
        $CurrentResults += Invoke-BossProbe "current-$Round" $CurrentPath
        $BaselineResults += Invoke-BossProbe "baseline-$Round" $BaselinePath
    }
}

$AllHashes = @($BaselineResults.Hash + $CurrentResults.Hash | Select-Object -Unique)
if ($AllHashes.Count -ne 1) {
    throw "Boss behavior trace mismatch: $($AllHashes -join ', ')"
}
$BaselineCpu = [double[]]$BaselineResults.CpuMs
$CurrentCpu = [double[]]$CurrentResults.CpuMs
$BaselineMemory = [double[]]$BaselineResults.PeakWorkingSetMiB
$CurrentMemory = [double[]]$CurrentResults.PeakWorkingSetMiB
$BaselineCpuP50 = Get-Percentile $BaselineCpu 0.50
$BaselineCpuP95 = Get-Percentile $BaselineCpu 0.95
$CurrentCpuP50 = Get-Percentile $CurrentCpu 0.50
$CurrentCpuP95 = Get-Percentile $CurrentCpu 0.95
$BaselineMemoryP50 = Get-Percentile $BaselineMemory 0.50
$BaselineMemoryP95 = Get-Percentile $BaselineMemory 0.95
$CurrentMemoryP50 = Get-Percentile $CurrentMemory 0.50
$CurrentMemoryP95 = Get-Percentile $CurrentMemory 0.95
$CpuP50Budget = [math]::Max($BaselineCpuP50 * 0.05, 0.2)
$CpuP95Budget = [math]::Max($BaselineCpuP95 * 0.05, 0.2)
$MemoryP50Budget = [math]::Max($BaselineMemoryP50 * 0.05, 16.0)
$MemoryP95Budget = [math]::Max($BaselineMemoryP95 * 0.05, 16.0)
$CpuP50Passed = $CurrentCpuP50 -le ($BaselineCpuP50 + $CpuP50Budget)
$CpuP95Passed = $CurrentCpuP95 -le ($BaselineCpuP95 + $CpuP95Budget)
$MemoryP50Passed = $CurrentMemoryP50 -le ($BaselineMemoryP50 + $MemoryP50Budget)
$MemoryP95Passed = $CurrentMemoryP95 -le ($BaselineMemoryP95 + $MemoryP95Budget)
$ExitNoiseSymmetric = (
    @($BaselineResults.FixedRefCountedExitNoise | Select-Object -Unique).Count -eq 1 -and
    @($CurrentResults.FixedRefCountedExitNoise | Select-Object -Unique).Count -eq 1 -and
    $BaselineResults[0].FixedRefCountedExitNoise -eq
        $CurrentResults[0].FixedRefCountedExitNoise
)
$Summary = [ordered]@{
    rounds = $Rounds
    trace_hash = $AllHashes[0]
    baseline_cpu_ms = $BaselineCpu
    current_cpu_ms = $CurrentCpu
    baseline_cpu_p50_ms = $BaselineCpuP50
    baseline_cpu_p95_ms = $BaselineCpuP95
    current_cpu_p50_ms = $CurrentCpuP50
    current_cpu_p95_ms = $CurrentCpuP95
    baseline_peak_working_set_mib = $BaselineMemory
    current_peak_working_set_mib = $CurrentMemory
    baseline_peak_working_set_p50_mib = $BaselineMemoryP50
    baseline_peak_working_set_p95_mib = $BaselineMemoryP95
    current_peak_working_set_p50_mib = $CurrentMemoryP50
    current_peak_working_set_p95_mib = $CurrentMemoryP95
    baseline_fixed_refcounted_exit_noise = @(
        $BaselineResults.FixedRefCountedExitNoise
    )
    current_fixed_refcounted_exit_noise = @(
        $CurrentResults.FixedRefCountedExitNoise
    )
    cpu_p50_budget_ms = $CpuP50Budget
    cpu_p95_budget_ms = $CpuP95Budget
    memory_p50_budget_mib = $MemoryP50Budget
    memory_p95_budget_mib = $MemoryP95Budget
    cpu_p50_passed = $CpuP50Passed
    cpu_p95_passed = $CpuP95Passed
    memory_p50_passed = $MemoryP50Passed
    memory_p95_passed = $MemoryP95Passed
    fixed_exit_noise_symmetric = $ExitNoiseSymmetric
}
$Summary | ConvertTo-Json -Depth 4
if (
    -not $CpuP50Passed -or
    -not $CpuP95Passed -or
    -not $MemoryP50Passed -or
    -not $MemoryP95Passed -or
    -not $ExitNoiseSymmetric
) {
    throw "Boss A/B performance or fixed-noise gate failed."
}
