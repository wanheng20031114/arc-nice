extends SceneTree

## Historical entrypoint retained for existing CI commands. Tower Defense no
## longer owns a GridPathfinder/Home flow field; this benchmark now measures
## the replacement SIMPLE_LINEAR cohort and proves that its navigation work
## never enters grid, profile, prefetch, test_move, or budget paths.

const TEST_RUNTIME_SCRIPT := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.gd"
)
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)
const ENEMY_COUNT := 300
const WARMUP_TICKS := 30
const MEASURE_TICKS := 120

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := TEST_RUNTIME_SCRIPT.new() as CombatRuntimeBase
	runtime.enemy_navigation_mode = (
		CombatRuntimeBase.EnemyNavigationMode.SIMPLE_LINEAR
	)
	var target := Node2D.new()
	target.global_position = Vector2(1200.0, 600.0)
	root.add_child(target)
	var forbidden_pathfinder := Node.new()
	var enemies: Array[Enemy] = []
	for enemy_index in range(ENEMY_COUNT):
		var enemy := ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
		root.add_child(enemy)
		enemy.global_position = Vector2(
			float(enemy_index % 25) * 3.0,
			float(enemy_index / 25) * 3.0
		)
		enemy.setup(ENEMY_CONFIG, null, forbidden_pathfinder, runtime)
		enemy.set_objective_target(target)
		enemies.append(enemy)
	await process_frame
	for enemy in enemies:
		_expect(
			enemy.uses_simple_enemy_navigation() and enemy.pathfinder == null,
			"Every benchmark enemy must freeze SIMPLE_LINEAR without a pathfinder."
		)

	Enemy.set_performance_metrics_enabled(true)
	for _tick in range(WARMUP_TICKS):
		await physics_frame
	Enemy.reset_performance_metrics()
	for _tick in range(MEASURE_TICKS):
		await physics_frame
	var metrics := Enemy.get_performance_metrics()
	Enemy.set_performance_metrics_enabled(false)

	print(
		(
			"TOWER_SIMPLE_LINEAR_CONTRACT enemies=%d ticks=%d "
			+ "move_and_slide=%d navigation=%d budget_deferrals=%d "
			+ "prefetch=%d test_move=%d host_physics_percentiles=profiler_required"
		)
		% [
			ENEMY_COUNT,
			MEASURE_TICKS,
			int(metrics["move_and_slide_calls"]),
			int(metrics["navigation_calls"]),
			int(metrics["navigation_budget_deferrals"]),
			int(metrics["navigation_flow_prefetches"]),
			int(metrics["test_move_calls"]),
		]
	)
	_expect(
		int(metrics["move_and_slide_calls"]) >= ENEMY_COUNT * MEASURE_TICKS,
		"Simple enemies must preserve 60 Hz move_and_slide collision motion."
	)
	_expect(
		int(metrics["navigation_calls"]) == 0,
		"Tower simple enemies must not enter complex navigation."
	)
	_expect(
		int(metrics["navigation_budget_deferrals"]) == 0,
		"Tower simple enemies must not request navigation budget."
	)
	_expect(
		int(metrics["navigation_flow_prefetches"]) == 0,
		"Tower simple enemies must not prefetch flow fields."
	)
	_expect(
		int(metrics["test_move_calls"]) == 0,
		"Tower simple navigation must not issue test_move probes."
	)

	for enemy in enemies:
		enemy.queue_free()
	target.queue_free()
	forbidden_pathfinder.free()
	runtime.free()
	await process_frame
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("TOWER_SIMPLE_LINEAR_BENCHMARK_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)
