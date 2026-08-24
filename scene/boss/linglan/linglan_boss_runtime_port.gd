@abstract
extends Node
class_name LinglanBossRuntimePort

## Strong mode-specific boundary for Linglan's arena rules. Neutral combat,
## pooling, damage and network operations stay on CombatRuntimeBase and
## MultiplayerGameplayGateway instead of being mirrored here.
signal airdrop_started(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
)

const AIRDROP_WARNING_SCENE := preload(
	"res://scene/boss/linglan/linglan_airdrop_warning_marker.tscn"
)

var combat_runtime: CombatRuntimeBase = null


func _ready() -> void:
	bind_runtime(get_parent() as CombatRuntimeBase)


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	combat_runtime = runtime_instance


func is_bound() -> bool:
	return combat_runtime != null and is_instance_valid(combat_runtime)


func apply_remote_airdrop_started(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if (
		not is_bound()
		or combat_runtime.runtime_mode
			!= CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or enemy_config == null
		or enemy_config.enemy_scene == null
		or not landing_position.is_finite()
		or is_terminal_combat_state()
	):
		return
	var safe_warning_duration := clampf(warning_duration, 0.0, 5.0)
	var safe_drop_height := clampf(drop_height, 0.0, 512.0)
	var safe_drop_duration := clampf(drop_duration, 0.01, 5.0)
	var warning := AIRDROP_WARNING_SCENE.instantiate() as LinglanAirdropWarningMarker
	if warning != null:
		combat_runtime.add_child(warning)
		warning.top_level = true
		warning.global_position = landing_position
		warning.start(maxf(safe_warning_duration, 0.05))
	_play_remote_airdrop_visual(
		enemy_config,
		landing_position,
		safe_warning_duration,
		safe_drop_height,
		safe_drop_duration
	)


func _play_remote_airdrop_visual(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if warning_duration > 0.0:
		await combat_runtime.get_tree().create_timer(warning_duration, false).timeout
	if (
		not is_bound()
		or not combat_runtime.is_inside_tree()
		or is_terminal_combat_state()
		or combat_runtime.enemy_container == null
	):
		return
	var visual := enemy_config.enemy_scene.instantiate() as Enemy
	if visual == null:
		return
	visual.name = "LinglanAirdropSniperVisual"
	combat_runtime.enemy_container.add_child(visual)
	visual.global_position = landing_position + Vector2.UP * drop_height
	visual.setup(enemy_config, null, null, combat_runtime)
	visual.configure_multiplayer_proxy()
	visual.collision_layer = 0
	visual.collision_mask = 0
	visual.add_to_group(&"linglan_airdrop_visual")
	var tween := visual.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.set_ease(Tween.EASE_IN)
	tween.tween_property(
		visual,
		"global_position",
		landing_position,
		drop_duration
	)
	await tween.finished
	if is_instance_valid(visual):
		visual.queue_free()


@abstract func uses_tower_defense_rules() -> bool
@abstract func is_terminal_combat_state() -> bool
@abstract func pause_background_music() -> void
@abstract func get_home_objective_target(from_position: Vector2) -> Node2D
@abstract func spawn_random_slime(spawn_position: Vector2) -> void
@abstract func get_enrage_sniper_config() -> EnemyConfig
@abstract func spawn_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void
@abstract func get_skill2_target_player(from_position: Vector2) -> Player
@abstract func spawn_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void
@abstract func get_skill2_target_global_position(target_cell: Vector2i) -> Vector2
@abstract func get_skill3_target_global_position(target_cell: Vector2i) -> Vector2
@abstract func get_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2
@abstract func get_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary
@abstract func get_skill4_orb_spawn_global_position(
	x_cell: int,
	y_cell: int
) -> Vector2
