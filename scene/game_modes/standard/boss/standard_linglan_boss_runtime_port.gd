extends LinglanBossRuntimePort
class_name StandardLinglanBossRuntimePort

var game: StandardGame = null


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	super.bind_runtime(runtime_instance)
	game = runtime_instance as StandardGame


func uses_tower_defense_rules() -> bool:
	return false


func is_terminal_combat_state() -> bool:
	return (
		game != null
		and game.wave_state in [
			CombatFlowState.State.VICTORY,
			CombatFlowState.State.DEFEAT,
		]
	)


func pause_background_music() -> void:
	if game != null:
		game.pause_all_background_music()


func get_home_objective_target(_from_position: Vector2) -> Node2D:
	return null


func spawn_random_slime(_spawn_position: Vector2) -> void:
	pass


func get_enrage_sniper_config() -> EnemyConfig:
	return game.get_linglan_enrage_sniper_config() if game != null else null


func spawn_airdrop_sniper(
	enemy_config: EnemyConfig,
	warning_scene: PackedScene,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if game != null:
		game.spawn_linglan_airdrop_sniper(
			enemy_config,
			warning_scene,
			warning_duration,
			drop_height,
			drop_duration
		)


func get_skill2_target_player(from_position: Vector2) -> Player:
	return game.get_linglan_skill2_target_player(from_position) if game != null else null


func spawn_skill2_enemies(
	enemy_config: EnemyConfig,
	marker_names: Array[StringName]
) -> void:
	if game != null:
		game.spawn_linglan_skill2_enemies(enemy_config, marker_names)


func get_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
	return (
		game.get_linglan_skill2_target_global_position(target_cell)
		if game != null
		else Vector2.ZERO
	)


func get_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
	return (
		game.get_linglan_skill3_target_global_position(target_cell)
		if game != null
		else Vector2.ZERO
	)


func get_skill4_target_global_position(
	target_cell_a: Vector2i,
	target_cell_b: Vector2i
) -> Vector2:
	return (
		game.get_linglan_skill4_target_global_position(target_cell_a, target_cell_b)
		if game != null
		else Vector2.ZERO
	)


func get_skill4_laser_bounds(
	left_cell_x: int,
	right_cell_x: int,
	top_cell_y: int,
	bottom_cell_y: int,
	inward_cell_distance: int
) -> Dictionary:
	if game == null:
		return {}
	return game.get_linglan_skill4_laser_bounds(
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
		game.get_linglan_skill4_orb_spawn_global_position(x_cell, y_cell)
		if game != null
		else Vector2.ZERO
	)
