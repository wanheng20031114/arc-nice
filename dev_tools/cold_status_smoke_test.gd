extends SceneTree

const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const BASIC_ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const OTHER_SLOW_SOURCE_ID := 9_001
const FLOAT_EPSILON := 0.001
const CHILL_VISUAL_MASK := 4


class ColdCallbackProbe:
	extends RefCounted

	var events: Array[Dictionary] = []

	func apply_state(stack_count: int, multiplier: float) -> void:
		events.append({
			"stack_count": stack_count,
			"multiplier": multiplier,
		})

	func last_event() -> Dictionary:
		return events.back() if not events.is_empty() else {}


var failures: Array[String] = []
var fixture: Node2D = null
var scheduler: Node = null
var previous_slow_only_optimization_enabled := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "ColdStatusSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	scheduler = root.get_node("ColdStatusScheduler")
	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	previous_slow_only_optimization_enabled = (
		Enemy.slow_only_status_process_optimization_enabled
	)
	Enemy.set_slow_only_status_process_optimization_enabled(true)

	await _test_scheduler_stack_duration_and_boundary()
	await _test_player_and_enemy_speed_integration()
	await _test_building_rejection()
	await _test_death_and_exit_cleanup()

	scheduler.call("clear_all")
	scheduler.set_physics_process(false)
	Enemy.set_slow_only_status_process_optimization_enabled(
		previous_slow_only_optimization_enabled
	)
	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("COLD_STATUS_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_scheduler_stack_duration_and_boundary() -> void:
	scheduler.call("clear_all")
	var player := _spawn_player()
	var callback_probe := ColdCallbackProbe.new()
	var expected_stacks := [1, 2, 3, 4, 4]
	var expected_durations := [3.0, 4.0, 5.0, 6.0, 7.0]
	var expected_multipliers := [0.75, 0.60, 0.35, 0.10, 0.10]

	for hit_index in range(expected_stacks.size()):
		_expect(
			bool(scheduler.call(
				"apply_cold",
				player,
				Callable(callback_probe, "apply_state")
			)),
			"ColdStatusScheduler rejected valid hit %d." % (hit_index + 1)
		)
		var snapshot := _get_snapshot(player)
		_expect(
			int(scheduler.call("get_stack_count", player))
				== expected_stacks[hit_index]
			and int(snapshot.get("stack_count", -1))
				== expected_stacks[hit_index],
			"Cold hit %d produced the wrong stack count: %s."
			% [hit_index + 1, snapshot]
		)
		_expect(
			_is_close(
				float(snapshot.get("time_left", -1.0)),
				expected_durations[hit_index]
			),
			"Cold hit %d must leave %.1f seconds, saw %s."
			% [
				hit_index + 1,
				expected_durations[hit_index],
				str(snapshot.get("time_left", null)),
			]
		)
		_expect(
			_is_close(
				float(snapshot.get("multiplier", -1.0)),
				expected_multipliers[hit_index]
			),
			"Cold hit %d produced the wrong multiplier: %s."
			% [hit_index + 1, snapshot]
		)
		var event := callback_probe.last_event()
		_expect(
			callback_probe.events.size() == hit_index + 1
			and int(event.get("stack_count", -1)) == expected_stacks[hit_index]
			and _is_close(
				float(event.get("multiplier", -1.0)),
				expected_multipliers[hit_index]
			),
			"Every accepted cold hit must publish its new state exactly once."
		)

	_expect(
		bool(scheduler.call("has_cold", player))
		and int(scheduler.call("get_active_target_count")) == 1
		and int(scheduler.call("get_heap_size")) == 1,
		"One five-hit target must occupy one active cold state and a heap entry."
	)

	# Five same-frame hits produce L4 with seven seconds remaining. The state is
	# still logically active just before the boundary and clears at the boundary.
	scheduler.call("_advance_active_colds", 6.999)
	_expect(
		bool(scheduler.call("has_cold", player))
		and int(scheduler.call("get_stack_count", player)) == 4
		and _is_close(
			float(_get_snapshot(player).get("time_left", -1.0)),
			0.001,
			0.0002
		),
		"Level-4 cold must remain active immediately before its exact expiry."
	)
	scheduler.call("_advance_active_colds", 0.001)
	_expect(
		not bool(scheduler.call("has_cold", player))
		and int(scheduler.call("get_stack_count", player)) == 0
		and _get_snapshot(player).is_empty(),
		"Cold must clear at the exact seven-second boundary."
	)
	var expiry_event := callback_probe.last_event()
	_expect(
		int(expiry_event.get("stack_count", -1)) == 0
		and _is_close(float(expiry_event.get("multiplier", -1.0)), 1.0),
		"Expiry must publish stack zero and restore the default multiplier."
	)

	_expect(
		bool(scheduler.call(
			"apply_cold",
			player,
			Callable(callback_probe, "apply_state")
		)),
		"A target must accept cold again after expiry."
	)
	var reset_snapshot := _get_snapshot(player)
	_expect(
		int(reset_snapshot.get("stack_count", -1)) == 1
		and _is_close(float(reset_snapshot.get("time_left", -1.0)), 3.0)
		and _is_close(float(reset_snapshot.get("multiplier", -1.0)), 0.75),
		"The first post-expiry hit must restart at L1 for three seconds."
	)
	var clear_succeeded := bool(scheduler.call("clear_target", player))
	var clear_event := callback_probe.last_event()
	_expect(
		clear_succeeded
		and not bool(scheduler.call("has_cold", player))
		and int(scheduler.call("get_active_target_count")) == 0
		and int(clear_event.get("stack_count", -1)) == 0
		and _is_close(float(clear_event.get("multiplier", -1.0)), 1.0),
		"clear_target must remove the active state immediately."
	)

	player.queue_free()
	await process_frame


func _test_player_and_enemy_speed_integration() -> void:
	scheduler.call("clear_all")
	var player := _spawn_player()
	var player_base_speed := player.move_speed
	player.current_move_speed_multiplier = 1.25
	player.collectible_swift_move_speed_multiplier = 1.0
	_expect(
		bool(player.call("apply_cold_status"))
		and bool(player.call("apply_cold_status")),
		"Player.apply_cold_status must forward valid hits to the scheduler."
	)
	_expect(
		_is_close(
			float(player.call("_get_effective_move_speed")),
			player_base_speed * 1.25 * 0.60
		),
		"Player L2 cold must multiply, not overwrite, an existing speed effect."
	)
	scheduler.call("clear_target", player)
	_expect(
		_is_close(
			float(player.call("_get_effective_move_speed")),
			player_base_speed * 1.25
		),
		"Clearing player cold must preserve the unrelated speed multiplier."
	)

	var enemy := _spawn_enemy(player)
	var enemy_base_speed := BASIC_ENEMY_CONFIG.move_speed
	enemy.add_move_speed_modifier(OTHER_SLOW_SOURCE_ID, 0.8)
	enemy.set_process(false)
	_expect(
		bool(enemy.call("apply_cold_status"))
		and bool(enemy.call("apply_cold_status")),
		"Enemy.apply_cold_status must forward valid hits to the scheduler."
	)
	_expect(
		_is_close(
			enemy.get_effective_move_speed(),
			enemy_base_speed * 0.8 * 0.60
		),
		"Enemy L2 cold must coexist multiplicatively with other modifiers."
	)
	_expect(
		not enemy.is_processing(),
		"A slow-only Enemy must not enable a per-render-frame process callback."
	)
	_expect(
		(enemy.get_collectible_visual_status_mask() & CHILL_VISUAL_MASK) != 0,
		"Authoritative Enemy snapshots must expose active cold through chill bit 4."
	)
	scheduler.call("clear_target", enemy)
	_expect(
		_is_close(enemy.get_effective_move_speed(), enemy_base_speed * 0.8)
		and enemy.move_speed_modifiers.has(OTHER_SLOW_SOURCE_ID),
		"Clearing cold must not remove an unrelated Enemy speed modifier."
	)
	_expect(
		(enemy.get_collectible_visual_status_mask() & CHILL_VISUAL_MASK) == 0,
		"Clearing cold must remove Enemy chill visual bit 4."
	)

	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_building_rejection() -> void:
	scheduler.call("clear_all")
	var building := PlantDefense.new()
	var callback_probe := ColdCallbackProbe.new()
	_expect(
		not bool(scheduler.call(
			"apply_cold",
			building,
			Callable(callback_probe, "apply_state")
		)),
		"ColdStatusScheduler must reject every PlantDefense building."
	)
	_expect(
		int(scheduler.call("get_stack_count", building)) == 0
		and _get_snapshot(building).is_empty()
		and callback_probe.events.is_empty(),
		"A rejected building must not create state or receive a multiplier callback."
	)
	building.free()


func _test_death_and_exit_cleanup() -> void:
	scheduler.call("clear_all")
	var player := _spawn_player()
	_expect(bool(player.call("apply_cold_status")), "Player cold setup failed.")
	player.current_health = 1
	player.invincibility_time_left = 0.0
	player.apply_damage(999, EnemyConfig.DamageType.MAGIC)
	_expect(
		player.is_dead and not bool(scheduler.call("has_cold", player)),
		"Player death must synchronously clear cold state."
	)

	var enemy := _spawn_enemy(null)
	_expect(bool(enemy.call("apply_cold_status")), "Enemy cold setup failed.")
	# Keep the death-cleanup assertion isolated from rewards and random drops.
	var death_config := BASIC_ENEMY_CONFIG.duplicate() as EnemyConfig
	death_config.xirang_kill_reward = 0
	death_config.drop_table = null
	enemy.config = death_config
	enemy.current_health = 1
	enemy.apply_damage(
		999,
		Vector2.ZERO,
		EnemyConfig.DamageType.MAGIC,
		false
	)
	_expect(
		enemy.is_dead and not bool(scheduler.call("has_cold", enemy)),
		"Enemy death must synchronously clear cold state."
	)

	var exiting_enemy := _spawn_enemy(null)
	_expect(
		bool(exiting_enemy.call("apply_cold_status")),
		"Exit-cleanup cold setup failed."
	)
	exiting_enemy.queue_free()
	await process_frame
	_expect(
		int(scheduler.call("get_active_target_count")) == 0,
		"A target leaving the tree must not remain in the active cold table."
	)

	enemy.queue_free()
	player.queue_free()
	await process_frame


func _spawn_player() -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.set_physics_process(false)
	player.set_process(false)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	return player


func _spawn_enemy(target_player: Player) -> Enemy:
	var enemy := BASIC_ENEMY_CONFIG.enemy_scene.instantiate() as Enemy
	fixture.add_child(enemy)
	enemy.setup(BASIC_ENEMY_CONFIG, target_player, null)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.hit_audio.stream = null
	return enemy


func _get_snapshot(target: Object) -> Dictionary:
	return scheduler.call("get_state_snapshot", target) as Dictionary


func _is_close(
	actual: float,
	expected: float,
	epsilon: float = FLOAT_EPSILON
) -> bool:
	return absf(actual - expected) <= epsilon


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
