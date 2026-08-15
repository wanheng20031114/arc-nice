@abstract
extends CombatRuntimeBase
class_name WaveCombatRuntimeBase

# 中性波次运行时只维护确定性的流程图、刷怪队列与共享战斗实体。
# 模式规则、Boss、商人、HUD、音乐和终局表现由具体模式根脚本拥有。

const PLAYER_BULLET_POOL_SCENE := preload("res://scene/combat/projectiles/bullet.tscn")
const CAPOO_AK47_BULLET_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_ak47_bullet.tscn"
)
const COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const COMBAT_ROBOT_SUICIDE_DRONE_ELITE_POOL_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone_elite.tscn"
)
const CAPOO_SMG_BULLET_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_smg_bullet.tscn"
)
const CAPOO_RPG_ROCKET_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_rpg_rocket.tscn"
)
const CAPOO_MAGE_FIREBALL_POOL_SCENE := preload(
	"res://scene/enemy/capoo/capoo_mage_fireball.tscn"
)
const FIRE_SORCERER_FIREBALL_VOLLEY_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const FROST_SORCERER_ICE_SPIKE_POOL_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const YUANSHI_FIRE_PROJECTILE_POOL_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.tscn"
)
const COLLECTIBLE_ARROW_POOL_SCENE := preload(
	"res://scene/combat/collectibles/collectible_arrow_projectile.tscn"
)
const COLLECTIBLE_SAKURA_ROCKET_POOL_SCENE := preload(
	"res://scene/combat/collectibles/collectible_sakura_rocket.tscn"
)
const GUARDIAN_POINT_LIGHT_TEXTURE := preload(
	"res://resources/texture/enemy/yuanshi_insect/guardian_point_light.png"
)
const COUNTDOWN_FINAL_SECONDS := 3
const MIN_WAVE_SPAWN_INTERVAL_SECONDS := 0.1
const MAX_WAVE_SPAWN_COUNT_PER_TICK := 10

@export_group("波次战役")
@export var mode_definition: GameModeDefinition = null
@export var singleplayer_campaign: WaveCampaignConfig = null
@export var multiplayer_campaign: WaveCampaignConfig = null

@export_group("波次流程")
@export_range(0.0, 60.0, 1.0, "or_greater") var pre_wave_duration: float = 5.0
@export var auto_start_waves: bool = true

@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoints
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var state_timer: Timer = $StateTimer
@onready var guardian_aura_system: GuardianAuraSystem = $GuardianAuraSystem
@onready var damage_number_pool: DamageNumberPool = $DamageNumberPool
@onready var session_object_pool: SessionObjectPool = $SessionObjectPool
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore

var random_generator := RandomNumberGenerator.new()
var wave_state: CombatFlowState.State = CombatFlowState.State.PRE_WAVE
var active_campaign: WaveCampaignConfig = null
var flow_graph: FlowGraphConfig = null
var waves: Array[WaveConfig] = []
var enemy_spawn_points: Array[Marker2D] = []
var enemy_spawn_points_by_name: Dictionary[StringName, Marker2D] = {}
var active_wave_spawn_points: Array[Marker2D] = []
var _balanced_spawn_point_bag: Array[Marker2D] = []
var spawn_point_configuration_valid := true
var pending_enemy_configs: Array[EnemyConfig] = []
var pending_enemy_xirang_kill_rewards: Array[int] = []
var pending_enemy_config_index: int = 0
var wave_enemy_terminal_ledger := WaveEnemyTerminalLedger.new()
var active_wave_enemy_ids: Dictionary:
	get:
		return wave_enemy_terminal_ledger.get_attached_enemy_ids()

var current_wave_index: int = 0
var current_wave_total: int:
	get:
		return wave_enemy_terminal_ledger.get_total()
var current_wave_spawned: int:
	get:
		return wave_enemy_terminal_ledger.get_spawned()
var current_wave_defeated: int:
	get:
		return wave_enemy_terminal_ledger.get_defeated()
var current_wave_escaped: int:
	get:
		return wave_enemy_terminal_ledger.get_escaped()
var current_wave_removed: int:
	get:
		return wave_enemy_terminal_ledger.get_removed()
var current_wave_resolved: int:
	get:
		return wave_enemy_terminal_ledger.get_resolved()
var countdown_seconds: int = 0
var current_flow_step: FlowStepConfig = null
var next_flow_step_after_rest: FlowStepConfig = null
var enemy_retarget_time_left: float = 0.0
var next_multiplayer_enemy_net_id: int = 1
var navigation_prewarm_requested: bool = false
var navigation_prewarmed: bool = false


## 账本拥有实体与聚合生命周期；运行时只负责把 Godot 信号翻译成领域事务。
func reset_wave_progress(
	total: int,
	spawned: int = 0,
	defeated: int = 0,
	escaped: int = 0,
	removed: int = 0
) -> void:
	if not wave_enemy_terminal_ledger.reset(
		total, spawned, defeated, escaped, removed
	):
		push_error("WaveCombatRuntimeBase: 非法波次进度重置被拒绝。")


func apply_wave_progress_snapshot(
	total: int,
	spawned: int,
	defeated: int,
	escaped: int = 0,
	removed: int = 0
) -> bool:
	return wave_enemy_terminal_ledger.apply_snapshot(
		total, spawned, defeated, escaped, removed
	)


func is_wave_progress_complete() -> bool:
	return wave_enemy_terminal_ledger.is_complete()


func get_wave_progress_snapshot() -> Dictionary:
	return {
		"wave_number": current_wave_index + 1,
		"total": current_wave_total,
		"spawned": current_wave_spawned,
		"defeated": current_wave_defeated,
		"escaped": current_wave_escaped,
		"removed": current_wave_removed,
		"resolved": current_wave_resolved,
	}


func register_active_wave_enemy(
	enemy: Enemy,
	role: WaveEnemyTerminalLedger.EnemyRole = (
		WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
	)
) -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	return wave_enemy_terminal_ledger.register_enemy(enemy.get_instance_id(), role)


func register_auxiliary_wave_enemy(enemy: Enemy) -> bool:
	return register_active_wave_enemy(
		enemy, WaveEnemyTerminalLedger.EnemyRole.AUXILIARY
	)


func clear_active_wave_enemies() -> void:
	wave_enemy_terminal_ledger.clear_entities()


func try_resolve_active_wave_enemy(
	enemy_id: int,
	reason: CombatTypes.EnemyTerminalReason
) -> bool:
	return wave_enemy_terminal_ledger.resolve_enemy(enemy_id, reason)


func try_resolve_active_wave_enemy_defeat(enemy_id: int) -> bool:
	return try_resolve_active_wave_enemy(
		enemy_id, CombatTypes.EnemyTerminalReason.DEFEATED
	)


## 只供无真实实体的边界测试构造完整领域状态。
func replace_wave_terminal_state_for_fixture(
	total: int,
	spawned: int,
	defeated: int,
	escaped: int = 0,
	removed: int = 0
) -> bool:
	return wave_enemy_terminal_ledger.reset(
		total, spawned, defeated, escaped, removed
	)


# 以下钩子只描述模式边界，不提供任何具体模式策略。
func _get_default_mode_definition() -> GameModeDefinition:
	return null


func _apply_wave_start_lighting(_wave_number: int) -> void:
	# 波次默认进入黑夜；固定昼夜策略仍由 CombatRuntimeBase 统一裁决。
	transition_world_to_night()


func _validate_mode_scene_content() -> bool:
	return true


func _initialize_mode_runtime_before_validation() -> void:
	pass


func _register_mode_object_pools() -> void:
	pass


@abstract func _connect_mode_dynamic_pickup_containers() -> void


@abstract func _register_static_multiplayer_pickups() -> void


func _initialize_mode_player_ui() -> void:
	pass


func _initialize_mode_runtime_content() -> void:
	pass


func _apply_initial_player_resources() -> void:
	pass


@abstract func _configure_singleplayer_player() -> void


@abstract func _configure_multiplayer_players() -> void


@abstract func _connect_mode_singleplayer_player_death_signal() -> void


@abstract func _update_multiplayer_remote_player_passive_state(delta: float) -> void


func _set_intermission_services_active(_active: bool) -> void:
	pass


func _present_flow_countdown(
	_state: CombatFlowState.State,
	_seconds: int
) -> void:
	pass


func _present_wave_started(
	_wave_config: WaveConfig,
	_is_remote: bool
) -> void:
	pass


func _present_wave_progress(
	_defeated_count: int,
	_total_count: int
) -> void:
	pass


func _present_remote_enemy_count(_alive_count: int) -> void:
	pass


func _present_terminal_state(_victory: bool) -> void:
	pass


func _hide_mode_wave_presentation() -> void:
	pass


func _present_countdown_tick() -> void:
	pass


func _present_intermission_started(_cleared_step: FlowStepConfig) -> void:
	pass


func _begin_mode_flow_step(_flow_step: FlowStepConfig) -> bool:
	return false


func _apply_remote_mode_flow_state(
	_state: CombatFlowState.State,
	_flow_step: FlowStepConfig
) -> bool:
	return false


func _prewarm_mode_runtime_data() -> void:
	pass


func _ready() -> void:
	random_generator.randomize()
	initialize_world_lighting()
	_initialize_mode_runtime_before_validation()
	if not _validate_wave_runtime_scene_content():
		set_process(false)
		set_physics_process(false)
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		var load_coordinator := get_node_or_null("/root/GameLoadCoordinator")
		if load_coordinator != null and bool(load_coordinator.call("is_loading")):
			defer_runtime_activation()
	if not _configure_active_campaign():
		set_process(false)
		set_physics_process(false)
		return
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		_configure_singleplayer_player()
	_collect_enemy_spawn_points()
	_configure_timers()
	_prewarm_enemy_visual_resources()
	CombatRuntimeBase.register_common_visual_effect_pools(session_object_pool)
	session_object_pool.register_scene(PLAYER_BULLET_POOL_SCENE, 64, 768)
	session_object_pool.register_scene(CAPOO_AK47_BULLET_POOL_SCENE, 32, 384)
	CombatRuntimeBase.register_combat_robot_gunner_bullet_pool(session_object_pool)
	CombatRuntimeBase.register_combat_robot_gunner_elite_bullet_pool(session_object_pool)
	session_object_pool.register_scene(COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE, 0, 384)
	session_object_pool.register_scene(COMBAT_ROBOT_SUICIDE_DRONE_ELITE_POOL_SCENE, 0, 384)
	session_object_pool.register_scene(CAPOO_SMG_BULLET_POOL_SCENE, 48, 512)
	session_object_pool.register_scene(CAPOO_RPG_ROCKET_POOL_SCENE, 12, 96)
	session_object_pool.register_scene(CAPOO_MAGE_FIREBALL_POOL_SCENE, 12, 96)
	session_object_pool.register_scene(
		FIRE_SORCERER_FIREBALL_VOLLEY_POOL_SCENE,
		48,
		704
	)
	session_object_pool.register_scene(
		FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_POOL_SCENE,
		48,
		704
	)
	session_object_pool.register_scene(FROST_SORCERER_ICE_SPIKE_POOL_SCENE, 48, 704)
	CombatRuntimeBase.register_capoo_mage_fireball_impact_pool(
		session_object_pool,
		12,
		24
	)
	session_object_pool.register_scene(YUANSHI_FIRE_PROJECTILE_POOL_SCENE, 24, 192)
	session_object_pool.register_scene(COLLECTIBLE_ARROW_POOL_SCENE, 24, 192)
	session_object_pool.register_scene(COLLECTIBLE_SAKURA_ROCKET_POOL_SCENE, 8, 64)
	_register_mode_object_pools()
	enable_singleplayer_combat_target_index()
	guardian_aura_system.set_authoritative_processing_enabled(
		runtime_mode != RuntimeMode.CLIENT_VIEW
	)
	_connect_mode_dynamic_pickup_containers()
	if runtime_mode != RuntimeMode.SINGLEPLAYER:
		run_state.ensure_run_started()
		run_state.set_active_multiplayer_peer(multiplayer_local_peer_id)
		_configure_multiplayer_players()
		_register_static_multiplayer_pickups()
	if player == null:
		push_error("%s: 无法创建当前角色，停止初始化。" % get_class())
		set_process(false)
		set_physics_process(false)
		return
	_apply_initial_player_resources()
	_initialize_mode_player_ui()
	if runtime_mode == RuntimeMode.SINGLEPLAYER:
		_connect_mode_singleplayer_player_death_signal()
	_initialize_mode_runtime_content()

	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		auto_start_waves = false
		if not runtime_activation_deferred:
			_start_client_flow_countdown(
				CombatFlowState.State.PRE_WAVE,
				_get_flow_step_id(_get_start_flow_step()),
				maxi(ceili(pre_wave_duration), 0)
			)
	elif auto_start_waves and not runtime_activation_deferred and _is_flow_system_ready():
		_enter_pre_flow_step(_get_start_flow_step())
	else:
		_hide_mode_wave_presentation()
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		if runtime_activation_deferred:
			call_deferred("prepare_shared_runtime_data_and_complete")
		else:
			mark_runtime_preparation_complete()
	elif auto_start_waves or runtime_activation_deferred:
		_schedule_enemy_navigation_prewarm()


func _validate_wave_runtime_scene_content() -> bool:
	if enemy_spawn_points_root == null or enemy_spawn_timer == null or state_timer == null:
		push_error("%s: 波次场景缺少静态出生点或计时器节点。" % get_class())
		return false
	return _validate_mode_scene_content()


func _configure_active_campaign() -> bool:
	var definition := mode_definition
	if definition == null:
		definition = _get_default_mode_definition()
	if definition != null and singleplayer_campaign == null:
		if not definition.singleplayer_campaign_path.is_empty():
			singleplayer_campaign = load(
				definition.singleplayer_campaign_path
			) as WaveCampaignConfig
	if definition != null and multiplayer_campaign == null:
		if not definition.multiplayer_campaign_path.is_empty():
			multiplayer_campaign = load(
				definition.multiplayer_campaign_path
			) as WaveCampaignConfig
	active_campaign = (
		singleplayer_campaign
		if runtime_mode == RuntimeMode.SINGLEPLAYER
		else multiplayer_campaign
	)
	flow_graph = null
	waves.clear()
	if active_campaign == null:
		push_error("%s: 当前运行模式没有配置 WaveCampaignConfig。" % get_class())
		return false
	var campaign_errors := active_campaign.validate_campaign()
	if not campaign_errors.is_empty():
		for error in campaign_errors:
			push_error(error)
		return false
	flow_graph = active_campaign.flow_graph
	waves.assign(active_campaign.get_waves())
	return true


func prewarm_shared_runtime_data() -> void:
	await super.prewarm_shared_runtime_data()
	await _prewarm_mode_runtime_data()


func _on_runtime_activated() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if current_flow_step == null and auto_start_waves and _is_flow_system_ready():
		_enter_pre_flow_step(_get_start_flow_step())


func _physics_process(delta: float) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		_update_multiplayer_remote_player_passive_state(delta)
		_update_multiplayer_enemy_targets(delta)

func apply_remote_flow_state(
	step_id: StringName,
	state: int,
	seconds: int
) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	var typed_state := state as CombatFlowState.State
	var flow_step := _get_flow_step_by_id(step_id)
	if (
		flow_step == null
		and typed_state not in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	):
		push_error(
			"%s: 收到当前 Campaign 不存在的流程 step_id：%s"
			% [get_class(), String(step_id)]
		)
		return
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	match typed_state:
		CombatFlowState.State.PRE_WAVE, CombatFlowState.State.INTERMISSION:
			transition_world_to_day()
			_start_client_flow_countdown(typed_state, step_id, seconds)
		CombatFlowState.State.WAVE_ACTIVE:
			state_timer.stop()
			wave_state = CombatFlowState.State.WAVE_ACTIVE
			_apply_wave_start_lighting(maxi(current_wave_index + 1, 1))
			_set_intermission_services_active(false)
			_present_wave_started(flow_step as WaveConfig, true)
		CombatFlowState.State.VICTORY:
			apply_remote_victory()
		CombatFlowState.State.DEFEAT:
			apply_remote_defeat()
		_:
			if not _apply_remote_mode_flow_state(typed_state, flow_step):
				push_error(
					"%s: 未处理流程状态 %d。" % [get_class(), int(typed_state)]
				)


func get_flow_state_snapshot() -> Dictionary:
	return {
		"step_id": _get_flow_step_id(current_flow_step),
		"state": int(wave_state),
		"countdown_seconds": countdown_seconds,
	}

func apply_remote_victory() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	_enter_victory(false)

func apply_remote_enemy_count(alive_count: int) -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	if wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	_present_remote_enemy_count(maxi(alive_count, 0))


func apply_remote_defeat() -> void:
	if runtime_mode != RuntimeMode.CLIENT_VIEW:
		return
	_enter_defeat()


func show_damage_number(
	amount: int,
	spawn_position: Vector2,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	return show_combat_number(
		amount,
		spawn_position,
		DamageNumberPool.CombatNumberKind.DAMAGE,
		impact_direction,
		damage_type,
		display_priority
	)

func show_combat_number(
	amount: int,
	spawn_position: Vector2,
	number_kind: DamageNumberPool.CombatNumberKind,
	motion_direction: Vector2 = Vector2.ZERO,
	damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL,
	display_priority: DamageNumberPool.DisplayPriority = DamageNumberPool.DisplayPriority.NORMAL
) -> bool:
	if damage_number_pool == null:
		return false
	return damage_number_pool.show_combat_number(
		amount,
		spawn_position,
		number_kind,
		motion_direction,
		damage_type,
		display_priority
	)

func _collect_enemy_spawn_points() -> void:
	enemy_spawn_points.clear()
	enemy_spawn_points_by_name.clear()
	active_wave_spawn_points.clear()
	_balanced_spawn_point_bag.clear()
	spawn_point_configuration_valid = true
	for child in enemy_spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point != null:
			var spawn_name := StringName(spawn_point.name)
			if enemy_spawn_points_by_name.has(spawn_name):
				push_error("EnemySpawnPoints 包含重复名称：%s" % String(spawn_name))
				spawn_point_configuration_valid = false
				continue
			enemy_spawn_points.append(spawn_point)
			enemy_spawn_points_by_name[spawn_name] = spawn_point

	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")

func _configure_timers() -> void:
	enemy_spawn_timer.one_shot = false
	if not enemy_spawn_timer.timeout.is_connected(_on_enemy_spawn_timer_timeout):
		enemy_spawn_timer.timeout.connect(_on_enemy_spawn_timer_timeout)

	state_timer.one_shot = false
	state_timer.wait_time = 1.0
	if not state_timer.timeout.is_connected(_on_state_timer_timeout):
		state_timer.timeout.connect(_on_state_timer_timeout)

func _prewarm_enemy_navigation_grids() -> void:
	if grid_pathfinder == null:
		return
	if not grid_pathfinder.has_method("prewarm_agent_grid"):
		return
	if not bool(grid_pathfinder.get("is_built")):
		return

	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true

			var body_half_extents := _get_enemy_scene_body_half_extents(enemy_config)
			if body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			grid_pathfinder.call(
				"prewarm_agent_grid",
				body_half_extents,
				traversal_types
			)
			if grid_pathfinder.has_method("prewarm_flow_navigation_target") and player != null:
				grid_pathfinder.call(
					"prewarm_flow_navigation_target",
					player.global_position,
					body_half_extents,
					traversal_types
				)

func _schedule_enemy_navigation_prewarm() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		return
	if navigation_prewarmed or navigation_prewarm_requested:
		return
	navigation_prewarm_requested = true
	call_deferred("_run_scheduled_enemy_navigation_prewarm")

func _run_scheduled_enemy_navigation_prewarm() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	navigation_prewarm_requested = false
	if navigation_prewarmed:
		await prewarm_shared_runtime_data()
		if not is_inside_tree():
			return
		mark_runtime_preparation_complete()
		return
	await _prewarm_enemy_navigation_grids_staged()
	if not is_inside_tree():
		return
	navigation_prewarmed = true
	await prewarm_shared_runtime_data()
	if not is_inside_tree():
		return
	mark_runtime_preparation_complete()

func _prewarm_enemy_navigation_grids_staged() -> void:
	update_runtime_preparation_progress("分析敌人通行体型…", 0, 1)
	await get_tree().process_frame
	if (
		grid_pathfinder == null
		or not grid_pathfinder.has_method("prewarm_agent_grid")
		or not bool(grid_pathfinder.get("is_built"))
	):
		return

	var profiles: Array[Dictionary] = []
	var seen_scene_keys: Dictionary = {}
	var seen_extent_keys: Dictionary = {}
	for wave_config in waves:
		if wave_config == null:
			continue
		for entry in wave_config.enemy_entries:
			if entry == null or entry.enemy_config == null:
				continue
			var enemy_config := entry.enemy_config
			if enemy_config.enemy_scene == null:
				continue
			var scene_key := enemy_config.enemy_scene.resource_path
			if scene_key.is_empty():
				scene_key = enemy_config.resource_path
			if seen_scene_keys.has(scene_key):
				continue
			seen_scene_keys[scene_key] = true
			var body_half_extents := _get_enemy_scene_body_half_extents(enemy_config)
			await get_tree().process_frame
			if not is_inside_tree() or body_half_extents == Vector2.ZERO:
				continue
			var traversal_types := enemy_config.terrain_traversal_types
			var extent_key := "%d:%d:%d" % [
				ceili(body_half_extents.x),
				ceili(body_half_extents.y),
				traversal_types,
			]
			if seen_extent_keys.has(extent_key):
				continue
			seen_extent_keys[extent_key] = true
			profiles.append({
				"half_extents": body_half_extents,
				"traversal_types": traversal_types,
			})

	var target_count := 1 if player != null else 0
	var total_steps := maxi(profiles.size() * (1 + target_count), 1)
	var completed_steps := 0
	update_runtime_preparation_progress("预热寻路网格…", completed_steps, total_steps)
	for profile in profiles:
		var half_extents: Vector2 = profile["half_extents"]
		var traversal_types: int = int(profile["traversal_types"])
		if grid_pathfinder.has_method("prewarm_agent_grid_staged"):
			await grid_pathfinder.call(
				"prewarm_agent_grid_staged",
				half_extents,
				traversal_types
			)
		else:
			grid_pathfinder.call("prewarm_agent_grid", half_extents, traversal_types)
		completed_steps += 1
		update_runtime_preparation_progress("预热寻路网格…", completed_steps, total_steps)
		await get_tree().process_frame
		if not is_inside_tree():
			return
		if player != null and grid_pathfinder.has_method("prewarm_flow_navigation_target"):
			if grid_pathfinder.has_method("prewarm_flow_navigation_target_staged"):
				await grid_pathfinder.call(
					"prewarm_flow_navigation_target_staged",
					player.global_position,
					half_extents,
					traversal_types
				)
			else:
				grid_pathfinder.call(
					"prewarm_flow_navigation_target",
					player.global_position,
					half_extents,
					traversal_types
				)
			completed_steps += 1
			update_runtime_preparation_progress("预热首波路线…", completed_steps, total_steps)
			await get_tree().process_frame

func _prewarm_enemy_visual_resources() -> void:
	GUARDIAN_POINT_LIGHT_TEXTURE.get_size()

func _get_enemy_scene_body_half_extents(enemy_config: EnemyConfig) -> Vector2:
	if enemy_config == null or enemy_config.enemy_scene == null:
		return Vector2.ZERO
	var instance := enemy_config.enemy_scene.instantiate()
	var enemy_instance := instance as Enemy
	if enemy_instance == null:
		if instance != null:
			instance.free()
		return Vector2.ZERO
	var body_half_extents := enemy_instance.get_configured_body_collision_half_extents()
	enemy_instance.free()
	return body_half_extents

func _enter_pre_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		_enter_victory()
		return
	wave_state = CombatFlowState.State.PRE_WAVE
	transition_world_to_day()
	current_flow_step = flow_step
	next_flow_step_after_rest = flow_step
	if flow_step is WaveConfig:
		current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	enemy_spawn_timer.stop()
	_set_intermission_services_active(false)
	countdown_seconds = maxi(ceili(pre_wave_duration), 0)
	_present_flow_countdown(wave_state, countdown_seconds)
	_schedule_enemy_navigation_prewarm()
	_emit_multiplayer_flow_state(CombatFlowState.State.PRE_WAVE)
	if countdown_seconds <= 0:
		_begin_flow_step(current_flow_step)
		return
	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_present_countdown_tick()
	state_timer.start(1.0)


func _enter_intermission(next_step: FlowStepConfig = null) -> void:
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_mode_adapter.revive_all_requested.emit()
	wave_state = CombatFlowState.State.INTERMISSION
	transition_world_to_day()
	enemy_spawn_timer.stop()
	_set_intermission_services_active(true)
	next_flow_step_after_rest = next_step
	countdown_seconds = (
		maxi(ceili(current_flow_step.post_clear_rest_duration), 0)
		if current_flow_step != null
		else 0
	)
	_present_intermission_started(current_flow_step)
	_present_flow_countdown(wave_state, countdown_seconds)
	_emit_multiplayer_flow_state(CombatFlowState.State.INTERMISSION)
	if countdown_seconds <= 0:
		_begin_flow_step(next_flow_step_after_rest)
		return
	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_present_countdown_tick()
	state_timer.start(1.0)


func _begin_flow_step(flow_step: FlowStepConfig) -> void:
	if flow_step == null:
		_enter_victory()
		return
	current_flow_step = flow_step
	next_flow_step_after_rest = null
	if flow_step is WaveConfig:
		_begin_wave_config(flow_step as WaveConfig)
	elif not _begin_mode_flow_step(flow_step):
		push_error("流程节点 %s 类型不支持。" % flow_step.get_flow_display_name())
		_enter_defeat()


func _begin_wave_config(wave_config: WaveConfig) -> void:
	if wave_config == null:
		push_error("流程节点缺少 WaveConfig。")
		_enter_defeat()
		return
	if not _resolve_wave_spawn_points(wave_config):
		_enter_defeat()
		return
	if runtime_mode != RuntimeMode.CLIENT_VIEW and not navigation_prewarmed:
		_prewarm_enemy_navigation_grids()
		navigation_prewarmed = true

	wave_state = CombatFlowState.State.WAVE_ACTIVE
	current_wave_index = _get_wave_number_for_step(wave_config) - 1
	_apply_wave_start_lighting(current_wave_index + 1)
	state_timer.stop()
	_set_intermission_services_active(false)
	clear_active_wave_enemies()
	_build_wave_spawn_queue(wave_config)
	reset_wave_progress(pending_enemy_configs.size())
	_present_wave_started(wave_config, false)
	_emit_multiplayer_flow_state(CombatFlowState.State.WAVE_ACTIVE)

	if current_wave_total <= 0:
		_check_wave_completion()
		return

	_spawn_wave_batch()
	if _has_pending_enemy_configs():
		enemy_spawn_timer.start(maxf(wave_config.spawn_interval, MIN_WAVE_SPAWN_INTERVAL_SECONDS))

func _build_wave_spawn_queue(wave_config: WaveConfig) -> void:
	pending_enemy_configs.clear()
	pending_enemy_xirang_kill_rewards.clear()
	pending_enemy_config_index = 0
	if wave_config.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN:
		_build_entry_round_robin_spawn_queue(wave_config)
		return
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		for _enemy_index in range(maxi(entry.count, 0)):
			pending_enemy_configs.append(entry.enemy_config)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(entry.enemy_config)
			)

	for source_index in range(pending_enemy_configs.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary_config := pending_enemy_configs[source_index]
		pending_enemy_configs[source_index] = pending_enemy_configs[target_index]
		pending_enemy_configs[target_index] = temporary_config
		var temporary_reward := pending_enemy_xirang_kill_rewards[source_index]
		pending_enemy_xirang_kill_rewards[source_index] = (
			pending_enemy_xirang_kill_rewards[target_index]
		)
		pending_enemy_xirang_kill_rewards[target_index] = temporary_reward

func _build_entry_round_robin_spawn_queue(wave_config: WaveConfig) -> void:
	var entries: Array[WaveEnemyEntry] = []
	var remaining_counts: Array[int] = []
	var remaining_total := 0
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var entry_count := maxi(entry.count, 0)
		if entry_count <= 0:
			continue
		entries.append(entry)
		remaining_counts.append(entry_count)
		remaining_total += entry_count

	while remaining_total > 0:
		for entry_index in range(entries.size()):
			if remaining_counts[entry_index] <= 0:
				continue
			var entry := entries[entry_index]
			pending_enemy_configs.append(entry.enemy_config)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(entry.enemy_config)
			)
			remaining_counts[entry_index] -= 1
			remaining_total -= 1

func _resolve_wave_spawn_points(wave_config: WaveConfig) -> bool:
	active_wave_spawn_points.clear()
	_balanced_spawn_point_bag.clear()
	var resolution := _inspect_wave_spawn_points(wave_config)
	if not bool(resolution.get("valid", false)):
		var error_message := str(resolution.get("error", ""))
		if not error_message.is_empty():
			push_error(error_message)
		return false
	active_wave_spawn_points.assign(resolution.get("points", []))
	return not active_wave_spawn_points.is_empty()

func _inspect_wave_spawn_points(wave_config: WaveConfig) -> Dictionary:
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

func _on_state_timer_timeout() -> void:
	if runtime_mode == RuntimeMode.CLIENT_VIEW:
		_update_client_flow_countdown()
		return
	if (
		wave_state != CombatFlowState.State.PRE_WAVE
		and wave_state != CombatFlowState.State.INTERMISSION
	):
		state_timer.stop()
		return
	countdown_seconds = maxi(countdown_seconds - 1, 0)
	if countdown_seconds > 0:
		_present_flow_countdown(wave_state, countdown_seconds)
		if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
			_present_countdown_tick()
		return
	state_timer.stop()
	if wave_state == CombatFlowState.State.PRE_WAVE:
		_begin_flow_step(current_flow_step)
	else:
		_begin_flow_step(next_flow_step_after_rest)


func _on_enemy_spawn_timer_timeout() -> void:
	_spawn_wave_batch()

func _start_client_flow_countdown(
	state: CombatFlowState.State,
	step_id: StringName,
	seconds: int
) -> void:
	wave_state = state
	var flow_step := _get_flow_step_by_id(step_id)
	if flow_step != null:
		current_flow_step = flow_step
		if flow_step is WaveConfig:
			current_wave_index = _get_wave_number_for_step(flow_step as WaveConfig) - 1
	if state == CombatFlowState.State.INTERMISSION:
		_present_intermission_started(flow_step)
	countdown_seconds = maxi(seconds, 0)
	_present_flow_countdown(wave_state, countdown_seconds)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	state_timer.start(1.0)


func _update_client_flow_countdown() -> void:
	if (
		wave_state != CombatFlowState.State.PRE_WAVE
		and wave_state != CombatFlowState.State.INTERMISSION
	):
		state_timer.stop()
		return
	countdown_seconds = maxi(countdown_seconds - 1, 0)
	_present_flow_countdown(wave_state, countdown_seconds)
	if countdown_seconds <= 0:
		state_timer.stop()
		return
	if countdown_seconds <= COUNTDOWN_FINAL_SECONDS:
		_present_countdown_tick()


func _spawn_wave_batch() -> void:
	if wave_state != CombatFlowState.State.WAVE_ACTIVE:
		enemy_spawn_timer.stop()
		return

	var wave_config := _get_current_wave()
	if wave_config == null:
		enemy_spawn_timer.stop()
		return

	var spawn_count_this_tick := mini(
		maxi(wave_config.spawn_count_per_tick, 1),
		MAX_WAVE_SPAWN_COUNT_PER_TICK
	)
	for _spawn_index in range(spawn_count_this_tick):
		if not _has_pending_enemy_configs():
			break
		if (
			wave_enemy_terminal_ledger.get_attached_enemy_count()
			>= maxi(wave_config.max_alive_enemies, 1)
		):
			break

		var enemy_config := pending_enemy_configs[pending_enemy_config_index]
		var xirang_kill_reward := pending_enemy_xirang_kill_rewards[
			pending_enemy_config_index
		]
		if not _try_spawn_enemy(enemy_config, xirang_kill_reward):
			break

		pending_enemy_config_index += 1

	if not _has_pending_enemy_configs():
		enemy_spawn_timer.stop()
		_clear_pending_enemy_spawn_queue()

	_check_wave_completion()

func _has_pending_enemy_configs() -> bool:
	return pending_enemy_config_index < pending_enemy_configs.size()

func _clear_pending_enemy_spawn_queue() -> void:
	pending_enemy_configs.clear()
	pending_enemy_xirang_kill_rewards.clear()
	pending_enemy_config_index = 0

func _try_spawn_enemy(
	enemy_config: EnemyConfig,
	xirang_kill_reward_override: int = -1
) -> bool:
	if not _is_spawn_system_ready() or enemy_config == null:
		return false

	var spawn_point := _pick_spawn_point()
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

	enemy_container.add_child(enemy_instance)
	enemy_instance.global_position = spawn_point.global_position
	enemy_instance.setup(
		enemy_config,
		_pick_enemy_target(spawn_point.global_position),
		grid_pathfinder,
		self
	)
	enemy_instance.set_xirang_kill_reward_override(xirang_kill_reward_override)
	var enemy_id := enemy_instance.get_instance_id()
	if not register_active_wave_enemy(enemy_instance):
		push_error("WaveCombatRuntimeBase: 敌人生成未能登记到当前波次。")
		enemy_instance.queue_free()
		return false
	enemy_instance.defeated.connect(_on_wave_enemy_defeated)
	enemy_instance.tree_exited.connect(_on_wave_enemy_tree_exited.bind(enemy_id))
	_register_multiplayer_enemy_instance(enemy_instance, enemy_config, enemy_instance.global_position)
	_spawn_enemy_spawn_effect(spawn_point.global_position)
	return true

func _register_multiplayer_enemy_instance(
	enemy_instance: Enemy,
	enemy_config: EnemyConfig,
	spawn_position: Vector2,
	broadcast_spawn: bool = true
) -> int:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return 0
	if enemy_instance == null or enemy_config == null:
		return 0
	var enemy_id := enemy_instance.get_instance_id()
	var existing_net_id := get_network_enemy_net_id_by_instance_id(enemy_id)
	if existing_net_id > 0:
		return existing_net_id
	var enemy_net_id := next_multiplayer_enemy_net_id
	next_multiplayer_enemy_net_id += 1
	if not register_network_enemy(enemy_net_id, enemy_instance):
		return 0
	if broadcast_spawn:
		multiplayer_gateway.enemy_spawned.emit(enemy_net_id, enemy_config, spawn_position)
	return enemy_net_id

func _on_wave_enemy_defeated(enemy: Enemy) -> void:
	if wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	if (
		enemy == null
		or not try_resolve_active_wave_enemy_defeat(enemy.get_instance_id())
	):
		return
	_emit_multiplayer_enemy_defeated(enemy)
	_present_wave_progress(current_wave_resolved, current_wave_total)
	_check_wave_completion()


func _emit_multiplayer_enemy_defeated(enemy: Enemy) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	if enemy == null:
		return
	var enemy_net_id := get_network_enemy_net_id_by_instance_id(
		enemy.get_instance_id()
	)
	if enemy_net_id <= 0:
		return
	multiplayer_gateway.enemy_defeated.emit(enemy_net_id, enemy.global_position)

func _on_wave_enemy_tree_exited(enemy_id: int) -> void:
	var result := wave_enemy_terminal_ledger.detach_enemy(enemy_id)
	if not result.accepted:
		if not result.known:
			push_error(
				"WaveCombatRuntimeBase: 未登记实体 %d 退出，执行隔离的网络清理。"
				% enemy_id
			)
			_cleanup_untracked_multiplayer_enemy_exit(enemy_id)
		return
	if (
		result.terminal_created
		and result.role == WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
	):
		push_error(
			"WaveCombatRuntimeBase: 波次目标 %d 未经终结便离开场景树，按 REMOVED 结算。"
			% enemy_id
		)
		_present_wave_progress(current_wave_resolved, current_wave_total)
	_mark_multiplayer_enemy_detached(enemy_id, result)
	_check_wave_completion()


func _mark_multiplayer_enemy_detached(
	enemy_id: int,
	detach_result: WaveEnemyTerminalLedger.DetachResult
) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var enemy_net_id := unregister_network_enemy_by_instance_id(enemy_id)
	if enemy_net_id <= 0:
		return
	# DEFEATED 只消费多人配对缓存；REMOVED 在离树时首次广播；
	# ESCAPED 已发送唯一终结包，不再追加通用 removed。
	if (
		detach_result.terminal_reason
		!= CombatTypes.EnemyTerminalReason.ESCAPED
	):
		multiplayer_gateway.enemy_removed.emit(enemy_net_id)


func _cleanup_untracked_multiplayer_enemy_exit(enemy_id: int) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	var enemy_net_id := unregister_network_enemy_by_instance_id(enemy_id)
	if enemy_net_id > 0:
		multiplayer_gateway.enemy_removed.emit(enemy_net_id)

func _check_wave_completion() -> void:
	if wave_state != CombatFlowState.State.WAVE_ACTIVE:
		return
	if _has_pending_enemy_configs():
		return
	if not is_wave_progress_complete():
		return
	if wave_enemy_terminal_ledger.get_attached_enemy_count(
		WaveEnemyTerminalLedger.EnemyRole.OBJECTIVE
	) > 0:
		return

	enemy_spawn_timer.stop()
	_complete_current_step()

func _complete_current_step() -> void:
	var next_step := _get_default_next_flow_step(current_flow_step)
	if next_step == null:
		_enter_victory()
		return
	if current_flow_step != null and current_flow_step.post_clear_rest_duration > 0.0:
		_enter_intermission(next_step)
		return
	_begin_flow_step(next_step)

func _enter_victory(emit_multiplayer: bool = true) -> void:
	if wave_state == CombatFlowState.State.VICTORY:
		return
	if emit_multiplayer and runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_mode_adapter.revive_all_requested.emit()
	wave_state = CombatFlowState.State.VICTORY
	transition_world_to_day()
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_intermission_services_active(false)
	_present_terminal_state(true)
	if emit_multiplayer and runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_mode_adapter.victory_started.emit()
		_emit_multiplayer_flow_state(CombatFlowState.State.VICTORY)


func _enter_defeat() -> void:
	if wave_state == CombatFlowState.State.DEFEAT:
		return
	wave_state = CombatFlowState.State.DEFEAT
	transition_world_to_day()
	enemy_spawn_timer.stop()
	state_timer.stop()
	_set_intermission_services_active(false)
	_present_terminal_state(false)
	if runtime_mode == RuntimeMode.HOST_AUTHORITY:
		multiplayer_mode_adapter.defeat_started.emit()


func get_enemy_for_net_id(net_id: int) -> Enemy:
	return get_network_enemy(net_id)

func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return collect_reused_enemy_snapshot_states(enemy_container)


func _update_multiplayer_enemy_targets(delta: float) -> void:
	enemy_retarget_time_left = maxf(enemy_retarget_time_left - delta, 0.0)
	if enemy_retarget_time_left > 0.0:
		return
	enemy_retarget_time_left = 0.35
	for child in enemy_container.get_children():
		var enemy := child as Enemy
		if enemy == null or enemy.is_dead:
			continue
		enemy.set_target_player(_pick_enemy_target(enemy.global_position))

func _pick_enemy_target(from_position: Vector2) -> Player:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return player
	var best_player: Player = null
	var best_distance := INF
	for peer_id_variant in peer_players:
		var candidate := peer_players[peer_id_variant] as Player
		if candidate == null or not is_instance_valid(candidate) or candidate.is_dead:
			continue
		var distance := from_position.distance_squared_to(candidate.global_position)
		if distance < best_distance:
			best_distance = distance
			best_player = candidate
	return best_player if best_player != null else player

func _is_flow_system_ready() -> bool:
	if flow_graph == null:
		push_error("%s 当前 Campaign 没有配置 FlowGraphConfig。" % get_class())
		return false
	if not _is_spawn_system_ready():
		return false
	var errors := flow_graph.validate_graph()
	for error in errors:
		push_warning(error)
	if not errors.is_empty():
		return false
	return _get_start_flow_step() != null

func _get_start_flow_step() -> FlowStepConfig:
	return flow_graph.start_step if flow_graph != null else null

func _get_flow_step_by_id(step_id: StringName) -> FlowStepConfig:
	if step_id == &"":
		return null
	return flow_graph.get_step_by_id(step_id) if flow_graph != null else null

func _get_flow_step_id(flow_step: FlowStepConfig) -> StringName:
	return flow_step.step_id if flow_step != null else &""

func _get_default_next_flow_step(flow_step: FlowStepConfig) -> FlowStepConfig:
	if flow_step == null:
		return null
	if flow_graph == null or flow_graph.get_step_index(flow_step) < 0:
		return null
	return flow_graph.get_default_next_step(flow_step)

func _get_wave_number_for_step(wave_config: WaveConfig) -> int:
	if wave_config == null:
		return current_wave_index + 1
	var wave_index := waves.find(wave_config)
	if wave_index >= 0:
		return wave_index + 1
	if flow_graph != null:
		var wave_number := 0
		for step in flow_graph.steps:
			if step is WaveConfig:
				wave_number += 1
			if step == wave_config:
				return maxi(wave_number, 1)
	return current_wave_index + 1

func _emit_multiplayer_flow_state(state: CombatFlowState.State) -> void:
	if runtime_mode != RuntimeMode.HOST_AUTHORITY:
		return
	multiplayer_mode_adapter.flow_state_changed.emit(
		_get_flow_step_id(current_flow_step),
		int(state),
		countdown_seconds
	)

func _is_spawn_system_ready() -> bool:
	return (
		player != null
		and grid_pathfinder != null
		and grid_pathfinder.get("is_built")
		and not enemy_spawn_points.is_empty()
	)

func _get_current_wave() -> WaveConfig:
	return current_flow_step as WaveConfig

func _pick_spawn_point() -> Marker2D:
	if active_wave_spawn_points.is_empty():
		return null
	var wave_config := _get_current_wave()
	if (
		wave_config != null
		and wave_config.spawn_point_order
		== WaveConfig.SpawnPointOrder.BALANCED_SHUFFLE_BAG
	):
		return _pick_balanced_spawn_point()
	return active_wave_spawn_points[
		random_generator.randi_range(0, active_wave_spawn_points.size() - 1)
	]


func _pick_balanced_spawn_point() -> Marker2D:
	if _balanced_spawn_point_bag.is_empty():
		_refill_balanced_spawn_point_bag()
	if _balanced_spawn_point_bag.is_empty():
		return null
	return _balanced_spawn_point_bag.pop_back()


func _refill_balanced_spawn_point_bag() -> void:
	_balanced_spawn_point_bag.assign(active_wave_spawn_points)
	for source_index in range(_balanced_spawn_point_bag.size() - 1, 0, -1):
		var target_index := random_generator.randi_range(0, source_index)
		var temporary_point := _balanced_spawn_point_bag[source_index]
		_balanced_spawn_point_bag[source_index] = _balanced_spawn_point_bag[target_index]
		_balanced_spawn_point_bag[target_index] = temporary_point

func _spawn_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	if not try_reserve_enemy_spawn_effect(spawn_global_position):
		return
	var effect := session_object_pool.acquire(ENEMY_SPAWN_EFFECT_SCENE) as Node2D
	if effect == null:
		return
	effect.global_position = spawn_global_position
	if effect.has_method("restart_effect"):
		effect.call("restart_effect")

func play_remote_enemy_spawn_effect(spawn_global_position: Vector2) -> void:
	_spawn_enemy_spawn_effect(spawn_global_position)

func _play_countdown_tick() -> void:
	_present_countdown_tick()
