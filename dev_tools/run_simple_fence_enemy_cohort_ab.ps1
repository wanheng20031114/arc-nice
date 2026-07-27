param(
    [string]$GodotExe = "C:\Program Files\Godot\Godot_console.exe",

    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$probeRunner = Join-Path $PSScriptRoot "run_tower_defense_enemy_cohort_probe.ps1"
$pairCount = 3
$enemyCount = 300
$baselineFenceCount = 0
$loadedFenceCount = 1000
$warmupFrames = 120
$sampleFrames = 240
$fixedFps = 60
$baseSeed = 20260727
$allowedRatio = 1.10
$allowedFixedMilliseconds = 0.5

if (-not (Test-Path -LiteralPath $probeRunner -PathType Leaf)) {
    throw "Enemy cohort runner was not found: $probeRunner"
}

function Invoke-CohortCase {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PairIndex,

        [Parameter(Mandatory = $true)]
        [int]$FenceCount
    )

    $probeParameters = @{
        EnemyConfig = "res://resources/config/enemies/yuanshi_insect_basic.tres"
        Phase = "approach"
        EnemyCount = $enemyCount
        FenceCount = $FenceCount
        FenceAbMetrics = $true
        WarmupFrames = $warmupFrames
        SampleFrames = $sampleFrames
        Seed = $baseSeed + $PairIndex
        MaxFps = 0
        Headless = $true
        FixedFps = $fixedFps
        EnemyHotMetrics = $true
        GodotExe = $GodotExe
        ProjectRoot = $ProjectRoot
    }
    $outputLines = @(& $probeRunner @probeParameters)
    $jsonLine = $outputLines |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace([string]$jsonLine)) {
        throw "Pair $PairIndex with $FenceCount fences produced no JSON payload."
    }
    $result = [string]$jsonLine | ConvertFrom-Json
    if ([int]$result.exit_code -ne 0) {
        throw "Pair $PairIndex with $FenceCount fences exited with $($result.exit_code)."
    }
    return $result
}

function ConvertTo-StructuralSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Run
    )

    $godot = $Run.godot
    $fixture = $godot.simple_fence_fixture
    $enemyIndex = $fixture.enemy_target_index_final
    $lastEnemyQuery = $fixture.enemy_target_last_query
    $allIndex = $fixture.all_target_index_final
    $lastAllQuery = $fixture.all_target_last_query
    $terrainSupport = $fixture.terrain_support_final
    $navigation = $godot.enemy_hot_segments
    $budget = $godot.navigation_refresh_budget_runtime
    $navigationStatic = $fixture.navigation_final
    return [ordered]@{
        phase = [string]$godot.phase
        requested_enemies = [int]$godot.requested_enemies
        warmup_frames = [int]$godot.warmup_frames
        sample_frames = [int]$godot.sample_frames
        alive_start = [int]$godot.alive_start
        alive_min = [int]$godot.alive_min
        alive_end = [int]$godot.alive_end
        combat_index_size = [int]$godot.combat_index_size
        physics_frames_elapsed = [int]$godot.physics_frames_elapsed
        simulation_seconds_elapsed = [double]$godot.simulation_seconds_elapsed
        navigation_generation = [int]$navigationStatic.generation
        raw_navigation_generation = [int]$navigationStatic.raw_generation
        raw_navigation_region = [string]$navigationStatic.raw_region
        raw_navigation_cell_count = [int]$navigationStatic.raw_cell_count
        raw_navigation_cell_hash = [long]$navigationStatic.raw_cell_hash
        raw_obstacle_count = [int]$navigationStatic.raw_obstacle_count
        raw_obstacle_hash = [long]$navigationStatic.raw_obstacle_hash
        raw_obstacle_stride = [int]$navigationStatic.raw_obstacle_stride
        enemy_index_registered = [int]$enemyIndex.registered_count
        enemy_index_membership = [int]$enemyIndex.membership_count
        enemy_index_anchor_reverse = [int]$enemyIndex.anchor_reverse_count
        enemy_index_bucket_reverse = [int]$enemyIndex.bucket_reverse_count
        enemy_index_slot_reverse = [int]$enemyIndex.slot_reverse_count
        enemy_index_bucket_count = [int]$enemyIndex.bucket_count
        enemy_index_registrations_total = [int]$enemyIndex.registrations_total
        enemy_index_queries_total = [int]$enemyIndex.queries_total
        enemy_index_consistent = [bool]$enemyIndex.structure_counts_consistent
        last_enemy_query_candidates = [int]$lastEnemyQuery.candidates_visited
        last_enemy_query_results = [int]$lastEnemyQuery.results_written
        minimap_index_queries_total = [int]$allIndex.queries_total
        last_minimap_query_candidates = [int]$lastAllQuery.candidates_visited
        last_minimap_query_results = [int]$lastAllQuery.results_written
        terrain_tracked_plants = [int]$terrainSupport.tracked_plant_count
        terrain_unsupported_plants = [int]$terrainSupport.unsupported_plant_count
        terrain_tick_plants_visited = [int]$terrainSupport.last_tick_plants_visited
        terrain_tick_plants_damaged = [int]$terrainSupport.last_tick_plants_damaged
        navigation_calls = [int]$navigation.navigation.calls
        navigation_refresh_calls = [int]$navigation.navigation_refresh_calls
        navigation_same_render_skips = [int]$navigation.navigation_same_render_skips
        navigation_budget_deferrals = [int]$navigation.navigation_budget_deferrals
        navigation_budget_cap = [int]$budget.cap_per_process_frame
        navigation_budget_admitted = [int]$budget.admitted
        navigation_budget_deferred = [int]$budget.deferred
        navigation_budget_saturated_frames = [int]$budget.saturated_process_frames
        navigation_budget_max_wait = [int]$budget.max_wait_process_frames
        navigation_budget_pending_agents = [int]$budget.pending_agents
    }
}

function Assert-CaseShape {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Run,

        [Parameter(Mandatory = $true)]
        [int]$ExpectedFenceCount,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $godot = $Run.godot
    $fixture = $godot.simple_fence_fixture
    if (
        [int]$godot.requested_enemies -ne $enemyCount -or
        [int]$godot.warmup_frames -ne $warmupFrames -or
        [int]$godot.sample_frames -ne $sampleFrames -or
        [int]$godot.requested_simple_fences -ne $ExpectedFenceCount -or
        [int]$godot.simple_fences -ne $ExpectedFenceCount
    ) {
        throw "$Label did not run the exact 300/120/240/$ExpectedFenceCount fixture."
    }
    if (
        [int]$fixture.real_static_body_count -ne $ExpectedFenceCount -or
        [int]$fixture.real_collision_shape_count -ne $ExpectedFenceCount -or
        [int]$fixture.all_target_index_final.registered_count -ne $ExpectedFenceCount -or
        [int]$fixture.all_target_index_final.queries_total -le 0 -or
        [int]$fixture.all_target_last_query.candidates_visited -ne 0 -or
        [int]$fixture.all_target_last_query.results_written -ne 0 -or
        -not [bool]$fixture.all_target_index_final.structure_counts_consistent
    ) {
        throw "$Label did not retain exact real fence bodies with a local zero-candidate minimap query."
    }
    if (
        [int]$fixture.enemy_target_index_final.registered_count -ne 0 -or
        [int]$fixture.enemy_target_index_final.membership_count -ne 0 -or
        [int]$fixture.enemy_target_last_query.candidates_visited -ne 0 -or
        [int]$fixture.enemy_target_last_query.results_written -ne 0 -or
        -not [bool]$fixture.enemy_target_index_final.structure_counts_consistent
    ) {
        throw "$Label allowed CONTACT_ONLY fences into proactive enemy targeting work."
    }
    if ($ExpectedFenceCount -eq $loadedFenceCount) {
        if (
            [int]$fixture.fence_subtree_node_count -le $ExpectedFenceCount -or
            [double]$fixture.node_count_delta -le 0.0 -or
            [double]$fixture.static_memory_mib_delta -le 0.0
        ) {
            throw "$Label did not expose positive real-node and static-memory fence cost."
        }
    }
}

$runs = [Collections.Generic.List[object]]::new()
$gateFailures = [Collections.Generic.List[string]]::new()

for ($pairIndex = 0; $pairIndex -lt $pairCount; $pairIndex++) {
    $executionOrder = if (($pairIndex % 2) -eq 0) {
        @($baselineFenceCount, $loadedFenceCount)
    } else {
        @($loadedFenceCount, $baselineFenceCount)
    }
    $pairRuns = @{}
    foreach ($fenceCount in $executionOrder) {
        $label = "pair=$($pairIndex + 1) fences=$fenceCount"
        Write-Host "SIMPLE_FENCE_ENEMY_COHORT_AB_RUN $label"
        $run = Invoke-CohortCase -PairIndex $pairIndex -FenceCount $fenceCount
        Assert-CaseShape -Run $run -ExpectedFenceCount $fenceCount -Label $label
        $pairRuns[$fenceCount] = $run
    }

    $baseline = $pairRuns[$baselineFenceCount]
    $loaded = $pairRuns[$loadedFenceCount]
    $pairFailureCountBefore = $gateFailures.Count
    $baselineStructure = ConvertTo-StructuralSnapshot -Run $baseline
    $loadedStructure = ConvertTo-StructuralSnapshot -Run $loaded
    $baselineStructureJson = $baselineStructure | ConvertTo-Json -Depth 8 -Compress
    $loadedStructureJson = $loadedStructure | ConvertTo-Json -Depth 8 -Compress
    if ($baselineStructureJson -cne $loadedStructureJson) {
        $gateFailures.Add(
            "Pair $($pairIndex + 1) structural workload mismatch: baseline=$baselineStructureJson loaded=$loadedStructureJson"
        )
    }

    $baselineP95 = [double]$baseline.godot.wall_ms.p95
    $loadedP95 = [double]$loaded.godot.wall_ms.p95
    $limitP95 = $baselineP95 * $allowedRatio + $allowedFixedMilliseconds
    if (
        [double]::IsNaN($baselineP95) -or
        [double]::IsInfinity($baselineP95) -or
        $baselineP95 -le 0.0 -or
        [double]::IsNaN($loadedP95) -or
        [double]::IsInfinity($loadedP95) -or
        $loadedP95 -le 0.0 -or
        $loadedP95 -gt $limitP95
    ) {
        $gateFailures.Add(
            "Pair $($pairIndex + 1) p95 failed: loaded=$loadedP95 baseline=$baselineP95 limit=$limitP95 ms"
        )
    }

    $pairResult = [ordered]@{
        pair = $pairIndex + 1
        seed = $baseSeed + $pairIndex
        execution_order_fences = $executionOrder
        baseline_wall_p95_ms = $baselineP95
        loaded_wall_p95_ms = $loadedP95
        allowed_wall_p95_ms = $limitP95
        ratio = if ($baselineP95 -gt 0.0) { $loadedP95 / $baselineP95 } else { 0.0 }
        baseline_process_p95_ms = [double]$baseline.godot.process_ms.p95
        loaded_process_p95_ms = [double]$loaded.godot.process_ms.p95
        baseline_physics_p95_ms = [double]$baseline.godot.physics_ms.p95
        loaded_physics_p95_ms = [double]$loaded.godot.physics_ms.p95
        baseline_navigation_lookahead_calls = [int]$baseline.godot.enemy_hot_segments.navigation_lookahead.calls
        loaded_navigation_lookahead_calls = [int]$loaded.godot.enemy_hot_segments.navigation_lookahead.calls
        baseline_navigation_flow_prefetches = [int]$baseline.godot.enemy_hot_segments.navigation_flow_prefetches
        loaded_navigation_flow_prefetches = [int]$loaded.godot.enemy_hot_segments.navigation_flow_prefetches
        baseline_verified_direct_move_calls = [int]$baseline.godot.enemy_hot_segments.verified_direct_move_calls
        loaded_verified_direct_move_calls = [int]$loaded.godot.enemy_hot_segments.verified_direct_move_calls
        baseline_node_count_p50 = [double]$baseline.godot.node_count.p50
        loaded_node_count_p50 = [double]$loaded.godot.node_count.p50
        fence_node_delta = [double]$loaded.godot.simple_fence_fixture.node_count_delta
        fence_subtree_nodes = [int]$loaded.godot.simple_fence_fixture.fence_subtree_node_count
        fence_static_memory_delta_mib = [double]$loaded.godot.simple_fence_fixture.static_memory_mib_delta
        structural_snapshot = $baselineStructure
    }
    $runs.Add([pscustomobject]$pairResult)
    if ($gateFailures.Count -eq $pairFailureCountBefore) {
        Write-Host (
            "SIMPLE_FENCE_ENEMY_COHORT_AB_PAIR_OK pair={0} baseline_p95={1:N3}ms loaded_p95={2:N3}ms limit={3:N3}ms" -f
            ($pairIndex + 1), $baselineP95, $loadedP95, $limitP95
        )
    } else {
        Write-Host "SIMPLE_FENCE_ENEMY_COHORT_AB_PAIR_FAILED pair=$($pairIndex + 1)"
    }
}

$summary = [ordered]@{
    status = if ($gateFailures.Count -eq 0) { "ok" } else { "failed" }
    pair_count = $pairCount
    enemy_count = $enemyCount
    baseline_fences = $baselineFenceCount
    loaded_fences = $loadedFenceCount
    warmup_frames = $warmupFrames
    sample_frames = $sampleFrames
    fixed_fps = $fixedFps
    p95_limit_formula = "loaded <= baseline * 1.10 + 0.5 ms"
    pairs = $runs
    failures = $gateFailures
}
Write-Output (
    "SIMPLE_FENCE_ENEMY_COHORT_AB_RESULT " +
    ($summary | ConvertTo-Json -Depth 12 -Compress)
)

if ($gateFailures.Count -gt 0) {
    throw ($gateFailures -join [Environment]::NewLine)
}
