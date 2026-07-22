extends SceneTree

const MP_GAME_PATH := "res://scene/multiplayer/mp_game.gd"
const MP_GAME_SCRIPT := preload(MP_GAME_PATH)


class RecordingMpGame:
	extends "res://scene/multiplayer/mp_game.gd"

	var sent_methods: Array[StringName] = []
	var sent_arguments: Array[Array] = []

	func _rpc_to_connected_clients(
		method_name: StringName,
		args: Array = []
	) -> void:
		sent_methods.append(method_name)
		sent_arguments.append(args.duplicate(true))


class TestNetManager:
	extends Node

	var host_mode := false

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return not host_mode


class LightningVfxRuntime:
	extends GameRuntimeBase

	var played_chains: Array[PackedVector2Array] = []

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(_peer_id: int) -> Player:
		return null

	func get_enemy_for_net_id(_net_id: int) -> Enemy:
		return null

	func get_pickup_for_net_id(_net_id: int) -> Pickup:
		return null

	func remove_multiplayer_player(_peer_id: int) -> void:
		pass

	func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
		return []

	func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
		return []

	func apply_remote_flow_state(
		_step_id: StringName,
		_state: int,
		_seconds: int
	) -> void:
		pass

	func get_flow_state_snapshot() -> Dictionary:
		return {}

	func apply_remote_boss_started(
		_net_id: int,
		_boss_config: BossConfig,
		_spawn_position: Vector2
	) -> void:
		pass

	func apply_remote_defeat() -> void:
		pass

	func apply_remote_victory() -> void:
		pass

	func apply_remote_enemy_count(_alive_count: int) -> void:
		pass

	func apply_remote_merchant_active(_active: bool) -> void:
		pass

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass

	func try_purchase_skill1_for_peer(_peer_id: int) -> int:
		return 0

	func apply_skill1_purchase_state(
		_peer_id: int,
		_current_xirang: int,
		_skill1_unlocked: bool,
		_skill1_upgrade_level: int = -1,
		_skill1_charge_duration: float = -1.0
	) -> void:
		pass

	func show_local_skill1_purchase_result(_result_code: int) -> void:
		pass

	func try_refresh_luoxi_collectibles_for_peer(_peer_id: int) -> int:
		return 0

	func get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
		return 0

	func try_claim_luoxi_collectible_for_peer(
		_peer_id: int,
		_config_path_or_choice: Variant
	) -> int:
		return 0

	func has_luoxi_collectible_claimed(_peer_id: int) -> bool:
		return false

	func record_luoxi_collectible_claim(_peer_id: int) -> void:
		pass

	func mark_luoxi_collectible_claimed(_peer_id: int) -> void:
		pass

	func show_local_luoxi_collectible_result(_result_code: int) -> void:
		pass

	func show_local_luoxi_refresh_result(
		_result_code: int,
		_refresh_count: int,
		_current_xirang: int
	) -> void:
		pass

	func show_debug_collectible_grant_result(
		_config_path: String,
		_success: bool
	) -> void:
		pass

	func play_lightning_sorcerer_chain_vfx(points: PackedVector2Array) -> bool:
		played_chains.append(points.duplicate())
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_host_broadcast_contract()
	_test_client_validation_and_visual_only_contract()

	if failures.is_empty():
		print("LIGHTNING_SORCERER_NETWORK_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_host_broadcast_contract() -> void:
	var mp_game := RecordingMpGame.new()
	var net_manager := TestNetManager.new()
	net_manager.host_mode = true
	mp_game.set("net_manager", net_manager)
	var valid_points := PackedVector2Array([
		Vector2(10.0, 20.0),
		Vector2(30.0, 40.0),
	])
	mp_game.broadcast_enemy_lightning_chain(valid_points)
	_expect(
		mp_game.sent_methods == [&"net_enemy_lightning_chain"]
		and mp_game.sent_arguments.size() == 1
		and mp_game.sent_arguments[0].size() == 1
		and mp_game.sent_arguments[0][0] == valid_points,
		"Host must send one PackedVector2Array and no gameplay payload alongside it."
	)

	mp_game.broadcast_enemy_lightning_chain(PackedVector2Array())
	mp_game.broadcast_enemy_lightning_chain(_make_points(1))
	mp_game.broadcast_enemy_lightning_chain(_make_points(7))
	mp_game.broadcast_enemy_lightning_chain(PackedVector2Array([Vector2(INF, 0.0)]))
	_expect(
		mp_game.sent_methods.size() == 1,
		"Host must drop incomplete, oversized, and non-finite lightning visual payloads."
	)
	mp_game.free()
	net_manager.free()


func _test_client_validation_and_visual_only_contract() -> void:
	var mp_game := MP_GAME_SCRIPT.new()
	var net_manager := TestNetManager.new()
	var runtime := LightningVfxRuntime.new()
	mp_game.set("net_manager", net_manager)
	mp_game.set("game", runtime)

	var two_points := _make_points(2)
	var six_points := _make_points(6)
	mp_game.net_enemy_lightning_chain(two_points)
	mp_game.net_enemy_lightning_chain(six_points)
	_expect(
		runtime.played_chains.size() == 2
		and runtime.played_chains[0] == two_points
		and runtime.played_chains[1] == six_points,
		"Client must accept only the inclusive 2..6-point visual payload range."
	)

	mp_game.net_enemy_lightning_chain(PackedVector2Array())
	mp_game.net_enemy_lightning_chain(_make_points(1))
	mp_game.net_enemy_lightning_chain(_make_points(7))
	mp_game.net_enemy_lightning_chain(PackedVector2Array([Vector2(NAN, 0.0)]))
	mp_game.net_enemy_lightning_chain(PackedVector2Array([Vector2(0.0, -INF)]))
	_expect(
		runtime.played_chains.size() == 2,
		"Client must drop out-of-range arrays plus NaN and infinite coordinates."
	)

	var source := FileAccess.get_file_as_string(MP_GAME_PATH)
	var function_start := source.find("func net_enemy_lightning_chain(")
	var function_end := -1
	var rpc_body := ""
	if function_start >= 0:
		function_end = source.find("\n\nfunc ", function_start)
		if function_end < 0:
			function_end = source.length()
		rpc_body = source.substr(function_start, function_end - function_start)
	_expect(
		function_start >= 0
		and function_end > function_start
		and rpc_body.contains("play_lightning_sorcerer_chain_vfx")
		and not rpc_body.contains("find_nearest")
		and not rpc_body.contains("take_damage")
		and not rpc_body.contains("request_multiplayer")
		and not rpc_body.contains("apply_authoritative"),
		"Client RPC must replay pure VFX without target selection or damage execution."
	)
	mp_game.free()
	runtime.free()
	net_manager.free()


func _make_points(count: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	for point_index in range(count):
		points.append(Vector2(point_index * 8.0, point_index * -4.0))
	return points


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
