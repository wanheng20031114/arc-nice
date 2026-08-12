extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const OPERATOR_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_drone_operator.tscn"
)
const DRONE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
)
const OPERATOR_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_drone_operator.tres"
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
const RAPID_PROJECTILE_MATERIAL := preload(
	"res://resources/shader/rapid_projectile_single_pass.tres"
)
const NET_CONSTANTS := preload("res://scene/multiplayer/net_constants.gd")
const WORLD_COLLISION_LAYER := 1
const WATER_COLLISION_LAYER := 1 << 11
const EPSILON := 0.001


class DirectPathfinder:
	extends Node

	var is_built := true

	func try_get_safe_navigation_step(
		_from_position: Vector2,
		target_position: Vector2,
		_half_extents: Vector2 = Vector2.ZERO,
		_terrain_types: int = DualGridTilemap.TraversalType.LAND
	) -> Dictionary:
		return {
			"status": GridPathfinder.NavigationStepStatus.READY,
			"is_complete_route": true,
			"waypoint": target_position,
		}


class DroneOperatorTestRoot:
	extends Node2D

	var registered_projectiles: Array[Dictionary] = []
	var enemy_actions: Array[Dictionary] = []
	var client_view := false
	var multiplayer_damage_requests: Array[Dictionary] = []

	func has_session_object_pool_scene(_scene: PackedScene) -> bool:
		return false

	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		_owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float
	) -> void:
		registered_projectiles.append({
			"projectile": projectile,
			"projectile_type": projectile_type,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
		})

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

	func is_client_view_runtime() -> bool:
		return client_view

	func request_multiplayer_player_damage(
		projectile_id: int,
		target_peer_id: int,
		damage: int,
		source_type: StringName,
		damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
		source_direction_or_is_ranged: Variant = Vector2.ZERO,
		is_ranged: bool = false,
		_contact_preconsumed: bool = false
	) -> bool:
		var damage_type := EnemyConfig.DamageType.PHYSICAL
		var source_direction := Vector2.ZERO
		if damage_type_or_source_direction is int:
			damage_type = int(damage_type_or_source_direction) as EnemyConfig.DamageType
		if source_direction_or_is_ranged is Vector2:
			source_direction = source_direction_or_is_ranged as Vector2
		elif source_direction_or_is_ranged is bool:
			is_ranged = bool(source_direction_or_is_ranged)
		multiplayer_damage_requests.append({
			"projectile_id": projectile_id,
			"target_peer_id": target_peer_id,
			"damage": damage,
			"source_type": source_type,
			"damage_type": damage_type,
			"source_direction": source_direction,
			"is_ranged": is_ranged,
		})
		for child in get_children():
			var player := child as Player
			if player == null or player.peer_id != target_peer_id:
				continue
			return player.apply_damage(
				damage,
				damage_type,
				{
					"is_ranged": is_ranged,
					"source_direction": source_direction,
				}
			)
		return false


class MpGameProjectileHarness:
	extends "res://scene/multiplayer/mp_game.gd"

	# The focused fixture drives only the replicated-projectile pipeline. Avoid
	# booting a complete multiplayer session while retaining MpGame's real
	# instantiation, dedupe and elapsed-compensation implementation.
	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass


var failures: Array[String] = []
var test_root: DroneOperatorTestRoot
var direct_pathfinder: DirectPathfinder
var motion_system: CombatRobotDroneMotionSystem


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = DroneOperatorTestRoot.new()
	test_root.name = "CombatRobotDroneOperatorSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	direct_pathfinder = DirectPathfinder.new()
	direct_pathfinder.name = "GridPathfinder"
	test_root.add_child(direct_pathfinder)
	motion_system = CombatRobotDroneMotionSystem.new()
	motion_system.name = "CombatRobotDroneMotionSystem"
	test_root.add_child(motion_system)

	_test_resource_and_scene_contract()
	_test_animation_and_marker_contract()
	await _test_player_lock_and_independent_drone()
	await _test_target_types_range_and_world_visibility()
	await _test_cooldown_tracking_and_touch_damage()
	await _test_drone_fixed_flight_and_explosion_damage()
	await _test_proxy_elapsed_and_action_ordering()
	await _test_mp_game_drone_projectile_pipeline()
	_test_multiplayer_and_runtime_source_contract()

	_cleanup_projectiles()
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_DRONE_OPERATOR_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		OPERATOR_CONFIG is CombatRobotDroneOperatorConfig,
		"Operator must use CombatRobotDroneOperatorConfig."
	)
	_expect(OPERATOR_CONFIG.display_name == "爆炸无人机操作员", "Display name mismatch.")
	_expect(OPERATOR_CONFIG.enemy_scene == OPERATOR_SCENE, "Enemy scene binding mismatch.")
	_expect(OPERATOR_CONFIG.drone_scene == DRONE_SCENE, "Drone scene binding mismatch.")
	_expect(
		OPERATOR_CONFIG.max_health == 180
		and OPERATOR_CONFIG.attack_damage == 50
		and OPERATOR_CONFIG.physical_defense == 15
		and OPERATOR_CONFIG.magic_defense == 15
		and is_equal_approx(OPERATOR_CONFIG.move_speed, 30.0)
		and OPERATOR_CONFIG.home_damage == 2
		and OPERATOR_CONFIG.xirang_kill_reward == 10,
		"Operator core attributes must remain 180/50/15/15/30/2/10."
	)
	_expect(
		OPERATOR_CONFIG.category_tags == PackedStringArray(["mechanical_life"])
		and not OPERATOR_CONFIG.has_category_tag(&"artificial_creation"),
		"Operator must belong only to mechanical_life."
	)
	_expect(
		is_equal_approx(OPERATOR_CONFIG.attack_range, 80.0)
		and is_equal_approx(OPERATOR_CONFIG.stop_distance, 40.0)
		and is_equal_approx(OPERATOR_CONFIG.deploy_delay, 0.10)
		and is_equal_approx(OPERATOR_CONFIG.attack_cooldown, 3.0)
		and OPERATOR_CONFIG.visible_target_check_limit == 4
		and is_equal_approx(OPERATOR_CONFIG.blocked_retry_interval, 0.35)
		and is_equal_approx(OPERATOR_CONFIG.drone_speed, 60.0)
		and is_equal_approx(OPERATOR_CONFIG.explosion_radius, 28.0),
		"Operator deployment parameters must match the approved contract."
	)
	_expect(OPERATOR_CONFIG.drop_table != null, "Operator must retain the full default drop table.")

	var operator := OPERATOR_SCENE.instantiate() as CombatRobotDroneOperator
	_expect(operator != null, "Operator scene must instantiate its dedicated class.")
	if operator == null:
		return
	var body_shape := operator.get_node("CollisionShape2D") as CollisionShape2D
	var touch_shape := operator.get_node(
		"TouchDamageArea/CollisionShape2D"
	) as CollisionShape2D
	var sense_shape := operator.get_node(
		"AttackSenseArea/CollisionShape2D"
	) as CollisionShape2D
	var sense_area := operator.get_node("AttackSenseArea") as Area2D
	_expect(
		body_shape.shape is RectangleShape2D
		and (body_shape.shape as RectangleShape2D).size == Vector2(8, 17)
		and touch_shape.shape is RectangleShape2D
		and (touch_shape.shape as RectangleShape2D).size == Vector2(8, 17),
		"Body and touch collision must use independent 8x17 rectangles."
	)
	_expect(
		not is_same(body_shape.shape, touch_shape.shape)
		and body_shape.position == Vector2(0, 1.5)
		and touch_shape.position == Vector2(0, 1.5),
		"Body and touch shapes must be independent and center on the box chassis."
	)
	_expect(
		sense_area.collision_layer == 0
		and sense_area.collision_mask == 514
		and not sense_area.monitorable
		and sense_shape.shape is CircleShape2D
		and is_equal_approx((sense_shape.shape as CircleShape2D).radius, 80.0),
		"AttackSenseArea must be an authored Player/Plant 80-pixel sensor."
	)
	for timer_name in [&"DeployTimer", &"CooldownTimer", &"BlockedRetryTimer"]:
		var timer := operator.get_node(String(timer_name)) as Timer
		_expect(
			timer != null
			and timer.one_shot
			and timer.process_callback == Timer.TIMER_PROCESS_PHYSICS,
			"%s must be an authored one-shot physics Timer." % timer_name
		)
	_expect(
		operator.get_node_or_null("DroneSpawn") is Marker2D,
		"Operator scene must author its center DroneSpawn marker."
	)
	_expect(bool(operator.call("_uses_inherited_touch_damage")), "Contact damage must remain enabled.")
	_expect(operator.can_target_water_plant_objectives(), "Operator must target water plants.")
	operator.free()

	var drone := DRONE_SCENE.instantiate() as CombatRobotSuicideDrone
	_expect(drone != null, "Drone scene must instantiate its dedicated class.")
	if drone == null:
		return
	_expect(
		drone is Node2D
		and drone.find_children("*", "CollisionObject2D", true, false).is_empty(),
		"Drone lease must contain no collision or attackable object."
	)
	_expect(
		drone.z_index == 3
		and drone.is_in_group(&"runtime_projectiles")
		and drone.get_node("DroneSprite").material == RAPID_PROJECTILE_MATERIAL,
		"Drone must use z=3, projectile telemetry, and the shared rapid material."
	)
	var circle := drone.explosion_shape as CircleShape2D
	_expect(circle != null and is_equal_approx(circle.radius, 28.0), "Explosion query radius must be 28.")
	_expect(not drone.is_processing() and not drone.is_physics_processing(), "Drone must own no per-node process callback.")
	drone.free()


func _test_animation_and_marker_contract() -> void:
	var operator_frames := load(
		"res://resources/animation/combat_robot_drone_operator.tres"
	) as SpriteFrames
	_expect(
		operator_frames.get_frame_count(&"move") == 8
		and is_equal_approx(operator_frames.get_animation_speed(&"move"), 14.0)
		and operator_frames.get_animation_loop(&"move")
		and operator_frames.get_frame_count(&"deploy") == 3
		and is_equal_approx(operator_frames.get_animation_speed(&"deploy"), 30.0)
		and not operator_frames.get_animation_loop(&"deploy")
		and operator_frames.get_frame_count(&"death") == 8
		and is_equal_approx(operator_frames.get_animation_speed(&"death"), 12.0),
		"Operator move/deploy/death animation contract mismatch."
	)
	var drone_frames := load(
		"res://resources/animation/combat_robot_suicide_drone.tres"
	) as SpriteFrames
	_expect(
		drone_frames.get_frame_count(&"fly") == 4
		and is_equal_approx(drone_frames.get_animation_speed(&"fly"), 12.0)
		and drone_frames.get_animation_loop(&"fly")
		and drone_frames.get_frame_count(&"target") == 4
		and is_equal_approx(drone_frames.get_animation_speed(&"target"), 12.0)
		and drone_frames.get_animation_loop(&"target")
		and drone_frames.get_frame_count(&"explode") == 8
		and is_equal_approx(drone_frames.get_animation_speed(&"explode"), 14.0)
		and not drone_frames.get_animation_loop(&"explode"),
		"Drone fly/X2 marker/X1 explosion animation contract mismatch."
	)
	var marker_texture := load(
		"res://resources/texture/enemy/mechanical_life/combat_robot_drone_target_marker.png"
	) as Texture2D
	var marker_image := marker_texture.get_image()
	var marker_rects: Array[Rect2i] = []
	for frame_index in range(4):
		var frame_image := marker_image.get_region(
			Rect2i(frame_index * 16, 0, 16, 16)
		)
		var used_rect := frame_image.get_used_rect()
		marker_rects.append(used_rect)
		_expect(
			Vector2(used_rect.position) + Vector2(used_rect.size) * 0.5
			== Vector2(8, 8),
			"Every X2 target-marker pulse frame must keep the exact center."
		)
	_expect(
		marker_rects[0].size != marker_rects[1].size
		and marker_rects[1].size != marker_rects[2].size,
		"The X2 lock point must retain its approved simple pulse animation."
	)


func _test_player_lock_and_independent_drone() -> void:
	_reset_records()
	var player := _spawn_player(Vector2(60, 0))
	var operator := _spawn_operator(Vector2.ZERO, player)
	operator.set_meta(&"net_id", 540)
	await physics_frame
	operator.call("_on_attack_sense_area_body_entered", player)
	_expect(
		operator.combat_state == CombatRobotDroneOperator.CombatState.DEPLOY
		and operator.animated_sprite.animation == &"deploy"
		and operator.locked_target_position.is_equal_approx(Vector2(60, 0)),
		"A visible player inside range must lock immediately and enter DEPLOY."
	)
	_expect(
		test_root.registered_projectiles.size() == 1
		and test_root.enemy_actions.size() == 1,
		"Lock commit must create one drone and one deploy action."
	)
	if test_root.registered_projectiles.size() == 1:
		var record := test_root.registered_projectiles[0]
		var drone := record.projectile as CombatRobotSuicideDrone
		_expect(
			record.projectile_type == OPERATOR_CONFIG.projectile_type
			and record.damage == 50
			and is_equal_approx(record.speed, 60.0)
			and is_equal_approx(record.lifetime, 1.0)
			and drone != null
			and drone.deployment_started
			and drone.target_marker.visible
			and not drone.drone_sprite.visible,
			"Commit must snapshot 50 damage and expose the target marker before launch."
		)
		var fixed_target := drone.target_position
		player.global_position = Vector2(-200, 40)
		player.is_dead = true
		operator.call("_die")
		_expect(
			drone.pool_active
			and drone.deployment_started
			and drone.target_position.is_equal_approx(fixed_target),
			"Target movement/death and operator death must not change or cancel the committed drone."
		)
	operator.queue_free()
	player.queue_free()
	_cleanup_projectiles()
	await process_frame


func _test_target_types_range_and_world_visibility() -> void:
	_reset_records()
	var boundary_player := _spawn_player(Vector2(80, 0))
	var operator := _spawn_operator(Vector2.ZERO, boundary_player)
	await physics_frame
	operator.sensed_targets[boundary_player.get_instance_id()] = boundary_player
	_expect(
		bool(operator.call("_try_select_and_begin_deploy")),
		"A player center exactly 80 pixels away must be accepted."
	)
	operator.queue_free()
	boundary_player.queue_free()
	_cleanup_projectiles()
	await process_frame

	var outside_player := _spawn_player(Vector2(80.1, 0))
	operator = _spawn_operator(Vector2.ZERO, outside_player)
	await physics_frame
	operator.sensed_targets[outside_player.get_instance_id()] = outside_player
	_expect(
		not bool(operator.call("_try_select_and_begin_deploy"))
		and test_root.registered_projectiles.is_empty(),
		"A target center beyond 80 pixels must not deploy a drone."
	)
	var home := Node2D.new()
	test_root.add_child(home)
	home.global_position = Vector2(30, 0)
	operator.call("_on_attack_sense_area_body_entered", home)
	_expect(
		not operator.sensed_targets.has(home.get_instance_id()),
		"An ordinary Home/navigation target must never enter combat sensing."
	)
	operator.queue_free()
	outside_player.queue_free()
	home.queue_free()
	await process_frame

	var plant := _spawn_plant(Vector2(50, 0))
	operator = _spawn_operator(Vector2.ZERO, null)
	await physics_frame
	operator.sensed_targets[plant.get_instance_id()] = plant
	_expect(
		bool(operator.call("_try_select_and_begin_deploy"))
		and operator.last_attack_target == plant,
		"A live plant, including a water-placed objective, must trigger deployment."
	)
	operator.queue_free()
	plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	_cleanup_projectiles()
	await process_frame

	var blocked_players: Array[Player] = []
	for target_index in range(4):
		blocked_players.append(_spawn_player(Vector2(20 + target_index * 10, 0)))
	var fifth_visible := _spawn_player(Vector2(0, 70))
	operator = _spawn_operator(Vector2.ZERO, blocked_players[0])
	var wall := _spawn_wall(Vector2(10, 0), Vector2(4, 20), WORLD_COLLISION_LAYER)
	await physics_frame
	for target in blocked_players:
		operator.sensed_targets[target.get_instance_id()] = target
	operator.sensed_targets[fifth_visible.get_instance_id()] = fifth_visible
	_expect(
		not bool(operator.call("_try_select_and_begin_deploy"))
		and test_root.registered_projectiles.is_empty()
		and not operator.blocked_retry_timer.is_stopped(),
		"Only the nearest four candidates may be checked; a visible fifth target must wait for retry."
	)
	wall.queue_free()
	await physics_frame
	operator.call("_on_blocked_retry_timer_timeout")
	_expect(
		operator.combat_state == CombatRobotDroneOperator.CombatState.DEPLOY
		and test_root.registered_projectiles.size() == 1,
		"The 0.35-second blocked retry must deploy once World visibility becomes clear."
	)
	operator.queue_free()
	for target in blocked_players:
		target.queue_free()
	fifth_visible.queue_free()
	_cleanup_projectiles()
	await process_frame


func _test_cooldown_tracking_and_touch_damage() -> void:
	_reset_records()
	var player := _spawn_player(Vector2(60, 0))
	var operator := _spawn_operator(Vector2.ZERO, player)
	await physics_frame
	operator.sensed_targets[player.get_instance_id()] = player
	_expect(bool(operator.call("_try_select_and_begin_deploy")), "Cooldown fixture must deploy.")
	operator.call("_on_deploy_timer_timeout")
	_expect(
		operator.combat_state == CombatRobotDroneOperator.CombatState.TRACKING_COOLDOWN
		and absf(operator.cooldown_timer.time_left - 3.0) <= 0.02,
		"Cooldown must begin only after the 0.10-second deployment phase."
	)
	operator.call("_physics_process", 0.0)
	_expect(
		absf(operator.velocity.length() - 30.0) <= 0.05,
		"Cooldown tracking beyond 40 pixels must use full effective move speed."
	)
	player.global_position = operator.global_position + Vector2(20, 0)
	operator.call("_physics_process", 0.0)
	_expect(operator.velocity == Vector2.ZERO, "Cooldown tracking must stop inside 40 pixels.")
	operator.queue_free()
	player.queue_free()
	_cleanup_projectiles()
	await process_frame

	player = _spawn_player(Vector2.ZERO)
	player.physical_defense = 0
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	operator = _spawn_operator(Vector2.ZERO, player)
	var health_before := player.current_health
	operator.call("_on_touch_damage_area_body_entered", player)
	_expect(
		health_before - player.current_health == 50
		and int(operator.call("_get_touch_damage_type"))
			== EnemyConfig.DamageType.PHYSICAL,
		"Operator body contact must deal 50 physical damage."
	)
	operator.queue_free()
	player.queue_free()
	await process_frame


func _test_drone_fixed_flight_and_explosion_damage() -> void:
	var drone := _spawn_drone(Vector2.ZERO, Vector2(0.6, 0.8), 50, 1.0)
	_expect(drone.begin_deployment(), "Fixed-flight fixture must begin deployment.")
	motion_system.set_physics_process(false)
	drone.advance_batched(0.05)
	_expect(
		drone.target_marker.visible and not drone.drone_sprite.visible,
		"The first 0.10 seconds must show only the animated lock marker."
	)
	drone.advance_batched(0.05)
	_expect(
		drone.drone_sprite.visible
		and drone.drone_sprite.position.is_equal_approx(Vector2.ZERO),
		"The drone must launch from its snapshotted body center at t=0.10."
	)
	drone.advance_batched(0.5)
	_expect(
		drone.drone_sprite.position.is_equal_approx(Vector2(18, 24))
		and absf(drone.drone_sprite.position.length() / 0.5 - 60.0) <= 0.05,
		"Diagonal fixed flight must preserve a 60-pixel/second velocity magnitude."
	)
	var world_wall := _spawn_wall(Vector2(24, 32), Vector2(20, 20), WORLD_COLLISION_LAYER)
	var water_wall := _spawn_wall(Vector2(27, 36), Vector2(20, 20), WATER_COLLISION_LAYER)
	await physics_frame
	drone.advance_batched(0.5)
	_expect(
		drone.explosion_started
		and drone.target_position.is_equal_approx(Vector2(36, 48))
		and drone.explosion_sprite.position.is_equal_approx(Vector2(36, 48))
		and drone.explosion_audio.position.is_equal_approx(Vector2(36, 48))
		and not drone.target_marker.visible
		and not drone.drone_sprite.visible,
		"World, Water, and units must not alter the predetermined endpoint."
	)
	drone.retire()
	world_wall.queue_free()
	water_wall.queue_free()
	await process_frame

	var near_player := _spawn_player(Vector2(60, 0))
	near_player.physical_defense = 0
	near_player.invincibility_duration = 0.0
	near_player.invincibility_time_left = 0.0
	var far_player := _spawn_player(Vector2(100, 0))
	far_player.physical_defense = 0
	far_player.invincibility_duration = 0.0
	far_player.invincibility_time_left = 0.0
	var plant := _spawn_plant(Vector2(42, 0))
	var blast_wall := _spawn_wall(Vector2(30, 0), Vector2(4, 40), WORLD_COLLISION_LAYER)
	await physics_frame
	await physics_frame
	var near_health := near_player.current_health
	var far_health := far_player.current_health
	var plant_health := plant.current_health
	drone = _spawn_drone(Vector2.ZERO, Vector2.RIGHT, 50, 1.0)
	drone.begin_deployment()
	motion_system.set_physics_process(false)
	drone.simulate_compensated_motion(1.1)
	_expect(
		near_health - near_player.current_health == 50
		and far_player.current_health == far_health
		and plant_health - plant.current_health
			== maxi(50 - plant.physical_defense, 1),
		(
			"Explosion mismatch: player=%d@%s/L%d disabled=%s dead=%s last=%d id=%d hit=%s, far=%d@%s, plant=%d, defense=%d, target=%s."
			% [
				near_health - near_player.current_health,
				near_player.global_position,
				near_player.collision_layer,
				near_player.collision_shape.disabled,
				near_player.is_dead,
				near_player.last_damage_taken,
				drone.projectile_id,
				drone.explosion_damaged_bodies.keys(),
				far_health - far_player.current_health,
				far_player.global_position,
				plant_health - plant.current_health,
				plant.physical_defense,
				drone.target_position,
			]
		)
	)
	var health_after_first_query := near_player.current_health
	drone.simulate_compensated_motion(1.2)
	_expect(
		near_player.current_health == health_after_first_query,
		"Repeated visual advancement must never apply the same explosion twice."
	)
	drone.retire()
	blast_wall.queue_free()
	plant.begin_removal(PlantDefense.RemovalMode.SILENT)
	near_player.queue_free()
	far_player.queue_free()
	await process_frame

	var client_player := _spawn_player(Vector2.ZERO)
	client_player.physical_defense = 0
	client_player.invincibility_duration = 0.0
	client_player.invincibility_time_left = 0.0
	await physics_frame
	var client_health := client_player.current_health
	test_root.client_view = true
	drone = _spawn_drone(Vector2.ZERO, Vector2.RIGHT, 50, 0.0)
	drone.begin_deployment()
	motion_system.set_physics_process(false)
	drone.simulate_compensated_motion(0.10)
	_expect(
		client_player.current_health == client_health,
		"Client-view drone explosions must remain visual-only."
	)
	test_root.client_view = false
	drone.retire()
	client_player.queue_free()
	await process_frame


func _test_proxy_elapsed_and_action_ordering() -> void:
	var player := _spawn_player(Vector2(60, 0))
	var proxy := _spawn_operator(Vector2.ZERO, player)
	proxy.configure_multiplayer_proxy()
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotDroneOperator.ACTION_DEPLOY,
		Vector2.LEFT,
		proxy.global_position,
		2,
		0.04
	)
	_expect(
		proxy.animated_sprite.animation == &"deploy"
		and proxy.animated_sprite.frame == 1
		and proxy.facing_left,
		"Proxy elapsed playback must seek to deploy frame one and preserve Host direction."
	)
	var accepted_frame := proxy.animated_sprite.frame
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotDroneOperator.ACTION_DEPLOY,
		Vector2.RIGHT,
		proxy.global_position,
		1,
		0.0
	)
	_expect(
		proxy.animated_sprite.frame == accepted_frame and proxy.facing_left,
		"Out-of-order deploy actions must be discarded."
	)
	await create_timer(0.07).timeout
	_expect(
		proxy.animated_sprite.animation == &"move",
		"Proxy deploy visuals must auto-restore at the remaining 0.06-second deadline."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotDroneOperator.ACTION_DEPLOY,
		Vector2.RIGHT,
		proxy.global_position,
		3,
		0.10
	)
	_expect(
		proxy.animated_sprite.animation == &"move",
		"An already-expired deploy action must not replay."
	)
	proxy.queue_free()
	player.queue_free()
	await process_frame


func _test_mp_game_drone_projectile_pipeline() -> void:
	var mp_game := MpGameProjectileHarness.new()
	mp_game.name = "MpGameDroneProjectileHarness"
	var keepalive_request := HTTPRequest.new()
	keepalive_request.name = "PublicRoomKeepaliveRequest"
	mp_game.add_child(keepalive_request)
	var mp_motion_system := CombatRobotDroneMotionSystem.new()
	mp_motion_system.name = "CombatRobotDroneMotionSystem"
	mp_game.add_child(mp_motion_system)
	var projectile_coordinator := MpProjectileCoordinator.new()
	projectile_coordinator.name = "ProjectileCoordinator"
	mp_game.add_child(projectile_coordinator)

	# MpGame requires a typed CombatRuntimeBase reference only to resolve the shared
	# motion system and client-view authority. Keeping this fixture off-tree avoids
	# constructing unrelated gameplay nodes.
	var runtime_stub := StandardGame.new()
	runtime_stub.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	runtime_stub.combat_robot_drone_motion_system = mp_motion_system
	var gameplay_gateway := MultiplayerGameplayGateway.new()
	gameplay_gateway.name = "MultiplayerGameplayGateway"
	runtime_stub.add_child(gameplay_gateway)
	gameplay_gateway.bind_runtime(runtime_stub)
	mp_game.game = runtime_stub
	mp_game.projectile_coordinator = projectile_coordinator
	projectile_coordinator.bind_runtime(runtime_stub)
	test_root.add_child(mp_game)
	await process_frame
	test_root.client_view = true
	mp_game.set("_has_host_time_offset", true)
	mp_game.set("_host_to_client_time_offset", 0.0)

	var projectile_type := "combat_robot_suicide_drone"
	var now := float(mp_game.call("_get_net_time"))
	mp_game.net_projectile_fired(
		71001,
		projectile_type,
		0,
		Vector2(10, 20),
		Vector2.RIGHT,
		50,
		60.0,
		1.0,
		false,
		0,
		now - 0.04,
		0
	)
	var deploy_drone := (
		projectile_coordinator.get_projectile(71001)
		as CombatRobotSuicideDrone
	)
	_expect(
		deploy_drone != null
		and deploy_drone.deployment_started
		and not deploy_drone.flight_started
		and deploy_drone.target_marker.visible
		and not deploy_drone.drone_sprite.visible,
		"MpGame must reconstruct a late deploy-stage drone with only its animated marker visible."
	)

	# A duplicate authoritative packet must reconcile the existing identity, not
	# create a second drone or overwrite its already committed trajectory.
	mp_game.net_projectile_fired(
		71001,
		projectile_type,
		0,
		Vector2(99, 99),
		Vector2.LEFT,
		99,
		60.0,
		1.0,
		false,
		0,
		now,
		0
	)
	_expect(
		int(projectile_coordinator.get_state_metrics().get("known_projectiles", -1)) == 1
		and projectile_coordinator.get_projectile(71001) == deploy_drone
		and deploy_drone.direction.is_equal_approx(Vector2.RIGHT)
		and deploy_drone.damage == 50,
		"Duplicate drone packets must not duplicate or rewrite the committed lease."
	)

	now = float(mp_game.call("_get_net_time"))
	mp_game.net_projectile_fired(
		71002,
		projectile_type,
		0,
		Vector2(20, 30),
		Vector2.RIGHT,
		50,
		60.0,
		1.0,
		false,
		0,
		now - 0.40,
		0
	)
	var flight_drone := (
		projectile_coordinator.get_projectile(71002)
		as CombatRobotSuicideDrone
	)
	_expect(
		flight_drone != null
		and flight_drone.flight_started
		and not flight_drone.explosion_started
		and flight_drone.target_marker.visible
		and flight_drone.drone_sprite.visible
		and absf(flight_drone.drone_sprite.position.x - 18.0) <= 1.0,
		"MpGame elapsed compensation must seek a drone into its fixed flight segment."
	)

	now = float(mp_game.call("_get_net_time"))
	mp_game.net_projectile_fired(
		71003,
		projectile_type,
		0,
		Vector2(30, 40),
		Vector2.RIGHT,
		50,
		60.0,
		1.0,
		false,
		0,
		now - 1.30,
		0
	)
	var explosion_drone := (
		projectile_coordinator.get_projectile(71003)
		as CombatRobotSuicideDrone
	)
	_expect(
		explosion_drone != null
		and explosion_drone.explosion_started
		and not explosion_drone.target_marker.visible
		and not explosion_drone.drone_sprite.visible
		and explosion_drone.explosion_sprite.visible
		and explosion_drone.explosion_sprite.position.is_equal_approx(Vector2(60, 0)),
		"MpGame elapsed compensation must seek a drone into the explosion at its unique endpoint."
	)

	var fully_expired_age := (
		CombatRobotSuicideDrone.DEPLOY_DELAY
		+ 1.0
		+ CombatRobotSuicideDrone.EXPLOSION_DURATION
		+ 0.5
	)
	now = float(mp_game.call("_get_net_time"))
	mp_game.net_projectile_fired(
		71004,
		projectile_type,
		0,
		Vector2(40, 50),
		Vector2.RIGHT,
		50,
		60.0,
		1.0,
		false,
		0,
		now - fully_expired_age,
		0
	)
	_expect(
		not projectile_coordinator.has_projectile(71004)
		and projectile_coordinator.has_projectile_record(71004),
		"A fully expired replicated drone must retire immediately while retaining its dedupe record."
	)
	var known_count_before_retry := int(
		projectile_coordinator.get_state_metrics().get("known_projectiles", -1)
	)
	mp_game.net_projectile_fired(
		71004,
		projectile_type,
		0,
		Vector2.ZERO,
		Vector2.UP,
		50,
		60.0,
		1.0,
		false,
		0,
		now,
		0
	)
	_expect(
		int(projectile_coordinator.get_state_metrics().get("known_projectiles", -1))
			== known_count_before_retry,
		"A duplicate packet for an expired drone must not resurrect a second visual."
	)

	for drone in [deploy_drone, flight_drone, explosion_drone]:
		if drone != null and is_instance_valid(drone):
			drone.retire()
	await process_frame
	test_root.client_view = false
	projectile_coordinator.unbind_runtime(runtime_stub)
	mp_game.game = null
	mp_game.queue_free()
	runtime_stub.free()
	await process_frame


func _test_multiplayer_and_runtime_source_contract() -> void:
	var mp_source := FileAccess.get_file_as_string(
		"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
	)
	_expect(
		mp_source.contains("COMBAT_ROBOT_SUICIDE_DRONE_TYPE")
		and mp_source.contains("COMBAT_ROBOT_SUICIDE_DRONE_ELITE_TYPE")
		and mp_source.contains("CombatRobotSuicideDrone.DEPLOY_DELAY")
		and mp_source.contains("CombatRobotSuicideDrone.EXPLOSION_DURATION")
		and mp_source.contains("_is_combat_robot_suicide_drone_type(projectile_type)"),
		(
			"MpProjectileCoordinator must share full three-stage elapsed compensation "
			+ "between the ordinary and elite drone types."
		)
	)
	_expect(
		NET_CONSTANTS.PROTOCOL_VERSION == 64
		and NET_CONSTANTS.CHANNEL_COUNT == 8,
		(
			"Protocol v64 must retain the v38 projectile, v39 shield-state, v63 resource, "
			+ "v40 slime semantics while isolating ninja boost visuals, ghost IDs, "
			+ "reconnect activation, P1E status confirmation, and the elite robot resource contract without adding channels."
		)
	)
	for source_path in [
		"res://scene/combat/runtime/wave_combat_runtime_base.gd",
		"res://scene/game_modes/tower_defense/prewarm/tower_defense_prewarmer_coordinator.gd",
	]:
		var compact_source := FileAccess.get_file_as_string(source_path)
		for whitespace in [" ", "\t", "\r", "\n"]:
			compact_source = compact_source.replace(whitespace, "")
		_expect(
			compact_source.contains(
				"session_object_pool.register_scene("
				+ "COMBAT_ROBOT_SUICIDE_DRONE_POOL_SCENE,0,384)"
			),
			"%s must lazily register the suicide-drone pool as 0/384." % source_path
		)
	var loading_source := FileAccess.get_file_as_string(
		"res://scene/loading/game_load_coordinator.gd"
	)
	_expect(
		loading_source.contains(
			"res://scene/enemy/mechanical_life/combat_robot_suicide_drone.tscn"
		),
		"GameLoadCoordinator must stage-load the suicide drone."
	)
	var registry_source := FileAccess.get_file_as_string(
		"res://scene/combat/combat_attack_registry.gd"
	)
	_expect(
		not registry_source.contains("combat_robot_suicide_drone"),
		"Host-only explosion damage must not consume a CombatAttackRegistry ID."
	)


func _spawn_operator(
	spawn_position: Vector2,
	player: Player
) -> CombatRobotDroneOperator:
	var operator := OPERATOR_SCENE.instantiate() as CombatRobotDroneOperator
	test_root.add_child(operator)
	operator.global_position = spawn_position
	operator.setup(OPERATOR_CONFIG, player, direct_pathfinder)
	operator.set_physics_process(false)
	return operator


func _spawn_drone(
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	flight_duration: float
) -> CombatRobotSuicideDrone:
	var drone := DRONE_SCENE.instantiate() as CombatRobotSuicideDrone
	test_root.add_child(drone)
	drone.global_position = spawn_position
	drone.setup(direction, damage, 60.0, flight_duration, 28.0, motion_system)
	return drone


func _spawn_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = spawn_position
	player.collision_layer = 2
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", 200)
	player.max_health = 200
	player.current_health = 200
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_plant(spawn_position: Vector2) -> AgaveCannon:
	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	test_root.add_child(plant)
	plant.global_position = spawn_position
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	return plant


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


func _reset_records() -> void:
	_cleanup_projectiles()
	test_root.registered_projectiles.clear()
	test_root.enemy_actions.clear()
	test_root.multiplayer_damage_requests.clear()


func _cleanup_projectiles() -> void:
	for record in test_root.registered_projectiles:
		var projectile := record.get("projectile") as Node
		if projectile != null and is_instance_valid(projectile):
			if projectile.has_method("retire"):
				projectile.call("retire")
			else:
				projectile.queue_free()
	test_root.registered_projectiles.clear()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
