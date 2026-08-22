extends SceneTree

const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const ROGUE_COMBAT_SCENE_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn"
)
const TEST_PORT := 19_349
const PREPARATION_TIMEOUT_MSEC := 30_000

var failures: Array[String] = []
var mp_game: MultiplayerGameplaySession = null
var net_manager: NetManagerStore = null


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_test_embedded_contract_atomicity()
	await _test_tower_session_with_rogue_runtime()
	await _cleanup()
	_finish()


func _test_embedded_contract_atomicity() -> void:
	var contract := MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	_expect(contract != null, "MpGame must implement MultiplayerGameplaySession.")
	if contract == null:
		return
	contract.embedded_runtime = true
	_expect(
		not contract.configure_embedded_runtime_contract(
			ROGUE_COMBAT_SCENE_PATH,
			GameModeCatalog.MODE_TEST_ARENA_P3,
			PackedInt32Array([1, 1])
		)
		and contract.runtime_scene_path_override.is_empty()
		and contract.runtime_game_mode_id_override
			== MultiplayerGameplaySession.INVALID_RUNTIME_GAME_MODE_ID,
		(
			"An invalid participant roster must not partially commit either embedded "
			+ "runtime override."
		)
	)
	_expect(
		contract.configure_embedded_runtime_contract(
			ROGUE_COMBAT_SCENE_PATH,
			GameModeCatalog.MODE_TEST_ARENA_P3,
			PackedInt32Array([1])
		)
		and contract.runtime_scene_path_override == ROGUE_COMBAT_SCENE_PATH
		and contract.runtime_game_mode_id_override
			== GameModeCatalog.MODE_TEST_ARENA_P3,
		(
			"A valid embedded runtime contract must atomically freeze its scene, mode, "
			+ "and participant roster before entering the tree."
		)
	)
	var committed_roster := contract.get(
		"_embedded_participant_peer_ids"
	) as Dictionary
	_expect(
		committed_roster == {1: true},
		"The atomic embedded contract must commit exactly its validated roster."
	)
	contract.free()


func _test_tower_session_with_rogue_runtime() -> void:
	net_manager = root.get_node_or_null("NetManager") as NetManagerStore
	_expect(net_manager != null, "NetManager autoload must exist for cross-mode coverage.")
	if net_manager == null:
		return

	net_manager.disconnect_from_game()
	net_manager.local_player_name = "CrossModeEmbeddedHost"
	net_manager.set_local_character_id(&"weishidaier", true)
	var host_error := net_manager.host_create_lan_server(TEST_PORT)
	_expect(host_error == OK, "Cross-mode smoke must create a local LAN Host.")
	if host_error != OK:
		return
	_expect(
		net_manager.set_host_game_mode(NetManagerStore.GameMode.TOWER_DEFENSE),
		"The outer fixture must own a tower-defense session."
	)
	net_manager.host_start_game()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.LOADING_GAME,
		"The outer tower session must enter its loading barrier."
	)
	net_manager.report_game_loaded()
	_expect(
		net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME,
		"The embedded Rogue runtime must start inside an active tower session."
	)
	if net_manager.connection_state != NetManagerStore.ConnectionState.IN_GAME:
		return

	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "RunState autoload must exist for cross-mode coverage.")
	if run_state == null:
		return
	run_state.begin_new_run(PlayerCharacterRegistry.WEISHIDAIER_ID, false)
	var membership_ready := run_state.reconcile_multiplayer_session_membership(
		net_manager.get_session_member_peer_ids(),
		net_manager.get_session_membership_revision()
	)
	_expect(
		membership_ready,
		"The outer session roster must be projected before creating embedded combat."
	)
	if not membership_ready:
		return

	var outer_mode_before := int(net_manager.get_current_game_mode())
	var transport_before := net_manager.multiplayer.multiplayer_peer
	var disconnected_observed := [false]
	var state_observer := func(new_state: NetManagerStore.ConnectionState) -> void:
		if new_state == NetManagerStore.ConnectionState.DISCONNECTED:
			disconnected_observed[0] = true
	net_manager.connection_state_changed.connect(state_observer)

	mp_game = MP_GAME_SCENE.instantiate() as MultiplayerGameplaySession
	_expect(mp_game != null, "MpGame scene must instantiate for cross-mode coverage.")
	if mp_game == null:
		_disconnect_state_observer(state_observer)
		return
	mp_game.embedded_runtime = true
	var local_peer_id := net_manager.get_local_peer_id()
	_expect(
		mp_game.configure_embedded_runtime_contract(
			ROGUE_COMBAT_SCENE_PATH,
			GameModeCatalog.MODE_TEST_ARENA_P3,
			PackedInt32Array([local_peer_id])
		),
		"Tower exploration must configure the Rogue child contract before add_child()."
	)
	root.add_child(mp_game)

	var runtime := mp_game.get_game_runtime()
	var adapter := (
		runtime.get_multiplayer_mode_adapter()
		if runtime != null
		else null
	)
	_expect(
		runtime is RogueCombatGame
		and adapter is RogueMultiplayerModeAdapter
		and adapter.accepts_game_mode_id(GameModeCatalog.MODE_TEST_ARENA_P3)
		and not adapter.accepts_game_mode_id(GameModeCatalog.MODE_TOWER_DEFENSE),
		(
			"The Rogue scene must validate its own runtime mode instead of accepting the "
			+ "outer tower session mode."
		)
	)
	_expect(
		int(net_manager.get_current_game_mode()) == outer_mode_before
		and outer_mode_before == GameModeCatalog.MODE_TOWER_DEFENSE,
		"Creating Rogue combat must not rewrite the outer tower session mode."
	)

	var deadline_msec := Time.get_ticks_msec() + PREPARATION_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline_msec:
		if (
			mp_game.is_runtime_preparation_complete()
			or mp_game.is_runtime_preparation_failed()
			or bool(disconnected_observed[0])
		):
			break
		await process_frame
	_expect(
		mp_game.is_runtime_preparation_complete(),
		"The cross-mode embedded Rogue runtime must complete preparation."
	)
	await process_frame
	await process_frame
	_expect(
		not bool(disconnected_observed[0])
		and net_manager.connection_state == NetManagerStore.ConnectionState.IN_GAME
		and net_manager.is_multiplayer_active()
		and net_manager.multiplayer.multiplayer_peer == transport_before,
		(
			"Embedded Rogue setup and preparation must not disconnect or replace the "
			+ "shared tower-session transport."
		)
	)
	_disconnect_state_observer(state_observer)


func _disconnect_state_observer(observer: Callable) -> void:
	if (
		net_manager != null
		and net_manager.connection_state_changed.is_connected(observer)
	):
		net_manager.connection_state_changed.disconnect(observer)


func _cleanup() -> void:
	if mp_game != null and is_instance_valid(mp_game):
		mp_game.queue_free()
		await process_frame
	mp_game = null
	if net_manager != null:
		net_manager.disconnect_from_game()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("MpGame cross-mode embedded runtime smoke test passed.")
		quit(0)
		return
	print(
		"MpGame cross-mode embedded runtime smoke test failed: %d issue(s)."
		% failures.size()
	)
	for failure in failures:
		print(" - %s" % failure)
	quit(1)
