extends SceneTree

const BUDGET_SCRIPT := preload("res://scene/enemy_spawn_effect_budget.gd")
const SPAWN_EFFECT_SCENE := preload(
	"res://scene/enemy/yuanshi_insect_spawn_effect.tscn"
)
const BULLET_HIT_EFFECT_SCENE := preload("res://scene/bullet_hit_effect.tscn")
const ENEMY_HIT_EFFECT_SCENE := preload("res://scene/enemy/enemy_hit_effect.tscn")

var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "EnemySpawnEffectBudgetSmokeFixture"
	root.add_child(fixture)
	current_scene = fixture

	await _test_jittered_sustained_rate()
	await _test_overload_is_bounded()
	await _test_offscreen_requests_preserve_visible_budget()
	_test_shared_runtime_pool_profile()
	_test_runtime_call_paths_share_the_budget()

	fixture.queue_free()
	await process_frame
	if failures.is_empty():
		print("ENEMY_SPAWN_EFFECT_BUDGET_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_jittered_sustained_rate() -> void:
	var budget = BUDGET_SCRIPT.new(40.0, 8.0)
	var batch_times := PackedFloat64Array([
		0.000,
		0.099,
		0.200,
		0.299,
		0.400,
		0.499,
		0.600,
		0.699,
		0.800,
		0.899,
	])
	var accepted := 0
	for batch_time in batch_times:
		for _spawn_index in range(4):
			if budget.try_consume_at(batch_time):
				accepted += 1
	_expect(
		accepted == 40,
		"A 99/101 ms jittered ten-batch wave must retain all 40 spawn effects."
	)
	await process_frame


func _test_overload_is_bounded() -> void:
	var budget = BUDGET_SCRIPT.new(40.0, 8.0)
	var initial_burst_accepted := 0
	for _request_index in range(16):
		if budget.try_consume_at(0.0):
			initial_burst_accepted += 1
	_expect(
		initial_burst_accepted == 8,
		"The two-batch burst reserve must reject the ninth simultaneous request."
	)
	var next_batch_accepted := 0
	for _request_index in range(8):
		if budget.try_consume_at(0.1):
			next_batch_accepted += 1
	_expect(
		next_batch_accepted == 4,
		"A saturated budget must replenish exactly four tokens per 100 ms."
	)
	await process_frame


func _test_offscreen_requests_preserve_visible_budget() -> void:
	var camera := Camera2D.new()
	camera.name = "BudgetCamera"
	camera.enabled = true
	fixture.add_child(camera)
	camera.global_position = Vector2.ZERO
	await process_frame
	_expect(
		fixture.get_viewport().get_camera_2d() == camera,
		"Spawn-effect visibility fixture must own the active viewport camera."
	)

	var budget = BUDGET_SCRIPT.new(40.0, 8.0)
	for _request_index in range(16):
		_expect(
			not budget.try_reserve(fixture, Vector2(100000.0, 100000.0), 0.0),
			"Far-offscreen pure visuals must be rejected before token consumption."
		)
	var visible_accepted := 0
	for _request_index in range(9):
		if budget.try_reserve(fixture, Vector2.ZERO, 0.0):
			visible_accepted += 1
	_expect(
		visible_accepted == 8,
		"Offscreen requests must leave all eight burst tokens for visible effects."
	)
	camera.queue_free()
	await process_frame


func _test_shared_runtime_pool_profile() -> void:
	var pool := SessionObjectPool.new()
	pool.name = "SharedVisualPoolProfile"
	fixture.add_child(pool)
	GameRuntimeBase.register_common_visual_effect_pools(pool)
	_expect_pool_capacity(
		pool,
		SPAWN_EFFECT_SCENE,
		GameRuntimeBase.ENEMY_SPAWN_EFFECT_RETAINED_CAPACITY,
		GameRuntimeBase.ENEMY_SPAWN_EFFECT_PREWARM_COUNT
	)
	_expect_pool_capacity(
		pool,
		BULLET_HIT_EFFECT_SCENE,
		64,
		64
	)
	_expect_pool_capacity(
		pool,
		ENEMY_HIT_EFFECT_SCENE,
		128,
		128
	)
	pool.queue_free()


func _test_runtime_call_paths_share_the_budget() -> void:
	for runtime_script_path in [
		"res://scene/game.gd",
		"res://scene/game_tower_defense.gd",
	]:
		var runtime_script := load(runtime_script_path) as GDScript
		_expect(runtime_script != null, "Runtime script must load: %s" % runtime_script_path)
		if runtime_script == null:
			continue
		var source := runtime_script.source_code
		_expect(
			source.count(
				"GameRuntimeBase.register_common_visual_effect_pools(session_object_pool)"
			) == 1,
			"Both runtime scenes must use the same visual pool profile: %s"
			% runtime_script_path
		)
		_expect(
			source.contains(
				"if not try_reserve_enemy_spawn_effect(spawn_global_position):"
			),
			"Local spawn visuals must use the shared visibility-first token bucket: %s"
			% runtime_script_path
		)
		_expect(
			source.contains(
				"func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:\n"
				+ "\t_spawn_enemy_spawn_effect(spawn_global_position)"
			),
			"Remote spawn visuals must follow the exact local budget path: %s"
			% runtime_script_path
		)
		_expect(
			not source.contains("_consume_spawn_effect_budget")
			and not source.contains("spawn_effects_this_second"),
			"Legacy fixed-window throttles must be removed: %s" % runtime_script_path
		)


func _expect_pool_capacity(
	pool: SessionObjectPool,
	scene: PackedScene,
	expected_capacity: int,
	expected_prewarmed: int
) -> void:
	var metrics := pool.get_metrics(scene.resource_path)
	_expect(
		int(metrics.get("retained_capacity", 0)) == expected_capacity
		and int(metrics.get("created", 0)) == expected_prewarmed,
		"Shared pool profile mismatch for %s: %s"
		% [scene.resource_path, str(metrics)]
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
