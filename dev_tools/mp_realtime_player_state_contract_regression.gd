extends SceneTree

const TEST_RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_verify_embedded_ingress_lease()
	await _verify_player_body_space_lifecycle()
	if _failures.is_empty():
		print("MP_REALTIME_PLAYER_STATE_CONTRACT_REGRESSION_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _verify_embedded_ingress_lease() -> void:
	var session: Variant = MP_GAME_SCRIPT.new()
	if not session.is_realtime_player_state_exchange_enabled():
		_failures.append("A standalone MpGame must always exchange realtime Player state.")
	if session.set_embedded_realtime_player_state_ingress_enabled(true):
		_failures.append("A standalone MpGame must reject the embedded-only ingress API.")

	var runtime := TEST_RUNTIME_SCENE.instantiate() as CombatRuntimeBase
	session.embedded_runtime = true
	session.game = runtime
	if session.is_realtime_player_state_exchange_enabled():
		_failures.append("An embedded MpGame must start with realtime ingress disabled.")
	if session.set_embedded_realtime_player_state_ingress_enabled(true):
		_failures.append("Ingress must remain disabled before embedded activation.")
	session._embedded_runtime_active = true
	if not session.set_embedded_realtime_player_state_ingress_enabled(true):
		_failures.append("An active embedded runtime must be able to acquire ingress.")
	if not session.is_realtime_player_state_exchange_enabled():
		_failures.append("The acquired embedded ingress lease was not observable.")
	if not session.set_embedded_realtime_player_state_ingress_enabled(false):
		_failures.append("An embedded runtime must be able to release ingress.")
	if session.is_realtime_player_state_exchange_enabled():
		_failures.append("Released embedded ingress must reject realtime exchange.")
	runtime.free()
	session.free()


func _verify_player_body_space_lifecycle() -> void:
	var coordinator := MpPlayerCoordinator.new()
	var net_manager := NetManagerStore.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	var runtime := TEST_RUNTIME_SCENE.instantiate() as CombatRuntimeBase
	var player := PLAYER_SCENE.instantiate() as Player
	if coordinator._is_player_motion_body_ready(player):
		_failures.append("A Player outside the SceneTree must not admit motion state.")

	root.add_child(runtime)
	runtime.add_child(player)
	player.peer_id = 1
	runtime.peer_players[player.peer_id] = player
	coordinator.bind_runtime(runtime)
	coordinator.bind_player_action_dependencies(
		net_manager,
		func() -> float: return 1.0,
		func(_peer_id: int) -> bool: return false
	)
	await process_frame
	await physics_frame
	if not coordinator._is_player_motion_body_ready(player):
		_failures.append("An in-tree Player must own the current World2D space RID.")

	player.process_mode = Node.PROCESS_MODE_DISABLED
	await physics_frame
	if coordinator._is_player_motion_body_ready(player):
		_failures.append("A disabled lifecycle Player must silently reject late motion state.")
	var observed := {
		"rejections": 0,
		"corrections": 0,
	}
	coordinator.player_state_rejected.connect(
		func(_peer_id: int, _sequence: int, _reason: StringName) -> void:
			observed["rejections"] = int(observed["rejections"]) + 1
	)
	coordinator.player_state_correction_requested.connect(
		func(_peer_id: int, _position: Vector2, _velocity: Vector2) -> void:
			observed["corrections"] = int(observed["corrections"]) + 1
	)
	coordinator._last_player_state_sequences[player.peer_id] = 7
	coordinator._accepted_player_state_positions[player.peer_id] = (
		player.global_position
	)
	coordinator._accepted_player_state_times[player.peer_id] = 0.5
	var lifecycle_position := player.global_position
	coordinator.handle_client_player_state(
		player.peer_id,
		8,
		lifecycle_position + Vector2.RIGHT,
		Vector2.RIGHT,
		Vector2.RIGHT,
		Vector2.ZERO,
		0,
		0,
		Vector2.ZERO,
		Vector2.ZERO
	)
	if (
		coordinator.get_last_accepted_player_input_sequence(player.peer_id) != 7
		or player.global_position != lifecycle_position
		or int(observed["rejections"]) != 0
		or int(observed["corrections"]) != 0
	):
		_failures.append(
			"A lifecycle-late packet must not advance sequence/position, emit correction, or count as an anti-cheat rejection."
		)

	player.process_mode = Node.PROCESS_MODE_INHERIT
	await physics_frame
	if not coordinator._is_player_motion_body_ready(player):
		_failures.append("A reactivated Player must rejoin its World2D space.")

	player.queue_free()
	if coordinator._is_player_motion_body_ready(player):
		_failures.append("A queued-for-deletion Player must reject motion state.")
	await process_frame
	runtime.queue_free()
	await process_frame
	coordinator.free()
	net_manager.free()
