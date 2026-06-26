extends SceneTree

const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL3_CONFIG := preload("res://resources/config/bosses/linglan_skill3.tres")
const SKILL4_CONFIG := preload("res://resources/config/bosses/linglan_skill4.tres")
const LASER_FIELD_SCENE := preload("res://scene/linglan_skill4_laser_field.tscn")
const ORB_SCENE := preload("res://scene/linglan_skill4_light_orb.tscn")
const LASER_FIELD_SCRIPT := preload("res://scene/linglan_skill4_laser_field.gd")
const ORB_SCRIPT := preload("res://scene/linglan_skill4_light_orb.gd")
const GAME_SCENE := preload("res://scene/game.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")


class Skill4Host:
	extends Node2D

	var target_position := Vector2(104.0, 32.0)
	var requested_target_cells: Array[Array] = []
	var laser_bounds_calls: Array[Array] = []
	var orb_spawn_calls: Array[Dictionary] = []
	var projectile_records: Array[Dictionary] = []
	var action_records: Array[Dictionary] = []
	var laser_bounds := {
		"start_min": Vector2(-48.0, -16.0),
		"start_max": Vector2(288.0, 256.0),
		"final_min": Vector2(32.0, 64.0),
		"final_max": Vector2(208.0, 176.0),
	}

	func get_linglan_skill4_target_global_position(
		target_cell_a: Vector2i,
		target_cell_b: Vector2i
	) -> Vector2:
		requested_target_cells.append([target_cell_a, target_cell_b])
		return target_position

	func get_linglan_skill4_laser_bounds(
		left_cell_x: int,
		right_cell_x: int,
		top_cell_y: int,
		bottom_cell_y: int,
		inward_cell_distance: int
	) -> Dictionary:
		laser_bounds_calls.append([
			left_cell_x,
			right_cell_x,
			top_cell_y,
			bottom_cell_y,
			inward_cell_distance,
		])
		return laser_bounds

	func get_linglan_skill4_orb_spawn_global_position(x_cell: int, y_cell: int) -> Vector2:
		orb_spawn_calls.append({"x_cell": x_cell, "y_cell": y_cell})
		return Vector2(float(x_cell) * 16.0, float(y_cell) * 16.0)

	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		pierces_enemies: bool = false,
		target_peer_id: int = 0
	) -> void:
		projectile_records.append({
			"projectile": projectile,
			"projectile_type": projectile_type,
			"owner_peer_id": owner_peer_id,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
			"pierces_enemies": pierces_enemies,
			"target_peer_id": target_peer_id,
		})

	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		action_records.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"action_position": action_position,
			"action_id": action_id,
		})


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LinglanSkill4SmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_skill4_config()
	await _test_skill4_scene_contract()
	await _test_laser_and_orb_damage()
	await _test_game_helpers()
	await _test_boss_skill4_schedule()
	_test_multiplayer_projectile_instantiation()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("LINGLAN_SKILL4_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_skill4_config() -> void:
	_expect(SKILL4_CONFIG.skill_name == &"linglan_skill4", "Skill4 name mismatch.")
	_expect(SKILL4_CONFIG.target_cell_a == Vector2i(6, 2), "Skill4 target cell A mismatch.")
	_expect(SKILL4_CONFIG.target_cell_b == Vector2i(7, 2), "Skill4 target cell B mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.move_speed, 120.0), "Skill4 move speed mismatch.")
	_expect(SKILL4_CONFIG.laser_start_left_cell_x == -3, "Skill4 left laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_start_right_cell_x == 18, "Skill4 right laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_start_top_cell_y == -1, "Skill4 top laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_start_bottom_cell_y == 16, "Skill4 bottom laser cell mismatch.")
	_expect(SKILL4_CONFIG.laser_inward_cell_distance == 5, "Skill4 inward distance mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.laser_warning_duration, 1.0), "Skill4 laser warning duration mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.laser_shrink_duration, 3.0), "Skill4 laser shrink duration mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_start_delay_after_laser, 0.5), "Skill4 orb delay mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.laser_core_width, 6.0), "Skill4 laser core width mismatch.")
	_expect(SKILL4_CONFIG.laser_damage == 50, "Skill4 laser damage mismatch.")
	_expect(SKILL4_CONFIG.orb_candidate_min_y == 0, "Skill4 orb min row mismatch.")
	_expect(SKILL4_CONFIG.orb_candidate_max_y == 15, "Skill4 orb max row mismatch.")
	_expect(SKILL4_CONFIG.orb_count_per_side == 12, "Skill4 orb count mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_spawn_interval, 2.0), "Skill4 orb interval mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_spawn_duration, 14.0), "Skill4 orb duration mismatch.")
	_expect(SKILL4_CONFIG.get_orb_wave_count() == 7, "Skill4 must spawn seven orb waves.")
	_expect(is_equal_approx(SKILL4_CONFIG.get_orb_start_time(), 4.5), "Skill4 orb phase start mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.get_total_duration(), 18.5), "Skill4 total duration mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_speed, 40.0), "Skill4 orb speed mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_lifetime, 10.0), "Skill4 orb lifetime mismatch.")
	_expect(SKILL4_CONFIG.orb_damage == 50, "Skill4 orb damage mismatch.")
	_expect(is_equal_approx(SKILL4_CONFIG.orb_radius, 8.0), "Skill4 orb radius mismatch.")
	_expect(SKILL4_CONFIG.laser_field_scene == LASER_FIELD_SCENE, "Skill4 laser scene mismatch.")
	_expect(SKILL4_CONFIG.orb_scene == ORB_SCENE, "Skill4 orb scene mismatch.")

	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = 2468
	var rows := SKILL4_CONFIG.get_random_orb_rows(random_generator)
	_expect(rows.size() == 12, "Skill4 must pick 12 orb rows.")
	var seen_rows: Dictionary = {}
	for row in rows:
		_expect(row >= 0 and row <= 15, "Skill4 picked an orb row outside 0..15.")
		_expect(not seen_rows.has(row), "Skill4 picked a duplicate orb row.")
		seen_rows[row] = true


func _test_skill4_scene_contract() -> void:
	var field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	_expect(field != null, "Skill4 laser field scene must instantiate.")
	if field == null:
		return
	test_root.add_child(field)
	field.setup(
		Vector2(-48.0, -16.0),
		Vector2(288.0, 256.0),
		Vector2(32.0, 64.0),
		Vector2(208.0, 176.0),
		50,
		6.0,
		3.0
	)
	field.set_physics_process(false)
	await process_frame
	_expect(field.collision_layer == 128, "Skill4 laser must use EnemyProjectile collision layer.")
	_expect(field.collision_mask == 2, "Skill4 laser must only collide with Player.")
	_expect(is_equal_approx(field.get_laser_progress(), 0.0), "Skill4 laser progress must start at zero.")
	_expect(field.is_warning_active(), "Skill4 laser must start in warning mode.")
	var top_shape := field.get_node_or_null("TopShape") as CollisionShape2D
	var left_shape := field.get_node_or_null("LeftShape") as CollisionShape2D
	_expect(top_shape != null and top_shape.shape is RectangleShape2D, "Skill4 top laser must use a rectangle core.")
	_expect(left_shape != null and left_shape.shape is RectangleShape2D, "Skill4 left laser must use a rectangle core.")
	if top_shape != null and top_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((top_shape.shape as RectangleShape2D).size.y, 1.5), "Skill4 warning horizontal laser core must be thin.")
	if left_shape != null and left_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((left_shape.shape as RectangleShape2D).size.x, 1.5), "Skill4 warning vertical laser core must be thin.")
	for node_name in ["TopGlow", "TopCore", "TopCenter", "LeftGlow", "LeftCore", "LeftCenter"]:
		var line := field.get_node_or_null("VisualRoot/%s" % node_name) as Line2D
		_expect(line != null, "Skill4 laser visual missing %s." % node_name)
		if node_name.ends_with("Core") and line != null:
			_expect(line.width < 6.0, "Skill4 warning core visual must be thinner than active laser.")
	field.call("_physics_process", 0.5)
	var warning_bounds := field.get_current_bounds()
	_expect(warning_bounds.position.is_equal_approx(Vector2(-48.0, -16.0)), "Skill4 warning min bounds must stay at start.")
	_expect(warning_bounds.end.is_equal_approx(Vector2(288.0, 256.0)), "Skill4 warning max bounds must stay at start.")
	field.call("_physics_process", 0.5)
	_expect(not field.is_warning_active(), "Skill4 laser warning must end before shrink starts.")
	if top_shape != null and top_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((top_shape.shape as RectangleShape2D).size.y, 6.0), "Skill4 active horizontal laser core must be 6px high.")
	if left_shape != null and left_shape.shape is RectangleShape2D:
		_expect(is_equal_approx((left_shape.shape as RectangleShape2D).size.x, 6.0), "Skill4 active vertical laser core must be 6px wide.")
	field.call("_physics_process", 1.5)
	var mid_bounds := field.get_current_bounds()
	_expect(mid_bounds.position.is_equal_approx(Vector2(-8.0, 24.0)), "Skill4 laser midpoint min bounds mismatch.")
	_expect(mid_bounds.end.is_equal_approx(Vector2(248.0, 216.0)), "Skill4 laser midpoint max bounds mismatch.")
	field.call("_physics_process", 1.5)
	var final_bounds := field.get_current_bounds()
	_expect(final_bounds.position.is_equal_approx(Vector2(32.0, 64.0)), "Skill4 laser final min bounds mismatch.")
	_expect(final_bounds.end.is_equal_approx(Vector2(208.0, 176.0)), "Skill4 laser final max bounds mismatch.")
	field.setup_multiplayer_visual_only()
	_expect(field.collision_layer == 0 and field.collision_mask == 0, "Skill4 proxy laser must disable collision layers.")
	if top_shape != null:
		_expect(top_shape.disabled, "Skill4 proxy laser must disable shape collision.")
	field.queue_free()
	await physics_frame

	var orb := ORB_SCENE.instantiate() as ORB_SCRIPT
	_expect(orb != null, "Skill4 orb scene must instantiate.")
	if orb != null:
		test_root.add_child(orb)
		await process_frame
		_expect(orb.collision_layer == 128, "Skill4 orb must use EnemyProjectile collision layer.")
		_expect(orb.collision_mask == 2, "Skill4 orb must only collide with Player.")
		var orb_shape := orb.get_node_or_null("CollisionShape2D") as CollisionShape2D
		_expect(orb_shape != null and orb_shape.shape is CircleShape2D, "Skill4 orb must expose a circle collision shape.")
		if orb_shape != null and orb_shape.shape is CircleShape2D:
			_expect(is_equal_approx((orb_shape.shape as CircleShape2D).radius, 8.0), "Skill4 orb collision radius must start at 8.")
		var core := orb.get_node_or_null("VisualRoot/Core") as Polygon2D
		_expect(core != null and core.material is ShaderMaterial, "Skill4 orb core must use shader glow material.")
		orb.queue_free()
	await process_frame
	await physics_frame


func _test_laser_and_orb_damage() -> void:
	current_scene = test_root
	var laser_player := _spawn_player(test_root, Vector2(0.0, -16.0), 1, 200)
	var field := LASER_FIELD_SCENE.instantiate() as LASER_FIELD_SCRIPT
	test_root.add_child(field)
	field.setup(
		Vector2(-48.0, -16.0),
		Vector2(288.0, 256.0),
		Vector2(32.0, 64.0),
		Vector2(208.0, 176.0),
		50,
		6.0,
		3.0
	)
	field.set_physics_process(false)
	await process_frame
	await physics_frame
	field.call("_physics_process", 0.5)
	_expect(
		laser_player.current_health == 200,
		"Skill4 laser warning must not deal damage, health=%d." % laser_player.current_health
	)
	field.call("_physics_process", 0.5)
	field.call("_physics_process", 0.016)
	_expect(
		laser_player.current_health == 150,
		"Skill4 laser must deal 50 damage on core overlap, health=%d." % laser_player.current_health
	)
	field.call("_physics_process", 0.016)
	_expect(
		laser_player.current_health == 150,
		"Skill4 laser must not damage the same player twice, health=%d." % laser_player.current_health
	)
	field.queue_free()
	laser_player.queue_free()
	await process_frame

	var orb_player := _spawn_player(test_root, Vector2(4.0, 0.0), 2, 200)
	var orb := ORB_SCENE.instantiate() as ORB_SCRIPT
	test_root.add_child(orb)
	orb.global_position = Vector2.ZERO
	orb.setup(Vector2.RIGHT, 50, 0.0, 10.0, 8.0)
	await physics_frame
	orb.call("_physics_process", 0.016)
	_expect(orb_player.current_health == 150, "Skill4 orb must deal 50 damage inside 8px radius.")
	orb.call("_physics_process", 0.016)
	_expect(orb_player.current_health == 150, "Skill4 orb must not damage the same player twice.")
	orb.queue_free()
	orb_player.queue_free()
	await process_frame

	var moving_orb := ORB_SCENE.instantiate() as ORB_SCRIPT
	test_root.add_child(moving_orb)
	moving_orb.global_position = Vector2.ZERO
	moving_orb.setup(Vector2.LEFT, 1, 40.0, 10.0, 8.0)
	moving_orb.call("_physics_process", 0.5)
	_expect(moving_orb.global_position.is_equal_approx(Vector2(-20.0, 0.0)), "Skill4 orb must move at configured speed.")
	moving_orb.queue_free()
	await process_frame


func _test_game_helpers() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Skill4 helper checks.")
	if game == null:
		return
	game.auto_start_waves = false
	test_root.add_child(game)
	await process_frame
	await physics_frame
	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var expected_target := (
		ground_layer.to_global(ground_layer.map_to_local(SKILL4_CONFIG.target_cell_a))
		+ ground_layer.to_global(ground_layer.map_to_local(SKILL4_CONFIG.target_cell_b))
	) * 0.5
	var actual_target := game.get_linglan_skill4_target_global_position(
		SKILL4_CONFIG.target_cell_a,
		SKILL4_CONFIG.target_cell_b
	)
	_expect(actual_target.is_equal_approx(expected_target), "Game must resolve Skill4 midpoint through map_to_local().")
	var bounds := game.get_linglan_skill4_laser_bounds(-3, 18, -1, 16, 5)
	_expect(
		(bounds.get("start_min") as Vector2).is_equal_approx(ground_layer.to_global(ground_layer.map_to_local(Vector2i(-3, -1)))),
		"Game Skill4 start min bounds mismatch."
	)
	_expect(
		(bounds.get("final_max") as Vector2).is_equal_approx(ground_layer.to_global(ground_layer.map_to_local(Vector2i(13, 11)))),
		"Game Skill4 final max bounds mismatch."
	)
	var orb_position := game.get_linglan_skill4_orb_spawn_global_position(-3, 7)
	_expect(
		orb_position.is_equal_approx(ground_layer.to_global(ground_layer.map_to_local(Vector2i(-3, 7)))),
		"Game Skill4 orb spawn position must use cell center."
	)
	game.queue_free()
	current_scene = test_root
	await process_frame
	await physics_frame


func _test_boss_skill4_schedule() -> void:
	var host := Skill4Host.new()
	host.name = "Skill4Host"
	root.add_child(host)
	current_scene = host

	var player := _spawn_player(host, Vector2(240.0, 0.0), 7, 200)
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene must instantiate for Skill4 schedule.")
	if boss == null:
		host.queue_free()
		current_scene = test_root
		return
	host.add_child(boss)
	await process_frame
	await physics_frame
	boss.global_position = Vector2(180.0, -72.0)
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(player, null)
	boss.boss_skill_phase = LinglanBoss.BossSkillPhase.SKILL3
	boss.skill3_elapsed = SKILL3_CONFIG.duration
	boss.skill3_shots_fired = SKILL3_CONFIG.get_shot_count()
	boss.call("_physics_process", 0.016)
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL4, "Skill3 completion must enter MOVE_TO_SKILL4.")
	_expect(
		host.requested_target_cells == [[SKILL4_CONFIG.target_cell_a, SKILL4_CONFIG.target_cell_b]],
		"Skill4 move must request target cells (6,2)/(7,2)."
	)

	var sprite := boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var saw_move_animation := false
	for _step in range(180):
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL4 and sprite != null:
			saw_move_animation = saw_move_animation or sprite.animation == &"move"
		boss.call("_physics_process", 1.0 / 60.0)
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL4:
			break
	_expect(saw_move_animation, "Skill4 movement phase must play Linglan move animation.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL4, "Linglan must enter Skill4 after reaching target.")
	_expect(boss.global_position.distance_to(host.target_position) <= 2.0, "Linglan did not arrive at Skill4 target.")
	_expect(host.laser_bounds_calls.size() == 1, "Skill4 must request laser bounds once at attack start.")
	_expect(_count_skill4_laser_fields(host) == 1, "Skill4 must spawn one laser field at attack start.")
	_expect(host.action_records.size() == 1, "Skill4 must broadcast one start action.")
	if sprite != null:
		_expect(sprite.animation == &"attack", "Skill4 attack phase must play Linglan attack animation.")

	boss.call("_physics_process", 4.49)
	_expect(host.projectile_records.is_empty(), "Skill4 must wait for warning, shrink, and 0.5s before orb waves.")
	boss.call("_physics_process", 0.02)
	_expect(host.projectile_records.size() == 24, "Skill4 first wave must spawn 12 orbs per side.")
	_expect(_first_wave_rows_are_unique_per_side(host), "Skill4 first wave rows must be unique per side.")
	for _step in range(900):
		boss.call("_physics_process", 1.0 / 60.0)
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.DONE:
			break
	_expect(host.projectile_records.size() == 168, "Skill4 must spawn exactly seven two-sided waves.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.DONE, "Skill4 must enter DONE after its 18.5s cycle.")
	_expect(boss.skill4_laser_field == null, "Skill4 must clear the laser field when the skill ends.")
	for record in host.projectile_records:
		_expect(record.get("projectile_type") == &"linglan_skill4_orb", "Skill4 registered wrong projectile type.")
		_expect(int(record.get("damage", 0)) == 50, "Skill4 registered wrong orb damage.")
		_expect(is_equal_approx(float(record.get("speed", 0.0)), 40.0), "Skill4 registered wrong orb speed.")
		_expect(is_equal_approx(float(record.get("lifetime", 0.0)), 10.0), "Skill4 registered wrong orb lifetime.")

	host.queue_free()
	current_scene = test_root
	await process_frame
	await physics_frame


func _test_multiplayer_projectile_instantiation() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MP game scene must instantiate for Skill4 projectile registry.")
	if mp_game == null:
		return
	var projectile := mp_game.call(
		"_instantiate_projectile",
		&"linglan_skill4_orb",
		999999,
		Vector2.LEFT,
		50,
		40.0,
		10.0,
		false,
		0
	) as ORB_SCRIPT
	_expect(projectile != null, "Multiplayer registry must instantiate linglan_skill4_orb.")
	if projectile != null:
		_expect(projectile.direction.is_equal_approx(Vector2.LEFT), "Registry Skill4 orb direction mismatch.")
		_expect(projectile.damage == 50, "Registry Skill4 orb damage mismatch.")
		_expect(is_equal_approx(projectile.speed, 40.0), "Registry Skill4 orb speed mismatch.")
		_expect(is_equal_approx(projectile.remaining_lifetime, 10.0), "Registry Skill4 orb lifetime mismatch.")
		_expect(is_equal_approx(projectile.orb_radius, 8.0), "Registry Skill4 orb radius mismatch.")
		projectile.free()
	mp_game.free()


func _spawn_player(parent: Node, position: Vector2, peer_id: int, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	parent.add_child(player)
	player.global_position = position
	player.peer_id = peer_id
	player.max_health = health
	player.current_health = health
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	if player.health_bar != null:
		player.health_bar.setup(player.max_health, player.current_health)
	return player


func _count_skill4_laser_fields(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child.get_script() == LASER_FIELD_SCRIPT:
			count += 1
	return count


func _first_wave_rows_are_unique_per_side(host: Skill4Host) -> bool:
	if host.orb_spawn_calls.size() < 24:
		return false
	var left_rows: Dictionary = {}
	var right_rows: Dictionary = {}
	for index in range(24):
		var call := host.orb_spawn_calls[index]
		var x_cell := int(call.get("x_cell", 0))
		var y_cell := int(call.get("y_cell", -999))
		if x_cell == SKILL4_CONFIG.laser_start_left_cell_x:
			if left_rows.has(y_cell):
				return false
			left_rows[y_cell] = true
		elif x_cell == SKILL4_CONFIG.laser_start_right_cell_x:
			if right_rows.has(y_cell):
				return false
			right_rows[y_cell] = true
	return left_rows.size() == 12 and right_rows.size() == 12


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
