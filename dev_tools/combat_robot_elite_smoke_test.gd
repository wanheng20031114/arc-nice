extends SceneTree

const ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_elite.tscn"
)
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_elite.tres"
)
const ORDINARY_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot.tscn"
)
const ORDINARY_CONFIG := preload(
	"res://resources/config/enemies/combat_robot.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const DEFAULT_DROP_TABLE := preload(
	"res://resources/config/enemies/default_enemy_drop_table.tres"
)

const WORLD_COLLISION_LAYER := 1
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11
const EXPECTED_WARNING_COLOR := Color("#9d4edd")


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
	test_root.name = "CombatRobotEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_scene_and_geometry_contract()
	await _test_unmodified_dash_distance_and_duration()
	await _test_dynamic_speed_multiplier()
	await _test_dash_collision(WORLD_COLLISION_LAYER, "World")
	await _test_dash_collision(WATER_TERRAIN_COLLISION_LAYER, "WaterTerrain")
	await _test_authoritative_action_contract()
	await _test_proxy_warning_and_elapsed_contract()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_ELITE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_scene_and_geometry_contract() -> void:
	_expect(
		ELITE_CONFIG is CombatRobotEliteConfig,
		"Elite robot must use CombatRobotEliteConfig."
	)
	_expect(
		ELITE_CONFIG is CombatRobotConfig,
		"Elite config must retain the ordinary combat-robot contract."
	)
	_expect(ELITE_CONFIG.display_name == "精英战斗机器人", "Display name mismatch.")
	_expect(ELITE_CONFIG.enemy_scene == ELITE_SCENE, "Enemy scene binding mismatch.")
	_expect(ELITE_CONFIG.max_health == 360, "Maximum health must be 360.")
	_expect(ELITE_CONFIG.attack_damage == 70, "Attack damage must be 70.")
	_expect(ELITE_CONFIG.physical_defense == 15, "Physical defense must be 15.")
	_expect(ELITE_CONFIG.magic_defense == 20, "Magic defense must be 20.")
	_expect(is_equal_approx(ELITE_CONFIG.move_speed, 40.0), "Move speed must be 40.")
	_expect(ELITE_CONFIG.home_damage == 2, "Home damage must remain 2.")
	_expect(ELITE_CONFIG.xirang_kill_reward == 10, "Kill reward must remain 10.")
	_expect(ELITE_CONFIG.drop_table == DEFAULT_DROP_TABLE, "Elite must use the common drop table.")
	_expect(
		ELITE_CONFIG.category_tags == PackedStringArray(["mechanical_life"]),
		"Elite robot must carry only mechanical_life."
	)
	_expect(is_equal_approx(ELITE_CONFIG.dash_trigger_range, 140.0), "Trigger range must stay 140.")
	_expect(is_equal_approx(ELITE_CONFIG.dash_windup, 0.4), "Windup must stay 0.4 seconds.")
	_expect(is_equal_approx(ELITE_CONFIG.dash_speed, 130.0), "Dash speed must be 130.")
	_expect(is_equal_approx(ELITE_CONFIG.dash_duration, 1.4), "Dash duration must stay 1.4 seconds.")
	_expect(is_equal_approx(ELITE_CONFIG.dash_cooldown, 3.0), "Cooldown must stay 3 seconds.")
	_expect(
		_color_rgb_equal(ELITE_CONFIG.windup_warning_color, EXPECTED_WARNING_COLOR),
		"Elite warning color must be #9D4EDD."
	)
	_expect(
		_color_rgb_equal(ORDINARY_CONFIG.windup_warning_color, Color(1.0, 0.28, 0.08)),
		"Ordinary warning color must retain its red-orange RGB."
	)

	var elite := ELITE_SCENE.instantiate() as CombatRobot
	var ordinary := ORDINARY_SCENE.instantiate() as CombatRobot
	_expect(elite != null and ordinary != null, "Both combat-robot scenes must instantiate CombatRobot.")
	if elite == null or ordinary == null:
		if elite != null:
			elite.free()
		if ordinary != null:
			ordinary.free()
		return
	var elite_warning := elite.get_node_or_null("WindupWarning") as Polygon2D
	var ordinary_warning := ordinary.get_node_or_null("WindupWarning") as Polygon2D
	_expect(elite_warning != null, "Elite scene must inherit WindupWarning.")
	if elite_warning != null:
		_expect(
			elite_warning.polygon == PackedVector2Array([
				Vector2(0, -3), Vector2(182, -3), Vector2(182, 3), Vector2(0, 3),
			]),
			"Elite warning corridor must be exactly 182x6 pixels."
		)
		_expect(
			_color_rgb_equal(elite_warning.color, EXPECTED_WARNING_COLOR),
			"Authored elite warning must start purple."
		)
	_expect(
		_same_collision_geometry(elite, ordinary),
		"Elite body, sword, and touch collision geometry must match the ordinary robot."
	)
	_expect(
		ordinary_warning != null
		and ordinary_warning.polygon[1].x == 140.0,
		"Ordinary warning corridor must remain 140 pixels."
	)
	var sprite := elite.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_expect(sprite != null and sprite.sprite_frames != null, "Elite must own SpriteFrames.")
	if sprite != null and sprite.sprite_frames != null:
		var expected := {
			&"move": [8, 14.0, true],
			&"windup": [4, 10.0, false],
			&"dash": [4, 12.0, true],
			&"death": [8, 12.0, false],
		}
		for animation_name: StringName in expected:
			var contract: Array = expected[animation_name]
			_expect(sprite.sprite_frames.has_animation(animation_name), "Missing %s animation." % animation_name)
			_expect(sprite.sprite_frames.get_frame_count(animation_name) == contract[0], "%s frame count mismatch." % animation_name)
			_expect(is_equal_approx(sprite.sprite_frames.get_animation_speed(animation_name), contract[1]), "%s FPS mismatch." % animation_name)
			_expect(sprite.sprite_frames.get_animation_loop(animation_name) == contract[2], "%s loop mismatch." % animation_name)
	elite.free()
	ordinary.free()


func _test_unmodified_dash_distance_and_duration() -> void:
	var player := _spawn_player(Vector2(500.0, 0.0))
	var elite := _spawn_elite(Vector2.ZERO, player)
	elite.dash_direction = Vector2.RIGHT
	elite.call("_start_dash")
	elite.call("_update_dash", 2.0)
	_expect(
		is_equal_approx(elite.global_position.x, 182.0),
		"130 speed for 1.4 seconds must clamp to exactly 182 pixels."
	)
	_expect(elite.combat_state == CombatRobot.CombatState.CHASE, "Timed dash must restore CHASE.")
	_expect(is_equal_approx(elite.dash_cooldown_left, 3.0), "Timed dash must start 3-second cooldown.")
	elite.queue_free()
	player.queue_free()
	await process_frame


func _test_dynamic_speed_multiplier() -> void:
	var player := _spawn_player(Vector2(500.0, 0.0))
	var elite := _spawn_elite(Vector2.ZERO, player)
	elite.dash_direction = Vector2.RIGHT
	elite.add_move_speed_modifier(92001, 0.5)
	elite.call("_start_dash")
	elite.call("_update_dash", 0.2)
	_expect(is_equal_approx(elite.global_position.x, 13.0), "Current 0.5 multiplier must reduce dash speed to 65.")
	elite.remove_move_speed_modifier(92001)
	elite.call("_update_dash", 2.0)
	_expect(
		is_equal_approx(elite.global_position.x, 169.0),
		"Removing the modifier must affect the remaining 1.2 seconds immediately."
	)
	elite.queue_free()
	player.queue_free()
	await process_frame


func _test_dash_collision(collision_layer_value: int, label: String) -> void:
	var player := _spawn_player(Vector2(500.0, 0.0))
	var wall := _spawn_wall(Vector2(40.0, 0.0), Vector2(4.0, 120.0), collision_layer_value)
	var elite := _spawn_elite(Vector2.ZERO, player)
	await physics_frame
	elite.dash_direction = Vector2(1.0, 0.35).normalized()
	elite.call("_start_dash")
	elite.call("_update_dash", 1.0)
	_expect(elite.combat_state == CombatRobot.CombatState.CHASE, "%s must stop the elite dash." % label)
	_expect(elite.global_position.x > 0.0 and elite.global_position.x < 38.0, "%s must stop before penetration." % label)
	_expect(elite.global_position.y < 20.0, "%s stop must not slide along the obstacle." % label)
	_expect(is_equal_approx(elite.dash_cooldown_left, 3.0), "%s stop must start cooldown." % label)
	elite.queue_free()
	wall.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_warning_and_elapsed_contract() -> void:
	var player := _spawn_player(Vector2(100.0, 0.0))
	var elite := _spawn_elite(Vector2.ZERO, player)
	elite.configure_multiplayer_proxy()
	var sprite := elite.get_node("AnimatedSprite2D") as AnimatedSprite2D
	elite.play_multiplayer_enemy_action_with_context(
		CombatRobot.ACTION_WINDUP,
		Vector2.LEFT,
		elite.global_position,
		1,
		0.2
	)
	_expect(sprite.animation == &"windup", "Proxy must resume elite windup animation.")
	_expect(elite.windup_warning.visible, "Proxy elapsed windup must show the warning.")
	_expect(_color_rgb_equal(elite.windup_warning.color, EXPECTED_WARNING_COLOR), "Proxy warning must use configured purple RGB.")
	_expect(is_equal_approx(elite.windup_warning.color.a, 0.2), "Half elapsed windup must resume at alpha 0.20.")
	elite.play_multiplayer_enemy_action_with_context(
		CombatRobot.ACTION_DASH_START,
		Vector2.RIGHT,
		elite.global_position,
		2,
		ELITE_CONFIG.dash_duration + 0.01
	)
	_expect(sprite.animation == &"move", "Expired proxy dash must restore movement immediately.")
	_expect(not elite.windup_warning.visible, "Expired proxy dash must clear warning.")
	elite.queue_free()
	player.queue_free()
	await process_frame


func _test_authoritative_action_contract() -> void:
	test_root.enemy_actions.clear()
	var player := _spawn_player(Vector2(80.0, 0.0))
	var elite := _spawn_elite(Vector2.ZERO, player)
	elite.set_meta(&"net_id", 501)
	_expect(bool(elite.call("_try_start_windup", player)), "Elite must enter windup for Host action coverage.")
	elite.call("_update_windup", ELITE_CONFIG.dash_windup)
	elite.call("_finish_dash")
	var actions := test_root.enemy_actions
	_expect(actions.size() == 3, "Host must broadcast windup, dash start, and dash end exactly once.")
	if actions.size() == 3:
		_expect(
			actions[0].action_name == CombatRobot.ACTION_WINDUP
			and actions[1].action_name == CombatRobot.ACTION_DASH_START
			and actions[2].action_name == CombatRobot.ACTION_DASH_END,
			"Elite must reuse the ordinary three-action dash protocol."
		)
		_expect(
			actions[0].net_id == 501
			and actions[0].action_id == 1
			and actions[1].action_id == 2
			and actions[2].action_id == 3,
			"Elite Host actions must keep a stable enemy id and monotonic ids."
		)
	elite.queue_free()
	player.queue_free()
	await process_frame


func _spawn_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	player.global_position = spawn_position
	test_root.add_child(player)
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	return player


func _spawn_elite(spawn_position: Vector2, player: Player) -> CombatRobot:
	var elite := ELITE_SCENE.instantiate() as CombatRobot
	test_root.add_child(elite)
	elite.global_position = spawn_position
	elite.setup(ELITE_CONFIG, player)
	elite.bind_gameplay_gateway(test_root)
	elite.set_physics_process(false)
	return elite


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


func _same_collision_geometry(elite: Node, ordinary: Node) -> bool:
	for parent_path in [NodePath("."), NodePath("TouchDamageArea")]:
		var elite_parent := elite.get_node(parent_path)
		var ordinary_parent := ordinary.get_node(parent_path)
		var elite_shapes := _direct_shapes(elite_parent)
		var ordinary_shapes := _direct_shapes(ordinary_parent)
		if elite_shapes.size() != ordinary_shapes.size():
			return false
		for index in range(elite_shapes.size()):
			var elite_shape := elite_shapes[index]
			var ordinary_shape := ordinary_shapes[index]
			if elite_shape.name != ordinary_shape.name or elite_shape.position != ordinary_shape.position:
				return false
			if not (elite_shape.shape is RectangleShape2D) or not (ordinary_shape.shape is RectangleShape2D):
				return false
			if (elite_shape.shape as RectangleShape2D).size != (ordinary_shape.shape as RectangleShape2D).size:
				return false
	return true


func _direct_shapes(parent_node: Node) -> Array[CollisionShape2D]:
	var shapes: Array[CollisionShape2D] = []
	for child in parent_node.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shapes.append(shape)
	return shapes


func _color_rgb_equal(left: Color, right: Color) -> bool:
	return (
		is_equal_approx(left.r, right.r)
		and is_equal_approx(left.g, right.g)
		and is_equal_approx(left.b, right.b)
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
