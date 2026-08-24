param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "run_enemy_simulation_ab_acceptance.ps1") -LibraryOnly

$tests = [Collections.Generic.List[object]]::new()


function Add-AbRunnerSelfTest {
    param(
        [string]$Name,
        [bool]$Passed,
        [object]$Details = $null
    )

    $tests.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $Passed
        details = $Details
    })
}


function New-AbRunnerSelfTestRandomBoundary {
    param(
        [object]$Scenario,
        [int]$Seed = 17,
        [int]$StateOffset = 0
    )

    $behaviorStates = @(
        for ($index = 0; $index -lt [int]$Scenario.enemy_count; $index += 1) {
            [pscustomobject]@{
                index = $index
                seed = $Seed + $index * 2
                state = 100000 + $StateOffset + $index
            }
        }
    )
    $dropStates = @(
        for ($index = 0; $index -lt [int]$Scenario.enemy_count; $index += 1) {
            [pscustomobject]@{
                index = $index
                seed = $Seed + $index * 2 + 1
                state = 200000 + $StateOffset + $index
            }
        }
    )
    $cornStates = @(
        for ($index = 0; $index -lt [int]$Scenario.corn_count; $index += 1) {
            [pscustomobject]@{
                index = $index
                seed = $Seed + $index
                state = 300000 + $StateOffset + $index
            }
        }
    )
    $agaveStates = @(
        for ($index = 0; $index -lt [int]$Scenario.agave_count; $index += 1) {
            [pscustomobject]@{
                index = $index
                seed = $Seed + [int]$Scenario.corn_count + $index
                state = 400000 + $StateOffset + $index
            }
        }
    )
    return [pscustomobject][ordered]@{
        requested_seed = $Seed
        determinized_after_ready = $true
        runtime = [pscustomobject]@{ seed = $Seed; state = 10 + $StateOffset }
        fate_coordinator = [pscustomobject]@{
            seed = $Seed + 2000000
            state = 20 + $StateOffset
        }
        fate_manager = [pscustomobject]@{
            seed = $Seed + 2000001
            state = 30 + $StateOffset
        }
        enemy_behavior_states = $behaviorStates
        enemy_drop_states = $dropStates
        boss_skill_states = @()
        corn_idle_states = $cornStates
        agave_idle_states = $agaveStates
    }
}


function New-AbRunnerSelfTestProxyBoundary {
    return [pscustomobject][ordered]@{
        proxy_count = 1000
        network_count = 1000
        index_count = 1000
        proxy_true_count = 1000
        process_disabled_count = 1000
        physics_process_disabled_count = 1000
        area_count = 2000
        monitoring_area_count = 0
        simulation_registered_count = 0
        contact_registered_count = 0
        authoritative_attack_state_count = 0
        authoritative_damage_state_count = 0
        dead_count = 0
        total_health = 1000000000
        target_assignment_events = 0
        damage_broadcast_events = 0
        defeat_events = 0
        pending_reward = 0
        reward_flush_queued = $false
    }
}


function New-AbRunnerSelfTestFingerprint {
    param(
        [string]$Mode = "legacy",
        [int]$FenceCount = -1,
        [string]$Commit = "0123456789abcdef",
        [object]$Scenario = $null
    )

    if ($null -eq $Scenario) {
        $Scenario = Get-AbScenarioDefinition "first_night_main"
    }
    $effectiveFenceCount = if ($FenceCount -ge 0) {
        $FenceCount
    } else {
        [int]$Scenario.fence_count
    }
    $buildingTotal = (
        $effectiveFenceCount +
        [int]$Scenario.corn_count +
        [int]$Scenario.agave_count
    )
    $proxyStart = New-AbRunnerSelfTestProxyBoundary
    $proxyEnd = New-AbRunnerSelfTestProxyBoundary
    $scenarioContract = [pscustomobject][ordered]@{
        fixture_kind = [string]$Scenario.fixture_kind
        flow_step_path = [string]$Scenario.flow_step_path
        host_configured_before_tree = $true
        host_authority_verified = $true
        host_enemy_count = [int]$Scenario.enemy_count
        allied_enemy_count = [int]$Scenario.allied_enemy_count
        hostile_enemy_count = [int]$Scenario.hostile_enemy_count
        unreachable_assignment_count = [int]$Scenario.unreachable_assignment_count
        client_proxy_count = [int]$Scenario.client_proxy_count
        client_index_count = [int]$Scenario.client_proxy_count
        client_authoritative_registered_count = 0
        client_proxy_start = $proxyStart
        client_proxy_end = $proxyEnd
        client_authoritative_attack_delta = 0
        client_authoritative_damage_delta = 0
        client_authoritative_kill_delta = 0
        client_authoritative_reward_delta = 0
        basic_pursuit_count = if ($Scenario.fixture_kind -eq "basic_pursuit") {
            300
        } else { 0 }
        tower_count = [int]$Scenario.corn_count + [int]$Scenario.agave_count
        projectile_pressure_verified = $Scenario.fixture_kind -eq "tower_projectile"
        tower_total_shots = if ($Scenario.fixture_kind -eq "tower_projectile") {
            960
        } else { 0 }
        tower_agave_projectile_shots = if ($Scenario.fixture_kind -eq "tower_projectile") {
            320
        } else { 0 }
        tower_peak_concurrent_projectiles = if (
            $Scenario.fixture_kind -eq "tower_projectile"
        ) { 16 } else { 0 }
        paired_dynamic_target_count = if ($Scenario.fixture_kind -eq "faction_battle") {
            300
        } else { 0 }
        faction_valid_dynamic_targets_start = [pscustomobject]@{
            allied = if ($Scenario.fixture_kind -eq "faction_battle") { 150 } else { 0 }
            hostile = if ($Scenario.fixture_kind -eq "faction_battle") { 150 } else { 0 }
        }
        faction_valid_dynamic_targets_end = [pscustomobject]@{
            allied = if ($Scenario.fixture_kind -eq "faction_battle") { 150 } else { 0 }
            hostile = if ($Scenario.fixture_kind -eq "faction_battle") { 150 } else { 0 }
        }
        faction_damage_taken = [pscustomobject]@{
            allied_damage_taken = if ($Scenario.fixture_kind -eq "faction_battle") { 100 } else { 0 }
            hostile_damage_taken = if ($Scenario.fixture_kind -eq "faction_battle") { 100 } else { 0 }
            allied_damaged_enemy_count = if ($Scenario.fixture_kind -eq "faction_battle") { 10 } else { 0 }
            hostile_damaged_enemy_count = if ($Scenario.fixture_kind -eq "faction_battle") { 10 } else { 0 }
        }
        water_target_verified = $Scenario.fixture_kind -eq "water_unreachable"
        disconnected_connectivity_verified = $Scenario.fixture_kind -eq "water_unreachable"
    }

    return [pscustomobject][ordered]@{
        commit = $Commit
        dirty = $false
        source_control_supported = $true
        godot = [pscustomobject]@{ executable = "godot"; version = "4.test" }
        os = [pscustomobject]@{ name = "TestOS"; version = "1" }
        cpu = [pscustomobject]@{ name = "TestCPU"; logical_processor_count = 8 }
        gpu = "TestGPU"
        rendering = [pscustomobject]@{
            requested_method = "gl_compatibility"
            effective_method = "gl_compatibility"
            requested_driver = "opengl3"
            effective_driver = "opengl3"
        }
        window = [pscustomobject]@{
            requested_size = @(0, 0)
            effective_size = @(0, 0)
        }
        vsync = [pscustomobject]@{
            requested_mode = "disabled"
            effective_mode = "disabled"
        }
        seed = 17
        rng_state_evidence = [pscustomobject][ordered]@{
            start = New-AbRunnerSelfTestRandomBoundary $Scenario 17 0
            end = New-AbRunnerSelfTestRandomBoundary $Scenario 17 1000
        }
        scenario = [pscustomobject]@{
            id = [string]$Scenario.id
            phase = [string]$Scenario.phase
            flow_state = 1
            night_factor = 1.0
            is_night = $true
            enemy_count = [int]$Scenario.enemy_count
            source_path = [string]$Scenario.source_path
            enemy_composition = [pscustomobject]@{ mixed = [int]$Scenario.enemy_count }
            building_composition = [pscustomobject]@{
                simple_fence = $effectiveFenceCount
                corn = [int]$Scenario.corn_count
                agave = [int]$Scenario.agave_count
                total = $buildingTotal
                placement_scope = if ($buildingTotal -gt 0) { "in_field" } else { "none" }
            }
            scenario_contract = $scenarioContract
            production_registration = [pscustomobject]@{
                required = $true
                before_measurement = [pscustomobject]@{
                    runtime_mode = 1
                    current_flow_step_path = [string]$Scenario.flow_step_path
                    ledger = [pscustomobject]@{
                        snapshot = [pscustomobject]@{
                            total = [int]$Scenario.enemy_count
                            spawned = [int]$Scenario.enemy_count
                            defeated = 0
                            escaped = 0
                            removed = 0
                            resolved = 0
                        }
                        active_count = [int]$Scenario.enemy_count
                        attached_count = [int]$Scenario.enemy_count
                    }
                    plant_objective_index = [pscustomobject]@{
                        tracked_enemies = [int]$Scenario.enemy_count
                    }
                    network_registry = [pscustomobject]@{
                        registered_count = [int]$Scenario.enemy_count
                        continuous_initial_ids = $true
                    }
                    combat_target_index = [pscustomobject]@{
                        registered_count = [int]$Scenario.enemy_count
                    }
                    cross_store = [pscustomobject]@{
                        combat_mapping_count = [int]$Scenario.enemy_count
                        ledger_mapping_count = [int]$Scenario.enemy_count
                        network_and_combat_ids_match = $true
                    }
                }
                after_measurement = [pscustomobject]@{}
            }
        }
        simulation = [pscustomobject]@{
            requested_mode = $Mode
            actual_mode = $Mode
            authoritative_tick_sampling = $true
            warmup_physics_ticks = 300
            sample_physics_ticks = 1800
        }
        intrusive_flags = [pscustomobject]@{
            fence_ab_metrics = $false
            enemy_hot_metrics = $false
            guardian_overlap_metrics = $false
            runtime_count_scans = $false
            projectile_hot_metrics = $false
            detailed_semantic_evidence = $false
            any_enabled = $false
        }
    }
}


function New-AbRunnerSelfTestPlanEntry {
    param(
        [string]$Mode,
        [string]$ScenarioId = "first_night_main"
    )

    $scenario = Get-AbScenarioDefinition $ScenarioId
    return [pscustomobject]@{
        scenario = $scenario
        scenario_id = $scenario.id
        seed = 17
        mode = $Mode
    }
}


function New-AbRunnerSelfTestInvocation {
    param(
        [ValidateSet("legacy", "layered_contact")]
        [string]$Mode,
        [int]$ContactRegistrationCount = -1,
        [int]$IndividualPhysicsCallbacks = -1,
        [int]$MonitoredTouchAreas = -1,
        [int]$RegistrationRejections = 0,
        [int]$ContactRegistrationRejections = 0,
        [string]$ActualMode = "",
        [string]$Stdout = "",
        [string]$Stderr = "",
        [string]$ScenarioId = "first_night_main"
    )

    $scenario = Get-AbScenarioDefinition $ScenarioId
    $enemyCount = [int]$scenario.enemy_count
    $isCandidate = $Mode -eq "layered_contact"
    if ($ContactRegistrationCount -lt 0) {
        $ContactRegistrationCount = if ($isCandidate) { $enemyCount } else { 0 }
    }
    if ($IndividualPhysicsCallbacks -lt 0) {
        $IndividualPhysicsCallbacks = if ($isCandidate) { 0 } else { $enemyCount }
    }
    if ($MonitoredTouchAreas -lt 0) {
        $MonitoredTouchAreas = if ($isCandidate) { 0 } else { $enemyCount }
    }
    if ([string]::IsNullOrWhiteSpace($ActualMode)) {
        $ActualMode = $Mode
    }
    $fingerprint = New-AbRunnerSelfTestFingerprint $ActualMode -Scenario $scenario
    $registeredCount = if ($isCandidate) { $enemyCount } else { 0 }
    $physicsTicks = if ($isCandidate) { 1800 } else { 0 }
    $authoritativeSteps = if ($isCandidate) {
        $enemyCount * 1800
    } else { 0 }
    $payload = [pscustomobject]@{
        valid = $true
        fingerprint = $fingerprint
        godot = [pscustomobject]@{
            rng_state_evidence = $fingerprint.rng_state_evidence
            alive_start = $enemyCount
            alive_end = $enemyCount
            individual_physics_processing_start = $IndividualPhysicsCallbacks
            touch_damage_area_monitoring_start = $MonitoredTouchAreas
            physics_frames_elapsed = 1800
            sampling_contract = [pscustomobject]@{
                authoritative_tick_sampling = $true
            }
            enemy_simulation = [pscustomobject]@{
                registered_start = $registeredCount
                active_start = $registeredCount
                registered = $registeredCount
                active = $registeredCount
                contact_registration_count = $ContactRegistrationCount
                registration_rejections = $RegistrationRejections
                contact_registration_rejections = $ContactRegistrationRejections
                physics_ticks = $physicsTicks
                authoritative_steps = $authoritativeSteps
            }
            physics_catchup = [pscustomobject]@{
                max_steps_per_render_sample = 1
                samples_with_multiple_steps = 0
            }
        }
    }
    return [pscustomobject]@{
        timed_out = $false
        exit_code = 0
        stdout = $Stdout
        stderr = $Stderr
        payload = $payload
    }
}


function Test-AbRunnerViolationCode {
    param(
        [object[]]$Violations,
        [string]$Code
    )

    return @($Violations | Where-Object { $_.code -eq $Code }).Count -gt 0
}


$plan = New-AbbaRunPlan $script:FormalScenarioIds @(11, 12, 13)
$orderValid = $plan.Count -eq 84
foreach ($scenarioId in $script:FormalScenarioIds) {
    foreach ($seed in @(11, 12, 13)) {
        $block = @($plan | Where-Object {
            $_.scenario_id -eq $scenarioId -and $_.seed -eq $seed
        } | Sort-Object block_position)
        $orderValid = (
            $orderValid -and
            $block.Count -eq 4 -and
            ($block.mode -join ",") -ceq "legacy,layered_contact,layered_contact,legacy" -and
            ($block.pair_index -join ",") -ceq "0,0,1,1"
        )
    }
}
Add-AbRunnerSelfTest "abba_order" $orderValid @($plan)

$scenarioDefinitionsValid = $true
$approachScenarioCount = 0
$engagementScenarioCount = 0
foreach ($scenarioId in $script:FormalScenarioIds) {
    $scenario = Get-AbScenarioDefinition $scenarioId
    if ($scenario.phase -eq "approach") {
        $approachScenarioCount += 1
    }
    elseif ($scenario.phase -eq "engagement") {
        $engagementScenarioCount += 1
    }
    $scenarioDefinitionsValid = (
        $scenarioDefinitionsValid -and
        $scenario.id -eq $scenarioId -and
        $scenario.enemy_count -in @(200, 300) -and
        $scenario.maximum_paired_p95_ratio -eq $(if (
            $scenario.role -eq "main"
        ) { 0.85 } else { 1.03 }) -and
        -not [string]::IsNullOrWhiteSpace([string]$scenario.fixture_kind) -and
        -not [string]::IsNullOrWhiteSpace([string]$scenario.source_path) -and
        -not [string]::IsNullOrWhiteSpace([string]$scenario.flow_step_path)
    )
}
$scenarioDefinitionsValid = (
    $scenarioDefinitionsValid -and
    $approachScenarioCount -eq 5 -and
    $engagementScenarioCount -eq 2
)
Add-AbRunnerSelfTest "seven_scenario_definitions" $scenarioDefinitionsValid @(
    $script:FormalScenarioIds | ForEach-Object { Get-AbScenarioDefinition $_ }
)

$basicEntry = (New-AbbaRunPlan @("basic_pursuit_300") @(11))[0]
$towerEntry = (New-AbbaRunPlan @("tower_projectile_96") @(11))[0]
$basicArguments = @(Get-AbBackendArguments `
    $basicEntry `
    "backend.ps1" `
    "C:\fixture" `
    "basic_token" `
    60)
$towerArguments = @(Get-AbBackendArguments `
    $towerEntry `
    "backend.ps1" `
    "C:\fixture" `
    "tower_token" `
    60)
$basicSourceIndex = [Array]::IndexOf($basicArguments, "-EnemyConfig")
$towerSourceIndex = [Array]::IndexOf($towerArguments, "-WaveConfig")
Add-AbRunnerSelfTest "scenario_backend_source_routing" (
    $basicSourceIndex -ge 0 -and
    $basicArguments[$basicSourceIndex + 1] -eq $script:BasicPursuitEnemy -and
    [Array]::IndexOf($basicArguments, "-WaveConfig") -lt 0 -and
    $towerSourceIndex -ge 0 -and
    $towerArguments[$towerSourceIndex + 1] -eq $script:FormalWave12 -and
    [Array]::IndexOf($towerArguments, "-EnemyConfig") -lt 0
) [pscustomobject]@{
    basic = $basicArguments
    tower = $towerArguments
}

$legacyRecord = [pscustomobject]@{ ordinal = 0; wall_p95_ms = 20.0 }
$candidateRecord = [pscustomobject]@{ ordinal = 1; wall_p95_ms = 17.0 }
$pair = New-AbPairedResult $legacyRecord $candidateRecord 0
Add-AbRunnerSelfTest "paired_formula" (
    [Math]::Abs($pair.candidate_over_legacy_ratio - 0.85) -lt 0.000000001 -and
    [Math]::Abs($pair.improvement_ratio - 0.15) -lt 0.000000001
) $pair

$mainScenario = Get-AbScenarioDefinition "first_night_main"
$criticalScenario = Get-AbScenarioDefinition "critical_300"
$mainBoundaryPairs = @(
    [pscustomobject]@{ candidate_over_legacy_ratio = 0.85 },
    [pscustomobject]@{ candidate_over_legacy_ratio = 0.85 }
)
$mainFailPairs = @(
    [pscustomobject]@{ candidate_over_legacy_ratio = 0.850001 },
    [pscustomobject]@{ candidate_over_legacy_ratio = 0.850001 }
)
$criticalBoundaryPairs = @(
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.03 },
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.03 }
)
$criticalFailPairs = @(
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.030001 },
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.030001 }
)
$criticalOutlierPairs = @(
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.00 },
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.031 },
    [pscustomobject]@{ candidate_over_legacy_ratio = 1.00 }
)
$mainBoundary = Get-AbScenarioVerdict $mainScenario $mainBoundaryPairs $true
$mainFailure = Get-AbScenarioVerdict $mainScenario $mainFailPairs $true
$criticalBoundary = Get-AbScenarioVerdict `
    $criticalScenario `
    $criticalBoundaryPairs `
    $true
$criticalFailure = Get-AbScenarioVerdict `
    $criticalScenario `
    $criticalFailPairs `
    $true
$criticalOutlierFailure = Get-AbScenarioVerdict `
    $criticalScenario `
    $criticalOutlierPairs `
    $true
Add-AbRunnerSelfTest "gate_boundaries" (
    $mainBoundary.verdict -eq "passed" -and
    $mainFailure.verdict -eq "failed" -and
    $criticalBoundary.verdict -eq "passed" -and
    $criticalFailure.verdict -eq "failed" -and
    $criticalOutlierFailure.verdict -eq "failed" -and
    $criticalOutlierFailure.gate_statistic -eq "maximum"
) [pscustomobject]@{
    main_boundary = $mainBoundary
    main_failure = $mainFailure
    critical_boundary = $criticalBoundary
    critical_failure = $criticalFailure
    critical_outlier_failure = $criticalOutlierFailure
}

$invalidScenario = Get-AbScenarioVerdict $mainScenario @() $false
$invalidGroup = Get-AbGroupVerdict $false @($mainBoundary, $criticalBoundary)
$invalidChildGroup = Get-AbGroupVerdict $true @($invalidScenario, $criticalBoundary)
$failedGroup = Get-AbGroupVerdict $true @($mainFailure, $criticalBoundary)
$passedGroup = Get-AbGroupVerdict $true @($mainBoundary, $criticalBoundary)
Add-AbRunnerSelfTest "invalid_propagation" (
    $invalidGroup -eq "invalid" -and
    $invalidChildGroup -eq "invalid" -and
    $failedGroup -eq "failed" -and
    $passedGroup -eq "passed"
) [pscustomobject]@{
    invalid_inputs = $invalidGroup
    invalid_child = $invalidChildGroup
    failed_gate = $failedGroup
    passed = $passedGroup
}

$legacyFingerprint = New-AbRunnerSelfTestFingerprint "legacy"
$candidateFingerprint = New-AbRunnerSelfTestFingerprint "layered_contact"
$buildingMismatch = New-AbRunnerSelfTestFingerprint "layered_contact" 39
$commitMismatch = New-AbRunnerSelfTestFingerprint "layered_contact" 40 "other-commit"
Add-AbRunnerSelfTest "fingerprint_contract" (
    (Test-AbFingerprintCompatible $legacyFingerprint $candidateFingerprint) -and
    -not (Test-AbFingerprintCompatible $legacyFingerprint $buildingMismatch) -and
    -not (Test-AbFingerprintCompatible `
        $legacyFingerprint `
        $commitMismatch `
        -EnvironmentOnly)
) [pscustomobject]@{
    mode_is_normalized = Test-AbFingerprintCompatible `
        $legacyFingerprint `
        $candidateFingerprint
    building_mismatch_rejected = -not (
        Test-AbFingerprintCompatible $legacyFingerprint $buildingMismatch
    )
    commit_mismatch_rejected = -not (
        Test-AbFingerprintCompatible `
            $legacyFingerprint `
            $commitMismatch `
            -EnvironmentOnly
    )
}

$legacyPlanEntry = New-AbRunnerSelfTestPlanEntry "legacy"
$candidatePlanEntry = New-AbRunnerSelfTestPlanEntry "layered_contact"
$legacyContractViolations = @(Get-AbRunContractViolations `
    $legacyPlanEntry `
    (New-AbRunnerSelfTestInvocation "legacy"))
$candidateContractViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation "layered_contact"))
Add-AbRunnerSelfTest "mode_ownership_contracts" (
    $legacyContractViolations.Count -eq 0 -and
    $candidateContractViolations.Count -eq 0
) [pscustomobject]@{
    legacy = $legacyContractViolations
    layered_contact = $candidateContractViolations
}

$allScenarioContractsValid = $true
$scenarioContractDetails = [ordered]@{}
foreach ($scenarioId in $script:FormalScenarioIds) {
    $scenarioPlanEntry = New-AbRunnerSelfTestPlanEntry `
        "layered_contact" `
        $scenarioId
    $scenarioInvocation = New-AbRunnerSelfTestInvocation `
        "layered_contact" `
        -ScenarioId $scenarioId
    $scenarioViolations = @(Get-AbRunContractViolations `
        $scenarioPlanEntry `
        $scenarioInvocation)
    $allScenarioContractsValid = (
        $allScenarioContractsValid -and $scenarioViolations.Count -eq 0
    )
    $scenarioContractDetails[$scenarioId] = $scenarioViolations
}
Add-AbRunnerSelfTest `
    "all_scenario_adapter_contracts" `
    $allScenarioContractsValid `
    $scenarioContractDetails

$specificAdapterCases = @(
    @("basic_pursuit_300", "basic_pursuit_count", 299, "basic_pursuit_contract_mismatch"),
    @("tower_projectile_96", "projectile_pressure_verified", $false, "tower_projectile_contract_mismatch"),
    @("faction_battle_150v150", "paired_dynamic_target_count", 299, "faction_battle_contract_mismatch"),
    @("obstacle_water_unreachable", "water_target_verified", $false, "water_unreachable_contract_mismatch"),
    @("host_client_proxy_1000", "client_index_count", 999, "host_client_proxy_contract_mismatch")
)
$specificAdapterRejectionsValid = $true
$specificAdapterDetails = [ordered]@{}
foreach ($adapterCase in $specificAdapterCases) {
    $scenarioId = [string]$adapterCase[0]
    $propertyName = [string]$adapterCase[1]
    $invalidValue = $adapterCase[2]
    $expectedCode = [string]$adapterCase[3]
    $scenarioPlanEntry = New-AbRunnerSelfTestPlanEntry `
        "layered_contact" `
        $scenarioId
    $scenarioInvocation = New-AbRunnerSelfTestInvocation `
        "layered_contact" `
        -ScenarioId $scenarioId
    $scenarioInvocation.payload.fingerprint.scenario.scenario_contract.$propertyName = (
        $invalidValue
    )
    $scenarioViolations = @(Get-AbRunContractViolations `
        $scenarioPlanEntry `
        $scenarioInvocation)
    $rejected = Test-AbRunnerViolationCode $scenarioViolations $expectedCode
    $specificAdapterRejectionsValid = $specificAdapterRejectionsValid -and $rejected
    $specificAdapterDetails[$scenarioId] = $scenarioViolations
}
Add-AbRunnerSelfTest `
    "scenario_adapter_rejections" `
    $specificAdapterRejectionsValid `
    $specificAdapterDetails

$hostInitializationInvocation = New-AbRunnerSelfTestInvocation `
    "layered_contact" `
    -ScenarioId "first_night_main"
$hostInitializationInvocation.payload.fingerprint.scenario.scenario_contract.host_configured_before_tree = $false
$hostInitializationViolations = @(Get-AbRunContractViolations `
    (New-AbRunnerSelfTestPlanEntry "layered_contact" "first_night_main") `
    $hostInitializationInvocation)
Add-AbRunnerSelfTest "pre_tree_host_configuration_rejection" (
    Test-AbRunnerViolationCode `
        $hostInitializationViolations `
        "scenario_adapter_contract_mismatch"
) $hostInitializationViolations

$rngForgeryInvocation = New-AbRunnerSelfTestInvocation `
    "layered_contact" `
    -ScenarioId "critical_300"
$rngForgeryInvocation.payload.godot.rng_state_evidence.start.enemy_behavior_states = @()
$rngForgeryViolations = @(Get-AbRunContractViolations `
    (New-AbRunnerSelfTestPlanEntry "layered_contact" "critical_300") `
    $rngForgeryInvocation)
$rngPairExpected = New-AbRunnerSelfTestFingerprint "legacy"
$rngPairForged = New-AbRunnerSelfTestFingerprint "layered_contact"
$rngPairForged.rng_state_evidence.end.runtime.state += 1
Add-AbRunnerSelfTest "rng_evidence_forgery_rejections" (
    (Test-AbRunnerViolationCode `
        $rngForgeryViolations `
        "rng_state_evidence_mismatch") -and
    -not (Test-AbFingerprintCompatible $rngPairExpected $rngPairForged)
) [pscustomobject]@{
    run_contract = $rngForgeryViolations
    pair_fingerprint_rejected = -not (
        Test-AbFingerprintCompatible $rngPairExpected $rngPairForged
    )
}

$towerForgeryDetails = [ordered]@{}
$towerForgeryValid = $true
$towerForgeryCases = @(
    @("total_shots", "tower_total_shots", 95),
    @("agave_shots", "tower_agave_projectile_shots", 31),
    @("concurrent_peak", "tower_peak_concurrent_projectiles", 7)
)
foreach ($towerCase in $towerForgeryCases) {
    $towerInvocation = New-AbRunnerSelfTestInvocation `
        "layered_contact" `
        -ScenarioId "tower_projectile_96"
    $towerContract = $towerInvocation.payload.fingerprint.scenario.scenario_contract
    $towerContract.PSObject.Properties[[string]$towerCase[1]].Value = $towerCase[2]
    $towerViolations = @(Get-AbRunContractViolations `
        (New-AbRunnerSelfTestPlanEntry `
            "layered_contact" `
            "tower_projectile_96") `
        $towerInvocation)
    $towerRejected = Test-AbRunnerViolationCode `
        $towerViolations `
        "tower_projectile_contract_mismatch"
    $towerForgeryValid = $towerForgeryValid -and $towerRejected
    $towerForgeryDetails[[string]$towerCase[0]] = $towerViolations
}
Add-AbRunnerSelfTest `
    "tower_pressure_forgery_rejections" `
    $towerForgeryValid `
    $towerForgeryDetails

$factionStartForgery = New-AbRunnerSelfTestInvocation `
    "layered_contact" `
    -ScenarioId "faction_battle_150v150"
$factionStartForgery.payload.fingerprint.scenario.scenario_contract.faction_valid_dynamic_targets_start.allied = 149
$factionEndForgery = New-AbRunnerSelfTestInvocation `
    "layered_contact" `
    -ScenarioId "faction_battle_150v150"
$factionEndForgery.payload.fingerprint.scenario.scenario_contract.faction_valid_dynamic_targets_end.hostile = 149
$factionDamageForgery = New-AbRunnerSelfTestInvocation `
    "layered_contact" `
    -ScenarioId "faction_battle_150v150"
$factionDamageForgery.payload.fingerprint.scenario.scenario_contract.faction_damage_taken.allied_damage_taken = 0
$factionVictimForgery = New-AbRunnerSelfTestInvocation `
    "layered_contact" `
    -ScenarioId "faction_battle_150v150"
$factionVictimForgery.payload.fingerprint.scenario.scenario_contract.faction_damage_taken.hostile_damaged_enemy_count = 0
$factionPlan = New-AbRunnerSelfTestPlanEntry `
    "layered_contact" `
    "faction_battle_150v150"
$factionStartViolations = @(Get-AbRunContractViolations `
    $factionPlan `
    $factionStartForgery)
$factionEndViolations = @(Get-AbRunContractViolations `
    $factionPlan `
    $factionEndForgery)
$factionDamageViolations = @(Get-AbRunContractViolations `
    $factionPlan `
    $factionDamageForgery)
$factionVictimViolations = @(Get-AbRunContractViolations `
    $factionPlan `
    $factionVictimForgery)
Add-AbRunnerSelfTest "faction_engagement_forgery_rejections" (
    (Test-AbRunnerViolationCode `
        $factionStartViolations `
        "faction_battle_contract_mismatch") -and
    (Test-AbRunnerViolationCode `
        $factionEndViolations `
        "faction_battle_contract_mismatch") -and
    (Test-AbRunnerViolationCode `
        $factionDamageViolations `
        "faction_battle_contract_mismatch") -and
    (Test-AbRunnerViolationCode `
        $factionVictimViolations `
        "faction_battle_contract_mismatch")
) [pscustomobject]@{
    start_targets = $factionStartViolations
    end_targets = $factionEndViolations
    bidirectional_damage = $factionDamageViolations
    damaged_victims = $factionVictimViolations
}

$proxyForgeryCases = @(
    @("start_proxy_flag", "client_proxy_start", "proxy_true_count", 999),
    @("start_process", "client_proxy_start", "process_disabled_count", 999),
    @("end_physics", "client_proxy_end", "physics_process_disabled_count", 999),
    @("start_area_presence", "client_proxy_start", "area_count", 0),
    @("end_area_monitoring", "client_proxy_end", "monitoring_area_count", 1),
    @("start_simulation", "client_proxy_start", "simulation_registered_count", 1),
    @("end_contact", "client_proxy_end", "contact_registered_count", 1),
    @("start_attack_state", "client_proxy_start", "authoritative_attack_state_count", 1),
    @("end_damage_state", "client_proxy_end", "authoritative_damage_state_count", 1),
    @("attack_delta", "contract", "client_authoritative_attack_delta", 1),
    @("damage_delta", "contract", "client_authoritative_damage_delta", 1),
    @("kill_delta", "contract", "client_authoritative_kill_delta", 1),
    @("reward_delta", "contract", "client_authoritative_reward_delta", 1)
)
$proxyForgeryValid = $true
$proxyForgeryDetails = [ordered]@{}
$proxyPlan = New-AbRunnerSelfTestPlanEntry `
    "layered_contact" `
    "host_client_proxy_1000"
foreach ($proxyCase in $proxyForgeryCases) {
    $proxyInvocation = New-AbRunnerSelfTestInvocation `
        "layered_contact" `
        -ScenarioId "host_client_proxy_1000"
    $proxyContract = $proxyInvocation.payload.fingerprint.scenario.scenario_contract
    if ([string]$proxyCase[1] -eq "contract") {
        $proxyContract.PSObject.Properties[[string]$proxyCase[2]].Value = (
            $proxyCase[3]
        )
    }
    else {
        $proxyBoundary = $proxyContract.PSObject.Properties[
            [string]$proxyCase[1]
        ].Value
        $proxyBoundary.PSObject.Properties[[string]$proxyCase[2]].Value = (
            $proxyCase[3]
        )
    }
    $proxyViolations = @(Get-AbRunContractViolations `
        $proxyPlan `
        $proxyInvocation)
    $proxyRejected = Test-AbRunnerViolationCode `
        $proxyViolations `
        "host_client_proxy_contract_mismatch"
    $proxyForgeryValid = $proxyForgeryValid -and $proxyRejected
    $proxyForgeryDetails[[string]$proxyCase[0]] = $proxyViolations
}
Add-AbRunnerSelfTest `
    "client_proxy_authority_forgery_rejections" `
    $proxyForgeryValid `
    $proxyForgeryDetails

$ownedBackendPath = "C:\repo path\run_tower_defense_enemy_cohort_probe.ps1"
$ownedInvocationToken = "ab_token-123"
$ownedExactProcess = [pscustomobject]@{
    Name = "pwsh.exe"
    CommandLine = 'pwsh.exe -NoProfile -File "C:\repo path\run_tower_defense_enemy_cohort_probe.ps1" -InvocationToken "ab_token-123"'
}
$ownedSubstringTokenProcess = [pscustomobject]@{
    Name = "pwsh.exe"
    CommandLine = 'pwsh.exe -NoProfile -File "C:\repo path\run_tower_defense_enemy_cohort_probe.ps1" -InvocationToken "ab_token-123-extra"'
}
$ownedWrongScriptProcess = [pscustomobject]@{
    Name = "pwsh.exe"
    CommandLine = 'pwsh.exe -NoProfile -File "C:\repo path\wrong.ps1" "C:\repo path\run_tower_defense_enemy_cohort_probe.ps1" -InvocationToken "ab_token-123"'
}
$ownedWrongHostProcess = [pscustomobject]@{
    Name = "powershell.exe"
    CommandLine = $ownedExactProcess.CommandLine
}
Add-AbRunnerSelfTest "owned_process_exact_marker_contract" (
    (Test-AbOwnedBackendRootMarker `
        $ownedExactProcess `
        $ownedInvocationToken `
        $ownedBackendPath) -and
    -not (Test-AbOwnedBackendRootMarker `
        $ownedSubstringTokenProcess `
        $ownedInvocationToken `
        $ownedBackendPath) -and
    -not (Test-AbOwnedBackendRootMarker `
        $ownedWrongScriptProcess `
        $ownedInvocationToken `
        $ownedBackendPath) -and
    -not (Test-AbOwnedBackendRootMarker `
        $ownedWrongHostProcess `
        $ownedInvocationToken `
        $ownedBackendPath)
) [pscustomobject]@{
    exact = Test-AbOwnedBackendRootMarker `
        $ownedExactProcess `
        $ownedInvocationToken `
        $ownedBackendPath
    substring_token_rejected = -not (Test-AbOwnedBackendRootMarker `
        $ownedSubstringTokenProcess `
        $ownedInvocationToken `
        $ownedBackendPath)
    non_adjacent_script_rejected = -not (Test-AbOwnedBackendRootMarker `
        $ownedWrongScriptProcess `
        $ownedInvocationToken `
        $ownedBackendPath)
    wrong_host_rejected = -not (Test-AbOwnedBackendRootMarker `
        $ownedWrongHostProcess `
        $ownedInvocationToken `
        $ownedBackendPath)
}

$registrationMismatchInvocation = New-AbRunnerSelfTestInvocation "legacy"
$registrationMismatchInvocation.payload.fingerprint.scenario.production_registration.before_measurement.network_registry.registered_count = 199
$registrationMismatchViolations = @(Get-AbRunContractViolations `
    $legacyPlanEntry `
    $registrationMismatchInvocation)
Add-AbRunnerSelfTest "production_registration_fingerprint_contract" (
    Test-AbRunnerViolationCode `
        $registrationMismatchViolations `
        "production_registration_fingerprint_mismatch"
) $registrationMismatchViolations

$contactMismatchViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation "layered_contact" `
        -ContactRegistrationCount 199))
$callbackFallbackViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation "layered_contact" `
        -IndividualPhysicsCallbacks 1))
$touchReductionViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation "layered_contact" `
        -MonitoredTouchAreas 11))
$registrationRejectionViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation "layered_contact" `
        -RegistrationRejections 1))
$modeFallbackViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation "layered_contact" `
        -ActualMode "legacy"))
Add-AbRunnerSelfTest "candidate_rejection_contracts" (
    (Test-AbRunnerViolationCode `
        $contactMismatchViolations `
        "candidate_contact_registration_mismatch") -and
    (Test-AbRunnerViolationCode `
        $callbackFallbackViolations `
        "candidate_coordinator_ownership_mismatch") -and
    (Test-AbRunnerViolationCode `
        $touchReductionViolations `
        "candidate_touch_area_reduction_mismatch") -and
    (Test-AbRunnerViolationCode `
        $registrationRejectionViolations `
        "candidate_registration_rejected") -and
    (Test-AbRunnerViolationCode `
        $modeFallbackViolations `
        "simulation_mode_mismatch")
) [pscustomobject]@{
    contact_registration = $contactMismatchViolations
    individual_callback_fallback = $callbackFallbackViolations
    touch_monitoring = $touchReductionViolations
    registration_rejection = $registrationRejectionViolations
    mode_fallback = $modeFallbackViolations
}

$stdoutErrorViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation `
        "layered_contact" `
        -Stdout "SCRIPT ERROR: synthetic failure"))
$stderrErrorViolations = @(Get-AbRunContractViolations `
    $candidatePlanEntry `
    (New-AbRunnerSelfTestInvocation `
        "layered_contact" `
        -Stderr "ERROR: synthetic failure"))
Add-AbRunnerSelfTest "engine_error_stream_scan" (
    (Test-AbRunnerViolationCode `
        $stdoutErrorViolations `
        "backend_stdout_engine_error") -and
    (Test-AbRunnerViolationCode `
        $stderrErrorViolations `
        "backend_stderr_engine_error") -and
    (Test-AbOutputContainsEngineError "prefix SCRIPT ERROR suffix") -and
    (Test-AbOutputContainsEngineError "ERROR: failure") -and
    -not (Test-AbOutputContainsEngineError "no engine failure")
) [pscustomobject]@{
    stdout = $stdoutErrorViolations
    stderr = $stderrErrorViolations
}

$failedTests = @($tests | Where-Object { -not [bool]$_.passed })
$result = [ordered]@{
    schema_version = $script:AcceptanceSchemaVersion
    mode = "self_test"
    valid = $failedTests.Count -eq 0
    verdict = if ($failedTests.Count -eq 0) { "passed" } else { "failed" }
    tests = @($tests)
    violations = @(
        $failedTests | ForEach-Object {
            [pscustomobject]@{
                code = "self_test_failure"
                message = "A/B runner self-test failed: $($_.name)"
            }
        }
    )
}
$result | ConvertTo-Json -Depth 30 -Compress
if ($failedTests.Count -gt 0) {
    exit 1
}
exit 0
