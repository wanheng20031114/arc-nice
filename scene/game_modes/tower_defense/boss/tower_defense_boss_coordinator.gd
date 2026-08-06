extends Node
class_name TowerDefenseBossCoordinator

const LINGLAN_BOSS_INTRO_VFX_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn"
)
const BOSS_HEALTH_HUD_SCENE_PATH := (
	"res://scene/boss/linglan/boss_health_hud.tscn"
)
const LINGLAN_SLIME_CONFIG_PATHS: Array[String] = [
	"res://resources/config/enemies/slime.tres",
	"res://resources/config/enemies/slime_green.tres",
	"res://resources/config/enemies/slime_golden.tres",
	"res://resources/config/enemies/slime_frost.tres",
	"res://resources/config/enemies/slime_fire.tres",
]
const LINGLAN_ENRAGE_SNIPER_CONFIG_PATH := (
	"res://resources/config/enemies/capoo_sniper.tres"
)
const LINGLAN_SPAWN_LEFT_OFFSET := 96.0
const LINGLAN_SKILL4_AUTHORED_TARGET_CENTER := Vector2(6.5, 2.0)
const LINGLAN_SKILL_REFERENCE_ARENA_POSITION := Vector2i(-3, -1)
const LINGLAN_AIRDROP_NEARBY_RADIUS := Vector2(96.0, 80.0)
const AUTHORED_LOGICAL_TILE_SIZE := 16.0

var enabled := false
var runtime: TowerDefenseGame
var boss_container: Node2D
var enemy_container: Node2D
var enemy_spawn_points_root: Node2D
var runtime_port: TowerDefenseLinglanBossRuntimePort
var ground_tile_map_layer: TileMapLayer
var campaign_coordinator: TowerDefenseCampaignCoordinator
var enemy_coordinator: TowerDefenseEnemyCoordinator
var home_defense_coordinator: TowerDefenseHomeDefenseCoordinator
var player_roster_coordinator: TowerDefensePlayerRosterCoordinator
var grid_pathfinder: GridPathfinder
var random_generator: RandomNumberGenerator

var active_boss_config: BossConfig
var linglan_boss_started := false
var linglan_boss: LinglanBoss
var linglan_boss_intro_vfx: LinglanBossIntroVFX
var boss_health_hud: BossHealthHUD
var linglan_skill4_orb_anchor_global_position := Vector2.ZERO
var linglan_skill4_orb_authored_center := LINGLAN_SKILL4_AUTHORED_TARGET_CENTER
var linglan_skill4_orb_anchor_valid := false
var linglan_slime_configs: Array[EnemyConfig] = []
var linglan_enrage_sniper_config: EnemyConfig
var runtime_scene_loads_requested := false
var runtime_resources_by_path: Dictionary[String, Resource] = {}


func setup(
	runtime_instance: TowerDefenseGame,
	configured_enabled: bool,
	configured_boss_container: Node2D,
	configured_enemy_container: Node2D,
	configured_spawn_points_root: Node2D,
	configured_runtime_port: TowerDefenseLinglanBossRuntimePort,
	configured_ground_layer: TileMapLayer,
	configured_campaign: TowerDefenseCampaignCoordinator,
	configured_enemy_coordinator: TowerDefenseEnemyCoordinator,
	configured_home_coordinator: TowerDefenseHomeDefenseCoordinator,
	configured_player_roster: TowerDefensePlayerRosterCoordinator,
	configured_pathfinder: GridPathfinder,
	configured_random: RandomNumberGenerator
) -> void:
	runtime = runtime_instance
	enabled = configured_enabled
	boss_container = configured_boss_container
	enemy_container = configured_enemy_container
	enemy_spawn_points_root = configured_spawn_points_root
	runtime_port = configured_runtime_port
	ground_tile_map_layer = configured_ground_layer
	campaign_coordinator = configured_campaign
	enemy_coordinator = configured_enemy_coordinator
	home_defense_coordinator = configured_home_coordinator
	player_roster_coordinator = configured_player_roster
	grid_pathfinder = configured_pathfinder
	random_generator = configured_random
	if runtime_port != null:
		runtime_port.bind_boss_coordinator(self)


func is_bound() -> bool:
	return (
		runtime != null
		and boss_container != null
		and enemy_container != null
		and enemy_spawn_points_root != null
		and runtime_port != null
		and ground_tile_map_layer != null
		and campaign_coordinator != null
		and enemy_coordinator != null
		and home_defense_coordinator != null
		and player_roster_coordinator != null
		and grid_pathfinder != null
		and random_generator != null
	)


func configure_existing_runtime_nodes() -> void:
	if linglan_boss == null:
		return
	var boss_config := active_boss_config
	if boss_config == null:
		boss_config = get_first_boss_config()
	if boss_config != null:
		linglan_boss.config = get_boss_enemy_config(boss_config)
		linglan_boss.global_position = get_linglan_spawn_global_position(boss_config)
	linglan_boss.set_active(false)
	_connect_boss_signals()
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
		_connect_intro_signal()
	if boss_health_hud != null:
		boss_health_hud.hide_all()


func begin_intro(boss_config: BossConfig = null) -> void:
	if not enabled:
		campaign_coordinator.enter_victory()
		return
	if boss_config == null:
		boss_config = campaign_coordinator.current_flow_step as BossConfig
	if boss_config == null or not ensure_runtime_nodes(boss_config):
		campaign_coordinator.enter_victory()
		return
	active_boss_config = boss_config
	player_roster_coordinator.reset_wave_death_counts()
	linglan_boss_started = true
	campaign_coordinator.current_flow_step = boss_config
	campaign_coordinator.wave_state = CombatFlowState.State.BOSS_INTRO
	runtime.enemy_spawn_timer.stop()
	runtime.state_timer.stop()
	runtime._clear_pending_enemy_spawn_queue()
	runtime._clear_active_enemies()
	campaign_coordinator.current_wave_total = 1
	campaign_coordinator.current_wave_spawned = 1
	campaign_coordinator.current_wave_defeated = 0
	campaign_coordinator.current_wave_escaped = 0
	campaign_coordinator.current_wave_resolved = 0
	runtime._clear_resolved_home_enemy_ids()
	runtime._clear_hud_alive_enemies()
	runtime._set_merchant_active(false)
	runtime._show_tower_defense_boss_progress(0, 1)
	runtime._update_boss_music(boss_config)
	prepare_arena(boss_config)
	var spawn_position := get_linglan_spawn_global_position(boss_config)
	linglan_skill4_orb_anchor_valid = false
	linglan_boss.config = get_boss_enemy_config(boss_config)
	linglan_boss.global_position = spawn_position
	linglan_boss.set_active(false)
	runtime._focus_camera_on_boss_intro(spawn_position)
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	runtime._emit_multiplayer_flow_state(CombatFlowState.State.BOSS_INTRO)
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.play_intro(spawn_position)
	else:
		_on_intro_finished()


func apply_remote_flow_state(
	state: CombatFlowState.State,
	boss_config: BossConfig
) -> void:
	match state:
		CombatFlowState.State.BOSS_INTRO:
			runtime.state_timer.stop()
			campaign_coordinator.wave_state = CombatFlowState.State.BOSS_INTRO
			runtime._set_local_merchants_active(false)
			runtime._show_tower_defense_boss_progress(0, 1)
			if boss_config != null:
				active_boss_config = boss_config
				runtime._update_boss_music(boss_config)
				prepare_arena(boss_config)
				play_remote_intro(boss_config)
		CombatFlowState.State.BOSS_ACTIVE:
			runtime.state_timer.stop()
			campaign_coordinator.wave_state = CombatFlowState.State.BOSS_ACTIVE
			runtime._set_local_merchants_active(false)
			runtime._show_tower_defense_boss_progress(0, 1)
			restore_remote_camera_if_intro_complete()
			if boss_config != null:
				active_boss_config = boss_config
				runtime._update_boss_music(boss_config)


func apply_remote_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> void:
	if (
		not enabled
		or runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or boss_config == null
	):
		return
	restore_remote_camera_if_intro_complete()
	active_boss_config = boss_config
	campaign_coordinator.current_flow_step = boss_config
	campaign_coordinator.wave_state = CombatFlowState.State.BOSS_ACTIVE
	runtime.state_timer.stop()
	runtime._show_tower_defense_boss_progress(0, 1)
	runtime._set_local_merchants_active(false)
	runtime._update_boss_music(boss_config)
	var boss_enemy := runtime.get_enemy_for_net_id(net_id) as LinglanBoss
	if boss_enemy == null or not is_instance_valid(boss_enemy):
		boss_enemy = instantiate_remote_proxy(net_id, boss_config, spawn_position)
	if boss_enemy == null or not is_instance_valid(boss_enemy):
		return
	linglan_boss = boss_enemy
	if boss_container != null and boss_enemy.get_parent() != boss_container:
		boss_enemy.reparent(boss_container, true)
	boss_enemy.global_position = spawn_position
	boss_enemy.visible = true
	if boss_enemy.animated_sprite != null and not boss_enemy.is_dead:
		boss_enemy.animated_sprite.play(&"idle")
	if ensure_health_hud(boss_config) and boss_health_hud != null:
		boss_health_hud.show_for_boss(boss_enemy, get_boss_display_name(boss_config))


func activate_boss() -> void:
	if linglan_boss == null or not is_instance_valid(linglan_boss):
		if not ensure_runtime_nodes(active_boss_config):
			campaign_coordinator.enter_victory()
			return
	if not boss_config_has_required_data(active_boss_config):
		campaign_coordinator.enter_victory()
		return
	campaign_coordinator.wave_state = CombatFlowState.State.BOSS_ACTIVE
	linglan_boss.config = get_boss_enemy_config(active_boss_config)
	linglan_boss.global_position = get_linglan_spawn_global_position(active_boss_config)
	linglan_boss.activate_boss(
		runtime.player,
		grid_pathfinder,
		runtime,
		runtime_port
	)
	if not linglan_boss.is_advancing_to_home():
		runtime._assign_enemy_targets(linglan_boss, linglan_boss.global_position)
	var boss_instance_id := linglan_boss.get_instance_id()
	runtime._register_active_enemy(linglan_boss)
	var exited_callback := _on_boss_tree_exited.bind(boss_instance_id)
	if not linglan_boss.tree_exited.is_connected(exited_callback):
		linglan_boss.tree_exited.connect(exited_callback)
	var boss_net_id := runtime._finalize_authoritative_enemy_spawn(
		linglan_boss,
		get_boss_enemy_config(active_boss_config),
		linglan_boss.global_position,
		false
	)
	runtime._show_tower_defense_boss_progress(0, 1)
	if boss_health_hud != null:
		boss_health_hud.show_for_boss(
			linglan_boss, get_boss_display_name(active_boss_config)
		)
	runtime._emit_multiplayer_flow_state(CombatFlowState.State.BOSS_ACTIVE)
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		runtime._emit_tower_boss_started_authoritatively(
			boss_net_id, active_boss_config, linglan_boss.global_position
		)


func finish_intro() -> void:
	_on_intro_finished()


func handle_boss_tree_exited(enemy_id: int) -> void:
	_on_boss_tree_exited(enemy_id)


func handle_boss_add_defeated(enemy: Enemy) -> void:
	_on_boss_add_defeated(enemy)


func handle_boss_defeated(enemy: Enemy) -> void:
	_on_boss_defeated(enemy)


func complete_boss_after_delay() -> void:
	_complete_boss_after_delay()


func stop_presentation() -> void:
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	if boss_health_hud != null:
		boss_health_hud.hide_all()


func complete_escaped_step_if_ready() -> void:
	if (
		campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or campaign_coordinator.current_wave_resolved < campaign_coordinator.current_wave_total
	):
		return
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	campaign_coordinator.complete_current_step()


func remove_remaining_adds() -> void:
	if enemy_container == null:
		runtime._clear_active_enemies()
		runtime._clear_hud_alive_enemies()
		return
	for child in enemy_container.get_children():
		var enemy := child as Enemy
		if enemy != null and is_instance_valid(enemy):
			if runtime._has_active_enemy(enemy.get_instance_id()):
				enemy.queue_free()
	runtime._clear_active_enemies()
	runtime._clear_hud_alive_enemies()


func request_runtime_scene_loads() -> void:
	if runtime_scene_loads_requested or not enabled:
		return
	runtime_scene_loads_requested = true
	for resource_path in get_runtime_resource_paths():
		ResourceLoader.load_threaded_request(resource_path)


func prewarm_runtime_resources() -> void:
	if not enabled or not runtime._can_continue_runtime_prewarm():
		return
	request_runtime_scene_loads()
	for resource_path in get_runtime_resource_paths():
		if runtime_resources_by_path.has(resource_path):
			continue
		var status := ResourceLoader.load_threaded_get_status(resource_path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await runtime.get_tree().process_frame
			if not runtime._can_continue_runtime_prewarm():
				return
			status = ResourceLoader.load_threaded_get_status(resource_path)
		var resource := (
			ResourceLoader.load_threaded_get(resource_path)
			if status == ResourceLoader.THREAD_LOAD_LOADED
			else ResourceLoader.load(resource_path)
		)
		if resource != null:
			runtime_resources_by_path[resource_path] = resource


func get_runtime_resource_paths() -> Array[String]:
	var paths: Array[String] = []
	for boss_config in get_configured_bosses():
		if not boss_config_has_required_data(boss_config):
			continue
		_append_unique_path(paths, get_boss_enemy_config_path(boss_config))
		_append_unique_path(paths, get_boss_intro_vfx_scene_path(boss_config))
		_append_unique_path(paths, get_boss_hud_scene_path(boss_config))
	for path in LINGLAN_SLIME_CONFIG_PATHS:
		_append_unique_path(paths, path)
	paths.append(LINGLAN_ENRAGE_SNIPER_CONFIG_PATH)
	return paths


func get_configured_bosses() -> Array[BossConfig]:
	return campaign_coordinator.get_configured_bosses() if campaign_coordinator != null else []


func get_first_boss_config() -> BossConfig:
	for boss_config in get_configured_bosses():
		if boss_config_has_required_data(boss_config):
			return boss_config
	return null


func boss_config_has_required_data(boss_config: BossConfig) -> bool:
	return boss_config != null and boss_config.has_required_data()


func get_boss_enemy_config(boss_config: BossConfig) -> EnemyConfig:
	if boss_config == null:
		return null
	return boss_config.get_enemy_config()


func get_boss_enemy_config_path(boss_config: BossConfig) -> String:
	if boss_config == null:
		return ""
	if not boss_config.enemy_config_path.is_empty():
		return boss_config.enemy_config_path
	return boss_config.enemy_config.resource_path if boss_config.enemy_config != null else ""


func get_boss_arena_center(boss_config: BossConfig) -> Vector2:
	return boss_config.arena_center if boss_config != null else Vector2.ZERO


func get_boss_arena_floor_rect(boss_config: BossConfig) -> Rect2i:
	return boss_config.arena_floor_rect if boss_config != null else Rect2i()


func get_boss_floor_source_id(boss_config: BossConfig) -> int:
	return boss_config.floor_source_id if boss_config != null else -1


func get_boss_floor_atlas_coords(boss_config: BossConfig) -> Vector2i:
	return boss_config.floor_atlas_coords if boss_config != null else Vector2i.ZERO


func should_clear_boss_inner_overlay_cells(boss_config: BossConfig) -> bool:
	return boss_config != null and boss_config.clear_inner_overlay_cells


func get_boss_display_name(boss_config: BossConfig) -> String:
	return boss_config.get_display_name() if boss_config != null else "Boss"


func get_boss_intro_vfx_scene_path(boss_config: BossConfig) -> String:
	if boss_config != null and not boss_config.intro_vfx_scene_path.is_empty():
		return boss_config.intro_vfx_scene_path
	return LINGLAN_BOSS_INTRO_VFX_SCENE_PATH


func get_boss_hud_scene_path(boss_config: BossConfig) -> String:
	if boss_config != null and not boss_config.boss_hud_scene_path.is_empty():
		return boss_config.boss_hud_scene_path
	return BOSS_HEALTH_HUD_SCENE_PATH


func get_linglan_spawn_global_position(boss_config: BossConfig) -> Vector2:
	var upper_gate_spawn := _get_enemy_spawn_marker(&"Spawn5")
	var lower_gate_spawn := _get_enemy_spawn_marker(&"Spawn6")
	if upper_gate_spawn != null and lower_gate_spawn != null:
		return (
			(upper_gate_spawn.global_position + lower_gate_spawn.global_position) * 0.5
			+ Vector2.LEFT * LINGLAN_SPAWN_LEFT_OFFSET
		).round()
	return get_boss_arena_center(boss_config)


func ensure_runtime_nodes(boss_config: BossConfig) -> bool:
	if not enabled or boss_container == null:
		return false
	var enemy_config := get_boss_enemy_config(boss_config)
	if enemy_config == null or enemy_config.enemy_scene == null:
		push_error("Boss 配置缺少可实例化的 EnemyConfig 或 enemy_scene。")
		return false
	if linglan_boss == null or not is_instance_valid(linglan_boss):
		var boss_instance := enemy_config.enemy_scene.instantiate()
		linglan_boss = boss_instance as LinglanBoss
		if linglan_boss == null:
			if boss_instance != null:
				boss_instance.free()
			push_error("Boss enemy_scene 必须实例化为 LinglanBoss。")
			return false
		linglan_boss.config = enemy_config
		linglan_boss.name = "LinglanBoss"
		boss_container.add_child(linglan_boss)
	linglan_boss.bind_combat_runtime(runtime)
	linglan_boss.bind_linglan_runtime_port(runtime_port)
	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		var intro_scene := _load_threaded_or_direct(
			get_boss_intro_vfx_scene_path(boss_config)
		) as PackedScene
		if intro_scene == null:
			push_error("无法加载铃兰 Boss 入场 VFX 场景。")
			return false
		var intro_instance := intro_scene.instantiate()
		linglan_boss_intro_vfx = intro_instance as LinglanBossIntroVFX
		if linglan_boss_intro_vfx == null:
			if intro_instance != null:
				intro_instance.free()
			push_error("铃兰 Boss 入场 VFX 场景类型不正确。")
			return false
		linglan_boss_intro_vfx.name = "LinglanBossIntroVFX"
		runtime.add_child(linglan_boss_intro_vfx)
	if not ensure_health_hud(boss_config):
		return false
	cache_slime_configs()
	if get_enrage_sniper_config() == null:
		push_error("无法加载铃兰半血空降狙击手配置。")
		return false
	configure_existing_runtime_nodes()
	return true


func ensure_health_hud(boss_config: BossConfig) -> bool:
	if boss_health_hud != null and is_instance_valid(boss_health_hud):
		return true
	var hud_scene := _load_threaded_or_direct(
		get_boss_hud_scene_path(boss_config)
	) as PackedScene
	if hud_scene == null:
		push_error("无法加载 Boss 大 HUD 场景。")
		return false
	var hud_instance := hud_scene.instantiate()
	boss_health_hud = hud_instance as BossHealthHUD
	if boss_health_hud == null:
		if hud_instance != null:
			hud_instance.free()
		push_error("Boss 大 HUD 场景类型不正确。")
		return false
	boss_health_hud.name = "BossHealthHUD"
	runtime.add_child(boss_health_hud)
	return true


func cache_slime_configs() -> void:
	if linglan_slime_configs.size() == LINGLAN_SLIME_CONFIG_PATHS.size():
		return
	linglan_slime_configs.clear()
	for config_path in LINGLAN_SLIME_CONFIG_PATHS:
		var config := _load_threaded_or_direct(config_path) as EnemyConfig
		if config != null:
			linglan_slime_configs.append(config)


func get_enrage_sniper_config() -> EnemyConfig:
	if linglan_enrage_sniper_config == null:
		linglan_enrage_sniper_config = _load_threaded_or_direct(
			LINGLAN_ENRAGE_SNIPER_CONFIG_PATH
		) as EnemyConfig
	return linglan_enrage_sniper_config


func spawn_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW or enemy_config == null:
		return
	for marker_name in marker_names:
		_try_spawn_boss_add_at_marker(enemy_config, marker_name)


func spawn_random_slime(spawn_position: Vector2) -> void:
	if (
		runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or not spawn_position.is_finite()
	):
		return
	cache_slime_configs()
	if linglan_slime_configs.is_empty():
		return
	var config := linglan_slime_configs[
		random_generator.randi_range(0, linglan_slime_configs.size() - 1)
	]
	_try_spawn_boss_add_at_position(config, spawn_position)


func spawn_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if (
		runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or enemy_config == null
		or enemy_config.enemy_scene == null
	):
		return
	var landing_position := _get_random_arena_position()
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		runtime_port.airdrop_started.emit(
			enemy_config, landing_position, warning_duration, drop_height, drop_duration
		)
	_spawn_airdrop_warning(warning_scene, landing_position, warning_duration)
	_finish_airdrop_sniper_spawn(
		enemy_config,
		landing_position,
		maxf(warning_duration, 0.0),
		maxf(drop_height, 0.0),
		maxf(drop_duration, 0.01)
	)


func get_skill2_target_player(from_position: Vector2) -> Player:
	return runtime._pick_enemy_target(from_position)


func get_skill_target_global_position(_target_cell: Vector2i) -> Vector2:
	return (
		linglan_boss.global_position
		if linglan_boss != null and is_instance_valid(linglan_boss)
		else get_linglan_spawn_global_position(active_boss_config)
	)


func get_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	linglan_skill4_orb_anchor_global_position = get_skill_target_global_position(
		target_cell_a
	)
	linglan_skill4_orb_authored_center = (
		Vector2(target_cell_a) + Vector2(target_cell_b)
	) * 0.5
	linglan_skill4_orb_anchor_valid = true
	return linglan_skill4_orb_anchor_global_position


func get_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary:
	if ground_tile_map_layer == null:
		var center := get_boss_arena_center(active_boss_config)
		return {"start_min": center, "start_max": center, "final_min": center, "final_max": center}
	var start_a := _get_tile_cell_global_position(_map_skill_cell_to_active_arena(
		Vector2i(left_cell_x, top_cell_y)
	))
	var start_b := _get_tile_cell_global_position(_map_skill_cell_to_active_arena(
		Vector2i(right_cell_x, bottom_cell_y)
	))
	var final_a := _get_tile_cell_global_position(_map_skill_cell_to_active_arena(
		Vector2i(left_cell_x + inward_cell_distance, top_cell_y + inward_cell_distance)
	))
	var final_b := _get_tile_cell_global_position(_map_skill_cell_to_active_arena(
		Vector2i(right_cell_x - inward_cell_distance, bottom_cell_y - inward_cell_distance)
	))
	return {
		"start_min": Vector2(minf(start_a.x, start_b.x), minf(start_a.y, start_b.y)),
		"start_max": Vector2(maxf(start_a.x, start_b.x), maxf(start_a.y, start_b.y)),
		"final_min": Vector2(minf(final_a.x, final_b.x), minf(final_a.y, final_b.y)),
		"final_max": Vector2(maxf(final_a.x, final_b.x), maxf(final_a.y, final_b.y)),
	}


func get_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
	var anchor := linglan_skill4_orb_anchor_global_position
	if not linglan_skill4_orb_anchor_valid:
		anchor = get_skill_target_global_position(Vector2i.ZERO)
	var authored_offset := Vector2(x_cell, y_cell) - linglan_skill4_orb_authored_center
	return anchor + _get_tile_cell_global_offset(authored_offset)


func prepare_arena(_boss_config: BossConfig) -> void:
	# Tower defense preserves its authored terrain, gates and player-built line.
	return


func play_remote_intro(boss_config: BossConfig) -> void:
	var spawn_position := get_linglan_spawn_global_position(boss_config)
	runtime._focus_camera_on_boss_intro(spawn_position)
	var scene := _load_threaded_or_direct(
		get_boss_intro_vfx_scene_path(boss_config)
	) as PackedScene
	if scene == null:
		return
	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		var intro_instance := scene.instantiate()
		linglan_boss_intro_vfx = intro_instance as LinglanBossIntroVFX
		if linglan_boss_intro_vfx == null:
			if intro_instance != null:
				intro_instance.free()
			return
		linglan_boss_intro_vfx.name = "LinglanBossIntroVFX"
		runtime.add_child(linglan_boss_intro_vfx)
	_connect_intro_signal()
	linglan_boss_intro_vfx.play_intro(spawn_position)


func restore_remote_camera_if_intro_complete() -> void:
	if (
		linglan_boss_intro_vfx != null
		and linglan_boss_intro_vfx.intro_tween != null
	):
		return
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	runtime._restore_camera_after_boss_intro()


func get_home_objective_target(from_position: Vector2) -> Node2D:
	return home_defense_coordinator.get_nearest_home_target(from_position)


func is_terminal_combat_state() -> bool:
	return campaign_coordinator.wave_state in [
		CombatFlowState.State.VICTORY,
		CombatFlowState.State.DEFEAT,
	]


func pause_background_music() -> void:
	runtime.pause_all_background_music()


func instantiate_remote_proxy(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> LinglanBoss:
	if not enabled or net_id <= 0 or boss_config == null:
		return null
	var enemy_config := get_boss_enemy_config(boss_config)
	if enemy_config == null or enemy_config.enemy_scene == null:
		return null
	var boss_instance := enemy_config.enemy_scene.instantiate()
	var boss_enemy := boss_instance as LinglanBoss
	if boss_enemy == null:
		if boss_instance != null:
			boss_instance.free()
		return null
	boss_container.add_child(boss_enemy)
	boss_enemy.global_position = spawn_position
	boss_enemy.setup(enemy_config, runtime.player, grid_pathfinder, runtime, runtime_port)
	runtime.configure_runtime_enemy_modifiers(boss_enemy)
	boss_enemy.configure_multiplayer_proxy()
	boss_enemy.set_meta("net_id", net_id)
	runtime.register_remote_boss_proxy_indices(boss_enemy, net_id)
	return boss_enemy


func _try_spawn_boss_add_at_marker(
	enemy_config: EnemyConfig,
	marker_name: StringName
) -> bool:
	var marker := _get_enemy_spawn_marker(marker_name)
	return (
		_try_spawn_boss_add_at_position(enemy_config, marker.global_position)
		if marker != null
		else false
	)


func _try_spawn_boss_add_at_position(
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> bool:
	if enemy_config == null or enemy_container == null or runtime.player == null:
		return false
	if enemy_config.enemy_scene == null:
		push_warning("Boss 召唤敌人配置 %s 缺少 enemy_scene。" % enemy_config.resource_path)
		return false
	var enemy_instance := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("Boss 召唤敌人场景实例化失败。")
		return false
	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_position
	enemy_instance.setup(
		enemy_config,
		runtime._pick_enemy_target(spawn_position),
		grid_pathfinder,
		runtime
	)
	runtime._assign_enemy_targets(enemy_instance, spawn_position)
	var enemy_id := enemy_instance.get_instance_id()
	runtime._register_active_enemy(enemy_instance)
	_connect_boss_add_signals(enemy_instance, enemy_id)
	runtime._finalize_authoritative_enemy_spawn(
		enemy_instance, enemy_config, enemy_instance.global_position
	)
	runtime._spawn_enemy_spawn_effect(spawn_position)
	return true


func _spawn_airdrop_warning(
	warning_scene: PackedScene,
	landing_position: Vector2,
	warning_duration: float
) -> void:
	if warning_scene == null:
		return
	var warning_instance := warning_scene.instantiate()
	var warning := warning_instance as LinglanAirdropWarningMarker
	if warning == null:
		if warning_instance != null:
			warning_instance.free()
		return
	runtime.add_child(warning)
	warning.top_level = true
	warning.global_position = landing_position
	warning.start(warning_duration)


func _finish_airdrop_sniper_spawn(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if warning_duration > 0.0:
		await runtime.get_tree().create_timer(warning_duration).timeout
	if campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE:
		return
	if enemy_container == null or runtime.player == null:
		return
	var enemy_instance := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("Linglan 空降狙击手场景实例化失败。")
		return
	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = landing_position + Vector2(0.0, -drop_height)
	enemy_instance.setup(
		enemy_config,
		runtime._pick_enemy_target(landing_position),
		grid_pathfinder,
		runtime
	)
	runtime._assign_enemy_targets(enemy_instance, landing_position)
	enemy_instance.velocity = Vector2.ZERO
	enemy_instance.set_process(false)
	enemy_instance.set_physics_process(false)
	_set_collision_shapes_disabled_recursive(enemy_instance, true)
	var tween := enemy_instance.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(enemy_instance, "global_position", landing_position, drop_duration)
	await tween.finished
	if not is_instance_valid(enemy_instance):
		return
	if campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE:
		enemy_instance.queue_free()
		return
	enemy_instance.global_position = landing_position
	enemy_instance.set_process(true)
	enemy_instance.set_physics_process(true)
	_set_collision_shapes_disabled_recursive(enemy_instance, false)
	var enemy_id := enemy_instance.get_instance_id()
	runtime._register_active_enemy(enemy_instance)
	_connect_boss_add_signals(enemy_instance, enemy_id)
	runtime._finalize_authoritative_enemy_spawn(
		enemy_instance, enemy_config, landing_position
	)
	runtime._spawn_enemy_spawn_effect(landing_position)


func _get_random_arena_position() -> Vector2:
	var front_center := get_skill_target_global_position(Vector2i.ZERO)
	for _attempt in range(8):
		var candidate := front_center + Vector2(
			random_generator.randf_range(
				-LINGLAN_AIRDROP_NEARBY_RADIUS.x, LINGLAN_AIRDROP_NEARBY_RADIUS.x
			),
			random_generator.randf_range(
				-LINGLAN_AIRDROP_NEARBY_RADIUS.y, LINGLAN_AIRDROP_NEARBY_RADIUS.y
			)
		)
		candidate = runtime._clamp_spectator_camera_position(candidate).round()
		if (
			grid_pathfinder == null
			or not grid_pathfinder.is_built
			or grid_pathfinder.is_navigation_segment_walkable(front_center, candidate)
		):
			return candidate
	return front_center.round()


func _on_intro_finished() -> void:
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		if linglan_boss_intro_vfx != null:
			linglan_boss_intro_vfx.stop_intro()
		runtime._restore_camera_after_boss_intro()
		return
	if campaign_coordinator.wave_state != CombatFlowState.State.BOSS_INTRO:
		return
	runtime._restore_camera_after_boss_intro()
	activate_boss()


func _on_boss_defeated(enemy: Enemy) -> void:
	if (
		campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or enemy != linglan_boss
	):
		return
	runtime._remove_active_enemy(enemy.get_instance_id())
	runtime._remove_hud_alive_enemy(enemy.get_instance_id())
	campaign_coordinator.current_wave_defeated = 1
	campaign_coordinator.current_wave_resolved = 1
	runtime._show_tower_defense_boss_progress(1, 1)
	runtime._emit_multiplayer_enemy_defeated(enemy)
	remove_remaining_adds()
	var victory_timer := runtime.get_tree().create_timer(1.3)
	victory_timer.timeout.connect(_complete_boss_after_delay)


func _complete_boss_after_delay() -> void:
	if campaign_coordinator.wave_state != CombatFlowState.State.BOSS_ACTIVE:
		return
	remove_remaining_adds()
	campaign_coordinator.complete_current_step()


func _on_boss_tree_exited(enemy_id: int) -> void:
	runtime._on_boss_enemy_tree_exited(enemy_id)


func _on_boss_add_defeated(enemy: Enemy) -> void:
	runtime._on_boss_add_defeated(enemy)


func _connect_boss_signals() -> void:
	if linglan_boss == null:
		return
	if not linglan_boss.defeated.is_connected(_on_boss_defeated):
		linglan_boss.defeated.connect(_on_boss_defeated)


func _connect_intro_signal() -> void:
	if (
		linglan_boss_intro_vfx != null
		and not linglan_boss_intro_vfx.intro_finished.is_connected(_on_intro_finished)
	):
		linglan_boss_intro_vfx.intro_finished.connect(_on_intro_finished)


func _connect_boss_add_signals(
	enemy_instance: Enemy,
	enemy_id: int = 0
) -> void:
	if enemy_id <= 0:
		enemy_id = enemy_instance.get_instance_id()
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	var exited_callback := _on_boss_tree_exited.bind(enemy_id)
	if not enemy_instance.tree_exited.is_connected(exited_callback):
		enemy_instance.tree_exited.connect(exited_callback)


func _get_enemy_spawn_marker(marker_name: StringName) -> Marker2D:
	return enemy_coordinator.get_spawn_marker(marker_name, enemy_spawn_points_root)


func _set_collision_shapes_disabled_recursive(root_node: Node, disabled: bool) -> void:
	if root_node == null:
		return
	for child in root_node.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shape.set_deferred("disabled", disabled)
		_set_collision_shapes_disabled_recursive(child, disabled)


func _get_tile_cell_global_position(cell: Vector2i) -> Vector2:
	return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(cell))


func _get_tile_cell_global_offset(cell_offset: Vector2) -> Vector2:
	if ground_tile_map_layer == null:
		return cell_offset * AUTHORED_LOGICAL_TILE_SIZE
	var origin := _get_tile_cell_global_position(Vector2i.ZERO)
	var right_step := _get_tile_cell_global_position(Vector2i.RIGHT) - origin
	var down_step := _get_tile_cell_global_position(Vector2i.DOWN) - origin
	return right_step * cell_offset.x + down_step * cell_offset.y


func _map_skill_cell_to_active_arena(authored_cell: Vector2i) -> Vector2i:
	if active_boss_config == null:
		return authored_cell
	var arena_rect := get_boss_arena_floor_rect(active_boss_config)
	if arena_rect.size.x <= 0 or arena_rect.size.y <= 0:
		return authored_cell
	return arena_rect.position + (authored_cell - LINGLAN_SKILL_REFERENCE_ARENA_POSITION)


func _load_threaded_or_direct(path: String) -> Resource:
	if path.is_empty():
		return null
	var retained := runtime_resources_by_path.get(path) as Resource
	if retained != null:
		return retained
	var status := ResourceLoader.load_threaded_get_status(path)
	if status in [
		ResourceLoader.THREAD_LOAD_IN_PROGRESS,
		ResourceLoader.THREAD_LOAD_LOADED,
	]:
		return ResourceLoader.load_threaded_get(path)
	return ResourceLoader.load(path)


static func _append_unique_path(paths: Array[String], path: String) -> void:
	if not path.is_empty() and not paths.has(path):
		paths.append(path)
