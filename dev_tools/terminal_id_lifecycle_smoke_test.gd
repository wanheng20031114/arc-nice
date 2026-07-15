extends SceneTree

const GAME_SCRIPT := preload("res://scene/game.gd")
const TOWER_DEFENSE_GAME_SCRIPT := preload("res://scene/game_tower_defense.gd")

const HOST_AUTHORITY := 1
const CLIENT_VIEW := 2
const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
const PRESSURE_EVENT_COUNT := 4096


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_reasons: Array[int] = []

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		if method_name == &"net_enemy_terminal" and args.size() >= 2:
			sent_reasons.append(int(args[1]))


class ClientNetManagerStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_game_enemy_removal_markers()
	_test_tower_defense_enemy_escape_marker()
	_test_pickup_tree_exit_markers(GAME_SCRIPT.new(), "Game")
	_test_pickup_tree_exit_markers(TOWER_DEFENSE_GAME_SCRIPT.new(), "GameTowerDefense")
	_test_host_terminal_pairing_cache()
	_test_client_escape_compatibility_has_no_tombstone_cache()
	if failures.is_empty():
		print("TERMINAL_ID_LIFECYCLE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_game_enemy_removal_markers() -> void:
	_exercise_enemy_exit_pressure(GAME_SCRIPT.new(), "Game")
	_exercise_enemy_exit_pressure(TOWER_DEFENSE_GAME_SCRIPT.new(), "GameTowerDefense")


func _exercise_enemy_exit_pressure(runtime: Node, label: String) -> void:
	runtime.set("runtime_mode", HOST_AUTHORITY)
	var removed_ids: Array[int] = []
	runtime.connect(
		"multiplayer_enemy_removed",
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	var instance_to_net := runtime.get("multiplayer_enemy_ids_by_instance") as Dictionary
	var net_to_enemy := runtime.get("multiplayer_enemies_by_net_id") as Dictionary
	for event_index in range(PRESSURE_EVENT_COUNT):
		var instance_id := 100_000 + event_index
		var net_id := event_index + 1
		instance_to_net[instance_id] = net_id
		net_to_enemy[net_id] = null
		if event_index % 2 == 0:
			runtime.call("_on_wave_enemy_tree_exited", instance_id)
		else:
			runtime.call("_on_boss_enemy_tree_exited", instance_id)
	_expect(
		removed_ids.size() == PRESSURE_EVENT_COUNT,
		"%s must emit exactly one removal for each wave/boss exit." % label
	)
	runtime.free()


func _test_tower_defense_enemy_escape_marker() -> void:
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	runtime.runtime_mode = HOST_AUTHORITY
	var escaped_ids: Array[int] = []
	var removed_ids: Array[int] = []
	runtime.multiplayer_enemy_escaped.connect(
		func(net_id: int) -> void: escaped_ids.append(net_id)
	)
	runtime.multiplayer_enemy_removed.connect(
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	var enemy := Enemy.new()
	var enemy_instance_id := enemy.get_instance_id()
	var net_id := 77
	runtime.multiplayer_enemy_ids_by_instance[enemy_instance_id] = net_id
	runtime.multiplayer_enemies_by_net_id[net_id] = enemy
	runtime._emit_multiplayer_enemy_escaped(enemy)
	_expect(
		runtime.pending_multiplayer_enemy_escape_ids.size() == 1,
		"Escape must retain one marker only until the paired tree exit."
	)
	# Boss and boss-add exits share this removal path; it must consume, not retain,
	# the escape marker while suppressing the duplicate generic terminal event.
	runtime._on_boss_enemy_tree_exited(enemy_instance_id)
	_expect(escaped_ids == [net_id], "Escape must emit its terminal event once.")
	_expect(removed_ids.is_empty(), "Escape tree exit must suppress generic removal.")
	_expect(
		runtime.pending_multiplayer_enemy_escape_ids.is_empty(),
		"Escape marker must be consumed by the paired boss tree exit."
	)
	enemy.free()
	runtime.free()


func _test_pickup_tree_exit_markers(runtime: Node, label: String) -> void:
	runtime.set("runtime_mode", HOST_AUTHORITY)
	var removed_ids: Array[int] = []
	var collected_ids: Array[int] = []
	runtime.connect(
		"multiplayer_pickup_removed",
		func(net_id: int) -> void: removed_ids.append(net_id)
	)
	runtime.connect(
		"multiplayer_pickup_collected",
		func(net_id: int, _peer_id: int, _config: PickupConfig, _applied: bool) -> void:
			collected_ids.append(net_id)
	)
	var pickup := Pickup.new()
	var pickup_index := runtime.get("multiplayer_pickups") as Dictionary
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 1
		pickup.set_meta("net_id", net_id)
		pickup_index[net_id] = pickup
		runtime.call("_on_multiplayer_pickup_consumed", pickup, 2, true)
		runtime.call("_on_multiplayer_pickup_tree_exited", net_id)
	_expect(
		removed_ids.size() == PRESSURE_EVENT_COUNT,
		"%s consumed pickups must emit one removal despite their later tree exit." % label
	)
	_expect(
		collected_ids.size() == PRESSURE_EVENT_COUNT,
		"%s consumed pickups must preserve one collection confirmation." % label
	)
	_expect(
		(runtime.get("pending_multiplayer_pickup_exit_ids") as Dictionary).is_empty(),
		"%s consumed pickup suppression markers must be consumed." % label
	)

	var spontaneous_net_id := PRESSURE_EVENT_COUNT + 1
	pickup_index[spontaneous_net_id] = pickup
	runtime.call("_on_multiplayer_pickup_tree_exited", spontaneous_net_id)
	_expect(
		removed_ids.size() == PRESSURE_EVENT_COUNT + 1,
		"%s spontaneous pickup exit must still emit one generic removal." % label
	)
	_expect(
		(runtime.get("pending_multiplayer_pickup_exit_ids") as Dictionary).is_empty(),
		"%s spontaneous pickup exit must not allocate a tombstone." % label
	)
	pickup.free()
	runtime.free()


func _test_host_terminal_pairing_cache() -> void:
	var mp_game := RecordingMpGame.new()
	mp_game._broadcast_enemy_terminal(1, ENEMY_TERMINAL_DEFEATED, Vector2.ZERO)
	mp_game._broadcast_enemy_terminal(1, ENEMY_TERMINAL_DEFEATED, Vector2.ZERO)
	_expect(
		mp_game.sent_reasons == [ENEMY_TERMINAL_DEFEATED],
		"Duplicate defeated event must remain suppressed while removal is pending."
	)
	mp_game._broadcast_enemy_terminal(1, ENEMY_TERMINAL_REMOVED, Vector2.ZERO)
	_expect(
		mp_game._host_terminal_enemy_ids.is_empty(),
		"Generic removal must consume the pending defeated marker."
	)

	mp_game.sent_reasons.clear()
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 10
		mp_game._broadcast_enemy_terminal(
			net_id,
			ENEMY_TERMINAL_DEFEATED,
			Vector2.ZERO
		)
		mp_game._broadcast_enemy_terminal(
			net_id,
			ENEMY_TERMINAL_REMOVED,
			Vector2.ZERO
		)
	_expect(
		mp_game._host_terminal_enemy_ids.is_empty(),
		"Thousands of defeated→removed pairs must leave no Host terminal IDs."
	)
	_expect(
		mp_game.sent_reasons.size() == PRESSURE_EVENT_COUNT,
		"Defeated→removed pairs must send only the defeated terminal event."
	)

	mp_game.sent_reasons.clear()
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 20_000
		mp_game._broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_REMOVED, Vector2.ZERO)
		mp_game._broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_ESCAPED, Vector2.ZERO)
	_expect(
		mp_game._host_terminal_enemy_ids.is_empty(),
		"Direct removed/escaped terminals must never allocate Host tombstones."
	)
	_expect(
		mp_game.sent_reasons.size() == PRESSURE_EVENT_COUNT * 2,
		"Direct removed/escaped terminal sends must remain intact."
	)
	mp_game.free()


func _test_client_escape_compatibility_has_no_tombstone_cache() -> void:
	var mp_game := RecordingMpGame.new()
	var net_manager_stub := ClientNetManagerStub.new()
	mp_game.set("net_manager", net_manager_stub)
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	runtime.runtime_mode = CLIENT_VIEW
	mp_game.game = runtime
	for event_index in range(PRESSURE_EVENT_COUNT):
		var net_id := event_index + 1
		mp_game.net_enemy_terminal(net_id, ENEMY_TERMINAL_ESCAPED, Vector2.ZERO)
		mp_game.net_enemy_escaped(net_id)
		mp_game.net_enemy_removed(net_id)
	_expect(
		mp_game._net_enemies.is_empty(),
		"Unified and legacy escape/removal traffic must leave no client enemies."
	)
	var source := FileAccess.get_file_as_string("res://scene/multiplayer/mp_game.gd")
	_expect(
		source.find("_escaped_enemy_ids") < 0,
		"Client escape compatibility must not keep a session-long ID tombstone cache."
	)
	runtime.free()
	mp_game.free()
	net_manager_stub.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
