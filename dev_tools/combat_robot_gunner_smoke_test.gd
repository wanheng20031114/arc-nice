extends SceneTree

const GUNNER_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner.tscn"
)
const BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
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
const AK_FIRE_AUDIO := preload(
	"res://resources/audio/capoo_ak47_fire.wav"
)
const ENEMY_SIMULATION_COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const WORLD_COLLISION_LAYER := 1
const WATER_TERRAIN_COLLISION_LAYER := 1 << 11
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


class GunnerTestGateway:
	extends MultiplayerGameplayGateway

	var enemy_actions: Array[Dictionary] = []
	var registered_projectiles: Array[Dictionary] = []
	var burst_descriptors: Array[PackedByteArray] = []
	var released_reservations := PackedInt64Array()
	var next_projectile_id := 12001
	var reject_next_data_registration := false

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

	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		_owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		_pierces_enemies: bool = false,
		_target_peer_id: int = 0,
		_target_enemy_net_id: int = 0,
		_damage_source_snapshot: DamageSourceSnapshot = null
	) -> void:
		registered_projectiles.append({
			"projectile": projectile,
			"service": null,
			"handle": RapidFireSimulationService.INVALID_HANDLE,
			"projectile_type": projectile_type,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
		})


	func register_local_data_projectile(
		service: RapidFireSimulationService,
		handle: int,
		projectile_type: StringName,
		_owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		_damage_source_snapshot: DamageSourceSnapshot = null
	) -> int:
		if reject_next_data_registration:
			reject_next_data_registration = false
			return 0
		var projectile_id := next_projectile_id
		if not service.assign_projectile_identity(handle, projectile_id):
			return 0
		next_projectile_id += 1
		registered_projectiles.append({
			"projectile": null,
			"service": service,
			"handle": handle,
			"projectile_id": projectile_id,
			"projectile_type": projectile_type,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
		})
		return projectile_id


	func reserve_enemy_rapid_fire_projectile_ids(
		count: int
	) -> PackedInt64Array:
		var ids := PackedInt64Array()
		for _shot_index in range(count):
			ids.append(next_projectile_id)
			next_projectile_id += 1
		return ids


	func release_enemy_rapid_fire_projectile_ids(
		projectile_ids: PackedInt64Array
	) -> bool:
		released_reservations.append_array(projectile_ids)
		return true


	func attach_reserved_enemy_rapid_fire_projectile(
		service: RapidFireSimulationService,
		handle: int,
		projectile_id: int,
		projectile_type: StringName,
		_owner_peer_id: int,
		damage: int,
		lifetime: float,
		damage_source_snapshot: DamageSourceSnapshot = null
	) -> bool:
		if reject_next_data_registration:
			reject_next_data_registration = false
			return false
		if not service.assign_projectile_identity(handle, projectile_id):
			return false
		registered_projectiles.append({
			"projectile": null,
			"service": service,
			"handle": handle,
			"projectile_id": projectile_id,
			"projectile_type": projectile_type,
			"spawn_position": service.get_position(handle),
			"direction": service.get_direction(handle),
			"damage": damage,
			"speed": service.get_speed(handle),
			"lifetime": lifetime,
			"damage_source_snapshot": damage_source_snapshot,
		})
		return true


	func broadcast_enemy_rapid_fire_burst(
		descriptor: PackedByteArray
	) -> bool:
		burst_descriptors.append(descriptor)
		return true


class GunnerTestRoot:
	extends PlayerTestCombatRuntime

	var recording_gateway: GunnerTestGateway = null
	var enemy_actions: Array[Dictionary]:
		get:
			return recording_gateway.enemy_actions
	var registered_projectiles: Array[Dictionary]:
		get:
			return recording_gateway.registered_projectiles
	var burst_descriptors: Array[PackedByteArray]:
		get:
			return recording_gateway.burst_descriptors


	func _init() -> void:
		super()
		runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		var motion_placeholder := get_node("CapooProjectileMotionSystem")
		remove_child(motion_placeholder)
		motion_placeholder.free()
		var motion_system := CapooProjectileMotionSystem.new()
		motion_system.name = "CapooProjectileMotionSystem"
		add_child(motion_system)

		var gateway_placeholder := get_node("MultiplayerGameplayGateway")
		remove_child(gateway_placeholder)
		gateway_placeholder.free()
		recording_gateway = GunnerTestGateway.new()
		recording_gateway.name = "MultiplayerGameplayGateway"
		add_child(recording_gateway)
		add_child(ENEMY_SIMULATION_COORDINATOR_SCENE.instantiate())


var failures: Array[String] = []
var test_root: GunnerTestRoot
var direct_pathfinder: DirectPathfinder


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(
		CombatRobotGunner.projectile_backend
		== CombatRobotGunner.ProjectileBackend.DATA,
		"Production gunner backend must default to DATA."
	)
	test_root = GunnerTestRoot.new()
	test_root.name = "CombatRobotGunnerSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	direct_pathfinder = DirectPathfinder.new()
	test_root.add_child(direct_pathfinder)

	_test_resource_and_scene_contract()
	await _test_player_and_plant_target_contract()
	await _test_successful_burst_scheduler_and_spread()
	await _test_locked_target_tracking_and_movement()
	await _test_muzzle_world_clamp_and_water_ignore()
	await _test_touch_damage_during_burst()
	await _test_death_cancels_remaining_burst()
	await _test_proxy_composite_phase_contract()

	_cleanup_registered_projectiles()
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(3):
		await process_frame

	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		GUNNER_CONFIG is CombatRobotGunnerConfig,
		"Gunner config must use CombatRobotGunnerConfig."
	)
	_expect(
		GUNNER_CONFIG.display_name == "持枪战斗机器人",
		"Display name mismatch."
	)
	_expect(GUNNER_CONFIG.enemy_scene == GUNNER_SCENE, "Enemy scene binding mismatch.")
	_expect(
		GUNNER_CONFIG.projectile_scene == BULLET_SCENE,
		"Projectile scene binding mismatch."
	)
	_expect(GUNNER_CONFIG.max_health == 180, "Maximum health must be 180.")
	_expect(GUNNER_CONFIG.attack_damage == 35, "Attack damage must be 35.")
	_expect(GUNNER_CONFIG.physical_defense == 10, "Physical defense must be 10.")
	_expect(GUNNER_CONFIG.magic_defense == 15, "Magic defense must be 15.")
	_expect(is_equal_approx(GUNNER_CONFIG.move_speed, 30.0), "Move speed must be 30.")
	_expect(GUNNER_CONFIG.home_damage == 2, "Home damage must be 2.")
	_expect(GUNNER_CONFIG.xirang_kill_reward == 10, "Kill reward must be 10.")
	_expect(
		GUNNER_CONFIG.category_tags == PackedStringArray(["mechanical_life"]),
		"Gunner must carry only the mechanical_life category."
	)
	_expect(GUNNER_CONFIG.drop_table != null, "Default drop table must remain assigned.")
	_expect(GUNNER_CONFIG.fire_animation_name == &"fire", "Fire preview animation mismatch.")
	_expect(GUNNER_CONFIG.fire_walk_animation_name == &"fire_walk", "Composite animation mismatch.")
	_expect(is_equal_approx(GUNNER_CONFIG.attack_range, 84.0), "Attack range must be 84.")
	_expect(is_equal_approx(GUNNER_CONFIG.stop_distance, 24.0), "Stop distance must be 24.")
	_expect(GUNNER_CONFIG.burst_count == 12, "Burst must contain 12 successful shots.")
	_expect(
		is_equal_approx(GUNNER_CONFIG.burst_fire_interval, 0.08),
		"Burst fire interval must be 0.08 seconds."
	)
	_expect(
		is_equal_approx(GUNNER_CONFIG.spread_angle_degrees, 5.0),
		"Spread must be plus or minus 5 degrees."
	)
	_expect(
		is_equal_approx(GUNNER_CONFIG.burst_move_speed_multiplier, 0.5),
		"Burst movement multiplier must be 0.5."
	)
	_expect(
		is_equal_approx(GUNNER_CONFIG.attack_cooldown, 2.5),
		"Attack cooldown must be 2.5 seconds."
	)
	_expect(is_equal_approx(GUNNER_CONFIG.projectile_speed, 80.0), "Bullet speed must be 80.")
	_expect(
		is_equal_approx(GUNNER_CONFIG.projectile_lifetime, 1.5),
		"Bullet lifetime must be 1.5 seconds."
	)
	_expect(GUNNER_CONFIG.attack_audio_stream == AK_FIRE_AUDIO, "AK fire audio must be reused.")

	var gunner := GUNNER_SCENE.instantiate() as CombatRobotGunner
	_expect(gunner != null, "Gunner scene must instantiate CombatRobotGunner.")
	if gunner == null:
		return
	var sprite := gunner.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var muzzle := gunner.get_node_or_null("Muzzle") as Marker2D
	var attack_audio := gunner.get_node_or_null("AttackAudio") as AudioStreamPlayer2D
	var body_shape := gunner.get_node("CollisionShape2D") as CollisionShape2D
	var touch_shape := gunner.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	_expect(sprite != null, "Scene must own its main AnimatedSprite2D.")
	_expect(muzzle != null and muzzle.position == Vector2(11, 2), "Muzzle must be authored at (11, 2).")
	_expect(gunner.get_node_or_null("MuzzleFlash") == null, "Atlas frames must replace polygon muzzle flash.")
	_expect(
		attack_audio != null
		and attack_audio.bus == &"SFX"
		and attack_audio.stream == AK_FIRE_AUDIO,
		"AttackAudio must use the SFX bus and AK stream."
	)
	_expect(gunner.combat_sense_update_interval_frames == 3, "Sensing must wait at most two ticks.")
	_expect(
		body_shape.shape is RectangleShape2D
		and (body_shape.shape as RectangleShape2D).size == Vector2(8, 17),
		"Body collision must match the box chassis."
	)
	_expect(
		touch_shape.shape is RectangleShape2D
		and (touch_shape.shape as RectangleShape2D).size == Vector2(8, 17)
		and touch_shape.shape != body_shape.shape,
		"Touch collision must use an independent box shape."
	)
	if sprite != null and sprite.sprite_frames != null:
		_expect(sprite.sprite_frames.get_frame_count(&"move") == 8, "Move must have 8 frames.")
		_expect(sprite.sprite_frames.get_frame_count(&"fire") == 4, "Fire preview must have 4 frames.")
		_expect(sprite.sprite_frames.get_frame_count(&"fire_walk") == 32, "Fire matrix must be 4x8.")
		_expect(sprite.sprite_frames.get_animation_speed(&"fire_walk") == 25.0, "Upper phase must be authored at 25 FPS.")
	_expect(bool(gunner.call("_uses_inherited_touch_damage")), "Body touch damage must remain enabled.")
	_expect(gunner.can_target_water_plant_objectives(), "Ranged gunner must target water plants.")
	gunner.free()


func _test_player_and_plant_target_contract() -> void:
	var player := _spawn_player(Vector2(60.0, 0.0))
	var gunner := _spawn_gunner(Vector2.ZERO, player, direct_pathfinder)
	_expect(
		bool(gunner.call("_try_start_burst", player)),
		"A live player inside 84 pixels must commit immediately."
	)
	gunner.call("_cancel_burst", true)
	player.global_position = Vector2(84.1, 0.0)
	_expect(
		not bool(gunner.call("_try_start_burst", player)),
		"A live player beyond 84 pixels must not commit a burst."
	)
	var ordinary_objective := Node2D.new()
	test_root.add_child(ordinary_objective)
	ordinary_objective.global_position = Vector2(60.0, 0.0)
	gunner.set_target_player(null)
	gunner.set_objective_target(ordinary_objective)
	_expect(
		not bool(gunner.call("_try_start_burst", ordinary_objective)),
		"Home and ordinary Node2D objectives must never trigger a burst."
	)

	var plant := AGAVE_SCENE.instantiate() as AgaveCannon
	test_root.add_child(plant)
	plant.global_position = Vector2(60.0, 0.0)
	plant.setup(AGAVE_CONFIG, null, [Vector2i.ZERO])
	plant.attack_timer.stop()
	gunner.set_target_player(null)
	gunner.set_objective_target(plant)
	_expect(
		bool(gunner.call("_try_start_burst", plant)),
		"A live plant inside 84 pixels must be a valid burst target."
	)
	_expect(gunner.burst_target == plant, "Burst must retain the committed plant reference.")
	gunner.queue_free()
	plant.queue_free()
	player.queue_free()
	ordinary_objective.queue_free()
	await process_frame


func _test_successful_burst_scheduler_and_spread() -> void:
	_cleanup_registered_projectiles()
	test_root.enemy_actions.clear()
	EnemyAttackAudioLimiter.reset_metrics()
	var player := _spawn_player(Vector2(60.0, 0.0))
	var gunner := _spawn_gunner(Vector2.ZERO, player, direct_pathfinder)
	gunner.set_objective_target(null)
	gunner.random_generator.seed = 424242
	gunner.set_meta(&"net_id", 77)
	var sprite := gunner.get_node("AnimatedSprite2D") as AnimatedSprite2D
	sprite.play(&"move")
	sprite.pause()
	sprite.frame = 3
	sprite.frame_progress = 0.5

	_expect(bool(gunner.call("_try_start_burst", player)), "Burst fixture failed to commit.")
	_expect(
		gunner.combat_state == CombatRobotGunner.CombatState.BURST
		and gunner.burst_target == player
		and gunner.locked_fire_direction.is_equal_approx(Vector2.RIGHT),
		"Commit must enter BURST and lock the target plus base direction."
	)
	_expect(
		is_equal_approx(gunner.fire_leg_phase, 3.5),
		"Entering BURST must inherit the move leg phase."
	)

	test_root.recording_gateway.reject_next_data_registration = true
	gunner.call("_update_burst", 0.0)
	_expect(
		gunner.burst_shots_fired == 0
		and is_zero_approx(gunner.burst_fire_time_left)
		and test_root.registered_projectiles.is_empty(),
		"A rejected DATA identity must stay pending without consuming a shot."
	)

	gunner.call("_update_burst", 0.0)
	_expect(
		gunner.burst_shots_fired == 1
		and test_root.registered_projectiles.size() == 1,
		"The retry must emit the immediate first successful shot."
	)
	_expect(
		sprite.animation == &"fire_walk"
		and not sprite.is_playing()
		and sprite.frame == 3,
		"First shot must manually select upper F0 with the inherited leg phase."
	)

	player.global_position = Vector2(0.0, -60.0)
	gunner.call("_update_burst", 0.881)
	_expect(
		test_root.registered_projectiles.size() == 12
		and gunner.burst_shots_fired == 12,
		"A hitch update must catch up to exactly 12 successful shots."
	)
	_expect(
		gunner.combat_state == CombatRobotGunner.CombatState.TRACKING_COOLDOWN
		and is_equal_approx(gunner.attack_cooldown_left, 2.5)
		and gunner.burst_target == null,
		"The 12th shot must transition BURST to a 2.5-second tracking cooldown."
	)
	_expect(
		sprite.frame / 8 == 2,
		"The even action sequence must leave the final successful shot on upper F2."
	)

	var saw_distinct_spread := false
	var first_direction := Vector2.ZERO
	var caught_up_spawn_position := Vector2.ZERO
	for shot_index in range(test_root.registered_projectiles.size()):
		var shot := test_root.registered_projectiles[shot_index]
		var shot_direction := shot.direction as Vector2
		if shot_index == 0:
			first_direction = shot_direction
		else:
			saw_distinct_spread = saw_distinct_spread or not shot_direction.is_equal_approx(first_direction)
		var spread_degrees := absf(rad_to_deg(Vector2.RIGHT.angle_to(shot_direction)))
		_expect(spread_degrees <= 5.0 + EPSILON, "Every Host-sampled shot must stay inside +/-5 degrees.")
		_expect(is_equal_approx(shot_direction.length(), 1.0), "Every shot direction must be normalized.")
		_expect(shot.projectile_type == &"combat_robot_gunner_bullet", "Projectile network type mismatch.")
		_expect(shot.damage == 35, "Each projectile must snapshot 35 outgoing damage.")
		_expect(is_equal_approx(shot.speed, 80.0), "Projectile registration speed mismatch.")
		_expect(is_equal_approx(shot.lifetime, 1.5), "Projectile registration lifetime mismatch.")
		if shot_index == 1:
			caught_up_spawn_position = shot.spawn_position as Vector2
		elif shot_index > 1:
			_expect(
				(shot.spawn_position as Vector2).is_equal_approx(caught_up_spawn_position),
				"Caught-up shots must use the current shooter position without historical interpolation."
			)
	_expect(saw_distinct_spread, "Independent Host spread samples must not all be identical.")
	_expect(
		test_root.enemy_actions.is_empty()
		and test_root.burst_descriptors.size() == 1,
		"A successful DATA burst must replace per-shot actions with one compact descriptor."
	)
	var decoded_descriptor := (
		EnemyRapidFireNetworkCodec.decode_burst(test_root.burst_descriptors[0])
		if test_root.burst_descriptors.size() == 1
		else {}
	)
	_expect(
		bool(decoded_descriptor.get("valid", false))
		and int(decoded_descriptor.get("count", 0)) == 12
		and int(decoded_descriptor.get("source_enemy_id", 0)) == 77
		and int(decoded_descriptor.get("action_id", 0)) == 1,
		"The compact burst descriptor must preserve count, source net id and action revision."
	)
	var audio_metrics := EnemyAttackAudioLimiter.get_metrics()
	_expect(audio_metrics.rapid_requests == 6, "A 12-shot burst must use the AK rapid-fire limiter cadence.")

	var exit_leg_phase := gunner.fire_leg_phase
	gunner.call("_physics_process", 0.08)
	var expected_exit_frame := floori(exit_leg_phase)
	var expected_exit_progress := exit_leg_phase - floorf(exit_leg_phase)
	_expect(
		sprite.animation == &"move"
		and sprite.frame == expected_exit_frame
		and is_equal_approx(sprite.frame_progress, expected_exit_progress),
		"Leaving the final 0.08-second fire visual must restore the inherited leg phase."
	)
	gunner.queue_free()
	player.queue_free()
	_cleanup_registered_projectiles()
	await process_frame


func _test_locked_target_tracking_and_movement() -> void:
	var original_player := _spawn_player(Vector2(60.0, 0.0))
	var replacement_player := _spawn_player(Vector2(120.0, 0.0))
	var home_target := Node2D.new()
	test_root.add_child(home_target)
	home_target.global_position = Vector2(140.0, 0.0)
	var gunner := _spawn_gunner(Vector2.ZERO, original_player, direct_pathfinder)
	_expect(bool(gunner.call("_try_start_burst", original_player)), "Tracking fixture failed to commit.")
	gunner.burst_fire_time_left = 100.0
	gunner.set_objective_target(home_target)
	gunner.set_target_player(replacement_player)
	original_player.global_position = Vector2(-60.0, -60.0)
	gunner.call("_clear_cached_navigation_move_direction")
	gunner.set_physics_process(true)

	var followed_original := await _wait_for_velocity_x(gunner, -1.0, 8)
	_expect(followed_original, "BURST navigation must follow the committed target's live position.")
	_expect(
		absf(gunner.velocity.length() - 15.0) <= 0.05,
		"Diagonal BURST tracking must preserve a half-speed magnitude of 15."
	)
	_expect(
		absf(gunner.velocity.x) > 0.1 and absf(gunner.velocity.y) > 0.1,
		"The half-speed fixture must exercise actual diagonal navigation."
	)
	_expect(
		gunner.burst_target == original_player and not gunner.facing_left,
		"A replacement preferred target must not replace the burst target or fixed firing facing."
	)
	gunner.add_move_speed_modifier(99101, 0.4)
	var slowed_during_burst := await _wait_for_speed(gunner, 6.0, 2)
	_expect(
		slowed_during_burst,
		"A live move-speed modifier must change BURST speed on the next physics frame."
	)
	gunner.remove_move_speed_modifier(99101)
	var restored_during_burst := await _wait_for_speed(gunner, 15.0, 2)
	_expect(
		restored_during_burst,
		"Removing the live modifier must immediately restore half-speed tracking."
	)

	original_player.global_position = gunner.global_position + Vector2(-20.0, 0.0)
	await physics_frame
	_expect(gunner.velocity == Vector2.ZERO, "Committed target inside 24 pixels must stop movement.")
	_expect(
		is_zero_approx(gunner.fire_leg_phase)
		and (gunner.animated_sprite.frame % 8) == 0,
		"The fire_walk leg phase must be fixed at zero inside stop distance."
	)

	original_player.is_dead = true
	var resumed_objective := await _wait_for_velocity_x(gunner, 1.0, 8)
	_expect(
		resumed_objective
		and gunner.burst_target == null
		and absf(gunner.velocity.length() - 15.0) <= 0.05,
		"A dead committed target must resume half-speed navigation toward the ordinary objective."
	)
	_expect(not gunner.facing_left, "Movement fallback must not rotate the locked firing facing.")

	gunner.call("_finish_burst")
	var resumed_full_speed := await _wait_for_speed(gunner, 30.0, 8)
	_expect(
		resumed_full_speed
		and gunner.combat_state == CombatRobotGunner.CombatState.TRACKING_COOLDOWN,
		"After BURST, TRACKING_COOLDOWN must restore full navigation speed."
	)
	gunner.queue_free()
	original_player.queue_free()
	replacement_player.queue_free()
	home_target.queue_free()
	await process_frame


func _test_touch_damage_during_burst() -> void:
	var previous_runtime_mode := test_root.runtime_mode
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	var player := _spawn_player(Vector2(60.0, 0.0))
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	var gunner := _spawn_gunner(Vector2.ZERO, player, direct_pathfinder)
	_expect(bool(gunner.call("_try_start_burst", player)), "Touch fixture failed to commit.")
	gunner.burst_fire_time_left = 100.0
	var health_before_touch := player.current_health
	gunner.call("_on_touch_damage_area_body_entered", player)
	_expect(
		health_before_touch - player.current_health == 35,
		"Body contact during BURST must deal the configured 35 damage."
	)
	_expect(
		int(gunner.call("_get_touch_damage_type"))
			== EnemyConfig.DamageType.PHYSICAL,
		"Body contact must use the physical damage channel."
	)
	_expect(
		gunner.combat_state == CombatRobotGunner.CombatState.BURST
		and gunner.burst_target == player,
		"Body contact must not cancel or retarget the committed burst."
	)
	gunner.queue_free()
	player.queue_free()
	test_root.runtime_mode = previous_runtime_mode
	await process_frame


func _test_muzzle_world_clamp_and_water_ignore() -> void:
	_cleanup_registered_projectiles()
	var player := _spawn_player(Vector2(60.0, 0.0))
	var gunner := _spawn_gunner(Vector2.ZERO, player, direct_pathfinder)
	gunner.set_meta(&"net_id", 79)
	gunner.set_objective_target(null)
	var world_wall := _spawn_wall(
		Vector2(8.0, 0.0),
		Vector2(2.0, 20.0),
		WORLD_COLLISION_LAYER
	)
	await physics_frame
	_expect(bool(gunner.call("_try_start_burst", player)), "World clamp fixture failed to commit.")
	gunner.call("_update_burst", 0.0)
	_expect(test_root.registered_projectiles.size() == 1, "World clamp fixture must fire once.")
	if test_root.registered_projectiles.size() == 1:
		var clamped_position := test_root.registered_projectiles[0].spawn_position as Vector2
		_expect(
			clamped_position.x < 7.0,
			"World layer between center and Muzzle must clamp spawn before the wall."
		)
	gunner.call("_cancel_burst", true)
	_cleanup_registered_projectiles()
	world_wall.queue_free()
	await physics_frame

	var water_wall := _spawn_wall(
		Vector2(8.0, 0.0),
		Vector2(2.0, 20.0),
		WATER_TERRAIN_COLLISION_LAYER
	)
	await physics_frame
	_expect(bool(gunner.call("_try_start_burst", player)), "Water ignore fixture failed to commit.")
	gunner.call("_update_burst", 0.0)
	_expect(test_root.registered_projectiles.size() == 1, "Water ignore fixture must fire once.")
	if test_root.registered_projectiles.size() == 1:
		var spawn_position := test_root.registered_projectiles[0].spawn_position as Vector2
		_expect(
			spawn_position.is_equal_approx(gunner.muzzle.global_position),
			"WaterTerrain must not clamp the real Muzzle spawn position."
		)
	gunner.queue_free()
	player.queue_free()
	water_wall.queue_free()
	_cleanup_registered_projectiles()
	await process_frame


func _test_death_cancels_remaining_burst() -> void:
	_cleanup_registered_projectiles()
	test_root.enemy_actions.clear()
	var player := _spawn_player(Vector2(60.0, 0.0))
	var gunner := _spawn_gunner(Vector2.ZERO, player, direct_pathfinder)
	gunner.set_meta(&"net_id", 80)
	gunner.set_objective_target(null)
	_expect(bool(gunner.call("_try_start_burst", player)), "Death fixture failed to commit.")
	gunner.call("_update_burst", 0.0)
	gunner.call("_update_burst", 0.161)
	var projectile_count_before_death := test_root.registered_projectiles.size()
	var action_count_before_death := test_root.enemy_actions.size()
	gunner.call("_die")
	gunner.call("_update_burst", 2.0)
	_expect(
		gunner.is_dead
		and gunner.combat_state == CombatRobotGunner.CombatState.TRACKING_READY
		and gunner.burst_target == null,
		"Death must cancel the active burst and clear its retained target."
	)
	_expect(
		test_root.registered_projectiles.size() == projectile_count_before_death
		and test_root.enemy_actions.size() == action_count_before_death,
		"Death must prevent every future scheduled projectile and fire action."
	)
	for record in test_root.registered_projectiles:
		var service := record.get("service") as RapidFireSimulationService
		var handle := int(record.get(
			"handle",
			RapidFireSimulationService.INVALID_HANDLE
		))
		_expect(
			service != null and service.is_handle_live(handle),
			"DATA handles fired before shooter death must remain live."
		)
	gunner.queue_free()
	player.queue_free()
	_cleanup_registered_projectiles()
	await process_frame


func _test_proxy_composite_phase_contract() -> void:
	var player := _spawn_player(Vector2(60.0, 0.0))
	var proxy := _spawn_gunner(Vector2.ZERO, player, direct_pathfinder)
	proxy.configure_multiplayer_proxy()
	proxy.velocity = Vector2.RIGHT * 15.0
	var sprite := proxy.animated_sprite
	sprite.play(&"move")
	sprite.pause()
	sprite.frame = 5
	sprite.frame_progress = 0.25

	proxy.play_multiplayer_enemy_action(
		CombatRobotGunner.ACTION_FIRE,
		Vector2.RIGHT,
		1
	)
	_expect(
		sprite.animation == &"fire_walk"
		and not sprite.is_playing()
		and sprite.frame == 5,
		"Odd proxy action must select upper F0 and inherit the leg phase."
	)
	proxy.play_multiplayer_enemy_action(
		CombatRobotGunner.ACTION_FIRE,
		Vector2.LEFT,
		2
	)
	_expect(
		sprite.frame / 8 == 2
		and proxy.facing_left
		and proxy.muzzle.position == Vector2(-14, 1),
		"Even proxy action must select F2 and mirror the Muzzle."
	)
	var even_frame := sprite.frame
	proxy.play_multiplayer_enemy_action(
		CombatRobotGunner.ACTION_FIRE,
		Vector2.RIGHT,
		1
	)
	_expect(sprite.frame == even_frame, "A stale proxy action must be ignored.")

	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotGunner.ACTION_FIRE,
		Vector2.RIGHT,
		proxy.global_position,
		3,
		0.04
	)
	_expect(
		sprite.frame / 8 == 1,
		"A 0.04-second-late odd action must advance F0 by one 25 FPS upper phase."
	)
	proxy.call("_process", 0.04)
	_expect(
		sprite.animation == &"move" and not proxy.proxy_fire_visual_active,
		"Proxy fire visual must restore before the 0.08-second phase wrap."
	)
	proxy.play_multiplayer_enemy_action_with_context(
		CombatRobotGunner.ACTION_FIRE,
		Vector2.RIGHT,
		proxy.global_position,
		4,
		0.08
	)
	_expect(
		sprite.animation == &"move" and not proxy.proxy_fire_visual_active,
		"An already-expired 0.08-second proxy flash must not replay."
	)
	proxy.play_multiplayer_enemy_action(
		CombatRobotGunner.ACTION_FIRE,
		Vector2.RIGHT,
		5
	)
	proxy.set_multiplayer_proxy_visual_active(false)
	_expect(
		sprite.animation == &"move" and not proxy.proxy_fire_visual_active,
		"Proxy culling must clear the transient composite fire visual."
	)
	proxy.queue_free()
	player.queue_free()
	await process_frame


func _spawn_gunner(
	spawn_position: Vector2,
	player: Player,
	shared_pathfinder: Node
) -> CombatRobotGunner:
	var gunner := GUNNER_SCENE.instantiate() as CombatRobotGunner
	test_root.add_child(gunner)
	gunner.global_position = spawn_position
	gunner.setup(GUNNER_CONFIG, player, shared_pathfinder, test_root)
	gunner.set_physics_process(false)
	return gunner


func _spawn_player(spawn_position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = spawn_position
	return player


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


func _wait_for_velocity_x(
	gunner: CombatRobotGunner,
	direction_sign: float,
	max_frames: int
) -> bool:
	for _frame_index in range(max_frames):
		await physics_frame
		if gunner.velocity.x * direction_sign > 0.1:
			return true
	return false


func _wait_for_speed(
	gunner: CombatRobotGunner,
	expected_speed: float,
	max_frames: int
) -> bool:
	for _frame_index in range(max_frames):
		await physics_frame
		if absf(gunner.velocity.length() - expected_speed) <= 0.05:
			return true
	return false


func _cleanup_registered_projectiles() -> void:
	for record in test_root.registered_projectiles:
		var projectile := record.get("projectile") as Node
		if projectile != null and is_instance_valid(projectile):
			projectile.queue_free()
		var service := record.get("service") as RapidFireSimulationService
		var handle := int(record.get(
			"handle",
			RapidFireSimulationService.INVALID_HANDLE
		))
		if service != null and service.is_handle_live(handle):
			service.release_projectile(handle)
	test_root.registered_projectiles.clear()
	test_root.burst_descriptors.clear()
	test_root.recording_gateway.reject_next_data_registration = false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
