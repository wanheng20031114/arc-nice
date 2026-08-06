param(
    [string]$GodotPath = "C:\Program Files\Godot\Godot.exe",
    [int]$RoundCount = 5
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$absoluteToleranceUsec = 200
$absoluteToleranceBytes = 16MB
if ($RoundCount -lt 5) {
    throw "Standard Merchant isolated A/B requires at least five rounds."
}

function Invoke-StandardMerchantArm {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("legacy", "extracted")]
        [string]$Arm
    )

    $process = $null
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $GodotPath
        $startInfo.Arguments = (
            "--headless --path `"{0}`" --script res://dev_tools/standard_merchant_coordinator_ab_probe.gd -- --arm={1}" `
            -f $projectRoot, $Arm
        )
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Unable to start Standard Merchant $Arm arm."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [long]$peakWorkingSetBytes = 0
        while (-not $process.HasExited) {
            $process.Refresh()
            try {
                $peakWorkingSetBytes = [Math]::Max(
                    $peakWorkingSetBytes,
                    [long]$process.WorkingSet64
                )
            } catch [System.InvalidOperationException] {
                break
            }
            Start-Sleep -Milliseconds 10
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
        if ($exitCode -ne 0) {
            throw "Standard Merchant $Arm arm failed with exit $exitCode`: $stdout $stderr"
        }
        $markerPattern = (
            "STANDARD_MERCHANT_COORDINATOR_AB_ARM_OK arm=(legacy|extracted) p50_usec=(\d+) p95_usec=(\d+) trajectory_hash=(-?\d+)"
        )
        $markerMatches = [regex]::Matches($stdout, $markerPattern)
        $badCount = [regex]::Matches(
            "$stdout`n$stderr",
            "(?m)^(?:SCRIPT ERROR|ERROR):"
        ).Count
        if ($badCount -ne 0) {
            throw "Standard Merchant $Arm arm emitted $badCount error markers: $stdout $stderr"
        }
        if ($markerMatches.Count -ne 1) {
            throw "Standard Merchant $Arm arm emitted $($markerMatches.Count) success markers: $stdout $stderr"
        }
        $match = $markerMatches[0]
        return [pscustomobject]@{
            Arm = $Arm
            P50Usec = [int]$match.Groups[2].Value
            P95Usec = [int]$match.Groups[3].Value
            TrajectoryHash = [int64]$match.Groups[4].Value
            PeakWorkingSetBytes = $peakWorkingSetBytes
            ExitCode = $exitCode
            MarkerCount = $markerMatches.Count
            BadCount = $badCount
        }
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-Median {
    param([long[]]$Values)
    $sorted = @($Values | Sort-Object)
    return [long]$sorted[[Math]::Floor($sorted.Count / 2)]
}

function Get-P95 {
    param([long[]]$Values)
    $sorted = @($Values | Sort-Object)
    return [long]$sorted[$sorted.Count - 1]
}

$legacyResults = @()
$extractedResults = @()
for ($round = 1; $round -le $RoundCount; $round++) {
    if ($round % 2 -eq 1) {
        $legacy = Invoke-StandardMerchantArm -Arm legacy
        $extracted = Invoke-StandardMerchantArm -Arm extracted
    } else {
        $extracted = Invoke-StandardMerchantArm -Arm extracted
        $legacy = Invoke-StandardMerchantArm -Arm legacy
    }
    if ($legacy.TrajectoryHash -ne $extracted.TrajectoryHash) {
        throw "Round $round trajectory hash mismatch: legacy=$($legacy.TrajectoryHash) extracted=$($extracted.TrajectoryHash)"
    }
    $legacyResults += $legacy
    $extractedResults += $extracted
    Write-Output (
        "STANDARD_MERCHANT_COORDINATOR_ISOLATED_AB_SAMPLE round={0} legacy_p50_usec={1} extracted_p50_usec={2} legacy_p95_usec={3} extracted_p95_usec={4} legacy_peak_bytes={5} extracted_peak_bytes={6} trajectory_hash={7} marker=1 bad=0 exit=0" `
        -f $round,
        $legacy.P50Usec,
        $extracted.P50Usec,
        $legacy.P95Usec,
        $extracted.P95Usec,
        $legacy.PeakWorkingSetBytes,
        $extracted.PeakWorkingSetBytes,
        $legacy.TrajectoryHash
    )
}

[long]$legacyP50Usec = Get-Median -Values @($legacyResults.P50Usec)
[long]$extractedP50Usec = Get-Median -Values @($extractedResults.P50Usec)
[long]$legacyP95Usec = Get-P95 -Values @($legacyResults.P95Usec)
[long]$extractedP95Usec = Get-P95 -Values @($extractedResults.P95Usec)
[long]$legacyP50Bytes = Get-Median -Values @($legacyResults.PeakWorkingSetBytes)
[long]$extractedP50Bytes = Get-Median -Values @($extractedResults.PeakWorkingSetBytes)
[long]$legacyP95Bytes = Get-P95 -Values @($legacyResults.PeakWorkingSetBytes)
[long]$extractedP95Bytes = Get-P95 -Values @($extractedResults.PeakWorkingSetBytes)
[long]$p50ToleranceUsec = [Math]::Max(
    [long][Math]::Ceiling($legacyP50Usec * 0.05),
    [long]$absoluteToleranceUsec
)
[long]$p95ToleranceUsec = [Math]::Max(
    [long][Math]::Ceiling($legacyP95Usec * 0.05),
    [long]$absoluteToleranceUsec
)
[long]$p50LimitUsec = $legacyP50Usec + $p50ToleranceUsec
[long]$p95LimitUsec = $legacyP95Usec + $p95ToleranceUsec
[long]$p50ToleranceBytes = [Math]::Max(
    [long][Math]::Ceiling($legacyP50Bytes * 0.05),
    [long]$absoluteToleranceBytes
)
[long]$p95ToleranceBytes = [Math]::Max(
    [long][Math]::Ceiling($legacyP95Bytes * 0.05),
    [long]$absoluteToleranceBytes
)
[long]$p50LimitBytes = $legacyP50Bytes + $p50ToleranceBytes
[long]$p95LimitBytes = $legacyP95Bytes + $p95ToleranceBytes
if ($extractedP50Usec -gt $p50LimitUsec) {
    throw "Extracted p50 duration exceeds limit: legacy=$legacyP50Usec extracted=$extractedP50Usec limit=$p50LimitUsec"
}
if ($extractedP95Usec -gt $p95LimitUsec) {
    throw "Extracted p95 duration exceeds limit: legacy=$legacyP95Usec extracted=$extractedP95Usec limit=$p95LimitUsec"
}
if ($extractedP50Bytes -gt $p50LimitBytes) {
    throw "Extracted p50 peak working set exceeds limit: legacy=$legacyP50Bytes extracted=$extractedP50Bytes limit=$p50LimitBytes"
}
if ($extractedP95Bytes -gt $p95LimitBytes) {
    throw "Extracted p95 peak working set exceeds limit: legacy=$legacyP95Bytes extracted=$extractedP95Bytes limit=$p95LimitBytes"
}

Write-Output (
    "STANDARD_MERCHANT_COORDINATOR_ISOLATED_AB_PROBE_OK rounds={0} legacy_p50_usec={1} extracted_p50_usec={2} legacy_p95_usec={3} extracted_p95_usec={4} p50_limit_usec={5} p95_limit_usec={6} legacy_p50_bytes={7} extracted_p50_bytes={8} legacy_p95_bytes={9} extracted_p95_bytes={10} p50_limit_bytes={11} p95_limit_bytes={12}" `
    -f $RoundCount,
    $legacyP50Usec,
    $extractedP50Usec,
    $legacyP95Usec,
    $extractedP95Usec,
    $p50LimitUsec,
    $p95LimitUsec,
    $legacyP50Bytes,
    $extractedP50Bytes,
    $legacyP95Bytes,
    $extractedP95Bytes,
    $p50LimitBytes,
    $p95LimitBytes
)
