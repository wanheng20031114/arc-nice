param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",
    [ValidateRange(1, 20)]
    [int]$Repetitions = 3,
    [ValidateNotNullOrEmpty()]
    [int[]]$FlowRadii = @(20, 16, 14),
    [ValidateRange(1, 512)]
    [int]$SourceRadius = 14,
    [switch]$ShowRawOutput
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$flowRadiusEnv = "ARC_NAV_DYNAMIC_FLOW_RADIUS"
$sourceRadiusEnv = "ARC_NAV_SOURCE_RADIUS"
$packedBuildEnv = "ARC_NAV_PACKED_FLOW_BUILD"
$diagnosticPrefix = "WALL_DYNAMIC_FLOW_DIAGNOSTIC radius="
$projectRoot = Split-Path -Parent $PSScriptRoot
$diagnosticScript = "res://dev_tools/game_tower_defense_wall_dynamic_flow_diagnostic.gd"


function Get-RequiredMetricText {
    param(
        [string]$Line,
        [string]$Name
    )

    $pattern = "(?:^|\s)" + [regex]::Escape($Name) + "=(?<value>\S+)"
    $metricMatch = [regex]::Match($Line, $pattern)
    if (-not $metricMatch.Success) {
        throw "Diagnostic output is missing metric '$Name': $Line"
    }
    return $metricMatch.Groups["value"].Value
}


function Get-RequiredIntMetric {
    param(
        [string]$Line,
        [string]$Name
    )

    return [int](Get-RequiredMetricText -Line $Line -Name $Name)
}


function Get-Median {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
        return 0.0
    }
    $sorted = @($Values | Sort-Object)
    $middle = [int][math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}


function Invoke-WallDynamicFlowDiagnostic {
    param(
        [int]$Radius,
        [bool]$Packed,
        [int]$Repetition
    )

    $packedText = $Packed.ToString().ToLowerInvariant()
    [Environment]::SetEnvironmentVariable($flowRadiusEnv, "$Radius", "Process")
    [Environment]::SetEnvironmentVariable($sourceRadiusEnv, "$SourceRadius", "Process")
    [Environment]::SetEnvironmentVariable($packedBuildEnv, $packedText, "Process")

    Write-Host (
        "WALL_DYNAMIC_FLOW_STORAGE_AB_RUN repetition={0} radius={1} source_radius={2} packed={3}" `
        -f $Repetition, $Radius, $SourceRadius, $packedText
    )
    $output = @(
        & $GodotExe `
            --headless `
            --path $projectRoot `
            --script $diagnosticScript 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    $exitCode = $LASTEXITCODE
    $diagnosticLines = @(
        $output | Where-Object { $_.Contains($diagnosticPrefix) }
    )
    if ($ShowRawOutput -or $exitCode -ne 0 -or $diagnosticLines.Count -ne 1) {
        $output | ForEach-Object { Write-Host $_ }
    }
    if ($exitCode -ne 0) {
        throw ((
                "Wall dynamic diagnostic failed with exit code {0} " `
                + "for radius={1}, packed={2}."
            ) -f $exitCode, $Radius, $packedText)
    }
    if ($diagnosticLines.Count -ne 1) {
        throw (
            "Expected exactly one wall diagnostic result for radius={0}, packed={1}; got {2}." `
            -f $Radius, $packedText, $diagnosticLines.Count
        )
    }

    $line = $diagnosticLines[0]
    $reportedPacked = Get-RequiredMetricText -Line $line -Name "packed"
    $result = [pscustomobject]@{
        Repetition = $Repetition
        Radius = Get-RequiredIntMetric -Line $line -Name "radius"
        SourceRadius = Get-RequiredIntMetric -Line $line -Name "source_radius"
        Packed = [bool]::Parse($reportedPacked)
        Cohort = Get-RequiredMetricText -Line $line -Name "cohort"
        Enemies = Get-RequiredIntMetric -Line $line -Name "enemies"
        InitialBuildFrames = Get-RequiredIntMetric -Line $line -Name "initial_build_frames"
        InitialFieldCells = Get-RequiredIntMetric -Line $line -Name "initial_field_cells"
        InitialFieldSignature = Get-RequiredMetricText -Line $line -Name "initial_field_signature"
        InitialRegionCells = Get-RequiredIntMetric -Line $line -Name "initial_region_cells"
        InitialExpansionsTotal = Get-RequiredIntMetric -Line $line -Name "initial_expansions_total"
        InitialUsecTotal = Get-RequiredIntMetric -Line $line -Name "initial_usec_total"
        InitialUsecPeak = Get-RequiredIntMetric -Line $line -Name "initial_usec_peak"
        ReplacementBuildFrames = Get-RequiredIntMetric -Line $line -Name "replacement_frames"
        ReplacementFieldCells = Get-RequiredIntMetric -Line $line -Name "replacement_field_cells"
        ReplacementFieldSignature = Get-RequiredMetricText -Line $line -Name "replacement_field_signature"
        ReplacementRegionCells = Get-RequiredIntMetric -Line $line -Name "replacement_region_cells"
        ReplacementExpansionsTotal = Get-RequiredIntMetric -Line $line -Name "replacement_expansions_total"
        ReplacementUsecTotal = Get-RequiredIntMetric -Line $line -Name "replacement_usec_total"
        ReplacementUsecPeak = Get-RequiredIntMetric -Line $line -Name "replacement_usec_peak"
        ProductionZero = Get-RequiredIntMetric -Line $line -Name "production_zero"
        RecoveredNonzero = Get-RequiredIntMetric -Line $line -Name "recovered_nonzero"
    }
    if ($result.Radius -ne $Radius) {
        throw "Requested radius=$Radius but diagnostic reported radius=$($result.Radius)."
    }
    if ($result.SourceRadius -ne $SourceRadius) {
        throw (
            "Requested source_radius=$SourceRadius but diagnostic reported " `
            + "source_radius=$($result.SourceRadius)."
        )
    }
    if ($result.Packed -ne $Packed) {
        throw "Requested packed=$packedText but diagnostic reported packed=$reportedPacked."
    }
    if (
        $result.ProductionZero -ne 0 `
        -or $result.RecoveredNonzero -ne $result.Enemies
    ) {
        throw ((
                "Navigation liveness gate failed for radius={0}, packed={1}: " `
                + "production_zero={2}, recovered={3}/{4}."
            ) -f (
                $Radius,
                $packedText,
                $result.ProductionZero,
                $result.RecoveredNonzero,
                $result.Enemies
            ))
    }
    return $result
}


if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot console executable was not found: $GodotExe"
}
$FlowRadii = @($FlowRadii | Select-Object -Unique)
if ($FlowRadii.Count -eq 0) {
    throw "At least one flow radius is required."
}
foreach ($radius in $FlowRadii) {
    if ($radius -lt 1) {
        throw "Flow radii must be positive; got $radius."
    }
}
$minimumFlowRadius = [int](($FlowRadii | Measure-Object -Minimum).Minimum)
if ($SourceRadius -le 12) {
    throw "SourceRadius must exceed the diagnostic's 12-cell minimum source distance."
}
if ($SourceRadius -gt $minimumFlowRadius) {
    throw (
        "SourceRadius=$SourceRadius exceeds the smallest flow radius=$minimumFlowRadius. " `
        + "Use one fixed cohort that fits every compared local field."
    )
}

$environmentNames = @($flowRadiusEnv, $sourceRadiusEnv, $packedBuildEnv)
$previousEnvironment = @{}
foreach ($name in $environmentNames) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        "Process"
    )
}

$results = @()
try {
    for ($repetition = 1; $repetition -le $Repetitions; $repetition += 1) {
        $orderedRadii = @($FlowRadii)
        if (($repetition % 2) -eq 0) {
            [array]::Reverse($orderedRadii)
        }
        for ($radiusIndex = 0; $radiusIndex -lt $orderedRadii.Count; $radiusIndex += 1) {
            $radius = [int]$orderedRadii[$radiusIndex]
            $packedOrder = @($false, $true)
            if ((($repetition + $radiusIndex) % 2) -eq 0) {
                $packedOrder = @($true, $false)
            }
            foreach ($packed in $packedOrder) {
                $results += Invoke-WallDynamicFlowDiagnostic `
                    -Radius $radius `
                    -Packed $packed `
                    -Repetition $repetition
            }
        }
    }
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $previousEnvironment[$name],
            "Process"
        )
    }
}

$expectedResultCount = $Repetitions * $FlowRadii.Count * 2
if ($results.Count -ne $expectedResultCount) {
    throw "Expected $expectedResultCount results but collected $($results.Count)."
}
$cohorts = @($results | Select-Object -ExpandProperty Cohort -Unique)
$enemyCounts = @($results | Select-Object -ExpandProperty Enemies -Unique)
if ($cohorts.Count -ne 1 -or $enemyCounts.Count -ne 1) {
    throw (
        "A/B cases did not retain one fixed cohort: cohorts={0}, enemy_counts={1}." `
        -f ($cohorts -join ","), ($enemyCounts -join ",")
    )
}
foreach ($radius in $FlowRadii) {
    for ($repetition = 1; $repetition -le $Repetitions; $repetition += 1) {
        $pair = @(
            $results | Where-Object {
                $_.Radius -eq $radius -and $_.Repetition -eq $repetition
            }
        )
        if ($pair.Count -ne 2) {
            throw "Expected one packed on/off pair for radius=$radius repetition=$repetition."
        }
        $legacy = @($pair | Where-Object { -not $_.Packed })[0]
        $packed = @($pair | Where-Object { $_.Packed })[0]
        $equivalentMetrics = @(
            "InitialFieldCells",
            "InitialFieldSignature",
            "InitialRegionCells",
            "InitialExpansionsTotal",
            "ReplacementFieldCells",
            "ReplacementFieldSignature",
            "ReplacementRegionCells",
            "ReplacementExpansionsTotal"
        )
        foreach ($metric in $equivalentMetrics) {
            if ($legacy.$metric -ne $packed.$metric) {
                throw ((
                        "Packed storage changed semantic work at radius={0}, repetition={1}: " `
                        + "{2} legacy={3} packed={4}."
                    ) -f (
                        $radius,
                        $repetition,
                        $metric,
                        $legacy.$metric,
                        $packed.$metric
                    ))
            }
        }
    }
}

$summaries = @()
foreach ($group in ($results | Group-Object Radius, Packed)) {
    $first = $group.Group[0]
    $initialUsec = @($group.Group | ForEach-Object { [double]$_.InitialUsecTotal })
    $replacementUsec = @(
        $group.Group | ForEach-Object { [double]$_.ReplacementUsecTotal }
    )
    $totalUsec = @(
        $group.Group |
            ForEach-Object {
                [double]($_.InitialUsecTotal + $_.ReplacementUsecTotal)
            }
    )
    $summaries += [pscustomobject]@{
        Radius = $first.Radius
        Packed = $first.Packed
        Runs = $group.Count
        Enemies = $first.Enemies
        InitialFieldCells = Get-Median @(
            $group.Group | ForEach-Object { [double]$_.InitialFieldCells }
        )
        ReplacementFieldCells = Get-Median @(
            $group.Group | ForEach-Object { [double]$_.ReplacementFieldCells }
        )
        InitialFramesP50 = Get-Median @(
            $group.Group | ForEach-Object { [double]$_.InitialBuildFrames }
        )
        ReplacementFramesP50 = Get-Median @(
            $group.Group | ForEach-Object { [double]$_.ReplacementBuildFrames }
        )
        InitialExpansionsP50 = Get-Median @(
            $group.Group | ForEach-Object { [double]$_.InitialExpansionsTotal }
        )
        ReplacementExpansionsP50 = Get-Median @(
            $group.Group | ForEach-Object { [double]$_.ReplacementExpansionsTotal }
        )
        InitialUsecP50 = Get-Median $initialUsec
        ReplacementUsecP50 = Get-Median $replacementUsec
        TotalUsecP50 = Get-Median $totalUsec
        InitialPeakUsecMax = [int](
            ($group.Group | Measure-Object -Property InitialUsecPeak -Maximum).Maximum
        )
        ReplacementPeakUsecMax = [int](
            ($group.Group | Measure-Object -Property ReplacementUsecPeak -Maximum).Maximum
        )
    }
}

$summaries = @($summaries | Sort-Object Radius, Packed)
foreach ($summary in $summaries) {
    Write-Host ((
            "WALL_DYNAMIC_FLOW_STORAGE_AB_SUMMARY " `
            + "radius={0} packed={1} runs={2} enemies={3} " `
            + "initial_field_cells_p50={4:F0} replacement_field_cells_p50={5:F0} " `
            + "initial_frames_p50={6:F1} replacement_frames_p50={7:F1} " `
            + "initial_expansions_p50={8:F0} replacement_expansions_p50={9:F0} " `
            + "initial_usec_p50={10:F1} replacement_usec_p50={11:F1} " `
            + "total_usec_p50={12:F1} initial_peak_usec_max={13} " `
            + "replacement_peak_usec_max={14}"
        ) -f (
            $summary.Radius,
            $summary.Packed.ToString().ToLowerInvariant(),
            $summary.Runs,
            $summary.Enemies,
            $summary.InitialFieldCells,
            $summary.ReplacementFieldCells,
            $summary.InitialFramesP50,
            $summary.ReplacementFramesP50,
            $summary.InitialExpansionsP50,
            $summary.ReplacementExpansionsP50,
            $summary.InitialUsecP50,
            $summary.ReplacementUsecP50,
            $summary.TotalUsecP50,
            $summary.InitialPeakUsecMax,
            $summary.ReplacementPeakUsecMax
        ))
}

foreach ($radius in ($FlowRadii | Sort-Object -Descending)) {
    $legacy = @(
        $summaries | Where-Object { $_.Radius -eq $radius -and -not $_.Packed }
    )
    $packed = @(
        $summaries | Where-Object { $_.Radius -eq $radius -and $_.Packed }
    )
    if ($legacy.Count -ne 1 -or $packed.Count -ne 1) {
        throw "Missing packed on/off pair for radius=$radius."
    }
    $initialSpeedup = (
        $legacy.InitialUsecP50 / [math]::Max($packed.InitialUsecP50, 1.0)
    )
    $replacementSpeedup = (
        $legacy.ReplacementUsecP50 / [math]::Max($packed.ReplacementUsecP50, 1.0)
    )
    $totalSpeedup = $legacy.TotalUsecP50 / [math]::Max($packed.TotalUsecP50, 1.0)
    Write-Host ((
            "WALL_DYNAMIC_FLOW_STORAGE_AB_COMPARISON " `
            + "radius={0} legacy_total_usec_p50={1:F1} packed_total_usec_p50={2:F1} " `
            + "initial_speedup={3:F3}x replacement_speedup={4:F3}x " `
            + "total_speedup={5:F3}x"
        ) -f (
            $radius,
            $legacy.TotalUsecP50,
            $packed.TotalUsecP50,
            $initialSpeedup,
            $replacementSpeedup,
            $totalSpeedup
        ))
}

Write-Host ((
        "WALL_DYNAMIC_FLOW_STORAGE_AB_OK radii={0} source_radius={1} " `
        + "repetitions={2} cohort={3} enemies={4}"
    ) -f (
        ($FlowRadii -join ","),
        $SourceRadius,
        $Repetitions,
        $cohorts[0],
        $enemyCounts[0]
    ))
exit 0
