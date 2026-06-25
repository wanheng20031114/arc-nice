extends SceneTree

const LINGLAN_SCENE := preload("res://scene/linglan_boss.tscn")
const LINGLAN_CONFIG := preload("res://resources/config/enemies/linglan_boss.tres")
const SKILL2_CONFIG := preload("res://resources/config/bosses/linglan_skill2.tres")
const ROCKET_SCENE := preload("res://scene/linglan_skill2_sakura_rocket.tscn")
const WARNING_ARROW_SCENE := preload("res://scene/linglan_skill2_warning_arrow.tscn")
const EXPLOSION_SCENE := preload("res://scene/linglan_skill2_sakura_explosion.tscn")
const EXPLOSION_FRAMES := preload("res://resources/animation/linglan_skill2_sakura_explosion.tres")
const GAME_SCENE := preload("res://scene/game.tscn")
const PLAYER_SCENE := preload("res://scene/player.tscn")
const BASIC_ENEMY_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const MAGE_FIREBALL_SCENE := preload("res://scene/enemy/capoo_mage_fireball.tscn")


class Skill2Host:
	extends Node2D

	var target_position := Vector2(180.0, -72.0)
	var target_player: Player = null
	var requested_target_cells: Array[Vector2i] = []
	var spawn_marker_calls: Array[StringName] = []
	var projectile_records: Array[Dictionary] = []

	func get_linglan_skill2_target_global_position(target_cell: Vector2i) -> Vector2:
		requested_target_cells.append(target_cell)
		return target_position

	func get_linglan_skill2_target_player(_from_position: Vector2) -> Player:
		return target_player

	func spawn_linglan_skill2_enemies(
		_enemy_config: EnemyConfig,
		marker_names: Array[StringName]
	) -> void:
		for marker_name in marker_names:
			spawn_marker_calls.append(marker_name)

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
	test_root.name = "LinglanSkill2SmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_skill2_config()
	await _test_skill2_scene_contract()
	await _test_game_target_and_spawn_entry()
	await _test_boss_skill2_schedule()
	await _test_rocket_homing_and_explosion_damage()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("LINGLAN_SKILL2_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_skill2_config() -> void:
	_expect(SKILL2_CONFIG.skill_name == &"linglan_skill2", "Skill2 name mismatch.")
	_expect(SKILL2_CONFIG.target_cell == Vector2i(15, 2), "Skill2 target cell mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.move_speed, 120.0), "Skill2 move speed mismatch.")
	_expect(SKILL2_CONFIG.attack_count == 10, "Skill2 attack count mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.attack_interval, 1.0), "Skill2 attack interval mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.warning_lead_time, 0.35), "Skill2 warning lead mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.rocket_speed, 210.0), "Skill2 rocket speed mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.rocket_homing_turn_rate, 1.3), "Skill2 rocket homing mismatch.")
	_expect(SKILL2_CONFIG.rocket_homing_turn_rate > 0.65, "Skill2 rocket homing must stay stronger than mage fireball.")
	_expect(is_equal_approx(SKILL2_CONFIG.rocket_lifetime, 5.0), "Skill2 rocket lifetime mismatch.")
	_expect(SKILL2_CONFIG.rocket_damage == 80, "Skill2 rocket damage mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.rocket_explosion_radius, 82.5), "Skill2 explosion radius mismatch.")
	_expect(SKILL2_CONFIG.rocket_scene == ROCKET_SCENE, "Skill2 rocket scene mismatch.")
	_expect(SKILL2_CONFIG.warning_arrow_scene == WARNING_ARROW_SCENE, "Skill2 warning arrow scene mismatch.")
	_expect(SKILL2_CONFIG.spawn_enemy_config != null, "Skill2 spawn enemy config missing.")
	_expect(SKILL2_CONFIG.spawn_marker_names == [&"Spawn4", &"Spawn5"], "Skill2 spawn marker names mismatch.")
	_expect(is_equal_approx(SKILL2_CONFIG.get_total_duration(), 10.0), "Skill2 total duration mismatch.")


func _test_skill2_scene_contract() -> void:
	var rocket := ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	_expect(rocket != null, "Skill2 rocket scene did not instantiate as LinglanSkill2SakuraRocket.")
	if rocket == null:
		return
	test_root.add_child(rocket)
	await process_frame

	_expect(rocket.collision_layer == 128, "Skill2 rocket collision layer must be EnemyProjectile(128).")
	_expect(rocket.collision_mask == 263, "Skill2 rocket collision mask must hit World/Player/EnemyBody/BossBody.")
	var body_shape := rocket.get_node_or_null("CollisionShape2D") as CollisionShape2D
	_expect(body_shape != null and body_shape.shape is CapsuleShape2D, "Skill2 rocket must expose a capsule hit shape.")
	var explosion_shape := rocket.get_node_or_null("ExplosionShape") as CollisionShape2D
	_expect(explosion_shape != null and explosion_shape.shape is CircleShape2D, "Skill2 rocket must expose an explosion circle shape.")
	if explosion_shape != null and explosion_shape.shape is CircleShape2D:
		var circle := explosion_shape.shape as CircleShape2D
		_expect(is_equal_approx(circle.radius, 82.5), "Skill2 explosion shape radius must be 82.5.")
	rocket.queue_free()

	var warning_arrow := WARNING_ARROW_SCENE.instantiate() as Node2D
	_expect(warning_arrow != null, "Skill2 warning arrow scene did not instantiate.")
	if warning_arrow != null:
		test_root.add_child(warning_arrow)
		await process_frame
		for node_name in ["GlowArrow", "CoreArrow", "HighlightArrow"]:
			_expect(
				warning_arrow.get_node_or_null(node_name) != null,
				"Skill2 warning arrow missing %s." % node_name
			)
		_expect(_count_line_nodes(warning_arrow) == 0, "Skill2 warning must use pink arrow polygons instead of Line2D lines.")
		_expect(_count_collision_nodes(warning_arrow) == 0, "Skill2 warning arrow must not own collision nodes.")
		warning_arrow.queue_free()

	_expect(EXPLOSION_FRAMES.has_animation(&"explode"), "Skill2 explosion animation missing.")
	if EXPLOSION_FRAMES.has_animation(&"explode"):
		_expect(EXPLOSION_FRAMES.get_frame_count(&"explode") == 16, "Skill2 explosion must keep 16 frames.")
		_expect(not EXPLOSION_FRAMES.get_animation_loop(&"explode"), "Skill2 explosion animation must not loop.")

	var explosion := EXPLOSION_SCENE.instantiate() as Node2D
	_expect(explosion != null, "Skill2 explosion scene did not instantiate.")
	if explosion != null:
		test_root.add_child(explosion)
		await process_frame
		var sprite := explosion.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		_expect(sprite != null and sprite.sprite_frames == EXPLOSION_FRAMES, "Skill2 explosion scene must use generated SpriteFrames.")
		if sprite != null:
			_expect(is_equal_approx(sprite.scale.x, 0.75), "Skill2 explosion visual scale must shrink with the damage radius.")
		explosion.queue_free()


func _test_game_target_and_spawn_entry() -> void:
	var game := GAME_SCENE.instantiate() as Game
	_expect(game != null, "Game scene must instantiate for Skill2 target/spawn checks.")
	if game == null:
		return
	game.auto_start_waves = false
	test_root.add_child(game)
	await process_frame
	await physics_frame

	var ground_layer := game.get_node("GroundTileMapLayer") as TileMapLayer
	var expected_target := ground_layer.to_global(ground_layer.map_to_local(SKILL2_CONFIG.target_cell))
	var actual_target := game.get_linglan_skill2_target_global_position(SKILL2_CONFIG.target_cell)
	_expect(actual_target.is_equal_approx(expected_target), "Game must resolve Skill2 target through GroundTileMapLayer.map_to_local().")

	var spawn4 := game.get_node("EnemySpawnPoints/Spawn4") as Marker2D
	var spawn5 := game.get_node("EnemySpawnPoints/Spawn5") as Marker2D
	var enemy_count_before := _count_enemy_children(game.enemy_container)
	game.spawn_linglan_skill2_enemies(SKILL2_CONFIG.spawn_enemy_config, SKILL2_CONFIG.spawn_marker_names)
	var spawned_positions := _get_enemy_positions_after_index(game.enemy_container, enemy_count_before)
	_expect(spawned_positions.size() == 2, "Skill2 Game spawn entry must create exactly two boss adds.")
	_expect(_positions_include(spawned_positions, spawn4.global_position), "Skill2 Game spawn entry must use Spawn4.")
	_expect(_positions_include(spawned_positions, spawn5.global_position), "Skill2 Game spawn entry must use Spawn5.")
	_expect(game.active_wave_enemy_ids.is_empty(), "Skill2 boss adds must not enter normal wave counters.")

	game.queue_free()
	current_scene = test_root
	await process_frame
	await physics_frame


func _test_boss_skill2_schedule() -> void:
	var host := Skill2Host.new()
	host.name = "Skill2Host"
	root.add_child(host)
	current_scene = host

	var player := _spawn_player(host, Vector2(260.0, -80.0), 7, 200)
	host.target_player = player

	var boss := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(boss != null, "Linglan scene must instantiate for Skill2 schedule.")
	if boss == null:
		host.queue_free()
		current_scene = test_root
		return
	host.add_child(boss)
	await process_frame
	await physics_frame
	boss.global_position = Vector2.ZERO
	boss.config = LINGLAN_CONFIG
	boss.activate_boss(player, null)

	boss.skill1_finished = true
	boss.boss_skill_phase = LinglanBoss.BossSkillPhase.SKILL1
	boss.call("_physics_process", 0.016)
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL2, "Skill1 completion must enter MOVE_TO_SKILL2.")
	_expect(host.requested_target_cells == [SKILL2_CONFIG.target_cell], "Skill2 move must request target cell (15,2).")

	var sprite := boss.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var saw_move_animation := false
	for _step in range(180):
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.MOVE_TO_SKILL2 and sprite != null:
			saw_move_animation = saw_move_animation or sprite.animation == &"move"
		boss.call("_physics_process", 1.0 / 60.0)
		if boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL2:
			break
	_expect(saw_move_animation, "Skill2 movement phase must play Linglan move animation.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.SKILL2, "Linglan must enter Skill2 after reaching target.")
	_expect(boss.global_position.distance_to(host.target_position) <= 2.0, "Linglan did not arrive at Skill2 target.")
	if sprite != null:
		_expect(not sprite.flip_h, "Rightward Skill2 movement must keep normal facing.")
		boss.call("_set_facing_from_direction", Vector2.LEFT)
		_expect(sprite.flip_h, "Leftward Linglan movement must mirror the move sprite like other enemies.")
		boss.call("_set_facing_from_direction", Vector2.RIGHT)
		_expect(not sprite.flip_h, "Linglan facing must restore after turning right.")

	boss.call("_physics_process", 0.01)
	_expect(host.spawn_marker_calls.size() == 2, "Skill2 must request Spawn4 and Spawn5 immediately at attack start.")
	_expect(host.spawn_marker_calls.slice(0, 2) == [&"Spawn4", &"Spawn5"], "Skill2 first spawn request must target Spawn4/Spawn5.")
	_expect(_count_skill2_warning_arrows(host) == 1, "Skill2 must show warning arrow before the first rocket.")
	_expect(host.projectile_records.is_empty(), "Skill2 must not fire before warning lead time.")

	for _step in range(660):
		boss.call("_physics_process", 1.0 / 60.0)

	_expect(host.projectile_records.size() == 10, "Skill2 must fire exactly 10 rockets.")
	_expect(host.spawn_marker_calls.size() == 20, "Skill2 must request 20 total boss add spawns.")
	_expect(boss.boss_skill_phase == LinglanBoss.BossSkillPhase.DONE, "Skill2 must enter DONE after the 10 second cycle.")
	for record in host.projectile_records:
		_expect(record.get("projectile_type") == &"linglan_skill2_rocket", "Skill2 registered wrong projectile type.")
		_expect(int(record.get("damage", 0)) == 80, "Skill2 registered wrong rocket damage.")
		_expect(is_equal_approx(float(record.get("speed", 0.0)), 210.0), "Skill2 registered wrong rocket speed.")
		_expect(int(record.get("target_peer_id", 0)) == 7, "Skill2 rocket must register target peer id.")

	host.queue_free()
	current_scene = test_root
	await process_frame
	await physics_frame


func _test_rocket_homing_and_explosion_damage() -> void:
	current_scene = test_root
	var homing_target := _spawn_player(test_root, Vector2(0.0, 120.0), 1, 200)
	var rocket := ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	var fireball := MAGE_FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(rocket)
	test_root.add_child(fireball)
	await process_frame
	rocket.global_position = Vector2.ZERO
	fireball.global_position = Vector2.ZERO
	rocket.setup(Vector2.RIGHT, 80, 210.0, 5.0, 82.5, homing_target, SKILL2_CONFIG.rocket_homing_turn_rate)
	fireball.setup(Vector2.RIGHT, 1, 155.0, 4.0, 10.5, homing_target, fireball.homing_turn_rate)
	rocket.call("_update_homing", 0.25)
	fireball.call("_update_homing", 0.25)
	_expect(
		absf(rocket.direction.angle()) > absf(fireball.direction.angle()) + 0.05,
		"Skill2 rocket homing must turn more strongly than mage fireball."
	)
	rocket.queue_free()
	fireball.queue_free()
	homing_target.queue_free()
	await process_frame

	var player := _spawn_player(test_root, Vector2(24.0, 0.0), 2, 200)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	var test_enemy_config := BASIC_ENEMY_CONFIG.duplicate(true) as EnemyConfig
	test_enemy_config.max_health = 200
	test_enemy_config.physical_defense = 0
	var enemy := test_enemy_config.enemy_scene.instantiate() as Enemy
	_expect(enemy != null, "Basic enemy scene must instantiate for Skill2 explosion damage.")
	if enemy == null:
		player.queue_free()
		return
	test_root.add_child(enemy)
	enemy.global_position = Vector2(48.0, 0.0)
	enemy.setup(test_enemy_config, player, null)

	var linglan_config := LINGLAN_CONFIG.duplicate(true) as EnemyConfig
	linglan_config.max_health = 500
	linglan_config.physical_defense = 0
	var linglan := LINGLAN_SCENE.instantiate() as LinglanBoss
	_expect(linglan != null, "Linglan scene must instantiate for self-damage check.")
	if linglan == null:
		player.queue_free()
		enemy.queue_free()
		return
	test_root.add_child(linglan)
	linglan.global_position = Vector2(72.0, 0.0)
	linglan.config = linglan_config
	linglan.activate_boss(player, null)
	linglan.set_physics_process(false)
	await _wait_process_and_physics_frames(3)
	for shape_node in linglan.body_collision_shapes:
		if shape_node != null:
			_expect(not shape_node.disabled, "Linglan body collision must be enabled before Skill2 explosion query.")

	var explosion_rocket := ROCKET_SCENE.instantiate() as LinglanSkill2SakuraRocket
	test_root.add_child(explosion_rocket)
	explosion_rocket.global_position = Vector2.ZERO
	explosion_rocket.setup(Vector2.RIGHT, 80, 210.0, 5.0, 82.5, player, SKILL2_CONFIG.rocket_homing_turn_rate)
	explosion_rocket.call("_explode")
	await process_frame

	_expect(player.current_health == 120, "Skill2 explosion must deal 80 damage to the player.")
	_expect(enemy.current_health == 120, "Skill2 explosion must deal 80 damage to normal enemies.")
	_expect(
		linglan.current_health == 420,
		"Skill2 explosion must also damage Linglan, health is %d." % linglan.current_health
	)
	_expect(_count_skill2_explosions(test_root) == 1, "Skill2 rocket must spawn one explosion effect.")
	_clear_skill2_explosions(test_root)

	player.queue_free()
	enemy.queue_free()
	linglan.queue_free()
	await process_frame
	await physics_frame


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


func _count_collision_nodes(node: Node) -> int:
	var count := 0
	if node is CollisionObject2D or node is CollisionShape2D:
		count += 1
	for child in node.get_children():
		count += _count_collision_nodes(child)
	return count


func _count_line_nodes(node: Node) -> int:
	var count := 0
	if node is Line2D:
		count += 1
	for child in node.get_children():
		count += _count_line_nodes(child)
	return count


func _count_enemy_children(container: Node) -> int:
	var count := 0
	for child in container.get_children():
		if child is Enemy:
			count += 1
	return count


func _get_enemy_positions_after_index(container: Node, enemy_start_index: int) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	var enemy_index := 0
	for child in container.get_children():
		var enemy := child as Enemy
		if enemy == null:
			continue
		if enemy_index >= enemy_start_index:
			positions.append(enemy.global_position)
		enemy_index += 1
	return positions


func _positions_include(positions: Array[Vector2], target_position: Vector2) -> bool:
	for position in positions:
		if position.distance_to(target_position) <= 0.01:
			return true
	return false


func _wait_process_and_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await process_frame
		await physics_frame


func _count_skill2_warning_arrows(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child.name.begins_with("LinglanSkill2WarningArrow"):
			count += 1
	return count


func _count_skill2_explosions(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child.get_script() == preload("res://scene/linglan_skill2_sakura_explosion.gd"):
			count += 1
	return count


func _clear_skill2_explosions(parent: Node) -> void:
	for child in parent.get_children():
		if child.get_script() == preload("res://scene/linglan_skill2_sakura_explosion.gd"):
			child.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
