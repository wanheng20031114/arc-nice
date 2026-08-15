extends Node
class_name TowerDefenseEnemyCoordinator

signal wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
)
signal wave_completed

const ENEMY_RETARGET_INTERVAL_SECONDS := 0.60
const ENEMY_RETARGET_MAX_PER_PHYSICS_FRAME := 16
const AUTHORED_LOGICAL_TILE_SIZE := 16.0
const PLANT_OBJECTIVE_AGGRO_RADIUS_CELLS := 8.0
const PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS := 10.0
const PLAYER_NEAR_MOVING_DIRECT_DISTANCE_CELLS := 16.0
const PLAYER_NEAR_MOVING_DIRECT_DISTANCE := (
	PLAYER_NEAR_MOVING_DIRECT_DISTANCE_CELLS * AUTHORED_LOGICAL_TILE_SIZE
)

var _runtime: CombatRuntimeBase
var _campaign_coordinator: TowerDefenseCampaignCoordinator
var _player_roster_coordinator: TowerDefensePlayerRosterCoordinator
var _plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator
var _enemy_container: Node2D
var _boss_container: Node2D
var _enemy_spawn_points_root: Node2D
var _ground_tile_map_layer: TileMapLayer
var _grid_pathfinder: GridPathfinder
var _enemy_spawn_timer: Timer
var _multiplayer_gateway: MultiplayerGameplayGateway
var _fate_coordinator: FateCoordinator
var _presentation_coordinator: TowerDefensePresentationCoordinator
var _session_object_pool: SessionObjectPool
var _enemy_spawn_effect_scene: PackedScene
var enemy_spawn_points: Array[Marker2D] = []
var enemy_spawn_points_by_name: Dictionary[StringName, Marker2D] = {}
var active_wave_spawn_points: Array[Marker2D] = []
var pending_enemy_configs: Array[EnemyConfig] = []
var pending_enemy_xirang_kill_rewards: Array[int] = []
var active_wave_enemy_ids: Dictionary = {}
var resolved_active_enemy_ids: Dictionary = {}
var hud_alive_enemy_ids: Dictionary = {}

var spawn_point_configuration_valid := true
var pending_enemy_config_index := 0
var next_multiplayer_enemy_net_id := 1
var enemy_retarget_time_left := 0.0
var enemy_retarget_sweep_remaining := 0
var enemy_retarget_cursor := 0
var _home_objective_targets: Array[Node2D] = []
var _pending_terminal_escape_net_ids: Dictionary = {}

var _random_generator: RandomNumberGenerator


func setup(
	runtime: CombatRuntimeBase,
	campaign_coordinator: TowerDefenseCampaignCoordinator,
	player_roster_coordinator: TowerDefensePlayerRosterCoordinator,
	plant_runtime_coordinator: TowerDefensePlantRuntimeCoordinator,
	random_generator: RandomNumberGenerator,
	enemy_container: Node2D,
	boss_container: Node2D,
	enemy_spawn_points_root: Node2D,
	ground_tile_map_layer: TileMapLayer,
	grid_pathfinder: GridPathfinder,
	enemy_spawn_timer: Timer,
	multiplayer_gateway: MultiplayerGameplayGateway,
	fate_coordinator: FateCoordinator,
	presentation_coordinator: TowerDefensePresentationCoordinator,
	session_object_pool: SessionObjectPool,
	enemy_spawn_effect_scene: PackedScene
) -> void:
	assert(runtime != null, "EnemyCoordinator 缺少 CombatRuntimeBase 运行时。")
	assert(campaign_coordinator != null, "EnemyCoordinator 缺少 CampaignCoordinator。")
	assert(player_roster_coordinator != null, "EnemyCoordinator 缺少 PlayerRosterCoordinator。")
	assert(plant_runtime_coordinator != null, "EnemyCoordinator 缺少 PlantRuntimeCoordinator。")
	assert(random_generator != null, "EnemyCoordinator 必须复用运行时 RNG。")
	assert(enemy_container != null, "EnemyCoordinator 缺少 EnemyContainer。")
	assert(boss_container != null, "EnemyCoordinator 缺少 BossContainer。")
	assert(enemy_spawn_points_root != null, "EnemyCoordinator 缺少 EnemySpawnPoints。")
	assert(ground_tile_map_layer != null, "EnemyCoordinator 缺少 Ground TileMapLayer。")
	assert(grid_pathfinder != null, "EnemyCoordinator 缺少强类型 GridPathfinder。")
	assert(enemy_spawn_timer != null, "EnemyCoordinator 缺少 EnemySpawnTimer。")
	assert(multiplayer_gateway != null, "EnemyCoordinator 缺少多人网关。")
	assert(fate_coordinator != null, "EnemyCoordinator 缺少命运协调器。")
	assert(presentation_coordinator != null, "EnemyCoordinator 缺少表现协调器。")
	assert(session_object_pool != null, "EnemyCoordinator 缺少会话对象池。")
	assert(enemy_spawn_effect_scene != null, "EnemyCoordinator 缺少出生特效场景。")
	_runtime = runtime
	_campaign_coordinator = campaign_coordinator
	_player_roster_coordinator = player_roster_coordinator
	_plant_runtime_coordinator = plant_runtime_coordinator
	_random_generator = random_generator
	_enemy_container = enemy_container
	_boss_container = boss_container
	_enemy_spawn_points_root = enemy_spawn_points_root
	_ground_tile_map_layer = ground_tile_map_layer
	_grid_pathfinder = grid_pathfinder
	_enemy_spawn_timer = enemy_spawn_timer
	_multiplayer_gateway = multiplayer_gateway
	_fate_coordinator = fate_coordinator
	_presentation_coordinator = presentation_coordinator
	_session_object_pool = session_object_pool
	_enemy_spawn_effect_scene = enemy_spawn_effect_scene
	_pending_terminal_escape_net_ids.clear()
	collect_spawn_points(_enemy_spawn_points_root)


func is_bound() -> bool:
	return (
		_runtime != null
		and _campaign_coordinator != null
		and _player_roster_coordinator != null
		and _plant_runtime_coordinator != null
		and _enemy_container != null
		and _boss_container != null
		and _enemy_spawn_points_root != null
		and _ground_tile_map_layer != null
		and _grid_pathfinder != null
		and _enemy_spawn_timer != null
		and _multiplayer_gateway != null
		and _fate_coordinator != null
		and _presentation_coordinator != null
		and _session_object_pool != null
		and _enemy_spawn_effect_scene != null
		and _random_generator != null
	)


func collect_spawn_points(spawn_points_root: Node2D) -> void:
	enemy_spawn_points.clear()
	enemy_spawn_points_by_name.clear()
	active_wave_spawn_points.clear()
	spawn_point_configuration_valid = true
	if spawn_points_root == null:
		push_error("EnemyCoordinator 缺少 EnemySpawnPoints 根节点。")
		spawn_point_configuration_valid = false
		return
	for child in spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point == null:
			continue
		var spawn_name := StringName(spawn_point.name)
		if enemy_spawn_points_by_name.has(spawn_name):
			push_error("EnemySpawnPoints 包含重复名称：%s" % String(spawn_name))
			spawn_point_configuration_valid = false
			continue
		enemy_spawn_points.append(spawn_point)
		enemy_spawn_points_by_name[spawn_name] = spawn_point
	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")


func inspect_spawn_points(wave_config: WaveConfig) -> Dictionary:
	var points: Array[Marker2D] = []
	if wave_config == null or not spawn_point_configuration_valid:
		return {"valid": false, "points": points, "error": ""}
	var enabled_names := wave_config.get_enabled_spawn_point_names()
	if enabled_names.is_empty():
		return {
			"valid": false,
			"points": points,
			"error": "波次 %s 没有启用任何出生点。" % wave_config.get_flow_display_name(),
		}
	for spawn_name in enabled_names:
		var marker := enemy_spawn_points_by_name.get(spawn_name) as Marker2D
		if marker == null:
			return {
				"valid": false,
				"points": points,
				"error": (
					"波次 %s 引用了场景中不存在的出生点 %s。"
					% [wave_config.get_flow_display_name(), String(spawn_name)]
				),
			}
		points.append(marker)
	return {"valid": true, "points": points, "error": ""}


func resolve_spawn_points(wave_config: WaveConfig) -> bool:
	active_wave_spawn_points.clear()
	var resolution := inspect_spawn_points(wave_config)
	if not bool(resolution.get("valid", false)):
		var error_message := str(resolution.get("error", ""))
		if not error_message.is_empty():
			push_error(error_message)
		return false
	active_wave_spawn_points.assign(resolution.get("points", []))
	return not active_wave_spawn_points.is_empty()


func begin_wave(
	wave_config: WaveConfig,
	progression_config: TowerDefenseProgressionConfig,
	player_count: int
) -> int:
	assert(is_bound(), "EnemyCoordinator 尚未 setup。")
	clear_queue()
	if wave_config == null or progression_config == null:
		return 0
	if wave_config.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN:
		_build_entry_round_robin_queue(
			wave_config, progression_config, player_count
		)
	else:
		_build_shuffled_queue(
			wave_config, progression_config, player_count
		)
	return pending_enemy_configs.size()


func _build_shuffled_queue(
	wave_config: WaveConfig,
	progression_config: TowerDefenseProgressionConfig,
	player_count: int
) -> void:
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var scaled_count := progression_config.get_scaled_enemy_count(
			maxi(entry.count, 0), maxi(player_count, 1)
		)
		for _enemy_index in range(scaled_count):
			var resolved := _fate_coordinator.resolve_enemy_config(entry.enemy_config)
			pending_enemy_configs.append(resolved)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(resolved)
			)
	for source_index in range(pending_enemy_configs.size() - 1, 0, -1):
		var target_index := _random_generator.randi_range(0, source_index)
		var config := pending_enemy_configs[source_index]
		pending_enemy_configs[source_index] = pending_enemy_configs[target_index]
		pending_enemy_configs[target_index] = config
		var reward := pending_enemy_xirang_kill_rewards[source_index]
		pending_enemy_xirang_kill_rewards[source_index] = (
			pending_enemy_xirang_kill_rewards[target_index]
		)
		pending_enemy_xirang_kill_rewards[target_index] = reward


func _build_entry_round_robin_queue(
	wave_config: WaveConfig,
	progression_config: TowerDefenseProgressionConfig,
	player_count: int
) -> void:
	var entries: Array[WaveEnemyEntry] = []
	var remaining_counts: Array[int] = []
	var remaining_total := 0
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var scaled_count := maxi(
			progression_config.get_scaled_enemy_count(
				maxi(entry.count, 0), maxi(player_count, 1)
			), 0
		)
		if scaled_count <= 0:
			continue
		entries.append(entry)
		remaining_counts.append(scaled_count)
		remaining_total += scaled_count
	while remaining_total > 0:
		for entry_index in range(entries.size()):
			if remaining_counts[entry_index] <= 0:
				continue
			var entry := entries[entry_index]
			var resolved := _fate_coordinator.resolve_enemy_config(entry.enemy_config)
			pending_enemy_configs.append(resolved)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(resolved)
			)
			remaining_counts[entry_index] -= 1
			remaining_total -= 1


func tick(max_alive_enemies: int, spawn_count_per_tick: int) -> int:
	assert(is_bound(), "EnemyCoordinator 尚未 setup。")
	var spawned_count := 0
	var spawn_limit := maxi(spawn_count_per_tick, 1)
	for _spawn_index in range(spawn_limit):
		if not has_pending_queue() or active_wave_enemy_ids.size() >= maxi(max_alive_enemies, 1):
			break
		if not try_spawn_enemy(
			pending_enemy_configs[pending_enemy_config_index],
			pending_enemy_xirang_kill_rewards[pending_enemy_config_index]
		):
			break
		pending_enemy_config_index += 1
		spawned_count += 1
	return spawned_count


func has_pending_queue() -> bool:
	return pending_enemy_config_index < pending_enemy_configs.size()


func clear_queue() -> void:
	pending_enemy_configs.clear()
	pending_enemy_xirang_kill_rewards.clear()
	pending_enemy_config_index = 0


func pick_spawn_point() -> Marker2D:
	if active_wave_spawn_points.is_empty():
		return null
	return active_wave_spawn_points[
		_random_generator.randi_range(0, active_wave_spawn_points.size() - 1)
	]


func get_spawn_marker(marker_name: StringName) -> Marker2D:
	if marker_name == &"":
		return null
	var marker := enemy_spawn_points_by_name.get(marker_name) as Marker2D
	if marker != null:
		return marker
	if _enemy_spawn_points_root == null:
		return null
	return _enemy_spawn_points_root.get_node_or_null(
		NodePath(String(marker_name))
	) as Marker2D


func register_external_enemy(enemy: Enemy) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var enemy_id := enemy.get_instance_id()
	active_wave_enemy_ids[enemy_id] = true
	resolved_active_enemy_ids.erase(enemy_id)


func has_active_enemy(enemy_id: int) -> bool:
	return active_wave_enemy_ids.has(enemy_id)


func remove_active_enemy(enemy_id: int) -> bool:
	return active_wave_enemy_ids.erase(enemy_id)


func clear_active_enemies() -> void:
	active_wave_enemy_ids.clear()
	resolved_active_enemy_ids.clear()


func has_active_enemies() -> bool:
	return not active_wave_enemy_ids.is_empty()


func try_resolve_active_enemy_defeat(enemy_id: int) -> bool:
	if (
		enemy_id <= 0
		or not active_wave_enemy_ids.has(enemy_id)
		or resolved_active_enemy_ids.has(enemy_id)
		or not _campaign_coordinator.try_resolve_wave_enemy_defeat()
	):
		return false
	resolved_active_enemy_ids[enemy_id] = true
	return true


func try_resolve_active_enemy_escape(enemy_id: int) -> bool:
	if (
		enemy_id <= 0
		or not active_wave_enemy_ids.has(enemy_id)
		or resolved_active_enemy_ids.has(enemy_id)
		or not _campaign_coordinator.try_resolve_wave_enemy_escape()
	):
		return false
	resolved_active_enemy_ids[enemy_id] = true
	active_wave_enemy_ids.erase(enemy_id)
	return true


func add_hud_enemy(enemy_id: int) -> bool:
	if hud_alive_enemy_ids.has(enemy_id):
		return false
	hud_alive_enemy_ids[enemy_id] = true
	return true


func remove_hud_enemy(enemy_id: int) -> bool:
	return hud_alive_enemy_ids.erase(enemy_id)


func clear_hud_enemies() -> void:
	hud_alive_enemy_ids.clear()


func hud_enemy_count() -> int:
	return hud_alive_enemy_ids.size()


func get_enemy(net_id: int) -> Enemy:
	return _runtime.get_network_enemy(net_id)


func take_remote_enemy_for_escape(net_id: int) -> Enemy:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or net_id <= 0:
		return null
	var enemy := get_enemy(net_id)
	if enemy == null:
		return null
	_runtime.unregister_network_enemy(net_id, enemy)
	return enemy


func get_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> Dictionary:
	return {
		"wave_number": wave_number,
		"defeated": defeated,
		"escaped": escaped,
		"resolved": resolved,
		"total": total,
	}


func report_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	wave_progress_changed.emit(wave_number, defeated, escaped, resolved, total)


func spawn_wave_batch(max_spawn_count_per_tick: int) -> void:
	if _campaign_coordinator.wave_state != CombatFlowState.State.WAVE_ACTIVE:
		_enemy_spawn_timer.stop()
		return

	var wave_config := _campaign_coordinator.current_flow_step as WaveConfig
	if wave_config == null:
		_enemy_spawn_timer.stop()
		return

	var spawn_count_this_tick := mini(
		maxi(wave_config.spawn_count_per_tick, 1),
		maxi(max_spawn_count_per_tick, 1)
	)
	var spawned_count := tick(
		wave_config.max_alive_enemies,
		spawn_count_this_tick
	)
	var recorded_spawn_count := _campaign_coordinator.record_wave_spawns(spawned_count)
	assert(
		recorded_spawn_count == spawned_count,
		"EnemyCoordinator 生成数超出 Campaign 波次总数。"
	)

	if not has_pending_queue():
		_enemy_spawn_timer.stop()
		clear_queue()

	check_wave_completion()


func on_spawn_timer_timeout() -> void:
	spawn_wave_batch(TowerDefenseCampaignCoordinator.MAX_WAVE_SPAWN_COUNT_PER_TICK)


func try_spawn_enemy(
	enemy_config: EnemyConfig,
	xirang_kill_reward_override: int = -1
) -> bool:
	if not is_spawn_system_ready() or enemy_config == null:
		return false

	var spawn_point := pick_spawn_point()
	if spawn_point == null:
		return false

	var spawn_scene := enemy_config.enemy_scene
	if spawn_scene == null:
		push_warning("敌人配置 %s 缺少 enemy_scene。" % enemy_config.resource_path)
		return false
	var enemy_instance := spawn_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("敌人场景实例化失败，请检查波次中的敌人配置。")
		return false

	_enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_point.global_position
	enemy_instance.setup(
		enemy_config,
		pick_enemy_target(spawn_point.global_position),
		_grid_pathfinder,
		_runtime
	)
	enemy_instance.set_xirang_kill_reward_override(xirang_kill_reward_override)
	assign_enemy_targets(enemy_instance, spawn_point.global_position)
	var enemy_id := enemy_instance.get_instance_id()
	register_external_enemy(enemy_instance)
	enemy_instance.defeated.connect(_on_wave_enemy_defeated)
	enemy_instance.tree_exited.connect(handle_wave_enemy_tree_exited.bind(enemy_id))
	finalize_authoritative_enemy_spawn(
		enemy_instance,
		enemy_config,
		enemy_instance.global_position
	)
	spawn_enemy_spawn_effect(spawn_point.global_position)
	return true


func finalize_authoritative_enemy_spawn(
	enemy_instance: Enemy,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	broadcast_spawn: bool = true
) -> int:
	configure_runtime_enemy_modifiers(enemy_instance)
	configure_authoritative_enemy_physics_interpolation(enemy_instance)
	var enemy_net_id := register_multiplayer_enemy_instance(
		enemy_instance,
		enemy_config,
		spawn_position,
		broadcast_spawn
	)
	register_hud_alive_enemy(enemy_instance)
	return enemy_net_id


func configure_runtime_enemy_modifiers(enemy_instance: Enemy) -> void:
	_fate_coordinator.configure_enemy_modifiers(enemy_instance)


func register_multiplayer_enemy_instance(
	enemy_instance: Enemy,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	broadcast_spawn: bool = true
) -> int:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return 0
	if enemy_instance == null or enemy_config == null:
		return 0
	var enemy_id := enemy_instance.get_instance_id()
	var existing_net_id := _runtime.get_network_enemy_net_id_by_instance_id(enemy_id)
	if existing_net_id > 0:
		return existing_net_id
	var enemy_net_id := next_multiplayer_enemy_net_id
	next_multiplayer_enemy_net_id += 1
	if not _runtime.register_network_enemy(enemy_net_id, enemy_instance):
		return 0
	if broadcast_spawn:
		_multiplayer_gateway.enemy_spawned.emit(
			enemy_net_id,
			enemy_config,
			spawn_position
		)
	return enemy_net_id


func configure_authoritative_enemy_physics_interpolation(enemy_instance: Enemy) -> void:
	if (
		_runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or enemy_instance == null
		or not is_instance_valid(enemy_instance)
	):
		return
	# Authoritative enemies and the local camera must share Godot's interpolated
	# physics timeline. Client proxies stay on NetInterpolator's render clock.
	enemy_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
	enemy_instance.reset_physics_interpolation()


func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	if _campaign_coordinator.wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	if enemy == null or not try_resolve_active_enemy_defeat(enemy.get_instance_id()):
		return
	remove_hud_alive_enemy(enemy.get_instance_id())
	emit_multiplayer_enemy_defeated(enemy)
	show_wave_progress()
	check_wave_completion()


func emit_multiplayer_enemy_defeated(enemy: Enemy) -> void:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if enemy == null:
		return
	var enemy_net_id := _runtime.get_network_enemy_net_id_by_instance_id(
		enemy.get_instance_id()
	)
	if enemy_net_id <= 0:
		return
	_multiplayer_gateway.enemy_defeated.emit(enemy_net_id, enemy.global_position)


func emit_multiplayer_enemy_escaped(enemy: Enemy) -> void:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	var enemy_net_id := _runtime.get_network_enemy_net_id_by_instance_id(
		enemy.get_instance_id()
	)
	if enemy_net_id <= 0:
		return
	_pending_terminal_escape_net_ids[enemy_net_id] = true
	_multiplayer_gateway.enemy_escaped.emit(enemy_net_id)


func register_remote_proxy_indices(enemy: Enemy, net_id: int) -> void:
	if enemy == null or net_id <= 0:
		return
	_runtime.register_network_enemy(net_id, enemy)


func collect_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return _runtime.collect_reused_enemy_snapshot_states(
		_enemy_container,
		_boss_container
	)


func handle_wave_enemy_tree_exited(enemy_id: int) -> void:
	remove_active_enemy(enemy_id)
	resolved_active_enemy_ids.erase(enemy_id)
	remove_hud_alive_enemy(enemy_id)
	mark_multiplayer_enemy_removed(enemy_id)
	check_wave_completion()


func mark_multiplayer_enemy_removed(enemy_id: int) -> void:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	var enemy_net_id := _runtime.unregister_network_enemy_by_instance_id(enemy_id)
	if enemy_net_id <= 0:
		return
	# Escape is the terminal replication event. Its marker is consumed exactly
	# once by the ensuing tree exit; normal exits still emit enemy_removed.
	if _pending_terminal_escape_net_ids.erase(enemy_net_id):
		return
	_multiplayer_gateway.enemy_removed.emit(enemy_net_id)


func check_wave_completion() -> void:
	if _campaign_coordinator.wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	if has_pending_queue():
		return
	if not _campaign_coordinator.is_wave_progress_complete():
		return
	if has_active_enemies():
		return

	_enemy_spawn_timer.stop()
	wave_completed.emit()


func finish_home_wave_escape() -> void:
	show_wave_progress()
	check_wave_completion()


func register_hud_alive_enemy(enemy: Enemy) -> void:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	if not add_hud_enemy(enemy.get_instance_id()):
		return
	_update_hud_alive_enemy_count()


func remove_hud_alive_enemy(enemy_id: int) -> void:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	if not remove_hud_enemy(enemy_id):
		return
	_update_hud_alive_enemy_count()


func clear_hud_alive_enemies() -> void:
	if _runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	clear_hud_enemies()
	_update_hud_alive_enemy_count()


func _update_hud_alive_enemy_count() -> void:
	_presentation_coordinator.show_enemy_count(hud_enemy_count())


func show_wave_progress() -> void:
	_presentation_coordinator.show_wave_progress(
		_campaign_coordinator.current_wave_index + 1,
		_campaign_coordinator.current_wave_defeated,
		_campaign_coordinator.current_wave_escaped,
		_campaign_coordinator.current_wave_resolved,
		_campaign_coordinator.current_wave_total
	)
	report_progress(
		_campaign_coordinator.current_wave_index + 1,
		_campaign_coordinator.current_wave_defeated,
		_campaign_coordinator.current_wave_escaped,
		_campaign_coordinator.current_wave_resolved,
		_campaign_coordinator.current_wave_total
	)


func get_wave_progress_snapshot() -> Dictionary:
	return _campaign_coordinator.get_replicated_wave_progress_snapshot()


func apply_remote_wave_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	if not _campaign_coordinator.apply_remote_wave_progress(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	):
		return
	show_wave_progress()


func is_spawn_system_ready() -> bool:
	return (
		_player_roster_coordinator.local_player != null
		and _grid_pathfinder.is_built
		and not enemy_spawn_points.is_empty()
	)


func spawn_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	if not _runtime.try_reserve_enemy_spawn_effect(spawn_global_position):
		return
	var effect := _session_object_pool.acquire(_enemy_spawn_effect_scene) as Node2D
	if effect == null:
		return
	effect.global_position = spawn_global_position
	if effect.has_method("restart_effect"):
		effect.call("restart_effect")


func update_targets(delta: float) -> void:
	enemy_retarget_time_left = maxf(enemy_retarget_time_left - delta, 0.0)
	if enemy_retarget_time_left <= 0.0 and enemy_retarget_sweep_remaining <= 0:
		enemy_retarget_time_left = ENEMY_RETARGET_INTERVAL_SECONDS
		enemy_retarget_sweep_remaining = _enemy_container.get_child_count()
		var boss_enemy := _get_active_boss_target()
		if (
			boss_enemy != null
			and is_instance_valid(boss_enemy)
			and not boss_enemy.is_dead
			and not boss_enemy.is_advancing_to_home()
		):
			assign_enemy_targets(boss_enemy, boss_enemy.global_position)
	_process_retarget_budget()


func _process_retarget_budget() -> void:
	var processed_count := 0
	while (
		enemy_retarget_sweep_remaining > 0
		and processed_count < ENEMY_RETARGET_MAX_PER_PHYSICS_FRAME
	):
		var enemy_count := _enemy_container.get_child_count()
		if enemy_count <= 0:
			enemy_retarget_sweep_remaining = 0
			enemy_retarget_cursor = 0
			return
		if enemy_retarget_cursor >= enemy_count:
			enemy_retarget_cursor = 0
		var enemy := _enemy_container.get_child(enemy_retarget_cursor) as Enemy
		enemy_retarget_cursor = (enemy_retarget_cursor + 1) % enemy_count
		enemy_retarget_sweep_remaining -= 1
		processed_count += 1
		if enemy == null or enemy.is_dead:
			continue
		assign_enemy_targets(enemy, enemy.global_position)


func assign_enemy_targets(enemy: Enemy, from_position: Vector2) -> void:
	if enemy == null or enemy.is_dead:
		return
	enemy.set_near_moving_target_direct_distance(
		PLAYER_NEAR_MOVING_DIRECT_DISTANCE
	)
	var combat_player := pick_enemy_target(from_position)
	var objective := _pick_enemy_objective(
		from_position,
		combat_player,
		enemy.can_target_water_plant_objectives()
	)
	enemy.set_target_player(combat_player)
	enemy.set_objective_target(objective)


func pick_enemy_target(from_position: Vector2) -> Player:
	if _runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		var local_player := _player_roster_coordinator.local_player
		return (
			local_player
			if local_player != null and not local_player.is_dead
			else null
		)
	var best_player: Player = null
	var best_distance := INF
	for peer_id_variant in _player_roster_coordinator.peer_players:
		var candidate := (
			_player_roster_coordinator.peer_players[peer_id_variant] as Player
		)
		if (
			candidate == null
			or not is_instance_valid(candidate)
			or candidate.is_dead
		):
			continue
		var distance := from_position.distance_squared_to(candidate.global_position)
		if distance < best_distance:
			best_distance = distance
			best_player = candidate
	return best_player


func _pick_enemy_objective(
	from_position: Vector2,
	combat_player: Player,
	include_water_plants: bool = false
) -> Node2D:
	var nearest_plant := _plant_runtime_coordinator.find_nearest_enemy_objective(
		from_position,
		PLANT_OBJECTIVE_AGGRO_RADIUS_CELLS,
		include_water_plants
	)
	if nearest_plant != null:
		return nearest_plant
	if (
		combat_player != null
		and is_instance_valid(combat_player)
		and not combat_player.is_dead
		and _get_logical_tile_distance_squared(
			from_position,
			combat_player.global_position
		) <= PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS * PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS
	):
		return combat_player
	return _get_nearest_home_target(from_position)


func set_home_objective_targets(targets: Array[Node2D]) -> void:
	_home_objective_targets.assign(targets)


func _get_active_boss_target() -> Enemy:
	for child in _boss_container.get_children():
		var candidate := child as Enemy
		if (
			candidate != null
			and is_instance_valid(candidate)
			and not candidate.is_dead
		):
			return candidate
	return null


func _get_nearest_home_target(from_position: Vector2) -> Node2D:
	var nearest_target: Node2D = null
	var nearest_distance_squared := INF
	for target in _home_objective_targets:
		if target == null or not is_instance_valid(target):
			continue
		var distance_squared := from_position.distance_squared_to(
			target.global_position
		)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_target = target
	return nearest_target


func _get_logical_tile_distance_squared(
	from_global_position: Vector2,
	to_global_position: Vector2
) -> float:
	if (
		_ground_tile_map_layer == null
		or _ground_tile_map_layer.tile_set == null
	):
		return (
			from_global_position.distance_squared_to(to_global_position)
			/ (AUTHORED_LOGICAL_TILE_SIZE * AUTHORED_LOGICAL_TILE_SIZE)
		)
	var tile_size := Vector2(_ground_tile_map_layer.tile_set.tile_size).abs()
	if tile_size.x <= 0.0 or tile_size.y <= 0.0:
		return INF
	var from_local := _ground_tile_map_layer.to_local(from_global_position)
	var to_local := _ground_tile_map_layer.to_local(to_global_position)
	var offset_in_cells := Vector2(
		(to_local.x - from_local.x) / tile_size.x,
		(to_local.y - from_local.y) / tile_size.y
	)
	return offset_in_cells.length_squared()


func request_retarget() -> void:
	enemy_retarget_time_left = 0.0


func clear_removed_plant_objective(plant: PlantDefense) -> void:
	if plant == null:
		return
	for container in [_enemy_container, _boss_container]:
		if container == null:
			continue
		for child in container.get_children():
			var enemy := child as Enemy
			if enemy != null and enemy.objective_target == plant:
				enemy.set_objective_target(null)
