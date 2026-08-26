extends SceneTree

const MAIN_MP_GAME_PATH := "res://scene/multiplayer/mp_game.gd"
const MAIN_PROJECTILE_COORDINATOR_PATH := (
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MAIN_PLAYER_COORDINATOR_PATH := (
	"res://scene/multiplayer/player/mp_player_coordinator.gd"
)
const RELAY_MP_GAME_PATH := "res://relay_servers/relay_godot_project/relay_mp_game_stub.gd"
const MAIN_ROGUE_ROUTE_PATH := "res://scene/multiplayer/mp_rogue_route.gd"
const RELAY_ROGUE_ROUTE_PATH := (
	"res://relay_servers/relay_godot_project/relay_rogue_route_stub.gd"
)
const MAIN_NET_MANAGER_PATH := "res://scene/multiplayer/net_manager.gd"
const RELAY_NET_MANAGER_PATH := "res://relay_servers/relay_godot_project/relay_net_manager_stub.gd"
const RELAY_SERVER_PATH := "res://relay_servers/relay_godot_project/relay_server.gd"
const GAME_RELAY_PEER_PATH := (
	"res://scene/multiplayer/transport/authenticated_relay_multiplayer_peer.gd"
)
const RELAY_PEER_PATH := (
	"res://relay_servers/relay_godot_project/authenticated_relay_multiplayer_peer.gd"
)
const RELAY_PROJECT_PATH := "res://relay_servers/relay_godot_project/project.godot"
const STANDARD_GAME_PATH := "res://scene/game_modes/standard/standard_game.gd"
const WAVE_RUNTIME_PATH := "res://scene/combat/runtime/wave_combat_runtime_base.gd"
const ROGUE_COMBAT_GAME_PATH := (
	"res://scene/game_modes/rogue/combat/rogue_combat_game.gd"
)
const TOWER_DEFENSE_PLAYER_ROSTER_PATH := (
	"res://scene/game_modes/tower_defense/player/tower_defense_player_roster_coordinator.gd"
)
const TOWER_WORLD_COORDINATOR_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/world/mp_tower_world_coordinator.gd"
)
const TOWER_FATE_COORDINATOR_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/fate/mp_tower_fate_coordinator.gd"
)
const TOWER_ECONOMY_COORDINATOR_PATH := (
	"res://scene/game_modes/tower_defense/multiplayer/economy/mp_tower_economy_coordinator.gd"
)
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
var NetManagerScript: GDScript = null

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var loaded_net_manager_script: Resource = load(MAIN_NET_MANAGER_PATH)
	if not (loaded_net_manager_script is GDScript):
		push_error("Main NetManager failed to load; RPC parity cannot be trusted.")
		quit(1)
		return
	NetManagerScript = loaded_net_manager_script as GDScript
	var main_rpcs := _extract_rpc_surface(MAIN_MP_GAME_PATH)
	var relay_rpcs := _extract_rpc_surface(RELAY_MP_GAME_PATH)
	_compare_rpc_surfaces("MpGame", main_rpcs, relay_rpcs)
	for required_method in [
		"net_tango_electric_surge_requested",
		"net_tango_electric_surge_started",
		"net_tango_electric_surge_finished",
		"net_tango_charge_started_requested",
		"net_tango_charge_released_requested",
		"net_tango_charge_cancelled_requested",
		"net_tango_charge_started",
		"net_tango_charge_released",
		"net_tango_charge_cancelled",
		"net_tango_charge_rejected",
		"net_tiyi_high_noon_requested",
		"net_tiyi_high_noon_started",
		"net_tiyi_high_noon_targets",
		"net_tiyi_high_noon_finished",
		"net_tiyi_high_noon_cancelled",
		"net_tiyi_sniper_hit_confirmed",
		"net_luoxi_collectible_refresh_requested",
		"net_luoxi_collectible_refresh_confirmed",
		"net_enemy_escaped",
		"net_base_health_changed",
		"net_player_healed",
		"net_player_full_health_restored",
		"net_plant_placement_requested",
		"net_nearest_plant_destruction_requested",
		"net_inventory_plant_placement_requested",
		"net_plant_spawned",
		"net_plant_placement_rejected",
		"net_plant_health_changed",
		"net_plant_damage_status_changed",
		"net_plant_removed",
		"net_plant_projectile_visual",
		"net_bamboo_mortar_visual_batch",
		"net_hydrangea_rain_visual",
		"net_corn_machine_gun_burst_batch",
		"net_tango_laser_volley",
		"net_linglan_skill1_ring_batch",
		"net_enemy_lightning_chain",
		"net_runtime_state_requested",
		"net_terrain_snapshot_requested",
		"net_terrain_snapshot_chunk",
		"net_terrain_delta",
		"net_tower_defense_wave_progress_changed",
		"net_xiaocong_interaction_requested",
		"net_xiaocong_fate_vote_requested",
		"net_xiaocong_collectible_choice_requested",
		"net_xiaocong_fate_state_changed",
		"net_test_arena_manual_night_changed",
		"net_inventory_item_use_requested",
		"net_inventory_item_discard_requested",
		"net_inventory_item_used",
		"net_inventory_item_discarded",
		"net_inventory_snapshot",
		"net_simple_crafting_requested",
		"net_simple_crafting_result",
		"net_pickup_collected",
		"net_luoxi_collectible_offer_requested",
		"net_luoxi_collectible_offer_state",
		"net_luoxi_collectible_choice_requested",
		"net_luoxi_collectible_confirmed",
		"net_luoxi_special_game_start_requested",
		"net_luoxi_special_game_card_reveal_requested",
		"net_luoxi_special_game_finish_requested",
		"net_luoxi_special_game_started",
		"net_luoxi_special_game_card_revealed",
		"net_luoxi_special_game_finished",
		"net_warehouse_command_requested",
		"net_warehouse_snapshot_requested",
		"net_warehouse_command_result",
		"net_warehouse_storage_snapshot_batch",
		"net_production_command_requested",
		"net_production_snapshot_requested",
		"net_production_command_result",
		"net_production_state_batch",
		"net_research_command_requested",
		"net_research_command_result",
		"net_research_state_updated",
		"net_tower_rogue_exploration_snapshot",
		"net_request_route_full_snapshot",
		"net_route_full_snapshot",
		"net_route_move_delta",
		"net_route_briefing_state",
		"net_route_briefing_cover_ready",
		"net_route_encounter_intro_ack",
		"net_route_encounter_vote",
		"net_route_encounter_result_ack",
		"net_route_encounter_snapshot",
		"net_shop_purchase_request",
		"net_shop_sell_request",
		"net_shop_exit_ack",
		"net_shop_snapshot",
		"net_route_avatar_input",
		"net_route_avatar_snapshot",
		"net_route_avatar_corrected",
	]:
		_expect(main_rpcs.has(required_method), "Gameplay RPC %s must be registered." % required_method)
	# v75 的玩家结果全部共享末尾 participant + session；完整 surface 比较锁定
	# 两者顺序，这里再显式锁定 17 类覆盖面。
	var session_bound_peer_result_methods := PackedStringArray([
		"net_warehouse_command_result",
		"net_inventory_snapshot",
		"net_research_state_updated",
		"net_pickup_collected",
		"net_upgrade_confirmed",
		"net_inventory_item_used",
		"net_inventory_item_discarded",
		"net_simple_crafting_result",
		"net_skill1_purchase_confirmed",
		"net_luoxi_collectible_offer_state",
		"net_luoxi_collectible_confirmed",
		"net_luoxi_collectible_refresh_confirmed",
		"net_luoxi_special_game_started",
		"net_luoxi_special_game_card_revealed",
		"net_luoxi_special_game_finished",
		"net_cheat_xirang_confirmed",
		"net_debug_collectible_granted",
	])
	for result_method in session_bound_peer_result_methods:
		_expect_rpc_signature_contains(
			main_rpcs,
			result_method,
			"participant_incarnation:int=0"
		)
		_expect_rpc_signature_contains(
			main_rpcs,
			result_method,
			"session_incarnation:int=0"
		)
		_expect(
			String(main_rpcs[result_method]).contains(
				"participant_incarnation:int=0,session_incarnation:int=0"
			),
			"%s 必须按 participant、session 的固定顺序追加身份 trailer。"
			% result_method
		)
	_expect(
		session_bound_peer_result_methods.size() == 17,
		"v75 必须让全部17类 peer-bearing CH6 结果携带成员与会话世代。"
	)
	if main_rpcs.has("net_tiyi_high_noon_requested"):
		_expect(
			String(main_rpcs["net_tiyi_high_noon_requested"]).contains("activation_id:int"),
			"High-noon requests must carry their monotonic activation id."
		)
	for tango_request_method in [
		"net_tango_charge_started_requested",
		"net_tango_charge_released_requested",
	]:
		_expect_rpc_signature_contains(main_rpcs, tango_request_method, "direction:Vector2")
		_expect_rpc_signature_contains(main_rpcs, tango_request_method, "request_id:int")
		_expect(
			not String(main_rpcs.get(tango_request_method, "")).contains("charge_ratio")
			and not String(main_rpcs.get(tango_request_method, "")).contains("damage"),
			"Tango requests must not accept client-authored charge ratio or damage."
		)
	_expect_rpc_signature_contains(
		main_rpcs,
		"net_tango_charge_cancelled_requested",
		"request_id:int"
	)
	_expect(
		not String(main_rpcs.get("net_tango_charge_cancelled_requested", "")).contains(
			"direction"
		)
		and not String(main_rpcs.get("net_tango_charge_cancelled_requested", "")).contains(
			"charge_ratio"
		)
		and not String(main_rpcs.get("net_tango_charge_cancelled_requested", "")).contains(
			"damage"
		),
		"Tango cancellation requests may carry only their active request id."
	)
	_expect_rpc_signature_contains(
		main_rpcs,
		"net_tango_electric_surge_requested",
		"request_id:int"
	)
	_expect_rpc_signature_contains(
		main_rpcs,
		"net_nearest_plant_destruction_requested",
		"request_id:int"
	)
	_expect_rpc_signature_contains(
		main_rpcs,
		"net_nearest_plant_destruction_requested",
		"target_net_id:int"
	)
	_expect(
		not String(main_rpcs.get("net_tango_electric_surge_requested", "")).contains(
			"origin"
		)
		and not String(main_rpcs.get("net_tango_electric_surge_requested", "")).contains(
			"duration"
		),
		"Electric Surge requests must not accept client-authored origin or duration."
	)
	for field_name in [
		"peer_id:int",
		"activation_id:int",
		"origin:Vector2",
		"remaining_seconds_at_send:float",
		"host_sent_at:float",
		"buff_active:bool",
		"request_id:int",
		"auto_fire_charge_sequence:int",
	]:
		_expect_rpc_signature_contains(
			main_rpcs,
			"net_tango_electric_surge_started",
			field_name
		)
	_test_tango_charge_authority_source()
	_test_tango_electric_surge_authority_source()
	_expect(
		not main_rpcs.has("net_wave_started"),
		"Legacy wave-index RPC must stay removed; flow step_id is the sole lifecycle source."
	)
	_test_gameplay_v17_transaction_contract(main_rpcs)
	_test_gameplay_channel_contract(main_rpcs)
	_expect_rpc_signature_contains(
		main_rpcs,
		"net_route_full_snapshot",
		"progression_ledger:Dictionary"
	)
	_expect_rpc_signature_contains(
		main_rpcs,
		"net_player_damage_applied",
		"confirmed_status_mask:int=0"
	)

	var main_rogue_route_rpcs := _extract_rpc_surface(MAIN_ROGUE_ROUTE_PATH)
	var relay_rogue_route_rpcs := _extract_rpc_surface(RELAY_ROGUE_ROUTE_PATH)
	_compare_rpc_surfaces(
		"MpRogueRoute",
		main_rogue_route_rpcs,
		relay_rogue_route_rpcs
	)
	for required_method in [
		"net_request_route_full_snapshot",
		"net_route_upgrade_requested",
		"net_route_full_snapshot",
		"net_route_move_delta",
		"net_route_briefing_state",
		"net_route_briefing_cover_ready",
		"net_route_encounter_intro_ack",
		"net_route_encounter_vote",
		"net_route_encounter_result_ack",
		"net_route_encounter_snapshot",
		"net_shop_purchase_request",
		"net_shop_sell_request",
		"net_shop_exit_ack",
		"net_shop_snapshot",
		"net_route_avatar_input",
		"net_route_avatar_snapshot",
		"net_route_avatar_corrected",
	]:
		_expect(
			main_rogue_route_rpcs.has(required_method),
			"P3 route RPC %s must be registered in main and Relay projects."
			% required_method
		)
	for shop_request_method in [
		"net_shop_purchase_request",
		"net_shop_sell_request",
		"net_shop_exit_ack",
	]:
		_expect_rpc_mode(
			main_rogue_route_rpcs,
			shop_request_method,
			"any_peer"
		)
		_expect_rpc_channel(
			main_rogue_route_rpcs,
			shop_request_method,
			0
		)
	_expect_rpc_mode(
		main_rogue_route_rpcs,
		"net_route_upgrade_requested",
		"any_peer"
	)
	_expect_rpc_channel(main_rogue_route_rpcs, "net_route_upgrade_requested", 0)
	for request_field in [
		"stat_type:int",
		"expected_level:int",
		"expected_xirang_revision:int",
	]:
		_expect_rpc_signature_contains(
			main_rogue_route_rpcs,
			"net_route_upgrade_requested",
			request_field
		)
	_expect(
		String(main_rogue_route_rpcs.get("net_route_upgrade_requested", "")).contains(
			"stat_type:int,expected_level:int,expected_xirang_revision:int"
		),
		"Route upgrade requests must preserve the three-field CAS order."
	)
	_expect_rpc_signature_contains(
		main_rogue_route_rpcs,
		"net_route_full_snapshot",
		"progression_ledger:Dictionary"
	)
	_expect_rpc_mode(
		main_rogue_route_rpcs,
		"net_shop_snapshot",
		"authority"
	)
	_expect_rpc_channel(main_rogue_route_rpcs, "net_shop_snapshot", 0)
	_expect_rpc_channel(
		main_rogue_route_rpcs,
		"net_route_avatar_input",
		NetConstants.CH_INPUT
	)
	_expect_rpc_channel(
		main_rogue_route_rpcs,
		"net_route_avatar_snapshot",
		NetConstants.CH_PLAYER_STATE
	)
	_expect_rpc_channel(
		main_rogue_route_rpcs,
		"net_route_avatar_corrected",
		NetConstants.CH_AUTH
	)

	var main_net_manager_rpcs := _extract_rpc_surface(MAIN_NET_MANAGER_PATH)
	var relay_net_manager_rpcs := _extract_rpc_surface(RELAY_NET_MANAGER_PATH)
	_compare_rpc_surfaces("NetManager", main_net_manager_rpcs, relay_net_manager_rpcs)
	for required_method in [
		"_rpc_relay_player_registration_forward",
		"_rpc_register_player",
		"_rpc_registration_accepted",
		"_rpc_content_rejected",
		"_rpc_protocol_rejected",
		"_rpc_join_rejected",
		"_rpc_relay_kick_peer",
		"_rpc_relay_identity_lookup",
		"_rpc_relay_identity_result",
		"_rpc_set_player_character",
		"_rpc_sync_player_list",
		"_rpc_start_game",
		"_rpc_host_game_ready",
		"_rpc_report_game_loaded",
		"_rpc_game_load_progress",
		"_rpc_player_reconnected",
	]:
		_expect(
			main_net_manager_rpcs.has(required_method),
			"NetManager RPC %s must be registered in the main and Relay projects." % required_method
		)
	_expect_rpc_mode(
		main_net_manager_rpcs,
		"_rpc_relay_player_registration_forward",
		"any_peer"
	)
	_expect_rpc_channel(
		main_net_manager_rpcs,
		"_rpc_relay_player_registration_forward",
		NetConstants.RELAY_SERVICE_CHANNEL
	)
	if main_net_manager_rpcs.has("_rpc_register_player"):
		_expect(
			String(main_net_manager_rpcs["_rpc_register_player"]).contains(
				"protocol_version:int=-1"
			)
			and String(main_net_manager_rpcs["_rpc_register_player"]).contains(
				"reconnect_token:String=\"\""
			)
			and String(main_net_manager_rpcs["_rpc_register_player"]).contains(
				"content_manifest_schema:int=-1"
			)
			and String(main_net_manager_rpcs["_rpc_register_player"]).contains(
				"content_digest:String=\"\""
			),
			"Player registration must carry protocol, reconnect identity, schema, and digest fields."
		)
	_expect_rpc_channel(main_net_manager_rpcs, "_rpc_register_player", NetConstants.CH_AUTH)
	_expect_rpc_mode(main_net_manager_rpcs, "_rpc_relay_kick_peer", "any_peer")
	_expect_rpc_mode(main_net_manager_rpcs, "_rpc_relay_identity_lookup", "any_peer")
	_expect_rpc_mode(main_net_manager_rpcs, "_rpc_relay_identity_result", "any_peer")
	for service_method: String in [
		"_rpc_relay_kick_peer",
		"_rpc_relay_identity_lookup",
		"_rpc_relay_identity_result",
	]:
		_expect_rpc_channel(
			main_net_manager_rpcs,
			service_method,
			NetConstants.RELAY_SERVICE_CHANNEL
		)
	for membership_method: String in [
		"_rpc_registration_accepted",
		"_rpc_content_rejected",
		"_rpc_protocol_rejected",
		"_rpc_join_rejected",
		"_rpc_sync_player_list",
	]:
		_expect_rpc_channel(
			main_net_manager_rpcs,
			membership_method,
			NetConstants.CH_MEMBERSHIP
		)
	if main_net_manager_rpcs.has("_rpc_sync_player_list"):
		_expect(
			String(main_net_manager_rpcs["_rpc_sync_player_list"]).contains("game_mode:int=0")
			and String(main_net_manager_rpcs["_rpc_sync_player_list"]).contains(
				"max_players:int=8"
			),
			"Player-list sync must carry the Host-authoritative game mode and room capacity."
		)
	if main_net_manager_rpcs.has("_rpc_start_game"):
		_expect(
			String(main_net_manager_rpcs["_rpc_start_game"]).contains("game_mode:int=0")
			and String(main_net_manager_rpcs["_rpc_start_game"]).contains("session_id:int=0"),
			"Start-game sync must carry both authoritative mode and loading session."
		)
	_test_registration_protocol_handshake_source()
	_expect(
		NetConstants.PROTOCOL_VERSION == 96,
		"协议v96必须冻结认证注册转发、Relay身份绑定与既有内容合同。"
	)
	_expect(
		NetConstants.CH_MEMBERSHIP == 8
		and NetConstants.ENET_MAX_CHANNEL == 8
		and NetConstants.CHANNEL_COUNT == 9
		and NetConstants.RELAY_CONTROL_CHANNEL == 9
		and NetConstants.RELAY_SERVICE_CHANNEL == 9
		and NetConstants.RELAY_ENET_MAX_CHANNEL == 9,
		(
			"Protocol v96 must keep application CH0..CH8 and order Relay "
			+ "topology plus service traffic on reliable CH9."
		)
	)
	_test_relay_channel_count()

	if failures.is_empty():
		print("RELAY_RPC_PARITY_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _compare_rpc_surfaces(label: String, main_rpcs: Dictionary, relay_rpcs: Dictionary) -> void:
	_expect(not main_rpcs.is_empty(), "Main %s RPC surface must not be empty." % label)
	_expect(
		main_rpcs.size() == relay_rpcs.size(),
		"Relay RPC count must match main %s (%d != %d)."
		% [label, relay_rpcs.size(), main_rpcs.size()]
	)
	for method_name_variant in main_rpcs.keys():
		var method_name := String(method_name_variant)
		_expect(relay_rpcs.has(method_name), "Relay %s is missing RPC %s." % [label, method_name])
		if relay_rpcs.has(method_name):
			_expect(
				String(relay_rpcs[method_name]) == String(main_rpcs[method_name]),
				"Relay %s RPC annotation/signature differs for %s." % [label, method_name]
			)
	for method_name_variant in relay_rpcs.keys():
		var method_name := String(method_name_variant)
		_expect(main_rpcs.has(method_name), "Relay %s has stale extra RPC %s." % [label, method_name])


func _test_registration_protocol_handshake_source() -> void:
	var net_manager: Variant = NetManagerScript.new()
	_expect(
		net_manager._is_protocol_version_compatible(NetConstants.PROTOCOL_VERSION)
		and not net_manager._is_protocol_version_compatible(
			NetConstants.PROTOCOL_VERSION - 1
		),
		"Protocol v94 hosts must accept exactly v94 and reject v93."
	)
	var pending_relay_registration := {
		"request_id": 7,
		"player_name": "BoundMember",
	}
	_expect(
		net_manager.is_valid_relay_registration_identity_binding(
			1, 7, 3, "room_01", "BoundMember", "member", true,
			pending_relay_registration, "room_01"
		)
		and not net_manager.is_valid_relay_registration_identity_binding(
			1, 7, 3, "room_01", "ForgedName", "member", true,
			pending_relay_registration, "room_01"
		)
		and not net_manager.is_valid_relay_registration_identity_binding(
			1, 7, 3, "room_01", "BoundMember", "host", true,
			pending_relay_registration, "room_01"
		),
		"Relay registration must require the peer-1 identity name, role, room, peer, and request tuple."
	)
	net_manager.net_role = 1
	net_manager.conn_mode = 1
	net_manager.relay_room_id = "room_01"
	net_manager._pending_relay_registrations[3] = {
		"request_id": 9,
		"lookup_deadline_msec": 10,
		"player_name": "BoundMember",
	}
	net_manager._late_registration_deadlines[3] = 10
	net_manager._poll_relay_identity_lookup_timeouts(10)
	_expect(
		not net_manager._pending_relay_registrations.has(3)
		and not net_manager._late_registration_deadlines.has(3)
		and not net_manager._handle_relay_identity_result(
			1, 1, 9, 3, "room_01", "BoundMember", "member", true
		),
		(
			"Relay identity lookups with no response must expire at the unified registration "
			+ "deadline, and a result arriving after expiry must remain invalid."
		)
	)
	net_manager.free()
	var source := FileAccess.get_file_as_string(MAIN_NET_MANAGER_PATH)
	_expect(not source.is_empty(), "Main NetManager source must be readable for protocol checks.")
	if source.is_empty():
		return
	var registration_call_regex := RegEx.new()
	var compile_error := registration_call_regex.compile(
		(
			"(?ms)_rpc_register_player\\.rpc_id\\s*\\(.*?"
			+ "NetConstants\\.PROTOCOL_VERSION\\s*,\\s*local_reconnect_token\\s*,\\s*"
			+ "_get_local_content_manifest_schema\\(\\)\\s*,\\s*"
			+ "_get_local_content_digest\\(\\)\\s*\\)"
		)
	)
	if compile_error != OK:
		failures.append("Unable to compile registration protocol parser regex.")
		return
	_expect(
		registration_call_regex.search_all(source).size() == 1
		and source.contains('"ticket": _relay_admission_ticket')
		and source.contains('"protocol_version": NetConstants.PROTOCOL_VERSION')
		and source.contains('"content_manifest_schema": _get_local_content_manifest_schema()')
		and source.contains('"content_digest": _get_local_content_digest()'),
		(
			"LAN registration and the Relay auth envelope must both carry protocol, "
			+ "schema, and content digest."
		)
	)
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile protocol whitespace regex.")
		return
	var compact_source := whitespace_regex.sub(source, "", true)
	_expect(
		compact_source.contains("ifnot_is_protocol_version_compatible(protocol_version):"),
		"Host registration must reject an incompatible protocol before adding the player."
	)
	_expect(
		compact_source.contains(
			"ifsender_id>0andresolved_host_id>0andsender_id!=resolved_host_id:return"
		),
		(
			"Player-list authority must reject an in-band Host migration whose claimed "
			+ "Host id differs from the authenticated RPC sender."
		)
	)
	_expect(
		compact_source.contains("orcontent_manifest_schema!=_get_local_content_manifest_schema()")
		and compact_source.contains("orcontent_digest!=_get_local_content_digest()")
		and compact_source.contains("_send_content_rejected_to_peer(sender_id)"),
		"Host registration must reject a mismatched content identity before member or reconnect mutation."
	)
	_expect(
		compact_source.contains(
			"_rpc_protocol_rejected.rpc_id(sender_id,NetConstants.PROTOCOL_VERSION)"
		),
		"Host registration rejection must report the expected protocol version."
	)
	_expect(
		compact_source.contains("call_deferred(\"_disconnect_incompatible_peer\",sender_id)"),
		"Host registration rejection must disconnect the incompatible peer after reporting it."
	)
	_expect(
		compact_source.contains("ifnot_is_registration_open():")
		and compact_source.contains(
			"ifconnection_state==ConnectionState.IN_GAME:"
		)
		and compact_source.contains("reconnect_started=_begin_peer_reconnect(")
		and compact_source.contains("_rpc_join_rejected.rpc_id("),
		"A locked Host must admit only token-matched reconnects and reject every other late registration."
	)
	_expect(
		compact_source.contains("ifconnected_players.has(sender_id):")
		and compact_source.contains("_try_replay_relay_registration_response(")
		and compact_source.contains("_accepted_peer_registration_tuples"),
		(
			"A connected Relay identity may only replay its exact accepted tuple for "
			+ "a targeted idempotent response."
		)
	)
	_expect(
		compact_source.contains("_late_registration_deadlines[peer_id]=(")
		and compact_source.contains("REGISTRATION_TIMEOUT_MILLISECONDSif_is_registration_open()")
		and compact_source.contains("elseLATE_REGISTRATION_TIMEOUT_MILLISECONDS")
		and compact_source.contains("_pending_relay_registrations.erase(peer_id)")
		and compact_source.contains("_reject_late_connected_peer(int(peer_id))"),
		"Every unregistered Host-side transport must have one bounded registration/identity deadline."
	)


func _test_relay_channel_count() -> void:
	var relay_source := FileAccess.get_file_as_string(RELAY_SERVER_PATH)
	var game_relay_peer_source := FileAccess.get_file_as_string(GAME_RELAY_PEER_PATH)
	var relay_peer_source := FileAccess.get_file_as_string(RELAY_PEER_PATH)
	var relay_project_source := FileAccess.get_file_as_string(RELAY_PROJECT_PATH)
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile Relay source whitespace regex.")
		return
	var compact_relay_source := whitespace_regex.sub(relay_source, "", true)
	_expect(not relay_source.is_empty(), "Relay server source must be readable.")
	_expect(
		FileAccess.file_exists(GAME_RELAY_PEER_PATH)
		and FileAccess.file_exists(RELAY_PEER_PATH)
		and not game_relay_peer_source.is_empty()
		and not relay_peer_source.is_empty()
		and game_relay_peer_source == relay_peer_source
		and game_relay_peer_source.contains("extends MultiplayerPeerExtension")
		and game_relay_peer_source.contains("const TOPOLOGY_CHANNEL := 9")
		and game_relay_peer_source.contains(
			"const RELAY_SERVICE_CHANNEL := TOPOLOGY_CHANNEL"
		),
		(
			"The main-project and nested Relay MultiplayerPeerExtension wrappers must "
			+ "remain byte-for-byte identical, with topology and service ordering on CH9."
		)
	)
	_expect(
		relay_source.contains("const CH_MEMBERSHIP := 8")
		and relay_source.contains("const RELAY_CONTROL_CHANNEL := CH_MEMBERSHIP + 1")
		and relay_source.contains("const RELAY_SERVICE_CHANNEL := RELAY_CONTROL_CHANNEL")
		and relay_source.contains("const ENET_MAX_CHANNEL := RELAY_CONTROL_CHANNEL")
		and relay_source.contains("const CHANNEL_COUNT := CH_MEMBERSHIP + 1")
		and relay_source.contains("const PROTOCOL_VERSION := 96")
		and relay_source.contains("const MAX_CLIENTS := 8")
		and relay_source.contains("--max-clients=")
		and relay_source.contains("create_server(_port, transport_capacity, ENET_MAX_CHANNEL)")
		and relay_source.contains("multiplayer.server_relay = false")
		and relay_source.contains("multiplayer.auth_callback = _on_auth_payload")
		and relay_source.contains("mark_peer_authenticated(peer_id)")
		and relay_source.contains("authentication=required"),
		(
			"Relay server must declare v91, admit up to eight authenticated players, "
			+ "keep application CH0..CH8, and reserve reliable CH9 for topology/service."
		)
	)
	_expect(
		relay_source.contains("const AUTH_REQUEST_KEYS := [")
		and relay_source.contains("func _parse_registration_request(")
		and relay_source.contains("func _registration_matches_claims(")
		and relay_source.contains("func _forward_authenticated_player_registration(")
		and relay_source.contains(
			"net_manager_stub._rpc_relay_player_registration_forward.rpc_id("
		),
		(
			"Relay v91 must validate the exact authenticated registration envelope "
			+ "and forward the stored tuple once after ordered topology publication."
		)
	)
	_expect(
		relay_project_source.contains(
			'MpRogueRoute="*res://relay_rogue_route_stub.gd"'
		)
		and relay_source.contains(
			'get_node_or_null("/root/MpRogueRoute")'
		)
		and relay_source.contains("net_manager_stub.set_multiplayer_authority(peer_id)")
		and relay_source.contains("mp_game_stub.set_multiplayer_authority(peer_id)")
		and relay_source.contains("rogue_route_stub.set_multiplayer_authority(peer_id)"),
		"Relay must mount the P3 stub at /root/MpRogueRoute and assign Host authority."
	)
	_expect(
		compact_relay_source.contains('ifrole=="host":_host_peer_id=peer_id_set_stub_authority(peer_id)')
		and compact_relay_source.contains("func_set_stub_authority(peer_id:int)->void:"),
		"A verified Host ticket must assign the same peer id to every Relay RPC stub through the authority helper."
	)
	_expect(
		compact_relay_source.contains("_host_was_authenticated=true")
		and compact_relay_source.contains(
			'ifrole=="host":returnregistered_host_peer_id<=0andnothost_was_authenticated'
		)
		and compact_relay_source.contains(
			"ifwas_host:_registration_by_peer.clear()_host_peer_id=0_set_stub_authority(1)"
		)
		and not compact_relay_source.contains("_host_was_authenticated=false"),
		(
			"A Relay lifetime must reject replacement-Host admission after its authenticated "
			+ "Host leaves; protocol v94 does not support Host migration."
		)
	)
	_expect(
		relay_source.contains("func request_host_peer_disconnect(")
		and relay_source.contains("is_authorized_host_kick_request(")
		and relay_source.contains("_relay_peer.disconnect_peer(target_peer_id, true)")
		and relay_source.contains("sender_peer_id == registered_host_peer_id"),
		"Relay kick control must authenticate its registered Host sender and disconnect only the requested live target."
	)
	_expect(
		relay_source.contains("func request_authenticated_peer_identity(")
		and relay_source.contains("is_authorized_host_identity_lookup_target(")
		and relay_source.contains("_identity_by_peer[target_peer_id]")
		and relay_source.contains("_rpc_relay_identity_result.rpc_id("),
		"Relay identity lookup must answer the live Host exclusively from its authenticated peer ledger."
	)


func _test_tango_charge_authority_source() -> void:
	var source := FileAccess.get_file_as_string(MAIN_MP_GAME_PATH)
	var player_source := FileAccess.get_file_as_string(MAIN_PLAYER_COORDINATOR_PATH)
	var projectile_source := FileAccess.get_file_as_string(
		MAIN_PROJECTILE_COORDINATOR_PATH
	)
	_expect(not source.is_empty(), "MpGame source must be readable for Tango authority checks.")
	_expect(
		not player_source.is_empty(),
		"PlayerCoordinator source must be readable for Tango authority checks."
	)
	_expect(
		not projectile_source.is_empty(),
		"ProjectileCoordinator source must be readable for Tango volley checks."
	)
	if source.is_empty() or player_source.is_empty() or projectile_source.is_empty():
		return
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile Tango authority whitespace regex.")
		return
	var compact_source := whitespace_regex.sub(source, "", true)
	var compact_player_source := whitespace_regex.sub(player_source, "", true)
	var compact_projectile_source := whitespace_regex.sub(
		projectile_source,
		"",
		true
	)
	_expect(
		compact_player_source.contains(
			"varelapsed:=maxf(_get_action_net_time()-float(charge.get(\"started_at\",0.0)),0.0)"
		)
		and compact_player_source.contains(
			"tango_player.resolve_authoritative_tango_charge_release_ratio(elapsed)"
		)
		and compact_player_source.contains(
			"ifcharge_ratio<0.0:"
		),
		"PlayerCoordinator must pass its Host elapsed time through Tango's authoritative charge policy."
	)
	_expect(
		compact_player_source.contains(
			"tango_player.try_authoritative_tango_charge_released(safe_direction,charge_ratio)"
		),
		"Only the Host-derived Tango charge ratio may enter authoritative release."
	)
	_expect(
		compact_player_source.contains(
			"funcapply_authoritative_tango_charge_cancelled(peer_id:int,request_id:int)->bool:"
		)
		and compact_player_source.contains(
			"int(charge.get(\"request_id\",0))!=request_id:"
		)
		and compact_player_source.contains(
			"cancel_authoritative_tango_charge(peer_id,true,request_id)"
		),
		"Host Tango cancellation must match the sender's active request before broadcasting."
	)
	_expect(
		compact_player_source.contains(
			"tango_player.reconcile_predicted_tango_barrage_started(safe_direction,charge_ratio,charge_sequence)"
		),
		"The owning client must reconcile its predicted Tango barrage instead of restarting it."
	)
	_expect(
		compact_source.contains("funcregister_local_tango_laser_volley(")
		and compact_source.contains(
			"projectile_coordinator.submit_local_tango_laser_volley("
		)
		and compact_projectile_source.contains(
			"funcregister_local_tango_laser_volley("
		)
		and compact_projectile_source.contains(
			"projectiles.size()!=TANGO_LASER_VOLLEY_PROJECTILE_COUNT"
		)
		and compact_projectile_source.contains(
			"allocate_projectile_id(owner_peer_id,true)"
		)
		and compact_projectile_source.contains(
			"&\"net_tango_laser_volley\""
		),
		"Tango's three projectiles must be allocated and broadcast as one Host-origin volley."
	)
	_expect(
		compact_projectile_source.contains("_last_tango_volley_visual_state_by_peer")
		and compact_projectile_source.contains("charge_sequence>current_charge_sequence")
		and compact_projectile_source.contains(
			"host_fire_timestamp>previous_visual_timestamp"
		)
		and compact_projectile_source.contains("_get_host_event_age(host_fire_timestamp)")
		and compact_source.contains("_get_unbounded_host_event_age,"),
		"Tango volley visuals must reject stale sequences/timestamps and use unbounded event age."
	)
	_expect(
		compact_player_source.contains("uses_passive_tango_mouse_aim")
		and compact_player_source.contains(
			"andnotpassive_tango_aim):returnVector2.ZERO"
		),
		"Tango's released barrage must continue sending passive mouse aim input."
	)
	_expect(
		compact_player_source.contains(
			"funcapply_authoritative_tango_charge_snapshot_ratios("
		)
		and compact_player_source.contains(
			"tango_player.resolve_authoritative_tango_charge_progress_ratio(maxf(sample_time-started_at,0.0))"
		),
		"Host snapshots must resolve Tango's charging bar through the same character policy."
	)
	_expect(
		compact_player_source.contains("has_local_tango_prediction()")
		and compact_player_source.contains("andlocal_tango_prediction_active")
		and compact_player_source.contains("ifsuppress_local_tango_snapshot:return"),
		"A local Tango prediction must not be overwritten by an older zero-ratio snapshot."
	)
	_expect(
		compact_player_source.count("orcharge_sequence<last_charge_sequence") == 2
		and compact_player_source.count(
			"ifcharge_sequence>last_charge_sequence:_tango_charge_sequences_by_peer[peer_id]=charge_sequence"
		) == 2,
		"Tango release and cancel terminals must accept a newer sequence when started was missed."
	)
	var reject_start := compact_player_source.find("funcapply_tango_charge_rejected(")
	var reject_end := compact_player_source.find("func", reject_start + 1)
	var reject_source := (
		compact_player_source.substr(reject_start, reject_end - reject_start)
		if reject_start >= 0 and reject_end > reject_start
		else ""
	)
	_expect(
		reject_source.contains(
			"orrequest_id!=_local_tango_active_request_id"
		),
		"A stale Tango rejection must not cancel a newer local prediction."
	)
	for game_path in [
		STANDARD_GAME_PATH,
		ROGUE_COMBAT_GAME_PATH,
		TOWER_DEFENSE_PLAYER_ROSTER_PATH,
	]:
		var game_source := FileAccess.get_file_as_string(game_path)
		_expect(
			game_source.contains("func request_tango_charge_started(direction: Vector2) -> bool:")
			and game_source.contains("func request_tango_charge_released(direction: Vector2) -> bool:")
			and game_source.contains("func request_tango_charge_cancelled() -> bool:"),
			"%s must expose the singleplayer Tango charge bridge." % game_path
		)


func _test_tango_electric_surge_authority_source() -> void:
	var source := FileAccess.get_file_as_string(MAIN_PLAYER_COORDINATOR_PATH)
	_expect(
		not source.is_empty(),
		"PlayerCoordinator source must be readable for Electric Surge checks."
	)
	if source.is_empty():
		return
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile Electric Surge authority whitespace regex.")
		return
	var compact_source := whitespace_regex.sub(source, "", true)
	_expect(
		compact_source.contains("varorigin:=tango_player.global_position")
		and compact_source.contains(
			"tango_player.try_start_authoritative_electric_surge(activation_id,origin,auto_fire_charge_sequence)"
		)
		and compact_source.contains(
			"_active_tango_electric_surges_by_peer[peer_id]={"
		),
		"Only the Host player's position and readiness may start an Electric Surge."
	)
	_expect(
		compact_source.contains("funcsend_active_tango_electric_surges_to_peer(")
		and compact_source.contains("remaining_seconds_at_send:float")
		and compact_source.contains("host_sent_at:float")
		and compact_source.contains(
			"_session_coordinator.map_host_timestamp_to_client_time(host_sent_at,false)"
		)
		and compact_source.contains(
			"tango_player.play_remote_electric_surge_started(activation_id,origin,remaining,false,auto_fire_charge_sequence)"
		),
		"Electric Surge recovery must use Host remaining time without poisoning clock offset."
	)
	_expect(
		compact_source.contains("tango_player.is_electric_surge_active()")
		and compact_source.contains("tango_player.is_tango_barrage_active()")
		and compact_source.contains(
			"[peer_id,safe_direction,1.0,charge_sequence,request_id]"
		),
		"The Host must convert a surge-period attack into the existing full-charge barrage terminal."
	)


func _test_gameplay_v17_transaction_contract(rpcs: Dictionary) -> void:
	_expect_rpc_signature_contains(
		rpcs,
		"net_enemy_lightning_chain",
		"points:PackedVector2Array"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_terrain_snapshot_requested",
		"known_revision:int"
	)
	for terrain_method in ["net_terrain_snapshot_chunk", "net_terrain_delta"]:
		_expect_rpc_signature_contains(rpcs, terrain_method, "cell_xy:PackedInt32Array")
		_expect_rpc_signature_contains(rpcs, terrain_method, "terrain_types:PackedInt32Array")
	_expect_rpc_signature_contains(rpcs, "net_plant_spawned", "runtime_state:Dictionary")
	_expect_rpc_signature_contains(rpcs, "net_plant_spawned", "host_sample_time:float")
	_expect_rpc_signature_contains(
		rpcs,
		"net_plant_damage_status_changed",
		"status_mask:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_plant_damage_status_changed",
		"status_revision:int"
	)
	for signature_fragment in [
		"peer_id:int",
		"current_health:int",
		"health_revision:int",
		"confirmed_healing:int",
	]:
		_expect_rpc_signature_contains(rpcs, "net_player_healed", signature_fragment)
	var tower_world_source := FileAccess.get_file_as_string(TOWER_WORLD_COORDINATOR_PATH)
	var tower_fate_source := FileAccess.get_file_as_string(TOWER_FATE_COORDINATOR_PATH)
	var tower_economy_source := FileAccess.get_file_as_string(
		TOWER_ECONOMY_COORDINATOR_PATH
	)
	_expect(
		not tower_world_source.is_empty()
		and not tower_fate_source.is_empty()
		and not tower_economy_source.is_empty(),
		"Tower multiplayer coordinator sources must be readable for gameplay checks."
	)
	_expect(
		tower_world_source.contains(
			'runtime_state["damage_status_mask"] = plant.get_damage_status_mask()'
		)
		and tower_world_source.contains(
			'runtime_state["damage_status_revision"] = plant.damage_status_revision'
		)
		and tower_world_source.contains("plant.apply_remote_damage_status_mask("),
		"Late-join plant runtime snapshots must carry and apply revisioned damage-status masks."
	)
	_expect(
		tower_fate_source.contains("_tower_adapter.get_xiaocong_fate_state_snapshot()")
		and tower_fate_source.contains(
			"_tower_adapter.apply_remote_xiaocong_fate_state(state)"
		)
		and tower_fate_source.contains("_admit_domain_request(peer_id)"),
		(
			"Xiaocong fate state must cross the explicit tower adapter during runtime "
			+ "repair, and all remote choices must pass Host admission."
		)
	)
	_expect(
		tower_world_source.contains("const TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS := 96")
		and tower_world_source.contains("const TERRAIN_TYPE_EMPTY := -1")
		and tower_world_source.contains("const TERRAIN_SNAPSHOT_REQUEST_RATE_PER_SECOND := 1.0")
		and tower_world_source.contains("const TERRAIN_SNAPSHOT_REQUEST_RATE_BURST := 2.0"),
		"Protocol v25 terrain repair must use 96-cell chunks, preserve EMPTY=-1, and rate-limit repair requests."
	)
	_expect(
		tower_economy_source.contains(
			"GlobalResearchRegistry.get_config_by_wire_id(research_id_wire)"
		)
		and tower_economy_source.contains(
			"or int(raw_command[\"schema\"])"
		)
		and tower_economy_source.contains(
			"!= ResearchCenter.MULTIPLAYER_RESEARCH_COMMAND_SCHEMA"
		)
		and tower_economy_source.contains(
			"building.try_start_global_research(research_config.research_id)"
		),
		"Protocol v25 research commands must use schema2 and resolve a Host-owned research whitelist."
	)
	for signature_fragment in [
		"plant_net_ids:PackedInt32Array",
		"action_ids:PackedInt32Array",
		"stages:PackedByteArray",
		"spawn_positions:PackedVector2Array",
		"landing_positions:PackedVector2Array",
		"committed_windup_durations:PackedFloat32Array",
		"host_action_times:PackedFloat64Array",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_bamboo_mortar_visual_batch",
			signature_fragment
		)
	for signature_fragment in [
		"plant_net_ids:PackedInt32Array",
		"action_ids:PackedInt32Array",
		"shot_counts:PackedByteArray",
		"directions:PackedVector2Array",
		"host_action_times:PackedFloat64Array",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_corn_machine_gun_burst_batch",
			signature_fragment
		)
	for signature_fragment in [
		"projectile_ids:PackedInt64Array",
		"spawn_positions:PackedVector2Array",
		"directions:PackedVector2Array",
		"owner_peer_id:int",
		"damage:int",
		"speed:float",
		"lifetime:float",
		"host_fire_timestamp:float",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_linglan_skill1_ring_batch",
			signature_fragment
		)
	for signature_fragment in [
		"projectile_ids:PackedInt64Array",
		"spawn_positions:PackedVector2Array",
		"direction:Vector2",
		"owner_peer_id:int",
		"charge_sequence:int",
		"charge_ratio:float",
		"barrage_remaining_seconds:float",
		"damage:int",
		"speed:float",
		"lifetime:float",
		"host_fire_timestamp:float",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_tango_laser_volley",
			signature_fragment
		)
	_expect_rpc_signature_contains(
		rpcs,
		"net_inventory_item_use_requested",
		"expected_inventory_revision:int=-1"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_inventory_item_discard_requested",
		"expected_inventory_revision:int=-1"
	)
	for signature_fragment in [
		"slot_index:int",
		"expected_inventory_revision:int",
		"item_config_path:String",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_inventory_plant_placement_requested",
			signature_fragment
		)
	for confirmation_method in [
		"net_inventory_item_used",
		"net_inventory_item_discarded",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			confirmation_method,
			"inventory_snapshot:Dictionary"
		)
		_expect(
			not String(rpcs[confirmation_method]).contains(
				"inventory_snapshot:Dictionary={}"
			),
			"Protocol v25 inventory confirmations must require an authoritative snapshot."
		)
		_expect_rpc_signature_contains(
			rpcs,
			confirmation_method,
			"force_inventory_repair:bool=false"
		)
	_expect_rpc_signature_contains(
		rpcs,
		"net_inventory_snapshot",
		"force_inventory_repair:bool=false"
	)
	for signature_fragment in [
		"request_id:int",
		"recipe_id:String",
		"expected_inventory_revision:int",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_simple_crafting_requested",
			signature_fragment
		)
	for signature_fragment in [
		"peer_id:int",
		"request_id:int",
		"recipe_id:String",
		"result:String",
		"inventory_snapshot:Dictionary",
		"force_inventory_repair:bool=false",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_simple_crafting_result",
			signature_fragment
		)
	_expect_rpc_signature_contains(
		rpcs,
		"net_pickup_collected",
		"inventory_snapshot:Dictionary={}"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_xiaocong_fate_vote_requested",
		"option_id:String"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_xiaocong_fate_vote_requested",
		"permanent_buff_id:String"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_xiaocong_collectible_choice_requested",
		"choice_index:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_xiaocong_fate_state_changed",
		"state:Dictionary"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_collectible_choice_requested",
		"offer_revision:int=0"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_collectible_offer_state",
		"config_paths:PackedStringArray"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_collectible_confirmed",
		"inventory_snapshot:Dictionary={}"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_special_game_card_reveal_requested",
		"session_revision:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_special_game_card_reveal_requested",
		"card_index:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_special_game_finish_requested",
		"session_revision:int"
	)
	for special_result_method in [
		"net_luoxi_special_game_started",
		"net_luoxi_special_game_finished",
	]:
		_expect_rpc_signature_contains(rpcs, special_result_method, "peer_id:int")
		_expect_rpc_signature_contains(rpcs, special_result_method, "result:Dictionary")
		_expect_rpc_signature_contains(
			rpcs,
			special_result_method,
			"inventory_snapshot:Dictionary={}"
		)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_special_game_card_revealed",
		"peer_id:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_luoxi_special_game_card_revealed",
		"result:Dictionary"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_warehouse_command_requested",
		"command:Dictionary"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_warehouse_snapshot_requested",
		"warehouse_net_id:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_warehouse_command_result",
		"result:Dictionary"
	)
	for signature_fragment in [
		"warehouse_net_ids:PackedInt32Array",
		"snapshots:Array",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_warehouse_storage_snapshot_batch",
			signature_fragment
		)
	_expect_rpc_signature_contains(
		rpcs,
		"net_production_command_requested",
		"command:Dictionary"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_production_snapshot_requested",
		"building_net_id:int"
	)
	_expect_rpc_signature_contains(
		rpcs,
		"net_production_command_result",
		"result:Dictionary"
	)
	for signature_fragment in [
		"net_ids:PackedInt32Array",
		"states:Array",
		"host_sample_times:PackedFloat64Array",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_production_state_batch",
			signature_fragment
		)
	_expect_rpc_signature_contains(
		rpcs,
		"net_research_command_requested",
		"command:Dictionary"
	)
	for signature_fragment in [
		"request_id:int",
		"building_net_id:int",
		"success:bool",
		"reason:StringName",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_research_command_result",
			signature_fragment
		)
	for signature_fragment in [
		"state:Dictionary",
		"changed_player_peer_id:int",
		"current_xirang:int",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_research_state_updated",
			signature_fragment
		)


func _test_gameplay_channel_contract(rpcs: Dictionary) -> void:
	var channel_regex := RegEx.new()
	if channel_regex.compile("@rpc\\([^)]*,([0-9]+)\\)func") != OK:
		failures.append("Unable to compile gameplay RPC channel parser regex.")
		return
	var channel_counts: Dictionary[int, int] = {}
	for method_name_variant in rpcs:
		var method_name := String(method_name_variant)
		var rpc_surface := String(rpcs[method_name])
		var channel_match := channel_regex.search(rpc_surface)
		_expect(channel_match != null, "Gameplay RPC %s must expose a channel." % method_name)
		if channel_match == null:
			continue
		var channel := int(channel_match.get_string(1))
		channel_counts[channel] = channel_counts.get(channel, 0) + 1
		_expect(
			channel >= 0 and channel < NetConstants.CHANNEL_COUNT,
			"Gameplay RPC %s uses out-of-range channel %d." % [method_name, channel]
		)
	_expect(
		channel_counts.get(NetConstants.CH_WORLD_EVENT, 0) == 68,
		"Protocol v96 must expose exactly 68 MpGame RPCs on reliable world-event CH5."
	)

	_expect_rpc_channel(rpcs, "net_runtime_state_requested", NetConstants.CH_AUTH)
	_expect_rpc_channel(rpcs, "net_terrain_snapshot_requested", NetConstants.CH_AUTH)
	_expect_rpc_channel(rpcs, "_rpc_client_player_state", NetConstants.CH_INPUT)
	_expect_rpc_channel(rpcs, "_rpc_receive_player_snapshot", NetConstants.CH_PLAYER_STATE)
	_expect_rpc_channel(rpcs, "_rpc_receive_enemy_snapshot", NetConstants.CH_ENEMY_STATE)
	_expect_rpc_channel(rpcs, "_rpc_projectile_fired_from_client", NetConstants.CH_PROJECTILE)
	_expect_rpc_channel(
		rpcs,
		"net_bamboo_mortar_visual_batch",
		NetConstants.CH_WORLD_EVENT
	)
	_expect_rpc_channel(
		rpcs,
		"net_corn_machine_gun_burst_batch",
		NetConstants.CH_PROJECTILE
	)
	for projectile_batch_method in [
		"net_tango_laser_volley",
		"net_linglan_skill1_ring_batch",
		"net_enemy_rapid_fire_burst",
	]:
		_expect_rpc_channel(
			rpcs,
			projectile_batch_method,
			NetConstants.CH_PROJECTILE
		)
	for world_event_method in [
		"net_enemy_rapid_fire_finished_batch",
		"net_tango_electric_surge_requested",
		"net_tango_electric_surge_started",
		"net_tango_electric_surge_finished",
		"net_tango_charge_started_requested",
		"net_tango_charge_released_requested",
		"net_tango_charge_cancelled_requested",
		"net_tango_charge_started",
		"net_tango_charge_released",
		"net_tango_charge_cancelled",
		"net_tango_charge_rejected",
		"net_enemy_spawned_batch",
		"net_enemy_faction_changed_batch",
		"net_enemy_target_presentation_state_batch",
		"net_enemy_terminal",
		"net_enemy_rapid_fire_repair_burst",
		"net_enemy_rapid_fire_snapshot_chunk",
		"net_capoo_data_projectile_snapshot_chunk",
		"net_plant_spawned",
		"net_nearest_plant_destruction_requested",
		"net_plant_damage_status_changed",
		"net_plant_removed",
		"net_pickup_collected",
		"net_base_health_changed",
		"net_terrain_snapshot_chunk",
		"net_terrain_delta",
		"net_xiaocong_fate_state_changed",
		"net_test_arena_manual_night_changed",
	]:
		_expect_rpc_channel(rpcs, world_event_method, NetConstants.CH_WORLD_EVENT)
	for signature_fragment in [
		"host_first_shot_timestamp:float",
		"descriptor:PackedByteArray",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_enemy_rapid_fire_burst",
			signature_fragment
		)
	for signature_fragment in [
		"snapshot_id:int",
		"chunk_index:int",
		"chunk_count:int",
		"host_snapshot_timestamp:float",
		"descriptor:PackedByteArray",
	]:
		_expect_rpc_signature_contains(
			rpcs,
			"net_enemy_rapid_fire_snapshot_chunk",
			signature_fragment
		)
		_expect_rpc_signature_contains(
			rpcs,
			"net_capoo_data_projectile_snapshot_chunk",
			signature_fragment
		)
	for transaction_method in [
		"net_inventory_item_use_requested",
		"net_inventory_item_discard_requested",
		"net_inventory_item_used",
		"net_inventory_item_discarded",
		"net_inventory_snapshot",
		"net_simple_crafting_requested",
		"net_simple_crafting_result",
		"net_xiaocong_interaction_requested",
		"net_xiaocong_fate_vote_requested",
		"net_xiaocong_collectible_choice_requested",
		"net_luoxi_collectible_offer_requested",
		"net_luoxi_collectible_offer_state",
		"net_luoxi_collectible_choice_requested",
		"net_luoxi_collectible_confirmed",
		"net_luoxi_special_game_start_requested",
		"net_luoxi_special_game_card_reveal_requested",
		"net_luoxi_special_game_finish_requested",
		"net_luoxi_special_game_started",
		"net_luoxi_special_game_card_revealed",
		"net_luoxi_special_game_finished",
		"net_warehouse_command_requested",
		"net_warehouse_snapshot_requested",
		"net_warehouse_command_result",
		"net_warehouse_storage_snapshot_batch",
		"net_production_command_requested",
		"net_production_snapshot_requested",
		"net_production_command_result",
		"net_production_state_batch",
		"net_research_command_requested",
		"net_research_command_result",
		"net_research_state_updated",
	]:
		_expect_rpc_channel(rpcs, transaction_method, NetConstants.CH_TRANSACTION)
	for feedback_method in [
		"net_enemy_damage_feedback_batch",
		"net_enemy_lightning_chain",
		"net_collectible_visual_effect",
		"net_collectible_follow_visual_effect",
		"net_plant_health_batch",
	]:
		_expect_rpc_channel(rpcs, feedback_method, NetConstants.CH_FEEDBACK)


func _expect_rpc_signature_contains(
	rpcs: Dictionary,
	method_name: String,
	required_fragment: String
) -> void:
	_expect(rpcs.has(method_name), "Gameplay RPC %s must be registered." % method_name)
	if not rpcs.has(method_name):
		return
	_expect(
		String(rpcs[method_name]).contains(required_fragment),
		"Gameplay RPC %s must contain %s." % [method_name, required_fragment]
	)


func _expect_rpc_channel(rpcs: Dictionary, method_name: String, expected_channel: int) -> void:
	_expect(rpcs.has(method_name), "Gameplay RPC %s must be registered." % method_name)
	if not rpcs.has(method_name):
		return
	_expect(
		String(rpcs[method_name]).contains(",%d)func" % expected_channel),
		"Gameplay RPC %s must use channel %d." % [method_name, expected_channel]
	)


func _expect_rpc_mode(rpcs: Dictionary, method_name: String, expected_mode: String) -> void:
	_expect(rpcs.has(method_name), "Gameplay RPC %s must be registered." % method_name)
	if not rpcs.has(method_name):
		return
	_expect(
		String(rpcs[method_name]).begins_with('@rpc("%s"' % expected_mode),
		"Gameplay RPC %s must use RPC mode %s." % [method_name, expected_mode]
	)


func _extract_rpc_surface(path: String) -> Dictionary:
	var source := FileAccess.get_file_as_string(path)
	if source.is_empty():
		failures.append("Unable to read RPC source: %s" % path)
		return {}
	var block_regex := RegEx.new()
	var compile_error := block_regex.compile(
		"(?ms)^@rpc\\([^\\r\\n]+\\)\\r?\\nfunc\\s+[A-Za-z0-9_]+\\s*\\(.*?\\)\\s*->\\s*void:"
	)
	if compile_error != OK:
		failures.append("Unable to compile RPC parser regex.")
		return {}
	var name_regex := RegEx.new()
	if name_regex.compile("(?m)^func\\s+([A-Za-z0-9_]+)") != OK:
		failures.append("Unable to compile RPC name regex.")
		return {}
	var whitespace_regex := RegEx.new()
	if whitespace_regex.compile("\\s+") != OK:
		failures.append("Unable to compile whitespace regex.")
		return {}
	var surface: Dictionary = {}
	for block_match in block_regex.search_all(source):
		var block := block_match.get_string()
		var name_match := name_regex.search(block)
		if name_match == null:
			failures.append("RPC block without a method name in %s." % path)
			continue
		var method_name := name_match.get_string(1)
		if surface.has(method_name):
			failures.append("Duplicate RPC %s in %s." % [method_name, path])
			continue
		# The relay project intentionally has no EnemyConfig class. PHYSICAL is enum value 0.
		block = block.replace("EnemyConfig.DamageType.PHYSICAL", "0")
		surface[method_name] = whitespace_regex.sub(block, "", true)
	return surface


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
