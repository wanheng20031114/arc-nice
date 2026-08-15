extends Node
class_name StandardMerchantCoordinator

signal merchant_active_changed(active: bool)

var runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var multiplayer_local_peer_id := 0
var merchants_enabled := true
var luoxi_collectible_claim_counts: Dictionary = {}

var _merchant: ZhuangfangyiMerchant = null
var _luoxi_merchant: LuoxiMerchant = null
var _player_roster: StandardPlayerRosterCoordinator = null
var _multiplayer_mode_adapter: StandardMultiplayerModeAdapter = null
var _run_state: RunStateStore = null
var _bound := false


func bind_dependencies(
	merchant: ZhuangfangyiMerchant,
	luoxi_merchant: LuoxiMerchant,
	player_roster: StandardPlayerRosterCoordinator,
	multiplayer_mode_adapter: StandardMultiplayerModeAdapter,
	run_state: RunStateStore,
	mode: int,
	local_peer_id: int,
	standard_merchants_enabled: bool,
	initial_claim_counts: Dictionary = {}
) -> void:
	merchants_enabled = standard_merchants_enabled
	runtime_mode = mode
	multiplayer_local_peer_id = local_peer_id
	_merchant = merchant if merchants_enabled else null
	_luoxi_merchant = luoxi_merchant if merchants_enabled else null
	_player_roster = player_roster
	_multiplayer_mode_adapter = multiplayer_mode_adapter
	_run_state = run_state
	luoxi_collectible_claim_counts = initial_claim_counts
	_bound = (
		_player_roster != null
		and _multiplayer_mode_adapter != null
		and _run_state != null
		and (
			not merchants_enabled
			or (_merchant != null and _luoxi_merchant != null)
		)
	)
	if _merchant != null:
		_merchant.bind_multiplayer_mode_adapter(_multiplayer_mode_adapter)
	if _luoxi_merchant != null:
		_luoxi_merchant.bind_multiplayer_mode_adapter(
			_multiplayer_mode_adapter
		)


func is_bound() -> bool:
	return _bound


func set_runtime_context(mode: int, local_peer_id: int) -> void:
	runtime_mode = mode
	multiplayer_local_peer_id = local_peer_id


func get_merchant() -> ZhuangfangyiMerchant:
	return _merchant


func get_luoxi_merchant() -> LuoxiMerchant:
	return _luoxi_merchant


func replace_luoxi_collectible_claim_counts(claim_counts: Dictionary) -> void:
	luoxi_collectible_claim_counts = claim_counts


func restore_peer_state(old_peer_id: int, new_peer_id: int) -> void:
	if not luoxi_collectible_claim_counts.has(old_peer_id):
		return
	luoxi_collectible_claim_counts[new_peer_id] = (
		luoxi_collectible_claim_counts[old_peer_id]
	)
	luoxi_collectible_claim_counts.erase(old_peer_id)


func set_active(active: bool) -> void:
	var changed := set_local_merchants_active(active)
	if not changed:
		return
	if runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		merchant_active_changed.emit(active)


func set_local_merchants_active(active: bool) -> bool:
	var changed := false
	if _merchant != null and _merchant.is_active != active:
		_merchant.set_active(active)
		changed = true
	if _luoxi_merchant != null and _luoxi_merchant.is_active != active:
		if active:
			luoxi_collectible_claim_counts.clear()
			_luoxi_merchant.reset_intermission_state()
		_luoxi_merchant.set_active(active)
		changed = true
	return changed


func allows_debug_collectible_grants() -> bool:
	return OS.is_debug_build()


func grant_debug_collectible(config_path: String) -> bool:
	if not allows_debug_collectible_grants():
		return false
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	if item == null:
		return false
	if (
		runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and multiplayer_local_peer_id > 0
	):
		return _run_state.try_add_item_for_peer(
			multiplayer_local_peer_id,
			item
		)
	return _run_state.try_add_item(item)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var player_instance := _player_roster.get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	if not player_instance.has_skill1():
		return MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	if player_instance.is_skill1_upgrade_maxed():
		return MerchantPurchaseResult.SkillUpgrade.UPGRADE_MAXED
	var free_upgrade := player_instance.has_collectible_effect(
		PickupConfig.COLLECTIBLE_EFFECT_ADMIN_DOLL
	)
	if not player_instance.try_upgrade_skill1(free_upgrade):
		return MerchantPurchaseResult.SkillUpgrade.INSUFFICIENT_XIRANG
	return MerchantPurchaseResult.SkillUpgrade.UPGRADE_SUCCESS


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	var player_instance := _player_roster.get_player_for_peer(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return
	if player_instance.current_xirang != current_xirang:
		player_instance.set_xirang_balance(current_xirang)
	if skill1_unlocked and not player_instance.has_skill1():
		player_instance.unlock_skill1()
	if skill1_upgrade_level >= 0:
		player_instance.apply_skill1_upgrade_state(
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	if _merchant == null:
		return
	_merchant.show_purchase_result(result_code)


func request_luoxi_collectible_choice(
	choice_index: int,
	config_path: String = ""
) -> void:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := (
		multiplayer_local_peer_id
		if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	var resolved_config_path := _resolve_luoxi_collectible_path(
		choice_index,
		config_path
	)
	var result_code := try_claim_luoxi_collectible_for_peer(
		peer_id,
		resolved_config_path
	)
	show_local_luoxi_collectible_result(result_code)


func request_luoxi_collectible_refresh() -> void:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var peer_id := (
		multiplayer_local_peer_id
		if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	var player_instance := _get_local_or_peer_player(peer_id)
	var result_code := try_refresh_luoxi_collectibles_for_peer(peer_id)
	show_local_luoxi_refresh_result(
		result_code,
		get_luoxi_collectible_refresh_count(peer_id),
		player_instance.current_xirang if player_instance != null else 0
	)


func try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	var player_instance := _get_local_or_peer_player(peer_id)
	if (
		player_instance == null
		or not is_instance_valid(player_instance)
		or _luoxi_merchant == null
	):
		return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	if has_luoxi_collectible_claimed(peer_id):
		return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	return _luoxi_merchant.try_purchase_refresh_for_player(player_instance)


func get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	if _luoxi_merchant == null:
		return 0
	return _luoxi_merchant.get_player_refresh_count(maxi(peer_id, 0))


func try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int:
	var player_instance := _get_local_or_peer_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER

	var claim_key := maxi(peer_id, 0)
	if (
		get_luoxi_collectible_claim_count(claim_key)
		>= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	):
		return MerchantPurchaseResult.CollectibleClaim.ALREADY_CLAIMED

	var config_path := ""
	if typeof(config_path_or_choice) == TYPE_INT:
		config_path = _resolve_luoxi_collectible_path(
			int(config_path_or_choice),
			""
		)
	else:
		config_path = String(config_path_or_choice)
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	if item == null:
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	if not player_instance.is_collectible_compatible(item):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	if not LuoxiMerchant.is_collectible_available_for_inventory(
		item,
		_run_state,
		peer_id
	):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER

	var stored := (
		_run_state.try_add_item_for_peer(peer_id, item)
		if peer_id > 0
		else _run_state.try_add_item(item)
	)
	if not stored:
		return MerchantPurchaseResult.CollectibleClaim.INVENTORY_FULL

	record_luoxi_collectible_claim(claim_key)
	return MerchantPurchaseResult.CollectibleClaim.SUCCESS


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return (
		get_luoxi_collectible_claim_count(peer_id)
		>= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func get_luoxi_collectible_claim_count(peer_id: int) -> int:
	return int(luoxi_collectible_claim_counts.get(maxi(peer_id, 0), 0))


func record_luoxi_collectible_claim(peer_id: int) -> void:
	var claim_key := maxi(peer_id, 0)
	luoxi_collectible_claim_counts[claim_key] = mini(
		get_luoxi_collectible_claim_count(claim_key) + 1,
		LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func mark_luoxi_collectible_claimed(peer_id: int) -> void:
	luoxi_collectible_claim_counts[maxi(peer_id, 0)] = (
		LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func show_local_luoxi_collectible_result(result_code: int) -> void:
	if _luoxi_merchant == null:
		return
	_luoxi_merchant.show_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if _luoxi_merchant == null:
		return
	_luoxi_merchant.show_refresh_result(
		result_code,
		refresh_count,
		current_xirang
	)


func _get_local_or_peer_player(peer_id: int) -> Player:
	return _player_roster.get_player_for_peer_or_singleplayer(peer_id)


func _resolve_luoxi_collectible_path(
	choice_index: int,
	config_path: String
) -> String:
	if not config_path.is_empty():
		return config_path
	var item := LuoxiMerchant.get_collectible_for_choice(choice_index)
	return item.resource_path if item != null else ""
