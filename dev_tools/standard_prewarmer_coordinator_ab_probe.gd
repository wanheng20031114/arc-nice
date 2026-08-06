extends SceneTree

const STANDARD_GAME_SCENE := preload(
	"res://scene/game_modes/standard/standard_game.tscn"
)
const ENRAGE_SNIPER_CONFIG := preload(
	"res://resources/config/enemies/capoo_sniper.tres"
)
const SAMPLE_COUNT := 21
const EVENTS_PER_SAMPLE := 72
const FIXED_SEED := 0x51A7D42
const ARM_ARGUMENT_PREFIX := "--arm="
const CACHE_PROBE_PATH := "res://standard_prewarmer_ab_retained_probe.tres"


class LegacyStandardPrewarmLogic:
	extends RefCounted

	var object_pool: SessionObjectPool = null
	var boss: StandardBossCoordinator = null
	var runtime_resources_by_path: Dictionary[String, Resource] = {}
	var linglan_enrage_sniper_config: EnemyConfig = null

	func bind_dependencies(
		pool: SessionObjectPool,
		boss_coordinator: StandardBossCoordinator
	) -> void:
		object_pool = pool
		boss = boss_coordinator

	func register_mode_object_pools() -> void:
		object_pool.register_scene(StandardGame.TANGO_LASER_BULLET_POOL_SCENE, 64, 768)
		object_pool.register_scene(StandardGame.LINGLAN_SKILL1_BULLET_POOL_SCENE, 64, 768)
		object_pool.register_scene(
			StandardGame.LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE,
			16,
			96
		)

	func get_boss_runtime_resource_paths() -> Array[String]:
		var paths := boss.get_runtime_resource_paths()
		paths.append(StandardGame.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)
		return paths

	func load_threaded_or_direct(path: String) -> Resource:
		if path.is_empty():
			return null
		var retained_resource := runtime_resources_by_path.get(path) as Resource
		if retained_resource != null:
			return retained_resource
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			return ResourceLoader.load_threaded_get(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return ResourceLoader.load_threaded_get(path)
		return load(path)

	func get_linglan_enrage_sniper_config() -> EnemyConfig:
		if linglan_enrage_sniper_config == null:
			linglan_enrage_sniper_config = (
				load_threaded_or_direct(
					StandardGame.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH
				) as EnemyConfig
			)
		return linglan_enrage_sniper_config


var failures: Array[String] = []
var game: StandardGame = null
var legacy_logic: LegacyStandardPrewarmLogic = null
var retained_cache: Dictionary[String, Resource] = {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var arm := _get_requested_arm()
	if arm != "legacy" and arm != "extracted":
		push_error("未知 Standard Prewarmer A/B arm：%s。" % arm)
		quit(1)
		return
	await _setup_fixture(arm)
	if not failures.is_empty():
		_finish_with_failures()
		return
	var samples: Array[int] = []
	var trajectory_hash := 0
	_run_arm_events(arm)
	for _sample_index in range(SAMPLE_COUNT):
		var started_at := Time.get_ticks_usec()
		var sample_hash := _run_arm_events(arm)
		samples.append(Time.get_ticks_usec() - started_at)
		trajectory_hash = _combine_hash(trajectory_hash, sample_hash)
	samples.sort()
	var p50_usec := samples[_nearest_rank_index(samples.size(), 0.50)]
	var p95_usec := samples[_nearest_rank_index(samples.size(), 0.95)]
	await _cleanup_fixture()
	if not failures.is_empty():
		_finish_with_failures()
		return
	print(
		"STANDARD_PREWARMER_COORDINATOR_AB_ARM_OK arm=%s p50_usec=%d p95_usec=%d trajectory_hash=%d seed=%d"
		% [arm, p50_usec, p95_usec, trajectory_hash, FIXED_SEED]
	)
	quit(0)


func _setup_fixture(arm: String) -> void:
	game = STANDARD_GAME_SCENE.instantiate() as StandardGame
	_expect(game != null, "Standard Prewarmer A/B 必须实例化真实 StandardGame。")
	if game == null:
		return
	game.auto_start_waves = false
	root.add_child(game)
	current_scene = game
	await process_frame
	await physics_frame
	_expect(
		game.prewarmer_coordinator != null
		and game.prewarmer_coordinator.is_bound(),
		"Standard Prewarmer A/B 必须使用已绑定的真实静态协调器。"
	)
	retained_cache[CACHE_PROBE_PATH] = StandardGame.TANGO_LASER_BULLET_POOL_SCENE
	legacy_logic = LegacyStandardPrewarmLogic.new()
	legacy_logic.bind_dependencies(game.session_object_pool, game.boss_coordinator)
	if arm == "legacy":
		legacy_logic.runtime_resources_by_path = retained_cache
		legacy_logic.linglan_enrage_sniper_config = ENRAGE_SNIPER_CONFIG
	else:
		game.prewarmer_coordinator.replace_runtime_resources_by_path(retained_cache)
		game.prewarmer_coordinator.replace_linglan_enrage_sniper_config(
			ENRAGE_SNIPER_CONFIG
		)
	_verify_frozen_initial_state()


func _verify_frozen_initial_state() -> void:
	var expected_paths: Array[String] = [
		"res://resources/config/enemies/linglan_boss.tres",
		"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn",
		"res://scene/boss/linglan/boss_health_hud.tscn",
		StandardGame.LINGLAN_ENRAGE_SNIPER_CONFIG_PATH,
	]
	_expect(
		legacy_logic.get_boss_runtime_resource_paths() == expected_paths
		and game._get_boss_runtime_resource_paths() == expected_paths,
		"A/B 两臂必须从同一 Boss runtime path 顺序开始。"
	)
	var pool_paths: Array[String] = [
			StandardGame.TANGO_LASER_BULLET_POOL_SCENE.resource_path,
			StandardGame.LINGLAN_SKILL1_BULLET_POOL_SCENE.resource_path,
			StandardGame.LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE.resource_path,
	]
	var expected_created_counts: Array[int] = [64, 64, 16]
	var expected_capacities: Array[int] = [768, 768, 96]
	for index in range(3):
		var scene_path: String = pool_paths[index]
		var expected_created: int = expected_created_counts[index]
		var expected_capacity: int = expected_capacities[index]
		var metrics := game.session_object_pool.get_metrics(scene_path)
		_expect(
			int(metrics.get("created", -1)) == expected_created
			and int(metrics.get("retained_capacity", -1)) == expected_capacity,
			"A/B 初态对象池指标不符合冻结值：%s。" % scene_path
		)


func _run_arm_events(arm: String) -> int:
	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = FIXED_SEED
	var trace_hash := 17
	for event_index in range(EVENTS_PER_SAMPLE):
		var operation := random_generator.randi_range(0, 2)
		var event_hash := (
			_run_legacy_event(operation, event_index)
			if arm == "legacy"
			else _run_extracted_event(operation, event_index)
		)
		trace_hash = _combine_hash(trace_hash, event_hash)
	return _combine_hash(trace_hash, _pool_state_hash())


func _run_legacy_event(operation: int, event_index: int) -> int:
	match operation:
		0:
			legacy_logic.register_mode_object_pools()
			return _combine_hash(event_index, _pool_state_hash())
		1:
			return _resource_paths_hash(
				legacy_logic.get_boss_runtime_resource_paths()
			)
		_:
			var retained := legacy_logic.load_threaded_or_direct(CACHE_PROBE_PATH)
			var empty_resource := legacy_logic.load_threaded_or_direct("")
			var enrage := legacy_logic.get_linglan_enrage_sniper_config()
			return _resolver_state_hash(retained, empty_resource, enrage)


func _run_extracted_event(operation: int, event_index: int) -> int:
	match operation:
		0:
			game._register_mode_object_pools()
			return _combine_hash(event_index, _pool_state_hash())
		1:
			return _resource_paths_hash(game._get_boss_runtime_resource_paths())
		_:
			var retained := game._load_threaded_or_direct(CACHE_PROBE_PATH)
			var empty_resource := game._load_threaded_or_direct("")
			var enrage := game.get_linglan_enrage_sniper_config()
			return _resolver_state_hash(retained, empty_resource, enrage)


func _pool_state_hash() -> int:
	var result := 23
	for scene_path in [
		StandardGame.TANGO_LASER_BULLET_POOL_SCENE.resource_path,
		StandardGame.LINGLAN_SKILL1_BULLET_POOL_SCENE.resource_path,
		StandardGame.LINGLAN_SAKURA_HIT_EFFECT_POOL_SCENE.resource_path,
	]:
		var metrics := game.session_object_pool.get_metrics(scene_path)
		result = _combine_hash(result, int(metrics.get("created", -1)))
		result = _combine_hash(result, int(metrics.get("inactive", -1)))
		result = _combine_hash(result, int(metrics.get("retained_capacity", -1)))
	return result


func _resource_paths_hash(paths: Array[String]) -> int:
	var result := paths.size()
	for resource_path in paths:
		result = _combine_hash(result, resource_path.hash())
	return result


func _resolver_state_hash(
	retained: Resource,
	empty_resource: Resource,
	enrage: EnemyConfig
) -> int:
	var result := 31
	result = _combine_hash(
		result,
		retained.resource_path.hash() if retained != null else -1
	)
	result = _combine_hash(result, 1 if empty_resource == null else 0)
	result = _combine_hash(
		result,
		enrage.resource_path.hash() if enrage != null else -1
	)
	return result


func _combine_hash(current: int, value: int) -> int:
	return int((current * 65599 + value) & 0x7fffffff)


func _nearest_rank_index(size: int, percentile: float) -> int:
	return clampi(ceili(float(size) * percentile) - 1, 0, size - 1)


func _get_requested_arm() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(ARM_ARGUMENT_PREFIX):
			return argument.trim_prefix(ARM_ARGUMENT_PREFIX)
	return ""


func _cleanup_fixture() -> void:
	if game != null:
		game.queue_free()
	for _cleanup_frame in range(8):
		await process_frame
		await physics_frame
	legacy_logic = null
	retained_cache.clear()


func _finish_with_failures() -> void:
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
