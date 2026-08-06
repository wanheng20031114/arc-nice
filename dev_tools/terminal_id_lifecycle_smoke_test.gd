extends SceneTree

const GAME_SCRIPT := preload("res://scene/game_modes/standard/standard_game.gd")
const TOWER_DEFENSE_GAME_SCRIPT := preload("res://scene/game_modes/tower_defense/tower_defense_game.gd")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const ENEMY_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_basic.tres"
)

const HOST_AUTHORITY := 1
const CLIENT_VIEW := 2
const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
const PRESSURE_EVENT_COUNT := 4096


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_reasons: Array[int] = []
	var last_terminal_args: Array = []

	func _ready() -> void:
		pass

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		if method_name == &"net_enemy_terminal" and args.size() >= 2:
			sent_reasons.append(int(args[1]))
			last_terminal_args = args.duplicate(true)


class ClientNetManagerStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true


class HostNetManagerStub:
	extends Node

	signal connection_state_changed
	signal player_left
	signal player_reconnected(
		old_peer_id: int,
		new_peer_id: int,
		player_name: String,
		character_id: StringName
	)

	func is_host() -> bool:
		return true

	func is_client() -> bool:
		return false


class DamageNumberRecorder:
	extends Node2D

	var amount := 0
	var impact_direction := Vector2.ZERO
	var damage_type := -1

	func show_damage_number(
		confirmed_amount: int,
		_world_position: Vector2,
		confirmed_direction: Vector2,
		confirmed_type: EnemyConfig.DamageType
	) -> void:
		amount = confirmed_amount
		impact_direction = confirmed_direction
		damage_type = int(confirmed_type)


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_game_enemy_removal_markers()
	_test_tower_defense_enemy_escape_marker()
	_test_pickup_tree_exit_markers(GAME_SCRIPT.new(), "StandardGame")
	_test_pickup_tree_exit_markers(TOWER_DEFENSE_GAME_SCRIPT.new(), "TowerDefenseGame")
	_test_host_terminal_pairing_cache()
	_test_reliable_terminal_feedback_payload()
	_test_real_batch_damage_terminal_chain()
	_test_client_escape_compatibility_has_no_tombstone_cache()
	if failures.is_empty():
		print("TERMINAL_ID_LIFECYCLE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_game_enemy_removal_markers() -> void:
	_exercise_enemy_exit_pressure(GAME_SCRIPT.new(), "StandardGame")
	_exercise_enemy_exit_pressure(TOWER_DEFENSE_GAME_SCRIPT.new(), "TowerDefenseGame")


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


func _test_reliable_terminal_feedback_payload() -> void:
	var mp_game := RecordingMpGame.new()
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	var enemy := Enemy.new()
	var net_id := 606
	var lethal_request := DamageRequest.new(
		25,
		CombatTypes.DamageType.PHYSICAL
	)
	lethal_request.with_directions(Vector2.RIGHT)
	enemy.last_damage_result = DamageResolver.resolve(
		lethal_request,
		DamageTargetProfile.new(25)
	)
	enemy.current_health = 0
	enemy.is_dead = true
	runtime.multiplayer_enemies_by_net_id[net_id] = enemy
	mp_game.game = runtime
	mp_game._pending_enemy_damage_feedback[net_id] = {
		"current_health": 10,
		"damage": 15,
		"impact_direction": Vector2.LEFT,
		"damage_type": int(EnemyConfig.DamageType.MAGIC),
		"show_hit_particles": false,
	}
	mp_game._active_enemy_damage_feedback_context[net_id] = {
		"impact_direction": Vector2.RIGHT,
		"damage_type": int(EnemyConfig.DamageType.PHYSICAL),
		"show_hit_particles": true,
	}
	mp_game._broadcast_enemy_terminal(
		net_id,
		ENEMY_TERMINAL_DEFEATED,
		Vector2(12.0, 8.0)
	)
	var args := mp_game.last_terminal_args
	_expect(
		args.size() == 9
		and int(args[0]) == net_id
		and int(args[1]) == ENEMY_TERMINAL_DEFEATED
		and args[2] == Vector2(12.0, 8.0)
		and int(args[3]) == 0
		and int(args[4]) == enemy.health_revision
		and int(args[5]) == 40
		and args[6] == Vector2.RIGHT
		and int(args[7]) == int(EnemyConfig.DamageType.PHYSICAL)
		and bool(args[8]),
		"可靠终结事件必须合并未发送的15点反馈与最后25点致死伤害，并携带最终方向、类型和粒子标记。"
	)
	_expect(
		not mp_game._pending_enemy_damage_feedback.has(net_id),
		"致死反馈并入可靠终结事件后必须从不可靠批队列移除，避免重复浮字。"
	)
	runtime.multiplayer_enemies_by_net_id.clear()
	enemy.free()
	runtime.free()
	mp_game.free()


func _test_real_batch_damage_terminal_chain() -> void:
	var mp_game := RecordingMpGame.new()
	var keepalive_request := HTTPRequest.new()
	keepalive_request.name = "PublicRoomKeepaliveRequest"
	mp_game.add_child(keepalive_request)
	root.add_child(mp_game)
	var net_manager_stub := HostNetManagerStub.new()
	mp_game.net_manager = net_manager_stub
	var runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	runtime.runtime_mode = HOST_AUTHORITY
	mp_game.game = runtime
	runtime.multiplayer_enemy_defeated.connect(
		mp_game._on_host_enemy_defeated
	)
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	if enemy == null:
		_expect(false, "真实批伤终结链必须能实例化敌人。")
		root.remove_child(mp_game)
		mp_game.free()
		runtime.free()
		net_manager_stub.free()
		return
	mp_game.add_child(enemy)
	var lethal_config := ENEMY_CONFIG.duplicate(true) as EnemyConfig
	lethal_config.max_health = 40
	lethal_config.physical_defense = 0
	enemy.setup(lethal_config, null, null)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	var net_id := 707
	enemy.set_meta(&"net_id", net_id)
	runtime.multiplayer_enemy_ids_by_instance[
		enemy.get_instance_id()
	] = net_id
	runtime.multiplayer_enemies_by_net_id[net_id] = enemy
	enemy.defeated.connect(
		func(defeated_enemy: Enemy) -> void:
			runtime._emit_multiplayer_enemy_defeated(defeated_enemy)
	)
	var accepted := (
		mp_game.apply_authoritative_plant_enemy_damage_batch(
			9901,
			enemy,
			PackedInt64Array([40]),
			PackedInt32Array([1]),
			Vector2.RIGHT,
			EnemyConfig.DamageType.PHYSICAL
		)
	)
	var args := mp_game.last_terminal_args
	_expect(
		accepted
		and enemy.is_dead
		and args.size() == 9
		and int(args[0]) == net_id
		and int(args[1]) == ENEMY_TERMINAL_DEFEATED
		and int(args[3]) == 0
		and int(args[4]) == enemy.health_revision
		and int(args[5]) == 40
		and args[6] == Vector2.RIGHT
		and int(args[7]) == int(EnemyConfig.DamageType.PHYSICAL),
		"真实apply_damage_batch→defeated信号→可靠terminal链必须携带最后40点致死反馈。"
	)
	_expect(
		not mp_game._pending_enemy_damage_feedback.has(net_id)
		and not mp_game._active_enemy_damage_feedback_context.has(net_id),
		"真实致死批伤结束后不得遗留不可靠反馈或活动伤害上下文。"
	)
	var client_mp_game := RecordingMpGame.new()
	var client_net_manager := ClientNetManagerStub.new()
	var client_runtime := TOWER_DEFENSE_GAME_SCRIPT.new()
	client_runtime.runtime_mode = CLIENT_VIEW
	client_mp_game.net_manager = client_net_manager
	client_mp_game.game = client_runtime
	var damage_recorder := DamageNumberRecorder.new()
	root.add_child(damage_recorder)
	var client_enemy := ENEMY_SCENE.instantiate() as Enemy
	damage_recorder.add_child(client_enemy)
	client_enemy.setup(lethal_config, null, null)
	client_enemy.configure_multiplayer_proxy()
	client_enemy.set_meta(&"net_id", net_id)
	client_mp_game._net_enemies[net_id] = client_enemy
	client_runtime.multiplayer_enemies_by_net_id[net_id] = client_enemy
	client_runtime.multiplayer_enemy_ids_by_instance[
		client_enemy.get_instance_id()
	] = net_id
	client_mp_game.callv("net_enemy_terminal", args)
	_expect(
		client_enemy.is_dead
		and client_enemy.current_health == 0
		and not client_mp_game._net_enemies.has(net_id)
		and not client_runtime.multiplayer_enemies_by_net_id.has(net_id)
		and damage_recorder.amount == 40
		and damage_recorder.impact_direction == Vector2.RIGHT
		and damage_recorder.damage_type
		== int(EnemyConfig.DamageType.PHYSICAL),
		"客户端消费九参数可靠terminal时必须先显示最后40点伤害、应用0生命，再执行死亡移除。"
	)
	runtime.multiplayer_enemies_by_net_id.clear()
	runtime.multiplayer_enemy_ids_by_instance.clear()
	mp_game.remove_child(enemy)
	enemy.free()
	root.remove_child(mp_game)
	mp_game.free()
	runtime.free()
	net_manager_stub.free()
	damage_recorder.remove_child(client_enemy)
	client_enemy.free()
	root.remove_child(damage_recorder)
	damage_recorder.free()
	client_runtime.free()
	client_mp_game.free()
	client_net_manager.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
