extends MultiplayerModeAdapter
class_name StandardMultiplayerModeAdapter


func get_standard_runtime() -> StandardGame:
	return runtime as StandardGame


func accepts_game_mode_id(mode_id: int) -> bool:
	return mode_id == GameModeCatalog.MODE_STANDARD


func allows_debug_collectible_grants() -> bool:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime != null
		and standard_runtime.allows_debug_collectible_grants()
	)


func is_terminal_combat_state() -> bool:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime != null
		and standard_runtime.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_remote_flow_state(step_id, state, seconds)


func get_flow_state_snapshot() -> Dictionary:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime.get_flow_state_snapshot()
		if standard_runtime != null
		else {}
	)


func apply_remote_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_remote_boss_started(
			net_id,
			boss_config,
			spawn_position
		)


func apply_remote_defeat() -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_remote_defeat()


func apply_remote_victory() -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_remote_victory()


func apply_remote_enemy_count(alive_count: int) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_remote_enemy_count(alive_count)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime.try_purchase_skill1_for_peer(peer_id)
		if standard_runtime != null
		else MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	)


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_skill1_purchase_state(
			peer_id,
			current_xirang,
			skill1_unlocked,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.show_local_skill1_purchase_result(result_code)


func show_debug_collectible_grant_result(
	config_path: String,
	success: bool
) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.show_debug_collectible_grant_result(
			config_path,
			success
		)


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.show_simple_crafting_result(
			recipe_id,
			result,
			request_token
		)


func apply_remote_merchant_active(active: bool) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.apply_remote_merchant_active(active)


func get_luoxi_merchant() -> LuoxiMerchant:
	var standard_runtime := get_standard_runtime()
	return standard_runtime.luoxi_merchant if standard_runtime != null else null


func prewarm_mode_runtime_data() -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		await LuoxiMerchant.prewarm_collectible_cache(standard_runtime)


func runtime_try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime.try_refresh_luoxi_collectibles_for_peer(peer_id)
		if standard_runtime != null
		else MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	)


func runtime_get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime.get_luoxi_collectible_refresh_count(peer_id)
		if standard_runtime != null
		else 0
	)


func runtime_try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime.try_claim_luoxi_collectible_for_peer(
			peer_id,
			config_path_or_choice
		)
		if standard_runtime != null
		else MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	)


func runtime_has_luoxi_collectible_claimed(peer_id: int) -> bool:
	var standard_runtime := get_standard_runtime()
	return (
		standard_runtime != null
		and standard_runtime.has_luoxi_collectible_claimed(peer_id)
	)


func runtime_record_luoxi_collectible_claim(peer_id: int) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.record_luoxi_collectible_claim(peer_id)


func runtime_mark_luoxi_collectible_claimed(peer_id: int) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.mark_luoxi_collectible_claimed(peer_id)


func show_local_luoxi_collectible_result(result_code: int) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.show_local_luoxi_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	var standard_runtime := get_standard_runtime()
	if standard_runtime != null:
		standard_runtime.show_local_luoxi_refresh_result(
			result_code,
			refresh_count,
			current_xirang
		)


func request_luoxi_collectible_choice(
	choice_index: int,
	config_path: String,
	offer_revision: int
) -> bool:
	if super.request_luoxi_collectible_choice(
		choice_index,
		config_path,
		offer_revision
	):
		return true
	var standard_runtime := runtime as StandardGame
	if standard_runtime == null:
		return false
	standard_runtime.request_luoxi_collectible_choice(
		choice_index,
		config_path
	)
	return true


func request_luoxi_collectible_refresh(offer_revision: int) -> bool:
	if super.request_luoxi_collectible_refresh(offer_revision):
		return true
	var standard_runtime := runtime as StandardGame
	if standard_runtime == null:
		return false
	standard_runtime.request_luoxi_collectible_refresh()
	return true


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if has_multiplayer_session():
		return super.has_luoxi_collectible_claimed(peer_id)
	var standard_runtime := runtime as StandardGame
	return (
		standard_runtime != null
		and standard_runtime.has_luoxi_collectible_claimed(peer_id)
	)
