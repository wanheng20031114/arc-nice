extends MultiplayerModeAdapter
class_name TowerDefenseMultiplayerModeAdapter

const MAIN_MENU_SCENE_PATH := "res://scene/main_menu.tscn"
const MultiplayerReconnectTypesScript := preload(
	"res://scene/multiplayer/reconnect/multiplayer_reconnect_types.gd"
)

signal test_arena_manual_night_changed(enabled: bool)
signal base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
)
signal plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal plant_placement_rejected(
	request_id: int,
	requester_peer_id: int,
	reason: StringName
)
signal plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
)
signal plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
)
signal plant_damage_applied(
	net_id: int,
	applied_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	world_position: Vector2
)
signal plant_healing_applied(
	net_id: int,
	applied_healing: int,
	world_position: Vector2
)
signal plant_removed(net_id: int, was_destroyed: bool)
signal terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
)
signal plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
)
signal inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
)
signal inventory_changed(peer_id: int)
signal xiaocong_interaction_requested
signal xiaocong_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
)
signal xiaocong_collectible_requested(choice_index: int)
signal xiaocong_fate_state_changed(state: Dictionary)
signal rogue_exploration_snapshot_changed(snapshot: Dictionary)

var _tower_runtime: TowerDefenseGame = null
var _campaign_coordinator: TowerDefenseCampaignCoordinator = null
var _enemy_coordinator: TowerDefenseEnemyCoordinator = null
var _home_defense_coordinator: TowerDefenseHomeDefenseCoordinator = null
var _plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator = null
var _player_roster_coordinator: TowerDefensePlayerRosterCoordinator = null
var _boss_coordinator: TowerDefenseBossCoordinator = null
var _fate_coordinator: FateCoordinator = null
var _fate_flow_coordinator: TowerDefenseFateFlowCoordinator = null
var _fate_manager: TowerDefenseFateManager = null
var _presentation_coordinator: TowerDefensePresentationCoordinator = null
var _profile_panel: TowerDefensePlayerProfilePanel = null
var _debug_collectible_window: DebugCollectibleWindow = null
var _merchant: ZhuangfangyiMerchant = null
var _luoxi_merchant: TowerDefenseLuoxiMerchant = null
var _luoxi_special_game_coordinator: LuoxiSpecialGameCoordinator = null
var _run_state: RunStateStore = null
var _research_coordinator: ResearchCoordinator = null
var _plant_placement_coordinator: TowerDefensePlantPlacementCoordinator = null
var _rogue_exploration_coordinator: TowerDefenseRogueExplorationCoordinator = null
var _state_timer: Timer = null
var _merchant_intermission_active := false
var _luoxi_collectible_claim_counts: Dictionary[int, int] = {}


func configure_tower_multiplayer(
	runtime_instance: TowerDefenseGame,
	mode: int,
	local_peer_id: int,
	player_names: Dictionary,
	player_character_ids: Dictionary
) -> void:
	_bind_tower_runtime(runtime_instance)
	if _tower_runtime == null:
		return
	_tower_runtime.runtime_mode = mode as CombatRuntimeBase.RuntimeMode
	_tower_runtime.multiplayer_local_peer_id = local_peer_id
	_tower_runtime.multiplayer_player_names = player_names.duplicate()
	_tower_runtime.multiplayer_player_character_ids = player_character_ids.duplicate()
	if _player_roster_coordinator != null and _player_roster_coordinator.is_bound():
		_player_roster_coordinator.set_runtime_identity(mode, local_peer_id)
		_player_roster_coordinator.configure_roster(
			player_names,
			player_character_ids
		)


func bind_tower_dependencies(
	runtime_instance: TowerDefenseGame,
	campaign: TowerDefenseCampaignCoordinator,
	enemy: TowerDefenseEnemyCoordinator,
	home: TowerDefenseHomeDefenseCoordinator,
	plant: TowerDefensePlantRuntimeCoordinator,
	player_roster: TowerDefensePlayerRosterCoordinator,
	boss: TowerDefenseBossCoordinator,
	fate: FateCoordinator,
	fate_flow: TowerDefenseFateFlowCoordinator,
	fate_manager: TowerDefenseFateManager,
	presentation: TowerDefensePresentationCoordinator,
	profile_panel: TowerDefensePlayerProfilePanel,
	debug_window: DebugCollectibleWindow,
	merchant: ZhuangfangyiMerchant,
	luoxi_merchant: TowerDefenseLuoxiMerchant,
	luoxi_game: LuoxiSpecialGameCoordinator,
	run_state: RunStateStore,
	research: ResearchCoordinator,
	plant_placement: TowerDefensePlantPlacementCoordinator,
	state_timer: Timer
) -> void:
	_bind_tower_runtime(runtime_instance)
	_campaign_coordinator = campaign
	_enemy_coordinator = enemy
	_home_defense_coordinator = home
	_plant_runtime_coordinator = plant
	_player_roster_coordinator = player_roster
	_boss_coordinator = boss
	_fate_coordinator = fate
	_fate_flow_coordinator = fate_flow
	_fate_manager = fate_manager
	_presentation_coordinator = presentation
	_profile_panel = profile_panel
	_debug_collectible_window = debug_window
	_merchant = merchant
	_luoxi_merchant = luoxi_merchant
	_luoxi_special_game_coordinator = luoxi_game
	_run_state = run_state
	_research_coordinator = research
	_plant_placement_coordinator = plant_placement
	_state_timer = state_timer
	_connect_mode_signals()


func is_tower_bound() -> bool:
	return (
		is_bound()
		and _tower_runtime != null
		and _campaign_coordinator != null
		and _enemy_coordinator != null
		and _home_defense_coordinator != null
		and _plant_runtime_coordinator != null
		and _player_roster_coordinator != null
		and _boss_coordinator != null
		and _fate_coordinator != null
		and _fate_flow_coordinator != null
		and _fate_manager != null
		and _presentation_coordinator != null
		and _profile_panel != null
		and _debug_collectible_window != null
		and _merchant != null
		and _luoxi_merchant != null
		and _luoxi_special_game_coordinator != null
		and _run_state != null
		and _research_coordinator != null
		and _plant_placement_coordinator != null
		and _rogue_exploration_coordinator != null
		and _state_timer != null
	)


func bind_rogue_exploration_coordinator(
	coordinator: TowerDefenseRogueExplorationCoordinator
) -> void:
	assert(coordinator != null, "塔防多人适配器缺少地下探索协调器。")
	assert(
		_rogue_exploration_coordinator == null
		or _rogue_exploration_coordinator == coordinator,
		"塔防多人适配器不得在运行时更换地下探索协调器。"
	)
	_rogue_exploration_coordinator = coordinator
	if not coordinator.exploration_snapshot_changed.is_connected(
		rogue_exploration_snapshot_changed.emit
	):
		coordinator.exploration_snapshot_changed.connect(
			rogue_exploration_snapshot_changed.emit
		)


func get_rogue_exploration_coordinator() -> TowerDefenseRogueExplorationCoordinator:
	return _rogue_exploration_coordinator


func get_rogue_route() -> RogueRouteGame:
	return (
		_rogue_exploration_coordinator.get_route()
		if _rogue_exploration_coordinator != null
		else null
	)


func get_rogue_combat_coordinator() -> RogueCombatMultiplayerCoordinator:
	if _rogue_exploration_coordinator == null:
		return null
	return (
		_rogue_exploration_coordinator.get_combat_coordinator()
		as RogueCombatMultiplayerCoordinator
	)


func is_rogue_exploration_active() -> bool:
	return (
		_rogue_exploration_coordinator != null
		and _rogue_exploration_coordinator.is_exploration_active()
	)


func is_rogue_tower_world_suspended() -> bool:
	return (
		_rogue_exploration_coordinator != null
		and _rogue_exploration_coordinator.is_tower_runtime_suspended()
	)


## Rogue 接管塔防世界、Fate 黑屋运行或战役已经终结时，任何会修改
## Tower/RunState 的管理请求都不得落到权威运行时。Fate 仍需保留外层
## 玩家同步用于黑屋走动，因此该契约不能与 world suspension 合并。
func is_tower_management_suspended() -> bool:
	return (
		is_rogue_tower_world_suspended()
		or is_fate_interlude_active()
		or is_terminal_combat_state()
	)


## 重连玩家可能跨过了探索进入/返回的满血边界。先从 RunState 重算
## 当前永久属性与最大生命惩罚，再由 MpPlayerCoordinator 产生新的健康修订。
func refresh_players_from_run_state_for_rogue_boundary() -> void:
	if _player_roster_coordinator != null:
		_player_roster_coordinator.refresh_players_from_run_state()


func is_rogue_progression_contract_compatible(
	snapshot: Dictionary
) -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.progression_config != null
		and typeof(snapshot.get("progression_contract_hash")) == TYPE_STRING
		and str(snapshot["progression_contract_hash"])
		== tower_runtime.progression_config.compute_runtime_contract_hash()
	)


func export_rogue_exploration_snapshot_for_peer(
	peer_id: int
) -> Dictionary:
	if _rogue_exploration_coordinator == null:
		return {}
	return _rogue_exploration_coordinator.export_multiplayer_snapshot_for_peer(
		peer_id
	)


func apply_remote_rogue_exploration_snapshot(snapshot: Dictionary) -> bool:
	if (
		_rogue_exploration_coordinator == null
		or _tower_runtime == null
		or _tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return false
	return _rogue_exploration_coordinator.apply_multiplayer_snapshot(snapshot)


func handle_rogue_exploration_peer_left(peer_id: int) -> void:
	if (
		_rogue_exploration_coordinator != null
		and _tower_runtime != null
		and _tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		_rogue_exploration_coordinator.host_remove_disconnected_peer(peer_id)


func handle_rogue_exploration_peer_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> bool:
	if (
		_rogue_exploration_coordinator == null
		or _tower_runtime == null
		or _tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		return false
	return _rogue_exploration_coordinator.host_migrate_reconnected_peer(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id
	)


func handle_rogue_combat_reconnected_member_ready(
	old_peer_id: int,
	new_peer_id: int,
	outcome: MultiplayerReconnectTypesScript.RuntimeProjectionOutcome
) -> bool:
	if (
		_rogue_exploration_coordinator == null
		or _tower_runtime == null
		or _tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		return false
	if not _rogue_exploration_coordinator.is_exploration_active():
		return true
	return _rogue_exploration_coordinator.handle_reconnected_member_ready(
		old_peer_id,
		new_peer_id,
		outcome
	)


func _bind_tower_runtime(runtime_instance: TowerDefenseGame) -> void:
	_tower_runtime = runtime_instance
	bind_runtime(runtime_instance)


func accepts_game_mode_id(mode_id: int) -> bool:
	return mode_id in [
		GameModeCatalog.MODE_TOWER_DEFENSE,
		GameModeCatalog.MODE_TEST_ARENA_P1,
		GameModeCatalog.MODE_TEST_ARENA_P2,
		GameModeCatalog.MODE_TEST_ARENA_P1B,
		GameModeCatalog.MODE_TEST_ARENA_P1C,
		GameModeCatalog.MODE_TEST_ARENA_P1D,
		GameModeCatalog.MODE_TEST_ARENA_P1E,
	]


func allows_debug_collectible_grants() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.sandbox_free_building_enabled
	)


func is_terminal_combat_state() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and _campaign_coordinator.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func is_fate_interlude_active() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and _campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE
	)


func consume_next_player_respawn_delay(peer_id: int) -> float:
	return (
		_player_roster_coordinator.consume_next_respawn_delay(peer_id)
		if _player_roster_coordinator != null
		else 10.0
	)


func update_player_respawn_countdown(
	peer_id: int,
	seconds_left: int
) -> void:
	if _presentation_coordinator == null:
		return
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	var is_local := (
		(
			tower_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
			and peer_id == 0
		)
		or peer_id == tower_runtime.multiplayer_local_peer_id
	)
	var display_name := "玩家"
	if tower_runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		display_name = str(
			tower_runtime.multiplayer_player_names.get(
				peer_id,
				"玩家 %d" % peer_id
			)
		)
	_presentation_coordinator.update_player_respawn_countdown(
		peer_id,
		display_name,
		seconds_left,
		is_local
	)


func clear_player_respawn_countdown(peer_id: int) -> void:
	if _presentation_coordinator != null:
		_presentation_coordinator.clear_player_respawn_countdown(peer_id)


func get_fixed_multiplayer_respawn_position(peer_id: int) -> Variant:
	return (
		_player_roster_coordinator.get_fixed_respawn_position(peer_id)
		if _player_roster_coordinator != null
		else null
	)


func handle_player_died(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or _player_roster_coordinator == null:
		return
	cancel_luoxi_special_game_for_peer(peer_id)
	_enemy_coordinator.request_retarget()
	var is_singleplayer := (
		tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and peer_id == 0
	)
	var dead_player := (
		tower_runtime.player
		if is_singleplayer
		else tower_runtime.get_player_for_peer(peer_id)
	)
	if is_singleplayer:
		_plant_placement_coordinator.cancel_placement()
		_plant_placement_coordinator.set_flow_state(
			_campaign_coordinator.wave_state
		)
	if _presentation_coordinator != null:
		_presentation_coordinator.present_player_death(dead_player)
	if is_terminal_combat_state():
		return
	if (
		is_singleplayer
		or peer_id == tower_runtime.multiplayer_local_peer_id
	):
		if _presentation_coordinator != null:
			_presentation_coordinator.begin_local_spectator_camera(
				tower_runtime.player
			)
	if is_singleplayer:
		_player_roster_coordinator.local_player = tower_runtime.player
		_player_roster_coordinator.begin_singleplayer_respawn()


func handle_player_revived(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	_enemy_coordinator.request_retarget()
	clear_player_respawn_countdown(peer_id)
	if (
		(
			tower_runtime.runtime_mode
			== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
			and peer_id == 0
		)
		or peer_id == tower_runtime.multiplayer_local_peer_id
	):
		if _presentation_coordinator != null:
			_presentation_coordinator.end_local_spectator_camera(
				tower_runtime.player
			)
	_plant_placement_coordinator.set_flow_state(
		_campaign_coordinator.wave_state
	)


func remove_multiplayer_player(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _player_roster_coordinator == null
		or peer_id <= 0
		or peer_id == tower_runtime.multiplayer_local_peer_id
	):
		return
	cancel_luoxi_special_game_for_peer(peer_id)
	_player_roster_coordinator.remove_multiplayer_player(peer_id)
	if _fate_coordinator != null:
		_fate_coordinator.remove_eligible_peer(peer_id)


func ensure_reconnected_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	reconnect_state: Dictionary = {}
) -> CombatRuntimeBase.ReconnectedPlayerProjection:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _player_roster_coordinator == null
		or new_peer_id <= 0
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.INVALID_REQUEST
		)
	var projection := (
		_player_roster_coordinator.ensure_reconnected_multiplayer_player(
			old_peer_id,
			new_peer_id,
			player_name,
			character_id,
			state,
			spawn_slot_index,
			reconnect_state
		)
	)
	if not projection.is_success():
		return projection
	if (
		projection.status
		== CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
	):
		return projection
	# 模式附属状态只在本次新建 Player 投影后迁移一次；通知重放不得重复结算。
	remap_luoxi_collectible_claims(old_peer_id, new_peer_id)
	if _fate_coordinator != null:
		_fate_coordinator.apply_player_modifiers_to_all()
	_enemy_coordinator.request_retarget()
	return projection


func synchronize_reconnected_player_presentation_lease(peer_id: int) -> bool:
	return (
		_fate_flow_coordinator != null
		and _fate_flow_coordinator.synchronize_reconnected_player_presentation_lease(
			peer_id
		)
	)


func synchronize_reconnected_player_rogue_suspension(peer_id: int) -> bool:
	return (
		_rogue_exploration_coordinator != null
		and _rogue_exploration_coordinator
			.synchronize_reconnected_player_suspension(peer_id)
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	if _campaign_coordinator != null:
		_campaign_coordinator.apply_remote_flow_state(step_id, state, seconds)


func get_flow_state_snapshot() -> Dictionary:
	return (
		_campaign_coordinator.get_flow_state_snapshot()
		if _campaign_coordinator != null
		else {}
	)


func apply_remote_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _boss_coordinator == null
		or tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or boss_config == null
	):
		return
	_boss_coordinator.apply_remote_started(net_id, boss_config, spawn_position)


func apply_remote_defeat() -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		_campaign_coordinator.apply_remote_flow_state(
			&"",
			CombatFlowState.State.DEFEAT,
			0
		)


func apply_remote_victory() -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		_campaign_coordinator.apply_remote_flow_state(
			&"",
			CombatFlowState.State.VICTORY,
			0
		)


func apply_remote_enemy_count(alive_count: int) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and _presentation_coordinator != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		_presentation_coordinator.show_enemy_count(alive_count)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var player_instance := _get_player(peer_id)
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
	var player_instance := _get_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		return
	player_instance.set_xirang_balance(current_xirang)
	if skill1_unlocked and not player_instance.has_skill1():
		player_instance.unlock_skill1()
	if skill1_upgrade_level >= 0:
		player_instance.apply_skill1_upgrade_state(
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	if _merchant != null:
		_merchant.show_purchase_result(result_code)


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
	_set_local_merchants_active(active)


func set_merchant_active(active: bool) -> void:
	var changed := _set_local_merchants_active(active)
	var tower_runtime := get_tower_runtime()
	if (
		changed
		and tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		merchant_active_changed.emit(active)


func set_local_merchants_active(active: bool) -> bool:
	return _set_local_merchants_active(active)


func publish_flow_state(state: CombatFlowState.State) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _campaign_coordinator == null
		or tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		return
	flow_state_changed.emit(
		_campaign_coordinator.get_flow_step_id(
			_campaign_coordinator.current_flow_step
		),
		int(state),
		_campaign_coordinator.countdown_seconds
	)


func publish_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or boss_config == null
	):
		return
	boss_started.emit(net_id, boss_config, spawn_position)
	_rebroadcast_boss_started_after_sync_window(net_id, boss_config)


func _rebroadcast_boss_started_after_sync_window(
	net_id: int,
	boss_config: BossConfig
) -> void:
	if net_id <= 0 or boss_config == null:
		return
	await get_tree().create_timer(0.75).timeout
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		or _campaign_coordinator == null
		or _campaign_coordinator.wave_state
		!= CombatFlowState.State.BOSS_ACTIVE
		or _boss_coordinator == null
		or _boss_coordinator.linglan_boss == null
		or not is_instance_valid(_boss_coordinator.linglan_boss)
	):
		return
	boss_started.emit(
		net_id,
		boss_config,
		_boss_coordinator.linglan_boss.global_position
	)


func publish_inventory_changed(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and peer_id > 0
	):
		inventory_changed.emit(peer_id)


func _handle_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		return
	plant_placement_requested.emit(request_id, plant_id, anchor)


func _handle_inventory_plant_placement_requested(
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or _plant_runtime_coordinator == null:
		return
	if (
		tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		inventory_plant_placement_requested.emit(
			request_id,
			plant_id,
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
		)
		return
	_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
	_plant_runtime_coordinator.request_singleplayer_inventory_placement(
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path,
		_run_state,
		tower_runtime.player,
		is_fate_interlude_active()
	)


func handle_debug_collectible_requested(config_path: String) -> void:
	if config_path.is_empty() or not allows_debug_collectible_grants():
		return
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and request_debug_collectible(config_path)
	):
		return
	show_debug_collectible_grant_result(
		config_path,
		grant_debug_collectible(config_path)
	)


func grant_debug_collectible(config_path: String) -> bool:
	if not allows_debug_collectible_grants() or _run_state == null:
		return false
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	if item == null:
		return false
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return false
	if (
		tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and tower_runtime.multiplayer_local_peer_id > 0
	):
		return _run_state.try_add_item_for_peer(
			tower_runtime.multiplayer_local_peer_id,
			item
		)
	return _run_state.try_add_item(item)


func handle_return_to_lobby_requested() -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	if (
		tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		_plant_placement_coordinator.cancel_placement()
		get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH)
		return
	return_to_lobby_requested.emit()


func handle_wave_start_requested() -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		request_wave_start()
		return
	request_authoritative_wave_start(tower_runtime.multiplayer_local_peer_id)


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


func handle_profile_building_placement_requested(
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	if begin_inventory_building_placement(slot_index, expected_inventory_revision):
		return
	if _profile_panel != null:
		_profile_panel.restore_after_failed_building_placement()


func request_wave_start() -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_multiplayer_start_wave()
	return true


func prewarm_mode_runtime_data(preparation_generation: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		await LuoxiMerchant.prewarm_collectible_cache(
			tower_runtime,
			preparation_generation
		)


func broadcast_plant_projectile_visual(
	plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.broadcast_plant_projectile_visual(
		plant_net_id,
		spawn_position,
		direction,
		speed,
		explosion_radius,
		lifetime
	)
	return true


func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.queue_bamboo_mortar_visual(
		plant_net_id,
		action_id,
		stage,
		spawn_position,
		landing_position,
		committed_windup_duration_seconds
	)
	return true


func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.queue_hydrangea_rain_visual(
		plant_net_id,
		action_id,
		target_position,
		action_elapsed_seconds
	)
	return true


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2
) -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.queue_corn_machine_gun_burst_visual(
		plant_net_id,
		action_id,
		direction
	)
	return true


func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
		or damage <= 0
	):
		return false
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return enemy.apply_damage(
			damage,
			impact_direction if impact_direction.is_finite() else Vector2.ZERO,
			damage_type
		)
	return (
		has_multiplayer_session()
		and multiplayer_session.apply_authoritative_plant_enemy_damage(
			damage_source_id,
			enemy,
			damage,
			impact_direction,
			damage_type
		)
	)


func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return false
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		if _plant_runtime_coordinator == null:
			return false
		_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
		return _plant_runtime_coordinator.apply_authoritative_enemy_damage_batch(
			damage_source_id,
			enemy,
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type
		)
	return (
		has_multiplayer_session()
		and multiplayer_session.apply_authoritative_plant_enemy_damage_batch(
			damage_source_id,
			enemy,
			damage_amounts,
			hit_counts,
			impact_direction,
			damage_type
		)
	)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return false
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return request_runtime_bamboo_mortar_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)
	return (
		has_multiplayer_session()
		and multiplayer_session.request_bamboo_mortar_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		cancel_runtime_bamboo_mortar_target_request(owner)
	elif (
		tower_runtime != null
		and tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and has_multiplayer_session()
	):
		multiplayer_session.cancel_bamboo_mortar_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		return select_runtime_bamboo_mortar_target_sync_for_fixture(
			center,
			minimum_range,
			maximum_range
		)
	return (
		multiplayer_session.select_bamboo_mortar_target_sync_for_fixture(
			center,
			minimum_range,
			maximum_range
		)
		if has_multiplayer_session()
		else null
	)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return false
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return queue_runtime_bamboo_mortar_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)
	return (
		has_multiplayer_session()
		and multiplayer_session.queue_bamboo_mortar_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)
	)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	):
		return get_runtime_bamboo_mortar_combat_metrics()
	return (
		multiplayer_session.get_bamboo_mortar_combat_metrics()
		if has_multiplayer_session()
		else {}
	)


func request_runtime_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and _plant_runtime_coordinator != null
		and _plant_runtime_coordinator.request_bamboo_mortar_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)
	)


func cancel_runtime_bamboo_mortar_target_request(owner: Node) -> void:
	if _plant_runtime_coordinator != null:
		_plant_runtime_coordinator.cancel_bamboo_mortar_target_request(owner)


func select_runtime_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	return (
		_plant_runtime_coordinator.select_bamboo_mortar_target_sync_for_fixture(
			center,
			minimum_range,
			maximum_range
		)
		if _plant_runtime_coordinator != null
		else null
	)


func queue_runtime_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	return (
		_plant_runtime_coordinator != null
		and _plant_runtime_coordinator.queue_bamboo_mortar_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)
	)


func get_runtime_bamboo_mortar_combat_metrics() -> Dictionary:
	return (
		_plant_runtime_coordinator.get_bamboo_mortar_combat_metrics()
		if _plant_runtime_coordinator != null
		else {}
	)


func get_tower_runtime() -> TowerDefenseGame:
	# Adapter and runtime share one authored scene lifetime; repeated validity
	# probes on every replicated event only add work to the hot signal boundary.
	if _tower_runtime != null:
		return _tower_runtime
	_tower_runtime = runtime as TowerDefenseGame
	return _tower_runtime


func supports_multiplayer_wave_progress() -> bool:
	return true


func request_authoritative_wave_start(requester_peer_id: int) -> bool:
	return (
		_campaign_coordinator != null
		and _campaign_coordinator.request_wave_start(requester_peer_id)
	)


func get_base_health_snapshot() -> Dictionary:
	return (
		_home_defense_coordinator.get_base_health_snapshot()
		if _home_defense_coordinator != null
		else {}
	)


func apply_remote_base_health(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if _home_defense_coordinator != null:
		_home_defense_coordinator.apply_remote_base_health(
			current_health,
			maximum_health,
			revision
		)


func apply_remote_enemy_escape(net_id: int) -> void:
	if _home_defense_coordinator != null:
		_home_defense_coordinator.apply_remote_enemy_escape(net_id)


func publish_authoritative_base_health(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		base_health_changed.emit(current_health, maximum_health, revision)


func get_wave_progress_snapshot() -> Dictionary:
	return _enemy_coordinator.get_wave_progress_snapshot()


func apply_remote_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	_enemy_coordinator.apply_remote_wave_progress(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


func request_authoritative_plant_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or _plant_runtime_coordinator == null:
		return
	_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
	_plant_runtime_coordinator.request_multiplayer_free_placement(
		requester_peer_id,
		request_id,
		plant_id,
		anchor,
		_get_player(requester_peer_id),
		_campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE,
		tower_runtime.sandbox_free_building_enabled
	)


func request_authoritative_inventory_plant_placement(
	requester_peer_id: int,
	request_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _plant_runtime_coordinator == null
		or _run_state == null
	):
		return
	_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
	_plant_runtime_coordinator.request_multiplayer_inventory_placement(
		requester_peer_id,
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path,
		_run_state,
		_get_player(requester_peer_id),
		_campaign_coordinator.wave_state == CombatFlowState.State.FATE_INTERLUDE
	)


func apply_remote_plant_spawn(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if _plant_runtime_coordinator != null:
		var tower_runtime := get_tower_runtime()
		if tower_runtime == null:
			return
		_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
		_plant_runtime_coordinator.apply_remote_plant_spawn(
			request_id,
			_get_player(owner_peer_id),
			net_id,
			plant_id,
			anchor,
			current_health,
			maximum_health,
			health_revision
		)


func apply_remote_plant_health(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if _plant_runtime_coordinator != null:
		var tower_runtime := get_tower_runtime()
		if tower_runtime == null:
			return
		_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
		_plant_runtime_coordinator.apply_remote_plant_health(
			net_id,
			current_health,
			maximum_health,
			health_revision
		)


func apply_remote_plant_removed(
	net_id: int,
	was_destroyed: bool = false,
	silent: bool = false
) -> void:
	if _plant_runtime_coordinator == null:
		return
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
	_plant_runtime_coordinator.apply_remote_plant_removed(
		net_id,
		was_destroyed,
		silent
	)


func apply_remote_plant_placement_rejected(
	request_id: int,
	reason: StringName
) -> void:
	if _plant_runtime_coordinator == null:
		return
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	_plant_runtime_coordinator.set_runtime_mode(tower_runtime.runtime_mode)
	_plant_runtime_coordinator.apply_remote_placement_rejected(request_id)


func has_multiplayer_plant(net_id: int) -> bool:
	return (
		_plant_runtime_coordinator != null
		and _plant_runtime_coordinator.has_multiplayer_plant(net_id)
	)


func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
	return (
		_plant_runtime_coordinator.get_multiplayer_plant(net_id)
		if _plant_runtime_coordinator != null
		else null
	)


func get_network_projectile_world_target(net_id: int) -> Node2D:
	return get_multiplayer_plant_node(net_id)


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	return (
		_plant_runtime_coordinator.get_multiplayer_plant_snapshots()
		if _plant_runtime_coordinator != null
		else []
	)


func get_authoritative_team_plant_count() -> int:
	return (
		_plant_runtime_coordinator.get_authoritative_team_plant_count()
		if _plant_runtime_coordinator != null
		else -1
	)


func find_nearest_operational_interaction_building(
	world_position: Vector2,
	maximum_distance: float
) -> PlantDefense:
	if _plant_runtime_coordinator == null:
		return null
	return _plant_runtime_coordinator.find_nearest_operational_interaction_building(
		world_position,
		maximum_distance
	)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array
) -> void:
	if _plant_runtime_coordinator == null:
		result.clear()
		return
	var typed_result: Array[PlantDefense] = []
	_plant_runtime_coordinator.query_living_plants_in_radius_into(
		center,
		radius,
		typed_result
	)
	result.assign(typed_result)


func configure_runtime_enemy_modifiers(enemy_instance: Enemy) -> void:
	if _fate_coordinator != null:
		_fate_coordinator.configure_enemy_modifiers(enemy_instance)


func supports_terrain_state() -> bool:
	return _plant_runtime_coordinator != null


func get_terrain_snapshot() -> Dictionary:
	return (
		_plant_runtime_coordinator.get_terrain_snapshot()
		if _plant_runtime_coordinator != null
		else {}
	)


func apply_remote_terrain_snapshot(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	return (
		_plant_runtime_coordinator != null
		and _plant_runtime_coordinator.apply_remote_terrain_snapshot(
			revision,
			cell_xy,
			terrain_types
		)
	)


func apply_remote_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	return (
		_plant_runtime_coordinator != null
		and _plant_runtime_coordinator.apply_remote_terrain_delta(
			revision,
			cell_xy,
			terrain_types
		)
	)


func request_xiaocong_interaction(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _fate_flow_coordinator == null
		or tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE
	):
		return
	_fate_flow_coordinator.request_interaction(peer_id)


func request_xiaocong_fate_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _fate_flow_coordinator == null
		or tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE
	):
		return
	_fate_flow_coordinator.request_fate_vote(
		peer_id,
		option_id,
		permanent_buff_id
	)


func request_xiaocong_collectible_choice(
	peer_id: int,
	choice_index: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _fate_flow_coordinator == null
		or tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _campaign_coordinator.wave_state != CombatFlowState.State.FATE_INTERLUDE
	):
		return
	_fate_flow_coordinator.request_collectible_choice(peer_id, choice_index)


func get_xiaocong_fate_state_snapshot() -> Dictionary:
	return (
		_fate_flow_coordinator.get_state_snapshot()
		if _fate_flow_coordinator != null
		else {}
	)


func apply_remote_xiaocong_fate_state(state: Dictionary) -> bool:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or _fate_flow_coordinator == null
		or _fate_manager == null
		or tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or int(state.get("revision", 0)) < _fate_manager.state_revision
	):
		return false
	return _fate_flow_coordinator.apply_remote_state(state)


func supports_test_arena_manual_night_sync() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.supports_test_arena_manual_night_sync()
	)


func get_test_arena_manual_night_enabled() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.get_test_arena_manual_night_enabled()
	)


func apply_remote_test_arena_manual_night(enabled: bool) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_test_arena_manual_night(enabled)


func get_reconnect_spawn_slot_index(peer_id: int) -> int:
	return (
		_player_roster_coordinator.get_spawn_slot_index(peer_id)
		if _player_roster_coordinator != null
		else 0
	)


func get_reconnect_wave_death_count(peer_id: int) -> int:
	return (
		_player_roster_coordinator.get_wave_death_count(peer_id)
		if _player_roster_coordinator != null
		else 0
	)


func get_completed_global_research_ids() -> Array[StringName]:
	if _research_coordinator == null:
		return []
	return _research_coordinator.get_completed_global_research_ids()


func get_research_runtime_state() -> Dictionary:
	if _research_coordinator == null:
		return {}
	return _research_coordinator.export_runtime_state()


func apply_remote_research_runtime_state(state: Dictionary) -> bool:
	return (
		_research_coordinator != null
		and _research_coordinator.apply_multiplayer_runtime_state(state)
	)


func connect_research_milestone_changed(callback: Callable) -> bool:
	if (
		_research_coordinator == null
		or not callback.is_valid()
	):
		return false
	if not _research_coordinator.research_milestone_changed.is_connected(
		callback
	):
		_research_coordinator.research_milestone_changed.connect(callback)
	return true


func get_luoxi_merchant() -> LuoxiMerchant:
	return _luoxi_merchant


func runtime_try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	var player_instance := _get_player(peer_id)
	if (
		player_instance == null
		or not is_instance_valid(player_instance)
		or _luoxi_merchant == null
		or runtime_has_luoxi_collectible_claimed(peer_id)
	):
		return MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	return _luoxi_merchant.try_purchase_refresh_for_player(player_instance)


func runtime_get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	return (
		_luoxi_merchant.get_player_refresh_count(maxi(peer_id, 0))
		if _luoxi_merchant != null
		else 0
	)


func runtime_try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int:
	var player_instance := _get_player(peer_id)
	if (
		player_instance == null
		or not is_instance_valid(player_instance)
		or _run_state == null
	):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	var claim_key := maxi(peer_id, 0)
	if (
		_get_luoxi_collectible_claim_count(claim_key)
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
	if (
		item == null
		or not player_instance.is_collectible_compatible(item)
		or not LuoxiMerchant.is_collectible_available_for_inventory(
			item,
			_run_state,
			peer_id
		)
	):
		return MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	var stored := (
		_run_state.try_add_item_for_peer(peer_id, item)
		if peer_id > 0
		else _run_state.try_add_item(item)
	)
	if not stored:
		return MerchantPurchaseResult.CollectibleClaim.INVENTORY_FULL
	runtime_record_luoxi_collectible_claim(claim_key)
	return MerchantPurchaseResult.CollectibleClaim.SUCCESS


func runtime_has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return (
		_get_luoxi_collectible_claim_count(peer_id)
		>= LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func runtime_get_luoxi_collectible_claim_count(peer_id: int) -> int:
	return _get_luoxi_collectible_claim_count(peer_id)


func runtime_record_luoxi_collectible_claim(peer_id: int) -> void:
	var claim_key := maxi(peer_id, 0)
	_luoxi_collectible_claim_counts[claim_key] = mini(
		_get_luoxi_collectible_claim_count(claim_key) + 1,
		LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func runtime_mark_luoxi_collectible_claimed(peer_id: int) -> void:
	_luoxi_collectible_claim_counts[maxi(peer_id, 0)] = (
		LuoxiMerchant.COLLECTIBLE_CLAIMS_PER_ROUND
	)


func show_local_luoxi_collectible_result(result_code: int) -> void:
	if _luoxi_merchant != null:
		_luoxi_merchant.show_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	if _luoxi_merchant != null:
		_luoxi_merchant.show_refresh_result(
			result_code,
			refresh_count,
			current_xirang
		)


func runtime_supports_luoxi_special_game() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and _campaign_coordinator.wave_state not in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func runtime_try_start_luoxi_special_game_for_peer(peer_id: int) -> Dictionary:
	if _luoxi_special_game_coordinator == null:
		return {
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		}
	return _luoxi_special_game_coordinator.start_for_peer(peer_id)


func runtime_try_reveal_luoxi_special_game_card_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> Dictionary:
	if _luoxi_special_game_coordinator == null:
		return {
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		}
	return _luoxi_special_game_coordinator.reveal_for_peer(
			peer_id,
			session_revision,
			card_index
	)


func runtime_try_finish_luoxi_special_game_for_peer(
	peer_id: int,
	session_revision: int
) -> Dictionary:
	if _luoxi_special_game_coordinator == null:
		return {
			"result_code": LuoxiSpecialGameCoordinator.ResultCode.INVALID_PLAYER,
		}
	return _luoxi_special_game_coordinator.finish_for_peer(
			peer_id,
			session_revision
	)


func show_local_luoxi_special_game_started(result: Dictionary) -> void:
	if _luoxi_merchant != null:
		_luoxi_merchant.apply_special_game_started(result)


func show_local_luoxi_special_game_card_revealed(result: Dictionary) -> void:
	if _luoxi_merchant != null:
		_luoxi_merchant.apply_special_game_card_revealed(result)


func show_local_luoxi_special_game_finished(result: Dictionary) -> void:
	if _luoxi_merchant != null:
		_luoxi_merchant.apply_special_game_finished(result)


func apply_luoxi_player_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	if not has_multiplayer_session():
		return 0
	return multiplayer_session.apply_luoxi_direct_health_loss(
		target_player,
		amount,
		minimum_health
	)


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int
) -> bool:
	return (
		_plant_placement_coordinator != null
		and _plant_placement_coordinator.begin_inventory_building_placement(
			slot_index,
			expected_inventory_revision
		)
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
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	var peer_id := (
		tower_runtime.multiplayer_local_peer_id
		if tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	var result_code := runtime_try_claim_luoxi_collectible_for_peer(
		peer_id,
		_resolve_luoxi_collectible_path(choice_index, config_path)
	)
	show_local_luoxi_collectible_result(result_code)
	return true


func request_luoxi_collectible_refresh(offer_revision: int) -> bool:
	if super.request_luoxi_collectible_refresh(offer_revision):
		return true
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	var peer_id := (
		tower_runtime.multiplayer_local_peer_id
		if tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	var player_instance := _get_player(peer_id)
	show_local_luoxi_refresh_result(
		runtime_try_refresh_luoxi_collectibles_for_peer(peer_id),
		runtime_get_luoxi_collectible_refresh_count(peer_id),
		player_instance.current_xirang if player_instance != null else 0
	)
	return true


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if has_multiplayer_session():
		return super.has_luoxi_collectible_claimed(peer_id)
	return runtime_has_luoxi_collectible_claimed(peer_id)


func supports_luoxi_special_game() -> bool:
	if has_multiplayer_session():
		return multiplayer_session.supports_luoxi_special_game()
	return runtime_supports_luoxi_special_game()


func request_luoxi_special_game_start() -> bool:
	if has_multiplayer_session():
		multiplayer_session.request_luoxi_special_game_start()
		return true
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	var peer_id := (
		tower_runtime.multiplayer_local_peer_id
		if tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	show_local_luoxi_special_game_started(
		runtime_try_start_luoxi_special_game_for_peer(peer_id)
	)
	return true


func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> bool:
	if has_multiplayer_session():
		multiplayer_session.request_luoxi_special_game_card_reveal(
			session_revision,
			card_index
		)
		return true
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	var peer_id := (
		tower_runtime.multiplayer_local_peer_id
		if tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	show_local_luoxi_special_game_card_revealed(
		runtime_try_reveal_luoxi_special_game_card_for_peer(
			peer_id,
			session_revision,
			card_index
		)
	)
	return true


func request_luoxi_special_game_finish(session_revision: int) -> bool:
	if has_multiplayer_session():
		multiplayer_session.request_luoxi_special_game_finish(session_revision)
		return true
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	var peer_id := (
		tower_runtime.multiplayer_local_peer_id
		if tower_runtime.runtime_mode
		!= CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		else 0
	)
	show_local_luoxi_special_game_finished(
		runtime_try_finish_luoxi_special_game_for_peer(
			peer_id,
			session_revision
		)
	)
	return true


func cancel_luoxi_special_game_for_peer(peer_id: int) -> void:
	if _luoxi_special_game_coordinator != null:
		_luoxi_special_game_coordinator.cancel_for_peer(peer_id)


func cancel_all_luoxi_special_games() -> void:
	if _luoxi_special_game_coordinator != null:
		_luoxi_special_game_coordinator.cancel_all()
	if _luoxi_merchant != null:
		_luoxi_merchant.abort_special_game()


func remap_luoxi_collectible_claims(old_peer_id: int, new_peer_id: int) -> void:
	if not _luoxi_collectible_claim_counts.has(old_peer_id):
		return
	_luoxi_collectible_claim_counts[new_peer_id] = (
		_luoxi_collectible_claim_counts[old_peer_id]
	)
	_luoxi_collectible_claim_counts.erase(old_peer_id)


func clear_luoxi_collectible_claims() -> void:
	_luoxi_collectible_claim_counts.clear()


func _get_luoxi_collectible_claim_count(peer_id: int) -> int:
	return int(_luoxi_collectible_claim_counts.get(maxi(peer_id, 0), 0))


func _resolve_luoxi_collectible_path(
	choice_index: int,
	config_path: String
) -> String:
	if not config_path.is_empty():
		return config_path
	var item := LuoxiMerchant.get_collectible_for_choice(choice_index)
	return item.resource_path if item != null else ""


func _get_player(peer_id: int) -> Player:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return null
	if (
		tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		and peer_id <= 0
	):
		return tower_runtime.player
	return (
		_player_roster_coordinator.get_player(peer_id)
		if _player_roster_coordinator != null
		else tower_runtime.get_player_for_peer(peer_id)
	)


func _set_local_merchants_active(active: bool) -> bool:
	var changed := _merchant_intermission_active != active
	var entering_new_intermission := active and not _merchant_intermission_active
	_merchant_intermission_active = active
	# Tower-defense merchants remain authored world entities between waves. The
	# replicated flag controls intermission state and offer reset, matching the
	# pre-extraction behavior rather than toggling their visibility off.
	if _merchant != null and not _merchant.is_active:
		_merchant.set_active(true)
		changed = true
	if _luoxi_merchant != null:
		if not _luoxi_merchant.is_active:
			_luoxi_merchant.set_active(true)
			changed = true
		if entering_new_intermission:
			clear_luoxi_collectible_claims()
			if _luoxi_special_game_coordinator != null:
				_luoxi_special_game_coordinator.cancel_all()
			_luoxi_merchant.reset_intermission_state()
	return changed


func _on_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and _campaign_coordinator.current_flow_step is WaveConfig
	):
		wave_progress_changed.emit(
			wave_number,
			defeated,
			escaped,
			resolved,
			total
		)


func _on_local_xiaocong_interaction_requested() -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		request_xiaocong_interaction(0)
	else:
		xiaocong_interaction_requested.emit()


func _on_local_xiaocong_fate_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		request_xiaocong_fate_vote(0, option_id, permanent_buff_id)
	else:
		xiaocong_vote_requested.emit(option_id, permanent_buff_id)


func _on_local_xiaocong_collectible_choice_requested(choice_index: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	if tower_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		request_xiaocong_collectible_choice(0, choice_index)
	else:
		xiaocong_collectible_requested.emit(choice_index)


func _on_xiaocong_fate_state_changed(snapshot: Dictionary) -> void:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime != null
		and tower_runtime.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	):
		xiaocong_fate_state_changed.emit(snapshot)


func _connect_mode_signals() -> void:
	if not _player_roster_coordinator.player_died.is_connected(handle_player_died):
		_player_roster_coordinator.player_died.connect(handle_player_died)
	if not _player_roster_coordinator.player_revived.is_connected(handle_player_revived):
		_player_roster_coordinator.player_revived.connect(handle_player_revived)
	if not _player_roster_coordinator.respawn_countdown_changed.is_connected(
		update_player_respawn_countdown
	):
		_player_roster_coordinator.respawn_countdown_changed.connect(
			update_player_respawn_countdown
		)
	if not _player_roster_coordinator.respawn_countdown_cleared.is_connected(
		clear_player_respawn_countdown
	):
		_player_roster_coordinator.respawn_countdown_cleared.connect(
			clear_player_respawn_countdown
		)
	if not _player_roster_coordinator.revive_all_requested.is_connected(
		revive_all_requested.emit
	):
		_player_roster_coordinator.revive_all_requested.connect(
			revive_all_requested.emit
		)
	if not _player_roster_coordinator.restore_all_full_health_requested.is_connected(
		restore_all_full_health_requested.emit
	):
		_player_roster_coordinator.restore_all_full_health_requested.connect(
			restore_all_full_health_requested.emit
		)
	if not _presentation_coordinator.return_to_lobby_requested.is_connected(
		handle_return_to_lobby_requested
	):
		_presentation_coordinator.return_to_lobby_requested.connect(
			handle_return_to_lobby_requested
		)
	if not _presentation_coordinator.start_wave_requested.is_connected(
		handle_wave_start_requested
	):
		_presentation_coordinator.start_wave_requested.connect(
			handle_wave_start_requested
		)
	if not _enemy_coordinator.wave_progress_changed.is_connected(
		_on_wave_progress_changed
	):
		_enemy_coordinator.wave_progress_changed.connect(_on_wave_progress_changed)
	if not _plant_runtime_coordinator.terrain_delta.is_connected(terrain_delta.emit):
		_plant_runtime_coordinator.terrain_delta.connect(terrain_delta.emit)
	if not _plant_runtime_coordinator.plant_health_changed.is_connected(
		plant_health_changed.emit
	):
		_plant_runtime_coordinator.plant_health_changed.connect(
			plant_health_changed.emit
		)
	if not _plant_runtime_coordinator.plant_damage_status_changed.is_connected(
		plant_damage_status_changed.emit
	):
		_plant_runtime_coordinator.plant_damage_status_changed.connect(
			plant_damage_status_changed.emit
		)
	if not _plant_runtime_coordinator.plant_damage_applied.is_connected(
		plant_damage_applied.emit
	):
		_plant_runtime_coordinator.plant_damage_applied.connect(
			plant_damage_applied.emit
		)
	if not _plant_runtime_coordinator.plant_healing_applied.is_connected(
		plant_healing_applied.emit
	):
		_plant_runtime_coordinator.plant_healing_applied.connect(
			plant_healing_applied.emit
		)
	if not _plant_runtime_coordinator.plant_spawned.is_connected(plant_spawned.emit):
		_plant_runtime_coordinator.plant_spawned.connect(plant_spawned.emit)
	if not _plant_runtime_coordinator.plant_placement_rejected.is_connected(
		plant_placement_rejected.emit
	):
		_plant_runtime_coordinator.plant_placement_rejected.connect(
			plant_placement_rejected.emit
		)
	if not _plant_runtime_coordinator.inventory_changed.is_connected(
		inventory_changed.emit
	):
		_plant_runtime_coordinator.inventory_changed.connect(inventory_changed.emit)
	if not _plant_runtime_coordinator.network_plant_removed.is_connected(
		plant_removed.emit
	):
		_plant_runtime_coordinator.network_plant_removed.connect(plant_removed.emit)
	if not _plant_placement_coordinator.plant_placement_requested.is_connected(
		_handle_plant_placement_requested
	):
		_plant_placement_coordinator.plant_placement_requested.connect(
			_handle_plant_placement_requested
		)
	if not _plant_placement_coordinator.inventory_plant_placement_requested.is_connected(
		_handle_inventory_plant_placement_requested
	):
		_plant_placement_coordinator.inventory_plant_placement_requested.connect(
			_handle_inventory_plant_placement_requested
		)
	if not _fate_flow_coordinator.local_interaction_requested.is_connected(
		_on_local_xiaocong_interaction_requested
	):
		_fate_flow_coordinator.local_interaction_requested.connect(
			_on_local_xiaocong_interaction_requested
		)
	if not _fate_flow_coordinator.local_fate_vote_requested.is_connected(
		_on_local_xiaocong_fate_vote_requested
	):
		_fate_flow_coordinator.local_fate_vote_requested.connect(
			_on_local_xiaocong_fate_vote_requested
		)
	if not _fate_flow_coordinator.local_collectible_choice_requested.is_connected(
		_on_local_xiaocong_collectible_choice_requested
	):
		_fate_flow_coordinator.local_collectible_choice_requested.connect(
			_on_local_xiaocong_collectible_choice_requested
		)
	if not _fate_flow_coordinator.state_snapshot_changed.is_connected(
		_on_xiaocong_fate_state_changed
	):
		_fate_flow_coordinator.state_snapshot_changed.connect(
			_on_xiaocong_fate_state_changed
		)
	if not _debug_collectible_window.collectible_requested.is_connected(
		handle_debug_collectible_requested
	):
		_debug_collectible_window.collectible_requested.connect(
			handle_debug_collectible_requested
		)
