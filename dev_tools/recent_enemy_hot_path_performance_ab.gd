extends SceneTree

# Focused same-process A/B certificates for three recent enemy hot paths.
# Optimized arms call the current production methods directly; legacy arms add
# only the superseded ordering/allocation around the same production fixtures.
# Timed samples alternate AB/BA order, while behavior equivalence is checked
# separately so validation work does not hide the measured cost.
const ENEMY_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_main_battle_elite.tscn"
)
const ENEMY_CONFIG: CombatRobotMainBattleEliteConfig = preload(
	"res://resources/config/enemies/combat_robot_main_battle_elite.tres"
)
const CARDBOARD_SCENE := preload(
	"res://scene/enemy/artificial_creation/cardboard_monster.tscn"
)
const CARDBOARD_CONFIG := preload(
	"res://resources/config/enemies/cardboard_monster.tres"
)
const COMBAT_ROBOT_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot.tscn"
)
const COMBAT_ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const COMPLETE_SHAPE_QUERY_2D := preload(
	"res://scene/combat/physics/complete_shape_query_2d.gd"
)

const FIXED_SEED := 0x52454345
const SAMPLE_PAIRS := 11
const ACTION_TARGET_COUNT := 96
const ACTION_ITERATIONS_PER_SAMPLE := 192
const ACTION_WARMUP_BATCHES := 3
const COOLDOWN_SECONDS := 5.0
const PLANT_COLLISION_LAYER := 1 << 9
const WARNING_ENDPOINT_COUNT := 1024
const WARNING_UPDATES_PER_SAMPLE := 120_000
const WARNING_WARMUP_UPDATES := 20_000
const WARNING_WARMUP_BATCHES := 3
const WARNING_EQUIVALENCE_UPDATES := 4096
const COMBAT_SENSE_ITERATIONS_PER_SAMPLE := 240_000
const COMBAT_SENSE_WARMUP_ITERATIONS := 40_000
const COMBAT_SENSE_WARMUP_BATCHES := 3
const CHECKSUM_MODULUS := 2_147_483_647
const CHECKSUM_MULTIPLIER := 48_271
const CHECKSUM_SEED := 17
const MAX_ACTION_PAIRED_RATIO := 0.25
const MAX_WARNING_PAIRED_RATIO := 0.80
const MAX_COMBAT_SENSE_PAIRED_RATIO := 0.65
const CLEANUP_FRAMES := 4

var failures: Array[String] = []
var runtime: EnemyGameplayGatewayTestRuntime = null
var enemy: CombatRobotMainBattleElite = null
var action_target_container: Node2D = null
var action_targets: Array[PlantDefense] = []
var warning_line: Line2D = null
var warning_endpoints := PackedVector2Array()
var warning_targets: Array[Node2D] = []
var authored_warning_points := PackedVector2Array()
var combat_sense_enemies: Array[Enemy] = []
var combat_sense_target_player: Player = null
var original_combat_sense_throttling := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _build_fixed_fixture()
	if not failures.is_empty():
		await _finish({})
		return

	var action_result := _measure_action_cooldown_ab()
	var warning_result := _measure_warning_line_ab()
	var combat_sense_result := _measure_combat_sense_ab()
	var result := {
		"status": "ok" if failures.is_empty() else "failed",
		"seed": FIXED_SEED,
		"sample_pairs": SAMPLE_PAIRS,
		"action_cooldown": action_result,
		"skill1_warning_line": warning_result,
		"combat_sense_due_false": combat_sense_result,
		"failures": failures.duplicate(),
	}
	await _finish(result)


func _build_fixed_fixture() -> void:
	runtime = RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	_expect(runtime != null, "The A/B fixture must instantiate its combat runtime.")
	if runtime == null:
		return
	root.add_child(runtime)
	current_scene = runtime
	original_combat_sense_throttling = Enemy.combat_sense_throttling_enabled
	Enemy.combat_sense_throttling_enabled = true

	action_target_container = Node2D.new()
	action_target_container.name = "RecentEnemyHotPathTargets"
	runtime.add_child(action_target_container)
	for target_index in range(ACTION_TARGET_COUNT):
		var target := _create_action_target(target_index)
		action_target_container.add_child(target)
		action_targets.append(target)

	enemy = ENEMY_SCENE.instantiate() as CombatRobotMainBattleElite
	_expect(enemy != null, "The production main-battle robot scene must instantiate.")
	if enemy == null:
		return
	runtime.get_node("EnemyContainer").add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(ENEMY_CONFIG, null, null, runtime)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.set_objective_target(action_targets[0])

	warning_line = enemy.skill1_warning_line
	_expect(warning_line != null, "The production enemy must own Skill1WarningLine.")
	if warning_line != null:
		authored_warning_points = warning_line.points.duplicate()
		_expect(
			authored_warning_points.size() == 2
			and authored_warning_points[0] == Vector2.ZERO,
			"Skill1WarningLine must retain two authored reusable points."
		)

	_build_warning_endpoints()
	_build_combat_sense_enemies()
	await process_frame
	await physics_frame
	await process_frame
	await physics_frame

	var query_metrics := {}
	enemy.target_query_shape.radius = ENEMY_CONFIG.skill2_trigger_range
	enemy.target_query.transform = Transform2D(0.0, enemy.global_position)
	var query_results := COMPLETE_SHAPE_QUERY_2D.intersect_shape_all(
		enemy.get_world_2d().direct_space_state,
		enemy.target_query,
		ENEMY_CONFIG.shape_query_batch_size,
		query_metrics
	)
	var nearest := enemy.call(
		"_find_nearest_target_in_range",
		ENEMY_CONFIG.skill2_trigger_range
	) as Node2D
	var preferred := enemy.call("_get_preferred_ranged_combat_target") as Node2D
	_expect(
		query_results.size() == ACTION_TARGET_COUNT,
		"The cooldown A/B fixture must expose every real physics target."
	)
	_expect(
		int(query_metrics.get("physics_query_count", 0)) >= 2
		and int(query_metrics.get("full_batch_count", 0)) >= 1,
		"The legacy fixture must exercise the production paged shape-query path."
	)
	_expect(
		nearest == action_targets[0] and preferred == action_targets[0],
		"Shape-query and preferred-target resolution must agree on the fixed nearest target."
	)
	for sense_enemy in combat_sense_enemies:
		_configure_combat_sense_not_due(sense_enemy)
		_expect(
			not bool(sense_enemy.call("_is_combat_sense_refresh_due")),
			"Combat-sense A/B must hold every production enemy at due=false."
		)
		_expect(
			sense_enemy.call("_get_preferred_ranged_combat_target") != null,
			"Legacy combat-sense resolution must have a stable live target to resolve."
		)


func _create_action_target(target_index: int) -> PlantDefense:
	var target := PlantDefense.new()
	target.name = "CooldownTarget%03d" % target_index
	target.collision_layer = PLANT_COLLISION_LAYER
	target.collision_mask = 0
	target.input_pickable = false
	target.max_health = 1_000_000
	target.current_health = target.max_health
	var collision := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 3.0
	collision.shape = shape
	target.add_child(collision)
	if target_index == 0:
		target.position = Vector2(36.0, 0.0)
		return target
	var ring_index := (target_index - 1) / 24
	var slot_index := (target_index - 1) % 24
	var radius := 64.0 + float(ring_index) * 38.0
	var angle := TAU * float(slot_index) / 24.0 + float(ring_index) * 0.0375
	target.position = Vector2.from_angle(angle) * radius
	return target


func _build_warning_endpoints() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = FIXED_SEED
	warning_endpoints.resize(WARNING_ENDPOINT_COUNT)
	warning_targets.resize(WARNING_ENDPOINT_COUNT)
	for endpoint_index in range(WARNING_ENDPOINT_COUNT):
		var angle := random.randf_range(-PI, PI)
		var distance := random.randf_range(24.0, 220.0)
		var endpoint := Vector2.from_angle(angle) * distance
		warning_endpoints[endpoint_index] = endpoint
		var target := Node2D.new()
		target.name = "WarningTarget%04d" % endpoint_index
		target.position = endpoint
		action_target_container.add_child(target)
		warning_targets[endpoint_index] = target


func _build_combat_sense_enemies() -> void:
	combat_sense_target_player = Player.new()
	combat_sense_target_player.name = "CombatSenseStableTarget"
	combat_sense_target_player.is_dead = false
	var cardboard := CARDBOARD_SCENE.instantiate() as CapooKnight
	var combat_robot := COMBAT_ROBOT_SCENE.instantiate() as CombatRobot
	_expect(cardboard != null, "The recent cardboard CapooKnight fixture must instantiate.")
	_expect(combat_robot != null, "The CombatRobot fixture must instantiate.")
	for sense_enemy in [cardboard, combat_robot]:
		if sense_enemy == null:
			continue
		runtime.get_node("EnemyContainer").add_child(sense_enemy)
		sense_enemy.global_position = Vector2(480.0, 480.0)
		var sense_config: EnemyConfig = (
			CARDBOARD_CONFIG if sense_enemy is CapooKnight else COMBAT_ROBOT_CONFIG
		)
		sense_enemy.setup(sense_config, null, null, runtime)
		sense_enemy.set_physics_process(false)
		sense_enemy.set_process(false)
		# The live proactive player makes legacy target resolution real, while a
		# null navigation objective and zero velocity make the due=false production
		# physics path return without unrelated navigation or collision work.
		sense_enemy.set_target_player(combat_sense_target_player)
		sense_enemy.set_objective_target(null)
		combat_sense_enemies.append(sense_enemy)


func _measure_action_cooldown_ab() -> Dictionary:
	for _warmup_index in range(ACTION_WARMUP_BATCHES):
		_run_action_batch(false, ACTION_ITERATIONS_PER_SAMPLE)
		_run_action_batch(true, ACTION_ITERATIONS_PER_SAMPLE)

	var legacy_samples: Array[float] = []
	var optimized_samples: Array[float] = []
	var paired_ratios: Array[float] = []
	var reference_behavior := {}
	for pair_index in range(SAMPLE_PAIRS):
		var legacy_result: Dictionary
		var optimized_result: Dictionary
		if pair_index % 2 == 0:
			legacy_result = _run_action_batch(false, ACTION_ITERATIONS_PER_SAMPLE)
			optimized_result = _run_action_batch(true, ACTION_ITERATIONS_PER_SAMPLE)
		else:
			optimized_result = _run_action_batch(true, ACTION_ITERATIONS_PER_SAMPLE)
			legacy_result = _run_action_batch(false, ACTION_ITERATIONS_PER_SAMPLE)
		var legacy_behavior := legacy_result["behavior"] as Dictionary
		var optimized_behavior := optimized_result["behavior"] as Dictionary
		_expect(
			legacy_behavior == optimized_behavior,
			"Cooldown A/B pair %d changed observable action behavior." % (pair_index + 1)
		)
		if reference_behavior.is_empty():
			reference_behavior = legacy_behavior.duplicate(true)
		else:
			_expect(
				legacy_behavior == reference_behavior,
				"Cooldown A/B behavior drifted between sample pairs."
			)
		var legacy_ms := float(legacy_result["elapsed_ms"])
		var optimized_ms := float(optimized_result["elapsed_ms"])
		legacy_samples.append(legacy_ms)
		optimized_samples.append(optimized_ms)
		paired_ratios.append(optimized_ms / maxf(legacy_ms, 0.000001))

	var legacy_summary := _summarize(legacy_samples)
	var optimized_summary := _summarize(optimized_samples)
	var paired_ratio := _median(paired_ratios)
	_expect(
		int(reference_behavior.get("started_count", -1)) == 0
		and int(reference_behavior.get("combat_state", -1))
			== CombatRobotMainBattleElite.CombatState.CHASE
		and int(reference_behavior.get("committed_target_id", -1)) == 0,
		"All-cooldown action batches must remain exact no-op decisions."
	)
	_expect(
		float(legacy_summary["median_ms"]) > 0.0,
		"Legacy cooldown samples must have measurable duration."
	)
	_expect(
		paired_ratio <= MAX_ACTION_PAIRED_RATIO,
		(
			"Cooldown early return did not reduce paired cost by at least 75%% "
			+ "(ratio=%.4f limit=%.2f)."
		)
		% [paired_ratio, MAX_ACTION_PAIRED_RATIO]
	)
	return {
		"target_count": ACTION_TARGET_COUNT,
		"query_batch_size": ENEMY_CONFIG.shape_query_batch_size,
		"iterations_per_sample": ACTION_ITERATIONS_PER_SAMPLE,
		"warmup_batches": ACTION_WARMUP_BATCHES,
		"optimized_production_entry": "_try_start_ready_action",
		"legacy_shape_queries": ACTION_ITERATIONS_PER_SAMPLE * SAMPLE_PAIRS,
		"legacy_target_resolutions": ACTION_ITERATIONS_PER_SAMPLE * SAMPLE_PAIRS,
		"optimized_shape_queries": 0,
		"optimized_target_resolutions": 0,
		"legacy_ms": legacy_summary,
		"optimized_ms": optimized_summary,
		"paired_ratio_median": paired_ratio,
		"speedup": (
			float(legacy_summary["median_ms"])
			/ maxf(float(optimized_summary["median_ms"]), 0.000001)
		),
		"maximum_allowed_paired_ratio": MAX_ACTION_PAIRED_RATIO,
		"behavior": reference_behavior,
	}


func _run_action_batch(use_optimized: bool, iterations: int) -> Dictionary:
	_reset_all_cooldown_action_state()
	var checksum := CHECKSUM_SEED
	var started_count := 0
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(iterations):
		var started := (
			_optimized_all_cooldown_action_probe()
			if use_optimized
			else _legacy_all_cooldown_action_probe()
		)
		if started:
			started_count += 1
		checksum = _mix_checksum(
			checksum,
			int(enemy.combat_state) * 2 + (1 if started else 0)
		)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	return {
		"elapsed_ms": elapsed_ms,
		"behavior": {
			"checksum": checksum,
			"started_count": started_count,
			"combat_state": int(enemy.combat_state),
			"committed_target_id": (
				int(enemy.committed_target.get_instance_id())
				if is_instance_valid(enemy.committed_target)
				else 0
			),
			"objective_target_id": (
				int(enemy.objective_target.get_instance_id())
				if is_instance_valid(enemy.objective_target)
				else 0
			),
			"attack_cooldown": enemy.attack_cooldown_left,
			"skill1_cooldown": enemy.skill1_cooldown_left,
			"skill2_cooldown": enemy.skill2_cooldown_left,
		},
	}


func _reset_all_cooldown_action_state() -> void:
	enemy.combat_state = CombatRobotMainBattleElite.CombatState.CHASE
	enemy.committed_target = null
	enemy.attack_cooldown_left = COOLDOWN_SECONDS
	enemy.skill1_cooldown_left = COOLDOWN_SECONDS
	enemy.skill2_cooldown_left = COOLDOWN_SECONDS
	enemy.velocity = Vector2.ZERO


# Mirrors the pre-refactor control flow: Skill2 target discovery and preferred
# target resolution both run before the three positive cooldowns reject action.
func _legacy_all_cooldown_action_probe() -> bool:
	if enemy.main_config == null:
		return false
	var skill2_target := enemy.call(
		"_find_nearest_target_in_range",
		enemy.main_config.skill2_trigger_range
	) as Node2D
	if enemy.skill2_cooldown_left <= 0.0 and skill2_target != null:
		return true
	var target := enemy.call("_get_preferred_ranged_combat_target") as Node2D
	if target == null:
		return false
	if (
		enemy.skill1_cooldown_left <= 0.0
		and bool(enemy.call(
			"_is_ranged_combat_target_in_range",
			target,
			enemy.main_config.skill1_trigger_range
		))
	):
		return true
	if (
		enemy.attack_cooldown_left <= 0.0
		and bool(enemy.call(
			"_is_ranged_combat_target_in_range",
			target,
			enemy.main_config.attack_range
		))
	):
		return true
	return false


# Calls the optimized production method itself. In this fixture all three
# actions have positive cooldown, so production must return before any physics
# query or target resolution while retaining the same public decision/state.
func _optimized_all_cooldown_action_probe() -> bool:
	return enemy._try_start_ready_action()


func _measure_warning_line_ab() -> Dictionary:
	for _warmup_index in range(WARNING_WARMUP_BATCHES):
		_run_warning_line_batch(false, WARNING_WARMUP_UPDATES)
		_run_warning_line_batch(true, WARNING_WARMUP_UPDATES)

	var legacy_semantics := _verify_warning_line_behavior(false)
	var optimized_semantics := _verify_warning_line_behavior(true)
	_expect(
		legacy_semantics == optimized_semantics,
		"Skill1WarningLine A/B changed its point checksum or final authored state."
	)

	var legacy_samples: Array[float] = []
	var optimized_samples: Array[float] = []
	var paired_ratios: Array[float] = []
	var expected_final_point := warning_endpoints[
		(WARNING_UPDATES_PER_SAMPLE - 1) % warning_endpoints.size()
	]
	for pair_index in range(SAMPLE_PAIRS):
		var legacy_result: Dictionary
		var optimized_result: Dictionary
		if pair_index % 2 == 0:
			legacy_result = _run_warning_line_batch(false, WARNING_UPDATES_PER_SAMPLE)
			optimized_result = _run_warning_line_batch(true, WARNING_UPDATES_PER_SAMPLE)
		else:
			optimized_result = _run_warning_line_batch(true, WARNING_UPDATES_PER_SAMPLE)
			legacy_result = _run_warning_line_batch(false, WARNING_UPDATES_PER_SAMPLE)
		var legacy_final := legacy_result["final_points"] as PackedVector2Array
		var optimized_final := optimized_result["final_points"] as PackedVector2Array
		_expect(
			legacy_final == optimized_final
			and legacy_final.size() == 2
			and legacy_final[0] == Vector2.ZERO
			and legacy_final[1] == expected_final_point,
			"Skill1WarningLine pair %d did not finish at identical exact points."
			% (pair_index + 1)
		)
		var legacy_ms := float(legacy_result["elapsed_ms"])
		var optimized_ms := float(optimized_result["elapsed_ms"])
		legacy_samples.append(legacy_ms)
		optimized_samples.append(optimized_ms)
		paired_ratios.append(optimized_ms / maxf(legacy_ms, 0.000001))

	var legacy_summary := _summarize(legacy_samples)
	var optimized_summary := _summarize(optimized_samples)
	var paired_ratio := _median(paired_ratios)
	_expect(
		float(legacy_summary["median_ms"]) > 0.0,
		"Legacy warning-line samples must have measurable duration."
	)
	_expect(
		paired_ratio <= MAX_WARNING_PAIRED_RATIO,
		(
			"Authored warning-line point reuse did not reduce paired cost by at least "
			+ "20%% (ratio=%.4f limit=%.2f)."
		)
		% [paired_ratio, MAX_WARNING_PAIRED_RATIO]
	)
	return {
		"authored_point_count": authored_warning_points.size(),
		"endpoint_count": warning_endpoints.size(),
		"updates_per_sample": WARNING_UPDATES_PER_SAMPLE,
		"warmup_batches": WARNING_WARMUP_BATCHES,
		"optimized_production_entry": "_update_skill1_warning_line",
		"legacy_ms": legacy_summary,
		"optimized_ms": optimized_summary,
		"paired_ratio_median": paired_ratio,
		"speedup": (
			float(legacy_summary["median_ms"])
			/ maxf(float(optimized_summary["median_ms"]), 0.000001)
		),
		"maximum_allowed_paired_ratio": MAX_WARNING_PAIRED_RATIO,
		"behavior_checksum": int(legacy_semantics.get("checksum", 0)),
		"verified_updates": WARNING_EQUIVALENCE_UPDATES,
		"final_points": _points_to_json(legacy_semantics["final_points"]),
	}


func _run_warning_line_batch(use_optimized: bool, updates: int) -> Dictionary:
	_reset_warning_line()
	var started_usec := Time.get_ticks_usec()
	for update_index in range(updates):
		var target := warning_targets[update_index % warning_targets.size()]
		if use_optimized:
			_set_warning_line_points_optimized(target)
		else:
			_set_warning_line_points_legacy(target)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	return {
		"elapsed_ms": elapsed_ms,
		"final_points": warning_line.points.duplicate(),
	}


func _verify_warning_line_behavior(use_optimized: bool) -> Dictionary:
	_reset_warning_line()
	var checksum := CHECKSUM_SEED
	for update_index in range(WARNING_EQUIVALENCE_UPDATES):
		var endpoint := warning_endpoints[update_index % warning_endpoints.size()]
		var target := warning_targets[update_index % warning_targets.size()]
		if use_optimized:
			_set_warning_line_points_optimized(target)
		else:
			_set_warning_line_points_legacy(target)
		var actual_start := warning_line.get_point_position(0)
		var actual_end := warning_line.get_point_position(1)
		checksum = _mix_vector_checksum(checksum, actual_start)
		checksum = _mix_vector_checksum(checksum, actual_end)
		_expect(
			actual_start == Vector2.ZERO and actual_end == endpoint,
			"Skill1WarningLine wrote a non-equivalent point during behavior verification."
		)
	return {
		"checksum": checksum,
		"final_points": warning_line.points.duplicate(),
		"visible": warning_line.visible,
	}


func _reset_warning_line() -> void:
	warning_line.points = authored_warning_points.duplicate()
	warning_line.visible = false


func _set_warning_line_points_legacy(target: Node2D) -> void:
	_legacy_update_skill1_warning_line(target)


# Preserves the pre-refactor production method body behind the same additional
# call boundary as the optimized production method. This prevents the A/B from
# charging only the optimized arm for entering its implementation method.
func _legacy_update_skill1_warning_line(target: Node2D) -> void:
	if warning_line == null or target == null or not is_instance_valid(target):
		enemy._hide_skill1_warning_line()
		return
	warning_line.points = PackedVector2Array([
		Vector2.ZERO,
		enemy.to_local(target.global_position),
	])
	warning_line.visible = true


func _set_warning_line_points_optimized(target: Node2D) -> void:
	enemy._update_skill1_warning_line(target)


func _measure_combat_sense_ab() -> Dictionary:
	var family_results := {}
	for sense_enemy in combat_sense_enemies:
		var family_name := (
			"cardboard_capoo_knight"
			if sense_enemy is CapooKnight
			else "combat_robot"
		)
		for _warmup_index in range(COMBAT_SENSE_WARMUP_BATCHES):
			_run_combat_sense_batch(
				sense_enemy,
				false,
				COMBAT_SENSE_WARMUP_ITERATIONS
			)
			_run_combat_sense_batch(
				sense_enemy,
				true,
				COMBAT_SENSE_WARMUP_ITERATIONS
			)

		var legacy_samples: Array[float] = []
		var optimized_samples: Array[float] = []
		var paired_ratios: Array[float] = []
		var total_legacy_resolutions := 0
		var total_optimized_resolutions := 0
		var total_legacy_resolution_hits := 0
		var total_optimized_resolution_hits := 0
		var reference_behavior := {}
		for pair_index in range(SAMPLE_PAIRS):
			var legacy_result: Dictionary
			var optimized_result: Dictionary
			if pair_index % 2 == 0:
				legacy_result = _run_combat_sense_batch(
					sense_enemy,
					false,
					COMBAT_SENSE_ITERATIONS_PER_SAMPLE
				)
				optimized_result = _run_combat_sense_batch(
					sense_enemy,
					true,
					COMBAT_SENSE_ITERATIONS_PER_SAMPLE
				)
			else:
				optimized_result = _run_combat_sense_batch(
					sense_enemy,
					true,
					COMBAT_SENSE_ITERATIONS_PER_SAMPLE
				)
				legacy_result = _run_combat_sense_batch(
					sense_enemy,
					false,
					COMBAT_SENSE_ITERATIONS_PER_SAMPLE
				)
			var legacy_behavior := legacy_result["behavior"] as Dictionary
			var optimized_behavior := optimized_result["behavior"] as Dictionary
			_expect(
				legacy_behavior == optimized_behavior,
				"%s combat-sense A/B pair %d changed action behavior."
				% [family_name, pair_index + 1]
			)
			if reference_behavior.is_empty():
				reference_behavior = legacy_behavior.duplicate(true)
			else:
				_expect(
					legacy_behavior == reference_behavior,
					"%s combat-sense behavior drifted between pairs."
					% family_name
				)
			var legacy_ms := float(legacy_result["elapsed_ms"])
			var optimized_ms := float(optimized_result["elapsed_ms"])
			legacy_samples.append(legacy_ms)
			optimized_samples.append(optimized_ms)
			paired_ratios.append(optimized_ms / maxf(legacy_ms, 0.000001))
			total_legacy_resolutions += int(legacy_result["target_resolution_calls"])
			total_optimized_resolutions += int(
				optimized_result["target_resolution_calls"]
			)
			total_legacy_resolution_hits += int(
				legacy_result["target_resolution_hits"]
			)
			total_optimized_resolution_hits += int(
				optimized_result["target_resolution_hits"]
			)

		var expected_legacy_resolutions := (
			COMBAT_SENSE_ITERATIONS_PER_SAMPLE * SAMPLE_PAIRS
		)
		var legacy_summary := _summarize(legacy_samples)
		var optimized_summary := _summarize(optimized_samples)
		var paired_ratio := _median(paired_ratios)
		_expect(
			total_legacy_resolutions == expected_legacy_resolutions
			and total_legacy_resolution_hits == expected_legacy_resolutions
			and total_optimized_resolutions == 0
			and total_optimized_resolution_hits == 0,
			(
				"%s combat-sense call counts must prove legacy resolution and "
				+ "optimized short-circuiting (legacy=%d optimized=%d expected=%d)."
			)
			% [
				family_name,
				total_legacy_resolutions,
				total_optimized_resolutions,
				expected_legacy_resolutions,
			]
		)
		_expect(
			int(reference_behavior.get("started_count", -1)) == 0
			and not bool(reference_behavior.get("sense_due", true)),
			"%s due=false fixture must never start a combat action." % family_name
		)
		_expect(
			paired_ratio <= MAX_COMBAT_SENSE_PAIRED_RATIO,
			(
				"%s due-first ordering did not reduce paired cost by at least 35%% "
				+ "(ratio=%.4f limit=%.2f)."
			)
			% [family_name, paired_ratio, MAX_COMBAT_SENSE_PAIRED_RATIO]
		)
		family_results[family_name] = {
			"target_fixture": "live_proactive_player",
			"iterations_per_sample": COMBAT_SENSE_ITERATIONS_PER_SAMPLE,
			"warmup_batches": COMBAT_SENSE_WARMUP_BATCHES,
			"optimized_production_entry": "_physics_process",
			"legacy_target_resolution_calls": total_legacy_resolutions,
			"legacy_target_resolution_hits": total_legacy_resolution_hits,
			"optimized_target_resolution_calls": total_optimized_resolutions,
			"optimized_target_resolution_hits": total_optimized_resolution_hits,
			"legacy_ms": legacy_summary,
			"optimized_ms": optimized_summary,
			"paired_ratio_median": paired_ratio,
			"speedup": (
				float(legacy_summary["median_ms"])
				/ maxf(float(optimized_summary["median_ms"]), 0.000001)
			),
			"maximum_allowed_paired_ratio": MAX_COMBAT_SENSE_PAIRED_RATIO,
			"behavior": reference_behavior,
		}
	return {
		"iterations_per_sample": COMBAT_SENSE_ITERATIONS_PER_SAMPLE,
		"warmup_batches": COMBAT_SENSE_WARMUP_BATCHES,
		"families": family_results,
	}


func _run_combat_sense_batch(
	sense_enemy: Enemy,
	use_optimized: bool,
	iterations: int
) -> Dictionary:
	_reset_combat_sense_state(sense_enemy)
	_configure_combat_sense_not_due(sense_enemy)
	var checksum := CHECKSUM_SEED
	var target_resolution_calls := 0
	var target_resolution_hits := 0
	var started_count := 0
	var started_usec := Time.get_ticks_usec()
	for _iteration in range(iterations):
		if not use_optimized:
			target_resolution_calls += 1
			var combat_target := sense_enemy.call(
				"_get_preferred_ranged_combat_target"
			) as Node2D
			if combat_target != null:
				target_resolution_hits += 1
		_call_production_combat_sense_physics(sense_enemy)
		var started := not _is_combat_sense_enemy_chasing(sense_enemy)
		if started:
			started_count += 1
		checksum = _mix_checksum(
			checksum,
			_get_combat_sense_state_value(sense_enemy) * 2 + (1 if started else 0)
		)
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var sense_due := bool(sense_enemy.call("_is_combat_sense_refresh_due"))
	var behavior := _get_combat_sense_behavior_snapshot(sense_enemy)
	behavior["checksum"] = checksum
	behavior["started_count"] = started_count
	behavior["sense_due"] = sense_due
	return {
		"elapsed_ms": elapsed_ms,
		"target_resolution_calls": target_resolution_calls,
		"target_resolution_hits": target_resolution_hits,
		"behavior": behavior,
	}


func _call_production_combat_sense_physics(sense_enemy: Enemy) -> void:
	if sense_enemy is CapooKnight:
		(sense_enemy as CapooKnight)._physics_process(0.0)
		return
	(sense_enemy as CombatRobot)._physics_process(0.0)


func _is_combat_sense_enemy_chasing(sense_enemy: Enemy) -> bool:
	return _get_combat_sense_state_value(sense_enemy) == 0


func _get_combat_sense_state_value(sense_enemy: Enemy) -> int:
	if sense_enemy is CapooKnight:
		return int((sense_enemy as CapooKnight).combat_state)
	return int((sense_enemy as CombatRobot).combat_state)


func _configure_combat_sense_not_due(sense_enemy: Enemy) -> void:
	const INTERVAL := 8
	sense_enemy.combat_sense_update_interval_frames = INTERVAL
	sense_enemy.navigation_update_frame_offset = posmod(
		1 - posmod(Engine.get_physics_frames(), INTERVAL),
		INTERVAL
	)


func _reset_combat_sense_state(sense_enemy: Enemy) -> void:
	sense_enemy.velocity = Vector2.ZERO
	sense_enemy.set_target_player(combat_sense_target_player)
	sense_enemy.set_objective_target(null)
	sense_enemy.touching_plants.clear()
	sense_enemy.touching_players.clear()
	sense_enemy.touched_plant = null
	sense_enemy.touched_player = null
	sense_enemy.touch_damage_cooldown_left = 0.0
	if sense_enemy is CapooKnight:
		var knight := sense_enemy as CapooKnight
		knight.combat_state = CapooKnight.CombatState.CHASE
		knight.committed_attack_target = null
		knight.attack_cooldown_left = 0.0
	else:
		var robot := sense_enemy as CombatRobot
		robot.combat_state = CombatRobot.CombatState.CHASE
		robot.dash_cooldown_left = 0.0


func _get_combat_sense_behavior_snapshot(sense_enemy: Enemy) -> Dictionary:
	if sense_enemy is CapooKnight:
		var knight := sense_enemy as CapooKnight
		return {
			"family": "capoo_knight",
			"combat_state": int(knight.combat_state),
			"committed_target_id": (
				int(knight.committed_attack_target.get_instance_id())
				if is_instance_valid(knight.committed_attack_target)
				else 0
			),
			"velocity": [knight.velocity.x, knight.velocity.y],
			"position": [knight.global_position.x, knight.global_position.y],
			"target_player_id": combat_sense_target_player.get_instance_id(),
			"objective_target_id": 0,
		}
	var robot := sense_enemy as CombatRobot
	return {
		"family": "combat_robot",
		"combat_state": int(robot.combat_state),
		"dash_direction": [robot.dash_direction.x, robot.dash_direction.y],
		"velocity": [robot.velocity.x, robot.velocity.y],
		"position": [robot.global_position.x, robot.global_position.y],
		"target_player_id": combat_sense_target_player.get_instance_id(),
		"objective_target_id": 0,
	}


func _summarize(samples: Array[float]) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	return {
		"sample_count": sorted.size(),
		"samples": samples.duplicate(),
		"median_ms": _median(sorted),
		"p95_ms": _nearest_rank(sorted, 0.95),
		"min_ms": sorted.front() if not sorted.is_empty() else 0.0,
		"max_ms": sorted.back() if not sorted.is_empty() else 0.0,
	}


func _median(samples: Array[float]) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 0:
		return (sorted[middle - 1] + sorted[middle]) * 0.5
	return sorted[middle]


func _nearest_rank(sorted: Array[float], percentile: float) -> float:
	if sorted.is_empty():
		return 0.0
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


func _mix_checksum(checksum: int, value: int) -> int:
	return posmod(checksum * CHECKSUM_MULTIPLIER + value, CHECKSUM_MODULUS)


func _mix_vector_checksum(checksum: int, value: Vector2) -> int:
	var mixed := _mix_checksum(checksum, roundi(value.x * 1000.0))
	return _mix_checksum(mixed, roundi(value.y * 1000.0))


func _points_to_json(points_variant: Variant) -> Array[Array]:
	var result: Array[Array] = []
	var points := points_variant as PackedVector2Array
	for point in points:
		result.append([point.x, point.y])
	return result


func _finish(result: Dictionary) -> void:
	if not result.is_empty():
		result["status"] = "ok" if failures.is_empty() else "failed"
		result["failures"] = failures.duplicate()
		print(
			"RECENT_ENEMY_HOT_PATH_PERFORMANCE_AB_RESULT %s"
			% JSON.stringify(result)
		)
	if warning_line != null and authored_warning_points.size() == 2:
		warning_line.points = authored_warning_points
		warning_line.visible = false
	for sense_enemy in combat_sense_enemies:
		if sense_enemy != null and is_instance_valid(sense_enemy):
			sense_enemy.set_target_player(null)
			sense_enemy.set_objective_target(null)
	if combat_sense_target_player != null:
		combat_sense_target_player.free()
		combat_sense_target_player = null
	Enemy.combat_sense_throttling_enabled = original_combat_sense_throttling
	current_scene = null
	if runtime != null:
		runtime.queue_free()
	for _cleanup_index in range(CLEANUP_FRAMES):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("RECENT_ENEMY_HOT_PATH_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
