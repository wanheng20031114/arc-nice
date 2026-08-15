extends Node
class_name StandardBossCoordinator

signal flow_state_requested(
	state: CombatFlowState.State,
	boss_config: BossConfig,
	is_remote: bool
)
signal step_completed
signal boss_started(boss: LinglanBoss, boss_config: BossConfig)
signal boss_proxy_created(boss: LinglanBoss, net_id: int)
signal boss_enemy_removed(enemy_id: int)
signal boss_defeated(enemy: Enemy)
signal music_requested(boss_config: BossConfig)
signal victory_requested

const LINGLAN_BOSS_INTRO_VFX_SCENE_PATH := (
	"res://scene/boss/linglan/linglan_boss_intro_vfx.tscn"
)
const BOSS_HEALTH_HUD_SCENE_PATH := (
	"res://scene/boss/linglan/boss_health_hud.tscn"
)

var enabled: bool = true
var runtime: WaveCombatRuntimeBase = null
var boss_container: Node2D = null
var runtime_port: LinglanBossRuntimePort = null
var ground_tile_map_layer: TileMapLayer = null
var overlay_tile_map_layer: TileMapLayer = null
var campaign_provider: StandardCampaignWaveCoordinator = null
var resource_resolver: Callable
var enrage_config_provider: Callable

var active_boss_config: BossConfig = null
var linglan_boss_started: bool = false
var linglan_boss: LinglanBoss = null
var linglan_boss_intro_vfx: LinglanBossIntroVFX = null
var boss_health_hud: BossHealthHUD = null
# 只由协调器持有：Boss 终结时一次性关闭，避免异步空投越过遭遇边界。
var encounter_scope := StandardBossEncounterScope.new()
var configured_bosses: Array[BossConfig]:
	get:
		return (
			campaign_provider.get_configured_bosses(
				runtime.flow_graph if runtime != null else null
			)
			if campaign_provider != null
			else []
		)


func bind_dependencies(
	runtime_instance: WaveCombatRuntimeBase,
	container: Node2D,
	linglan_runtime_port: LinglanBossRuntimePort,
	ground_layer: TileMapLayer,
	overlay_layer: TileMapLayer,
	campaign: StandardCampaignWaveCoordinator,
	resolve_resource: Callable,
	provide_enrage_config: Callable
) -> void:
	runtime = runtime_instance
	boss_container = container
	runtime_port = linglan_runtime_port
	ground_tile_map_layer = ground_layer
	overlay_tile_map_layer = overlay_layer
	campaign_provider = campaign
	resource_resolver = resolve_resource
	enrage_config_provider = provide_enrage_config


func configure(
	is_enabled: bool,
	campaign: StandardCampaignWaveCoordinator
) -> void:
	enabled = is_enabled
	campaign_provider = campaign


func is_bound() -> bool:
	return (
		runtime != null
		and boss_container != null
		and runtime_port != null
		and ground_tile_map_layer != null
		and overlay_tile_map_layer != null
		and campaign_provider != null
		and resource_resolver.is_valid()
		and enrage_config_provider.is_valid()
	)


func configure_existing_runtime_nodes() -> void:
	if linglan_boss == null:
		return
	var boss_config := active_boss_config if active_boss_config != null else get_first_boss_config()
	if boss_config != null:
		linglan_boss.config = get_boss_enemy_config(boss_config)
		linglan_boss.global_position = get_boss_arena_center(boss_config)
	linglan_boss.set_active(false)
	_connect_boss_signals()
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
		_connect_intro_signal()
	if boss_health_hud != null:
		boss_health_hud.hide_all()


func start_step(boss_config: BossConfig) -> bool:
	end_encounter()
	if not enabled or boss_config == null:
		victory_requested.emit()
		return true
	if not _ensure_runtime_nodes(boss_config):
		victory_requested.emit()
		return true
	encounter_scope.begin()
	active_boss_config = boss_config
	linglan_boss_started = true
	flow_state_requested.emit(
		CombatFlowState.State.BOSS_INTRO,
		boss_config,
		false
	)
	music_requested.emit(boss_config)
	_prepare_arena(boss_config)
	linglan_boss.config = get_boss_enemy_config(boss_config)
	linglan_boss.global_position = get_boss_arena_center(boss_config)
	linglan_boss.set_active(false)
	if boss_health_hud != null:
		boss_health_hud.hide_all()
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.play_intro(get_boss_arena_center(boss_config))
	else:
		_on_intro_finished()
	return true


func apply_remote_state(
	state: CombatFlowState.State,
	boss_config: BossConfig
) -> bool:
	if boss_config == null:
		return false
	if state not in [
		CombatFlowState.State.BOSS_INTRO,
		CombatFlowState.State.BOSS_ACTIVE,
	]:
		return false
	active_boss_config = boss_config
	flow_state_requested.emit(state, boss_config, true)
	music_requested.emit(boss_config)
	match state:
		CombatFlowState.State.BOSS_INTRO:
			_prepare_arena(boss_config)
			_play_remote_intro(boss_config)
		CombatFlowState.State.BOSS_ACTIVE:
			stop_presentation()
	return true


func apply_remote_started(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> bool:
	if (
		runtime == null
		or runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or boss_config == null
	):
		return false
	stop_presentation()
	active_boss_config = boss_config
	flow_state_requested.emit(
		CombatFlowState.State.BOSS_ACTIVE,
		boss_config,
		true
	)
	music_requested.emit(boss_config)
	var boss_enemy := runtime.get_enemy_for_net_id(net_id) as LinglanBoss
	if boss_enemy == null or not is_instance_valid(boss_enemy):
		boss_enemy = _instantiate_remote_proxy(net_id, boss_config, spawn_position)
	if boss_enemy == null or not is_instance_valid(boss_enemy):
		return true
	linglan_boss = boss_enemy
	if boss_container != null and linglan_boss.get_parent() != boss_container:
		linglan_boss.reparent(boss_container, true)
	linglan_boss.global_position = spawn_position
	linglan_boss.visible = true
	if linglan_boss.animated_sprite != null and not linglan_boss.is_dead:
		linglan_boss.animated_sprite.play(&"idle")
	if _ensure_health_hud(boss_config) and boss_health_hud != null:
		boss_health_hud.show_for_boss(
			linglan_boss,
			get_boss_display_name(boss_config)
		)
	return true


func stop_presentation() -> void:
	if linglan_boss_intro_vfx != null:
		linglan_boss_intro_vfx.stop_intro()
	if boss_health_hud != null:
		boss_health_hud.hide_all()


func end_encounter() -> bool:
	return encounter_scope.close()


func get_encounter_entity_count() -> int:
	return encounter_scope.get_live_entity_count()


func finish_intro() -> void:
	_on_intro_finished()


func activate_boss() -> void:
	_activate_boss()


func prepare_arena(boss_config: BossConfig) -> void:
	_prepare_arena(boss_config)


func play_remote_intro(boss_config: BossConfig) -> void:
	_play_remote_intro(boss_config)


func get_enrage_sniper_config() -> EnemyConfig:
	return (
		enrage_config_provider.call() as EnemyConfig
		if enrage_config_provider.is_valid()
		else null
	)


func spawn_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	if (
		runtime == null
		or runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or runtime.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or enemy_config == null
	):
		return
	var encounter_generation: int = encounter_scope.get_generation()
	if not encounter_scope.is_current(encounter_generation):
		return
	for marker_name in marker_names:
		_try_spawn_boss_add_at_marker(
			enemy_config,
			marker_name,
			encounter_generation
		)


func spawn_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if (
		runtime == null
		or runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or runtime.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or enemy_config == null
		or enemy_config.enemy_scene == null
	):
		return
	var encounter_generation: int = encounter_scope.get_generation()
	if not encounter_scope.is_current(encounter_generation):
		return
	var landing_position := _get_random_arena_position()
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		runtime_port.airdrop_started.emit(
			enemy_config,
			landing_position,
			warning_duration,
			drop_height,
			drop_duration
		)
	_spawn_airdrop_warning(
		warning_scene,
		landing_position,
		warning_duration,
		encounter_generation
	)
	_finish_airdrop_sniper_spawn(
		enemy_config,
		landing_position,
		maxf(warning_duration, 0.0),
		maxf(drop_height, 0.0),
		maxf(drop_duration, 0.01),
		encounter_generation
	)


func get_skill2_target_player(from_position: Vector2) -> Player:
	return runtime._pick_enemy_target(from_position) if runtime != null else null


func _spawn_airdrop_warning(
	warning_scene: PackedScene,
	landing_position: Vector2,
	warning_duration: float,
	encounter_generation: int
) -> void:
	if (
		runtime == null
		or warning_scene == null
		or not encounter_scope.is_current(encounter_generation)
	):
		return
	var warning_instance := warning_scene.instantiate()
	var warning := warning_instance as LinglanAirdropWarningMarker
	if warning == null:
		if warning_instance != null:
			warning_instance.free()
		return
	runtime.add_child(warning)
	if not encounter_scope.track(warning, encounter_generation):
		warning.queue_free()
		return
	warning.top_level = true
	warning.global_position = landing_position
	warning.start(warning_duration)


func _finish_airdrop_sniper_spawn(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float,
	encounter_generation: int
) -> void:
	if warning_duration > 0.0:
		await get_tree().create_timer(warning_duration).timeout
	if (
		not _is_encounter_generation_active(encounter_generation)
		or runtime.enemy_container == null
		or runtime.player == null
	):
		return
	var enemy_instance := enemy_config.enemy_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("Linglan 空降狙击手场景实例化失败。")
		return
	runtime.enemy_container.add_child(enemy_instance)
	# 下落阶段也属于遭遇实体；先登记和接入退出链，再启动任何异步表现。
	if not encounter_scope.track(enemy_instance, encounter_generation):
		enemy_instance.queue_free()
		return
	if not runtime.register_auxiliary_wave_enemy(enemy_instance):
		encounter_scope.untrack(enemy_instance.get_instance_id())
		enemy_instance.queue_free()
		return
	_connect_boss_add_signals(enemy_instance)
	enemy_instance.global_position = landing_position + Vector2(0.0, -drop_height)
	enemy_instance.setup(
		enemy_config,
		runtime._pick_enemy_target(landing_position),
		runtime.grid_pathfinder,
		runtime
	)
	enemy_instance.velocity = Vector2.ZERO
	enemy_instance.set_process(false)
	enemy_instance.set_physics_process(false)
	_set_collision_shapes_disabled_recursive(enemy_instance, true)
	var tween := enemy_instance.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(
		enemy_instance,
		"global_position",
		landing_position,
		drop_duration
	)
	# 使用独立计时器保证 close 回收 tween 目标后协程仍会结束并释放引用。
	await get_tree().create_timer(drop_duration, false).timeout
	if not is_instance_valid(enemy_instance):
		return
	if not _is_encounter_generation_active(encounter_generation):
		if not enemy_instance.is_queued_for_deletion():
			enemy_instance.queue_free()
		return
	enemy_instance.global_position = landing_position
	enemy_instance.set_process(true)
	enemy_instance.set_physics_process(true)
	_set_collision_shapes_disabled_recursive(enemy_instance, false)
	runtime._register_multiplayer_enemy_instance(
		enemy_instance,
		enemy_config,
		landing_position
	)
	runtime._spawn_enemy_spawn_effect(landing_position)


func _set_collision_shapes_disabled_recursive(
	root_node: Node,
	disabled: bool
) -> void:
	if root_node == null:
		return
	for child in root_node.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shape.set_deferred("disabled", disabled)
		_set_collision_shapes_disabled_recursive(child, disabled)


func _get_random_arena_position() -> Vector2:
	if runtime == null:
		return Vector2.ZERO
	if active_boss_config == null or ground_tile_map_layer == null:
		return (
			linglan_boss.global_position
			if linglan_boss != null
			else Vector2.ZERO
		)
	var arena_rect := get_boss_arena_floor_rect(active_boss_config)
	if arena_rect.size.x <= 0 or arena_rect.size.y <= 0:
		return get_boss_arena_center(active_boss_config)
	var min_cell_x := arena_rect.position.x
	var max_cell_x := arena_rect.position.x + arena_rect.size.x - 1
	var min_cell_y := arena_rect.position.y
	var max_cell_y := arena_rect.position.y + arena_rect.size.y - 1
	if arena_rect.size.x > 2:
		min_cell_x += 1
		max_cell_x -= 1
	if arena_rect.size.y > 2:
		min_cell_y += 1
		max_cell_y -= 1
	var target_cell := Vector2i(
		runtime.random_generator.randi_range(min_cell_x, max_cell_x),
		runtime.random_generator.randi_range(min_cell_y, max_cell_y)
	)
	return _get_tile_cell_global_position(target_cell)


func _try_spawn_boss_add_at_marker(
	enemy_config: EnemyConfig,
	marker_name: StringName,
	encounter_generation: int
) -> bool:
	if (
		not _is_encounter_generation_active(encounter_generation)
		or enemy_config == null
		or runtime.enemy_container == null
		or runtime.player == null
	):
		return false
	var spawn_marker := _get_enemy_spawn_marker(marker_name)
	if spawn_marker == null:
		return false
	var spawn_scene := enemy_config.enemy_scene
	if spawn_scene == null:
		push_warning(
			"Boss 召唤敌人配置 %s 缺少 enemy_scene。"
			% enemy_config.resource_path
		)
		return false
	var enemy_instance := spawn_scene.instantiate() as Enemy
	if enemy_instance == null:
		push_warning("Boss 召唤敌人场景实例化失败。")
		return false
	runtime.enemy_container.add_child(enemy_instance)
	if not encounter_scope.track(enemy_instance, encounter_generation):
		enemy_instance.queue_free()
		return false
	if not runtime.register_auxiliary_wave_enemy(enemy_instance):
		encounter_scope.untrack(enemy_instance.get_instance_id())
		enemy_instance.queue_free()
		return false
	_connect_boss_add_signals(enemy_instance)
	enemy_instance.global_position = spawn_marker.global_position
	enemy_instance.setup(
		enemy_config,
		runtime._pick_enemy_target(spawn_marker.global_position),
		runtime.grid_pathfinder,
		runtime
	)
	runtime._register_multiplayer_enemy_instance(
		enemy_instance,
		enemy_config,
		enemy_instance.global_position
	)
	runtime._spawn_enemy_spawn_effect(spawn_marker.global_position)
	return true


func _connect_boss_add_signals(enemy_instance: Enemy) -> void:
	var enemy_id := enemy_instance.get_instance_id()
	if not enemy_instance.defeated.is_connected(_on_boss_add_defeated):
		enemy_instance.defeated.connect(_on_boss_add_defeated)
	var exited_callback := _on_boss_add_tree_exited.bind(enemy_id)
	if not enemy_instance.tree_exited.is_connected(exited_callback):
		enemy_instance.tree_exited.connect(exited_callback)


func _get_enemy_spawn_marker(marker_name: StringName) -> Marker2D:
	if runtime == null or marker_name == &"":
		return null
	for marker in runtime.enemy_spawn_points:
		if marker != null and marker.name == String(marker_name):
			return marker
	if runtime.enemy_spawn_points_root == null:
		return null
	var node := runtime.enemy_spawn_points_root.get_node_or_null(
		NodePath(String(marker_name))
	)
	return node as Marker2D


func _on_boss_add_defeated(enemy: Enemy) -> void:
	if (
		runtime == null
		or enemy == null
		or not runtime.try_resolve_active_wave_enemy_defeat(
			enemy.get_instance_id()
		)
	):
		return
	runtime._emit_multiplayer_enemy_defeated(enemy)


func _is_encounter_generation_active(encounter_generation: int) -> bool:
	return (
		encounter_scope.is_current(encounter_generation)
		and runtime != null
		and runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and runtime.wave_state == CombatFlowState.State.BOSS_ACTIVE
	)


func get_first_boss_config() -> BossConfig:
	for boss_config in configured_bosses:
		if boss_config_has_required_data(boss_config):
			return boss_config
	return null


func get_runtime_resource_paths() -> Array[String]:
	var paths: Array[String] = []
	for boss_config in configured_bosses:
		if not boss_config_has_required_data(boss_config):
			continue
		_append_unique_path(paths, get_boss_enemy_config_path(boss_config))
		_append_unique_path(paths, get_boss_intro_vfx_scene_path(boss_config))
		_append_unique_path(paths, get_boss_hud_scene_path(boss_config))
	return paths


func boss_config_has_required_data(boss_config: BossConfig) -> bool:
	return boss_config != null and boss_config.has_required_data()


func get_boss_enemy_config(boss_config: BossConfig) -> EnemyConfig:
	if boss_config == null:
		return null
	if boss_config.enemy_config != null:
		return boss_config.enemy_config
	var enemy_config_path := get_boss_enemy_config_path(boss_config)
	return _resolve_resource(enemy_config_path) as EnemyConfig


func get_boss_enemy_config_path(boss_config: BossConfig) -> String:
	if boss_config == null:
		return ""
	if not boss_config.enemy_config_path.is_empty():
		return boss_config.enemy_config_path
	return (
		boss_config.enemy_config.resource_path
		if boss_config.enemy_config != null
		else ""
	)


func get_boss_arena_center(boss_config: BossConfig) -> Vector2:
	return boss_config.arena_center if boss_config != null else Vector2.ZERO


func get_boss_arena_floor_rect(boss_config: BossConfig) -> Rect2i:
	return boss_config.arena_floor_rect if boss_config != null else Rect2i()


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


func get_skill_target_global_position(target_cell: Vector2i) -> Vector2:
	if ground_tile_map_layer != null:
		return _get_tile_cell_global_position(target_cell)
	return get_boss_arena_center(active_boss_config)


func get_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	if ground_tile_map_layer != null:
		return (
			_get_tile_cell_global_position(target_cell_a)
			+ _get_tile_cell_global_position(target_cell_b)
		) * 0.5
	return get_boss_arena_center(active_boss_config)


func get_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary:
	if ground_tile_map_layer == null:
		var fallback_center := get_boss_arena_center(active_boss_config)
		return {
			"start_min": fallback_center,
			"start_max": fallback_center,
			"final_min": fallback_center,
			"final_max": fallback_center,
		}
	var start_a := _get_tile_cell_global_position(Vector2i(left_cell_x, top_cell_y))
	var start_b := _get_tile_cell_global_position(Vector2i(right_cell_x, bottom_cell_y))
	var final_a := _get_tile_cell_global_position(Vector2i(
		left_cell_x + inward_cell_distance,
		top_cell_y + inward_cell_distance
	))
	var final_b := _get_tile_cell_global_position(Vector2i(
		right_cell_x - inward_cell_distance,
		bottom_cell_y - inward_cell_distance
	))
	return {
		"start_min": Vector2(minf(start_a.x, start_b.x), minf(start_a.y, start_b.y)),
		"start_max": Vector2(maxf(start_a.x, start_b.x), maxf(start_a.y, start_b.y)),
		"final_min": Vector2(minf(final_a.x, final_b.x), minf(final_a.y, final_b.y)),
		"final_max": Vector2(maxf(final_a.x, final_b.x), maxf(final_a.y, final_b.y)),
	}


func get_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
	if ground_tile_map_layer != null:
		return _get_tile_cell_global_position(Vector2i(x_cell, y_cell))
	return get_boss_arena_center(active_boss_config)


func _ensure_runtime_nodes(boss_config: BossConfig) -> bool:
	if runtime == null or boss_container == null:
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
	_connect_boss_signals()
	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		var intro_scene := _resolve_resource(
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
	_connect_intro_signal()
	if not _ensure_health_hud(boss_config):
		return false
	if (
		enrage_config_provider.is_valid()
		and (enrage_config_provider.call() as EnemyConfig) == null
	):
		push_error("无法加载铃兰半血空降狙击手配置。")
		return false
	configure_existing_runtime_nodes()
	return true


func _ensure_health_hud(boss_config: BossConfig) -> bool:
	if boss_health_hud != null and is_instance_valid(boss_health_hud):
		return true
	var hud_scene := _resolve_resource(get_boss_hud_scene_path(boss_config)) as PackedScene
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


func _instantiate_remote_proxy(
	net_id: int,
	boss_config: BossConfig,
	spawn_position: Vector2
) -> LinglanBoss:
	if net_id <= 0 or runtime == null or boss_container == null:
		return null
	var enemy_config := get_boss_enemy_config(boss_config)
	if enemy_config == null or enemy_config.enemy_scene == null:
		return null
	var boss_enemy := enemy_config.enemy_scene.instantiate() as LinglanBoss
	if boss_enemy == null:
		return null
	boss_container.add_child(boss_enemy)
	boss_enemy.global_position = spawn_position
	boss_enemy.setup(
		enemy_config,
		runtime.player,
		runtime.grid_pathfinder,
		runtime,
		runtime_port
	)
	boss_enemy.configure_multiplayer_proxy()
	boss_proxy_created.emit(boss_enemy, net_id)
	return boss_enemy


func _on_intro_finished() -> void:
	if runtime == null or runtime.wave_state != CombatFlowState.State.BOSS_INTRO:
		return
	_activate_boss()


func _activate_boss() -> void:
	if active_boss_config == null:
		end_encounter()
		victory_requested.emit()
		return
	if not _ensure_runtime_nodes(active_boss_config):
		end_encounter()
		victory_requested.emit()
		return
	flow_state_requested.emit(
		CombatFlowState.State.BOSS_ACTIVE,
		active_boss_config,
		false
	)
	linglan_boss.config = get_boss_enemy_config(active_boss_config)
	linglan_boss.global_position = get_boss_arena_center(active_boss_config)
	linglan_boss.activate_boss(
		runtime.player,
		runtime.grid_pathfinder,
		runtime,
		runtime_port
	)
	if boss_health_hud != null:
		boss_health_hud.show_for_boss(
			linglan_boss,
			get_boss_display_name(active_boss_config)
		)
	boss_started.emit(linglan_boss, active_boss_config)


func _on_boss_add_tree_exited(enemy_id: int) -> void:
	encounter_scope.untrack(enemy_id)
	boss_enemy_removed.emit(enemy_id)


func _on_active_boss_tree_exited(enemy_id: int) -> void:
	if (
		linglan_boss != null
		and is_instance_valid(linglan_boss)
		and linglan_boss.get_instance_id() == enemy_id
	):
		end_encounter()
	boss_enemy_removed.emit(enemy_id)


func _on_boss_defeated(enemy: Enemy) -> void:
	if (
		runtime == null
		or runtime.wave_state != CombatFlowState.State.BOSS_ACTIVE
		or enemy != linglan_boss
		or not encounter_scope.is_open()
	):
		return
	var defeated_generation: int = encounter_scope.get_generation()
	# 先封闭遭遇，再广播 Boss 终结；任何等待中的空投从此只能安全退出。
	end_encounter()
	boss_defeated.emit(enemy)
	var victory_timer := get_tree().create_timer(1.3)
	await victory_timer.timeout
	if (
		runtime != null
		and runtime.wave_state == CombatFlowState.State.BOSS_ACTIVE
		and encounter_scope.get_generation() == defeated_generation
		and not encounter_scope.is_open()
	):
		step_completed.emit()


func _prepare_arena(boss_config: BossConfig) -> void:
	if boss_config == null or ground_tile_map_layer == null:
		return
	var arena_rect := get_boss_arena_floor_rect(boss_config)
	if arena_rect.size.x <= 0 or arena_rect.size.y <= 0:
		return
	var floor_source_id := boss_config.floor_source_id
	var floor_atlas_coords := boss_config.floor_atlas_coords
	for cell_x in range(arena_rect.position.x, arena_rect.position.x + arena_rect.size.x):
		for cell_y in range(arena_rect.position.y, arena_rect.position.y + arena_rect.size.y):
			ground_tile_map_layer.set_cell(
				Vector2i(cell_x, cell_y),
				floor_source_id,
				floor_atlas_coords,
				0
			)
	if boss_config.clear_inner_overlay_cells and overlay_tile_map_layer != null:
		for cell in overlay_tile_map_layer.get_used_cells():
			if arena_rect.has_point(cell):
				overlay_tile_map_layer.erase_cell(cell)
	if runtime != null and runtime.grid_pathfinder != null:
		runtime.grid_pathfinder.rebuild()


func _play_remote_intro(boss_config: BossConfig) -> void:
	if linglan_boss_intro_vfx == null or not is_instance_valid(linglan_boss_intro_vfx):
		var intro_scene := _resolve_resource(
			get_boss_intro_vfx_scene_path(boss_config)
		) as PackedScene
		if intro_scene == null:
			return
		var intro_instance := intro_scene.instantiate()
		linglan_boss_intro_vfx = intro_instance as LinglanBossIntroVFX
		if linglan_boss_intro_vfx == null:
			if intro_instance != null:
				intro_instance.free()
			return
		linglan_boss_intro_vfx.name = "LinglanBossIntroVFX"
		runtime.add_child(linglan_boss_intro_vfx)
	if linglan_boss_intro_vfx.intro_finished.is_connected(_on_intro_finished):
		linglan_boss_intro_vfx.intro_finished.disconnect(_on_intro_finished)
	linglan_boss_intro_vfx.play_intro(get_boss_arena_center(boss_config))


func _connect_boss_signals() -> void:
	if linglan_boss == null:
		return
	if not linglan_boss.defeated.is_connected(_on_boss_defeated):
		linglan_boss.defeated.connect(_on_boss_defeated)
	var enemy_id := linglan_boss.get_instance_id()
	var exited_callback := _on_active_boss_tree_exited.bind(enemy_id)
	if not linglan_boss.tree_exited.is_connected(exited_callback):
		linglan_boss.tree_exited.connect(exited_callback)


func _connect_intro_signal() -> void:
	if (
		linglan_boss_intro_vfx != null
		and not linglan_boss_intro_vfx.intro_finished.is_connected(_on_intro_finished)
	):
		linglan_boss_intro_vfx.intro_finished.connect(_on_intro_finished)


func _exit_tree() -> void:
	end_encounter()


func _get_tile_cell_global_position(cell: Vector2i) -> Vector2:
	if ground_tile_map_layer == null:
		return Vector2.ZERO
	return ground_tile_map_layer.to_global(ground_tile_map_layer.map_to_local(cell))


func _resolve_resource(path: String) -> Resource:
	if path.is_empty():
		return null
	if resource_resolver.is_valid():
		return resource_resolver.call(path) as Resource
	push_error("StandardBossCoordinator: 资源解析器尚未绑定。")
	return null


func _append_unique_path(paths: Array[String], path: String) -> void:
	if not path.is_empty() and not paths.has(path):
		paths.append(path)
