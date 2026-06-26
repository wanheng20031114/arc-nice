extends SceneTree

const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL2_CONFIG := preload("res://resources/config/bosses/linglan_skill2.tres")
const SKILL3_CONFIG := preload("res://resources/config/bosses/linglan_skill3.tres")
const ORB_SCENE := preload("res://scene/linglan_skill3_light_orb.tscn")
const GAME_SCENE := preload("res://scene/game.tscn")
const MP_GAME_SCENE := preload("res://scene/multiplayer/mp_game.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")


class Skill3Host:
	extends Node2D

	var target_position := Vector2.ZERO
	var requested_target_cells: Array[Vector2i] = []
	var projectile_records: Array[Dictionary] = []

	func get_linglan_skill3_target_global_position(target_cell: Vector2i) -> Vector2:
		requested_target_cells.append(target_cell)
		return target_position

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


var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "LinglanSkill3SmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_skill3_config()
	await _test_skill3_scene_contract()
	await _test_game_target_entry()
	await _test_orb_lifecycle_and_damage()
	await _test_boss_skill3_schedule()
	_test_multiplayer_projectile_instantiation()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("LINGLAN_SKILL3_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_skill3_config() -> void:
	_expect(SKILL3_CONFIG.skill_name == &"linglan_skill3", "Skill3 name mismatch.")
	_expect(SKILL3_CONFIG.target_cell == Vector2i(0, 1), "Skill3 target cell mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.move_speed, 120.0), "Skill3 move speed mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.duration, 10.0), "Skill3 duration mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.fire_interval, 0.25), "Skill3 fire interval mismatch.")
	_expect(SKILL3_CONFIG.get_shot_count() == 40, "Skill3 must fire 40 orbs.")
	_expect(is_equal_approx(SKILL3_CONFIG.direction_min_degrees, 0.0), "Skill3 direction min mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.direction_max_degrees, 90.0), "Skill3 direction max mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_speed, 90.0), "Skill3 orb speed mismatch.")
	_expect(SKILL3_CONFIG.orb_damage == 50, "Skill3 orb damage mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_base_radius, 15.0), "Skill3 orb base radius mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_grow_scale, 3.0), "Skill3 orb grow scale mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_expanded_hold_duration, 0.5), "Skill3 expanded hold mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_flash_lead_time, 2.0), "Skill3 flash lead mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_grow_delay_min, 2.2), "Skill3 grow delay min mismatch.")
	_expect(is_equal_approx(SKILL3_CONFIG.orb_grow_delay_max, 3.6), "Skill3 grow delay max mismatch.")
	_expect(SKILL3_CONFIG.orb_scene == ORB_SCENE, "Skill3 orb scene mismatch.")

	var random_generator := RandomNumberGenerator.new()
	random_generator.seed = 12345
	for _index in range(32):
		var grow_delay := SKILL3_CONFIG.get_random_grow_delay(random_generator)
		_expect(grow_delay >= 2.2 and grow_delay <= 3.6, "Skill3 grow delay must stay inside configured range.")


func _test_skill3_scene_contract() -> void:
	var orb := ORB_SCENE.instantiate() as LinglanSkill3LightOrb
	_expect(orb != null, "Skill3 orb scene must instantiate as LinglanSkill3LightOrb.")
	if orb == null:
		return
	test_root.add_child(orb)
	await process_frame

	_expect(orb.collision_layer == 128, "Skill3 orb must use EnemyProjectile collision layer.")
	_expect(orb.collision_mask == 2, "Skill3 orb must only collide with Player.")
	var shape := orb.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_expect(shape != null and shape.shape is CircleShape2D, "Skill3 orb must expose a circle collision shape.")
	if shape != null and shape.shape is CircleShape2D:
		_expect(is_equal_approx((shape.shape as CircleShape2D).radius, 15.0), "Skill3 orb collision radius must start at 15.")
	var visual_root := orb.get_node_or_null("VisualRoot") as Node2D
	_expect(visual_root != null, "Skill3 orb must have an editable VisualRoot.")
	if visual_root != null:
		for node_name in ["OuterHalo", "MidHalo", "InnerHalo", "Core", "BoundaryGlow", "BoundaryEdge"]:
			var polygon := visual_root.get_node_or_null(node_name) as Polygon2D
			_expect(polygon != null, "Skill3 orb visual missing %s." % node_name)
			_expect(polygon == null or polygon.material is ShaderMaterial, "Skill3 orb %s must use shader glow material." % node_name)
			_expect(polygon == null or polygon.polygon.size() >= 32, "Skill3 orb %s must use a smooth enough circle polygon." % node_name)
		var outer_halo := visual_root.get_node_or_null("OuterHalo") as Polygon2D
		var boundary_edge := visual_root.get_node_or_null("BoundaryEdge") as Polygon2D
		var core := visual_root.get_node_or_null("Core") as Polygon2D
		_expect(outer_halo == null or outer_halo.scale.x >= 30.0, "Skill3 orb outer halo must extend beyond the collision core.")
		_expect(outer_halo == null or outer_halo.scale.x <= 34.0, "Skill3 orb outer halo must stay visually restrained.")
		_expect(boundary_edge == null or is_equal_approx(boundary_edge.scale.x, 15.0), "Skill3 orb boundary edge must match the base collision radius.")
		_expect(core == null or is_equal_approx(core.scale.x, 15.0), "Skill3 orb core must match its 15px base radius.")
		if core != null and core.material is ShaderMaterial:
			var core_material := core.material as ShaderMaterial
			var core_tint: Color = core_material.get_shader_parameter(&"tint")
			_expect(core_tint.a >= 0.5, "Skill3 orb core must be a high-density fill inside the collision radius.")
			_expect(float(core_material.get_shader_parameter(&"inner_radius")) >= 0.75, "Skill3 orb core must keep most of the collision radius densely lit.")
		if outer_halo != null and outer_halo.material is ShaderMaterial:
			var outer_material := outer_halo.material as ShaderMaterial
			var outer_tint: Color = outer_material.get_shader_parameter(&"tint")
			_expect(outer_tint.a >= 0.08, "Skill3 orb outer halo must be visible outside the collision radius.")
	_expect(orb.get_current_radius() == 15.0, "Skill3 orb current radius must start at base radius.")
	orb.queue_free()
	await process_frame


func _test_game_target_entry() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Skill3 target check.")
	if game == null:
		return
	game.auto_start_waves = false
	test_root.add_child(game)
	await process_frame
	await physics_frame
	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var expected_target := ground_layer.to_global(ground_layer.map_to_local(SKILL3_CONFIG.target_cell))
	var actual_target := game.get_linglan_skill3_target_global_position(SKILL3_CONFIG.target_cell)
	_expect(actual_target.is_equal_approx(expected_target), "Game must resolve Skill3 target through GroundTileMapLayer.map_to_local().")
	game.queue_free()
	current_scene = test_root
	await process_frame
	await physics_frame


func _test_orb_lifecycle_and_damage() -> void:
	current_scene = test_root
	var near_player := _spawn_player(test_root, Vector2(4.0, 0.0), 1, 200)
	var orb := ORB_SCENE.instantiate() as LinglanSkill3LightOrb
	test_root.add_child(orb)
	orb.global_position = Vector2.ZERO
	orb.setup(Vector2.RIGHT, 50, 0.0, 2.2)
	await process_frame
	orb.call("_physics_process", 0.016)
	_expect(near_player.current_health == 150, "Small Skill3 orb must deal 50 damage on contact.")
	orb.call("_physics_process", 0.016)
	_expect(near_player.current_health == 150, "Skill3 orb must not damage the same player twice.")
	near_player.queue_free()
	orb.queue_free()
	await process_frame

	var far_player := _spawn_player(test_root, Vector2(30.0, 0.0), 2, 200)
	var enemy_config := BASIC_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	enemy_config.max_health = 200
	enemy_config.physical_defense = 0
	var enemy := enemy_config.enemy_scene.instantiate() as Enemy
	test_root.add_child(enemy)
	enemy.global_position = Vector2(24.0, 18.0)
	enemy.setup(enemy_config, far_player, null)
	enemy.set_physics_process(false)
	var linglan_config := LINGLAN_CONFIG.duplicate(true) as EnemyConfig
	linglan_config.max_health = 500
	linglan_config.physical_defense = 0
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	test_root.add_child(linglan)
	linglan.global_position = Vector2(0.0, 34.0)
	linglan.config = linglan_config
	linglan.activate_boss(far_player, null)
	linglan.set_physics_process(false)
	await _wait_process_and_physics_frames(3)

	var grow_orb := ORB_SCENE.instantiate() as LinglanSkill3LightOrb
	test_root.add_child(grow_orb)
	grow_orb.global_position = Vector2.ZERO
	grow_orb.setup(Vector2.RIGHT, 50, 0.0, 2.2)
	await process_frame
	grow_orb.call("_physics_process", 0.05)
	_expect(not grow_orb.is_flashing(), "Skill3 orb must not flash before grow_delay - flash_lead_time.")
	grow_orb.call("_physics_process", 0.25)
	_expect(grow_orb.is_flashing(), "Skill3 orb must flash during the final two seconds before growth.")
	_expect(far_player.current_health == 200, "Small Skill3 orb must not damage a player outside 15px.")
	grow_orb.call("_grow")
	await physics_frame
	_expect(grow_orb.is_expanded(), "Skill3 orb must enter expanded state.")
	_expect(is_equal_approx(grow_orb.get_current_radius(), 45.0), "Skill3 orb expanded radius must be 45.")
	var grow_shape := grow_orb.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if grow_shape != null and grow_shape.shape is CircleShape2D:
		_expect(is_equal_approx((grow_shape.shape as CircleShape2D).radius, 45.0), "Skill3 orb expanded collision shape must be 45.")
	_expect(is_equal_approx(grow_orb.get_visual_scale().x, 3.0), "Skill3 orb visual expansion must triple at growth.")
	_expect(far_player.current_health == 150, "Expanded Skill3 orb must deal 50 damage.")
	_expect(enemy.current_health == 200, "Skill3 orb must not damage normal enemies.")
	_expect(linglan.current_health == 500, "Skill3 orb must not damage Linglan.")
	grow_orb.call("_physics_process", 0.51)
	await process_frame
	_expect(not is_instance_valid(grow_orb), "Skill3 orb must disappear after expanded hold duration.")

	far_player.queue_free()
	enemy.queue_free()
	linglan.queue_free()
	await process_frame
	await physics_frame


func _test_boss_skill3_schedule() -> void:
	var host := Skill3Host.new()
	host.name = "Skill3Host"
	host.target_position = Vector2.ZERO
	root.add_child(host)
	current_scene = host

	var player := _spawn_player(host, Vector2(240.0, 0.0), 7, 200)
	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene must instantiate for Skill3 schedule.")
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
	boss.boss_skill_phase = LinglanBoss.BossSkillPhase.SKILL2
	boss.skill2_elapsed = SKILL2_CONFIG.get_total_duration()
	boss.skill2_shots_fired = SKILL2_CONFIG.attack_count
	boss.call("_physics_process", 0.016)
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL3, "Skill2 completion must enter MOVE_TO_SKILL3.")
	_expect(host.requested_target_cells == [SKILL3_CONFIG.target_cell], "Skill3 move must request target cell (0,1).")

	var sprite := boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var saw_move_animation := false
	for _step in range(180):
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL3 and sprite != null:
			saw_move_animation = saw_move_animation or sprite.animation == &"move"
		boss.call("_physics_process", 1.0 / 60.0)
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL3:
			break
	_expect(saw_move_animation, "Skill3 movement phase must play Linglan move animation.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL3, "Linglan must enter Skill3 after reaching target.")
	_expect(boss.global_position.distance_to(host.target_position) <= 2.0, "Linglan did not arrive at Skill3 target.")
	if sprite != null:
		_expect(sprite.flip_h, "Leftward Skill3 movement must mirror Linglan move sprite.")

	boss.call("_physics_process", 0.01)
	_expect(host.projectile_records.size() == 1, "Skill3 must fire immediately after attack starts.")
	for _step in range(660):
		boss.call("_physics_process", 1.0 / 60.0)
	_expect(host.projectile_records.size() == 40, "Skill3 must fire exactly 40 orbs.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.DONE, "Skill3 must enter DONE after the 10 second cycle.")
	for record in host.projectile_records:
		var direction: Vector2 = record.get("direction", Vector2.ZERO)
		_expect(record.get("projectile_type") == &"linglan_skill3_orb", "Skill3 registered wrong projectile type.")
		_expect(int(record.get("damage", 0)) == 50, "Skill3 registered wrong orb damage.")
		_expect(is_equal_approx(float(record.get("speed", 0.0)), 90.0), "Skill3 registered wrong orb speed.")
		_expect(float(record.get("lifetime", 0.0)) >= 2.2 and float(record.get("lifetime", 0.0)) <= 3.6, "Skill3 registered grow delay outside range.")
		_expect(direction.length() > 0.99 and direction.x >= -0.001 and direction.y >= -0.001, "Skill3 orb direction must stay in right-to-down quadrant.")

	host.queue_free()
	current_scene = test_root
	await process_frame
	await physics_frame


func _test_multiplayer_projectile_instantiation() -> void:
	var mp_game := MP_GAME_SCENE.instantiate()
	_expect(mp_game != null, "MP game scene must instantiate for Skill3 projectile registry.")
	if mp_game == null:
		return
	var projectile := mp_game.call(
		"_instantiate_projectile",
		&"linglan_skill3_orb",
		999999,
		Vector2.DOWN,
		50,
		90.0,
		2.4,
		false,
		0
	) as LinglanSkill3LightOrb
	_expect(projectile != null, "Multiplayer registry must instantiate linglan_skill3_orb.")
	if projectile != null:
		_expect(projectile.direction.is_equal_approx(Vector2.DOWN), "Registry Skill3 orb direction mismatch.")
		_expect(projectile.damage == 50, "Registry Skill3 orb damage mismatch.")
		_expect(is_equal_approx(projectile.speed, 90.0), "Registry Skill3 orb speed mismatch.")
		_expect(is_equal_approx(projectile.grow_delay, 2.4), "Registry Skill3 orb grow delay mismatch.")
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


func _wait_process_and_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
