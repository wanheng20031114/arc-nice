extends SceneTree

const SAMPLE_COUNT := 21
const ITERATIONS_PER_SAMPLE := 384
const FIXED_SEED := 0x62D4A91B
const ENEMY_CONFIGS := [
	preload("res://resources/config/enemies/yuanshi_insect_basic.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fast.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_shell.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_bomber.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres"),
	preload("res://resources/config/enemies/yuanshi_insect_guardian.tres"),
]


class ProfileRuntimeProbe:
	extends TowerDefenseGame

	var home_targets: Array[Node2D] = []

	func get_home_objective_targets() -> Array[Node2D]:
		return home_targets


class ProfilePrewarmerProbe:
	extends TowerDefensePrewarmerCoordinator

	var body_half_extents_by_config_path: Dictionary = {}

	func _get_enemy_scene_body_half_extents(enemy_config: EnemyConfig) -> Vector2:
		var configured_extents: Vector2 = body_half_extents_by_config_path.get(
			enemy_config.resource_path,
			Vector2.ZERO
		)
		return configured_extents


var failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var fixture := _create_fixed_fixture()
	_test_strict_trace_parity(fixture)
	_warm_up(fixture, true)
	_warm_up(fixture, false)

	var legacy_time_samples: Array[int] = []
	var extracted_time_samples: Array[int] = []
	var legacy_memory_samples: Array[int] = []
	var extracted_memory_samples: Array[int] = []
	var legacy_hash := 0
	var extracted_hash := 0
	for sample_index in range(SAMPLE_COUNT):
		if sample_index % 2 == 0:
			legacy_hash ^= _measure_legacy(
				fixture,
				legacy_time_samples,
				legacy_memory_samples
			)
			extracted_hash ^= _measure_extracted(
				fixture,
				extracted_time_samples,
				extracted_memory_samples
			)
		else:
			extracted_hash ^= _measure_extracted(
				fixture,
				extracted_time_samples,
				extracted_memory_samples
			)
			legacy_hash ^= _measure_legacy(
				fixture,
				legacy_time_samples,
				legacy_memory_samples
			)

	legacy_time_samples.sort()
	extracted_time_samples.sort()
	legacy_memory_samples.sort()
	extracted_memory_samples.sort()
	var p50_index := _nearest_rank_index(0.50)
	var p95_index := _nearest_rank_index(0.95)
	var legacy_p50 := legacy_time_samples[p50_index]
	var extracted_p50 := extracted_time_samples[p50_index]
	var legacy_p95 := legacy_time_samples[p95_index]
	var extracted_p95 := extracted_time_samples[p95_index]
	var legacy_memory_p50 := legacy_memory_samples[p50_index]
	var extracted_memory_p50 := extracted_memory_samples[p50_index]
	var legacy_memory_p95 := legacy_memory_samples[p95_index]
	var extracted_memory_p95 := extracted_memory_samples[p95_index]
	var p50_limit := legacy_p50 + maxi(ceili(legacy_p50 * 0.05), 200)
	var p95_limit := legacy_p95 + maxi(ceili(legacy_p95 * 0.05), 200)
	var memory_p50_limit := legacy_memory_p50 + maxi(
		ceili(legacy_memory_p50 * 0.05),
		16 * 1024 * 1024
	)
	var memory_p95_limit := legacy_memory_p95 + maxi(
		ceili(legacy_memory_p95 * 0.05),
		16 * 1024 * 1024
	)

	_expect(
		legacy_hash == extracted_hash,
		"Prewarmer profile/target 轨迹必须严格一致：legacy=%d extracted=%d。"
		% [legacy_hash, extracted_hash]
	)
	_expect(
		extracted_p50 <= p50_limit,
		"extracted p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p50, extracted_p50, p50_limit]
	)
	_expect(
		extracted_p95 <= p95_limit,
		"extracted p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_p95, extracted_p95, p95_limit]
	)
	_expect(
		extracted_memory_p50 <= memory_p50_limit,
		"extracted memory p50 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p50, extracted_memory_p50, memory_p50_limit]
	)
	_expect(
		extracted_memory_p95 <= memory_p95_limit,
		"extracted memory p95 超限：legacy=%d extracted=%d limit=%d。"
		% [legacy_memory_p95, extracted_memory_p95, memory_p95_limit]
	)

	_cleanup_fixture(fixture)
	if failures.is_empty():
		print(
			"TOWER_DEFENSE_PREWARMER_COORDINATOR_AB_PROBE_OK legacy_p50_usec=%d extracted_p50_usec=%d legacy_p95_usec=%d extracted_p95_usec=%d p50_limit_usec=%d p95_limit_usec=%d legacy_memory_p50_bytes=%d extracted_memory_p50_bytes=%d legacy_memory_p95_bytes=%d extracted_memory_p95_bytes=%d memory_p50_limit_bytes=%d memory_p95_limit_bytes=%d trajectory_hash=%d seed=%d"
			% [
				legacy_p50,
				extracted_p50,
				legacy_p95,
				extracted_p95,
				p50_limit,
				p95_limit,
				legacy_memory_p50,
				extracted_memory_p50,
				legacy_memory_p95,
				extracted_memory_p95,
				memory_p50_limit,
				memory_p95_limit,
				legacy_hash,
				FIXED_SEED,
			]
		)
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _create_fixed_fixture() -> Dictionary:
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var waves: Array[WaveConfig] = []
	for wave_index in range(8):
		var wave := WaveConfig.new()
		wave.wave_name = "A/B %02d" % wave_index
		for _entry_index in range(18):
			var entry := WaveEnemyEntry.new()
			entry.enemy_config = ENEMY_CONFIGS[
				random_generator.randi_range(0, ENEMY_CONFIGS.size() - 1)
			] as EnemyConfig
			wave.enemy_entries.append(entry)
		waves.append(wave)

	var runtime := ProfileRuntimeProbe.new()
	runtime.player = Player.new()
	runtime.player.global_position = Vector2(
		random_generator.randf_range(-320.0, 320.0),
		random_generator.randf_range(-180.0, 180.0)
	)
	for _target_index in range(4):
		var target := Node2D.new()
		target.global_position = Vector2(
			random_generator.randf_range(-320.0, 320.0),
			random_generator.randf_range(-180.0, 180.0)
		)
		runtime.home_targets.append(target)

	var coordinator := ProfilePrewarmerProbe.new()
	coordinator.runtime = runtime
	coordinator.waves.assign(waves)
	for config_index in range(ENEMY_CONFIGS.size()):
		var enemy_config := ENEMY_CONFIGS[config_index] as EnemyConfig
		# Repeated extent buckets deliberately exercise extent-key de-duplication
		# after scene-key de-duplication without mutating authored resources.
		coordinator.body_half_extents_by_config_path[enemy_config.resource_path] = Vector2(
			6.25 + float(config_index % 3),
			7.25 + float((config_index / 2) % 2)
		)
	return {
		"runtime": runtime,
		"coordinator": coordinator,
		"waves": waves,
		"extents": coordinator.body_half_extents_by_config_path,
	}


func _test_strict_trace_parity(fixture: Dictionary) -> void:
	var coordinator := fixture["coordinator"] as ProfilePrewarmerProbe
	var runtime := fixture["runtime"] as ProfileRuntimeProbe
	var legacy_profiles := _legacy_collect_unique_enemy_profiles(
		fixture["waves"] as Array[WaveConfig],
		fixture["extents"] as Dictionary
	)
	var extracted_profiles := coordinator._collect_unique_enemy_profiles()
	var legacy_targets := _legacy_collect_navigation_targets(runtime)
	var extracted_targets := coordinator._collect_navigation_targets()
	var legacy_trace := _trace_hash(legacy_profiles, legacy_targets)
	var extracted_trace := _trace_hash(extracted_profiles, extracted_targets)
	_expect(
		legacy_trace == extracted_trace,
		"固定 seed 的 profile 去重与 navigation target 顺序必须严格一致。"
	)
	_expect(
		extracted_targets.size() == 1 + runtime.home_targets.size()
		and is_same(extracted_targets[0], runtime.player),
		"导航目标顺序必须固定为本地玩家在前、Home 目标在后。"
	)
	for target_index in range(runtime.home_targets.size()):
		_expect(
			is_same(extracted_targets[target_index + 1], runtime.home_targets[target_index]),
			"Home 导航目标顺序不得在协调器迁移后重排。"
		)


func _legacy_collect_unique_enemy_profiles(
	wave_configs: Array[WaveConfig],
	body_half_extents_by_config_path: Dictionary
) -> Array[Dictionary]:
	var profiles: Array[Dictionary] = []
	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in wave_configs:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true
			var body_half_extents: Vector2 = body_half_extents_by_config_path.get(
				enemy_config.resource_path,
				Vector2.ZERO
			)
			if body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			profiles.append({
				"half_extents": body_half_extents,
				"traversal_types": traversal_types,
			})
	return profiles


func _legacy_collect_navigation_targets(
	runtime: ProfileRuntimeProbe
) -> Array[Node2D]:
	var navigation_targets: Array[Node2D] = []
	if runtime.player != null:
		navigation_targets.append(runtime.player)
	navigation_targets.append_array(runtime.get_home_objective_targets())
	return navigation_targets


func _measure_legacy(
	fixture: Dictionary,
	time_samples: Array[int],
	memory_samples: Array[int]
) -> int:
	var runtime := fixture["runtime"] as ProfileRuntimeProbe
	var wave_configs := fixture["waves"] as Array[WaveConfig]
	var extents := fixture["extents"] as Dictionary
	var checksum := 0
	var started_at := Time.get_ticks_usec()
	for iteration in range(ITERATIONS_PER_SAMPLE):
		var profiles := _legacy_collect_unique_enemy_profiles(wave_configs, extents)
		var targets := _legacy_collect_navigation_targets(runtime)
		checksum = hash([checksum, iteration, _trace_hash(profiles, targets)])
	time_samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	return checksum


func _measure_extracted(
	fixture: Dictionary,
	time_samples: Array[int],
	memory_samples: Array[int]
) -> int:
	var coordinator := fixture["coordinator"] as ProfilePrewarmerProbe
	var checksum := 0
	var started_at := Time.get_ticks_usec()
	for iteration in range(ITERATIONS_PER_SAMPLE):
		var profiles := coordinator._collect_unique_enemy_profiles()
		var targets := coordinator._collect_navigation_targets()
		checksum = hash([checksum, iteration, _trace_hash(profiles, targets)])
	time_samples.append(Time.get_ticks_usec() - started_at)
	memory_samples.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	return checksum


func _trace_hash(
	profiles: Array[Dictionary],
	navigation_targets: Array[Node2D]
) -> int:
	var trace: Array = []
	for profile in profiles:
		var half_extents: Vector2 = profile["half_extents"]
		trace.append([
			ceili(half_extents.x * 1000.0),
			ceili(half_extents.y * 1000.0),
			int(profile["traversal_types"]),
		])
	for navigation_target in navigation_targets:
		trace.append([
			roundi(navigation_target.global_position.x * 1000.0),
			roundi(navigation_target.global_position.y * 1000.0),
		])
	return hash(trace)


func _warm_up(fixture: Dictionary, use_legacy: bool) -> void:
	var discarded_times: Array[int] = []
	var discarded_memory: Array[int] = []
	if use_legacy:
		_measure_legacy(fixture, discarded_times, discarded_memory)
	else:
		_measure_extracted(fixture, discarded_times, discarded_memory)


func _cleanup_fixture(fixture: Dictionary) -> void:
	var runtime := fixture["runtime"] as ProfileRuntimeProbe
	for target in runtime.home_targets:
		target.free()
	runtime.home_targets.clear()
	if runtime.player != null:
		runtime.player.free()
		runtime.player = null
	(fixture["coordinator"] as ProfilePrewarmerProbe).free()
	runtime.free()


func _nearest_rank_index(percentile: float) -> int:
	return clampi(ceili(SAMPLE_COUNT * percentile) - 1, 0, SAMPLE_COUNT - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
