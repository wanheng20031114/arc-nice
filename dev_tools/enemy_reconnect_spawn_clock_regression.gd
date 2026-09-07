extends SceneTree

const ENEMY_PATH := "res://resources/config/enemies/yuanshi_insect_basic.tres"

class ClockRuntime extends TowerDefenseGame:
	var spawn_presentations := 0

	# This codec/lifecycle fixture binds real Enemy nodes and the authoritative
	# registry; only the unrelated spawn VFX pool is replaced by a counter.
	func play_remote_enemy_spawn_effect(_position: Vector2) -> void:
		spawn_presentations += 1


var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)


func _run() -> void:
	var runtime := ClockRuntime.new()
	runtime.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var container := Node2D.new()
	root.add_child(container)
	runtime.enemy_container = container
	var coordinator := MpEnemyCoordinator.new()
	coordinator.bind_runtime(runtime)
	var config := load(ENEMY_PATH) as EnemyConfig
	var faction := config.default_combat_faction_id
	coordinator.receive_enemy_spawn_packet(1, ENEMY_PATH, Vector2(10, 20), 1.0, 3.0, true, -100.0, faction, 0, true)
	var first := runtime.get_network_enemy(1)
	_check(first != null and coordinator.enemy_spawn_incarnation_tokens.get(1) == 1.0, "Historical spawn before the new local clock is accepted with original positive incarnation")
	_check(coordinator.enemy_spawn_snapshot_times.get(1) == -99.0, "Historical local timestamp is preserved exactly without clamping")
	if first != null:
		coordinator.receive_enemy_spawn_packet(1, ENEMY_PATH, Vector2(99, 99), 1.0, 4.0, true, -200.0, faction, 0, true)
		_check(runtime.get_network_enemy(1) == first, "Duplicate incarnation remains idempotent across changed clock offset")
		coordinator.receive_enemy_spawn_packet(1, ENEMY_PATH, Vector2(99, 99), 0.5, 4.0, true, -200.0, faction, 0, true)
		_check(runtime.get_network_enemy(1) == first and coordinator.enemy_spawn_incarnation_tokens[1] == 1.0, "Older incarnation remains rejected")
	for invalid_time in [-1.0, NAN, INF]:
		coordinator.receive_enemy_spawn_packet(2, ENEMY_PATH, Vector2.ZERO, invalid_time, 4.0, true, -100.0, faction, 0, true)
		_check(runtime.get_network_enemy(2) == null, "Invalid host wire timestamp rejected")
	for invalid_offset in [NAN, INF]:
		coordinator.receive_enemy_spawn_packet(2, ENEMY_PATH, Vector2.ZERO, 2.0, 4.0, true, invalid_offset, faction, 0, true)
		_check(runtime.get_network_enemy(2) == null, "Nonfinite mapped time rejected")
	coordinator.receive_enemy_spawn_packet(2, "res://not_registered.tres", Vector2.ZERO, 2.0, 4.0, true, -100.0, faction, 0, true)
	_check(runtime.get_network_enemy(2) == null, "Unknown config cannot enter through historical replay")
	for invalid_record in 2:
		var times := PackedFloat64Array([2.0, 3.0])
		times[invalid_record] = -1.0
		coordinator.receive_enemy_spawn_batch(PackedInt32Array([2, 3]), PackedStringArray([ENEMY_PATH, ENEMY_PATH]), PackedVector2Array([Vector2.ZERO, Vector2.ONE]), times, 4.0, true, -100.0, PackedByteArray([faction, faction]), PackedInt32Array([0, 0]), true)
		_check(runtime.get_network_enemy(2) == null and runtime.get_network_enemy(3) == null, "Invalid first/last raw token rejects the whole batch")
	coordinator.receive_enemy_spawn_batch(PackedInt32Array([2, 3]), PackedStringArray([ENEMY_PATH, ENEMY_PATH]), PackedVector2Array([Vector2.ZERO, Vector2.ONE]), PackedFloat64Array([2.0, 3.0]), 4.0, true, -100.0, PackedByteArray([faction, faction]), PackedInt32Array([0, 0]), true)
	_check(runtime.get_network_enemy(2) != null and runtime.get_network_enemy(3) != null, "Whole valid historical batch is restored")
	coordinator.mark_client_terminal(4, 20.0)
	coordinator.receive_enemy_spawn_packet(4, ENEMY_PATH, Vector2.ZERO, 19.0, 4.0, true, -100.0, faction, 0, true)
	_check(runtime.get_network_enemy(4) == null, "Terminal tombstone rejects old incarnation even with valid negative local mapping")
	coordinator.receive_enemy_spawn_packet(4, ENEMY_PATH, Vector2.ZERO, 21.0, 4.0, true, -100.0, faction, 0, true)
	_check(runtime.get_network_enemy(4) != null and not coordinator._is_client_terminal_blocked(4), "A genuinely newer incarnation can replace the tombstone")
	_check(runtime.spawn_presentations == 4, "Only four committed incarnations publish their spawn presentation")
	coordinator.unbind_runtime(runtime)
	runtime.clear_network_enemy_registry()
	container.free()
	coordinator.free()
	runtime.free()
	for frame in 3:
		await process_frame
	print("ENEMY_RECONNECT_CLOCK ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)
