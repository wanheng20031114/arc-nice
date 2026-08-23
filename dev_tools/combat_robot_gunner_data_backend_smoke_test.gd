extends SceneTree

const GUNNER_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner.tscn"
)
const GUNNER_ELITE_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite.tscn"
)
const GUNNER_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner.tres"
)
const GUNNER_ELITE_CONFIG := preload(
	"res://resources/config/enemies/combat_robot_gunner_elite.tres"
)
const GUNNER_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.tscn"
)
const GUNNER_ELITE_BULLET_SCENE := preload(
	"res://scene/enemy/mechanical_life/combat_robot_gunner_elite_bullet.tscn"
)
const ENEMY_SIMULATION_COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const FIXED_SEED := 8242026
const SOURCE_ENEMY_ID := 731
const WORLD_COLLISION_LAYER := 1


class CapturingGateway:
	extends MultiplayerGameplayGateway

	var next_projectile_id := 9101
	var legacy_shots: Array[Dictionary] = []
	var data_shots: Array[Dictionary] = []
	var enemy_actions: Array[Dictionary] = []
	var reject_data_registration := false


	func register_local_projectile(
		projectile: Node,
		projectile_type: StringName,
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		_pierces_enemies: bool = false,
		_target_peer_id: int = 0,
		_target_enemy_net_id: int = 0
	) -> void:
		var projectile_id := next_projectile_id
		next_projectile_id += 1
		var bullet := projectile as CapooAK47Bullet
		if bullet != null:
			bullet.setup_multiplayer(
				projectile_id,
				owner_peer_id,
				projectile_type
			)
		legacy_shots.append({
			"projectile_id": projectile_id,
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
		owner_peer_id: int,
		spawn_position: Vector2,
		direction: Vector2,
		damage: int,
		speed: float,
		lifetime: float,
		_damage_source_snapshot: DamageSourceSnapshot = null
	) -> int:
		if reject_data_registration:
			return 0
		var projectile_id := next_projectile_id
		if not service.assign_projectile_identity(handle, projectile_id):
			return 0
		next_projectile_id += 1
		var payload := [
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime,
			false,
			0,
			7.25,
			0,
		]
		data_shots.append({
			"projectile_id": projectile_id,
			"projectile_type": projectile_type,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
			"payload_size": payload.size(),
		})
		return projectile_id


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


var failures := PackedStringArray()
var saved_projectile_backend := CombatRobotGunner.ProjectileBackend.SHADOW


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	saved_projectile_backend = CombatRobotGunner.projectile_backend
	_expect(
		CombatRobotGunner.projectile_backend
		== CombatRobotGunner.ProjectileBackend.SHADOW,
		"Gunner production migration must default to SHADOW."
	)
	await _test_fixed_seed_backend_parity(
		GUNNER_SCENE,
		GUNNER_CONFIG,
		RapidFireSimulationService.Profile.GUNNER,
		"ordinary"
	)
	await _test_fixed_seed_backend_parity(
		GUNNER_ELITE_SCENE,
		GUNNER_ELITE_CONFIG,
		RapidFireSimulationService.Profile.GUNNER_ELITE,
		"elite"
	)
	await _test_shadow_observer(GUNNER_SCENE, GUNNER_CONFIG, "ordinary")
	await _test_shadow_observer(
		GUNNER_ELITE_SCENE,
		GUNNER_ELITE_CONFIG,
		"elite"
	)
	await _test_shadow_failure_does_not_cancel_legacy()
	await _test_data_host_rejection_and_client_boundary()
	await _test_data_muzzle_world_clearance()
	CombatRobotGunner.projectile_backend = saved_projectile_backend
	_finish()


func _test_fixed_seed_backend_parity(
	enemy_scene: PackedScene,
	enemy_config: CombatRobotGunnerConfig,
	expected_profile: RapidFireSimulationService.Profile,
	label: String
) -> void:
	var legacy_result := await _capture_complete_burst(
		enemy_scene,
		enemy_config,
		CombatRobotGunner.ProjectileBackend.LEGACY,
		"GunnerLegacy%s" % label
	)
	var data_result := await _capture_complete_burst(
		enemy_scene,
		enemy_config,
		CombatRobotGunner.ProjectileBackend.DATA,
		"GunnerData%s" % label
	)
	var legacy_shots := legacy_result.get("shots", []) as Array
	var data_shots := data_result.get("shots", []) as Array
	var data_records := data_result.get("data_records", []) as Array
	_expect(
		legacy_shots.size() == enemy_config.burst_count
		and data_shots.size() == enemy_config.burst_count
		and data_records.size() == enemy_config.burst_count,
		"%s gunner LEGACY/DATA must both commit the authored burst count."
		% label
	)
	_expect(
		int(legacy_result.get("live_nodes", -1)) == enemy_config.burst_count
		and int(data_result.get("live_nodes", -1)) == 0,
		"%s DATA authority must replace every live projectile Node with a handle."
		% label
	)
	_expect(
		int(legacy_result.get("random_state", -1))
		== int(data_result.get("random_state", -2)),
		"%s fixed-seed spread and pitch RNG order must match LEGACY exactly."
		% label
	)
	_expect(
		int(legacy_result.get("action_sequence", -1))
		== enemy_config.burst_count
		and int(data_result.get("action_sequence", -1))
		== enemy_config.burst_count,
		"%s successful shots must preserve the action sequence." % label
	)

	var compare_count := mini(
		legacy_shots.size(),
		mini(data_shots.size(), data_records.size())
	)
	for shot_index in range(compare_count):
		var legacy_shot := legacy_shots[shot_index] as Dictionary
		var data_shot := data_shots[shot_index] as Dictionary
		var data_record := data_records[shot_index] as Dictionary
		_expect(
			legacy_shot.get("projectile_type") == enemy_config.projectile_type
			and data_shot.get("projectile_type")
			== enemy_config.projectile_type
			and int(data_shot.get("payload_size", 0)) == 12,
			"%s shot %d must retain its projectile type and 12-field RPC."
			% [label, shot_index]
		)
		_expect(
			(legacy_shot.get("spawn_position") as Vector2).is_equal_approx(
				data_shot.get("spawn_position") as Vector2
			)
			and (legacy_shot.get("direction") as Vector2).is_equal_approx(
				data_shot.get("direction") as Vector2
			)
			and int(legacy_shot.get("damage", -1))
			== int(data_shot.get("damage", -2))
			and is_equal_approx(
				float(legacy_shot.get("speed", -1.0)),
				float(data_shot.get("speed", -2.0))
			)
			and is_equal_approx(
				float(legacy_shot.get("lifetime", -1.0)),
				float(data_shot.get("lifetime", -2.0))
			),
			"%s shot %d fixed-seed spawn, spread, damage, speed and lifetime differ."
			% [label, shot_index]
		)
		_expect(
			int(data_record.get("profile", -1)) == expected_profile
			and int(data_record.get("projectile_id", 0))
			== int(data_shot.get("projectile_id", -1))
			and int(data_record.get("world_check_interval", 0))
			== CapooAK47Bullet.WORLD_COLLISION_CHECK_INTERVAL_FRAMES
			and int(data_record.get("world_check_phase", -1))
			== (
				int(data_shot.get("projectile_id", 0))
				% CapooAK47Bullet.WORLD_COLLISION_CHECK_INTERVAL_FRAMES
			)
			and int(data_record.get("source_enemy_id", 0)) == SOURCE_ENEMY_ID
			and (data_record.get("position") as Vector2).is_equal_approx(
				data_shot.get("spawn_position") as Vector2
			)
			and (data_record.get("direction") as Vector2).is_equal_approx(
				data_shot.get("direction") as Vector2
			)
			and int(data_record.get("damage", -1))
			== int(data_shot.get("damage", -2)),
			"%s shot %d DATA record must preserve identity, profile and semantics."
			% [label, shot_index]
		)
	_compare_action_sequences(
		legacy_result.get("actions", []) as Array,
		data_result.get("actions", []) as Array,
		label
	)


func _capture_complete_burst(
	enemy_scene: PackedScene,
	enemy_config: CombatRobotGunnerConfig,
	backend: CombatRobotGunner.ProjectileBackend,
	fixture_name: String
) -> Dictionary:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		fixture_name
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway, enemy_scene, enemy_config)
	var service := _get_rapid_service(fixture)
	CombatRobotGunner.projectile_backend = backend
	enemy.random_generator.seed = FIXED_SEED
	_fire_complete_burst(enemy, enemy_config)

	var shots := (
		gateway.data_shots.duplicate(true)
		if backend == CombatRobotGunner.ProjectileBackend.DATA
		else gateway.legacy_shots.duplicate(true)
	)
	var result := {
		"shots": shots,
		"actions": gateway.enemy_actions.duplicate(true),
		"random_state": enemy.random_generator.state,
		"action_sequence": enemy.action_sequence,
		"live_nodes": _count_live_gunner_bullets(fixture),
		"data_records": _collect_data_records(service),
	}
	await _destroy_fixture(fixture)
	return result


func _test_shadow_observer(
	enemy_scene: PackedScene,
	enemy_config: CombatRobotGunnerConfig,
	label: String
) -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"GunnerShadow%s" % label
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway, enemy_scene, enemy_config)
	var service := _get_rapid_service(fixture)
	CombatRobotGunner.projectile_backend = CombatRobotGunner.ProjectileBackend.SHADOW
	_expect(
		bool(enemy.call(&"_fire_locked_bullet")),
		"%s SHADOW shot must retain legacy authority." % label
	)
	var handle := service.get_handle_at_stable_index(0)
	var expected_profile := (
		RapidFireSimulationService.Profile.GUNNER_ELITE
		if enemy_config.projectile_type
		== &"combat_robot_gunner_elite_bullet"
		else RapidFireSimulationService.Profile.GUNNER
	)
	_expect(
		_count_live_gunner_bullets(fixture) == 1
		and service.get_active_slot_count() == 1
		and service.get_slot_mode(handle)
		== RapidFireSimulationService.Mode.SHADOW
		and service.get_slot_profile(handle) == expected_profile
		and int(service.get_metrics().get("damage_applications", -1)) == 0,
		"%s SHADOW must pair one authoritative Node with one inert typed handle."
		% label
	)
	var bullet := _find_live_gunner_bullet(fixture)
	if bullet != null:
		bullet.retire(false)
	await physics_frame
	_expect(
		service.get_active_slot_count() == 0,
		"%s SHADOW retirement must release its observer handle." % label
	)
	await _destroy_fixture(fixture)


func _test_shadow_failure_does_not_cancel_legacy() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"GunnerRejectedShadow"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway, GUNNER_SCENE, GUNNER_CONFIG)
	var service := _get_rapid_service(fixture)
	service.prepare_for_runtime_teardown()
	CombatRobotGunner.projectile_backend = CombatRobotGunner.ProjectileBackend.SHADOW
	_expect(
		bool(enemy.call(&"_fire_locked_bullet"))
		and gateway.legacy_shots.size() == 1
		and _count_live_gunner_bullets(fixture) == 1
		and enemy.shadow_registration_failures == 1,
		"Rejected SHADOW observation must not cancel the legacy authority shot."
	)
	await _destroy_fixture(fixture)


func _test_data_host_rejection_and_client_boundary() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"GunnerRejectedData"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway, GUNNER_SCENE, GUNNER_CONFIG)
	var service := _get_rapid_service(fixture)
	gateway.reject_data_registration = true
	CombatRobotGunner.projectile_backend = CombatRobotGunner.ProjectileBackend.DATA
	_expect(
		not bool(enemy.call(&"_fire_locked_bullet"))
		and gateway.legacy_shots.is_empty()
		and gateway.data_shots.is_empty()
		and _count_live_gunner_bullets(fixture) == 0
		and service.get_active_slot_count() == 0
		and gateway.enemy_actions.is_empty(),
		"Rejected Host DATA identity must release the handle without Node fallback or action."
	)
	fixture.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	gateway.reject_data_registration = false
	_expect(
		not bool(enemy.call(&"_fire_locked_bullet"))
		and service.get_active_slot_count() == 0
		and _count_live_gunner_bullets(fixture) == 0,
		"CLIENT_VIEW must never create a gunner authority backend."
	)
	await _destroy_fixture(fixture)


func _test_data_muzzle_world_clearance() -> void:
	var fixture := _create_fixture(
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
		"GunnerDataMuzzleClamp"
	)
	var gateway := fixture.get_node(
		"MultiplayerGameplayGateway"
	) as CapturingGateway
	var enemy := _spawn_enemy(fixture, gateway, GUNNER_SCENE, GUNNER_CONFIG)
	var wall := StaticBody2D.new()
	wall.collision_layer = WORLD_COLLISION_LAYER
	wall.collision_mask = 0
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(2.0, 20.0)
	collision_shape.shape = rectangle
	wall.add_child(collision_shape)
	fixture.add_child(wall)
	wall.global_position = enemy.global_position + Vector2(8.0, 0.0)
	await physics_frame
	CombatRobotGunner.projectile_backend = CombatRobotGunner.ProjectileBackend.DATA
	_expect(
		bool(enemy.call(&"_fire_locked_bullet"))
		and gateway.data_shots.size() == 1,
		"DATA muzzle clamp fixture must fire one shot."
	)
	if gateway.data_shots.size() == 1:
		var spawn_position := gateway.data_shots[0].get(
			"spawn_position",
			Vector2.ZERO
		) as Vector2
		var wall_left_edge := wall.global_position.x - 1.0
		_expect(
			wall_left_edge - spawn_position.x >= 4.9
			and spawn_position.x > enemy.global_position.x,
			"DATA must preserve the authored five-pixel clearance before the muzzle wall."
		)
	await _destroy_fixture(fixture)


func _create_fixture(
	runtime_mode: CombatRuntimeBase.RuntimeMode,
	fixture_name: String
) -> PlayerTestCombatRuntime:
	var fixture := PlayerTestCombatRuntime.new()
	fixture.name = fixture_name
	fixture.runtime_mode = runtime_mode
	var motion_placeholder := fixture.get_node("CapooProjectileMotionSystem")
	fixture.remove_child(motion_placeholder)
	motion_placeholder.free()
	var motion_system := CapooProjectileMotionSystem.new()
	motion_system.name = "CapooProjectileMotionSystem"
	motion_system.process_physics_priority = 5
	fixture.add_child(motion_system)
	var gateway_placeholder := fixture.get_node("MultiplayerGameplayGateway")
	fixture.remove_child(gateway_placeholder)
	gateway_placeholder.free()
	var gateway := CapturingGateway.new()
	gateway.name = "MultiplayerGameplayGateway"
	fixture.add_child(gateway)
	fixture.add_child(ENEMY_SIMULATION_COORDINATOR_SCENE.instantiate())
	root.add_child(fixture)
	current_scene = fixture
	return fixture


func _spawn_enemy(
	fixture: PlayerTestCombatRuntime,
	gateway: CapturingGateway,
	enemy_scene: PackedScene,
	enemy_config: CombatRobotGunnerConfig
) -> CombatRobotGunner:
	var enemy := enemy_scene.instantiate() as CombatRobotGunner
	fixture.enemy_container.add_child(enemy)
	enemy.global_position = Vector2(160.0, 160.0)
	enemy.setup(
		enemy_config,
		null,
		fixture.get_node("GridPathfinder"),
		fixture
	)
	enemy.bind_gameplay_gateway(gateway)
	enemy.set_process(false)
	enemy.set_physics_process(false)
	enemy.locked_fire_direction = Vector2.RIGHT
	enemy.set_meta(&"net_id", SOURCE_ENEMY_ID)
	return enemy


func _fire_complete_burst(
	enemy: CombatRobotGunner,
	enemy_config: CombatRobotGunnerConfig
) -> void:
	enemy.combat_state = CombatRobotGunner.CombatState.BURST
	enemy.burst_shots_fired = 0
	enemy.burst_fire_time_left = 0.0
	for shot_index in range(enemy_config.burst_count):
		enemy.call(
			&"_update_burst",
			0.0 if shot_index == 0 else enemy_config.burst_fire_interval
		)


func _get_rapid_service(
	fixture: PlayerTestCombatRuntime
) -> RapidFireSimulationService:
	var services := fixture.get_enemy_combat_services()
	return services.get_rapid_fire_simulation_service()


func _collect_data_records(
	service: RapidFireSimulationService
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for stable_index in range(service.get_dense_record_count()):
		var handle := service.get_handle_at_stable_index(stable_index)
		if handle <= RapidFireSimulationService.INVALID_HANDLE:
			continue
		records.append({
			"profile": service.get_slot_profile(handle),
			"projectile_id": service.get_projectile_id(handle),
			"world_check_interval": service.get_world_check_interval(handle),
			"world_check_phase": service.get_world_check_phase(handle),
			"source_enemy_id": service.get_source_enemy_id(handle),
			"position": service.get_position(handle),
			"direction": service.get_direction(handle),
			"damage": service.get_damage(handle),
		})
	return records


func _compare_action_sequences(
	legacy_actions: Array,
	data_actions: Array,
	label: String
) -> void:
	_expect(
		legacy_actions.size() == data_actions.size()
		and legacy_actions.size() == GUNNER_CONFIG.burst_count,
		"%s LEGACY/DATA action counts must match." % label
	)
	for action_index in range(mini(legacy_actions.size(), data_actions.size())):
		var legacy_action := legacy_actions[action_index] as Dictionary
		var data_action := data_actions[action_index] as Dictionary
		_expect(
			legacy_action.get("net_id") == data_action.get("net_id")
			and legacy_action.get("action_name") == data_action.get("action_name")
			and (legacy_action.get("direction") as Vector2).is_equal_approx(
				data_action.get("direction") as Vector2
			)
			and (legacy_action.get("action_position") as Vector2).is_equal_approx(
				data_action.get("action_position") as Vector2
			)
			and int(legacy_action.get("action_id", 0)) == action_index + 1
			and int(data_action.get("action_id", 0)) == action_index + 1,
			"%s action %d order or payload differs across backends."
			% [label, action_index]
		)


func _count_live_gunner_bullets(fixture: Node) -> int:
	var count := 0
	for child in fixture.get_children():
		var bullet := child as CombatRobotGunnerBullet
		if bullet != null and bullet.pool_active and not bullet.has_hit:
			count += 1
	return count


func _find_live_gunner_bullet(
	fixture: Node
) -> CombatRobotGunnerBullet:
	for child in fixture.get_children():
		var bullet := child as CombatRobotGunnerBullet
		if bullet != null and bullet.pool_active and not bullet.has_hit:
			return bullet
	return null


func _destroy_fixture(fixture: PlayerTestCombatRuntime) -> void:
	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("COMBAT_ROBOT_GUNNER_DATA_BACKEND_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
