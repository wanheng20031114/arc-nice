extends LinglanBossRuntimePort
class_name TowerDefenseLinglanBossRuntimePort

var boss_coordinator: TowerDefenseBossCoordinator


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	super.bind_runtime(runtime_instance)


func bind_boss_coordinator(coordinator: TowerDefenseBossCoordinator) -> void:
	boss_coordinator = coordinator


func uses_tower_defense_rules() -> bool:
	return true


func is_terminal_combat_state() -> bool:
	return (
		boss_coordinator != null
		and boss_coordinator.is_terminal_combat_state()
	)


func pause_background_music() -> void:
	if boss_coordinator != null:
		boss_coordinator.pause_background_music()


func get_home_objective_target(from_position: Vector2) -> Node2D:
	return (
		boss_coordinator.get_home_objective_target(from_position)
		if boss_coordinator != null
		else null
	)


func spawn_random_slime(spawn_position: Vector2) -> void:
	if boss_coordinator != null:
		boss_coordinator.spawn_random_slime(spawn_position)


func get_enrage_sniper_config() -> EnemyConfig:
	return boss_coordinator.get_enrage_sniper_config() if boss_coordinator != null else null


func spawn_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if boss_coordinator != null:
		boss_coordinator.spawn_airdrop_sniper(
			enemy_config,
			warning_scene,
			warning_duration,
			drop_height,
			drop_duration
		)


func get_skill2_target_player(from_position: Vector2) -> Player:
	return boss_coordinator.get_skill2_target_player(from_position) if boss_coordinator != null else null


func spawn_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	if boss_coordinator != null:
		boss_coordinator.spawn_skill2_enemies(enemy_config, marker_names)


func get_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
	return (
		boss_coordinator.get_skill_target_global_position(target_cell)
		if boss_coordinator != null
		else Vector2.ZERO
	)


func get_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
	return (
		boss_coordinator.get_skill_target_global_position(target_cell)
		if boss_coordinator != null
		else Vector2.ZERO
	)


func get_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	return (
		boss_coordinator.get_skill4_target_global_position(target_cell_a, target_cell_b)
		if boss_coordinator != null
		else Vector2.ZERO
	)


func get_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary:
	if boss_coordinator == null:
		return {}
	return boss_coordinator.get_skill4_laser_bounds(
		left_cell_x,
		right_cell_x,
		top_cell_y,
		bottom_cell_y,
		inward_cell_distance
	)


func get_skill4_orb_spawn_global_position(
	x_cell: int,
	y_cell: int
) -> Vector2:
	return (
		boss_coordinator.get_skill4_orb_spawn_global_position(x_cell, y_cell)
		if boss_coordinator != null
		else Vector2.ZERO
	)
