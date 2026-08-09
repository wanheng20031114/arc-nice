extends MultiplayerModeAdapter
class_name RogueMultiplayerModeAdapter


func get_rogue_runtime() -> RogueCombatGame:
	return runtime as RogueCombatGame


func accepts_game_mode_id(mode_id: int) -> bool:
	return mode_id == GameModeCatalog.MODE_TEST_ARENA_P3


func allows_debug_collectible_grants() -> bool:
	var rogue_runtime := get_rogue_runtime()
	return (
		rogue_runtime != null
		and rogue_runtime.allows_debug_collectible_grants()
	)


func allows_player_respawn(peer_id: int) -> bool:
	var rogue_runtime := get_rogue_runtime()
	return (
		rogue_runtime != null
		and rogue_runtime.allows_player_respawn(peer_id)
	)


func allows_enemy_pickup_drops() -> bool:
	var rogue_runtime := get_rogue_runtime()
	return (
		rogue_runtime != null
		and rogue_runtime.allows_enemy_pickup_drops()
	)


func is_terminal_combat_state() -> bool:
	var rogue_runtime := get_rogue_runtime()
	return (
		rogue_runtime != null
		and rogue_runtime.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.apply_remote_flow_state(step_id, state, seconds)


func get_flow_state_snapshot() -> Dictionary:
	var rogue_runtime := get_rogue_runtime()
	return rogue_runtime.get_flow_state_snapshot() if rogue_runtime != null else {}


func get_multiplayer_defeat_reason() -> String:
	var rogue_runtime := get_rogue_runtime()
	return (
		rogue_runtime.get_multiplayer_defeat_reason()
		if rogue_runtime != null
		else ""
	)


func apply_remote_defeat_with_reason(failure_reason: String) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.apply_remote_defeat_with_reason(failure_reason)


func apply_remote_defeat() -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.apply_remote_defeat()


func apply_remote_victory() -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.apply_remote_victory()


func apply_remote_enemy_count(alive_count: int) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.apply_remote_enemy_count(alive_count)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var rogue_runtime := get_rogue_runtime()
	return (
		rogue_runtime.try_purchase_skill1_for_peer(peer_id)
		if rogue_runtime != null
		else MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	)


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.apply_skill1_purchase_state(
			peer_id,
			current_xirang,
			skill1_unlocked,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.show_local_skill1_purchase_result(result_code)


func show_debug_collectible_grant_result(
	config_path: String,
	success: bool
) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.show_debug_collectible_grant_result(config_path, success)


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	var rogue_runtime := get_rogue_runtime()
	if rogue_runtime != null:
		rogue_runtime.show_simple_crafting_result(
			recipe_id,
			result,
			request_token
		)


func handle_profile_upgrade_requested(stat_type: int) -> void:
	profile_upgrade_requested.emit(stat_type)


func handle_profile_inventory_item_use_requested(slot_index: int) -> void:
	profile_inventory_item_use_requested.emit(slot_index)


func handle_profile_inventory_item_discard_requested(slot_index: int) -> void:
	profile_inventory_item_discard_requested.emit(slot_index)


func handle_profile_simple_crafting_requested(
	recipe_id: StringName,
	request_token: int
) -> void:
	profile_simple_crafting_requested.emit(recipe_id, request_token)


func handle_profile_simple_crafting_cancel_requested(request_token: int) -> void:
	profile_simple_crafting_cancel_requested.emit(request_token)
