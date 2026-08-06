extends Node
class_name MultiplayerModeAdapter

signal merchant_active_changed(active: bool)
signal flow_state_changed(
	step_id: StringName,
	state: int,
	countdown_seconds: int
)
signal wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
)
signal boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
)
signal defeat_started
signal victory_started
signal revive_all_requested
signal profile_upgrade_requested(stat_type: int)
signal profile_inventory_item_use_requested(slot_index: int)
signal profile_inventory_item_discard_requested(slot_index: int)
signal profile_simple_crafting_requested(
	recipe_id: StringName,
	request_token: int
)
signal profile_simple_crafting_cancel_requested(request_token: int)
signal return_to_lobby_requested

var runtime: CombatRuntimeBase = null
var multiplayer_session: MultiplayerGameplaySession = null


func _ready() -> void:
	bind_runtime(get_parent() as CombatRuntimeBase)


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	runtime = runtime_instance


func attach_multiplayer_session(session: MultiplayerGameplaySession) -> void:
	multiplayer_session = session


func detach_multiplayer_session(session: MultiplayerGameplaySession) -> void:
	if multiplayer_session == session:
		multiplayer_session = null


func is_bound() -> bool:
	return runtime != null and is_instance_valid(runtime)


func has_multiplayer_session() -> bool:
	return (
		multiplayer_session != null
		and is_instance_valid(multiplayer_session)
	)


func accepts_game_mode_id(_mode_id: int) -> bool:
	return false


func prewarm_mode_runtime_data() -> void:
	pass


## Modes without intermission merchants deliberately ignore the shared wire
## event. Merchant presentation belongs to the concrete mode adapter, not the
## neutral combat runtime contract.
func apply_remote_merchant_active(_active: bool) -> void:
	pass


func allows_debug_collectible_grants() -> bool:
	return false


func allows_player_respawn(_peer_id: int) -> bool:
	return true


func allows_enemy_pickup_drops() -> bool:
	return true


## Resolves a mode-owned combat target used by neutral projectile replication.
## Standard and rogue modes have no plant-style world target and return null.
func get_network_projectile_world_target(_net_id: int) -> Node2D:
	return null


func is_terminal_combat_state() -> bool:
	return false


func consume_next_player_respawn_delay(_peer_id: int) -> float:
	return 10.0


func update_player_respawn_countdown(
	_peer_id: int,
	_seconds_left: int
) -> void:
	pass


func clear_player_respawn_countdown(_peer_id: int) -> void:
	pass


func get_fixed_multiplayer_respawn_position(_peer_id: int) -> Variant:
	return null


func apply_remote_flow_state(
	_step_id: StringName,
	_state: int,
	_seconds: int
) -> void:
	pass


func get_flow_state_snapshot() -> Dictionary:
	return {}


func supports_multiplayer_wave_progress() -> bool:
	return false


func request_authoritative_wave_start(_requester_peer_id: int) -> bool:
	return false


func get_wave_progress_snapshot() -> Dictionary:
	return {}


func apply_remote_wave_progress(
	_wave_number: int,
	_defeated: int,
	_escaped: int,
	_resolved: int,
	_total: int
) -> void:
	pass


func apply_remote_boss_started(
	_net_id: int,
	_boss_config: BossConfig,
	_spawn_position: Vector2
) -> void:
	pass


func get_multiplayer_defeat_reason() -> String:
	return ""


func apply_remote_defeat_with_reason(_failure_reason: String) -> void:
	apply_remote_defeat()


func apply_remote_defeat() -> void:
	pass


func apply_remote_victory() -> void:
	pass


func apply_remote_enemy_count(_alive_count: int) -> void:
	pass


func try_purchase_skill1_for_peer(_peer_id: int) -> int:
	return MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER


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


func show_debug_collectible_grant_result(
	_config_path: String,
	_success: bool
) -> void:
	pass


func show_simple_crafting_result(
	_recipe_id: StringName,
	_result: StringName,
	_request_token: int
) -> void:
	pass


func request_debug_collectible(config_path: String) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_debug_collectible(config_path)
	return true


func request_skill1_purchase() -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_multiplayer_skill1_purchase()
	return true


func uses_authoritative_luoxi_offers() -> bool:
	return (
		has_multiplayer_session()
		and multiplayer_session.uses_authoritative_luoxi_offers()
	)


func request_luoxi_collectible_offer() -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_luoxi_collectible_offer()
	return true


func request_luoxi_collectible_choice(
	choice_index: int,
	config_path: String,
	offer_revision: int
) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_luoxi_collectible_choice(
		choice_index,
		config_path,
		offer_revision
	)
	return true


func request_luoxi_collectible_refresh(offer_revision: int) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_luoxi_collectible_refresh(offer_revision)
	return true


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return (
		has_multiplayer_session()
		and multiplayer_session.has_luoxi_collectible_claimed(peer_id)
	)


## Host-authoritative merchant operations deliberately live on the mode
## adapter rather than CombatRuntimeBase. Modes without this merchant keep the
## explicit fail-closed defaults below and never inherit merchant semantics.
func runtime_try_refresh_luoxi_collectibles_for_peer(_peer_id: int) -> int:
	return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER


func get_luoxi_merchant() -> LuoxiMerchant:
	return null


func runtime_get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
	return 0


func runtime_try_claim_luoxi_collectible_for_peer(
	_peer_id: int,
	_config_path_or_choice: Variant
) -> int:
	return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER


func runtime_has_luoxi_collectible_claimed(_peer_id: int) -> bool:
	return false


func runtime_record_luoxi_collectible_claim(_peer_id: int) -> void:
	pass


func runtime_mark_luoxi_collectible_claimed(_peer_id: int) -> void:
	pass


func show_local_luoxi_collectible_result(_result_code: int) -> void:
	pass


func show_local_luoxi_refresh_result(
	_result_code: int,
	_refresh_count: int,
	_current_xirang: int
) -> void:
	pass


func runtime_supports_luoxi_special_game() -> bool:
	return false


func runtime_try_start_luoxi_special_game_for_peer(
	_peer_id: int
) -> Dictionary:
	return {"result_code": 1}


func runtime_try_reveal_luoxi_special_game_card_for_peer(
	_peer_id: int,
	_session_revision: int,
	_card_index: int
) -> Dictionary:
	return {"result_code": 1}


func runtime_try_finish_luoxi_special_game_for_peer(
	_peer_id: int,
	_session_revision: int
) -> Dictionary:
	return {"result_code": 1}


func show_local_luoxi_special_game_started(_result: Dictionary) -> void:
	pass


func show_local_luoxi_special_game_card_revealed(_result: Dictionary) -> void:
	pass


func show_local_luoxi_special_game_finished(_result: Dictionary) -> void:
	pass
