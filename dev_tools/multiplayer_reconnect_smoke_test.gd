extends SceneTree

const GAME_SCENE := preload("res://scene/game_tower_defense.tscn")
const WOOD_MATERIAL: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)

const HOST_PEER_ID := 101
const OLD_PEER_ID := 202
const NEW_PEER_ID := 303
const RESTORED_POSITION := Vector2(384.0, 256.0)


class HostNetManagerStub:
	extends Node

	func is_host() -> bool:
		return true


var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_reconnect_token_contract()
	await _test_authoritative_player_state_remap()
	await _cleanup_root()
	if failures.is_empty():
		print("MULTIPLAYER_RECONNECT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_reconnect_token_contract() -> void:
	var net_manager := NetManagerStore.new()
	root.add_child(net_manager)
	await process_frame
	_expect(
		net_manager.local_reconnect_token.length()
		== NetManagerStore.RECONNECT_TOKEN_HEX_LENGTH
		and net_manager.call(
			"_is_valid_reconnect_token",
			net_manager.local_reconnect_token
		),
		"NetManager must generate a private 128-bit reconnect identity."
	)
	_expect(
		not net_manager.set_local_reconnect_token("short")
		and net_manager.set_local_reconnect_token(
			"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
		),
		"Reconnect identities must reject malformed values and accept 32 lowercase hex characters."
	)
	net_manager.queue_free()
	await process_frame


func _test_authoritative_player_state_remap() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as GameTowerDefense
	game.auto_start_waves = false
	game.configure_multiplayer(
		GameRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		HOST_PEER_ID,
		{HOST_PEER_ID: "Host", OLD_PEER_ID: "Reconnect"},
		{HOST_PEER_ID: &"weishidaier", OLD_PEER_ID: &"weishidaier"}
	)
	root.add_child(game)
	current_scene = game
	for _frame in 4:
		await process_frame
		await physics_frame
	var old_player := game.get_player_for_peer(OLD_PEER_ID) as Player
	_expect(old_player != null, "Reconnect fixture must create the original remote player.")
	if old_player == null:
		current_scene = null
		game.queue_free()
		return
	old_player.global_position = RESTORED_POSITION
	old_player.grant_xirang_reward(4321)
	old_player.set_multiplayer_health_state(old_player.max_health - 11, false)
	var expected_xirang := old_player.current_xirang
	var expected_health := old_player.current_health
	game.player_wave_death_counts[OLD_PEER_ID] = 2
	game.research_coordinator.player_technology_levels[OLD_PEER_ID] = 2
	var expected_wood := run_state.get_inventory_item_total_for_peer(
		OLD_PEER_ID,
		WOOD_MATERIAL
	) + 7
	_expect(
		run_state.try_add_item_count_for_peer(OLD_PEER_ID, WOOD_MATERIAL, 7),
		"Reconnect fixture must seed the authoritative peer inventory."
	)

	var mp_game := preload("res://scene/multiplayer/mp_game.gd").new()
	var net_stub := HostNetManagerStub.new()
	mp_game.game = game
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	var expected_revive_at := float(mp_game.call("_get_net_time")) + 5.0
	mp_game._dead_player_revive_times[OLD_PEER_ID] = expected_revive_at
	mp_game._dead_player_revive_last_seconds[OLD_PEER_ID] = 5
	mp_game.call("_on_net_player_left", OLD_PEER_ID)
	for _frame in 3:
		await process_frame
		await physics_frame
	_expect(
		game.get_player_for_peer(OLD_PEER_ID) == null,
		"Disconnect must remove the obsolete peer runtime before reconnect."
	)
	mp_game.call(
		"_on_net_player_reconnected",
		OLD_PEER_ID,
		NEW_PEER_ID,
		"Reconnect",
		&"weishidaier"
	)
	var restored := game.get_player_for_peer(NEW_PEER_ID) as Player
	_expect(
		restored != null
		and restored.global_position == RESTORED_POSITION
		and restored.current_xirang == expected_xirang
		and restored.current_health == expected_health,
		"Reconnect must restore position, Xirang, and life state under the new ENet peer id."
	)
	_expect(
		not run_state.has_multiplayer_peer_state(OLD_PEER_ID)
		and run_state.has_multiplayer_peer_state(NEW_PEER_ID)
		and run_state.get_inventory_item_total_for_peer(
			NEW_PEER_ID,
			WOOD_MATERIAL
		) == expected_wood,
		"Reconnect must atomically remap the authoritative personal inventory."
	)
	_expect(
		game.multiplayer_spawn_slot_indices.has(NEW_PEER_ID)
		and game.production_coordinator.is_personal_output_peer_available(
			NEW_PEER_ID
		)
		and int(game.player_wave_death_counts.get(NEW_PEER_ID, 0)) == 2
		and int(
			game.research_coordinator.player_technology_levels.get(
				NEW_PEER_ID,
				-1
			)
		) == 2
		and is_equal_approx(
			float(mp_game._dead_player_revive_times.get(NEW_PEER_ID, -1.0)),
			expected_revive_at
		),
		"Reconnect must restore spawn, production, research, and pending respawn state."
	)
	mp_game.free()
	net_stub.free()
	current_scene = null
	game.queue_free()
	for _frame in 4:
		await process_frame
		await physics_frame


func _cleanup_root() -> void:
	current_scene = null
	for _frame in 4:
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
