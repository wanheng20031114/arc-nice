extends SceneTree

const COORDINATOR_SCENE := preload(
	"res://scene/game_modes/tower_defense/multiplayer/fate/mp_tower_fate_coordinator.tscn"
)
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const MP_GAME_SOURCE_PATH := "res://scene/multiplayer/mp_game.gd"
const FATE_MANAGER_SOURCE_PATH := (
	"res://scene/game_modes/tower_defense/fate/tower_defense_fate_manager.gd"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)


class TestRuntime:
	extends CombatRuntimeBase

	var test_player: Player = null

	func _ready() -> void:
		pass

	func configure_multiplayer(
		_mode: int,
		_local_peer_id: int,
		_player_names: Dictionary,
		_player_character_ids: Dictionary = {}
	) -> void:
		pass

	func get_player_for_peer(peer_id: int) -> Player:
		return test_player if test_player != null and test_player.peer_id == peer_id else null

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

	func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
		pass


class TestNetManager:
	extends NetManagerStore

	var host_mode := true
	var gameplay_admitted := true

	func is_host() -> bool:
		return host_mode

	func is_client() -> bool:
		return not host_mode

	func get_local_peer_id() -> int:
		return 1 if host_mode else 2

	func get_host_peer_id() -> int:
		return 1

	func is_peer_send_ready(peer_id: int) -> bool:
		return peer_id > 0

	func is_gameplay_ingress_admitted(peer_id: int) -> bool:
		return gameplay_admitted and peer_id > 0


class TestTowerAdapter:
	extends TowerDefenseMultiplayerModeAdapter

	var interaction_peers: Array[int] = []
	var votes: Array[Dictionary] = []
	var collectible_choices: Array[Dictionary] = []
	var applied_states: Array[Dictionary] = []
	var fate_snapshot := {"revision": 17, "phase": "voting"}

	func request_xiaocong_interaction(peer_id: int) -> void:
		interaction_peers.append(peer_id)

	func request_xiaocong_fate_vote(
		peer_id: int,
		option_id: StringName,
		permanent_buff_id: StringName
	) -> void:
		votes.append({
			"peer_id": peer_id,
			"option_id": option_id,
			"permanent_buff_id": permanent_buff_id,
		})

	func request_xiaocong_collectible_choice(
		peer_id: int,
		choice_index: int
	) -> void:
		collectible_choices.append({
			"peer_id": peer_id,
			"choice_index": choice_index,
		})

	func get_xiaocong_fate_state_snapshot() -> Dictionary:
		return fate_snapshot.duplicate(true)

	func apply_remote_xiaocong_fate_state(state: Dictionary) -> bool:
		applied_states.append(state.duplicate(true))
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var coordinator := COORDINATOR_SCENE.instantiate() as MpTowerFateCoordinator
	_expect(coordinator != null, "TowerFateCoordinator scene must instantiate.")
	if coordinator == null:
		_finish()
		return
	root.add_child(coordinator)
	_test_static_boundary(coordinator)
	_test_host_and_client_paths(coordinator)
	coordinator.queue_free()
	await process_frame
	_finish()


func _test_static_boundary(coordinator: MpTowerFateCoordinator) -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(
		mp_game != null
		and mp_game.get_node_or_null("TowerFateCoordinator")
		is MpTowerFateCoordinator,
		"MpGame must statically contain TowerFateCoordinator."
	)
	if mp_game != null:
		mp_game.free()
	var source := FileAccess.get_file_as_string(MP_GAME_SOURCE_PATH)
	var rpc_pattern := RegEx.new()
	rpc_pattern.compile("(?m)^@rpc\\(")
	_expect(
		rpc_pattern.search_all(source).size() == 151,
		(
			"Tower fate extraction must preserve all 151 protocol-v94 MpGame "
			+ "RPC facades, including the embedded Rogue transport."
		)
	)
	for function_name in [
		"net_xiaocong_interaction_requested",
		"net_xiaocong_fate_vote_requested",
		"net_xiaocong_collectible_choice_requested",
	]:
		_expect(
			_rpc_entry_captures_sender_first(source, function_name),
			"%s must capture sender in its first executable line." % function_name
		)
		_expect(
			_rpc_entry_uses_shared_admission_before_fate(source, function_name),
			"%s must use shared admission before fate domain handling."
			% function_name
		)
	_expect(
		not source.contains("func _admit_remote_xiaocong_request"),
		"MpGame must not retain the extracted Xiaocong domain admission helper."
	)
	var bare_mp_game := MP_GAME_SCRIPT.new()
	_expect(
		bare_mp_game._is_valid_xiaocong_vote_payload(
			TowerDefenseFateRegistry.OPTION_CRITICAL_CORE,
			StringName()
		),
		"Bare MpGame instances must retain the pure vote validation facade."
	)
	bare_mp_game.free()
	var coordinator_source := coordinator.get_script().source_code as String
	_expect(
		not coordinator_source.contains("current_scene")
		and not coordinator_source.contains("has_method")
		and not coordinator_source.contains(".call("),
		"TowerFateCoordinator must use typed dependencies without dynamic guessing."
	)
	var fate_source := FileAccess.get_file_as_string(FATE_MANAGER_SOURCE_PATH)
	for contract in [
		"const PERMANENT_BUFF_OFFER_COUNT := 3",
		"func _roll_permanent_buff_offer() -> void:",
		"func submit_vote(",
		"func _choose_majority_value(",
	]:
		_expect(
			fate_source.contains(contract),
			"FateManager must preserve unselected three-choice voting contract: %s"
			% contract
		)


func _test_host_and_client_paths(coordinator: MpTowerFateCoordinator) -> void:
	var runtime := TestRuntime.new()
	var player := PLAYER_SCENE.instantiate() as Player
	player.peer_id = 2
	runtime.test_player = player
	var adapter := TestTowerAdapter.new()
	var net_manager := TestNetManager.new()
	coordinator.bind_runtime(runtime, adapter, net_manager, 0.0)

	coordinator.request_local_interaction()
	coordinator.request_local_vote(TowerDefenseFateRegistry.OPTION_BASE_REBUILD, &"")
	coordinator.request_local_collectible_choice(1)
	_expect(adapter.interaction_peers == [1], "Host local interaction must apply directly.")
	_expect(adapter.votes.size() == 1, "Host local valid vote must apply directly.")
	_expect(
		adapter.collectible_choices.size() == 1,
		"Host local collectible choice must apply directly."
	)

	coordinator.clear_peer(2)
	adapter.interaction_peers.clear()
	var votes_before_denial := adapter.votes.size()
	var choices_before_denial := adapter.collectible_choices.size()
	net_manager.gameplay_admitted = false
	coordinator.handle_remote_interaction(2)
	coordinator.handle_remote_vote(
		2,
		String(TowerDefenseFateRegistry.OPTION_BASE_REBUILD),
		""
	)
	coordinator.handle_remote_collectible_choice(2, 1)
	_expect(
		adapter.interaction_peers.is_empty()
		and adapter.votes.size() == votes_before_denial
		and adapter.collectible_choices.size() == choices_before_denial
		and (coordinator.get("_transaction_rate_buckets") as Dictionary).is_empty(),
		"重连 ready 前 Fate 请求必须零写且不能创建领域限流状态。"
	)
	net_manager.gameplay_admitted = true
	for request_index in range(11):
		coordinator.handle_remote_interaction(2)
	_expect(
		adapter.interaction_peers.size()
		== MpTowerFateCoordinator.XIAOCONG_TRANSACTION_RATE_BURST,
		"Xiaocong domain burst must admit ten requests and reject the overflow."
	)
	coordinator.clear_peer(2)
	coordinator.handle_remote_vote(
		2,
		String(TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT),
		String(TowerDefenseFateRegistry.BUFF_BUILDING_REGENERATION)
	)
	coordinator.handle_remote_vote(2, "unknown", "")
	coordinator.handle_remote_collectible_choice(2, 4)
	_expect(adapter.votes.size() == 2, "Only the valid remote permanent-buff vote must pass.")
	_expect(
		adapter.collectible_choices.size() == 1,
		"Out-of-range remote collectible choices must be rejected."
	)

	var broadcasts: Array[Dictionary] = []
	var peer_sends: Array[Dictionary] = []
	coordinator.rpc_broadcast_requested.connect(
		func(method_name: StringName, args: Array) -> void:
			broadcasts.append({"method": method_name, "args": args})
	)
	coordinator.rpc_to_peer_requested.connect(
		func(peer_id: int, method_name: StringName, args: Array) -> void:
			peer_sends.append({"peer_id": peer_id, "method": method_name, "args": args})
	)
	coordinator.handle_host_fate_state_changed({"revision": 18})
	coordinator.send_fate_state_to_peer(2)
	_expect(broadcasts.size() == 1, "Host fate changes must request one broadcast.")
	_expect(peer_sends.size() == 1, "Late join must request one authoritative fate snapshot.")

	net_manager.host_mode = false
	var host_requests: Array[Dictionary] = []
	coordinator.rpc_to_host_requested.connect(
		func(method_name: StringName, args: Array) -> void:
			host_requests.append({"method": method_name, "args": args})
	)
	coordinator.request_local_interaction()
	coordinator.request_local_vote(TowerDefenseFateRegistry.OPTION_BASE_REBUILD, &"")
	coordinator.request_local_collectible_choice(2)
	_expect(host_requests.size() == 3, "Client local fate decisions must route to host.")
	coordinator.receive_fate_state({"revision": 19}, 99)
	coordinator.receive_fate_state({"revision": 19}, 1)
	_expect(adapter.applied_states.size() == 1, "Client must only apply host fate state.")

	coordinator.unbind_runtime(runtime)
	player.free()
	runtime.free()
	adapter.free()
	net_manager.free()


func _rpc_entry_captures_sender_first(source: String, function_name: String) -> bool:
	var body := _function_body(source, function_name)
	if body.is_empty():
		return false
	for raw_line in body.split("\n"):
		var line := String(raw_line).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		return line == "var sender_id := multiplayer.get_remote_sender_id()"
	return false


func _rpc_entry_uses_shared_admission_before_fate(
	source: String,
	function_name: String
) -> bool:
	var body := _function_body(source, function_name)
	var admission_index := body.find(
		"transactions_coordinator.consume_remote_transaction_admission"
	)
	var fate_index := body.find("tower_fate_coordinator.handle_remote_")
	return admission_index >= 0 and fate_index > admission_index


func _function_body(source: String, function_name: String) -> String:
	var function_start := source.find("func %s(" % function_name)
	if function_start < 0:
		return ""
	var body_start := source.find(") -> void:\n", function_start)
	if body_start < 0:
		return ""
	body_start += ") -> void:".length()
	var next_function := source.find("\nfunc ", body_start + 1)
	var next_rpc := source.find("\n@rpc(", body_start + 1)
	var body_end := source.length()
	if next_function >= 0:
		body_end = mini(body_end, next_function)
	if next_rpc >= 0:
		body_end = mini(body_end, next_rpc)
	return source.substr(body_start + 1, body_end - body_start - 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("MP_TOWER_FATE_COORDINATOR_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
