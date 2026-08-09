extends Node
class_name FateCoordinator

const FATE_STONE_CONFIG: PickupConfig = preload(
	"res://resources/config/fate/xiaocong_fate_stone.tres"
)
const ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH: Dictionary = {
	"res://resources/config/enemies/capoo_knight.tres":
		"res://resources/config/enemies/capoo_knight_elite.tres",
	"res://resources/config/enemies/stone_golem.tres":
		"res://resources/config/enemies/stone_golem_elite.tres",
	"res://resources/config/enemies/combat_robot.tres":
		"res://resources/config/enemies/combat_robot_elite.tres",
	"res://resources/config/enemies/combat_robot_gunner.tres":
		"res://resources/config/enemies/combat_robot_gunner_elite.tres",
	"res://resources/config/enemies/combat_robot_drone_operator.tres":
		"res://resources/config/enemies/combat_robot_drone_operator_elite.tres",
	"res://resources/config/enemies/combat_robot_shield_bearer.tres":
		"res://resources/config/enemies/combat_robot_shield_bearer_elite.tres",
	"res://resources/config/enemies/combat_robot_ninja.tres":
		"res://resources/config/enemies/combat_robot_ninja_elite.tres",
	"res://resources/config/enemies/fire_sorcerer.tres":
		"res://resources/config/enemies/fire_sorcerer_elite.tres",
	"res://resources/config/enemies/frost_sorcerer.tres":
		"res://resources/config/enemies/frost_sorcerer_elite.tres",
	"res://resources/config/enemies/lightning_sorcerer.tres":
		"res://resources/config/enemies/lightning_sorcerer_elite.tres",
}
const YUANSHI_ATTACK_SOURCE_ID := 880001
const ARTIFICIAL_DEFENSE_SOURCE_ID := 880002
const SLIME_SPEED_SOURCE_ID := 880003
const ALL_ENEMY_SPEED_SOURCE_ID := 880004

@onready var manager: TowerDefenseFateManager = $TowerDefenseFateManager
@onready var runtime_tick_timer: Timer = $RuntimeTickTimer

var campaign_coordinator: TowerDefenseCampaignCoordinator = null
var home_defense_coordinator: TowerDefenseHomeDefenseCoordinator = null
var player_roster_coordinator: TowerDefensePlayerRosterCoordinator = null
var multiplayer_adapter: TowerDefenseMultiplayerModeAdapter = null
var run_state: RunStateStore = null
var luoxi_merchant: TowerDefenseLuoxiMerchant = null
var enemy_container: Node2D = null
var boss_container: Node2D = null
var day_cycle_config: DayCycleConfig = null
var active_permanent_buff_ids: Array[StringName] = []
var elite_bias_day := 0
var double_xirang_day := 0
var player_dash_cooldown_reduction := 0.0
var player_max_health_multiplier := 1.0
var player_move_speed_multiplier := 1.0
var hurt_speed_penalty_enabled := false
var pending_stone_peer_ids: Array[int] = []
var random_generator := RandomNumberGenerator.new()
var elite_enemy_config_by_base_path: Dictionary = {}
var elite_enemy_config_loads_requested := false


func _ready() -> void:
	random_generator.randomize()
	runtime_tick_timer.timeout.connect(_on_runtime_tick)
	manager.resolution_requested.connect(_on_resolution_requested)
	manager.state_changed.connect(_on_manager_state_changed)


func setup(
	new_campaign_coordinator: TowerDefenseCampaignCoordinator,
	new_home_defense_coordinator: TowerDefenseHomeDefenseCoordinator,
	new_player_roster_coordinator: TowerDefensePlayerRosterCoordinator,
	new_multiplayer_adapter: TowerDefenseMultiplayerModeAdapter,
	new_run_state: RunStateStore,
	new_luoxi_merchant: TowerDefenseLuoxiMerchant,
	new_enemy_container: Node2D,
	new_boss_container: Node2D,
	new_day_cycle_config: DayCycleConfig
) -> void:
	campaign_coordinator = new_campaign_coordinator
	home_defense_coordinator = new_home_defense_coordinator
	player_roster_coordinator = new_player_roster_coordinator
	multiplayer_adapter = new_multiplayer_adapter
	run_state = new_run_state
	luoxi_merchant = new_luoxi_merchant
	enemy_container = new_enemy_container
	boss_container = new_boss_container
	day_cycle_config = new_day_cycle_config
	request_elite_enemy_config_loads()
	_apply_runtime_state_to_world()


func request_elite_enemy_config_loads() -> void:
	if elite_enemy_config_loads_requested:
		return
	elite_enemy_config_loads_requested = true
	for elite_path_value in ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.values():
		var elite_path := str(elite_path_value)
		if not elite_path.is_empty():
			ResourceLoader.load_threaded_request(elite_path)


func prewarm_elite_enemy_configs() -> void:
	request_elite_enemy_config_loads()
	for base_path_value in ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH:
		var base_path := str(base_path_value)
		if elite_enemy_config_by_base_path.has(base_path):
			continue
		var elite_path := str(ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH[base_path_value])
		var status := ResourceLoader.load_threaded_get_status(elite_path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
			if not is_inside_tree():
				return
			status = ResourceLoader.load_threaded_get_status(elite_path)
		var elite_config := (
			ResourceLoader.load_threaded_get(elite_path) as EnemyConfig
			if status == ResourceLoader.THREAD_LOAD_LOADED
			else load(elite_path) as EnemyConfig
		)
		if elite_config != null:
			elite_enemy_config_by_base_path[base_path] = elite_config


func begin_interlude(
	day_number: int,
	resume_step_id: StringName,
	peer_ids: Array[int],
	host_peer_id: int
) -> void:
	var available_buff_ids := _get_available_permanent_buff_ids()
	var available_option_ids: Array[StringName] = []
	for config in TowerDefenseFateRegistry.get_all_option_configs():
		if (
			available_buff_ids.size()
			< config.required_available_permanent_buff_count()
		):
			continue
		if (
			config.option_id == TowerDefenseFateRegistry.OPTION_FATE_STONE
			and not _fate_stone_would_benefit_any_peer(peer_ids)
		):
			continue
		available_option_ids.append(config.option_id)
	manager.begin_interlude(
		day_number,
		resume_step_id,
		peer_ids,
		host_peer_id,
		available_option_ids,
		available_buff_ids
	)


func request_collectible_choice(peer_id: int, choice_index: int) -> void:
	if not is_collectible_choice_pending_for_peer(peer_id):
		return
	var offer_variant: Variant = manager.collectible_offers.get(peer_id, [])
	if not (offer_variant is Array) or choice_index < 0 or choice_index >= offer_variant.size():
		return
	var config_path := str(offer_variant[choice_index])
	var item := LuoxiMerchant.get_collectible_for_path(config_path)
	var player_instance := _get_player(peer_id)
	if player_instance == null or not is_instance_valid(player_instance):
		remove_eligible_peer(peer_id)
		return
	if (
		item == null
		or not player_instance.is_collectible_compatible(item)
		or not LuoxiMerchant.is_collectible_available_for_inventory(
			item,
			run_state,
			peer_id
		)
	):
		manager.record_collectible_result(peer_id, false, "该收藏品当前无法获得")
		return
	if not _try_store_item(peer_id, item):
		manager.record_collectible_result(
			peer_id,
			false,
			"背包已满，请先清出一个空位后再次选择"
		)
		return
	player_instance.refresh_collectible_stats()
	_notify_inventory_changed(peer_id)
	manager.record_collectible_result(peer_id, true, "收藏品已放入背包")


func is_collectible_choice_pending_for_peer(peer_id: int) -> bool:
	return (
		manager.active
		and manager.stage == TowerDefenseFateManager.STAGE_COLLECTIBLE_REWARD
		and manager.eligible_peer_ids.has(peer_id)
		and not manager.collectible_claimed_peer_ids.has(peer_id)
	)


func remove_eligible_peer(peer_id: int) -> void:
	pending_stone_peer_ids.erase(peer_id)
	manager.remove_eligible_peer(peer_id)
	_finalize_stone_resolution_if_ready()


func clear_pending_rewards() -> void:
	pending_stone_peer_ids.clear()


func has_permanent_buff(buff_id: StringName) -> bool:
	return active_permanent_buff_ids.has(buff_id)


func export_runtime_state() -> Dictionary:
	var buff_ids := PackedStringArray()
	for buff_id in active_permanent_buff_ids:
		buff_ids.append(String(buff_id))
	return {
		"active_permanent_buff_ids": buff_ids,
		"elite_bias_day": elite_bias_day,
		"double_xirang_day": double_xirang_day,
		"player_dash_cooldown_reduction": player_dash_cooldown_reduction,
		"player_max_health_multiplier": player_max_health_multiplier,
		"player_move_speed_multiplier": player_move_speed_multiplier,
		"hurt_speed_penalty_enabled": hurt_speed_penalty_enabled,
		"pending_stone_peer_ids": pending_stone_peer_ids.duplicate(),
	}


func apply_remote_runtime_state(state: Dictionary) -> void:
	var incoming_buffs: Array[StringName] = []
	var raw_buffs: Variant = state.get("active_permanent_buff_ids", [])
	if raw_buffs is Array or raw_buffs is PackedStringArray:
		for wire_id in raw_buffs:
			var config := TowerDefenseFateRegistry.get_permanent_buff_config_by_wire_id(
				str(wire_id)
			)
			if config != null and not incoming_buffs.has(config.buff_id):
				incoming_buffs.append(config.buff_id)
	active_permanent_buff_ids = incoming_buffs
	elite_bias_day = maxi(int(state.get("elite_bias_day", 0)), 0)
	double_xirang_day = maxi(int(state.get("double_xirang_day", 0)), 0)
	player_dash_cooldown_reduction = maxf(
		float(state.get("player_dash_cooldown_reduction", 0.0)),
		0.0
	)
	player_max_health_multiplier = maxf(
		float(state.get("player_max_health_multiplier", 1.0)),
		0.01
	)
	player_move_speed_multiplier = maxf(
		float(state.get("player_move_speed_multiplier", 1.0)),
		0.0
	)
	hurt_speed_penalty_enabled = bool(
		state.get("hurt_speed_penalty_enabled", false)
	)
	pending_stone_peer_ids = _variant_to_sorted_peer_ids(
		state.get("pending_stone_peer_ids", [])
	)
	_apply_runtime_state_to_world()


func resolve_enemy_config(enemy_config: EnemyConfig) -> EnemyConfig:
	if (
		enemy_config == null
		or campaign_coordinator == null
		or day_cycle_config == null
	):
		return enemy_config
	var current_day := day_cycle_config.get_day_number(
		campaign_coordinator.current_wave_index + 1
	)
	var contract := TowerDefenseFateRegistry.get_option_config(
		TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT
	)
	var replacement_chance := contract.secondary_amount if contract != null else 0.0
	if current_day != elite_bias_day or random_generator.randf() >= replacement_chance:
		return enemy_config
	var base_path := enemy_config.resource_path
	var elite_config := elite_enemy_config_by_base_path.get(base_path) as EnemyConfig
	if elite_config != null:
		return elite_config
	var elite_path := str(ELITE_ENEMY_CONFIG_PATH_BY_BASE_PATH.get(base_path, ""))
	if elite_path.is_empty():
		return enemy_config
	var status := ResourceLoader.load_threaded_get_status(elite_path)
	elite_config = (
		ResourceLoader.load_threaded_get(elite_path) as EnemyConfig
		if status == ResourceLoader.THREAD_LOAD_LOADED
		else load(elite_path) as EnemyConfig
	)
	if elite_config == null:
		return enemy_config
	elite_enemy_config_by_base_path[base_path] = elite_config
	return elite_config


func configure_enemy_modifiers(enemy_instance: Enemy) -> void:
	if (
		enemy_instance == null
		or not is_instance_valid(enemy_instance)
		or enemy_instance.config == null
	):
		return
	var enemy_config := enemy_instance.config
	var yuanshi_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_YUANSHI_ATTACK_REDUCTION
	)
	if yuanshi_config != null and enemy_config.has_category_tag(
		EnemyConfig.CATEGORY_YUANSHI_INSECT
	):
		enemy_instance.add_outgoing_attack_damage_multiplier_modifier(
			YUANSHI_ATTACK_SOURCE_ID,
			1.0 - yuanshi_config.magnitude
		)
	var artificial_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_ARTIFICIAL_DEFENSE_REDUCTION
	)
	if artificial_config != null and enemy_config.has_category_tag(
		EnemyConfig.CATEGORY_ARTIFICIAL_CREATION
	):
		var reduced_defense := floori(
			float(enemy_config.physical_defense) * (1.0 - artificial_config.magnitude)
		)
		enemy_instance.add_physical_defense_modifier(
			ARTIFICIAL_DEFENSE_SOURCE_ID,
			reduced_defense - enemy_config.physical_defense
		)
	var slime_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_SLIME_SPEED_REDUCTION
	)
	if slime_config != null and enemy_config.has_category_tag(
		EnemyConfig.CATEGORY_SLIME
	):
		enemy_instance.add_move_speed_modifier(
			SLIME_SPEED_SOURCE_ID,
			1.0 - slime_config.magnitude
		)
	var health_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_ENEMY_MAX_HEALTH_REDUCTION
	)
	if health_config != null:
		enemy_instance.set_runtime_max_health_multiplier(1.0 - health_config.magnitude)
	var speed_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_ENEMY_SPEED_REDUCTION
	)
	if speed_config != null:
		enemy_instance.add_move_speed_modifier(
			ALL_ENEMY_SPEED_SOURCE_ID,
			1.0 - speed_config.magnitude
		)


func is_double_xirang_reward_active() -> bool:
	return (
		campaign_coordinator != null
		and day_cycle_config != null
		and campaign_coordinator.wave_state in [
			CombatFlowState.State.WAVE_ACTIVE,
			CombatFlowState.State.BOSS_ACTIVE,
		]
		and day_cycle_config.get_day_number(
			campaign_coordinator.current_wave_index + 1
		)
		== double_xirang_day
	)


func apply_player_modifiers_to_all() -> void:
	if player_roster_coordinator == null:
		return
	var low_health_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_LOW_HEALTH_REDUCTION
	)
	var dangerous_speed_config := TowerDefenseFateRegistry.get_option_config(
		TowerDefenseFateRegistry.OPTION_DANGEROUS_SPEED
	)
	for player_instance in _get_all_players():
		player_instance.configure_tower_defense_fate_modifiers(
			player_max_health_multiplier,
			player_move_speed_multiplier,
			player_dash_cooldown_reduction,
			low_health_config.secondary_magnitude if low_health_config != null else 0.0,
			low_health_config.magnitude if low_health_config != null else 0.0,
			(
				dangerous_speed_config.secondary_amount
				if hurt_speed_penalty_enabled and dangerous_speed_config != null
				else 1.0
			),
			(
				dangerous_speed_config.duration_seconds
				if hurt_speed_penalty_enabled and dangerous_speed_config != null
				else 0.0
			)
		)


func apply_enemy_modifiers_to_existing() -> void:
	if enemy_container == null or boss_container == null:
		return
	for container in [enemy_container, boss_container]:
		if container == null:
			continue
		for child in container.get_children():
			var enemy_instance := child as Enemy
			if enemy_instance != null and is_instance_valid(enemy_instance):
				configure_enemy_modifiers(enemy_instance)


func _on_resolution_requested(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	if (
		player_roster_coordinator == null
		or player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return
	var option_config := TowerDefenseFateRegistry.get_option_config(option_id)
	if option_config == null:
		manager.force_finish()
		return
	match option_config.effect_type:
		TowerDefenseFateOptionConfig.EffectType.PERMANENT_ELITE_CONTRACT:
			if not _activate_permanent_buff(permanent_buff_id):
				manager.force_finish()
				return
			elite_bias_day = manager.completed_day + 1
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.BASE_REBUILD:
			_set_base_health(
				home_defense_coordinator.maximum_base_health
					+ roundi(option_config.primary_amount),
				-1
			)
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.COLLECTIBLE_REWARD:
			_begin_collectible_reward()
		TowerDefenseFateOptionConfig.EffectType.FATE_STONE:
			_grant_fate_stone_to_all()
		TowerDefenseFateOptionConfig.EffectType.XIRANG_GIFT:
			_grant_xirang_to_eligible_players(
				roundi(option_config.primary_amount)
			)
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.DASH_COOLDOWN:
			player_dash_cooldown_reduction += option_config.primary_amount
			apply_player_modifiers_to_all()
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.MAX_HEALTH:
			player_max_health_multiplier += option_config.primary_amount
			apply_player_modifiers_to_all()
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.CRITICAL_BUFF_SELECTION:
			if not _activate_permanent_buff(permanent_buff_id):
				manager.force_finish()
				return
			_set_base_health(
				home_defense_coordinator.maximum_base_health,
				roundi(option_config.primary_amount)
			)
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.DOUBLE_XIRANG:
			_clear_eligible_player_xirang()
			double_xirang_day = manager.completed_day + 1
			manager.finalize_resolution()
		TowerDefenseFateOptionConfig.EffectType.DANGEROUS_SPEED:
			player_move_speed_multiplier += option_config.primary_amount
			hurt_speed_penalty_enabled = true
			apply_player_modifiers_to_all()
			manager.finalize_resolution()


func _activate_permanent_buff(buff_id: StringName) -> bool:
	if (
		TowerDefenseFateRegistry.get_permanent_buff_config(buff_id) == null
		or active_permanent_buff_ids.has(buff_id)
	):
		return false
	active_permanent_buff_ids.append(buff_id)
	active_permanent_buff_ids.sort_custom(func(left: StringName, right: StringName) -> bool:
		var left_config := TowerDefenseFateRegistry.get_permanent_buff_config(left)
		var right_config := TowerDefenseFateRegistry.get_permanent_buff_config(right)
		return left_config.menu_order < right_config.menu_order
	)
	_apply_runtime_state_to_world()
	return true


func _get_available_permanent_buff_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for config in TowerDefenseFateRegistry.get_all_permanent_buff_configs():
		if not active_permanent_buff_ids.has(config.buff_id):
			result.append(config.buff_id)
	return result


func _get_buff_config(
	buff_id: StringName
) -> TowerDefensePermanentBuffConfig:
	if not has_permanent_buff(buff_id):
		return null
	return TowerDefenseFateRegistry.get_permanent_buff_config(buff_id)


func _set_base_health(new_maximum: int, new_current: int) -> void:
	if home_defense_coordinator == null:
		return
	var resolved_maximum := maxi(new_maximum, 1)
	var resolved_current := (
		resolved_maximum
		if new_current < 0
		else clampi(new_current, 0, resolved_maximum)
	)
	home_defense_coordinator.set_authoritative_base_health(
		resolved_maximum,
		resolved_current
	)


func _begin_collectible_reward() -> void:
	_prune_missing_players()
	if not manager.active or manager.stage != TowerDefenseFateManager.STAGE_RESOLVING:
		return
	var offers_by_peer: Dictionary = {}
	var eligible_snapshot := manager.eligible_peer_ids.duplicate()
	for peer_id in eligible_snapshot:
		var player_instance := _get_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			remove_eligible_peer(peer_id)
			continue
		var offer_paths := luoxi_merchant.build_authoritative_offer_paths(
			player_instance,
			[],
			random_generator,
			LuoxiMerchant.DEFAULT_CHOICE_COUNT
		)
		if offer_paths.size() != LuoxiMerchant.DEFAULT_CHOICE_COUNT:
			push_error("小葱收藏品奖励无法为玩家 %d 生成完整选项。" % peer_id)
			manager.force_finish()
			return
		var wire_paths: Array = []
		for config_path in offer_paths:
			wire_paths.append(str(config_path))
		offers_by_peer[peer_id] = wire_paths
	if not manager.active or manager.stage != TowerDefenseFateManager.STAGE_RESOLVING:
		return
	if offers_by_peer.size() != manager.eligible_peer_ids.size():
		push_error("小葱收藏品奖励的玩家选项未完整生成。")
		manager.force_finish()
		return
	manager.begin_collectible_reward(offers_by_peer)


func _grant_fate_stone_to_all() -> void:
	pending_stone_peer_ids.clear()
	for peer_id in manager.eligible_peer_ids:
		if _peer_has_item(peer_id, FATE_STONE_CONFIG):
			continue
		if not _try_store_item(peer_id, FATE_STONE_CONFIG):
			pending_stone_peer_ids.append(peer_id)
			continue
		_notify_inventory_changed(peer_id)
	if not _finalize_stone_resolution_if_ready():
		manager.notify_external_state_changed()


func _retry_pending_stones() -> void:
	if (
		pending_stone_peer_ids.is_empty()
		or not manager.active
		or manager.stage != TowerDefenseFateManager.STAGE_RESOLVING
	):
		return
	var previous_pending := pending_stone_peer_ids.duplicate()
	var still_pending: Array[int] = []
	for peer_id in pending_stone_peer_ids:
		if not manager.eligible_peer_ids.has(peer_id):
			continue
		if (
			_peer_has_item(peer_id, FATE_STONE_CONFIG)
			or _try_store_item(peer_id, FATE_STONE_CONFIG)
		):
			_notify_inventory_changed(peer_id)
		else:
			still_pending.append(peer_id)
	pending_stone_peer_ids = still_pending
	var finalized := _finalize_stone_resolution_if_ready()
	if not finalized and pending_stone_peer_ids != previous_pending:
		manager.notify_external_state_changed()


func _finalize_stone_resolution_if_ready() -> bool:
	if not pending_stone_peer_ids.is_empty():
		return false
	if (
		not manager.active
		or manager.stage != TowerDefenseFateManager.STAGE_RESOLVING
		or manager.winning_option_id != TowerDefenseFateRegistry.OPTION_FATE_STONE
	):
		return false
	manager.finalize_resolution()
	return true


func _fate_stone_would_benefit_any_peer(peer_ids: Array[int]) -> bool:
	for peer_id in peer_ids:
		if not _peer_has_item(peer_id, FATE_STONE_CONFIG):
			return true
	return false


func _try_store_item(peer_id: int, item: PickupConfig) -> bool:
	if run_state == null:
		return false
	if peer_id > 0:
		return run_state.try_add_item_for_peer(peer_id, item)
	return run_state.try_add_item(item)


func _peer_has_item(peer_id: int, item: PickupConfig) -> bool:
	if run_state == null:
		return false
	return (
		run_state.get_inventory_item_total_for_peer(peer_id, item) > 0
		if peer_id > 0
		else run_state.get_inventory_item_total(item) > 0
	)


func _notify_inventory_changed(peer_id: int) -> void:
	if (
		player_roster_coordinator != null
		and player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and peer_id > 0
	):
		multiplayer_adapter.publish_inventory_changed(peer_id)


func _on_runtime_tick() -> void:
	if (
		player_roster_coordinator == null
		or player_roster_coordinator.runtime_mode
		== CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		return
	manager.advance_stage_timeout(runtime_tick_timer.wait_time)
	_prune_missing_players()
	_retry_pending_stones()
	_apply_regeneration_tick()


func _apply_regeneration_tick() -> void:
	var player_regen := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_PLAYER_REGENERATION
	)
	if player_regen != null:
		for player_instance in _get_all_players():
			if not player_instance.is_dead:
				player_instance.heal(
					ceili(float(player_instance.max_health) * player_regen.magnitude)
				)
	var building_regen := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_BUILDING_REGENERATION
	)
	if (
		building_regen == null
		or campaign_coordinator.wave_state not in [
			CombatFlowState.State.WAVE_ACTIVE,
			CombatFlowState.State.BOSS_ACTIVE,
		]
	):
		return
	for plant_variant in get_tree().get_nodes_in_group(&"plant_defense"):
		var plant := plant_variant as PlantDefense
		if (
			plant == null
			or not is_instance_valid(plant)
			or plant.is_dead
			or plant.is_removing
			or plant.is_multiplayer_proxy
		):
			continue
		plant.receive_healing(roundi(building_regen.magnitude), self)


func _on_manager_state_changed(_state: Dictionary) -> void:
	_apply_runtime_state_to_world()


func _apply_runtime_state_to_world() -> void:
	if player_roster_coordinator == null:
		return
	apply_player_modifiers_to_all()
	apply_enemy_modifiers_to_existing()
	var luoxi_config := _get_buff_config(
		TowerDefenseFateRegistry.BUFF_LUOXI_EXTRA_CHOICE
	)
	if luoxi_config != null:
		LuoxiMerchant.set_runtime_choice_count(roundi(luoxi_config.magnitude))
	else:
		LuoxiMerchant.reset_runtime_choice_count()


func _grant_xirang_to_eligible_players(amount: int) -> void:
	for peer_id in manager.eligible_peer_ids:
		var player_instance := _get_player(peer_id)
		if player_instance != null and is_instance_valid(player_instance):
			player_instance.grant_xirang_reward(amount)


func _clear_eligible_player_xirang() -> void:
	for peer_id in manager.eligible_peer_ids:
		var player_instance := _get_player(peer_id)
		if (
			player_instance != null
			and is_instance_valid(player_instance)
			and player_instance.current_xirang > 0
		):
			player_instance.try_spend_xirang(player_instance.current_xirang)


func _get_player(peer_id: int) -> Player:
	if player_roster_coordinator == null:
		return null
	return player_roster_coordinator.get_player_for_runtime_peer(peer_id)


func _get_all_players() -> Array[Player]:
	return (
		player_roster_coordinator.get_all_players()
		if player_roster_coordinator != null
		else []
	)


func _prune_missing_players() -> void:
	if not manager.active:
		return
	var eligible_snapshot := manager.eligible_peer_ids.duplicate()
	for peer_id in eligible_snapshot:
		var player_instance := _get_player(peer_id)
		if player_instance == null or not is_instance_valid(player_instance):
			remove_eligible_peer(peer_id)


func _variant_to_sorted_peer_ids(value: Variant) -> Array[int]:
	var result: Array[int] = []
	if value is Array or value is PackedInt32Array:
		for entry in value:
			var peer_id := int(entry)
			if peer_id >= 0 and not result.has(peer_id):
				result.append(peer_id)
	result.sort()
	return result
