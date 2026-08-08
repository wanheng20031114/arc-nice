extends SceneTree

const ROBOT_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot.tscn"
)
const ROBOT_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const AGAVE_SCENE := preload(
	"res://scene/plant_defense/agave_cannon.tscn"
)
const AGAVE_CONFIG := preload(
	"res://resources/config/plant_defense/agave_cannon.tres"
)
const WORLD_COLLISION_LAYER := 1
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11

class EnemyActionRecorder extends MultiplayerGameplayGateway:
	var enemy_actions: Array[Dictionary] = []

	func broadcast_enemy_action(
		net_id: int,
		action_name: StringName,
		direction: Vector2,
		action_position: Vector2,
		action_id: int
	) -> void:
		enemy_actions.append({
			"net_id": net_id,
			"action_name": action_name,
			"direction": direction,
			"action_position": action_position,
			"action_id": action_id,
		})

var failures: Array[String] = []
var test_root: EnemyActionRecorder


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = EnemyActionRecorder.new()
	test_root.name = "CombatRobotSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_and_scene_contract()
	await _test_target_lock_contract()
	await _test_player_plant_only_target_contract()
	await _test_dash_duration_speed_and_player_passthrough()
	await _test_dash_stops_on_collision_layer(
		WORLD_COLLISION_LAYER,
		"World"
	)
	await _test_dash_stops_on_collision_layer(
		WATER_TERRAIN_COLLISION_LAYER,
		"WaterTerrain"
	)
	await _test_authoritative_action_broadcast_contract()
	await _test_proxy_action_contract()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		ROBOT_CONFIG is CombatRobotConfig,
		"Combat robot must use CombatRobotConfig."
	)
	_expect(ROBOT_CONFIG.display_name == "战斗机器人", "Display name mismatch.")
	_expect(ROBOT_CONFIG.enemy_scene == ROBOT_SCENE, "Enemy scene binding mismatch.")
	_expect(ROBOT_CONFIG.max_health == 180, "Maximum health must be 180.")
	_expect(ROBOT_CONFIG.attack_damage == 35, "Attack damage must be 35.")
	_expect(ROBOT_CONFIG.physical_defense == 15, "Physical defense must be 15.")
	_expect(ROBOT_CONFIG.magic_defense == 20, "Magic defense must be 20.")
	_expect(is_equal_approx(ROBOT_CONFIG.move_speed, 30.0), "Move speed must be 30.")
	_expect(ROBOT_CONFIG.home_damage == 2, "Home damage must be 2.")
	_expect(ROBOT_CONFIG.xirang_kill_reward == 10, "Kill reward must be 10.")
	_expect(
		ROBOT_CONFIG.category_tags == PackedStringArray(["mechanical_life"]),
		"Combat robot must carry only the mechanical_life category."
	)
	_expect(
		is_equal_approx(ROBOT_CONFIG.dash_trigger_range, 140.0),
		"Dash trigger range must be 140."
	)
	_expect(
		is_equal_approx(ROBOT_CONFIG.dash_windup, 0.4),
		"Dash windup must be 0.4 seconds."
	)
	_expect(
		is_equal_approx(ROBOT_CONFIG.dash_speed, 100.0),
		"Dash base speed must be 100."
	)
	_expect(
		is_equal_approx(ROBOT_CONFIG.dash_duration, 1.4),
		"Dash duration must be 1.4 seconds."
	)
	_expect(
		is_equal_approx(ROBOT_CONFIG.dash_cooldown, 3.0),
		"Dash cooldown must be 3 seconds."
	)

	var robot := ROBOT_SCENE.instantiate() as CombatRobot
	_expect(robot != null, "Combat robot scene must instantiate CombatRobot.")
	if robot == null:
		return
	var sprite := robot.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var body_shapes := _collect_direct_collision_shapes(robot)
	var touch_shapes := _collect_direct_collision_shapes(
		robot.get_node("TouchDamageArea")
	)
	var warning := robot.get_node_or_null("WindupWarning") as Polygon2D
	_expect(sprite != null, "Scene must own an AnimatedSprite2D.")
	_expect(body_shapes.size() == 2, "Scene must own chassis and sword body shapes.")
	_expect(touch_shapes.size() == 2, "Touch area must own chassis and sword shapes.")
	_expect(warning != null, "Scene must own its windup warning polygon.")
	if sprite != null:
		_expect(sprite.scale == Vector2.ONE, "Pixel art must remain at native scale.")
		for animation_name in [&"move", &"windup", &"dash", &"death"]:
			_expect(
				sprite.sprite_frames != null
				and sprite.sprite_frames.has_animation(animation_name),
				"Missing %s animation." % animation_name
			)
	if body_shapes.size() == 2 and touch_shapes.size() == 2:
		for shape_node in body_shapes + touch_shapes:
			_expect(
				shape_node.shape is RectangleShape2D,
				"Every combat robot collision shape must be a rectangle."
			)
		_expect(
			_all_shape_resources_are_independent(body_shapes, touch_shapes),
			"Chassis/sword and body/touch shapes must all be independent resources."
		)
		_expect(
			(body_shapes[0].shape as RectangleShape2D).size == Vector2(8, 15),
			"Body collision size must match the box-shaped chassis."
		)
		_expect(
			(touch_shapes[0].shape as RectangleShape2D).size == Vector2(8, 15),
			"Touch collision size must match the box-shaped chassis."
		)
		_expect(
			(body_shapes[1].shape as RectangleShape2D).size == Vector2(7, 3)
			and (touch_shapes[1].shape as RectangleShape2D).size == Vector2(7, 3),
			"The sword must use independent slender rectangle collisions."
		)
	if warning != null:
		_expect(not warning.visible, "Windup warning must start hidden.")
		_expect(
			warning.polygon == PackedVector2Array([
				Vector2(0, -3),
				Vector2(140, -3),
				Vector2(140, 3),
				Vector2(0, 3),
			]),
			"Windup warning must be an unadjusted narrow 140-pixel corridor."
		)
	_expect(
		robot.collision_layer == 4 and robot.collision_mask == 2049,
		"Body collision must retain EnemyBody versus World/WaterTerrain only."
	)
	var touch_area := robot.get_node_or_null("TouchDamageArea") as Area2D
	_expect(
		touch_area != null
		and touch_area.collision_layer == 8
		and touch_area.collision_mask == 514,
		"Touch damage area must retain player/plant contact layers."
	)
	_expect(
		bool(robot.call("_uses_inherited_touch_damage")),
		"Combat robot must retain inherited physical touch damage."
	)
	_expect(
		int(robot.call("_get_touch_damage_type"))
		== EnemyConfig.DamageType.PHYSICAL,
		"Combat robot touch damage must use the physical damage channel."
	)
	robot.free()


func _test_target_lock_contract() -> void:
	var player := _spawn_player(Vector2(141.0, 0.0))
	var robot := _spawn_robot(Vector2.ZERO, player)
	_expect(
		not bool(robot.call("_try_start_windup", player)),
		"A target beyond 140 pixels must not trigger a dash."
	)
	player.global_position = Vector2(84.0, 48.0)
	var expected_direction := robot.global_position.direction_to(
		player.global_position
	)
	_expect(
		bool(robot.call("_try_start_windup", player)),
		"A live player within 140 pixels must trigger windup."
	)
	_expect(
		robot.combat_state == CombatRobot.CombatState.WINDUP,
		"Combat robot must enter WINDUP before dashing."
	)
	_expect(
		robot.dash_direction.is_equal_approx(expected_direction),
		"Dash direction must lock when windup begins."
	)
	_expect(
		robot.windup_warning.visible
		and is_equal_approx(
			robot.windup_warning.rotation,
			expected_direction.angle()
		),
		"Windup must show the authored corridor in the locked direction."
	)
	var initial_warning_alpha := robot.windup_warning.color.a
	player.global_position = Vector2(-80.0, 90.0)
	robot.call("_update_windup", 0.15)
	_expect(
		robot.dash_direction.is_equal_approx(expected_direction),
		"Moving the target during windup must not steer the locked direction."
	)
	_expect(
		robot.windup_warning.color.a > initial_warning_alpha
		and is_equal_approx(
			robot.windup_warning.rotation,
			expected_direction.angle()
		),
		"Windup warning must progress from 0 to 1 without tracking target motion."
	)
	player.queue_free()
	await process_frame
	robot.call("_update_windup", 0.3)
	_expect(
		robot.combat_state == CombatRobot.CombatState.DASH,
		"A committed dash must continue after its target disappears."
	)
	_expect(
		robot.dash_direction.is_equal_approx(expected_direction),
		"A disappearing target must not change the committed direction."
	)
	_expect(not robot.windup_warning.visible, "Starting DASH must hide the warning.")
	robot.queue_free()
	await process_frame


func _test_player_plant_only_target_contract() -> void:
	var player := _spawn_player(Vector2(600.0, 0.0))
	var robot := _spawn_robot(Vector2.ZERO, player)
	var home_gate := Node2D.new()
	test_root.add_child(home_gate)
	home_gate.global_position = Vector2(60.0, 0.0)
	robot.set_objective_target(home_gate)
	_expect(
		not bool(robot.call("_try_start_windup")),
		"A navigation-only Home gate must never trigger the dash."
	)

	var plant := _spawn_agave(Vector2(80.0, 0.0))
	robot.set_objective_target(plant)
	_expect(
		bool(robot.call("_try_start_windup")),
		"A live plant within 140 pixels must trigger the dash."
	)
	_expect(
		robot.dash_direction.is_equal_approx(Vector2.RIGHT),
		"Plant targets must commit the same fixed-direction dash contract."
	)

	robot.queue_free()
	home_gate.queue_free()
	plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	player.queue_free()
	await process_frame


func _test_dash_duration_speed_and_player_passthrough() -> void:
	var player := _spawn_player(Vector2(30.0, 0.0))
	var robot := _spawn_robot(Vector2.ZERO, player)
	robot.dash_direction = Vector2.RIGHT
	robot.add_move_speed_modifier(91001, 0.5)
	robot.call("_start_dash")
	robot.call("_update_dash", 0.2)
	_expect(
		is_equal_approx(robot.global_position.x, 10.0),
		"Dash must multiply base speed by the current effective move-speed multiplier."
	)
	_expect(
		robot.combat_state == CombatRobot.CombatState.DASH,
		"Player contact must not terminate the dash."
	)
	robot.remove_move_speed_modifier(91001)
	robot.call("_update_dash", 2.0)
	_expect(
		is_equal_approx(robot.global_position.x, 130.0),
		"Dash motion must clamp to its remaining duration without frame overshoot."
	)
	_expect(
		robot.combat_state == CombatRobot.CombatState.CHASE,
		"Dash must return to CHASE after its duration."
	)
	_expect(
		is_equal_approx(robot.dash_cooldown_left, 3.0),
		"A completed dash must start the three-second cooldown."
	)
	_expect(
		not bool(robot.call("_try_start_windup", player)),
		"Cooldown must prevent an immediate second dash."
	)
	robot.queue_free()
	player.queue_free()
	await process_frame


func _test_dash_stops_on_collision_layer(
	collision_layer_value: int,
	label: String
) -> void:
	var player := _spawn_player(Vector2(500.0, 0.0))
	var wall := _spawn_wall(
		Vector2(40.0, 0.0),
		Vector2(4.0, 120.0),
		collision_layer_value
	)
	var robot := _spawn_robot(Vector2.ZERO, player)
	await physics_frame
	robot.dash_direction = Vector2(1.0, 0.4).normalized()
	robot.call("_start_dash")
	robot.call("_update_dash", 1.0)
	_expect(
		robot.combat_state == CombatRobot.CombatState.CHASE,
		"%s collision must end the dash immediately." % label
	)
	_expect(
		robot.global_position.x > 0.0 and robot.global_position.x < 38.0,
		"%s collision must stop before penetrating the obstacle." % label
	)
	_expect(
		robot.global_position.y < 20.0,
		"%s collision must stop without sliding along the obstacle." % label
	)
	_expect(
		is_equal_approx(robot.dash_cooldown_left, 3.0),
		"%s collision must start the normal dash cooldown." % label
	)
	robot.queue_free()
	wall.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_contract() -> void:
	var player := _spawn_player(Vector2(100.0, 0.0))
	var robot := _spawn_robot(Vector2.ZERO, player)
	robot.configure_multiplayer_proxy()
	var sprite := robot.get_node("AnimatedSprite2D") as AnimatedSprite2D
	robot.play_multiplayer_enemy_action(
		CombatRobot.ACTION_WINDUP,
		Vector2.LEFT,
		1
	)
	_expect(sprite.animation == &"windup", "Proxy windup action must play windup.")
	_expect(
		robot.windup_warning.visible
		and is_equal_approx(robot.windup_warning.rotation, PI),
		"Proxy windup must show the corridor in the committed direction."
	)
	robot.play_multiplayer_enemy_action(
		CombatRobot.ACTION_DASH_START,
		Vector2.LEFT,
		2
	)
	_expect(sprite.animation == &"dash", "Proxy dash action must play dash.")
	_expect(not robot.windup_warning.visible, "Proxy dash start must hide warning.")
	robot.play_multiplayer_enemy_action(
		CombatRobot.ACTION_DASH_END,
		Vector2.LEFT,
		1
	)
	_expect(sprite.animation == &"dash", "A stale proxy action must be ignored.")
	_expect(
		not robot.windup_warning.visible,
		"A stale proxy warning tween must not re-show after dash start."
	)
	robot.play_multiplayer_enemy_action(
		CombatRobot.ACTION_DASH_END,
		Vector2.LEFT,
		3
	)
	_expect(sprite.animation == &"move", "Proxy dash end must restore movement.")
	_expect(not robot.windup_warning.visible, "Proxy dash end must hide warning.")
	robot.play_multiplayer_enemy_action_with_context(
		CombatRobot.ACTION_WINDUP,
		Vector2.RIGHT,
		robot.global_position,
		4,
		ROBOT_CONFIG.dash_windup * 0.5
	)
	_expect(
		robot.windup_warning.visible
		and is_equal_approx(
			robot.windup_warning.color.a,
			lerpf(0.06, 0.34, 0.5)
		),
		"Proxy windup must resume its warning from the received elapsed time."
	)
	robot.play_multiplayer_enemy_action_with_context(
		CombatRobot.ACTION_DASH_START,
		Vector2.RIGHT,
		robot.global_position,
		5,
		ROBOT_CONFIG.dash_duration + 0.1
	)
	_expect(
		sprite.animation == &"move" and not robot.windup_warning.visible,
		"An already-expired proxy dash action must not replay stale visuals."
	)
	robot.queue_free()
	player.queue_free()
	await process_frame


func _test_authoritative_action_broadcast_contract() -> void:
	test_root.enemy_actions.clear()
	var player := _spawn_player(Vector2(80.0, 0.0))
	var robot := _spawn_robot(Vector2.ZERO, player)
	robot.set_meta(&"net_id", 77)
	_expect(
		bool(robot.call("_try_start_windup", player)),
		"The authoritative robot must enter windup for broadcast coverage."
	)
	robot.call("_update_windup", ROBOT_CONFIG.dash_windup)
	robot.call("_finish_dash")
	var actions := test_root.enemy_actions
	_expect(
		actions.size() == 3,
		"Windup, dash start, and dash end must each use the generic enemy action channel."
	)
	if actions.size() == 3:
		_expect(
			actions[0].action_name == CombatRobot.ACTION_WINDUP
			and actions[1].action_name == CombatRobot.ACTION_DASH_START
			and actions[2].action_name == CombatRobot.ACTION_DASH_END,
			"Authoritative dash actions must preserve their lifecycle ordering."
		)
		_expect(
			actions[0].net_id == 77
			and actions[0].action_id == 1
			and actions[1].action_id == 2
			and actions[2].action_id == 3,
			"Authoritative dash actions must carry a stable enemy id and monotonic ids."
		)
	robot.queue_free()
	player.queue_free()
	await process_frame


func _spawn_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = spawn_position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	return player


func _spawn_agave(spawn_position: Vector2) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	plant.global_position = spawn_position
	test_root.add_child(plant)
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	return plant


func _spawn_robot(spawn_position: Vector2, player: Player) -> CombatRobot:
	var robot := ROBOT_SCENE.instantiate() as CombatRobot
	test_root.add_child(robot)
	robot.global_position = spawn_position
	robot.setup(ROBOT_CONFIG, player)
	robot.bind_gameplay_gateway(test_root)
	robot.set_physics_process(false)
	return robot


func _spawn_wall(
	spawn_position: Vector2,
	size: Vector2,
	collision_layer_value: int
) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = collision_layer_value
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape_node.shape = rectangle
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = spawn_position
	return wall


func _collect_direct_collision_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	for child in parent_node.get_children():
		var shape_node := child as CollisionShape2D
		if shape_node != null:
			shapes.append(shape_node)
	return shapes


func _all_shape_resources_are_independent(
	body_shapes: Array[CollisionShape2D],
	touch_shapes: Array[CollisionShape2D]
) -> bool:
	var seen_shapes: Array[Shape2D] = []
	for shape_node in body_shapes + touch_shapes:
		if shape_node.shape in seen_shapes:
			return false
		seen_shapes.append(shape_node.shape)
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
