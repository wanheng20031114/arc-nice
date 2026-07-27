extends SceneTree

const MAIN_MP_GAME_PATH := "res://scene/multiplayer/mp_game.gd"
const RELAY_MP_GAME_PATH := "res://relay_servers/relay_godot_project/relay_mp_game_stub.gd"
const MAIN_NET_MANAGER_PATH := "res://scene/multiplayer/net_manager.gd"
const RELAY_NET_MANAGER_PATH := "res://relay_servers/relay_godot_project/relay_net_manager_stub.gd"
const RELAY_SERVER_PATH := "res://relay_servers/relay_godot_project/relay_server.gd"
const NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const NetManagerScript := preload("res://scene/multiplayer/net_manager.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_rpcs := _extract_rpc_surface(MAIN_MP_GAME_PATH)
	var relay_rpcs := _extract_rpc_surface(RELAY_MP_GAME_PATH)
	_compare_rpc_surfaces("MpGame", main_rpcs, relay_rpcs)
	for required_method in [
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
		"net_plant_placement_requested",
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
		_expect(main_rpcs.has(required_method), "Gameplay RPC %s must be registered." % required_method)
	if main_rpcs.has("net_tiyi_high_noon_requested"):
		_expect(
			String(main_rpcs["net_tiyi_high_noon_requested"]).contains("activation_id:int"),
			"High-noon requests must carry their monotonic activation id."
		)
	_expect(
		not main_rpcs.has("net_wave_started"),
		"Legacy wave-index RPC must stay removed; flow step_id is the sole lifecycle source."
	)
	_test_gameplay_v17_transaction_contract(main_rpcs)
	_test_gameplay_channel_contract(main_rpcs)

	var main_net_manager_rpcs := _extract_rpc_surface(MAIN_NET_MANAGER_PATH)
	var relay_net_manager_rpcs := _extract_rpc_surface(RELAY_NET_MANAGER_PATH)
	_compare_rpc_surfaces("NetManager", main_net_manager_rpcs, relay_net_manager_rpcs)
	for required_method in [
		"_rpc_register_player",
		"_rpc_protocol_rejected",
		"_rpc_join_rejected",
		"_rpc_set_player_character",
		"_rpc_sync_player_list",
		"_rpc_start_game",
		"_rpc_host_game_ready",
		"_rpc_report_game_loaded",
		"_rpc_game_load_progress",
	]:
		_expect(
			main_net_manager_rpcs.has(required_method),
			"NetManager RPC %s must be registered in the main and Relay projects." % required_method
		)
	if main_net_manager_rpcs.has("_rpc_register_player"):
		_expect(
			String(main_net_manager_rpcs["_rpc_register_player"]).contains(
				"protocol_version:int=-1"
			),
			"Player registration must carry a protocol version and reject legacy omitted values."
		)
	if main_net_manager_rpcs.has("_rpc_sync_player_list"):
		_expect(
			String(main_net_manager_rpcs["_rpc_sync_player_list"]).contains("game_mode:int=0"),
			"Player-list sync must carry the Host-authoritative game mode."
		)
	if main_net_manager_rpcs.has("_rpc_start_game"):
		_expect(
			String(main_net_manager_rpcs["_rpc_start_game"]).contains("game_mode:int=0")
			and String(main_net_manager_rpcs["_rpc_start_game"]).contains("session_id:int=0"),
			"Start-game sync must carry both authoritative mode and loading session."
		)
	_test_registration_protocol_handshake_source()
	_expect(
		NetConstants.PROTOCOL_VERSION == 25,
		"Int32 player health/position snapshots require protocol v25."
	)
	_expect(NetConstants.CHANNEL_COUNT == 8, "Protocol v25 must provision eight ENet channels.")
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
	var net_manager := NetManagerScript.new()
	_expect(
		net_manager._is_protocol_version_compatible(25)
		and not net_manager._is_protocol_version_compatible(24),
		"Protocol v25 hosts must accept exactly v25 and reject v24."
	)
	net_manager.free()
	var source := FileAccess.get_file_as_string(MAIN_NET_MANAGER_PATH)
	_expect(not source.is_empty(), "Main NetManager source must be readable for protocol checks.")
	if source.is_empty():
		return
	var registration_call_regex := RegEx.new()
	var compile_error := registration_call_regex.compile(
		"(?ms)_rpc_register_player\\.rpc_id\\s*\\(.*?NetConstants\\.PROTOCOL_VERSION\\s*\\)"
	)
	if compile_error != OK:
		failures.append("Unable to compile registration protocol parser regex.")
		return
	_expect(
		registration_call_regex.search_all(source).size() == 2,
		"LAN and Relay registration must both send NetConstants.PROTOCOL_VERSION."
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
		and compact_source.contains("_rpc_join_rejected.rpc_id("),
		"Host registration must reject peers after the frozen loading roster begins."
	)
	_expect(
		compact_source.contains(
			"ifconnected_players.has(sender_id)andnot_is_registration_open():return"
		),
		"A delayed duplicate registration from the frozen roster must remain idempotent."
	)
	_expect(
		compact_source.contains(
			"ifis_host()andnot_is_registration_open()andpeer_id!=get_host_peer_id():"
		)
		and compact_source.contains("call_deferred(\"_reject_late_connected_peer\",peer_id)"),
		"The Host must reject a newly connected transport peer as soon as loading locks the room."
	)


func _test_relay_channel_count() -> void:
	var relay_source := FileAccess.get_file_as_string(RELAY_SERVER_PATH)
	_expect(not relay_source.is_empty(), "Relay server source must be readable.")
	_expect(
		relay_source.contains("const CHANNEL_COUNT := 8")
		and relay_source.contains("const PROTOCOL_VERSION := 25")
		and relay_source.contains("create_server(_port, MAX_CLIENTS, CHANNEL_COUNT)"),
		"Relay server must declare v25 and provision the same eight ENet channels as clients."
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
	var mp_game_source := FileAccess.get_file_as_string(MAIN_MP_GAME_PATH)
	_expect(
		mp_game_source.contains(
			'runtime_state["damage_status_mask"] = plant.get_damage_status_mask()'
		)
		and mp_game_source.contains(
			'runtime_state["damage_status_revision"] = plant.damage_status_revision'
		)
		and mp_game_source.contains("plant.apply_remote_damage_status_mask("),
		"Late-join plant runtime snapshots must carry and apply revisioned damage-status masks."
	)
	_expect(
		mp_game_source.contains("game.get_xiaocong_fate_state_snapshot()")
		and mp_game_source.contains("game.apply_remote_xiaocong_fate_state(state)")
		and mp_game_source.contains("_admit_remote_xiaocong_request(sender_id)"),
		"Xiaocong fate state must participate in runtime repair and all remote choices must pass Host admission."
	)
	_expect(
		mp_game_source.contains("const TERRAIN_SNAPSHOT_CHUNK_MAX_CELLS := 96")
		and mp_game_source.contains("const TERRAIN_TYPE_EMPTY := -1")
		and mp_game_source.contains("const TERRAIN_SNAPSHOT_REQUEST_RATE_PER_SECOND := 1.0")
		and mp_game_source.contains("const TERRAIN_SNAPSHOT_REQUEST_RATE_BURST := 2.0"),
		"Protocol v25 terrain repair must use 96-cell chunks, preserve EMPTY=-1, and rate-limit repair requests."
	)
	_expect(
		mp_game_source.contains(
			"GlobalResearchRegistry.get_config_by_wire_id(research_id_wire)"
		)
		and mp_game_source.contains(
			"or int(raw_command[\"schema\"])"
		)
		and mp_game_source.contains(
			"!= ResearchCenter.MULTIPLAYER_RESEARCH_COMMAND_SCHEMA"
		)
		and mp_game_source.contains(
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
	for method_name_variant in rpcs:
		var method_name := String(method_name_variant)
		var rpc_surface := String(rpcs[method_name])
		var channel_match := channel_regex.search(rpc_surface)
		_expect(channel_match != null, "Gameplay RPC %s must expose a channel." % method_name)
		if channel_match == null:
			continue
		var channel := int(channel_match.get_string(1))
		_expect(
			channel >= 0 and channel < NetConstants.CHANNEL_COUNT,
			"Gameplay RPC %s uses out-of-range channel %d." % [method_name, channel]
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
	_expect_rpc_channel(
		rpcs,
		"net_linglan_skill1_ring_batch",
		NetConstants.CH_PROJECTILE
	)
	for world_event_method in [
		"net_enemy_spawned_batch",
		"net_enemy_terminal",
		"net_plant_spawned",
		"net_plant_damage_status_changed",
		"net_plant_removed",
		"net_base_health_changed",
		"net_terrain_snapshot_chunk",
		"net_terrain_delta",
		"net_xiaocong_fate_state_changed",
	]:
		_expect_rpc_channel(rpcs, world_event_method, NetConstants.CH_WORLD_EVENT)
	for transaction_method in [
		"net_inventory_item_use_requested",
		"net_inventory_item_discard_requested",
		"net_inventory_item_used",
		"net_inventory_item_discarded",
		"net_inventory_snapshot",
		"net_simple_crafting_requested",
		"net_simple_crafting_result",
		"net_pickup_collected",
		"net_xiaocong_interaction_requested",
		"net_xiaocong_fate_vote_requested",
		"net_xiaocong_collectible_choice_requested",
		"net_luoxi_collectible_offer_requested",
		"net_luoxi_collectible_offer_state",
		"net_luoxi_collectible_choice_requested",
		"net_luoxi_collectible_confirmed",
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
