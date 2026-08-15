extends SceneTree

const GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const WOOD_MATERIAL: PickupConfig = preload(
	"res://resources/config/materials/material_wood.tres"
)

const HOST_PEER_ID := 101
const OLD_PEER_ID := 202
const FATE_BYSTANDER_PEER_ID := 250
const FATE_BYSTANDER_RECONNECTED_PEER_ID := 260
const NEW_PEER_ID := 303
const FATE_RECONNECTED_PEER_ID := 707
const POST_FATE_RECONNECTED_PEER_ID := 909
const RESTORED_POSITION := Vector2(384.0, 256.0)
const CLIENT_LOCAL_PEER_ID := 404
const UNSEEN_OLD_PEER_ID := 505
const UNSEEN_NEW_PEER_ID := 606


class HostNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return true

	func get_local_peer_id() -> int:
		return HOST_PEER_ID


class ClientNetManagerStub:
	extends NetManagerStore

	func is_host() -> bool:
		return false

	func is_client() -> bool:
		return true

	func get_local_peer_id() -> int:
		return CLIENT_LOCAL_PEER_ID

	func get_host_peer_id() -> int:
		return HOST_PEER_ID


var failures: Array[String] = []
var reconnect_deadline_events: Array[PackedInt32Array] = []
var lobby_registration_events: Array[int] = []
var fixture_teleport_player_coordinator: MpPlayerCoordinator = null
var fixture_authoritative_teleport_broadcasts: Array[Dictionary] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_reconnect_token_contract()
	_test_late_loaded_report_cannot_revive_timed_out_reconnect()
	_test_lobby_ingress_is_bounded_and_idempotent()
	await _test_authoritative_player_state_remap()
	await _test_embedded_client_restores_unseen_participant()
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


func _test_late_loaded_report_cannot_revive_timed_out_reconnect() -> void:
	var net_manager := NetManagerStore.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.IN_GAME
	net_manager.loading_session_id = 73
	net_manager.connected_players[NEW_PEER_ID] = "Reconnect"
	net_manager.connected_player_characters[NEW_PEER_ID] = &"weishidaier"
	net_manager.confirmed_character_peers[NEW_PEER_ID] = true
	net_manager._peer_reconnect_tokens[NEW_PEER_ID] = (
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	)
	net_manager._pending_reconnect_loads[NEW_PEER_ID] = {
		"old_peer_id": OLD_PEER_ID,
		"token": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"deadline_msec": 10_000,
	}
	reconnect_deadline_events.clear()
	net_manager.player_reconnected.connect(
		_on_deadline_fixture_player_reconnected
	)

	var eligible_before_deadline := bool(
		net_manager._can_complete_pending_reconnect_load(
			NEW_PEER_ID,
			73,
			9_999
		)
	)
	net_manager._poll_reconnect_deadlines(10_000)
	var pending := (
		net_manager._pending_reconnect_loads[NEW_PEER_ID] as Dictionary
	)
	net_manager._handle_report_game_loaded(NEW_PEER_ID, 73, 10_001)
	_expect(
		eligible_before_deadline
		and bool(pending.get("timed_out", false))
		and not net_manager._can_complete_pending_reconnect_load(
			NEW_PEER_ID,
			73,
			10_001
		)
		and net_manager._pending_reconnect_loads.has(NEW_PEER_ID)
		and reconnect_deadline_events.is_empty(),
		(
			"A reconnect load report arriving after its deadline must remain rejected "
			+ "without emitting player_reconnected, while preserving the old identity "
			+ "record for disconnect cleanup."
		)
	)
	net_manager.player_reconnected.disconnect(
		_on_deadline_fixture_player_reconnected
	)
	net_manager.free()


func _on_deadline_fixture_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	_player_name: String,
	_character_id: StringName
) -> void:
	reconnect_deadline_events.append(
		PackedInt32Array([old_peer_id, new_peer_id])
	)


func _test_lobby_ingress_is_bounded_and_idempotent() -> void:
	var net_manager := NetManagerStore.new()
	net_manager.net_role = NetManagerStore.NetRole.HOST
	net_manager.connection_state = NetManagerStore.ConnectionState.HOSTING_LAN
	lobby_registration_events.clear()
	net_manager.player_joined.connect(_on_lobby_fixture_player_joined)
	var reconnect_token := "cccccccccccccccccccccccccccccccc"
	var registered := net_manager._handle_player_registration(
		OLD_PEER_ID,
		"Remote",
		"weishidaier",
		true,
		NET_CONSTANTS.PROTOCOL_VERSION,
		reconnect_token
	)
	var replayed := net_manager._handle_player_registration(
		OLD_PEER_ID,
		"MutatedName",
		"hoe_cat",
		false,
		NET_CONSTANTS.PROTOCOL_VERSION,
		"dddddddddddddddddddddddddddddddd"
	)
	var character_changed := net_manager._handle_player_character_request(
		OLD_PEER_ID,
		"hoe_cat",
		true
	)
	var no_op_character_replay := net_manager._handle_player_character_request(
		OLD_PEER_ID,
		"hoe_cat",
		true
	)

	var rate_peer_id := 707
	var admitted_at_once := 0
	for _attempt in range(int(NetManagerStore.LOBBY_COMMAND_RATE_BURST) + 1):
		if net_manager._consume_lobby_command_admission(rate_peer_id, 100.0):
			admitted_at_once += 1
	var admitted_after_refill := net_manager._consume_lobby_command_admission(
		rate_peer_id,
		101.0
	)
	_expect(
		registered
		and not replayed
		and lobby_registration_events == [OLD_PEER_ID]
		and str(net_manager.connected_players.get(OLD_PEER_ID, "")) == "Remote"
		and str(net_manager._peer_reconnect_tokens.get(OLD_PEER_ID, ""))
		== reconnect_token
		and character_changed
		and not no_op_character_replay
		and net_manager.get_player_character_id(OLD_PEER_ID)
		== PlayerCharacterRegistry.HOE_CAT_ID,
		(
			"A connected lobby identity must register once, retain its reconnect token, "
			+ "and broadcast character state only when that state actually changes."
		)
	)
	_expect(
		admitted_at_once == int(NetManagerStore.LOBBY_COMMAND_RATE_BURST)
		and admitted_after_refill,
		(
			"The shared lobby command bucket must cap one peer's immediate reliable "
			+ "ingress while refilling for legitimate later input."
		)
	)
	net_manager.player_joined.disconnect(_on_lobby_fixture_player_joined)
	net_manager.free()


func _on_lobby_fixture_player_joined(peer_id: int, _player_name: String) -> void:
	lobby_registration_events.append(peer_id)


func _test_authoritative_player_state_remap() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier")
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		HOST_PEER_ID,
		{
			HOST_PEER_ID: "Host",
			OLD_PEER_ID: "Reconnect",
			FATE_BYSTANDER_PEER_ID: "Bystander",
		},
		{
			HOST_PEER_ID: &"weishidaier",
			OLD_PEER_ID: &"weishidaier",
			FATE_BYSTANDER_PEER_ID: &"weishidaier",
		}
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
	# Route and embedded-combat avatars share the global RunState signal. Keep a
	# route-like stale listener alive across the combat remap to prove that a
	# read-side cache refresh cannot recreate the removed old-peer ledger.
	var stale_route_player := PlayerCharacterRegistry.instantiate_character(
		PlayerCharacterRegistry.WEISHIDAIER_ID
	) as Player
	root.add_child(stale_route_player)
	await process_frame
	stale_route_player.configure_multiplayer_control(
		OLD_PEER_ID,
		false,
		"StaleRouteAvatar"
	)
	stale_route_player.set_process(false)
	stale_route_player.set_physics_process(false)

	var mp_game := MP_GAME_SCRIPT.new()
	var net_stub := HostNetManagerStub.new()
	mp_game.game = game
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	_bind_multiplayer_runtime(mp_game, game)
	mp_game.player_coordinator.bind_player_action_dependencies(
		net_stub,
		Callable(mp_game, "_get_net_time"),
		Callable(mp_game, "_is_embedded_participant_suspended")
	)
	fixture_teleport_player_coordinator = mp_game.player_coordinator
	fixture_authoritative_teleport_broadcasts.clear()
	mp_game.player_coordinator.authoritative_teleport_broadcast_requested.connect(
		_on_fixture_authoritative_teleport_broadcast_requested
	)
	game.multiplayer_gateway.player_teleport_requested.connect(
		_on_fixture_player_teleport_requested
	)
	var admitted_actions_at_once := 0
	for _attempt in range(int(MpPlayerCoordinator.PLAYER_ACTION_INGRESS_RATE_BURST) + 1):
		if mp_game._consume_remote_player_action_admission(
			OLD_PEER_ID,
			200.0
		):
			admitted_actions_at_once += 1
	var admitted_action_after_refill := (
		mp_game._consume_remote_player_action_admission(
			OLD_PEER_ID,
			201.0
		)
	)
	_expect(
		admitted_actions_at_once
		== int(MpPlayerCoordinator.PLAYER_ACTION_INGRESS_RATE_BURST)
		and admitted_action_after_refill,
		(
			"Reliable player actions must share a bounded per-peer ingress budget "
			+ "without blocking legitimate input after refill."
		)
	)
	var expected_revive_at := float(mp_game.call("_get_net_time")) + 5.0
	mp_game.player_coordinator._dead_player_revive_times[OLD_PEER_ID] = (
		expected_revive_at
	)
	mp_game.player_coordinator._dead_player_revive_last_seconds[OLD_PEER_ID] = 5
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
			float(
				mp_game.player_coordinator.capture_reconnect_life_state(
					NEW_PEER_ID
				).get("revive_at", -1.0)
			),
			expected_revive_at
		),
		(
			"Reconnect must restore spawn, production, research, and pending respawn "
			+ "state. slot=%s production=%s deaths=%s research=%s revive=%s expected=%s"
		)
		% [
			game.multiplayer_spawn_slot_indices.get(NEW_PEER_ID),
			game.production_coordinator.is_personal_output_peer_available(
				NEW_PEER_ID
			),
			game.player_wave_death_counts.get(NEW_PEER_ID),
			game.research_coordinator.player_technology_levels.get(NEW_PEER_ID),
			mp_game.player_coordinator.capture_reconnect_life_state(
				NEW_PEER_ID
			).get("revive_at"),
			expected_revive_at,
		]
	)
	var bystander_before_boundary := game.get_player_for_peer(
		FATE_BYSTANDER_PEER_ID
	) as Player
	var stale_bystander_position := Vector2(812.0, 346.0)
	bystander_before_boundary.global_position = stale_bystander_position
	mp_game.call("_on_net_player_left", FATE_BYSTANDER_PEER_ID)
	var pre_boundary_reconnect_state := (
		mp_game._disconnected_player_reconnect_states.get(
			FATE_BYSTANDER_PEER_ID,
			{}
		) as Dictionary
	)
	_expect(
		not bool(
			pre_boundary_reconnect_state.get(
				"tower_world_spawn_restore_pending",
				false
			)
		),
		"A disconnect before Rogue must not claim the return boundary early."
	)
	mp_game.call("_mark_disconnected_players_for_rogue_boundary_full_health")
	_expect(
		bool(
			pre_boundary_reconnect_state.get(
				"tower_world_spawn_restore_pending",
				false
			)
		),
		"The Rogue full-health boundary must mark earlier disconnects for world return."
	)
	mp_game.call(
		"_on_net_player_reconnected",
		FATE_BYSTANDER_PEER_ID,
		FATE_BYSTANDER_RECONNECTED_PEER_ID,
		"BoundaryReconnect",
		&"weishidaier"
	)
	var bystander := game.get_player_for_peer(
		FATE_BYSTANDER_RECONNECTED_PEER_ID
	) as Player
	var bystander_world_position: Variant = (
		game.tower_multiplayer_mode_adapter
		.get_fixed_multiplayer_respawn_position(
			FATE_BYSTANDER_RECONNECTED_PEER_ID
		)
	)
	_expect(
		bystander != null
		and bystander_world_position is Vector2
		and bystander.global_position == (bystander_world_position as Vector2)
		and bystander.global_position != stale_bystander_position
		and game.multiplayer_spawn_slot_indices.get(
			FATE_BYSTANDER_RECONNECTED_PEER_ID
		) == 2,
		"A pre-Rogue disconnect must return to its stable PlayerSpawn slot after the boundary."
	)
	game.campaign_coordinator.wave_state = CombatFlowState.State.FATE_INTERLUDE
	game.fate_flow_coordinator.teleport_authoritative_players_to_room()
	var stale_fate_position := Vector2(917.0, 563.0)
	restored.global_position = stale_fate_position
	restored.velocity = Vector2(21.0, -7.0)
	mp_game.call("_on_net_player_left", NEW_PEER_ID)
	var fate_reconnect_state := (
		mp_game._disconnected_player_reconnect_states.get(
			NEW_PEER_ID,
			{}
		) as Dictionary
	)
	_expect(
		bool(
			fate_reconnect_state.get(
				"tower_world_spawn_restore_pending",
				false
			)
		),
		"A Fate-room disconnect must retain a pending Tower world return."
	)
	for _frame in 3:
		await process_frame
		await physics_frame
	mp_game.call(
		"_on_net_player_reconnected",
		NEW_PEER_ID,
		FATE_RECONNECTED_PEER_ID,
		"FateReconnect",
		&"weishidaier"
	)
	var fate_restored := game.get_player_for_peer(
		FATE_RECONNECTED_PEER_ID
	) as Player
	var fate_room_position := (
		game.xiaocong_fate_interlude.get_player_spawn_position(1)
	)
	_expect(
		fate_restored != null
		and fate_room_position != stale_fate_position
		and fate_restored.global_position == fate_room_position
		and fate_restored.velocity == Vector2.ZERO
		and fate_restored.combat_actions_locked
		and not fate_restored.controls_locked
		and game.multiplayer_spawn_slot_indices.get(FATE_RECONNECTED_PEER_ID) == 1
		and bystander != null
		and bystander.global_position
		== game.xiaocong_fate_interlude.get_player_spawn_position(2)
		and bystander.global_position != fate_restored.global_position,
		(
			"Fate reconnect must supersede the stale snapshot with its stable room "
			+ "slot, without colliding after the new peer ID changes sort order."
		)
	)
	_expect(
		mp_game.player_coordinator.get_accepted_player_position(
			FATE_RECONNECTED_PEER_ID
		) == fate_room_position,
		"Fate reconnect must replace the Host accepted pose before runtime repair."
	)
	mp_game.call("_on_net_player_left", FATE_RECONNECTED_PEER_ID)
	game.fate_flow_coordinator.restore_authoritative_players_from_room()
	game.campaign_coordinator.wave_state = CombatFlowState.State.INTERMISSION
	mp_game.call(
		"_on_net_player_reconnected",
		FATE_RECONNECTED_PEER_ID,
		POST_FATE_RECONNECTED_PEER_ID,
		"PostFateReconnect",
		&"weishidaier"
	)
	var post_fate_restored := game.get_player_for_peer(
		POST_FATE_RECONNECTED_PEER_ID
	) as Player
	var post_fate_world_position: Variant = (
		game.tower_multiplayer_mode_adapter
		.get_fixed_multiplayer_respawn_position(POST_FATE_RECONNECTED_PEER_ID)
	)
	var final_teleport_broadcast := (
		fixture_authoritative_teleport_broadcasts.back() as Dictionary
		if not fixture_authoritative_teleport_broadcasts.is_empty()
		else {}
	)
	_expect(
		post_fate_restored != null
		and post_fate_world_position is Vector2
		and post_fate_restored.global_position
		== (post_fate_world_position as Vector2)
		and post_fate_restored.velocity == Vector2.ZERO
		and not post_fate_restored.combat_actions_locked
		and mp_game.player_coordinator.get_accepted_player_position(
			POST_FATE_RECONNECTED_PEER_ID
		) == post_fate_world_position
		and int(final_teleport_broadcast.get("peer_id", 0))
		== POST_FATE_RECONNECTED_PEER_ID
		and final_teleport_broadcast.get("target_position")
		== post_fate_world_position,
		(
			"A player disconnected through Fate departure must be authoritatively "
			+ "returned to PlayerSpawn instead of restoring the stale room pose."
		)
	)
	fixture_teleport_player_coordinator = null
	mp_game.free()
	net_stub.free()
	stale_route_player.queue_free()
	current_scene = null
	game.queue_free()
	for _frame in 4:
		await process_frame
		await physics_frame


func _test_embedded_client_restores_unseen_participant() -> void:
	var run_state := root.get_node("RunState") as RunStateStore
	run_state.begin_new_run(&"weishidaier", false)
	var game := GAME_SCENE.instantiate() as TowerDefenseGame
	_disable_tower_fixture_background_loads(game)
	game.auto_start_waves = false
	game.configure_multiplayer(
		CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		CLIENT_LOCAL_PEER_ID,
		{
			HOST_PEER_ID: "Host",
			CLIENT_LOCAL_PEER_ID: "ClientA",
		},
		{
			HOST_PEER_ID: &"weishidaier",
			CLIENT_LOCAL_PEER_ID: &"weishidaier",
		}
	)
	root.add_child(game)
	current_scene = game
	for _frame in 4:
		await process_frame
		await physics_frame

	var mp_game := MP_GAME_SCRIPT.new()
	mp_game.embedded_runtime = true
	_expect(
		mp_game.configure_embedded_participant_roster(PackedInt32Array([
			HOST_PEER_ID,
			CLIENT_LOCAL_PEER_ID,
			UNSEEN_OLD_PEER_ID,
		])),
		"Client placeholder fixture must freeze the original combat roster."
	)
	var net_stub := ClientNetManagerStub.new()
	mp_game.game = game
	mp_game.run_state = run_state
	mp_game.net_manager = net_stub
	_bind_multiplayer_runtime(mp_game, game)
	mp_game.call(
		"_on_net_player_reconnected",
		UNSEEN_OLD_PEER_ID,
		UNSEEN_NEW_PEER_ID,
		"ClientB",
		&"weishidaier"
	)
	var restored := game.get_player_for_peer(UNSEEN_NEW_PEER_ID) as Player
	_expect(
		restored != null
		and not mp_game._embedded_participant_peer_ids.has(UNSEEN_OLD_PEER_ID)
		and mp_game._embedded_participant_peer_ids.has(UNSEEN_NEW_PEER_ID)
		and run_state.has_multiplayer_peer_state(UNSEEN_NEW_PEER_ID),
		(
			"A rejoined client with no old local capture must create a remote combat "
			+ "placeholder and remap the frozen roster."
		)
	)
	if restored != null:
		var authoritative_state := SnapshotManager.PlayerState.new()
		authoritative_state.peer_id = UNSEEN_NEW_PEER_ID
		authoritative_state.character_id = &"weishidaier"
		authoritative_state.position = Vector2(512.0, 288.0)
		authoritative_state.velocity = Vector2(10.0, -2.0)
		authoritative_state.current_health = 17
		authoritative_state.max_health = 120
		authoritative_state.health_revision = 4
		authoritative_state.current_xirang = 345
		authoritative_state.ammo_capacity = 12
		authoritative_state.current_ammo = 7
		restored.apply_multiplayer_snapshot_motion(
			authoritative_state.position,
			authoritative_state.velocity,
			authoritative_state.facing,
			authoritative_state.anim_state
		)
		mp_game.player_coordinator.call(
			"_apply_realtime_snapshot",
			restored,
			authoritative_state
		)
		_expect(
			restored.global_position == authoritative_state.position
			and restored.current_health == 17
			and restored.max_health == 120
			and restored.current_xirang == 345
			and restored.current_ammo == 7,
			(
				"The next Host player keyframe must fully converge the placeholder; "
				+ "actual pos=%s health=%d/%d xirang=%d ammo=%d."
			)
			% [
				restored.global_position,
				restored.current_health,
				restored.max_health,
				restored.current_xirang,
				restored.current_ammo,
			]
		)

	var authoritative_run_state := RunStateStore.new()
	authoritative_run_state.begin_new_run(&"weishidaier", false)
	authoritative_run_state.ensure_multiplayer_peer_state(UNSEEN_NEW_PEER_ID)
	_expect(
		authoritative_run_state.try_add_item_count_for_peer(
			UNSEEN_NEW_PEER_ID,
			WOOD_MATERIAL,
			2
		),
		"Authoritative inventory fixture must create a new-id snapshot."
	)
	var inventory_snapshot := (
		authoritative_run_state.export_inventory_snapshot_for_peer(
			UNSEEN_NEW_PEER_ID
		)
	)
	mp_game.call(
		"net_inventory_snapshot",
		UNSEEN_NEW_PEER_ID,
		inventory_snapshot,
		true
	)
	_expect(
		run_state.get_inventory_item_total_for_peer(
			UNSEEN_NEW_PEER_ID,
			WOOD_MATERIAL
		) == 2,
		"The reliable Host inventory snapshot must converge the placeholder RunState."
	)
	authoritative_run_state.free()
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


func _disable_tower_fixture_background_loads(game: TowerDefenseGame) -> void:
	var fate_coordinator := game.get_node_or_null("FateCoordinator") as FateCoordinator
	if fate_coordinator != null:
		fate_coordinator.elite_enemy_config_loads_requested = true


func _bind_multiplayer_runtime(
	mp_game,
	game: CombatRuntimeBase
) -> void:
	var session_coordinator := MpSessionCoordinator.new()
	session_coordinator.name = "SessionCoordinator"
	mp_game.add_child(session_coordinator)
	mp_game.session_coordinator = session_coordinator
	session_coordinator.bind_runtime(game)
	var player_coordinator := MpPlayerCoordinator.new()
	player_coordinator.name = "PlayerCoordinator"
	game.add_child(player_coordinator)
	mp_game.player_coordinator = player_coordinator
	player_coordinator.bind_runtime(game)
	var enemy_coordinator := MpEnemyCoordinator.new()
	enemy_coordinator.name = "EnemyCoordinator"
	mp_game.add_child(enemy_coordinator)
	mp_game.enemy_coordinator = enemy_coordinator
	var projectile_coordinator := MpProjectileCoordinator.new()
	projectile_coordinator.name = "ProjectileCoordinator"
	mp_game.add_child(projectile_coordinator)
	mp_game.projectile_coordinator = projectile_coordinator
	var tower_world_coordinator := MpTowerWorldCoordinator.new()
	tower_world_coordinator.name = "TowerWorldCoordinator"
	mp_game.add_child(tower_world_coordinator)
	mp_game.tower_world_coordinator = tower_world_coordinator
	var tower_economy_coordinator := MpTowerEconomyCoordinator.new()
	tower_economy_coordinator.name = "TowerEconomyCoordinator"
	mp_game.add_child(tower_economy_coordinator)
	mp_game.tower_economy_coordinator = tower_economy_coordinator
	var tower_fate_coordinator := MpTowerFateCoordinator.new()
	tower_fate_coordinator.name = "TowerFateCoordinator"
	mp_game.add_child(tower_fate_coordinator)
	mp_game.tower_fate_coordinator = tower_fate_coordinator
	var collectible_presentation_coordinator := (
		MpCollectiblePresentationCoordinator.new()
	)
	collectible_presentation_coordinator.name = "CollectiblePresentationCoordinator"
	mp_game.add_child(collectible_presentation_coordinator)
	mp_game.collectible_presentation_coordinator = (
		collectible_presentation_coordinator
	)
	var network_diagnostics_coordinator := MpNetworkDiagnosticsCoordinator.new()
	network_diagnostics_coordinator.name = "NetworkDiagnosticsCoordinator"
	mp_game.add_child(network_diagnostics_coordinator)
	mp_game.network_diagnostics_coordinator = network_diagnostics_coordinator
	var gameplay_gateway := game.get_multiplayer_gameplay_gateway()
	var mode_adapter := game.get_multiplayer_mode_adapter()
	mp_game._gameplay_gateway = gameplay_gateway
	mp_game._mode_adapter = mode_adapter
	mp_game.tower_mode_adapter = (
		mode_adapter as TowerDefenseMultiplayerModeAdapter
	)
	player_coordinator.bind_life_dependencies(
		mp_game.net_manager,
		mode_adapter,
		projectile_coordinator,
		Callable(mp_game, "_get_net_time"),
		Callable(mp_game, "_cancel_player_life_tango_for_revive_schedule"),
		Callable(mp_game, "_cancel_player_life_actions_for_revive"),
		Callable(mp_game, "_clear_player_life_tiyi_lifecycle_state"),
		Callable(mp_game, "_get_player_life_revive_anchor_position"),
		Callable(mp_game, "_commit_player_life_revive_position")
	)
	var transactions_coordinator := MpTransactionsCoordinator.new()
	transactions_coordinator.name = "TransactionsCoordinator"
	mp_game.add_child(transactions_coordinator)
	mp_game.transactions_coordinator = transactions_coordinator
	transactions_coordinator.bind_session(
		mp_game,
		game,
		mode_adapter,
		mp_game.net_manager,
		mp_game.run_state,
		mp_game._suspended_embedded_participant_peer_ids
	)
	var merchant_transactions_coordinator := (
		MpMerchantTransactionsCoordinator.new()
	)
	merchant_transactions_coordinator.name = "MerchantTransactionsCoordinator"
	mp_game.add_child(merchant_transactions_coordinator)
	mp_game.merchant_transactions_coordinator = merchant_transactions_coordinator
	merchant_transactions_coordinator.bind_runtime(
		game,
		mode_adapter,
		mp_game.run_state,
		mp_game.net_manager,
		session_coordinator.get_net_time_origin()
	)
	var rogue_route_bridge := MpRogueRoute.new()
	rogue_route_bridge.name = "TowerRogueRouteBridge"
	rogue_route_bridge.auto_bind_scene_runtime = false
	mp_game.add_child(rogue_route_bridge)
	mp_game.tower_rogue_route_bridge = rogue_route_bridge
	if gameplay_gateway != null:
		gameplay_gateway.attach_multiplayer_session(mp_game)
	if mode_adapter != null:
		mode_adapter.attach_multiplayer_session(mp_game)


func _on_fixture_player_teleport_requested(
	peer_id: int,
	target_position: Vector2
) -> void:
	_expect(
		fixture_teleport_player_coordinator != null
		and fixture_teleport_player_coordinator.handle_authoritative_player_teleport_request(
			peer_id,
			target_position
		),
		"Reconnect fixture failed to commit the authoritative Fate teleport."
	)


func _on_fixture_authoritative_teleport_broadcast_requested(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int
) -> void:
	fixture_authoritative_teleport_broadcasts.append({
		"peer_id": peer_id,
		"target_position": target_position,
		"snapshot_sequence_cutoff": snapshot_sequence_cutoff,
	})


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
