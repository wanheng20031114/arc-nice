extends MultiplayerModeAdapter
class_name TowerDefenseMultiplayerModeAdapter

signal test_arena_manual_night_changed(enabled: bool)
signal base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
)
signal wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
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


func accepts_game_mode_id(mode_id: int) -> bool:
	return mode_id in [
		GameModeCatalog.MODE_TOWER_DEFENSE,
		GameModeCatalog.MODE_TEST_ARENA_P1,
		GameModeCatalog.MODE_TEST_ARENA_P2,
		GameModeCatalog.MODE_TEST_ARENA_P1B,
	]


func allows_debug_collectible_grants() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.allows_debug_collectible_grants()
	)


func is_terminal_combat_state() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func is_fate_interlude_active() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.wave_state == CombatFlowState.State.FATE_INTERLUDE
	)


func consume_next_player_respawn_delay(peer_id: int) -> float:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.consume_next_player_respawn_delay(peer_id)
		if tower_runtime != null
		else 10.0
	)


func update_player_respawn_countdown(
	peer_id: int,
	seconds_left: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.update_player_respawn_countdown(peer_id, seconds_left)


func clear_player_respawn_countdown(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.clear_player_respawn_countdown(peer_id)


func get_fixed_multiplayer_respawn_position(peer_id: int) -> Variant:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_fixed_multiplayer_respawn_position(peer_id)
		if tower_runtime != null
		else null
	)


func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_flow_state(step_id, state, seconds)


func get_flow_state_snapshot() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return tower_runtime.get_flow_state_snapshot() if tower_runtime != null else {}


func apply_remote_boss_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_boss_started(
			net_id,
			boss_config,
			spawn_position
		)


func apply_remote_defeat() -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_defeat()


func apply_remote_victory() -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_victory()


func apply_remote_enemy_count(alive_count: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_enemy_count(alive_count)


func try_purchase_skill1_for_peer(peer_id: int) -> int:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.try_purchase_skill1_for_peer(peer_id)
		if tower_runtime != null
		else MerchantPurchaseResult.SkillUpgrade.INVALID_PLAYER
	)


func apply_skill1_purchase_state(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_skill1_purchase_state(
			peer_id,
			current_xirang,
			skill1_unlocked,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func show_local_skill1_purchase_result(result_code: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_local_skill1_purchase_result(result_code)


func show_debug_collectible_grant_result(
	config_path: String,
	success: bool
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_debug_collectible_grant_result(config_path, success)


func show_simple_crafting_result(
	recipe_id: StringName,
	result: StringName,
	request_token: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_simple_crafting_result(
			recipe_id,
			result,
			request_token
		)


func apply_remote_merchant_active(active: bool) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_merchant_active(active)


func request_wave_start() -> bool:
	if not has_multiplayer_session():
		return false
	multiplayer_session.request_multiplayer_start_wave()
	return true


func prewarm_mode_runtime_data() -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		await LuoxiMerchant.prewarm_collectible_cache(tower_runtime)


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
		return tower_runtime.apply_authoritative_plant_enemy_damage_batch(
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
		and tower_runtime.request_bamboo_mortar_target(
			owner,
			minimum_range,
			maximum_range,
			callback
		)
	)


func cancel_runtime_bamboo_mortar_target_request(owner: Node) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.cancel_bamboo_mortar_target_request(owner)


func select_runtime_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.select_bamboo_mortar_target_sync_for_fixture(
			center,
			minimum_range,
			maximum_range
		)
		if tower_runtime != null
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
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.queue_bamboo_mortar_explosion(
			landing_position,
			inner_radius,
			outer_radius,
			inner_damage,
			outer_damage,
			damage_source_id
		)
	)


func get_runtime_bamboo_mortar_combat_metrics() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_bamboo_mortar_combat_metrics()
		if tower_runtime != null
		else {}
	)


func get_tower_runtime() -> TowerDefenseGame:
	return runtime as TowerDefenseGame


func request_authoritative_wave_start(requester_peer_id: int) -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.request_tower_defense_wave_start(requester_peer_id)
	)


func get_base_health_snapshot() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_base_health_snapshot()
		if tower_runtime != null
		else {}
	)


func apply_remote_base_health(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_base_health(
			current_health,
			maximum_health,
			revision
		)


func apply_remote_enemy_escape(net_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_enemy_escape(net_id)


func get_wave_progress_snapshot() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_tower_defense_wave_progress_snapshot()
		if tower_runtime != null
		else {}
	)


func apply_remote_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_tower_defense_wave_progress(
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
	if tower_runtime != null:
		tower_runtime.request_multiplayer_plant_placement(
			requester_peer_id,
			request_id,
			plant_id,
			anchor
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
	if tower_runtime != null:
		tower_runtime.request_multiplayer_inventory_plant_placement(
			requester_peer_id,
			request_id,
			plant_id,
			anchor,
			slot_index,
			expected_inventory_revision,
			item_config_path
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
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_plant_spawn(
			request_id,
			owner_peer_id,
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
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_plant_health(
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
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		return
	if silent:
		tower_runtime.apply_remote_plant_removed_silently(net_id)
	else:
		tower_runtime.apply_remote_plant_removed_with_reason(
			net_id,
			was_destroyed
		)


func apply_remote_plant_placement_rejected(
	request_id: int,
	reason: StringName
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_plant_placement_rejected(request_id, reason)


func has_multiplayer_plant(net_id: int) -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.has_multiplayer_plant(net_id)
	)


func get_multiplayer_plant_node(net_id: int) -> PlantDefense:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_multiplayer_plant_node(net_id)
		if tower_runtime != null
		else null
	)


func get_multiplayer_plant_snapshots() -> Array[Dictionary]:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_multiplayer_plant_snapshots()
		if tower_runtime != null
		else []
	)


func get_authoritative_team_plant_count() -> int:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.plant_system == null:
		return -1
	return tower_runtime.plant_system.plants_by_net_id.size()


func find_nearest_operational_interaction_building(
	world_position: Vector2,
	maximum_distance: float
) -> PlantDefense:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.plant_system == null:
		return null
	return tower_runtime.plant_system.find_nearest_operational_interaction_building_world(
		world_position,
		maximum_distance
	)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null:
		result.clear()
		return
	tower_runtime.query_living_plants_in_radius_into(center, radius, result)


func configure_runtime_enemy_modifiers(enemy_instance: Enemy) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.configure_runtime_enemy_modifiers(enemy_instance)


func supports_terrain_state() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.supports_multiplayer_terrain_state()
	)


func get_terrain_snapshot() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_multiplayer_terrain_snapshot()
		if tower_runtime != null
		else {}
	)


func apply_remote_terrain_snapshot(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.apply_remote_terrain_snapshot(
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
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.apply_remote_terrain_delta(
			revision,
			cell_xy,
			terrain_types
		)
	)


func request_xiaocong_interaction(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.request_xiaocong_interaction(peer_id)


func request_xiaocong_fate_vote(
	peer_id: int,
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.request_xiaocong_fate_vote(
			peer_id,
			option_id,
			permanent_buff_id
		)


func request_xiaocong_collectible_choice(
	peer_id: int,
	choice_index: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.request_xiaocong_collectible_choice(peer_id, choice_index)


func get_xiaocong_fate_state_snapshot() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_xiaocong_fate_state_snapshot()
		if tower_runtime != null
		else {}
	)


func apply_remote_xiaocong_fate_state(state: Dictionary) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.apply_remote_xiaocong_fate_state(state)


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
	var tower_runtime := get_tower_runtime()
	return (
		int(tower_runtime.multiplayer_spawn_slot_indices.get(peer_id, 0))
		if tower_runtime != null
		else 0
	)


func get_reconnect_wave_death_count(peer_id: int) -> int:
	var tower_runtime := get_tower_runtime()
	return (
		int(tower_runtime.player_wave_death_counts.get(peer_id, 0))
		if tower_runtime != null
		else 0
	)


func get_completed_global_research_ids() -> Array[StringName]:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.research_coordinator == null:
		return []
	return tower_runtime.research_coordinator.get_completed_global_research_ids()


func get_research_runtime_state() -> Dictionary:
	var tower_runtime := get_tower_runtime()
	if tower_runtime == null or tower_runtime.research_coordinator == null:
		return {}
	return tower_runtime.research_coordinator.export_runtime_state()


func apply_remote_research_runtime_state(state: Dictionary) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null and tower_runtime.research_coordinator != null:
		tower_runtime.research_coordinator.apply_multiplayer_runtime_state(state)


func connect_research_milestone_changed(callback: Callable) -> bool:
	var tower_runtime := get_tower_runtime()
	if (
		tower_runtime == null
		or tower_runtime.research_coordinator == null
		or not callback.is_valid()
	):
		return false
	if not tower_runtime.research_coordinator.research_milestone_changed.is_connected(
		callback
	):
		tower_runtime.research_coordinator.research_milestone_changed.connect(callback)
	return true


func get_luoxi_merchant() -> LuoxiMerchant:
	var tower_runtime := get_tower_runtime()
	return tower_runtime.luoxi_merchant if tower_runtime != null else null


func runtime_try_refresh_luoxi_collectibles_for_peer(peer_id: int) -> int:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.try_refresh_luoxi_collectibles_for_peer(peer_id)
		if tower_runtime != null
		else MerchantPurchaseResult.OfferRefresh.INVALID_PLAYER
	)


func runtime_get_luoxi_collectible_refresh_count(peer_id: int) -> int:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.get_luoxi_collectible_refresh_count(peer_id)
		if tower_runtime != null
		else 0
	)


func runtime_try_claim_luoxi_collectible_for_peer(
	peer_id: int,
	config_path_or_choice: Variant
) -> int:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.try_claim_luoxi_collectible_for_peer(
			peer_id,
			config_path_or_choice
		)
		if tower_runtime != null
		else MerchantPurchaseResult.CollectibleClaim.INVALID_PLAYER
	)


func runtime_has_luoxi_collectible_claimed(peer_id: int) -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.has_luoxi_collectible_claimed(peer_id)
	)


func runtime_record_luoxi_collectible_claim(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.record_luoxi_collectible_claim(peer_id)


func runtime_mark_luoxi_collectible_claimed(peer_id: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.mark_luoxi_collectible_claimed(peer_id)


func show_local_luoxi_collectible_result(result_code: int) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_local_luoxi_collectible_result(result_code)


func show_local_luoxi_refresh_result(
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_local_luoxi_refresh_result(
			result_code,
			refresh_count,
			current_xirang
		)


func runtime_supports_luoxi_special_game() -> bool:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime != null
		and tower_runtime.supports_luoxi_special_game()
	)


func runtime_try_start_luoxi_special_game_for_peer(peer_id: int) -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.try_start_luoxi_special_game_for_peer(peer_id)
		if tower_runtime != null
		else {"result_code": 1}
	)


func runtime_try_reveal_luoxi_special_game_card_for_peer(
	peer_id: int,
	session_revision: int,
	card_index: int
) -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.try_reveal_luoxi_special_game_card_for_peer(
			peer_id,
			session_revision,
			card_index
		)
		if tower_runtime != null
		else {"result_code": 1}
	)


func runtime_try_finish_luoxi_special_game_for_peer(
	peer_id: int,
	session_revision: int
) -> Dictionary:
	var tower_runtime := get_tower_runtime()
	return (
		tower_runtime.try_finish_luoxi_special_game_for_peer(
			peer_id,
			session_revision
		)
		if tower_runtime != null
		else {"result_code": 1}
	)


func show_local_luoxi_special_game_started(result: Dictionary) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_local_luoxi_special_game_started(result)


func show_local_luoxi_special_game_card_revealed(result: Dictionary) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_local_luoxi_special_game_card_revealed(result)


func show_local_luoxi_special_game_finished(result: Dictionary) -> void:
	var tower_runtime := get_tower_runtime()
	if tower_runtime != null:
		tower_runtime.show_local_luoxi_special_game_finished(result)


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
	var tower_runtime := runtime as TowerDefenseGame
	return (
		tower_runtime != null
		and tower_runtime.begin_inventory_building_placement(
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
	var tower_runtime := runtime as TowerDefenseGame
	if tower_runtime == null:
		return false
	tower_runtime.request_luoxi_collectible_choice(choice_index, config_path)
	return true


func request_luoxi_collectible_refresh(offer_revision: int) -> bool:
	if super.request_luoxi_collectible_refresh(offer_revision):
		return true
	var tower_runtime := runtime as TowerDefenseGame
	if tower_runtime == null:
		return false
	tower_runtime.request_luoxi_collectible_refresh()
	return true


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	if has_multiplayer_session():
		return super.has_luoxi_collectible_claimed(peer_id)
	var tower_runtime := runtime as TowerDefenseGame
	return (
		tower_runtime != null
		and tower_runtime.has_luoxi_collectible_claimed(peer_id)
	)


func supports_luoxi_special_game() -> bool:
	if has_multiplayer_session():
		return multiplayer_session.supports_luoxi_special_game()
	var tower_runtime := runtime as TowerDefenseGame
	return (
		tower_runtime != null
		and tower_runtime.supports_luoxi_special_game()
	)


func request_luoxi_special_game_start() -> bool:
	if has_multiplayer_session():
		multiplayer_session.request_luoxi_special_game_start()
		return true
	var tower_runtime := runtime as TowerDefenseGame
	if tower_runtime == null:
		return false
	tower_runtime.request_luoxi_special_game_start()
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
	var tower_runtime := runtime as TowerDefenseGame
	if tower_runtime == null:
		return false
	tower_runtime.request_luoxi_special_game_card_reveal(
		session_revision,
		card_index
	)
	return true


func request_luoxi_special_game_finish(session_revision: int) -> bool:
	if has_multiplayer_session():
		multiplayer_session.request_luoxi_special_game_finish(session_revision)
		return true
	var tower_runtime := runtime as TowerDefenseGame
	if tower_runtime == null:
		return false
	tower_runtime.request_luoxi_special_game_finish(session_revision)
	return true
