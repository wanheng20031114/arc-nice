extends MultiplayerModeAdapter
class_name StandardMultiplayerModeAdapter

const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"

var _wave_runtime: WaveCombatRuntimeBase = null
var _player_roster: StandardPlayerRosterCoordinator = null
var _boss_coordinator: StandardBossCoordinator = null
var _merchant_coordinator: StandardMerchantCoordinator = null
var _profile_panel: StandardPlayerProfilePanel = null
var _debug_collectible_window: DebugCollectibleWindow = null
var _wave_hud: StandardWaveHUD = null


func configure_standard_multiplayer(
	runtime_instance: WaveCombatRuntimeBase,
	merchant: StandardMerchantCoordinator,
	player_roster: StandardPlayerRosterCoordinator,
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary
) -> void:
	_bind_runtime_dependencies(runtime_instance, merchant, player_roster)
	if _wave_runtime == null:
		return
	_wave_runtime.runtime_mode = mode as CombatRuntimeBase.RuntimeMode
	_wave_runtime.multiplayer_local_peer_id = local_peer_id
	if _merchant_coordinator != null:
		_merchant_coordinator.set_runtime_context(
			_wave_runtime.runtime_mode,
			_wave_runtime.multiplayer_local_peer_id
		)
	if _player_roster != null:
		_player_roster.configure_peer_metadata(
			player_names,
			player_character_ids
		)


func bind_standard_dependencies(
	runtime_instance: WaveCombatRuntimeBase,
	player_roster: StandardPlayerRosterCoordinator,
	boss: StandardBossCoordinator,
	merchant: StandardMerchantCoordinator,
	profile_panel: StandardPlayerProfilePanel,
	debug_collectible_window: DebugCollectibleWindow,
	wave_hud: StandardWaveHUD
) -> void:
	_bind_runtime_dependencies(runtime_instance, merchant, player_roster)
	_boss_coordinator = boss
	_profile_panel = profile_panel
	_debug_collectible_window = debug_collectible_window
	_wave_hud = wave_hud
	_connect_runtime_signals()


func is_standard_bound() -> bool:
	return (
		is_bound()
		and _wave_runtime != null
		and _player_roster != null
		and _boss_coordinator != null
		and _merchant_coordinator != null
		and _profile_panel != null
		and _debug_collectible_window != null
		and _wave_hud != null
	)


func _bind_runtime_dependencies(
	runtime_instance: WaveCombatRuntimeBase,
	merchant: StandardMerchantCoordinator,
	player_roster: StandardPlayerRosterCoordinator
) -> void:
	_wave_runtime = runtime_instance
	_merchant_coordinator = merchant
	_player_roster = player_roster
	bind_runtime(runtime_instance)


func _connect_runtime_signals() -> void:
	if _player_roster != null:
		if not _player_roster.multiplayer_player_died.is_connected(
			_on_multiplayer_player_died
		):
			_player_roster.multiplayer_player_died.connect(
				_on_multiplayer_player_died
			)
		if not _player_roster.all_players_dead.is_connected(
			_on_all_multiplayer_players_dead
		):
			_player_roster.all_players_dead.connect(
				_on_all_multiplayer_players_dead
			)
		if not _player_roster.peer_restored.is_connected(
			_on_multiplayer_peer_restored
		):
			_player_roster.peer_restored.connect(_on_multiplayer_peer_restored)
	if (
		_merchant_coordinator != null
		and not _merchant_coordinator.merchant_active_changed.is_connected(
			_on_merchant_active_changed
		)
	):
		_merchant_coordinator.merchant_active_changed.connect(
			_on_merchant_active_changed
		)
	if _boss_coordinator != null:
		if not _boss_coordinator.flow_state_requested.is_connected(
			_on_boss_flow_state_requested
		):
			_boss_coordinator.flow_state_requested.connect(
				_on_boss_flow_state_requested
			)
		if not _boss_coordinator.boss_started.is_connected(_on_boss_started):
			_boss_coordinator.boss_started.connect(_on_boss_started)


func accepts_game_mode_id(mode_id: int) -> bool:
	return mode_id == GameModeCatalog.MODE_STANDARD


func allows_debug_collectible_grants() -> bool:
	return (
		_merchant_coordinator != null
		and _merchant_coordinator.allows_debug_collectible_grants()
	)


func is_terminal_combat_state() -> bool:
	return (
		_wave_runtime != null
		and _wave_runtime.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	if _wave_runtime != null:
		_wave_runtime.apply_remote_flow_state(step_id, state, seconds)


func get_flow_state_snapshot() -> Dictionary:
	return _wave_runtime.get_flow_state_snapshot() if _wave_runtime != null else {}


func apply_remote_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	if (
		_wave_runtime == null
		or _boss_coordinator == null
		or _wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or boss_config == null
	):
		return
	_wave_runtime.current_flow_step = boss_config
	_boss_coordinator.apply_remote_started(
		net_id,
		boss_config,
		spawn_position
	)


func apply_remote_defeat() -> void:
	if _wave_runtime != null:
		_wave_runtime.apply_remote_defeat()


func apply_remote_victory() -> void:
	if _wave_runtime != null:
		_wave_runtime.apply_remote_victory()


func apply_remote_enemy_count(alive_count: int) -> void:
	if _wave_runtime != null:
		_wave_runtime.apply_remote_enemy_count(alive_count)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	return (
		_merchant_coordinator.try_purchase_skill1_for_peer(peer_id)
		if _merchant_coordinator != null
		else MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	)


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.apply_skill1_purchase_state(
			peer_id,
			current_xirang,
			skill1_unlocked,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.show_local_skill1_purchase_result(result_code)


func show_debug_collectible_grant_result(
	config_path: String,
	success: bool
) -> void:
	if _debug_collectible_window != null:
		_debug_collectible_window.show_grant_result(config_path, success)


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	if _profile_panel != null:
		_profile_panel.show_simple_crafting_result(
			recipe_id,
			result,
			request_token
		)


func apply_remote_merchant_active(active: bool) -> void:
	if _merchant_coordinator == null:
		return
	_merchant_coordinator.set_local_merchants_active(active)
	if (
		_wave_runtime == null
		or _wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return
	if (
		not active
		and _wave_runtime.wave_state in [
			CombatFlowState.State.PRE_WAVE,
			CombatFlowState.State.INTERMISSION,
		]
	):
		_wave_runtime.state_timer.stop()


func get_luoxi_merchant() -> LuoxiMerchant:
	return (
		_merchant_coordinator.get_luoxi_merchant()
		if _merchant_coordinator != null
		else null
	)


func prewarm_mode_runtime_data(preparation_generation: int) -> void:
	if _wave_runtime != null:
		await LuoxiMerchant.prewarm_collectible_cache(
			_wave_runtime,
			preparation_generation
		)


func runtime_try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	return (
		_merchant_coordinator.try_refresh_luoxi_collectibles_for_peer(peer_id)
		if _merchant_coordinator != null
		else MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	)


func runtime_get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	return (
		_merchant_coordinator.get_luoxi_collectible_refresh_count(peer_id)
		if _merchant_coordinator != null
		else 0
	)


func runtime_try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int:
	return (
		_merchant_coordinator.try_claim_luoxi_collectible_for_peer(
			peer_id,
			config_path_or_choice
		)
		if _merchant_coordinator != null
		else MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	)


func runtime_has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return (
		_merchant_coordinator != null
		and _merchant_coordinator.has_luoxi_collectible_claimed(peer_id)
	)


func runtime_record_luoxi_collectible_claim(peer_id: int) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.record_luoxi_collectible_claim(peer_id)


func runtime_mark_luoxi_collectible_claimed(peer_id: int) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.mark_luoxi_collectible_claimed(peer_id)


func show_local_luoxi_collectible_result(result_code: int) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.show_local_luoxi_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.show_local_luoxi_refresh_result(
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
	if _merchant_coordinator == null:
		return false
	_merchant_coordinator.request_luoxi_collectible_choice(
		choice_index,
		config_path
	)
	return true


func request_luoxi_collectible_refresh(offer_revision: int) -> bool:
	if super.request_luoxi_collectible_refresh(offer_revision):
		return true
	if _merchant_coordinator == null:
		return false
	_merchant_coordinator.request_luoxi_collectible_refresh()
	return true


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if has_multiplayer_session():
		return super.has_luoxi_collectible_claimed(peer_id)
	return runtime_has_luoxi_collectible_claimed(peer_id)


func handle_debug_collectible_requested(config_path: String) -> void:
	if config_path.is_empty() or _merchant_coordinator == null:
		return
	if (
		_wave_runtime != null
		and _wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and request_debug_collectible(config_path)
	):
		return
	show_debug_collectible_grant_result(
		config_path,
		_merchant_coordinator.grant_debug_collectible(config_path)
	)


func handle_return_to_lobby_requested() -> void:
	if (
		_wave_runtime != null
		and _wave_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		_wave_runtime.prepare_for_scene_teardown()
		get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
		return
	return_to_lobby_requested.emit()


func _on_profile_multiplayer_upgrade_requested(stat_type: int) -> void:
	profile_upgrade_requested.emit(stat_type)


func _on_profile_multiplayer_inventory_item_use_requested(
	slot_index: int
) -> void:
	profile_inventory_item_use_requested.emit(slot_index)


func _on_profile_multiplayer_inventory_item_discard_requested(
	slot_index: int
) -> void:
	profile_inventory_item_discard_requested.emit(slot_index)


func _on_profile_multiplayer_simple_crafting_requested(
	recipe_id: StringName,
	request_token: int
) -> void:
	profile_simple_crafting_requested.emit(recipe_id, request_token)


func _on_profile_multiplayer_simple_crafting_cancel_requested(
	request_token: int
) -> void:
	profile_simple_crafting_cancel_requested.emit(request_token)


func _on_multiplayer_player_died(_peer_id: int) -> void:
	if (
		_wave_runtime == null
		or _player_roster == null
		or _wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or is_terminal_combat_state()
	):
		return
	_player_roster.schedule_multiplayer_defeat_check()


func _on_all_multiplayer_players_dead() -> void:
	if (
		_wave_runtime == null
		or _wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or is_terminal_combat_state()
	):
		return
	_wave_runtime._enter_defeat()


func _on_multiplayer_peer_restored(old_peer_id: int, new_peer_id: int) -> void:
	if _merchant_coordinator != null:
		_merchant_coordinator.restore_peer_state(old_peer_id, new_peer_id)


func _on_merchant_active_changed(active: bool) -> void:
	merchant_active_changed.emit(active)


func _on_boss_flow_state_requested(
	state: CombatFlowState.State,
	boss_config: BossConfig,
	is_remote: bool
) -> void:
	if _wave_runtime == null or _boss_coordinator == null or _wave_hud == null:
		return
	_wave_runtime.state_timer.stop()
	_wave_runtime.wave_state = state
	_wave_runtime._set_intermission_services_active(false)
	_wave_hud.hide_all()
	_boss_coordinator.active_boss_config = boss_config
	if is_remote:
		return
	match state:
		CombatFlowState.State.BOSS_INTRO:
			_wave_runtime.current_flow_step = boss_config
			_wave_runtime.enemy_spawn_timer.stop()
			_wave_runtime._clear_pending_enemy_spawn_queue()
			_wave_runtime.clear_active_wave_enemies()
			_wave_runtime.reset_wave_progress(1, 1)
			_wave_runtime._emit_multiplayer_flow_state(state)
		CombatFlowState.State.BOSS_ACTIVE:
			pass


func _on_boss_started(boss: LinglanBoss, boss_config: BossConfig) -> void:
	if _wave_runtime == null or _boss_coordinator == null:
		return
	if boss == null or boss_config == null:
		return
	_wave_runtime.register_active_wave_enemy(boss)
	var boss_net_id := _wave_runtime._register_multiplayer_enemy_instance(
		boss,
		_boss_coordinator.get_boss_enemy_config(boss_config),
		boss.global_position,
		false
	)
	_wave_runtime._emit_multiplayer_flow_state(
		CombatFlowState.State.BOSS_ACTIVE
	)
	if (
		_wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		return
	boss_started.emit(boss_net_id, boss_config, boss.global_position)
	_rebroadcast_boss_started_after_sync_window(boss_net_id, boss_config)


func _rebroadcast_boss_started_after_sync_window(
	boss_net_id: int,
	boss_config: BossConfig
) -> void:
	if boss_net_id <= 0 or boss_config == null:
		return
	await get_tree().create_timer(0.75).timeout
	if (
		_wave_runtime == null
		or _boss_coordinator == null
		or _wave_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or _wave_runtime.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or _boss_coordinator.linglan_boss == null
		or not is_instance_valid(_boss_coordinator.linglan_boss)
	):
		return
	boss_started.emit(
		boss_net_id,
		boss_config,
		_boss_coordinator.linglan_boss.global_position
	)
