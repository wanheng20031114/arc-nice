param(
    [string[]]$ScenarioIds = @(
        "first_night_main",
        "critical_300",
        "basic_pursuit_300",
        "tower_projectile_96",
        "faction_battle_150v150",
        "obstacle_water_unreachable",
        "host_client_proxy_1000"
    ),

    [int[]]$Seeds = @(20260717, 20260718, 20260719),

    [switch]$Execute,

    [switch]$LibraryOnly,

    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$OutputRoot = (Join-Path $PSScriptRoot "output/enemy_simulation_ab_acceptance"),

    [ValidateSet("gl_compatibility", "mobile", "forward_plus")]
    [string]$RenderingMethod = "gl_compatibility",

    [ValidateSet("opengl3", "vulkan", "d3d12")]
    [string]$RenderingDriver = "opengl3",

    [ValidateRange(1, 3600)]
    [int]$PerRunTimeoutSeconds = 600,

    [ValidateRange(1, 86400)]
    [int]$GlobalTimeoutSeconds = 21600,

    [ValidateRange(50, 5000)]
    [int]$ExternalSampleIntervalMs = 100,

    [ValidateRange(3, 1000)]
    [int]$MinimumExternalSamples = 20
)

# Formal execution is intentionally opt-in:
#   pwsh dev_tools/run_enemy_simulation_ab_acceptance.ps1 -Execute
# It runs seven scenarios x three seeds x four ABBA positions (84 isolated Godot
# processes). Every run uses 300 warmup + 1800 measured authoritative ticks.
# Raw backend JSON and matching SHA-256 sidecars are written below
# dev_tools/output/, which is ignored by Git. A clean shared commit and stable
# environment fingerprint are mandatory for a valid aggregate.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AcceptanceSchemaVersion = 4
$script:BackendRunnerName = "run_tower_defense_enemy_cohort_probe.ps1"
$script:FormalWave01 = (
    "res://resources/config/campaigns/tower_defense/formal/wave_01.tres"
)
$script:FormalWave12 = (
    "res://resources/config/campaigns/tower_defense/formal/wave_12.tres"
)
$script:BasicPursuitEnemy = (
    "res://resources/config/enemies/yuanshi_insect_basic.tres"
)
$script:RequiredWarmupTicks = 300
$script:RequiredSampleTicks = 1800
$script:MainMaximumRatio = 0.85
$script:CriticalMaximumRatio = 1.03
$script:LegacyMode = "legacy"
$script:CandidateMode = "layered_contact"
$script:MaximumCandidateTouchMonitoringRatio = 0.05
$script:TowerMinimumTotalShots = 96
$script:TowerMinimumAgaveProjectileShots = 32
$script:TowerMinimumConcurrentProjectiles = 8
$script:FormalScenarioIds = @(
    "first_night_main",
    "critical_300",
    "basic_pursuit_300",
    "tower_projectile_96",
    "faction_battle_150v150",
    "obstacle_water_unreachable",
    "host_client_proxy_1000"
)
$script:ActiveChildProcess = $null
$script:ActiveInvocationToken = ""
$script:ActiveBackendRunnerPath = ""
$script:OwnedProcessIdentityByPid = @{}
$script:OwnedProcessCreationUtcByPid = @{}


function Get-AbOptionalProperty {
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


function Test-AbFormalRandomStateBoundary {
    param(
        [object]$Boundary,
        [int]$ExpectedSeed,
        [int]$ExpectedEnemyCount,
        [int]$ExpectedCornCount,
        [int]$ExpectedAgaveCount
    )

    if (
        $null -eq $Boundary -or
        -not [bool](Get-AbOptionalProperty `
            $Boundary `
            "determinized_after_ready" `
            $false) -or
        [int](Get-AbOptionalProperty $Boundary "requested_seed" -1) -ne
            $ExpectedSeed
    ) {
        return $false
    }
    $runtime = Get-AbOptionalProperty $Boundary "runtime" $null
    $fate = Get-AbOptionalProperty $Boundary "fate_coordinator" $null
    $fateManager = Get-AbOptionalProperty $Boundary "fate_manager" $null
    if (
        [long](Get-AbOptionalProperty $runtime "seed" ([long]-1)) -ne
            [long]$ExpectedSeed -or
        [long](Get-AbOptionalProperty $fate "seed" ([long]-1)) -ne
            ([long]$ExpectedSeed + 2000000L) -or
        [long](Get-AbOptionalProperty $fateManager "seed" ([long]-1)) -ne
            ([long]$ExpectedSeed + 2000001L) -or
        $null -eq (Get-AbOptionalProperty $runtime "state" $null) -or
        $null -eq (Get-AbOptionalProperty $fate "state" $null) -or
        $null -eq (Get-AbOptionalProperty $fateManager "state" $null)
    ) {
        return $false
    }
    $behaviorStates = @(
        Get-AbOptionalProperty $Boundary "enemy_behavior_states" @()
    )
    $dropStates = @(Get-AbOptionalProperty $Boundary "enemy_drop_states" @())
    $cornStates = @(Get-AbOptionalProperty $Boundary "corn_idle_states" @())
    $agaveStates = @(Get-AbOptionalProperty $Boundary "agave_idle_states" @())
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
            [int](Get-AbOptionalProperty $behaviorStates[$index] "index" -1) -ne
                $index -or
            [long](Get-AbOptionalProperty $behaviorStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$index * 2L) -or
            $null -eq (Get-AbOptionalProperty $behaviorStates[$index] "state" $null) -or
            [int](Get-AbOptionalProperty $dropStates[$index] "index" -1) -ne
                $index -or
            [long](Get-AbOptionalProperty $dropStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$index * 2L + 1L) -or
            $null -eq (Get-AbOptionalProperty $dropStates[$index] "state" $null)
        ) {
            return $false
        }
    }
    for ($index = 0; $index -lt $ExpectedCornCount; $index += 1) {
        if (
            [long](Get-AbOptionalProperty $cornStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$index) -or
            $null -eq (Get-AbOptionalProperty $cornStates[$index] "state" $null)
        ) {
            return $false
        }
    }
    for ($index = 0; $index -lt $ExpectedAgaveCount; $index += 1) {
        if (
            [long](Get-AbOptionalProperty $agaveStates[$index] "seed" ([long]-1)) -ne
                ([long]$ExpectedSeed + [long]$ExpectedCornCount + [long]$index) -or
            $null -eq (Get-AbOptionalProperty $agaveStates[$index] "state" $null)
        ) {
            return $false
        }
    }
    return $true
}


function Test-AbClientProxyAuthorityBoundary {
    param([object]$Boundary)

    return (
        $null -ne $Boundary -and
        [int](Get-AbOptionalProperty $Boundary "proxy_count" -1) -eq 1000 -and
        [int](Get-AbOptionalProperty $Boundary "network_count" -1) -eq 1000 -and
        [int](Get-AbOptionalProperty $Boundary "index_count" -1) -eq 1000 -and
        [int](Get-AbOptionalProperty $Boundary "proxy_true_count" -1) -eq 1000 -and
        [int](Get-AbOptionalProperty $Boundary "process_disabled_count" -1) -eq 1000 -and
        [int](Get-AbOptionalProperty `
            $Boundary `
            "physics_process_disabled_count" `
            -1) -eq 1000 -and
        [int](Get-AbOptionalProperty $Boundary "area_count" -1) -gt 0 -and
        [int](Get-AbOptionalProperty $Boundary "monitoring_area_count" -1) -eq 0 -and
        [int](Get-AbOptionalProperty `
            $Boundary `
            "simulation_registered_count" `
            -1) -eq 0 -and
        [int](Get-AbOptionalProperty `
            $Boundary `
            "contact_registered_count" `
            -1) -eq 0 -and
        [int](Get-AbOptionalProperty `
            $Boundary `
            "authoritative_attack_state_count" `
            -1) -eq 0 -and
        [int](Get-AbOptionalProperty `
            $Boundary `
            "authoritative_damage_state_count" `
            -1) -eq 0 -and
        [int](Get-AbOptionalProperty $Boundary "dead_count" -1) -eq 0 -and
        [int](Get-AbOptionalProperty $Boundary "pending_reward" -1) -eq 0 -and
        -not [bool](Get-AbOptionalProperty $Boundary "reward_flush_queued" $true)
    )
}


function Get-AbSha256Hex {
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}


function Get-AbMedian {
    param([double[]]$Values)

    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) {
        return $null
    }
    $middle = [int][Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) {
        return [double]$ordered[$middle]
    }
    return ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2.0
}


function Test-AbOutputContainsEngineError {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    return [regex]::IsMatch($Text, '(?im)\bSCRIPT\s+ERROR\b|\bERROR:')
}


function Get-AbScenarioDefinition {
    param([string]$ScenarioId)

    switch ($ScenarioId) {
        "first_night_main" {
            return [pscustomobject][ordered]@{
                id = "first_night_main"
                role = "main"
                fixture_kind = "host_wave"
                phase = "approach"
                wave_config = $script:FormalWave01
                enemy_config = ""
                source_path = $script:FormalWave01
                flow_step_path = $script:FormalWave01
                enemy_count = 200
                fence_count = 40
                corn_count = 40
                agave_count = 20
                allied_enemy_count = 0
                hostile_enemy_count = 200
                unreachable_assignment_count = 0
                client_proxy_count = 0
                maximum_paired_p95_ratio = $script:MainMaximumRatio
            }
        }
        "critical_300" {
            return [pscustomobject][ordered]@{
                id = "critical_300"
                role = "critical"
                fixture_kind = "host_wave"
                phase = "approach"
                wave_config = $script:FormalWave01
                enemy_config = ""
                source_path = $script:FormalWave01
                flow_step_path = $script:FormalWave01
                enemy_count = 300
                fence_count = 40
                corn_count = 40
                agave_count = 20
                allied_enemy_count = 0
                hostile_enemy_count = 300
                unreachable_assignment_count = 0
                client_proxy_count = 0
                maximum_paired_p95_ratio = $script:CriticalMaximumRatio
            }
        }
        "basic_pursuit_300" {
            return [pscustomobject][ordered]@{
                id = "basic_pursuit_300"
                role = "critical"
                fixture_kind = "basic_pursuit"
                phase = "approach"
                wave_config = ""
                enemy_config = $script:BasicPursuitEnemy
                source_path = $script:BasicPursuitEnemy
                flow_step_path = $script:FormalWave01
                enemy_count = 300
                fence_count = 0
                corn_count = 0
                agave_count = 0
                allied_enemy_count = 0
                hostile_enemy_count = 300
                unreachable_assignment_count = 0
                client_proxy_count = 0
                maximum_paired_p95_ratio = $script:CriticalMaximumRatio
            }
        }
        "tower_projectile_96" {
            return [pscustomobject][ordered]@{
                id = "tower_projectile_96"
                role = "critical"
                fixture_kind = "tower_projectile"
                phase = "engagement"
                wave_config = $script:FormalWave12
                enemy_config = ""
                source_path = $script:FormalWave12
                flow_step_path = $script:FormalWave12
                enemy_count = 300
                fence_count = 0
                corn_count = 64
                agave_count = 32
                allied_enemy_count = 0
                hostile_enemy_count = 300
                unreachable_assignment_count = 0
                client_proxy_count = 0
                maximum_paired_p95_ratio = $script:CriticalMaximumRatio
            }
        }
        "faction_battle_150v150" {
            return [pscustomobject][ordered]@{
                id = "faction_battle_150v150"
                role = "critical"
                fixture_kind = "faction_battle"
                phase = "engagement"
                wave_config = ""
                enemy_config = $script:BasicPursuitEnemy
                source_path = $script:BasicPursuitEnemy
                flow_step_path = $script:FormalWave01
                enemy_count = 300
                fence_count = 0
                corn_count = 0
                agave_count = 0
                allied_enemy_count = 150
                hostile_enemy_count = 150
                unreachable_assignment_count = 0
                client_proxy_count = 0
                maximum_paired_p95_ratio = $script:CriticalMaximumRatio
            }
        }
        "obstacle_water_unreachable" {
            return [pscustomobject][ordered]@{
                id = "obstacle_water_unreachable"
                role = "critical"
                fixture_kind = "water_unreachable"
                phase = "approach"
                wave_config = ""
                enemy_config = $script:BasicPursuitEnemy
                source_path = $script:BasicPursuitEnemy
                flow_step_path = $script:FormalWave01
                enemy_count = 300
                fence_count = 0
                corn_count = 0
                agave_count = 0
                allied_enemy_count = 1
                hostile_enemy_count = 299
                unreachable_assignment_count = 299
                client_proxy_count = 0
                maximum_paired_p95_ratio = $script:CriticalMaximumRatio
            }
        }
        "host_client_proxy_1000" {
            return [pscustomobject][ordered]@{
                id = "host_client_proxy_1000"
                role = "critical"
                fixture_kind = "host_client_proxy"
                phase = "approach"
                wave_config = $script:FormalWave01
                enemy_config = ""
                source_path = $script:FormalWave01
                flow_step_path = $script:FormalWave01
                enemy_count = 300
                fence_count = 0
                corn_count = 0
                agave_count = 0
                allied_enemy_count = 0
                hostile_enemy_count = 300
                unreachable_assignment_count = 0
                client_proxy_count = 1000
                maximum_paired_p95_ratio = $script:CriticalMaximumRatio
            }
        }
        default {
            throw "Unsupported A/B acceptance scenario: $ScenarioId"
        }
    }
}


function New-AbbaRunPlan {
    param(
        [string[]]$RequestedScenarioIds,
        [int[]]$RequestedSeeds
    )

    $plan = [Collections.Generic.List[object]]::new()
    $ordinal = 0
    foreach ($scenarioId in $RequestedScenarioIds) {
        $scenario = Get-AbScenarioDefinition $scenarioId
        foreach ($seed in $RequestedSeeds) {
            $modes = @(
                $script:LegacyMode,
                $script:CandidateMode,
                $script:CandidateMode,
                $script:LegacyMode
            )
            for ($position = 0; $position -lt $modes.Count; $position += 1) {
                $plan.Add([pscustomobject][ordered]@{
                    ordinal = $ordinal
                    scenario = $scenario
                    scenario_id = $scenario.id
                    seed = [int]$seed
                    block_position = $position
                    mode = $modes[$position]
                    pair_index = if ($position -lt 2) { 0 } else { 1 }
                })
                $ordinal += 1
            }
        }
    }
    return @($plan)
}


function ConvertTo-AbBoolToken {
    param(
        [string]$Name,
        [bool]$Value
    )

    return "-${Name}:`$$($Value.ToString().ToLowerInvariant())"
}


function Get-AbPairFingerprintProjection {
    param([object]$Fingerprint)

    $simulation = Get-AbOptionalProperty $Fingerprint "simulation" $null
    return [ordered]@{
        commit = Get-AbOptionalProperty $Fingerprint "commit" $null
        dirty = Get-AbOptionalProperty $Fingerprint "dirty" $null
        source_control_supported = Get-AbOptionalProperty `
            $Fingerprint `
            "source_control_supported" `
            $false
        godot = Get-AbOptionalProperty $Fingerprint "godot" $null
        os = Get-AbOptionalProperty $Fingerprint "os" $null
        cpu = Get-AbOptionalProperty $Fingerprint "cpu" $null
        gpu = Get-AbOptionalProperty $Fingerprint "gpu" $null
        rendering = Get-AbOptionalProperty $Fingerprint "rendering" $null
        window = Get-AbOptionalProperty $Fingerprint "window" $null
        vsync = Get-AbOptionalProperty $Fingerprint "vsync" $null
        seed = Get-AbOptionalProperty $Fingerprint "seed" $null
        rng_state_evidence = Get-AbOptionalProperty `
            $Fingerprint `
            "rng_state_evidence" `
            $null
        scenario = Get-AbOptionalProperty $Fingerprint "scenario" $null
        simulation_contract = [ordered]@{
            authoritative_tick_sampling = Get-AbOptionalProperty `
                $simulation `
                "authoritative_tick_sampling" `
                $false
            warmup_physics_ticks = Get-AbOptionalProperty `
                $simulation `
                "warmup_physics_ticks" `
                0
            sample_physics_ticks = Get-AbOptionalProperty `
                $simulation `
                "sample_physics_ticks" `
                0
        }
        intrusive_flags = Get-AbOptionalProperty `
            $Fingerprint `
            "intrusive_flags" `
            $null
    }
}


function Get-AbEnvironmentFingerprintProjection {
    param([object]$Fingerprint)

    return [ordered]@{
        commit = Get-AbOptionalProperty $Fingerprint "commit" $null
        dirty = Get-AbOptionalProperty $Fingerprint "dirty" $null
        source_control_supported = Get-AbOptionalProperty `
            $Fingerprint `
            "source_control_supported" `
            $false
        godot = Get-AbOptionalProperty $Fingerprint "godot" $null
        os = Get-AbOptionalProperty $Fingerprint "os" $null
        cpu = Get-AbOptionalProperty $Fingerprint "cpu" $null
        gpu = Get-AbOptionalProperty $Fingerprint "gpu" $null
        rendering = Get-AbOptionalProperty $Fingerprint "rendering" $null
        window = Get-AbOptionalProperty $Fingerprint "window" $null
        vsync = Get-AbOptionalProperty $Fingerprint "vsync" $null
        intrusive_flags = Get-AbOptionalProperty `
            $Fingerprint `
            "intrusive_flags" `
            $null
    }
}


function Test-AbFingerprintCompatible {
    param(
        [object]$Expected,
        [object]$Actual,
        [switch]$EnvironmentOnly
    )

    $expectedProjection = if ($EnvironmentOnly) {
        Get-AbEnvironmentFingerprintProjection $Expected
    } else {
        Get-AbPairFingerprintProjection $Expected
    }
    $actualProjection = if ($EnvironmentOnly) {
        Get-AbEnvironmentFingerprintProjection $Actual
    } else {
        Get-AbPairFingerprintProjection $Actual
    }
    $expectedJson = $expectedProjection | ConvertTo-Json -Depth 30 -Compress
    $actualJson = $actualProjection | ConvertTo-Json -Depth 30 -Compress
    return $expectedJson -ceq $actualJson
}


function Get-AbRunContractViolations {
    param(
        [object]$PlanEntry,
        [object]$Invocation
    )

    $violations = [Collections.Generic.List[object]]::new()
    if ([bool]$Invocation.timed_out) {
        $violations.Add([pscustomobject]@{
            code = "backend_timeout"
            message = "The backend runner timed out."
        })
        return @($violations)
    }
    $stdout = [string](Get-AbOptionalProperty $Invocation "stdout" "")
    $stderr = [string](Get-AbOptionalProperty $Invocation "stderr" "")
    if (Test-AbOutputContainsEngineError $stdout) {
        $violations.Add([pscustomobject]@{
            code = "backend_stdout_engine_error"
            message = "Backend stdout contained SCRIPT ERROR or ERROR:."
        })
    }
    if (Test-AbOutputContainsEngineError $stderr) {
        $violations.Add([pscustomobject]@{
            code = "backend_stderr_engine_error"
            message = "Backend stderr contained SCRIPT ERROR or ERROR:."
        })
    }
    $payload = $Invocation.payload
    if ($null -eq $payload) {
        $violations.Add([pscustomobject]@{
            code = "missing_backend_payload"
            message = "The backend runner did not return JSON."
        })
        return @($violations)
    }
    if ([int]$Invocation.exit_code -ne 0) {
        $violations.Add([pscustomobject]@{
            code = "backend_exit_code"
            message = "The backend runner exited with $($Invocation.exit_code)."
        })
    }
    if (-not [bool](Get-AbOptionalProperty $payload "valid" $false)) {
        $violations.Add([pscustomobject]@{
            code = "invalid_backend_sample"
            message = "The backend marked the sample invalid."
        })
    }
    $fingerprint = Get-AbOptionalProperty $payload "fingerprint" $null
    $scenarioFingerprint = Get-AbOptionalProperty $fingerprint "scenario" $null
    $simulationFingerprint = Get-AbOptionalProperty $fingerprint "simulation" $null
    $rngFingerprint = Get-AbOptionalProperty `
        $fingerprint `
        "rng_state_evidence" `
        $null
    if (
        $null -eq $fingerprint -or
        -not [bool](Get-AbOptionalProperty `
            $fingerprint `
            "source_control_supported" `
            $false) -or
        [string]::IsNullOrWhiteSpace(
            [string](Get-AbOptionalProperty $fingerprint "commit" "")
        ) -or
        [bool](Get-AbOptionalProperty $fingerprint "dirty" $true)
    ) {
        $violations.Add([pscustomobject]@{
            code = "incomplete_source_fingerprint"
            message = "Formal evidence requires one clean, identified Git commit."
        })
    }
    if (
        [string](Get-AbOptionalProperty $scenarioFingerprint "id" "") -ne
        [string]$PlanEntry.scenario_id -or
        [int](Get-AbOptionalProperty $scenarioFingerprint "enemy_count" -1) -ne
            [int]$PlanEntry.scenario.enemy_count -or
        [string](Get-AbOptionalProperty $scenarioFingerprint "source_path" "") -ne
            [string]$PlanEntry.scenario.source_path
    ) {
        $violations.Add([pscustomobject]@{
            code = "scenario_fingerprint_mismatch"
            message = "The fingerprint scenario/source/count did not match the ABBA plan."
        })
    }
    if (
        [int](Get-AbOptionalProperty $scenarioFingerprint "flow_state" -1) -ne 1 -or
        -not [bool](Get-AbOptionalProperty $scenarioFingerprint "is_night" $false) -or
        [Math]::Abs(
            [double](Get-AbOptionalProperty $scenarioFingerprint "night_factor" -1.0) -
            1.0
        ) -gt 0.000001
    ) {
        $violations.Add([pscustomobject]@{
            code = "first_night_runtime_mismatch"
            message = "The formal sample was not captured in WAVE_ACTIVE at full night."
        })
    }
    $buildingFingerprint = Get-AbOptionalProperty `
        $scenarioFingerprint `
        "building_composition" `
        $null
    if (
        [int](Get-AbOptionalProperty $buildingFingerprint "simple_fence" -1) -ne
            [int]$PlanEntry.scenario.fence_count -or
        [int](Get-AbOptionalProperty $buildingFingerprint "corn" -1) -ne
            [int]$PlanEntry.scenario.corn_count -or
        [int](Get-AbOptionalProperty $buildingFingerprint "agave" -1) -ne
            [int]$PlanEntry.scenario.agave_count -or
        [int](Get-AbOptionalProperty $buildingFingerprint "total" -1) -ne
            ([int]$PlanEntry.scenario.fence_count +
                [int]$PlanEntry.scenario.corn_count +
                [int]$PlanEntry.scenario.agave_count) -or
        [string](Get-AbOptionalProperty `
            $buildingFingerprint `
            "placement_scope" `
            "") -ne $(if (
                [int]$PlanEntry.scenario.fence_count +
                [int]$PlanEntry.scenario.corn_count +
                [int]$PlanEntry.scenario.agave_count -gt 0
            ) { "in_field" } else { "none" })
    ) {
        $violations.Add([pscustomobject]@{
            code = "building_fingerprint_mismatch"
            message = "The sample did not contain the planned real building fixture."
        })
    }
    $productionRegistration = Get-AbOptionalProperty `
        $scenarioFingerprint `
        "production_registration" `
        $null
    $registrationBefore = Get-AbOptionalProperty `
        $productionRegistration `
        "before_measurement" `
        $null
    $registrationLedger = Get-AbOptionalProperty `
        $registrationBefore `
        "ledger" `
        $null
    $registrationLedgerSnapshot = Get-AbOptionalProperty `
        $registrationLedger `
        "snapshot" `
        $null
    $registrationNetwork = Get-AbOptionalProperty `
        $registrationBefore `
        "network_registry" `
        $null
    $registrationCombatIndex = Get-AbOptionalProperty `
        $registrationBefore `
        "combat_target_index" `
        $null
    $registrationPlantIndex = Get-AbOptionalProperty `
        $registrationBefore `
        "plant_objective_index" `
        $null
    if (
        -not [bool](Get-AbOptionalProperty `
            $productionRegistration `
            "required" `
            $false) -or
        [int](Get-AbOptionalProperty $registrationBefore "runtime_mode" -1) -ne 1 -or
        [string](Get-AbOptionalProperty `
            $registrationBefore `
            "current_flow_step_path" `
            "") -ne [string]$PlanEntry.scenario.flow_step_path -or
        [int](Get-AbOptionalProperty `
            $registrationLedgerSnapshot `
            "total" `
            -1) -ne [int]$PlanEntry.scenario.enemy_count -or
        [int](Get-AbOptionalProperty `
            $registrationLedgerSnapshot `
            "spawned" `
            -1) -ne [int]$PlanEntry.scenario.enemy_count -or
        [int](Get-AbOptionalProperty `
            $registrationLedger `
            "active_count" `
            -1) -ne [int]$PlanEntry.scenario.enemy_count -or
        [int](Get-AbOptionalProperty `
            $registrationNetwork `
            "registered_count" `
            -1) -ne [int]$PlanEntry.scenario.enemy_count -or
        [int](Get-AbOptionalProperty `
            $registrationCombatIndex `
            "registered_count" `
            -1) -ne [int]$PlanEntry.scenario.enemy_count -or
        [int](Get-AbOptionalProperty `
            $registrationPlantIndex `
            "tracked_enemies" `
            -1) -ne [int]$PlanEntry.scenario.enemy_count
    ) {
        $violations.Add([pscustomobject]@{
            code = "production_registration_fingerprint_mismatch"
            message = (
                "The formal sample did not enter through the production wave, " +
                "network and target-index registration path."
            )
        })
    }
    $scenarioContract = Get-AbOptionalProperty `
        $scenarioFingerprint `
        "scenario_contract" `
        $null
    if (
        [string](Get-AbOptionalProperty $scenarioContract "fixture_kind" "") -ne
            [string]$PlanEntry.scenario.fixture_kind -or
        [string](Get-AbOptionalProperty $scenarioContract "flow_step_path" "") -ne
            [string]$PlanEntry.scenario.flow_step_path -or
        [int](Get-AbOptionalProperty $scenarioContract "host_enemy_count" -1) -ne
            [int]$PlanEntry.scenario.enemy_count -or
        [int](Get-AbOptionalProperty $scenarioContract "allied_enemy_count" -1) -ne
            [int]$PlanEntry.scenario.allied_enemy_count -or
        [int](Get-AbOptionalProperty $scenarioContract "hostile_enemy_count" -1) -ne
            [int]$PlanEntry.scenario.hostile_enemy_count -or
        [int](Get-AbOptionalProperty `
            $scenarioContract `
            "unreachable_assignment_count" `
            -1) -ne [int]$PlanEntry.scenario.unreachable_assignment_count -or
        [int](Get-AbOptionalProperty $scenarioContract "client_proxy_count" -1) -ne
            [int]$PlanEntry.scenario.client_proxy_count -or
        -not [bool](Get-AbOptionalProperty `
            $scenarioContract `
            "host_authority_verified" `
            $false) -or
        -not [bool](Get-AbOptionalProperty `
            $scenarioContract `
            "host_configured_before_tree" `
            $false)
    ) {
        $violations.Add([pscustomobject]@{
            code = "scenario_adapter_contract_mismatch"
            message = "The measured fixture did not satisfy its formal scenario adapter contract."
        })
    }
    switch ([string]$PlanEntry.scenario.fixture_kind) {
        "basic_pursuit" {
            if ([int](Get-AbOptionalProperty `
                $scenarioContract `
                "basic_pursuit_count" `
                -1) -ne 300) {
                $violations.Add([pscustomobject]@{
                    code = "basic_pursuit_contract_mismatch"
                    message = "The basic pursuit adapter did not retain 300 authored basic enemies."
                })
            }
        }
        "tower_projectile" {
            if (
                [int](Get-AbOptionalProperty $scenarioContract "tower_count" -1) -ne 96 -or
                [int](Get-AbOptionalProperty `
                    $scenarioContract `
                    "tower_total_shots" `
                    -1) -lt $script:TowerMinimumTotalShots -or
                [int](Get-AbOptionalProperty `
                    $scenarioContract `
                    "tower_agave_projectile_shots" `
                    -1) -lt $script:TowerMinimumAgaveProjectileShots -or
                [int](Get-AbOptionalProperty `
                    $scenarioContract `
                    "tower_peak_concurrent_projectiles" `
                    -1) -lt $script:TowerMinimumConcurrentProjectiles -or
                -not [bool](Get-AbOptionalProperty `
                    $scenarioContract `
                    "projectile_pressure_verified" `
                    $false)
            ) {
                $violations.Add([pscustomobject]@{
                    code = "tower_projectile_contract_mismatch"
                    message = "The tower adapter did not prove 96 active towers and projectile pressure."
                })
            }
        }
        "faction_battle" {
            $targetsStart = Get-AbOptionalProperty `
                $scenarioContract `
                "faction_valid_dynamic_targets_start" `
                $null
            $targetsEnd = Get-AbOptionalProperty `
                $scenarioContract `
                "faction_valid_dynamic_targets_end" `
                $null
            $damageTaken = Get-AbOptionalProperty `
                $scenarioContract `
                "faction_damage_taken" `
                $null
            if (
                [int](Get-AbOptionalProperty `
                    $scenarioContract `
                    "paired_dynamic_target_count" `
                    -1) -ne 300 -or
                [int](Get-AbOptionalProperty $targetsStart "allied" -1) -ne 150 -or
                [int](Get-AbOptionalProperty $targetsStart "hostile" -1) -ne 150 -or
                [int](Get-AbOptionalProperty $targetsEnd "allied" -1) -ne 150 -or
                [int](Get-AbOptionalProperty $targetsEnd "hostile" -1) -ne 150 -or
                [long](Get-AbOptionalProperty `
                    $damageTaken `
                    "allied_damage_taken" `
                    0) -le 0 -or
                [long](Get-AbOptionalProperty `
                    $damageTaken `
                    "hostile_damage_taken" `
                    0) -le 0 -or
                [int](Get-AbOptionalProperty `
                    $damageTaken `
                    "allied_damaged_enemy_count" `
                    0) -le 0 -or
                [int](Get-AbOptionalProperty `
                    $damageTaken `
                    "hostile_damaged_enemy_count" `
                    0) -le 0
            ) {
                $violations.Add([pscustomobject]@{
                    code = "faction_battle_contract_mismatch"
                    message = "The faction adapter did not prove 150v150 paired dynamic targets."
                })
            }
        }
        "water_unreachable" {
            if (
                -not [bool](Get-AbOptionalProperty `
                    $scenarioContract `
                    "water_target_verified" `
                    $false) -or
                -not [bool](Get-AbOptionalProperty `
                    $scenarioContract `
                    "disconnected_connectivity_verified" `
                    $false)
            ) {
                $violations.Add([pscustomobject]@{
                    code = "water_unreachable_contract_mismatch"
                    message = "The obstacle adapter did not prove a water target and disconnected navigation."
                })
            }
        }
        "host_client_proxy" {
            $proxyStart = Get-AbOptionalProperty `
                $scenarioContract `
                "client_proxy_start" `
                $null
            $proxyEnd = Get-AbOptionalProperty `
                $scenarioContract `
                "client_proxy_end" `
                $null
            if (
                [int](Get-AbOptionalProperty `
                    $scenarioContract `
                    "client_index_count" `
                    -1) -ne 1000 -or
                [int](Get-AbOptionalProperty `
                    $scenarioContract `
                    "client_authoritative_registered_count" `
                    -1) -ne 0 -or
                -not (Test-AbClientProxyAuthorityBoundary $proxyStart) -or
                -not (Test-AbClientProxyAuthorityBoundary $proxyEnd) -or
                [long](Get-AbOptionalProperty `
                    $scenarioContract `
                    "client_authoritative_attack_delta" `
                    -1) -ne 0 -or
                [long](Get-AbOptionalProperty `
                    $scenarioContract `
                    "client_authoritative_damage_delta" `
                    -1) -ne 0 -or
                [long](Get-AbOptionalProperty `
                    $scenarioContract `
                    "client_authoritative_kill_delta" `
                    -1) -ne 0 -or
                [long](Get-AbOptionalProperty `
                    $scenarioContract `
                    "client_authoritative_reward_delta" `
                    -1) -ne 0
            ) {
                $violations.Add([pscustomobject]@{
                    code = "host_client_proxy_contract_mismatch"
                    message = "The client adapter did not retain 1,000 indexed non-authoritative proxies."
                })
            }
        }
    }
    $godot = Get-AbOptionalProperty $payload "godot" $null
    $godotRngEvidence = Get-AbOptionalProperty `
        $godot `
        "rng_state_evidence" `
        $null
    $rngStart = Get-AbOptionalProperty $godotRngEvidence "start" $null
    $rngEnd = Get-AbOptionalProperty $godotRngEvidence "end" $null
    if (
        -not (Test-AbFormalRandomStateBoundary `
            $rngStart `
            ([int]$PlanEntry.seed) `
            ([int]$PlanEntry.scenario.enemy_count) `
            ([int]$PlanEntry.scenario.corn_count) `
            ([int]$PlanEntry.scenario.agave_count)) -or
        -not (Test-AbFormalRandomStateBoundary `
            $rngEnd `
            ([int]$PlanEntry.seed) `
            ([int]$PlanEntry.scenario.enemy_count) `
            ([int]$PlanEntry.scenario.corn_count) `
            ([int]$PlanEntry.scenario.agave_count)) -or
        ($rngFingerprint | ConvertTo-Json -Depth 30 -Compress) -cne
            ($godotRngEvidence | ConvertTo-Json -Depth 30 -Compress)
    ) {
        $violations.Add([pscustomobject]@{
            code = "rng_state_evidence_mismatch"
            message = "The run omitted or forged post-ready RNG state evidence."
        })
    }
    if ([int](Get-AbOptionalProperty $fingerprint "seed" -1) -ne [int]$PlanEntry.seed) {
        $violations.Add([pscustomobject]@{
            code = "seed_fingerprint_mismatch"
            message = "The fingerprint seed did not match the ABBA plan."
        })
    }
    if (
        [string](Get-AbOptionalProperty $simulationFingerprint "actual_mode" "") -ne
        [string]$PlanEntry.mode
    ) {
        $violations.Add([pscustomobject]@{
            code = "simulation_mode_mismatch"
            message = "The actual coordinator mode did not match the ABBA plan."
        })
    }
    $sampling = Get-AbOptionalProperty $godot "sampling_contract" $null
    $simulation = Get-AbOptionalProperty $godot "enemy_simulation" $null
    $aliveStart = [int](Get-AbOptionalProperty $godot "alive_start" -1)
    $aliveEnd = [int](Get-AbOptionalProperty $godot "alive_end" -1)
    $expectedEnemyCount = [int]$PlanEntry.scenario.enemy_count
    $maximumExpectedSteps = $aliveStart * $script:RequiredSampleTicks
    $minimumExpectedSteps = $aliveEnd * $script:RequiredSampleTicks
    if (
        -not [bool](Get-AbOptionalProperty `
            $sampling `
            "authoritative_tick_sampling" `
            $false) -or
        [int](Get-AbOptionalProperty $godot "physics_frames_elapsed" -1) -ne
            $script:RequiredSampleTicks
    ) {
        $violations.Add([pscustomobject]@{
            code = "authoritative_tick_mismatch"
            message = "The sample did not cover exactly 1800 authoritative physics ticks."
        })
    }
    if ($aliveStart -ne $expectedEnemyCount) {
        $violations.Add([pscustomobject]@{
            code = "formal_starting_cohort_mismatch"
            message = (
                "The formal scenario started with $aliveStart enemies; " +
                "expected $expectedEnemyCount."
            )
        })
    }
    $contactRegistrationCount = [int](Get-AbOptionalProperty `
        $simulation `
        "contact_registration_count" `
        -1)
    $touchMonitoringStart = [int](Get-AbOptionalProperty `
        $godot `
        "touch_damage_area_monitoring_start" `
        -1)
    $registrationRejections = [int](Get-AbOptionalProperty `
        $simulation `
        "registration_rejections" `
        -1)
    $contactRegistrationRejections = [int](Get-AbOptionalProperty `
        $simulation `
        "contact_registration_rejections" `
        -1)
    if ([string]$PlanEntry.mode -eq $script:CandidateMode) {
        if (
            [int](Get-AbOptionalProperty $simulation "physics_ticks" -1) -ne
                $script:RequiredSampleTicks -or
            [int](Get-AbOptionalProperty $simulation "authoritative_steps" -1) -lt
                $minimumExpectedSteps -or
            [int](Get-AbOptionalProperty $simulation "authoritative_steps" -1) -gt
                $maximumExpectedSteps -or
            [int](Get-AbOptionalProperty $simulation "registered_start" -1) -ne
                $expectedEnemyCount -or
            [int](Get-AbOptionalProperty $simulation "active_start" -1) -ne
                $expectedEnemyCount -or
            [int](Get-AbOptionalProperty $simulation "registered" -1) -ne
                $aliveEnd -or
            [int](Get-AbOptionalProperty $simulation "active" -1) -ne
                $aliveEnd -or
            [int](Get-AbOptionalProperty `
                $godot `
                "individual_physics_processing_start" `
                -1) -ne 0
        ) {
            $violations.Add([pscustomobject]@{
                code = "candidate_coordinator_ownership_mismatch"
                message = (
                    "LAYERED_CONTACT did not exclusively own the complete formal " +
                    "cohort for the authoritative window."
                )
            })
        }
        if (
            $contactRegistrationCount -lt 0 -or
            $contactRegistrationCount + $touchMonitoringStart -ne
                $expectedEnemyCount
        ) {
            $violations.Add([pscustomobject]@{
                code = "candidate_contact_registration_mismatch"
                message = (
                    "LAYERED_CONTACT registered $contactRegistrationCount shared " +
                    "contact proxies and retained $touchMonitoringStart authored " +
                    "monitors; the disjoint total must equal $expectedEnemyCount."
                )
            })
        }
        if ($registrationRejections -ne 0 -or $contactRegistrationRejections -ne 0) {
            $violations.Add([pscustomobject]@{
                code = "candidate_registration_rejected"
                message = (
                    "LAYERED_CONTACT observed simulation/contact registration " +
                    "rejections ($registrationRejections/$contactRegistrationRejections)."
                )
            })
        }
        $maximumMonitoredTouchAreas = [int][Math]::Floor(
            $expectedEnemyCount * $script:MaximumCandidateTouchMonitoringRatio
        )
        if (
            $touchMonitoringStart -lt 0 -or
            $touchMonitoringStart -gt $maximumMonitoredTouchAreas
        ) {
            $violations.Add([pscustomobject]@{
                code = "candidate_touch_area_reduction_mismatch"
                message = (
                    "LAYERED_CONTACT retained $touchMonitoringStart monitored " +
                    "TouchDamageArea nodes; at most $maximumMonitoredTouchAreas " +
                    "is allowed for a 95% reduction."
                )
            })
        }
    } elseif ([string]$PlanEntry.mode -eq $script:LegacyMode) {
        if (
            [int](Get-AbOptionalProperty $simulation "registered_start" -1) -ne 0 -or
            [int](Get-AbOptionalProperty $simulation "active_start" -1) -ne 0 -or
            [int](Get-AbOptionalProperty $simulation "registered" -1) -ne 0 -or
            [int](Get-AbOptionalProperty $simulation "active" -1) -ne 0 -or
            [int](Get-AbOptionalProperty $simulation "physics_ticks" -1) -ne 0 -or
            [int](Get-AbOptionalProperty $simulation "authoritative_steps" -1) -ne 0
        ) {
            $violations.Add([pscustomobject]@{
                code = "legacy_coordinator_work"
                message = "LEGACY unexpectedly registered enemies or executed coordinator work."
            })
        }
        if (
            [int](Get-AbOptionalProperty `
                $godot `
                "individual_physics_processing_start" `
                -1) -ne $expectedEnemyCount
        ) {
            $violations.Add([pscustomobject]@{
                code = "legacy_individual_ownership_mismatch"
                message = "LEGACY did not retain one physics callback per formal enemy."
            })
        }
        if ($contactRegistrationCount -ne 0 -or $touchMonitoringStart -ne $expectedEnemyCount) {
            $violations.Add([pscustomobject]@{
                code = "legacy_contact_ownership_mismatch"
                message = (
                    "LEGACY must keep all authored TouchDamageArea monitors and no " +
                    "shared-contact registrations."
                )
            })
        }
    } else {
        $violations.Add([pscustomobject]@{
            code = "unsupported_ab_mode"
            message = "The A/B plan contained an unsupported mode: $($PlanEntry.mode)."
        })
    }
    $catchup = Get-AbOptionalProperty $godot "physics_catchup" $null
    if (
        [int](Get-AbOptionalProperty $catchup "max_steps_per_render_sample" -1) -ne 1 -or
        [int](Get-AbOptionalProperty $catchup "samples_with_multiple_steps" -1) -ne 0
    ) {
        $violations.Add([pscustomobject]@{
            code = "multi_physics_step_sample"
            message = "At least one A/B sample did not contain exactly one physics step."
        })
    }
    return @($violations)
}


function New-AbPairedResult {
    param(
        [object]$LegacyRecord,
        [object]$CandidateRecord,
        [int]$PairIndex
    )

    $legacyP95 = [double]$LegacyRecord.wall_p95_ms
    $candidateP95 = [double]$CandidateRecord.wall_p95_ms
    $ratio = if ($legacyP95 -gt 0.0) {
        $candidateP95 / $legacyP95
    } else {
        [double]::PositiveInfinity
    }
    return [pscustomobject][ordered]@{
        pair_index = $PairIndex
        legacy_ordinal = $LegacyRecord.ordinal
        candidate_ordinal = $CandidateRecord.ordinal
        legacy_p95_ms = $legacyP95
        candidate_p95_ms = $candidateP95
        candidate_over_legacy_ratio = $ratio
        improvement_ratio = 1.0 - $ratio
    }
}


function Get-AbScenarioVerdict {
    param(
        [object]$Scenario,
        [object[]]$Pairs,
        [bool]$InputsValid
    )

    if (-not $InputsValid -or $Pairs.Count -eq 0) {
        return [pscustomobject][ordered]@{
            scenario_id = $Scenario.id
            valid = $false
            verdict = "invalid"
            median_paired_p95_ratio = $null
            median_improvement_ratio = $null
            maximum_ratio = [double]$Scenario.maximum_paired_p95_ratio
        }
    }
    $ratios = @(
        $Pairs | ForEach-Object {
            [double]$_.candidate_over_legacy_ratio
        }
    )
    $medianRatio = Get-AbMedian $ratios
    $maximumObservedRatio = [double](
        $ratios | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    )
    $gateRatio = if ([string]$Scenario.role -eq "critical") {
        $maximumObservedRatio
    } else {
        [double]$medianRatio
    }
    $passed = $gateRatio -le [double]$Scenario.maximum_paired_p95_ratio
    return [pscustomobject][ordered]@{
        scenario_id = $Scenario.id
        role = $Scenario.role
        valid = $true
        verdict = if ($passed) { "passed" } else { "failed" }
        pair_count = $Pairs.Count
        median_paired_p95_ratio = [double]$medianRatio
        median_improvement_ratio = 1.0 - [double]$medianRatio
        maximum_observed_paired_p95_ratio = $maximumObservedRatio
        gate_statistic = if ([string]$Scenario.role -eq "critical") {
            "maximum"
        } else {
            "median"
        }
        maximum_ratio = [double]$Scenario.maximum_paired_p95_ratio
    }
}


function Get-AbGroupVerdict {
    param(
        [bool]$InputsValid,
        [object[]]$ScenarioVerdicts
    )

    if (-not $InputsValid -or @($ScenarioVerdicts | Where-Object {
        -not [bool]$_.valid
    }).Count -gt 0) {
        return "invalid"
    }
    if (@($ScenarioVerdicts | Where-Object {
        [string]$_.verdict -ne "passed"
    }).Count -gt 0) {
        return "failed"
    }
    return "passed"
}


function Get-AbBackendArguments {
    param(
        [object]$PlanEntry,
        [string]$BackendRunner,
        [string]$ResolvedProjectRoot,
        [string]$InvocationToken,
        [int]$TimeoutSeconds
    )

    $scenario = $PlanEntry.scenario
    $arguments = @(
        "-NoProfile",
        "-File", $BackendRunner,
        "-ScenarioId", [string]$scenario.id,
        "-SimulationMode", [string]$PlanEntry.mode,
        (ConvertTo-AbBoolToken "AuthoritativeTickSampling" $true),
        (ConvertTo-AbBoolToken "DetailedSemanticEvidence" $false),
        "-GateProfile", "cpu60",
        "-Phase", [string]$scenario.phase,
        "-EnemyCount", [string]$scenario.enemy_count,
        "-FenceCount", [string]$scenario.fence_count,
        "-CornCount", [string]$scenario.corn_count,
        "-AgaveCount", [string]$scenario.agave_count,
        "-WarmupFrames", [string]$script:RequiredWarmupTicks,
        "-SampleFrames", [string]$script:RequiredSampleTicks,
        "-Seed", [string]$PlanEntry.seed,
        (ConvertTo-AbBoolToken "Headless" $true),
        "-FixedFps", "60",
        "-MaxFps", "0",
        "-VsyncMode", "disabled",
        "-RenderingMethod", $RenderingMethod,
        "-RenderingDriver", $RenderingDriver,
        "-WallP95BudgetMs", "1000",
        "-WallP99BudgetMs", "1000",
        "-Over18RatioBudget", "1",
        "-Over33RatioBudget", "1",
        (ConvertTo-AbBoolToken "FenceAbMetrics" $false),
        (ConvertTo-AbBoolToken "EnemyHotMetrics" $false),
        (ConvertTo-AbBoolToken "GuardianOverlapMetrics" $false),
        (ConvertTo-AbBoolToken "RuntimeCountScans" $false),
        (ConvertTo-AbBoolToken "ProjectileHotMetrics" $false),
        "-GodotExe", $GodotExe,
        "-ProjectRoot", $ResolvedProjectRoot,
        "-ExternalSampleIntervalMs", [string]$ExternalSampleIntervalMs,
        "-MinimumExternalSamples", [string]$MinimumExternalSamples,
        "-TimeoutSeconds", [string]$TimeoutSeconds,
        "-InvocationToken", $InvocationToken
    )
    if ([string]::IsNullOrWhiteSpace([string]$scenario.wave_config)) {
        $arguments += @("-EnemyConfig", [string]$scenario.enemy_config)
    }
    else {
        $arguments += @("-WaveConfig", [string]$scenario.wave_config)
    }
    return $arguments
}


function Get-AbProcessIdentity {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $creationUtc = ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
    return "$([int]$CimProcess.ProcessId)|$($creationUtc.Ticks)"
}


function Test-AbCommandLineHasExactArgument {
    param(
        [string]$CommandLine,
        [string]$Argument
    )

    if (
        [string]::IsNullOrWhiteSpace($CommandLine) -or
        [string]::IsNullOrWhiteSpace($Argument)
    ) {
        return $false
    }
    return [regex]::IsMatch(
        $CommandLine,
        ('(?:^|\s|"){0}(?=\s|"|$)' -f [regex]::Escape($Argument)),
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}


function Test-AbCommandLineHasExactSwitchValue {
    param(
        [string]$CommandLine,
        [string]$Switch,
        [string]$Value
    )

    if (
        [string]::IsNullOrWhiteSpace($CommandLine) -or
        [string]::IsNullOrWhiteSpace($Switch) -or
        [string]::IsNullOrWhiteSpace($Value)
    ) {
        return $false
    }
    $pattern = '(?:^|\s){0}\s+(?:"{1}"|{1})(?=\s|$)' -f @(
        [regex]::Escape($Switch),
        [regex]::Escape($Value)
    )
    return [regex]::IsMatch(
        $CommandLine,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}


function Test-AbOwnedBackendRootMarker {
    param(
        [Parameter(Mandatory = $true)]$CimProcess,
        [string]$InvocationToken,
        [string]$BackendRunner
    )

    if (
        $CimProcess.Name -ine "pwsh.exe" -or
        [string]::IsNullOrWhiteSpace([string]$CimProcess.CommandLine)
    ) {
        return $false
    }
    $commandLine = [string]$CimProcess.CommandLine
    return (
        (Test-AbCommandLineHasExactSwitchValue `
            $commandLine `
            "-File" `
            $BackendRunner) -and
        (Test-AbCommandLineHasExactSwitchValue `
            $commandLine `
            "-InvocationToken" `
            $InvocationToken)
    )
}


function Register-AbOwnedProcess {
    param([Parameter(Mandatory = $true)]$CimProcess)

    $processId = [int]$CimProcess.ProcessId
    if (-not $script:OwnedProcessIdentityByPid.ContainsKey($processId)) {
        $script:OwnedProcessIdentityByPid[$processId] = Get-AbProcessIdentity $CimProcess
        $script:OwnedProcessCreationUtcByPid[$processId] = (
            ([DateTime]$CimProcess.CreationDate).ToUniversalTime()
        )
    }
}


function Initialize-AbOwnedProcessTree {
    param(
        [int]$RootProcessId,
        [string]$InvocationToken,
        [string]$BackendRunner,
        [DateTime]$StartedUtc
    )

    $script:OwnedProcessIdentityByPid = @{}
    $script:OwnedProcessCreationUtcByPid = @{}
    $root = $null
    for ($attempt = 0; $attempt -lt 10 -and $null -eq $root; $attempt += 1) {
        $root = Get-CimInstance `
            Win32_Process `
            -Filter "ProcessId = $RootProcessId" `
            -ErrorAction Stop
        if ($null -eq $root) {
            Start-Sleep -Milliseconds 50
        }
    }
    if (
        $null -eq $root -or
        ([DateTime]$root.CreationDate).ToUniversalTime() -lt
            $StartedUtc.AddSeconds(-2) -or
        -not (Test-AbOwnedBackendRootMarker `
            $root `
            $InvocationToken `
            $BackendRunner)
    ) {
        throw "The A/B backend root did not match its exact PID/token/script identity."
    }
    Register-AbOwnedProcess $root
}


function Update-AbOwnedProcessTree {
    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($processInfo in $snapshot) {
            $processId = [int]$processInfo.ProcessId
            $parentId = [int]$processInfo.ParentProcessId
            if (
                $script:OwnedProcessIdentityByPid.ContainsKey($processId) -or
                -not $script:OwnedProcessIdentityByPid.ContainsKey($parentId)
            ) {
                continue
            }
            $creationUtc = ([DateTime]$processInfo.CreationDate).ToUniversalTime()
            if ($creationUtc -lt $script:OwnedProcessCreationUtcByPid[$parentId]) {
                continue
            }
            Register-AbOwnedProcess $processInfo
            $changed = $true
        }
    }
    return $snapshot
}


function Get-LiveAbOwnedProcesses {
    $snapshot = @(Update-AbOwnedProcessTree)
    return @($snapshot | Where-Object {
        $processId = [int]$_.ProcessId
        $script:OwnedProcessIdentityByPid.ContainsKey($processId) -and
        $script:OwnedProcessIdentityByPid[$processId] -eq (Get-AbProcessIdentity $_)
    })
}


function Stop-AbOwnedProcessTree {
    if ($script:OwnedProcessIdentityByPid.Count -eq 0) {
        return
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $live = @(Get-LiveAbOwnedProcesses)
        if ($live.Count -eq 0) {
            $script:OwnedProcessIdentityByPid = @{}
            $script:OwnedProcessCreationUtcByPid = @{}
            return
        }
        $parentByPid = @{}
        foreach ($processInfo in $live) {
            $parentByPid[[int]$processInfo.ProcessId] = [int]$processInfo.ParentProcessId
        }
        $depthByPid = @{}
        foreach ($processInfo in $live) {
            $processId = [int]$processInfo.ProcessId
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
                $depth += 1
            }
            $depthByPid[$processId] = $depth
        }
        foreach ($processInfo in @($live | Sort-Object {
            -1 * $depthByPid[[int]$_.ProcessId]
        })) {
            Stop-Process `
                -Id ([int]$processInfo.ProcessId) `
                -Force `
                -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(Get-LiveAbOwnedProcesses)
    if ($remaining.Count -gt 0) {
        $description = @($remaining | ForEach-Object {
            "$($_.Name) PID=$($_.ProcessId)"
        }) -join ", "
        throw "A/B owned process cleanup failed: $description"
    }
    $script:OwnedProcessIdentityByPid = @{}
    $script:OwnedProcessCreationUtcByPid = @{}
}


function Invoke-AbBackend {
    param(
        [string[]]$Arguments,
        [string]$InvocationToken,
        [string]$BackendRunner,
        [int]$WaitTimeoutSeconds
    )

    $pwsh = Get-Command pwsh -ErrorAction Stop
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $startedUtc = [DateTime]::UtcNow
    try {
        if (-not $process.Start()) {
            throw "Unable to start the A/B backend runner."
        }
        $script:ActiveChildProcess = $process
        $script:ActiveInvocationToken = $InvocationToken
        $script:ActiveBackendRunnerPath = $BackendRunner
        Initialize-AbOwnedProcessTree `
            $process.Id `
            $InvocationToken `
            $BackendRunner `
            $startedUtc
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $waitDeadline = $startedUtc.AddSeconds($WaitTimeoutSeconds)
        while (
            -not $process.HasExited -and
            [DateTime]::UtcNow -lt $waitDeadline
        ) {
            $process.WaitForExit(100) | Out-Null
            Update-AbOwnedProcessTree | Out-Null
        }
        if (-not $process.HasExited) {
            try {
                $process.Kill($true)
            }
            catch {
                # The token-scoped child may already be exiting.
            }
            $process.WaitForExit(5000) | Out-Null
            Stop-AbOwnedProcessTree
            return [pscustomobject]@{
                timed_out = $true
                exit_code = -1
                elapsed_seconds = ([DateTime]::UtcNow - $startedUtc).TotalSeconds
                stdout = ""
                stderr = "The A/B backend exceeded its timeout."
                raw_json = ""
                payload = $null
            }
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $jsonMatches = [regex]::Matches($stdout, '(?m)^\{[^\r\n]+\}\r?$')
        $rawJson = if ($jsonMatches.Count -gt 0) {
            $jsonMatches[$jsonMatches.Count - 1].Value.Trim()
        } else {
            ""
        }
        $payload = if ([string]::IsNullOrWhiteSpace($rawJson)) {
            $null
        } else {
            $rawJson | ConvertFrom-Json -Depth 100
        }
        return [pscustomobject]@{
            timed_out = $false
            exit_code = [int]$process.ExitCode
            elapsed_seconds = ([DateTime]::UtcNow - $startedUtc).TotalSeconds
            stdout = $stdout
            stderr = $stderr
            raw_json = $rawJson
            payload = $payload
        }
    }
    finally {
        try {
            Stop-AbOwnedProcessTree
        }
        finally {
            $script:ActiveChildProcess = $null
            $script:ActiveInvocationToken = ""
            $script:ActiveBackendRunnerPath = ""
            $process.Dispose()
        }
    }
}


function Save-AbRawEvidence {
    param(
        [string]$SessionDirectory,
        [object]$PlanEntry,
        [object]$Invocation
    )

    $stem = "{0:D2}_{1}_seed{2}_{3}_{4}" -f @(
        [int]$PlanEntry.ordinal,
        [string]$PlanEntry.scenario_id,
        [int]$PlanEntry.seed,
        [int]$PlanEntry.block_position,
        [string]$PlanEntry.mode
    )
    $rawJson = [string]$Invocation.raw_json
    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        $rawJson = ([ordered]@{
            valid = $false
            timed_out = [bool]$Invocation.timed_out
            exit_code = [int]$Invocation.exit_code
            stdout = [string]$Invocation.stdout
            stderr = [string]$Invocation.stderr
        } | ConvertTo-Json -Depth 10 -Compress)
    }
    $jsonPath = Join-Path $SessionDirectory "$stem.raw.json"
    $hashPath = Join-Path $SessionDirectory "$stem.raw.sha256"
    $stdoutPath = Join-Path $SessionDirectory "$stem.stdout.log"
    $stdoutHashPath = Join-Path $SessionDirectory "$stem.stdout.sha256"
    $stderrPath = Join-Path $SessionDirectory "$stem.stderr.log"
    $stderrHashPath = Join-Path $SessionDirectory "$stem.stderr.sha256"
    [IO.File]::WriteAllText(
        $jsonPath,
        $rawJson,
        [Text.UTF8Encoding]::new($false)
    )
    $hash = Get-AbSha256Hex $rawJson
    [IO.File]::WriteAllText(
        $hashPath,
        "$hash  $([IO.Path]::GetFileName($jsonPath))`n",
        [Text.UTF8Encoding]::new($false)
    )
    $stdout = [string]$Invocation.stdout
    $stderr = [string]$Invocation.stderr
    [IO.File]::WriteAllText(
        $stdoutPath,
        $stdout,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $stderrPath,
        $stderr,
        [Text.UTF8Encoding]::new($false)
    )
    $stdoutHash = Get-AbSha256Hex $stdout
    $stderrHash = Get-AbSha256Hex $stderr
    [IO.File]::WriteAllText(
        $stdoutHashPath,
        "$stdoutHash  $([IO.Path]::GetFileName($stdoutPath))`n",
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $stderrHashPath,
        "$stderrHash  $([IO.Path]::GetFileName($stderrPath))`n",
        [Text.UTF8Encoding]::new($false)
    )
    return [pscustomobject][ordered]@{
        json_path = $jsonPath
        sha256_path = $hashPath
        sha256 = $hash
        stdout_path = $stdoutPath
        stdout_sha256_path = $stdoutHashPath
        stdout_sha256 = $stdoutHash
        stderr_path = $stderrPath
        stderr_sha256_path = $stderrHashPath
        stderr_sha256 = $stderrHash
    }
}


if ($LibraryOnly) {
    return
}

$normalizedScenarios = @($ScenarioIds | Select-Object -Unique)
$normalizedSeeds = @($Seeds | Select-Object -Unique)
if ($normalizedScenarios.Count -ne $script:FormalScenarioIds.Count -or @(
    $normalizedScenarios | Where-Object {
        $_ -notin $script:FormalScenarioIds
    }
).Count -gt 0) {
    throw (
        "Formal acceptance requires every declared scenario exactly once: " +
        ($script:FormalScenarioIds -join ", ")
    )
}
if ($normalizedSeeds.Count -ne 3) {
    throw "Formal acceptance requires exactly three distinct seeds."
}

$resolvedProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$backendRunner = Join-Path $PSScriptRoot $script:BackendRunnerName
if (-not (Test-Path -LiteralPath $backendRunner -PathType Leaf)) {
    throw "Cohort backend runner was not found: $backendRunner"
}
if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) {
    throw "Godot executable was not found: $GodotExe"
}

$plan = New-AbbaRunPlan $normalizedScenarios $normalizedSeeds
$planSummary = [ordered]@{
    schema_version = $script:AcceptanceSchemaVersion
    order = "ABBA"
    pair_policy = "adjacent A-B and B-A pairs"
    legacy_mode = $script:LegacyMode
    candidate_mode = $script:CandidateMode
    scenarios = @($normalizedScenarios)
    seeds = @($normalizedSeeds)
    run_count = $plan.Count
    warmup_physics_ticks = $script:RequiredWarmupTicks
    sample_physics_ticks = $script:RequiredSampleTicks
    main_minimum_improvement_ratio = 1.0 - $script:MainMaximumRatio
    critical_maximum_regression_ratio = $script:CriticalMaximumRatio - 1.0
    expected_isolated_process_count = $plan.Count
    detailed_semantic_evidence = $false
}
if (-not $Execute) {
    [ordered]@{
        schema_version = $script:AcceptanceSchemaVersion
        mode = "dry_run"
        valid = $true
        verdict = "planned"
        execute_required = $true
        settings = $planSummary
        plan = @($plan)
    } | ConvertTo-Json -Depth 20 -Compress
    exit 0
}

$startedUtc = [DateTime]::UtcNow
$deadlineUtc = $startedUtc.AddSeconds($GlobalTimeoutSeconds)
$sessionToken = [Guid]::NewGuid().ToString("N")
$sessionDirectory = Join-Path $OutputRoot (
    "{0}_{1}" -f $startedUtc.ToString("yyyyMMdd_HHmmss"), $sessionToken
)
$null = New-Item -ItemType Directory -Path $sessionDirectory -Force
$records = [Collections.Generic.List[object]]::new()
$violations = [Collections.Generic.List[object]]::new()
$referenceEnvironmentFingerprint = $null

try {
    foreach ($entry in $plan) {
        $remainingSeconds = [int][Math]::Floor(
            ($deadlineUtc - [DateTime]::UtcNow).TotalSeconds
        )
        if ($remainingSeconds -le 0) {
            $violations.Add([pscustomobject]@{
                code = "global_timeout"
                message = "The full A/B acceptance group exceeded its timeout."
            })
            break
        }
        $invocationToken = "enemyab_$($sessionToken)_$($entry.ordinal)"
        $childTimeout = [Math]::Min($PerRunTimeoutSeconds, $remainingSeconds)
        $arguments = Get-AbBackendArguments `
            $entry `
            $backendRunner `
            $resolvedProjectRoot `
            $invocationToken `
            $childTimeout
        $invocation = Invoke-AbBackend `
            $arguments `
            $invocationToken `
            $backendRunner `
            $childTimeout
        $evidence = Save-AbRawEvidence $sessionDirectory $entry $invocation
        $contractViolations = @(Get-AbRunContractViolations $entry $invocation)
        $payload = $invocation.payload
        $fingerprint = Get-AbOptionalProperty $payload "fingerprint" $null
        if ($null -ne $fingerprint) {
            if ($null -eq $referenceEnvironmentFingerprint) {
                $referenceEnvironmentFingerprint = $fingerprint
            } elseif (-not (Test-AbFingerprintCompatible `
                $referenceEnvironmentFingerprint `
                $fingerprint `
                -EnvironmentOnly)) {
                $contractViolations += [pscustomobject]@{
                    code = "environment_fingerprint_mismatch"
                    message = "A run used a different build or runtime environment fingerprint."
                }
            }
        }
        $godot = Get-AbOptionalProperty $payload "godot" $null
        $wall = Get-AbOptionalProperty $godot "wall_ms" $null
        $record = [pscustomobject][ordered]@{
            ordinal = [int]$entry.ordinal
            scenario_id = [string]$entry.scenario_id
            seed = [int]$entry.seed
            block_position = [int]$entry.block_position
            pair_index = [int]$entry.pair_index
            mode = [string]$entry.mode
            valid = $contractViolations.Count -eq 0
            wall_p95_ms = [double](Get-AbOptionalProperty $wall "p95" 0.0)
            fingerprint = $fingerprint
            violations = @($contractViolations)
            raw_evidence = $evidence
            elapsed_seconds = [double]$invocation.elapsed_seconds
        }
        $records.Add($record)
        foreach ($violation in $contractViolations) {
            $violations.Add([pscustomobject][ordered]@{
                ordinal = [int]$entry.ordinal
                scenario_id = [string]$entry.scenario_id
                seed = [int]$entry.seed
                mode = [string]$entry.mode
                code = [string]$violation.code
                message = [string]$violation.message
            })
        }
    }
}
finally {
    if ($null -ne $script:ActiveChildProcess -and -not $script:ActiveChildProcess.HasExited) {
        try {
            $script:ActiveChildProcess.Kill($true)
            $script:ActiveChildProcess.WaitForExit(5000) | Out-Null
        }
        catch {
            # The token-scoped child may already have terminated.
        }
    }
    Stop-AbOwnedProcessTree
}

$pairs = [Collections.Generic.List[object]]::new()
foreach ($scenarioId in $normalizedScenarios) {
    foreach ($seed in $normalizedSeeds) {
        $block = @($records | Where-Object {
            $_.scenario_id -eq $scenarioId -and $_.seed -eq $seed
        } | Sort-Object block_position)
        if ($block.Count -ne 4) {
            $violations.Add([pscustomobject]@{
                code = "incomplete_abba_block"
                message = "ABBA block $scenarioId/$seed did not contain four runs."
            })
            continue
        }
        $expectedOrder = @(
            $script:LegacyMode,
            $script:CandidateMode,
            $script:CandidateMode,
            $script:LegacyMode
        ) -join ","
        if (($block.mode -join ",") -cne $expectedOrder) {
            $violations.Add([pscustomobject]@{
                code = "abba_order_mismatch"
                message = "ABBA block $scenarioId/$seed used the wrong order."
            })
            continue
        }
        $referencePairFingerprint = $block[0].fingerprint
        foreach ($sample in $block) {
            if (
                $null -eq $sample.fingerprint -or
                -not (Test-AbFingerprintCompatible `
                    $referencePairFingerprint `
                    $sample.fingerprint)
            ) {
                $violations.Add([pscustomobject]@{
                    code = "pair_fingerprint_mismatch"
                    message = "ABBA block $scenarioId/$seed mixed incompatible fingerprints."
                })
                break
            }
        }
        if (@($block | Where-Object { -not [bool]$_.valid }).Count -gt 0) {
            continue
        }
        $firstPair = New-AbPairedResult $block[0] $block[1] 0
        $secondPair = New-AbPairedResult $block[3] $block[2] 1
        foreach ($pair in @($firstPair, $secondPair)) {
            $pair | Add-Member -NotePropertyName scenario_id -NotePropertyValue $scenarioId
            $pair | Add-Member -NotePropertyName seed -NotePropertyValue $seed
            $pairs.Add($pair)
        }
    }
}

$inputsValid = (
    $records.Count -eq $plan.Count -and
    $violations.Count -eq 0
)
$scenarioVerdicts = [Collections.Generic.List[object]]::new()
foreach ($scenarioId in $normalizedScenarios) {
    $scenario = Get-AbScenarioDefinition $scenarioId
    $scenarioPairs = @($pairs | Where-Object { $_.scenario_id -eq $scenarioId })
    $scenarioVerdicts.Add(
        (Get-AbScenarioVerdict $scenario $scenarioPairs $inputsValid)
    )
}
$verdict = Get-AbGroupVerdict $inputsValid @($scenarioVerdicts)
$summary = [ordered]@{
    schema_version = $script:AcceptanceSchemaVersion
    mode = "executed"
    valid = $verdict -ne "invalid"
    verdict = $verdict
    started_utc = $startedUtc.ToString("o")
    elapsed_seconds = [Math]::Round(
        ([DateTime]::UtcNow - $startedUtc).TotalSeconds,
        3
    )
    settings = $planSummary
    expected_run_count = $plan.Count
    completed_run_count = $records.Count
    output_directory = $sessionDirectory
    environment_fingerprint = $referenceEnvironmentFingerprint
    records = @($records)
    adjacent_pairs = @($pairs)
    scenario_verdicts = @($scenarioVerdicts)
    violations = @($violations)
}
$summaryJson = $summary | ConvertTo-Json -Depth 50 -Compress
$summaryPath = Join-Path $sessionDirectory "summary.json"
$summaryHashPath = Join-Path $sessionDirectory "summary.sha256"
[IO.File]::WriteAllText(
    $summaryPath,
    $summaryJson,
    [Text.UTF8Encoding]::new($false)
)
$summaryHash = Get-AbSha256Hex $summaryJson
[IO.File]::WriteAllText(
    $summaryHashPath,
    "$summaryHash  summary.json`n",
    [Text.UTF8Encoding]::new($false)
)
$summary["summary_path"] = $summaryPath
$summary["summary_sha256_path"] = $summaryHashPath
$summary["summary_sha256"] = $summaryHash
$summary | ConvertTo-Json -Depth 50 -Compress
if ($verdict -ne "passed") {
    exit 1
}
exit 0
