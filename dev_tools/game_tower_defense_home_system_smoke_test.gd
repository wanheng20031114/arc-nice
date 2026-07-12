extends SceneTree

const TOWER_SCENE := preload("res://scene/game_tower_defense.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const FIRE_RANGED_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_fire_ranged.tres")
const RETARGET_STRESS_ENEMY_COUNT := 300
const EXPECTED_HOME_CELLS: Array[Vector2i] = [
	Vector2i(2, 22),
	Vector2i(3, 22),
	Vector2i(2, 23),
	Vector2i(3, 23),
]
const EXPECTED_HOME_DAMAGE := {
	"capoo_ak47": 2,
	"capoo_knight": 5,
	"capoo_knight_elite": 8,
	"capoo_mage": 5,
	"capoo_rpg": 5,
	"capoo_smg": 2,
	"capoo_sniper": 2,
	"capoo_swordsman": 5,
	"yuanshi_insect_basic": 1,
	"yuanshi_insect_bomber": 1,
	"yuanshi_insect_fast": 1,
	"yuanshi_insect_fire_ranged": 2,
	"yuanshi_insect_green_shell": 5,
	"yuanshi_insect_guardian": 5,
	"yuanshi_insect_purple_bomber": 1,
	"yuanshi_insect_shell": 2,
}

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := TOWER_SCENE.instantiate() as GameTowerDefense
	_expect(game != null, "Tower-defense scene must instantiate for Home verification.")
	if game == null:
		_finish()
		return
	game.auto_start_waves = false
	_expect(not game.linglan_boss_enabled, "Tower-defense Linglan must be disabled by default.")
	root.add_child(game)
	current_scene = game
	await process_frame
	await process_frame

	_verify_camera(game)
	_verify_spawn_mask_resolution(game)
	_verify_home_gate_areas(game)
	await _verify_physical_home_gate_trigger(game)
	await _verify_far_linear_enemy_reaches_home(game)
	_verify_target_selection(game)
	_verify_enemy_contract(game)
	_verify_home_damage_resources()
	_expect(game.bosses.is_empty(), "Tower-defense Campaign must not contain a Boss step.")
	await _verify_escape_resolution(game)

	game.queue_free()
	await process_frame
	await process_frame
	_finish()


func _verify_camera(game: GameTowerDefense) -> void:
	_expect(game.map_camera.get_parent() == game.player, "Camera2D must follow the local player.")
	_expect(game.map_camera.position == Vector2.ZERO, "Following camera must use zero local offset.")
	_expect(game.map_camera.zoom == Vector2(2.0, 2.0), "Tower-defense camera must retain 2x zoom.")
	_expect(not game.map_camera.position_smoothing_enabled, "Tower-defense camera smoothing must stay disabled.")
	_expect(
		game.map_camera.process_callback == Camera2D.CAMERA2D_PROCESS_PHYSICS,
		"The interpolated follow camera must sample physics transforms."
	)
	_expect(
		game.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"Tower-defense static scene branches must stay outside physics interpolation."
	)
	_expect(
		game.player.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_ON,
		"The local player and its following camera must use native interpolation."
	)
	_expect(
		physics_interpolation,
		"Tower-defense runtime must enable native physics interpolation."
	)


func _verify_spawn_mask_resolution(game: GameTowerDefense) -> void:
	var test_wave := WaveConfig.new()
	test_wave.step_id = &"spawn_mask_probe"
	test_wave.spawn_point_mask = (1 << 1) | (1 << 5)
	_expect(
		bool(game.call("_resolve_wave_spawn_points", test_wave)),
		"Tower-defense runtime must resolve an authored spawn-point subset."
	)
	var resolved_names: Array[StringName] = []
	for marker in game.active_wave_spawn_points:
		resolved_names.append(StringName(marker.name))
	_expect(
		resolved_names == [&"Spawn2", &"Spawn6"],
		"Tower-defense runtime must spawn only from the wave mask, including Spawn6."
	)

	var empty_wave := WaveConfig.new()
	empty_wave.step_id = &"empty_spawn_mask_probe"
	empty_wave.spawn_point_mask = 0
	var empty_resolution := game.call("_inspect_wave_spawn_points", empty_wave) as Dictionary
	_expect(
		not bool(empty_resolution.get("valid", true))
		and (empty_resolution.get("points", []) as Array).is_empty(),
		"An empty spawn mask must fail without falling back to every marker."
	)
	_expect(
		str(empty_resolution.get("error", "")).contains("没有启用任何出生点"),
		"An empty spawn mask must produce a precise configuration diagnostic."
	)

	var spawn6 := game.enemy_spawn_points_by_name.get(&"Spawn6") as Marker2D
	_expect(spawn6 != null, "Spawn6 must exist before the missing-marker probe.")
	if spawn6 == null:
		return
	game.enemy_spawn_points_by_name.erase(&"Spawn6")
	var missing_wave := WaveConfig.new()
	missing_wave.step_id = &"missing_spawn_marker_probe"
	missing_wave.spawn_point_mask = 1 << 5
	var missing_resolution := game.call("_inspect_wave_spawn_points", missing_wave) as Dictionary
	game.enemy_spawn_points_by_name[&"Spawn6"] = spawn6
	_expect(
		not bool(missing_resolution.get("valid", true))
		and (missing_resolution.get("points", []) as Array).is_empty(),
		"A missing authored marker must fail without falling back to every marker."
	)
	_expect(
		str(missing_resolution.get("error", "")).contains("Spawn6"),
		"A missing marker diagnostic must identify the authored marker name."
	)


func _verify_home_gate_areas(game: GameTowerDefense) -> void:
	var controller := game.home_gate_controller
	_expect(controller != null, "HomeGateController must exist.")
	if controller == null:
		return
	var cells := controller.get_home_gate_cells()
	_expect(cells.size() == EXPECTED_HOME_CELLS.size(), "Exactly four home-gate cells must be discovered.")
	for expected_cell in EXPECTED_HOME_CELLS:
		_expect(cells.has(expected_cell), "Missing home-gate cell %s." % expected_cell)
		_expect(
			game.plant_system.reserved_cells.has(expected_cell),
			"Home-gate cells must be reserved against plant placement: %s." % expected_cell
		)
	var targets := controller.get_objective_targets()
	_expect(targets.size() == 1, "The connected 2x2 Home gate must expose one corridor-center objective.")
	if targets.size() == 1:
		_expect(
			targets[0].global_position.is_equal_approx(Vector2(50.0, 368.0)),
			"The Home objective must use the connected gate's geometric center."
		)
	_expect(controller.home_gate_areas.size() == EXPECTED_HOME_CELLS.size(), "Every Home tile must retain one physical trigger Area2D.")
	for area in controller.home_gate_areas:
		_expect(area.collision_layer == 0, "Home Area2D must not occupy a collision layer.")
		_expect(area.collision_mask == 4, "Home Area2D must only detect Enemy layer value 4.")
		var shape_node := area.get_node_or_null("CollisionShape2D") as CollisionShape2D
		var rectangle := shape_node.shape as RectangleShape2D if shape_node != null else null
		_expect(rectangle != null and rectangle.size == Vector2(16, 16), "Home trigger must match one logical 16x16 cell.")


func _verify_physical_home_gate_trigger(game: GameTowerDefense) -> void:
	var targets := game.get_home_objective_targets()
	if targets.is_empty():
		return
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Basic enemy must instantiate for the physical Home trigger probe.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	enemy.set_physics_process(false)
	enemy.global_position = targets[0].global_position + Vector2(48.0, 0.0)
	await physics_frame
	var health_before := game.current_base_health
	enemy.global_position = targets[0].global_position
	for _frame in range(3):
		await physics_frame
		await process_frame
	_expect(
		game.current_base_health == health_before - BASIC_CONFIG.home_damage,
		"Enemy CharacterBody2D entering a Home Area2D must damage the base."
	)
	_expect(
		not is_instance_valid(enemy) or enemy.is_dead,
		"The physical Home trigger must immediately resolve and remove its enemy."
	)
	game.current_base_health = game.maximum_base_health
	game.base_health_revision = 0
	game.current_wave_escaped = 0
	game.current_wave_resolved = 0
	game.resolved_home_enemy_ids.clear()
	game.call("_update_base_health_display")


func _verify_far_linear_enemy_reaches_home(game: GameTowerDefense) -> void:
	var targets := game.get_home_objective_targets()
	if targets.is_empty() or game.enemy_spawn_points.is_empty():
		return
	var spawn_position := game.enemy_spawn_points[0].global_position
	var nearest_gate := targets[0]
	var nearest_distance := spawn_position.distance_squared_to(nearest_gate.global_position)
	for target in targets:
		var distance := spawn_position.distance_squared_to(target.global_position)
		if distance < nearest_distance:
			nearest_gate = target
			nearest_distance = distance

	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Far-linear Home journey must instantiate a basic enemy.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.global_position = spawn_position
	enemy.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	enemy.set_objective_target(nearest_gate)
	enemy.add_move_speed_modifier(900001, 8.0)
	# This fixture verifies the complete far-linear -> flow -> physical gate
	# journey. Runtime cold-build staging has its own dedicated smoke test.
	game.grid_pathfinder.prewarm_agent_grid(
		enemy.get_configured_body_collision_half_extents(),
		BASIC_CONFIG.terrain_traversal_types
	)
	game.grid_pathfinder.prewarm_flow_navigation_target(
		nearest_gate.global_position,
		enemy.get_configured_body_collision_half_extents(),
		BASIC_CONFIG.terrain_traversal_types
	)
	_expect(
		enemy.global_position.distance_to(nearest_gate.global_position)
		>= Enemy.FAR_STATIC_OBJECTIVE_DISTANCE,
		"The Home journey fixture must begin in the far linear movement tier."
	)

	game.set_physics_process(false)
	var health_before := game.current_base_health
	for _frame in range(420):
		await physics_frame
		await process_frame
		if not is_instance_valid(enemy) or game.current_base_health < health_before:
			break
	_expect(
		game.current_base_health == health_before - BASIC_CONFIG.home_damage,
		"A far linear enemy must transition through flow navigation and physically reach Home."
	)
	_expect(
		not is_instance_valid(enemy) or enemy.is_dead,
		"The completed far-to-Home journey must resolve the enemy exactly once."
	)
	game.set_physics_process(true)
	game.current_base_health = game.maximum_base_health
	game.base_health_revision = 0
	game.current_wave_escaped = 0
	game.current_wave_resolved = 0
	game.resolved_home_enemy_ids.clear()
	game.call("_update_base_health_display")


func _verify_target_selection(game: GameTowerDefense) -> void:
	var targets := game.get_home_objective_targets()
	if targets.is_empty():
		return
	var logical_tile_width := float(game.ground_tile_map_layer.tile_set.tile_size.x)
	_expect(
		is_equal_approx(
			GameTowerDefense.PLAYER_OBJECTIVE_AGGRO_RADIUS / logical_tile_width,
			GameTowerDefense.PLAYER_OBJECTIVE_AGGRO_RADIUS_CELLS
		),
		"The player aggro radius must equal 16 logical tiles."
	)
	_expect(
		is_equal_approx(
			GameTowerDefense.PLAYER_OBJECTIVE_AGGRO_RADIUS * game.map_camera.zoom.x,
			512.0
		),
		"At tower-defense zoom 2, the player aggro radius must appear as 512 screen pixels."
	)
	var gate := targets[0]
	var near_gate := gate.global_position + Vector2(-2.0, 0.0)
	game.player.global_position = near_gate + Vector2(logical_tile_width * 16.01, 0.0)
	var picked_gate: Node2D = game.call("_pick_enemy_objective", near_gate, game.player) as Node2D
	_expect(picked_gate == gate, "Without a nearby plant or player, enemies must choose Home.")

	game.player.global_position = near_gate + Vector2(logical_tile_width * 16.0, 0.0)
	_expect(
		game.call("_pick_enemy_objective", near_gate, game.player) == game.player,
		"A player exactly 16 tiles away must outrank even a much closer Home gate."
	)

	var boundary_plant := _register_target_probe_plant(
		game,
		near_gate + Vector2(logical_tile_width * 8.0, 0.0)
	)
	var nearer_plant := _register_target_probe_plant(
		game,
		near_gate + Vector2(logical_tile_width * 3.0, 0.0)
	)
	_expect(
		game.call("_pick_enemy_objective", near_gate, game.player) == nearer_plant,
		"The nearest living plant inside eight tiles must be the highest-priority objective."
	)
	nearer_plant.is_dead = true
	_expect(
		game.call("_pick_enemy_objective", near_gate, game.player) == boundary_plant,
		"A dead plant must be ignored and the exact eight-tile boundary must remain inclusive."
	)
	boundary_plant.is_dead = true
	_expect(
		game.call("_pick_enemy_objective", near_gate, game.player) == game.player,
		"The player must become the objective after all nearby plants die."
	)
	game.enemy_retarget_time_left = 1.0
	_release_target_probe_plant(game, nearer_plant)
	_release_target_probe_plant(game, boundary_plant)
	_expect(
		is_zero_approx(game.enemy_retarget_time_left),
		"Removing a plant objective must request a fresh budgeted retarget sweep."
	)

	game.player.global_position = near_gate + Vector2(logical_tile_width * 16.01, 0.0)
	_expect(
		game.call("_pick_enemy_objective", near_gate, game.player) == gate,
		"A player beyond 16 tiles must not pull an enemy away from Home."
	)
	# Leave enough margin for the retarget probe itself, which starts four world
	# pixels to the other side of near_gate.
	game.player.global_position = gate.global_position + Vector2(logical_tile_width * 17.0, 0.0)

	var retarget_enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(retarget_enemy != null, "Basic enemy must instantiate for timed retarget verification.")
	if retarget_enemy == null:
		return
	game.enemy_container.add_child(retarget_enemy)
	retarget_enemy.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	retarget_enemy.set_physics_process(false)
	retarget_enemy.collision_layer = 0
	retarget_enemy.global_position = gate.global_position + Vector2(2.0, 0.0)
	game.enemy_retarget_time_left = 0.0
	game.call("_update_tower_defense_enemy_targets", 0.0)
	_expect(
		retarget_enemy.objective_target == gate,
		"The authoritative retarget loop must move an enemy toward its nearest Home gate."
	)
	_expect(
		is_equal_approx(
			retarget_enemy.near_moving_target_direct_distance,
			GameTowerDefense.PLAYER_OBJECTIVE_AGGRO_RADIUS
		),
		"Tower defense must scope its 16-tile direct-player tier without changing other modes."
	)
	retarget_enemy.global_position = game.player.global_position + Vector2(2.0, 0.0)
	game.call("_update_tower_defense_enemy_targets", 0.1)
	_expect(
		retarget_enemy.objective_target == gate,
		"The retarget loop must retain its objective until the 0.35-second interval expires."
	)
	game.call("_update_tower_defense_enemy_targets", 0.3)
	_expect(
		retarget_enemy.objective_target == game.player,
		"The retarget loop must switch back to a nearer living player after its interval."
	)
	retarget_enemy.cached_navigation_move_direction = Vector2.RIGHT
	retarget_enemy.cached_navigation_uses_direct_objective_approach = true
	retarget_enemy.set_target_player(game.player)
	_expect(
		retarget_enemy.cached_navigation_move_direction == Vector2.RIGHT
		and retarget_enemy.cached_navigation_uses_direct_objective_approach,
		"Reassigning the same combat player must preserve the cached navigation direction."
	)
	retarget_enemy.free()

	_verify_retarget_budget(game, gate)


func _register_target_probe_plant(
	game: GameTowerDefense,
	global_position: Vector2
) -> PlantDefense:
	var plant := PlantDefense.new()
	game.plant_container.add_child(plant)
	plant.global_position = global_position
	var cell := game.ground_tile_map_layer.local_to_map(
		game.ground_tile_map_layer.to_local(global_position)
	)
	var footprint: Array[Vector2i] = [cell]
	game.plant_system.call("_register_plant_footprint", plant, footprint)
	return plant


func _release_target_probe_plant(game: GameTowerDefense, plant: PlantDefense) -> void:
	if plant == null or not is_instance_valid(plant):
		return
	game.plant_system.call("_release_plant_footprint", plant)
	plant.free()


func _verify_retarget_budget(game: GameTowerDefense, gate: Node2D) -> void:
	# Keep the spatial index non-empty while all 300 enemies are outside plant
	# aggro. This exercises the bounded 8-tile query instead of its empty fast path.
	var far_plant := _register_target_probe_plant(
		game,
		gate.global_position + Vector2(512.0, 512.0)
	)
	var enemies: Array[Enemy] = []
	for index in range(RETARGET_STRESS_ENEMY_COUNT):
		var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
		if enemy == null:
			continue
		game.enemy_container.add_child(enemy)
		enemy.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
		enemy.set_physics_process(false)
		enemy.collision_layer = 0
		enemy.global_position = gate.global_position + Vector2(2.0, 0.0)
		enemies.append(enemy)

	game.enemy_retarget_cursor = 0
	game.enemy_retarget_sweep_remaining = 0
	game.enemy_retarget_time_left = 0.0
	var gate_target_count := 0
	var required_budget_frames := ceili(
		float(enemies.size())
		/ float(GameTowerDefense.ENEMY_RETARGET_MAX_PER_PHYSICS_FRAME)
	)
	for _budget_frame in range(required_budget_frames):
		var previous_gate_target_count := gate_target_count
		game.call("_update_tower_defense_enemy_targets", 0.0)
		gate_target_count = 0
		for enemy in enemies:
			if enemy.objective_target == gate:
				gate_target_count += 1
		_expect(
			gate_target_count - previous_gate_target_count
				<= GameTowerDefense.ENEMY_RETARGET_MAX_PER_PHYSICS_FRAME,
			"A 300-enemy retarget sweep must preserve its per-frame budget."
		)
	_expect(
		gate_target_count == enemies.size(),
		"A budgeted 300-enemy retarget sweep must eventually visit every enemy."
	)
	for enemy in enemies:
		enemy.free()
	_release_target_probe_plant(game, far_plant)


func _verify_enemy_contract(game: GameTowerDefense) -> void:
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Basic enemy must instantiate for target-contract verification.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	_expect(enemy.target_player == game.player, "setup() must retain the combat player.")
	_expect(enemy.objective_target == game.player, "setup() must default movement to the player.")
	_expect(enemy.reward_player == game.player, "setup() must default rewards to the player.")
	var gate_targets := game.get_home_objective_targets()
	if not gate_targets.is_empty():
		enemy.set_objective_target(gate_targets[0])
		_expect(not enemy.is_objective_targeting_player(), "A gate objective must be distinct from the combat player.")
	enemy.queue_free()

	var ranged := FIRE_RANGED_CONFIG.enemy_scene.instantiate() as YuanshiInsectFireRanged
	_expect(ranged != null, "Ranged enemy must instantiate for gate-attack verification.")
	if ranged == null:
		return
	game.enemy_container.add_child(ranged)
	ranged.setup(FIRE_RANGED_CONFIG, game.player, game.grid_pathfinder)
	if not gate_targets.is_empty():
		ranged.set_objective_target(gate_targets[0])
		_expect(not bool(ranged.call("_try_start_ranged_attack")), "Ranged enemies must not attack while pursuing a gate.")
	ranged.queue_free()


func _verify_home_damage_resources() -> void:
	for config_name in EXPECTED_HOME_DAMAGE:
		var config_path := "res://resources/config/enemies/%s.tres" % config_name
		var config := load(config_path) as EnemyConfig
		_expect(config != null, "Enemy config must load: %s." % config_path)
		if config != null:
			_expect(
				config.home_damage == int(EXPECTED_HOME_DAMAGE[config_name]),
				"Unexpected home_damage for %s." % config_name
			)

func _verify_escape_resolution(game: GameTowerDefense) -> void:
	var pickup_count_before := _count_reward_nodes(game)
	var enemy := BASIC_CONFIG.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Basic enemy must instantiate for escape verification.")
	if enemy == null:
		return
	game.enemy_container.add_child(enemy)
	enemy.global_position = game.player.global_position
	enemy.setup(BASIC_CONFIG, game.player, game.grid_pathfinder)
	var defeated_state := {"emitted": false}
	enemy.defeated.connect(func(_defeated_enemy: Enemy) -> void: defeated_state["emitted"] = true)

	game.wave_state = GameTowerDefense.WaveState.WAVE_ACTIVE
	game.current_wave_total = 2
	game.current_wave_spawned = 1
	game.current_wave_defeated = 0
	game.current_wave_escaped = 0
	game.current_wave_resolved = 0
	game.active_wave_enemy_ids.clear()
	game.active_wave_enemy_ids[enemy.get_instance_id()] = true
	var health_before := game.current_base_health
	game.call("_on_enemy_reached_home", enemy, Vector2i(2, 22))
	game.call("_on_enemy_reached_home", enemy, Vector2i(3, 22))

	_expect(game.current_base_health == health_before - BASIC_CONFIG.home_damage, "Overlapping gates must damage the base exactly once.")
	_expect(game.current_wave_defeated == 0, "Escaped enemies must not count as defeated.")
	_expect(game.current_wave_escaped == 1, "Escaped enemies must increment escaped once.")
	_expect(game.current_wave_resolved == 1, "Escaped enemies must increment resolved once.")
	_expect(not bool(defeated_state["emitted"]), "Escaped enemies must not emit defeated.")
	_expect(enemy.is_dead and not enemy.visible, "Escaped enemies must disappear immediately.")
	await process_frame
	await process_frame
	_expect(_count_reward_nodes(game) == pickup_count_before, "Escaped enemies must not drop pickups, materials, or Xirang.")

	game.call("_apply_base_damage", game.current_base_health)
	_expect(game.wave_state == GameTowerDefense.WaveState.DEFEAT, "Base health reaching zero must cause defeat.")

	game.current_base_health = game.maximum_base_health
	game.wave_state = GameTowerDefense.WaveState.WAVE_ACTIVE
	game.current_flow_step = null
	game.current_wave_total = 1
	game.current_wave_spawned = 1
	game.current_wave_resolved = 1
	game.pending_enemy_configs.clear()
	game.pending_enemy_config_index = 0
	game.active_wave_enemy_ids.clear()
	game.call("_check_wave_completion")
	_expect(game.wave_state == GameTowerDefense.WaveState.VICTORY, "Wave completion must use resolved, allowing escaped enemies to finish a wave.")


func _count_reward_nodes(node: Node) -> int:
	var count := 1 if node is Pickup or node is XirangDrop else 0
	for child in node.get_children():
		count += _count_reward_nodes(child)
	return count


func _finish() -> void:
	if failures.is_empty():
		print("GAME_TOWER_DEFENSE_HOME_SYSTEM_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
