param(
    [string]$EnemyConfig = "res://resources/config/enemies/yuanshi_insect_basic.tres",

    [string]$WaveConfig = "",

    [ValidateSet("approach", "engagement", "burst", "boss")]
    [string]$Phase = "approach",

    [ValidateRange(0, 5000)]
    [int]$EnemyCount = 300,

    [ValidateSet(
        "custom",
        "first_night_main",
        "critical_300",
        "basic_pursuit_300",
        "tower_projectile_96",
        "faction_battle_150v150",
        "obstacle_water_unreachable",
        "host_client_proxy_1000"
    )]
    [string]$ScenarioId = "custom",

    [ValidateSet("project", "legacy", "compat_60", "layered_area", "layered_contact")]
    [string]$SimulationMode = "project",

    [bool]$AuthoritativeTickSampling = $false,

    [bool]$DetailedSemanticEvidence = $false,

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

    [ValidateSet("diagnostic", "cpu60", "window60", "wave60")]
    [string]$GateProfile = "diagnostic",

    [bool]$QuickValidation = $false,

    [ValidateRange(0.0, 1000.0)]
    [double]$WallP95BudgetMs = (1000.0 / 60.0),

    [ValidateRange(0.0, 1000.0)]
    [double]$WallP99BudgetMs = (1000.0 / 30.0),

    [ValidateRange(0.0, 1.0)]
    [double]$Over18RatioBudget = 0.05,

    [ValidateRange(0.0, 1.0)]
    [double]$Over33RatioBudget = 0.005,

    [ValidateSet("project", "disabled", "enabled")]
    [string]$VsyncMode = "project",

    [ValidateSet("", "gl_compatibility", "mobile", "forward_plus")]
    [string]$RenderingMethod = "",

    [ValidateSet("", "opengl3", "vulkan", "d3d12")]
    [string]$RenderingDriver = "",

    [string]$WindowSize = "",

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

    [bool]$EnemyAttackAudioLimiter = $true,

    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),

    [ValidateRange(100, 5000)]
    [int]$ExternalSampleIntervalMs = 250,

    [ValidateRange(3, 10000)]
    [int]$MinimumExternalSamples = 3,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 180,

    [ValidatePattern('^[A-Za-z0-9_-]*$')]
    [string]$InvocationToken = ""
)

$ErrorActionPreference = "Stop"
$probeScript = "res://dev_tools/tower_defense_enemy_cohort_performance_probe.gd"
$ScenarioId = $ScenarioId.ToLowerInvariant()
$SimulationMode = $SimulationMode.ToLowerInvariant()
$formalScenarioIds = @(
    "first_night_main",
    "critical_300",
    "basic_pursuit_300",
    "tower_projectile_96",
    "faction_battle_150v150",
    "obstacle_water_unreachable",
    "host_client_proxy_1000"
)
$formalScenarioPhaseById = @{
    first_night_main = "approach"
    critical_300 = "approach"
    basic_pursuit_300 = "approach"
    tower_projectile_96 = "engagement"
    faction_battle_150v150 = "engagement"
    obstacle_water_unreachable = "approach"
    host_client_proxy_1000 = "approach"
}

function Get-NearestRankValue {
    param(
        [object[]]$Values,
        [ValidateRange(0.0, 1.0)]
        [double]$Percentile
    )

    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) {
        return 0.0
    }
    $rank = [Math]::Ceiling($Percentile * $ordered.Count)
    $index = [Math]::Max([Math]::Min($rank - 1, $ordered.Count - 1), 0)
    return [double]$ordered[$index]
}

function Get-OptionalPropertyValue {
    param(
        [object]$InputObject,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $DefaultValue
    }
    return $property.Value
}

function Test-FormalRandomStateBoundary {
    param(
        [object]$Boundary,
        [int]$ExpectedSeed,
        [int]$ExpectedEnemyCount,
        [int]$ExpectedCornCount,
        [int]$ExpectedAgaveCount
    )

    if (
        $null -eq $Boundary -or
        -not [bool](Get-OptionalPropertyValue `
            $Boundary `
            "determinized_after_ready" `
            $false) -or
        [int](Get-OptionalPropertyValue $Boundary "requested_seed" -1) -ne
            $ExpectedSeed
    ) {
        return $false
    }
    $runtime = Get-OptionalPropertyValue $Boundary "runtime" $null
    $fate = Get-OptionalPropertyValue $Boundary "fate_coordinator" $null
    $fateManager = Get-OptionalPropertyValue $Boundary "fate_manager" $null
    if (
        [long](Get-OptionalPropertyValue $runtime "seed" ([long]-1)) -ne
            [long]$ExpectedSeed -or
        [long](Get-OptionalPropertyValue $fate "seed" ([long]-1)) -ne
            ([long]$ExpectedSeed + 2000000L) -or
        [long](Get-OptionalPropertyValue $fateManager "seed" ([long]-1)) -ne
            ([long]$ExpectedSeed + 2000001L) -or
        $null -eq (Get-OptionalPropertyValue $runtime "state" $null) -or
        $null -eq (Get-OptionalPropertyValue $fate "state" $null) -or
        $null -eq (Get-OptionalPropertyValue $fateManager "state" $null)
    ) {
        return $false
    }
    $behaviorStates = @(
        Get-OptionalPropertyValue $Boundary "enemy_behavior_states" @()
    )
    $dropStates = @(Get-OptionalPropertyValue $Boundary "enemy_drop_states" @())
    $cornStates = @(Get-OptionalPropertyValue $Boundary "corn_idle_states" @())
    $agaveStates = @(Get-OptionalPropertyValue $Boundary "agave_idle_states" @())
    if (
        $behaviorStates.Count -ne $ExpectedEnemyCount -or
        $dropStates.Count -ne $ExpectedEnemyCount -or
        $cornStates.Count -ne $ExpectedCornCount -or
        $agaveStates.Count -ne $ExpectedAgaveCount
    ) {
        return $false
    }
    for ($index = 0; $index -lt $ExpectedEnemyCount; $index += 1) {
        if (
            [int](Get-OptionalPropertyValue $behaviorStates[$index] "index" -1) -ne
                $index -or
            [long](Get-OptionalPropertyValue $behaviorStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$index * 2L) -or
            $null -eq (Get-OptionalPropertyValue `
                $behaviorStates[$index] `
                "state" `
                $null) -or
            [int](Get-OptionalPropertyValue $dropStates[$index] "index" -1) -ne
                $index -or
            [long](Get-OptionalPropertyValue $dropStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$index * 2L + 1L) -or
            $null -eq (Get-OptionalPropertyValue $dropStates[$index] "state" $null)
        ) {
            return $false
        }
    }
    for ($index = 0; $index -lt $ExpectedCornCount; $index += 1) {
        if (
            [int](Get-OptionalPropertyValue $cornStates[$index] "index" -1) -ne
                $index -or
            [long](Get-OptionalPropertyValue $cornStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$index) -or
            $null -eq (Get-OptionalPropertyValue $cornStates[$index] "state" $null)
        ) {
            return $false
        }
    }
    for ($index = 0; $index -lt $ExpectedAgaveCount; $index += 1) {
        if (
            [int](Get-OptionalPropertyValue $agaveStates[$index] "index" -1) -ne
                $index -or
            [long](Get-OptionalPropertyValue $agaveStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$ExpectedCornCount + [long]$index) -or
            $null -eq (Get-OptionalPropertyValue $agaveStates[$index] "state" $null)
        ) {
            return $false
        }
    }
    return $true
}

function Test-ClientProxyAuthorityBoundary {
    param([object]$Boundary)

    return (
        $null -ne $Boundary -and
        [int](Get-OptionalPropertyValue $Boundary "proxy_count" -1) -eq 1000 -and
        [int](Get-OptionalPropertyValue $Boundary "network_count" -1) -eq 1000 -and
        [int](Get-OptionalPropertyValue $Boundary "index_count" -1) -eq 1000 -and
        [int](Get-OptionalPropertyValue $Boundary "proxy_true_count" -1) -eq 1000 -and
        [int](Get-OptionalPropertyValue $Boundary "process_disabled_count" -1) -eq 1000 -and
        [int](Get-OptionalPropertyValue `
            $Boundary `
            "physics_process_disabled_count" `
            -1) -eq 1000 -and
        [int](Get-OptionalPropertyValue $Boundary "area_count" -1) -gt 0 -and
        [int](Get-OptionalPropertyValue $Boundary "monitoring_area_count" -1) -eq 0 -and
        [int](Get-OptionalPropertyValue `
            $Boundary `
            "simulation_registered_count" `
            -1) -eq 0 -and
        [int](Get-OptionalPropertyValue `
            $Boundary `
            "contact_registered_count" `
            -1) -eq 0 -and
        [int](Get-OptionalPropertyValue `
            $Boundary `
            "authoritative_attack_state_count" `
            -1) -eq 0 -and
        [int](Get-OptionalPropertyValue `
            $Boundary `
            "authoritative_damage_state_count" `
            -1) -eq 0 -and
        [int](Get-OptionalPropertyValue $Boundary "dead_count" -1) -eq 0 -and
        [int](Get-OptionalPropertyValue $Boundary "pending_reward" -1) -eq 0 -and
        -not [bool](Get-OptionalPropertyValue $Boundary "reward_flush_queued" $true)
    )
}

function New-ProcessPerformanceCounterSet {
    param(
        [string]$CategoryName,
        [string]$CounterName,
        [int]$ProcessId,
        [string]$InstancePattern = "*"
    )

    $result = [Collections.Generic.List[object]]::new()
    try {
        $category = [Diagnostics.PerformanceCounterCategory]::new($CategoryName)
        $pidPrefix = "pid_{0}_" -f $ProcessId
        foreach ($instanceName in $category.GetInstanceNames()) {
            if (
                -not $instanceName.StartsWith($pidPrefix) -or
                $instanceName -notlike $InstancePattern
            ) {
                continue
            }
            $counter = [Diagnostics.PerformanceCounter]::new(
                $CategoryName,
                $CounterName,
                $instanceName,
                $true
            )
            $null = $counter.NextValue()
            $result.Add($counter)
        }
    }
    catch {
        foreach ($counter in $result) {
            $counter.Dispose()
        }
        $result.Clear()
    }
    return $result
}

function Get-PerformanceCounterSetTotal {
    param([object[]]$Counters)

    $total = 0.0
    foreach ($counter in $Counters) {
        try {
            $total += [double]$counter.NextValue()
        }
        catch {
            continue
        }
    }
    return $total
}

function Get-ProbeProcessIdentity {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $creationUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
    return "$([int]$CimProcess.ProcessId)|$($creationUtc.Ticks)"
}

function Test-IsGodotProcess {
    param([Parameter(Mandatory = $true)]$CimProcess)

    return (
        $CimProcess.Name -ieq "Godot.exe" -or
        $CimProcess.Name -ieq "Godot_console.exe"
    )
}

function Test-IsMarkedProbeGodotProcess {
    param([Parameter(Mandatory = $true)]$CimProcess)

    if (-not (Test-IsGodotProcess $CimProcess) -or $null -eq $CimProcess.CommandLine) {
        return $false
    }
    $commandLine = [string]$CimProcess.CommandLine
    $escapedRunToken = [regex]::Escape($runToken)
    $escapedProbeScript = [regex]::Escape($probeScript)
    $hasExactToken = [regex]::IsMatch(
        $commandLine,
        ('(?:^|\s|")--runner-token={0}(?=\s|"|$)' -f $escapedRunToken)
    )
    $hasExactProbe = [regex]::IsMatch(
        $commandLine,
        ('(?:^|\s|"){0}(?=\s|"|$)' -f $escapedProbeScript)
    )
    # Headless/check-only are the normal automated modes. Formal render A/B is
    # intentionally windowed, but remains a non-editor --script invocation with
    # the same unguessable token and exact probe path.
    $isNonEditorProbe = (
        [regex]::IsMatch($commandLine, "(?:^|\s)--headless(?:\s|$)") -or
        [regex]::IsMatch($commandLine, "(?:^|\s)--check-only(?:\s|$)") -or
        [regex]::IsMatch($commandLine, "(?:^|\s)--script(?:\s|$)")
    )
    return $hasExactToken -and $hasExactProbe -and $isNonEditorProbe
}

function Register-OwnedProbeProcess {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $processId = [int]$CimProcess.ProcessId
    if (-not $script:ownedProbeIdentityByPid.ContainsKey($processId)) {
        $script:ownedProbeIdentityByPid[$processId] = (
            Get-ProbeProcessIdentity $CimProcess
        )
        $script:ownedProbeCreationUtcByPid[$processId] = (
            ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
        )
    }
}

function Update-OwnedProbeProcessRegistry {
    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    foreach ($process in $snapshot) {
        if (Test-IsMarkedProbeGodotProcess $process) {
            Register-OwnedProbeProcess $process
        }
    }

    # A console launcher may hand execution to another Godot binary. Track the
    # complete descendant tree from an already token-proven root without ever
    # adopting an unrelated editor process.
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($process in $snapshot) {
            $processId = [int]$process.ProcessId
            $parentId = [int]$process.ParentProcessId
            if (
                $script:ownedProbeIdentityByPid.ContainsKey($processId) -or
                -not $script:ownedProbeIdentityByPid.ContainsKey($parentId)
            ) {
                continue
            }
            $creationUtc = ([DateTime]$process.CreationDate).ToUniversalTime()
            if ($creationUtc -lt $script:ownedProbeCreationUtcByPid[$parentId]) {
                continue
            }
            Register-OwnedProbeProcess $process
            $changed = $true
        }
    }
    return $snapshot
}

function Get-LiveOwnedProbeProcesses {
    $snapshot = @(Update-OwnedProbeProcessRegistry)
    return @($snapshot | Where-Object {
        $processId = [int]$_.ProcessId
        $script:ownedProbeIdentityByPid.ContainsKey($processId) -and
        $script:ownedProbeIdentityByPid[$processId] -eq (
            Get-ProbeProcessIdentity $_
        )
    })
}

function Get-LiveMarkedProbeGodotProcesses {
    return @(Get-LiveOwnedProbeProcesses | Where-Object {
        Test-IsMarkedProbeGodotProcess $_
    })
}

function Stop-OwnedProbeProcessTree {
    $live = @(Get-LiveOwnedProbeProcesses)
    if ($live.Count -gt 0) {
        $parentByPid = @{}
        foreach ($process in $live) {
            $parentByPid[[int]$process.ProcessId] = [int]$process.ParentProcessId
        }
        $depthByPid = @{}
        foreach ($process in $live) {
            $processId = [int]$process.ProcessId
            $cursor = $processId
            $depth = 0
            $visited = @{}
            while (
                $parentByPid.ContainsKey($cursor) -and
                $parentByPid[$cursor] -ne 0 -and
                -not $visited.ContainsKey($cursor)
            ) {
                $visited[$cursor] = $true
                $cursor = $parentByPid[$cursor]
                $depth++
            }
            $depthByPid[$processId] = $depth
        }
        foreach ($process in @($live | Sort-Object {
            -1 * $depthByPid[[int]$_.ProcessId]
        })) {
            Stop-Process `
                -Id ([int]$process.ProcessId) `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @(Get-LiveOwnedProbeProcesses)
        if ($remaining.Count -eq 0) {
            return
        }
        # A console handoff can race the first snapshot. Newly adopted
        # descendants are still owned by the token-proven tree, so stop them in
        # the same bounded cleanup transaction before checking again.
        foreach ($process in @($remaining | Sort-Object ProcessId -Descending)) {
            Stop-Process `
                -Id ([int]$process.ProcessId) `
                -Force `
                -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $cleanupDeadline)

    $remainingDescriptions = @($remaining | ForEach-Object {
        "$($_.Name) PID=$($_.ProcessId)"
    })
    throw "Probe process cleanup failed: $($remainingDescriptions -join ', ')"
}

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot console executable was not found: $GodotExe"
}
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    throw "Godot project root was not found: $ProjectRoot"
}
if ($GateProfile -eq "diagnostic" -and $QuickValidation) {
    throw "QuickValidation is only valid for an enforcing gate profile."
}
if ($GateProfile -ne "diagnostic") {
    $gateConfigurationFailures = [Collections.Generic.List[string]]::new()
    $minimumWarmupFrames = if ($QuickValidation) { 60 } else { 120 }
    $minimumSampleFrames = if ($QuickValidation) { 240 } else { 1200 }
    if ($FixedFps -ne 60) {
        $gateConfigurationFailures.Add("FixedFps must be 60.")
    }
    $isFormalAbScenario = $formalScenarioPhaseById.ContainsKey($ScenarioId)
    $expectedScenarioPhase = if ($isFormalAbScenario) {
        [string]$formalScenarioPhaseById[$ScenarioId]
    } else {
        "engagement"
    }
    if ($Phase -ne $expectedScenarioPhase) {
        $gateConfigurationFailures.Add(
            "$ScenarioId requires Phase=$expectedScenarioPhase."
        )
    }
    if ($EnemyCount -notin @(200, 300)) {
        $gateConfigurationFailures.Add("EnemyCount must be exactly 200 or 300.")
    }
    if ($WarmupFrames -lt $minimumWarmupFrames) {
        $gateConfigurationFailures.Add(
            "WarmupFrames must be at least $minimumWarmupFrames."
        )
    }
    if ($SampleFrames -lt $minimumSampleFrames) {
        $gateConfigurationFailures.Add(
            "SampleFrames must be at least $minimumSampleFrames."
        )
    }
    if (
        $FenceAbMetrics -or
        $EnemyHotMetrics -or
        $GuardianOverlapMetrics -or
        $RuntimeCountScans -or
        $DetailedSemanticEvidence
    ) {
        $gateConfigurationFailures.Add(
            "Intrusive hot-path/count instrumentation must be disabled."
        )
    }
    if ($AuthoritativeTickSampling) {
        if ($WarmupFrames -ne 300) {
            $gateConfigurationFailures.Add(
                "AuthoritativeTickSampling requires WarmupFrames=300."
            )
        }
        if ($SampleFrames -ne 1800) {
            $gateConfigurationFailures.Add(
                "AuthoritativeTickSampling requires SampleFrames=1800."
            )
        }
        if ($DetailedSemanticEvidence) {
            $gateConfigurationFailures.Add(
                "AuthoritativeTickSampling requires DetailedSemanticEvidence=false."
            )
        }
    }
    if ($ScenarioId -in @("first_night_main", "critical_300")) {
        $expectedScenarioEnemyCount = if ($ScenarioId -eq "first_night_main") {
            200
        } else {
            300
        }
        if (
            $WaveConfig -ne
            "res://resources/config/campaigns/tower_defense/formal/wave_01.tres"
        ) {
            $gateConfigurationFailures.Add(
                "$ScenarioId requires the formal tower-defense wave_01 resource."
            )
        }
        if ($EnemyCount -ne $expectedScenarioEnemyCount) {
            $gateConfigurationFailures.Add(
                "$ScenarioId requires EnemyCount=$expectedScenarioEnemyCount."
            )
        }
        if (($FenceCount + $CornCount + $AgaveCount) -ne 100) {
            $gateConfigurationFailures.Add(
                "$ScenarioId requires exactly 100 fence/corn/agave buildings."
            )
        }
        if (-not $AuthoritativeTickSampling) {
            $gateConfigurationFailures.Add(
                "$ScenarioId requires AuthoritativeTickSampling=true."
            )
        }
    }
    if ($GateProfile -eq "cpu60") {
        if (-not $Headless) {
            $gateConfigurationFailures.Add("cpu60 requires Headless=true.")
        }
        if ($MaxFps -ne 0) {
            $gateConfigurationFailures.Add("cpu60 requires MaxFps=0.")
        }
    } else {
        if ($Headless) {
            $gateConfigurationFailures.Add("$GateProfile requires Headless=false.")
        }
        if ($MaxFps -ne 60) {
            $gateConfigurationFailures.Add("$GateProfile requires MaxFps=60.")
        }
        if ($WindowSize -ne "1280x720") {
            $gateConfigurationFailures.Add(
                "$GateProfile requires WindowSize=1280x720."
            )
        }
        if ($VsyncMode -ne "disabled") {
            $gateConfigurationFailures.Add("$GateProfile requires VsyncMode=disabled.")
        }
        if ([string]::IsNullOrWhiteSpace($RenderingMethod)) {
            $gateConfigurationFailures.Add(
                "$GateProfile requires an explicit RenderingMethod."
            )
        }
        if ([string]::IsNullOrWhiteSpace($RenderingDriver)) {
            $gateConfigurationFailures.Add(
                "$GateProfile requires an explicit RenderingDriver."
            )
        }
        if ($GateProfile -eq "window60" -and -not [string]::IsNullOrWhiteSpace($WaveConfig)) {
            $gateConfigurationFailures.Add(
                "window60 requires a single EnemyConfig source."
            )
        }
        if ($GateProfile -eq "wave60" -and [string]::IsNullOrWhiteSpace($WaveConfig)) {
            $gateConfigurationFailures.Add("wave60 requires WaveConfig.")
        }
    }
    if ($gateConfigurationFailures.Count -gt 0) {
        throw (
            "Invalid $GateProfile gate configuration: " +
            ($gateConfigurationFailures -join " ")
        )
    }
}

$resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$gitCommit = $null
$gitDirty = $null
$gitFingerprintSupported = $false
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $gitCommand) {
    $commitOutput = @(
        & $gitCommand.Source -C $resolvedProjectRoot rev-parse HEAD 2>$null
    )
    if ($LASTEXITCODE -eq 0 -and $commitOutput.Count -gt 0) {
        $gitCommit = [string]$commitOutput[0].Trim()
        $statusOutput = @(
            & $gitCommand.Source `
                -C $resolvedProjectRoot `
                status --porcelain=v1 --untracked-files=normal `
                2>$null
        )
        if ($LASTEXITCODE -eq 0) {
            $gitDirty = $statusOutput.Count -gt 0
            $gitFingerprintSupported = $true
        }
    }
}
$requiredExternalSampleCount = if ($GateProfile -eq "diagnostic") {
    $MinimumExternalSamples
} elseif ($QuickValidation) {
    [Math]::Max($MinimumExternalSamples, 3)
} else {
    [Math]::Max($MinimumExternalSamples, 20)
}
$effectiveWallP95BudgetMs = if (
    $GateProfile -in @("window60", "wave60") -and
    -not $PSBoundParameters.ContainsKey("WallP95BudgetMs")
) {
    18.0
} else {
    $WallP95BudgetMs
}
$wallP95BudgetText = $effectiveWallP95BudgetMs.ToString(
    "G17",
    [Globalization.CultureInfo]::InvariantCulture
)
$wallP99BudgetText = $WallP99BudgetMs.ToString(
    "G17",
    [Globalization.CultureInfo]::InvariantCulture
)
$over18RatioBudgetText = $Over18RatioBudget.ToString(
    "G17",
    [Globalization.CultureInfo]::InvariantCulture
)
$over33RatioBudgetText = $Over33RatioBudget.ToString(
    "G17",
    [Globalization.CultureInfo]::InvariantCulture
)
$tempStem = "arc_nice_enemy_cohort_{0}" -f ([Guid]::NewGuid().ToString("N"))
$runToken = if ([string]::IsNullOrWhiteSpace($InvocationToken)) {
    [Guid]::NewGuid().ToString("N")
} else {
    $InvocationToken
}
$script:ownedProbeIdentityByPid = @{}
$script:ownedProbeCreationUtcByPid = @{}
$stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ($tempStem + ".out")
$stderrPath = Join-Path ([IO.Path]::GetTempPath()) ($tempStem + ".err")

$godotArguments = @()
if ($Headless) {
    $godotArguments += "--headless"
}
if ($FixedFps -gt 0) {
    $godotArguments += @("--fixed-fps", $FixedFps)
}
if (-not [string]::IsNullOrWhiteSpace($RenderingMethod)) {
    $godotArguments += @("--rendering-method", $RenderingMethod)
}
if (-not [string]::IsNullOrWhiteSpace($RenderingDriver)) {
    $godotArguments += @("--rendering-driver", $RenderingDriver)
}
$godotArguments += @(
    "--path", $resolvedProjectRoot,
    "--script", $probeScript,
    "--",
    "--runner-token=$runToken",
    "--phase=$Phase",
    "--enemies=$EnemyCount",
    "--scenario-id=$ScenarioId",
    "--authoritative-tick-sampling=$($AuthoritativeTickSampling.ToString().ToLowerInvariant())",
    "--detailed-semantic-evidence=$($DetailedSemanticEvidence.ToString().ToLowerInvariant())",
    "--fences=$FenceCount",
    "--fence-ab-metrics=$($FenceAbMetrics.ToString().ToLowerInvariant())",
    "--warmup=$WarmupFrames",
    "--samples=$SampleFrames",
    "--seed=$Seed",
    "--corn=$CornCount",
    "--agave=$AgaveCount",
    "--max-fps=$MaxFps",
    "--gate-profile=$GateProfile",
    "--quick-validation=$($QuickValidation.ToString().ToLowerInvariant())",
    "--wall-p95-budget-ms=$wallP95BudgetText",
    "--wall-p99-budget-ms=$wallP99BudgetText",
    "--over-18-ratio-budget=$over18RatioBudgetText",
    "--over-33-ratio-budget=$over33RatioBudgetText",
    "--vsync-mode=$VsyncMode",
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
    "--enemy-attack-audio-limiter=$($EnemyAttackAudioLimiter.ToString().ToLowerInvariant())"
)
if ($SimulationMode -ne "project") {
    $godotArguments += "--enemy-simulation-mode=$SimulationMode"
}
if (-not [string]::IsNullOrWhiteSpace($WindowSize)) {
    if ($WindowSize -notmatch '^\d+x\d+$') {
        throw "WindowSize must use WIDTHxHEIGHT, for example 1920x1080."
    }
    $godotArguments += "--window-size=$WindowSize"
}
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
$measurementStarted = $false
$stdoutReadOffset = 0L
$gpuDedicatedCounters = @()
$gpuLocalCounters = @()
$gpuCommittedCounters = @()
$gpu3dCounters = @()
$nextGpuCounterDiscoveryUtc = [DateTime]::MinValue
$runDeadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$timedOut = $false

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

    $discoveryDeadline = [DateTime]::UtcNow.AddSeconds(
        [Math]::Min(15, $TimeoutSeconds)
    )
    while ([DateTime]::UtcNow -lt $discoveryDeadline -and $enginePid -eq 0) {
        $engineProcess = Get-LiveMarkedProbeGodotProcesses |
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

    if ($enginePid -gt 0) {
        # Prime Windows GPU counters during fixture construction/warmup, not
        # inside the measured window. Counter discovery can take long enough to
        # distort a short benchmark if deferred until MEASURE_BEGIN.
        $gpuDedicatedCounters = @(
            New-ProcessPerformanceCounterSet `
                -CategoryName "GPU Process Memory" `
                -CounterName "Dedicated Usage" `
                -ProcessId $enginePid
        )
        $gpuLocalCounters = @(
            New-ProcessPerformanceCounterSet `
                -CategoryName "GPU Process Memory" `
                -CounterName "Local Usage" `
                -ProcessId $enginePid
        )
        $gpuCommittedCounters = @(
            New-ProcessPerformanceCounterSet `
                -CategoryName "GPU Process Memory" `
                -CounterName "Total Committed" `
                -ProcessId $enginePid
        )
        $gpu3dCounters = @(
            New-ProcessPerformanceCounterSet `
                -CategoryName "GPU Engine" `
                -CounterName "Utilization Percentage" `
                -ProcessId $enginePid `
                -InstancePattern "*engtype_3D*"
        )
    }

    while ($enginePid -gt 0) {
        if ([DateTime]::UtcNow -ge $runDeadlineUtc) {
            $timedOut = $true
            break
        }
        $engine = Get-Process -Id $enginePid -ErrorAction SilentlyContinue
        if ($null -eq $engine) {
            break
        }

        $counterDiscoveryUtc = [DateTime]::UtcNow
        if (
            -not $measurementStarted -and
            $counterDiscoveryUtc -ge $nextGpuCounterDiscoveryUtc -and
            (
                $gpuDedicatedCounters.Count -eq 0 -or
                $gpuLocalCounters.Count -eq 0 -or
                $gpuCommittedCounters.Count -eq 0 -or
                $gpu3dCounters.Count -eq 0
            )
        ) {
            if ($gpuDedicatedCounters.Count -eq 0) {
                $gpuDedicatedCounters = @(
                    New-ProcessPerformanceCounterSet `
                        -CategoryName "GPU Process Memory" `
                        -CounterName "Dedicated Usage" `
                        -ProcessId $enginePid
                )
            }
            if ($gpuLocalCounters.Count -eq 0) {
                $gpuLocalCounters = @(
                    New-ProcessPerformanceCounterSet `
                        -CategoryName "GPU Process Memory" `
                        -CounterName "Local Usage" `
                        -ProcessId $enginePid
                )
            }
            if ($gpuCommittedCounters.Count -eq 0) {
                $gpuCommittedCounters = @(
                    New-ProcessPerformanceCounterSet `
                        -CategoryName "GPU Process Memory" `
                        -CounterName "Total Committed" `
                        -ProcessId $enginePid
                )
            }
            if ($gpu3dCounters.Count -eq 0) {
                $gpu3dCounters = @(
                    New-ProcessPerformanceCounterSet `
                        -CategoryName "GPU Engine" `
                        -CounterName "Utilization Percentage" `
                        -ProcessId $enginePid `
                        -InstancePattern "*engtype_3D*"
                )
            }
            $nextGpuCounterDiscoveryUtc = $counterDiscoveryUtc.AddSeconds(1)
        }

        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            $stdoutReader = [IO.File]::Open(
                $stdoutPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite
            )
            try {
                if ($stdoutReadOffset -le $stdoutReader.Length) {
                    $stdoutReader.Position = $stdoutReadOffset
                    $streamReader = [IO.StreamReader]::new(
                        $stdoutReader,
                        [Text.Encoding]::UTF8,
                        $true,
                        4096,
                        $true
                    )
                    try {
                        $newOutput = $streamReader.ReadToEnd()
                        $stdoutReadOffset = $stdoutReader.Position
                    }
                    finally {
                        $streamReader.Dispose()
                    }
                    if ($newOutput -match "TOWER_DEFENSE_ENEMY_COHORT_MEASURE_BEGIN") {
                        $measurementStarted = $true
                        $samples.Clear()
                        $lastCpuSeconds = $null
                        $lastSampleUtc = [DateTime]::UtcNow
                    }
                    if ($newOutput -match "TOWER_DEFENSE_ENEMY_COHORT_MEASURE_END") {
                        $measurementStarted = $false
                    }
                }
            }
            finally {
                $stdoutReader.Dispose()
            }
        }

        $nowUtc = [DateTime]::UtcNow
        $cpuSeconds = $engine.TotalProcessorTime.TotalSeconds
        if ($measurementStarted -and $null -ne $lastCpuSeconds) {
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
                GpuDedicatedMiB = (
                    Get-PerformanceCounterSetTotal $gpuDedicatedCounters
                ) / 1MB
                GpuLocalMiB = (
                    Get-PerformanceCounterSetTotal $gpuLocalCounters
                ) / 1MB
                GpuCommittedMiB = (
                    Get-PerformanceCounterSetTotal $gpuCommittedCounters
                ) / 1MB
                Gpu3dPercent = Get-PerformanceCounterSetTotal $gpu3dCounters
            })
        }
        if ($measurementStarted) {
            $lastCpuSeconds = $cpuSeconds
            $lastSampleUtc = $nowUtc
        }
        Start-Sleep -Milliseconds $ExternalSampleIntervalMs
    }

    if ($timedOut) {
        throw "Enemy cohort probe exceeded its $TimeoutSeconds-second timeout."
    }

    if ($null -ne $launcher) {
        $remainingMilliseconds = [int][Math]::Floor(
            [Math]::Max(
                ($runDeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds,
                0.0
            )
        )
        if (
            $remainingMilliseconds -le 0 -or
            -not $launcher.WaitForExit($remainingMilliseconds)
        ) {
            throw "Enemy cohort probe exceeded its $TimeoutSeconds-second timeout."
        }
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
    $runnerContractViolations = [Collections.Generic.List[string]]::new()
    $payloadRuntimeEnvironment = Get-OptionalPropertyValue `
        $payload `
        "runtime_environment" `
        $null
    $payloadSchemaVersion = [int](
        Get-OptionalPropertyValue $payload "schema_version" 0
    )
    $payloadGate = Get-OptionalPropertyValue $payload "gate" $null
    $payloadGateProfile = [string](
        Get-OptionalPropertyValue $payloadGate "profile" ""
    )
    $payloadGateStatus = [string](
        Get-OptionalPropertyValue $payloadGate "status" ""
    )
    $payloadGateValid = [bool](
        Get-OptionalPropertyValue $payloadGate "valid" $false
    )
    $payloadGateQuickValidation = [bool](
        Get-OptionalPropertyValue $payloadGate "quick_validation" $false
    )
    $payloadValid = [bool](Get-OptionalPropertyValue $payload "valid" $false)
    $payloadVerdict = [string](
        Get-OptionalPropertyValue $payload "verdict" ""
    )
    $payloadViolationsProperty = $payload.PSObject.Properties["violations"]
    $payloadViolations = if ($null -eq $payloadViolationsProperty) {
        $null
    } else {
        $payloadViolationsProperty.Value
    }
    $expectedSuccessMarker = if ($GateProfile -eq "diagnostic") {
        "TOWER_DEFENSE_ENEMY_COHORT_DIAGNOSTIC_COMPLETE"
    } elseif ($QuickValidation) {
        "TOWER_DEFENSE_ENEMY_COHORT_$($GateProfile.ToUpperInvariant())_GATE_SMOKE_OK"
    } else {
        "TOWER_DEFENSE_ENEMY_COHORT_$($GateProfile.ToUpperInvariant())_GATE_OK"
    }
    $successMarkerSeen = [regex]::IsMatch(
        $stdout,
        "(?m)^$([regex]::Escape($expectedSuccessMarker))\r?$"
    )
    if ($payloadSchemaVersion -ne 1) {
        $runnerContractViolations.Add(
            "Unsupported or missing Godot result schema_version=$payloadSchemaVersion."
        )
    }
    if ($payloadGateProfile -ne $GateProfile) {
        $runnerContractViolations.Add(
            "Godot gate profile '$payloadGateProfile' did not match '$GateProfile'."
        )
    }
    if ($GateProfile -in @("window60", "wave60")) {
        $payloadRenderingMethod = [string](
            Get-OptionalPropertyValue $payload "renderer" ""
        )
        if ($payloadRenderingMethod -ne $RenderingMethod) {
            $runnerContractViolations.Add(
                "Godot renderer '$payloadRenderingMethod' did not match '$RenderingMethod'."
            )
        }
        $payloadRenderingDriver = [string](
            Get-OptionalPropertyValue $payload "render_driver" ""
        )
        if ($payloadRenderingDriver -ne $RenderingDriver) {
            $runnerContractViolations.Add(
                "Godot rendering driver '$payloadRenderingDriver' did not match '$RenderingDriver'."
            )
        }
    }
    $payloadSeed = [int](Get-OptionalPropertyValue $payload "seed" -1)
    if ($payloadSeed -ne $Seed) {
        $runnerContractViolations.Add(
            "Godot seed '$payloadSeed' did not match '$Seed'."
        )
    }
    $payloadScenarioId = [string](
        Get-OptionalPropertyValue $payload "scenario_id" ""
    )
    if ($payloadScenarioId -ne $ScenarioId) {
        $runnerContractViolations.Add(
            "Godot scenario '$payloadScenarioId' did not match '$ScenarioId'."
        )
    }
    $payloadPhase = [string](Get-OptionalPropertyValue $payload "phase" "")
    if ($payloadPhase -ne $Phase) {
        $runnerContractViolations.Add(
            "Godot phase '$payloadPhase' did not match '$Phase'."
        )
    }
    if ($ScenarioId -in $formalScenarioIds) {
        $payloadScenarioContract = Get-OptionalPropertyValue `
            $payload `
            "scenario_contract" `
            $null
        $rngStateEvidence = Get-OptionalPropertyValue `
            $payload `
            "rng_state_evidence" `
            $null
        $rngStateStart = Get-OptionalPropertyValue `
            $rngStateEvidence `
            "start" `
            $null
        $rngStateEnd = Get-OptionalPropertyValue `
            $rngStateEvidence `
            "end" `
            $null
        if (
            -not (Test-FormalRandomStateBoundary `
                $rngStateStart `
                $Seed `
                $EnemyCount `
                $CornCount `
                $AgaveCount) -or
            -not (Test-FormalRandomStateBoundary `
                $rngStateEnd `
                $Seed `
                $EnemyCount `
                $CornCount `
                $AgaveCount)
        ) {
            $runnerContractViolations.Add(
                "Formal scenario omitted or forged its post-ready RNG state evidence."
            )
        }
        $productionRegistration = Get-OptionalPropertyValue `
            $payload `
            "production_registration_fingerprint" `
            $null
        $registrationBefore = Get-OptionalPropertyValue `
            $productionRegistration `
            "before_measurement" `
            $null
        $registrationLedger = Get-OptionalPropertyValue `
            $registrationBefore `
            "ledger" `
            $null
        $registrationLedgerSnapshot = Get-OptionalPropertyValue `
            $registrationLedger `
            "snapshot" `
            $null
        $registrationPlantIndex = Get-OptionalPropertyValue `
            $registrationBefore `
            "plant_objective_index" `
            $null
        $registrationNetwork = Get-OptionalPropertyValue `
            $registrationBefore `
            "network_registry" `
            $null
        $registrationCombatIndex = Get-OptionalPropertyValue `
            $registrationBefore `
            "combat_target_index" `
            $null
        $registrationCrossStore = Get-OptionalPropertyValue `
            $registrationBefore `
            "cross_store" `
            $null
        if (
            $null -eq $productionRegistration -or
            -not [bool](Get-OptionalPropertyValue `
                $productionRegistration `
                "required" `
                $false) -or
            [int](Get-OptionalPropertyValue $registrationBefore "runtime_mode" -1) -ne 1 -or
            [string](Get-OptionalPropertyValue `
                $registrationBefore `
                "current_flow_step_path" `
                "") -ne [string](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "flow_step_path" `
                    "") -or
            [int](Get-OptionalPropertyValue `
                $registrationLedgerSnapshot `
                "total" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationLedgerSnapshot `
                "spawned" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationLedger `
                "active_count" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationLedger `
                "attached_count" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationPlantIndex `
                "tracked_enemies" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationNetwork `
                "registered_count" `
                -1) -ne $EnemyCount -or
            -not [bool](Get-OptionalPropertyValue `
                $registrationNetwork `
                "continuous_initial_ids" `
                $false) -or
            [int](Get-OptionalPropertyValue `
                $registrationCombatIndex `
                "registered_count" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationCrossStore `
                "combat_mapping_count" `
                -1) -ne $EnemyCount -or
            [int](Get-OptionalPropertyValue `
                $registrationCrossStore `
                "ledger_mapping_count" `
                -1) -ne $EnemyCount -or
            -not [bool](Get-OptionalPropertyValue `
                $registrationCrossStore `
                "network_and_combat_ids_match" `
                $false)
        ) {
            $runnerContractViolations.Add(
                "Formal scenario omitted or violated its production registration fingerprint."
            )
        }
        if (
            -not [bool](Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "host_configured_before_tree" `
                $false) -or
            -not [bool](Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "host_authority_verified" `
                $false)
        ) {
            $runnerContractViolations.Add(
                "Formal runtime did not prove pre-tree production Host configuration."
            )
        }
        if ($ScenarioId -eq "tower_projectile_96") {
            if (
                [int](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "tower_total_shots" `
                    -1) -lt 96 -or
                [int](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "tower_agave_projectile_shots" `
                    -1) -lt 32 -or
                [int](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "tower_peak_concurrent_projectiles" `
                    -1) -lt 8 -or
                -not [bool](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "projectile_pressure_verified" `
                    $false)
            ) {
                $runnerContractViolations.Add(
                    "Tower scenario did not sustain its required shot and concurrent-projectile workload."
                )
            }
        }
        if ($ScenarioId -eq "faction_battle_150v150") {
            $factionTargetsStart = Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "faction_valid_dynamic_targets_start" `
                $null
            $factionTargetsEnd = Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "faction_valid_dynamic_targets_end" `
                $null
            $factionDamage = Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "faction_damage_taken" `
                $null
            if (
                [int](Get-OptionalPropertyValue $factionTargetsStart "allied" -1) -ne 150 -or
                [int](Get-OptionalPropertyValue $factionTargetsStart "hostile" -1) -ne 150 -or
                [int](Get-OptionalPropertyValue $factionTargetsEnd "allied" -1) -ne 150 -or
                [int](Get-OptionalPropertyValue $factionTargetsEnd "hostile" -1) -ne 150 -or
                [long](Get-OptionalPropertyValue `
                    $factionDamage `
                    "allied_damage_taken" `
                    0) -le 0 -or
                [long](Get-OptionalPropertyValue `
                    $factionDamage `
                    "hostile_damage_taken" `
                    0) -le 0 -or
                [int](Get-OptionalPropertyValue `
                    $factionDamage `
                    "allied_damaged_enemy_count" `
                    0) -le 0 -or
                [int](Get-OptionalPropertyValue `
                    $factionDamage `
                    "hostile_damaged_enemy_count" `
                    0) -le 0
            ) {
                $runnerContractViolations.Add(
                    "Faction scenario did not prove persistent 150v150 targets and bidirectional damage."
                )
            }
        }
        if ($ScenarioId -eq "host_client_proxy_1000") {
            $clientProxyStart = Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "client_proxy_start" `
                $null
            $clientProxyEnd = Get-OptionalPropertyValue `
                $payloadScenarioContract `
                "client_proxy_end" `
                $null
            if (
                -not (Test-ClientProxyAuthorityBoundary $clientProxyStart) -or
                -not (Test-ClientProxyAuthorityBoundary $clientProxyEnd) -or
                [long](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "client_authoritative_attack_delta" `
                    -1) -ne 0 -or
                [long](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "client_authoritative_damage_delta" `
                    -1) -ne 0 -or
                [long](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "client_authoritative_kill_delta" `
                    -1) -ne 0 -or
                [long](Get-OptionalPropertyValue `
                    $payloadScenarioContract `
                    "client_authoritative_reward_delta" `
                    -1) -ne 0
            ) {
                $runnerContractViolations.Add(
                    "Client proxy scenario did not prove 1,000 presentation-only proxies with zero authority deltas."
                )
            }
        }
    }
    $payloadSimulation = Get-OptionalPropertyValue `
        $payload `
        "enemy_simulation" `
        $null
    $payloadActualSimulationMode = [string](
        Get-OptionalPropertyValue $payloadSimulation "actual_mode" ""
    )
    if (
        $SimulationMode -ne "project" -and
        $payloadActualSimulationMode -ne $SimulationMode
    ) {
        $runnerContractViolations.Add(
            "Godot simulation mode '$payloadActualSimulationMode' did not match '$SimulationMode'."
        )
    }
    $payloadSamplingContract = Get-OptionalPropertyValue `
        $payload `
        "sampling_contract" `
        $null
    if (
        [bool](Get-OptionalPropertyValue `
            $payloadSamplingContract `
            "authoritative_tick_sampling" `
            $false) -ne $AuthoritativeTickSampling
    ) {
        $runnerContractViolations.Add(
            "Godot authoritative_tick_sampling did not match the runner request."
        )
    }
    if (
        [bool](Get-OptionalPropertyValue `
            $payloadSamplingContract `
            "detailed_semantic_evidence" `
            $true) -ne $DetailedSemanticEvidence
    ) {
        $runnerContractViolations.Add(
            "Godot detailed_semantic_evidence did not match the runner request."
        )
    }
    if ($payloadValid -ne $payloadGateValid -or $payloadVerdict -ne $payloadGateStatus) {
        $runnerContractViolations.Add(
            "Godot top-level valid/verdict did not match its nested gate result."
        )
    }
    if ($null -eq $payloadViolationsProperty) {
        $runnerContractViolations.Add("Godot result omitted top-level violations.")
    }
    if ($payloadGateQuickValidation -ne $QuickValidation) {
        $runnerContractViolations.Add(
            "Godot quick_validation did not match the runner request."
        )
    }
    $allowedGateStatuses = if ($GateProfile -eq "diagnostic") {
        @("diagnostic")
    } elseif ($QuickValidation) {
        @("smoke_passed", "failed", "invalid")
    } else {
        @("passed", "failed", "invalid")
    }
    if ($payloadGateStatus -notin $allowedGateStatuses) {
        $runnerContractViolations.Add(
            "Unexpected Godot gate status '$payloadGateStatus'."
        )
    }
    $internalSucceeded = if ($GateProfile -eq "diagnostic") {
        $payloadGateStatus -eq "diagnostic" -and $payloadGateValid
    } elseif ($QuickValidation) {
        $payloadGateStatus -eq "smoke_passed" -and $payloadGateValid
    } else {
        $payloadGateStatus -eq "passed" -and $payloadGateValid
    }
    if ($internalSucceeded) {
        if (-not $successMarkerSeen) {
            $runnerContractViolations.Add(
                "Godot did not emit the expected success marker '$expectedSuccessMarker'."
            )
        }
        if ($launcherExitCode -ne 0) {
            $runnerContractViolations.Add(
                "Godot reported success but exited with $launcherExitCode."
            )
        }
    } else {
        if ($successMarkerSeen) {
            $runnerContractViolations.Add(
                "Godot emitted '$expectedSuccessMarker' for a non-success result."
            )
        }
        if ($launcherExitCode -eq 0) {
            $runnerContractViolations.Add(
                "Godot reported a non-success result but exited with zero."
            )
        }
    }
    $external = [ordered]@{
        engine_pid = $enginePid
        sample_count = $samples.Count
        minimum_required_sample_count = $requiredExternalSampleCount
        measurement_window_sample_sufficient = (
            $samples.Count -ge $requiredExternalSampleCount
        )
        logical_processor_count = [Environment]::ProcessorCount
        cpu_measurement_scope = "whole_process"
        whole_process_cpu_average_percent = 0.0
        whole_process_cpu_max_percent = 0.0
        whole_process_cpu_core_equivalent_average_percent = 0.0
        whole_process_cpu_core_equivalent_max_percent = 0.0
        working_average_mib = 0.0
        working_p50_mib = 0.0
        working_p95_mib = 0.0
        working_max_mib = 0.0
        private_average_mib = 0.0
        private_p50_mib = 0.0
        private_p95_mib = 0.0
        private_max_mib = 0.0
        gpu_process_memory_monitor_available = $false
        gpu_process_memory_instance_count = 0
        gpu_dedicated_p50_mib = 0.0
        gpu_dedicated_p95_mib = 0.0
        gpu_dedicated_max_mib = 0.0
        gpu_local_p50_mib = 0.0
        gpu_local_p95_mib = 0.0
        gpu_committed_p50_mib = 0.0
        gpu_committed_p95_mib = 0.0
        gpu_3d_p50_percent = 0.0
        gpu_3d_p95_percent = 0.0
        gpu_3d_monitor_available = $false
        gpu_3d_instance_count = 0
        gpu_3d_scope = "aggregate_across_matching_3d_engines"
        threads_max = 0
        handles_max = 0
    }
    if ($samples.Count -ge 3) {
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
        $external.working_p50_mib = [Math]::Round(
            (Get-NearestRankValue `
                -Values @($samples.WorkingMiB) `
                -Percentile 0.50),
            3
        )
        $external.working_p95_mib = [Math]::Round(
            (Get-NearestRankValue `
                -Values @($samples.WorkingMiB) `
                -Percentile 0.95),
            3
        )
        $external.working_max_mib = [Math]::Round($working.Maximum, 3)
        $external.private_average_mib = [Math]::Round($private.Average, 3)
        $external.private_p50_mib = [Math]::Round(
            (Get-NearestRankValue `
                -Values @($samples.PrivateMiB) `
                -Percentile 0.50),
            3
        )
        $external.private_p95_mib = [Math]::Round(
            (Get-NearestRankValue `
                -Values @($samples.PrivateMiB) `
                -Percentile 0.95),
            3
        )
        $external.private_max_mib = [Math]::Round($private.Maximum, 3)
        $external.gpu_process_memory_monitor_available = (
            $gpuDedicatedCounters.Count -gt 0
        )
        $external.gpu_process_memory_instance_count = $gpuDedicatedCounters.Count
        $external.gpu_3d_monitor_available = ($gpu3dCounters.Count -gt 0)
        $external.gpu_3d_instance_count = $gpu3dCounters.Count
        if ($external.gpu_process_memory_monitor_available) {
            $gpuDedicated = $samples | Measure-Object GpuDedicatedMiB -Maximum
            $external.gpu_dedicated_p50_mib = [Math]::Round(
                (Get-NearestRankValue @($samples.GpuDedicatedMiB) 0.50),
                3
            )
            $external.gpu_dedicated_p95_mib = [Math]::Round(
                (Get-NearestRankValue @($samples.GpuDedicatedMiB) 0.95),
                3
            )
            $external.gpu_dedicated_max_mib = [Math]::Round(
                $gpuDedicated.Maximum,
                3
            )
            $external.gpu_local_p50_mib = [Math]::Round(
                (Get-NearestRankValue @($samples.GpuLocalMiB) 0.50),
                3
            )
            $external.gpu_local_p95_mib = [Math]::Round(
                (Get-NearestRankValue @($samples.GpuLocalMiB) 0.95),
                3
            )
            $external.gpu_committed_p50_mib = [Math]::Round(
                (Get-NearestRankValue @($samples.GpuCommittedMiB) 0.50),
                3
            )
            $external.gpu_committed_p95_mib = [Math]::Round(
                (Get-NearestRankValue @($samples.GpuCommittedMiB) 0.95),
                3
            )
        }
        if ($external.gpu_3d_monitor_available) {
            $external.gpu_3d_p50_percent = [Math]::Round(
                (Get-NearestRankValue @($samples.Gpu3dPercent) 0.50),
                3
            )
            $external.gpu_3d_p95_percent = [Math]::Round(
                (Get-NearestRankValue @($samples.Gpu3dPercent) 0.95),
                3
            )
        }
        $external.threads_max = [int]$threads.Maximum
        $external.handles_max = [int]$handles.Maximum
    }

    $runnerViolations = [Collections.Generic.List[object]]::new()
    foreach ($payloadViolation in @($payloadViolations)) {
        if ($null -ne $payloadViolation) {
            $runnerViolations.Add($payloadViolation)
        }
    }
    foreach ($contractViolation in $runnerContractViolations) {
        $runnerViolations.Add([pscustomobject]@{
            code = "runner_contract_violation"
            message = $contractViolation
        })
    }
    $externalSampleSufficient = [bool](
        $external.measurement_window_sample_sufficient
    )
    if ($GateProfile -ne "diagnostic" -and -not $externalSampleSufficient) {
        $runnerViolations.Add([pscustomobject]@{
            code = "external_sample_insufficient"
            message = (
                "External process sampling captured $($samples.Count) samples; " +
                "requires $requiredExternalSampleCount."
            )
            actual = $samples.Count
            limit = $requiredExternalSampleCount
        })
    }

    $finalValid = (
        $payloadGateValid -and
        $runnerContractViolations.Count -eq 0 -and
        ($GateProfile -eq "diagnostic" -or $externalSampleSufficient)
    )
    $finalVerdict = if (-not $finalValid) {
        "invalid"
    } else {
        $payloadGateStatus
    }
    $finalPassed = $finalVerdict -eq "passed"
    $finalSucceeded = (
        $internalSucceeded -and
        $runnerContractViolations.Count -eq 0 -and
        ($GateProfile -eq "diagnostic" -or $externalSampleSufficient)
    )
    $finalExitCode = if ($finalSucceeded) { 0 } else { 1 }
    $payloadGodotEnvironment = Get-OptionalPropertyValue `
        $payloadRuntimeEnvironment `
        "godot" `
        $null
    $payloadOsEnvironment = Get-OptionalPropertyValue `
        $payloadRuntimeEnvironment `
        "os" `
        $null
    $payloadCpuEnvironment = Get-OptionalPropertyValue `
        $payloadRuntimeEnvironment `
        "cpu" `
        $null
    $effectiveVsyncModeValue = [int](
        Get-OptionalPropertyValue $payload "vsync_mode" -1
    )
    $effectiveVsyncModeName = switch ($effectiveVsyncModeValue) {
        0 { "disabled" }
        1 { "enabled" }
        2 { "adaptive" }
        3 { "mailbox" }
        default { "unknown" }
    }
    $intrusiveFlags = [ordered]@{
        fence_ab_metrics = $FenceAbMetrics
        enemy_hot_metrics = $EnemyHotMetrics
        guardian_overlap_metrics = $GuardianOverlapMetrics
        runtime_count_scans = $RuntimeCountScans
        detailed_semantic_evidence = $DetailedSemanticEvidence
        any_enabled = (
            $FenceAbMetrics -or
            $EnemyHotMetrics -or
            $GuardianOverlapMetrics -or
            $RuntimeCountScans -or
            $DetailedSemanticEvidence
        )
    }
    $fingerprint = [ordered]@{
        commit = $gitCommit
        dirty = $gitDirty
        source_control_supported = $gitFingerprintSupported
        godot = [ordered]@{
            executable = (Resolve-Path -LiteralPath $GodotExe).Path
            version = [string](
                Get-OptionalPropertyValue $payloadGodotEnvironment "string" ""
            )
            version_info = $payloadGodotEnvironment
        }
        os = [ordered]@{
            name = [string](
                Get-OptionalPropertyValue $payloadOsEnvironment "name" ""
            )
            version = [string](
                Get-OptionalPropertyValue $payloadOsEnvironment "version" ""
            )
        }
        cpu = [ordered]@{
            name = [string](
                Get-OptionalPropertyValue $payloadCpuEnvironment "name" ""
            )
            logical_processor_count = [int](
                Get-OptionalPropertyValue `
                    $payloadCpuEnvironment `
                    "logical_processor_count" `
                    $external.logical_processor_count
            )
        }
        gpu = [string](Get-OptionalPropertyValue $payload "gpu" "")
        rendering = [ordered]@{
            requested_method = $RenderingMethod
            effective_method = [string](
                Get-OptionalPropertyValue $payload "renderer" ""
            )
            requested_driver = $RenderingDriver
            effective_driver = [string](
                Get-OptionalPropertyValue $payload "render_driver" ""
            )
        }
        window = [ordered]@{
            requested_size = Get-OptionalPropertyValue `
                $payload `
                "requested_window_size" `
                @()
            effective_size = Get-OptionalPropertyValue `
                $payload `
                "window_size" `
                @()
        }
        vsync = [ordered]@{
            requested_mode = $VsyncMode
            effective_mode = $effectiveVsyncModeName
            effective_mode_value = $effectiveVsyncModeValue
        }
        seed = $payloadSeed
        rng_state_evidence = Get-OptionalPropertyValue `
            $payload `
            "rng_state_evidence" `
            $null
        scenario = [ordered]@{
            id = $payloadScenarioId
            phase = [string](Get-OptionalPropertyValue $payload "phase" "")
            flow_state = [int](
                Get-OptionalPropertyValue $payload "flow_state" -1
            )
            night_factor = [double](
                Get-OptionalPropertyValue $payload "night_factor" -1.0
            )
            is_night = [bool](
                Get-OptionalPropertyValue $payload "is_night" $false
            )
            enemy_count = [int](
                Get-OptionalPropertyValue $payload "requested_enemies" -1
            )
            source_path = [string](
                Get-OptionalPropertyValue $payload "source_path" ""
            )
            enemy_composition = Get-OptionalPropertyValue `
                $payload `
                "composition" `
                $null
            building_composition = Get-OptionalPropertyValue `
                $payload `
                "building_composition" `
                $null
            production_registration = Get-OptionalPropertyValue `
                $payload `
                "production_registration_fingerprint" `
                $null
            scenario_contract = Get-OptionalPropertyValue `
                $payload `
                "scenario_contract" `
                $null
            deterministic_outcome = [ordered]@{
                alive_start = [int](
                    Get-OptionalPropertyValue $payload "alive_start" -1
                )
                alive_min = [int](
                    Get-OptionalPropertyValue $payload "alive_min" -1
                )
                alive_end = [int](
                    Get-OptionalPropertyValue $payload "alive_end" -1
                )
                player_damage = [int](
                    Get-OptionalPropertyValue $payload "player_damage" -1
                )
                base_damage = [int](
                    Get-OptionalPropertyValue $payload "base_damage" -1
                )
                corn_target_locks = [int](
                    Get-OptionalPropertyValue $payload "corn_target_locks" -1
                )
                corn_hitscan_rays = [int](
                    Get-OptionalPropertyValue $payload "corn_hitscan_rays" -1
                )
                combat_index_size = [int](
                    Get-OptionalPropertyValue $payload "combat_index_size" -1
                )
            }
        }
        simulation = [ordered]@{
            requested_mode = $SimulationMode
            actual_mode = $payloadActualSimulationMode
            authoritative_tick_sampling = $AuthoritativeTickSampling
            warmup_physics_ticks = $WarmupFrames
            sample_physics_ticks = $SampleFrames
        }
        intrusive_flags = $intrusiveFlags
    }
    $combined = [ordered]@{
        schema_version = 1
        valid = $finalValid
        verdict = $finalVerdict
        violations = $runnerViolations
        fingerprint = $fingerprint
        gate = [ordered]@{
            profile = $GateProfile
            quick_validation = $QuickValidation
            status = $finalVerdict
            valid = $finalValid
            passed = $finalPassed
            success_marker = $expectedSuccessMarker
            success_marker_seen = $successMarkerSeen
            external_sample_sufficient = $externalSampleSufficient
            contract_violations = $runnerContractViolations
        }
        godot = $payload
        external_process = $external
        engine_exit_code = $launcherExitCode
        exit_code = $finalExitCode
    }
    $combined | ConvertTo-Json -Depth 12 -Compress

    if ($finalExitCode -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            [Console]::Error.WriteLine($stderr.TrimEnd())
        }
        foreach ($contractViolation in $runnerContractViolations) {
            [Console]::Error.WriteLine(
                "ENEMY_COHORT_RUNNER_CONTRACT_FAILED: $contractViolation"
            )
        }
        if ($GateProfile -ne "diagnostic" -and -not $externalSampleSufficient) {
            [Console]::Error.WriteLine(
                "ENEMY_COHORT_EXTERNAL_SAMPLE_INSUFFICIENT: " +
                "$($samples.Count)/$requiredExternalSampleCount"
            )
        }
        exit $finalExitCode
    }
}
finally {
	$cleanupFailure = $null
	foreach ($counter in @(
		$gpuDedicatedCounters +
		$gpuLocalCounters +
		$gpuCommittedCounters +
		$gpu3dCounters
	)) {
		$counter.Dispose()
	}
    try {
        # Refresh ownership before stopping so a late console-to-engine handoff
        # is included. Every adopted root must carry this invocation's token and
        # exact probe script; ordinary editor windows can never match.
        $null = Update-OwnedProbeProcessRegistry
        if ($null -ne $launcher -and -not $launcher.HasExited) {
            $launcherCim = Get-CimInstance `
                Win32_Process `
                -Filter "ProcessId = $($launcher.Id)" `
                -ErrorAction SilentlyContinue
            if (
                $null -ne $launcherCim -and
                (Test-IsMarkedProbeGodotProcess $launcherCim)
            ) {
                Register-OwnedProbeProcess $launcherCim
            }
        }
        Stop-OwnedProbeProcessTree
		if ($null -ne $launcher -and -not $launcher.HasExited) {
			# The launcher handle was created by this call. This fallback covers an
			# executable whose CIM command line disappeared during an exit race.
			Stop-Process `
				-Id $launcher.Id `
				-Force `
				-ErrorAction SilentlyContinue
		}
		# Stopping the console root can race a final engine handoff. Refresh and
		# drain the owned tree once more before the independent global proof.
		Stop-OwnedProbeProcessTree

        # Independent post-cleanup proof: do not trust cached process handles or
        # a successful Stop-Process return value.
        $remainingMarkedGodot = @(
            Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object { Test-IsMarkedProbeGodotProcess $_ }
        )
        if ($remainingMarkedGodot.Count -gt 0) {
            $remainingText = @($remainingMarkedGodot | ForEach-Object {
                "$($_.Name) PID=$($_.ProcessId)"
            }) -join ", "
            throw "Marked Godot process remained after cleanup: $remainingText"
        }
    }
    catch {
        $cleanupFailure = $_
    }
    foreach ($tempPath in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
    if ($null -ne $cleanupFailure) {
        throw $cleanupFailure
    }
}
