param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),

    [int[]]$Seeds = @(20260824, 20260825, 20260826),

    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$probePath = "res://dev_tools/enemy_simulation_semantic_golden_probe.gd"
$modes = @("legacy", "compat_60", "layered_area", "layered_contact")
$expectedTickCount = 150
$activeProcess = $null


function Invoke-SemanticGoldenProbe {
    param(
        [string]$Mode,
        [int]$Seed,
        [string]$ResolvedProjectRoot
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $GodotExe
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "--headless",
        "--path", $ResolvedProjectRoot,
        "--script", $probePath,
        "--",
        "--semantic-mode=$Mode",
        "--semantic-seed=$Seed"
    )) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Unable to start the semantic golden probe."
        }
        $script:activeProcess = $process
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                # The timed-out process may already be exiting.
            }
            $process.WaitForExit(5000) | Out-Null
            throw "Semantic golden probe timed out: mode=$Mode seed=$Seed"
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $match = [regex]::Matches(
            $stdout,
            '(?m)^ENEMY_SIMULATION_SEMANTIC_GOLDEN_JSON (\{[^\r\n]+\})\r?$'
        )
        if ($process.ExitCode -ne 0 -or $match.Count -ne 1) {
            throw (
                "Semantic golden probe failed: mode=$Mode seed=$Seed " +
                "exit=$($process.ExitCode)`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
            )
        }
        $payload = $match[0].Groups[1].Value | ConvertFrom-Json -Depth 50
        if ([string]$payload.status -ne "ok") {
            throw "Semantic golden invariants failed: mode=$Mode seed=$Seed"
        }
        if (
            [string]$payload.mode -cne $Mode -or
            [string]$payload.requested_mode -cne $Mode -or
            [int]$payload.seed -ne $Seed -or
            [int]$payload.tick_count -ne $expectedTickCount -or
            [string]::IsNullOrWhiteSpace([string]$payload.canonical_sha256) -or
            [int]$payload.canonical_line_count -le 0
        ) {
            throw (
                "Semantic golden identity contract failed: requested_mode=$Mode " +
                "probe_requested_mode=$($payload.requested_mode) " +
                "actual_mode=$($payload.mode) requested_seed=$Seed " +
                "actual_seed=$($payload.seed) tick_count=$($payload.tick_count)"
            )
        }
        $runtimeErrors = [regex]::Matches(
            "$stdout`n$stderr",
            '(?m)^(?:SCRIPT ERROR|ERROR):\s+.+$'
        )
        if ($runtimeErrors.Count -gt 0) {
            throw (
                "Semantic golden emitted runtime errors: mode=$Mode seed=$Seed`n" +
                (($runtimeErrors | ForEach-Object { $_.Value }) -join "`n")
            )
        }
        return [pscustomobject][ordered]@{
            mode = [string]$payload.mode
            seed = [int]$payload.seed
            tick_count = [int]$payload.tick_count
            canonical_sha256 = [string]$payload.canonical_sha256
            canonical_line_count = [int]$payload.canonical_line_count
            event_counts = $payload.event_counts
            invariants = $payload.invariants
            transition_events = @($payload.transition_events)
        }
    }
    finally {
        $script:activeProcess = $null
        if (-not $process.HasExited) {
            try {
                $process.Kill($true)
                $process.WaitForExit(5000) | Out-Null
            }
            catch {
                # Best-effort process-scoped cleanup.
            }
        }
        $process.Dispose()
    }
}


if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot executable was not found: $GodotExe"
}
$resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$uniqueSeeds = @($Seeds | Select-Object -Unique)
if ($uniqueSeeds.Count -lt 3) {
    throw "Semantic golden requires at least three unique seeds."
}
$records = [Collections.Generic.List[object]]::new()
$violations = [Collections.Generic.List[object]]::new()

try {
    foreach ($seed in $uniqueSeeds) {
        $seedRecords = [Collections.Generic.List[object]]::new()
        foreach ($mode in $modes) {
            $record = Invoke-SemanticGoldenProbe $mode $seed $resolvedProjectRoot
            $records.Add($record)
            $seedRecords.Add($record)
        }
        $legacy = @($seedRecords | Where-Object { $_.mode -eq "legacy" })[0]
        $legacyCounts = $legacy.event_counts | ConvertTo-Json -Compress -Depth 10
        foreach ($candidate in @($seedRecords | Where-Object { $_.mode -ne "legacy" })) {
            $candidateCounts = $candidate.event_counts | ConvertTo-Json -Compress -Depth 10
            if (
                $candidate.canonical_sha256 -ne $legacy.canonical_sha256 -or
                $candidate.canonical_line_count -ne $legacy.canonical_line_count -or
                $candidateCounts -cne $legacyCounts
            ) {
                $violations.Add([pscustomobject][ordered]@{
                    seed = $seed
                    mode = $candidate.mode
                    code = "semantic_trace_mismatch"
                    legacy_sha256 = $legacy.canonical_sha256
                    candidate_sha256 = $candidate.canonical_sha256
                    legacy_event_counts = $legacy.event_counts
                    candidate_event_counts = $candidate.event_counts
                    legacy_events = $legacy.transition_events
                    candidate_events = $candidate.transition_events
                })
            }
        }
    }
}
finally {
    if ($null -ne $script:activeProcess -and -not $script:activeProcess.HasExited) {
        try {
            $script:activeProcess.Kill($true)
            $script:activeProcess.WaitForExit(5000) | Out-Null
        }
        catch {
            # Best-effort cleanup for an interrupted runner.
        }
    }
}

$passed = $violations.Count -eq 0
$summary = [ordered]@{
    schema_version = 1
    status = if ($passed) { "passed" } else { "failed" }
    modes = $modes
    seeds = $uniqueSeeds
    expected_run_count = $modes.Count * $uniqueSeeds.Count
    completed_run_count = $records.Count
    records = @($records)
    violations = @($violations)
}
$summary | ConvertTo-Json -Compress -Depth 50
if (-not $passed) {
    exit 1
}
exit 0
