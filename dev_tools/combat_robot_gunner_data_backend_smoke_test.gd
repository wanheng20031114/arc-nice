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
const ENEMY_SIMULATION_COORDINATOR_SCENE := preload(
	"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
)
const RAPID_FIRE_CODEC := preload(
	"res://scene/multiplayer/projectile/enemy_rapid_fire_network_codec.gd"
)
const FIXED_SEED := 8242026
const SOURCE_ENEMY_ID := 731
const WORLD_COLLISION_LAYER := 1


class CapturingGateway:
	extends MultiplayerGameplayGateway

	var next_projectile_id := 9101
	var node_shots: Array[Dictionary] = []
	var data_shots: Array[Dictionary] = []
	var burst_descriptors: Array[PackedByteArray] = []
	var released_reservations := PackedInt64Array()
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
		_target_enemy_net_id: int = 0,
		_damage_source_snapshot: DamageSourceSnapshot = null
	) -> void:
		var projectile_id := next_projectile_id
		next_projectile_id += 1
		node_shots.append({
			"projectile_id": projectile_id,
			"projectile_type": projectile_type,
			"spawn_position": spawn_position,
			"direction": direction,
			"damage": damage,
			"speed": speed,
			"lifetime": lifetime,
		})


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
		if reject_data_registration:
			return false
		if not service.assign_projectile_identity(handle, projectile_id):
			return false
		data_shots.append({
			"projectile_id": projectile_id,
			"projectile_type": projectile_type,
			"spawn_position": service.get_position(handle),
			"direction": service.get_direction(handle),
			"damage": damage,
			"lifetime": lifetime,
			"damage_source_snapshot": damage_source_snapshot,
			"payload_size": 0,
		})
		return true


	func broadcast_enemy_rapid_fire_burst(
		descriptor: PackedByteArray
	) -> bool:
		burst_descriptors.append(descriptor)
		return true


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


func _init() -> void:
	call_deferred(&"_run")


func _run() -> void:
	await _test_fixed_seed_data_burst(
		GUNNER_SCENE,
		GUNNER_CONFIG,
		RapidFireSimulationService.Profile.GUNNER,
		"ordinary"
	)
	await _test_fixed_seed_data_burst(
		GUNNER_ELITE_SCENE,
		GUNNER_ELITE_CONFIG,
		RapidFireSimulationService.Profile.GUNNER_ELITE,
		"elite"
	)
	await _test_data_host_rejection_and_client_boundary()
	await _test_data_muzzle_world_clearance()
	_finish()


func _test_fixed_seed_data_burst(
	enemy_scene: PackedScene,
	enemy_config: CombatRobotGunnerConfig,
	expected_profile: RapidFireSimulationService.Profile,
	label: String
) -> void:
	var data_result := await _capture_complete_burst(
		enemy_scene,
		enemy_config,
		"GunnerData%s" % label
	)
	var repeat_result := await _capture_complete_burst(
		enemy_scene,
		enemy_config,
		"GunnerDataRepeat%s" % label
	)
	var data_shots := data_result.get("shots", []) as Array
	var repeat_shots := repeat_result.get("shots", []) as Array
	var data_records := data_result.get("data_records", []) as Array
	var data_descriptors := data_result.get("burst_descriptors", []) as Array
	_expect(
		data_shots.size() == enemy_config.burst_count
		and repeat_shots.size() == enemy_config.burst_count
		and data_records.size() == enemy_config.burst_count,
		"%s gunner DATA must commit the authored burst count deterministically."
		% label
	)
	_expect(
		int(data_result.get("live_nodes", -1)) == 0
		and int(repeat_result.get("live_nodes", -1)) == 0,
		"%s DATA authority must replace every live projectile Node with a handle."
		% label
	)
	_expect(
		int(data_result.get("random_state", -1))
		== int(repeat_result.get("random_state", -2)),
		"%s fixed-seed DATA spread and pitch RNG order must be deterministic."
		% label
	)
	_expect(
		int(data_result.get("action_sequence", -1)) == 1,
		"%s DATA burst must reserve exactly one action id."
		% label
	)
	_expect(
		data_descriptors.size() == 1,
		"%s DATA burst must emit one projectile descriptor." % label
	)
	var decoded_descriptor := (
		RAPID_FIRE_CODEC.decode_burst(
			data_descriptors[0] as PackedByteArray
		)
		if data_descriptors.size() == 1
		else {}
	)
	_expect(
		bool(decoded_descriptor.get("valid", false))
		and int(decoded_descriptor.get("count", 0)) == enemy_config.burst_count
		and int(decoded_descriptor.get("source_enemy_id", 0)) == SOURCE_ENEMY_ID
		and int(decoded_descriptor.get("action_id", 0)) == 1,
		"%s descriptor must preserve count, source identity and action id." % label
	)
	var descriptor_directions := decoded_descriptor.get(
		"directions",
		PackedVector2Array()
	) as PackedVector2Array

	var compare_count := mini(
		data_shots.size(),
		mini(repeat_shots.size(), data_records.size())
	)
	for shot_index in range(compare_count):
		var data_shot := data_shots[shot_index] as Dictionary
		var repeat_shot := repeat_shots[shot_index] as Dictionary
		var data_record := data_records[shot_index] as Dictionary
		var source_snapshot := data_shot.get(
			"damage_source_snapshot"
		) as DamageSourceSnapshot
		_expect(
			data_shot.get("projectile_type")
			== enemy_config.projectile_type,
			"%s shot %d must retain its projectile type without per-shot RPC."
			% [label, shot_index]
		)
		_expect(
			(data_shot.get("spawn_position") as Vector2).is_equal_approx(
				repeat_shot.get("spawn_position") as Vector2
			)
			and (data_shot.get("direction") as Vector2).is_equal_approx(
				repeat_shot.get("direction") as Vector2
			)
			and int(data_shot.get("damage", -1)) == enemy_config.attack_damage
			and is_equal_approx(
				float(data_shot.get("lifetime", -1.0)),
				enemy_config.projectile_lifetime
			),
			"%s shot %d must preserve deterministic spawn, spread and authored damage/lifetime."
			% [label, shot_index]
		)
		_expect(
			source_snapshot != null
			and source_snapshot.source_faction_id
			== CombatRelationService.HOSTILE_WAVE
			and source_snapshot.instigator_entity_id == SOURCE_ENEMY_ID,
			"%s shot %d 必须把敌军发射来源快照贯穿批量预留注册。"
			% [label, shot_index]
		)
		_expect(
			shot_index < descriptor_directions.size()
			and absf(
				descriptor_directions[shot_index].angle_to(
					data_shot.get("direction") as Vector2
				)
			) < 0.0002,
			"%s shot %d descriptor direction must match fixed-seed gameplay RNG."
			% [label, shot_index]
		)
		_expect(
			int(data_record.get("profile", -1)) == expected_profile
			and int(data_record.get("projectile_id", 0))
			== int(data_shot.get("projectile_id", -1))
			and int(data_record.get("world_check_interval", 0))
			== RapidFireSimulationService.GUNNER_WORLD_CHECK_INTERVAL
			and int(data_record.get("world_check_phase", -1))
			== (
				int(data_shot.get("projectile_id", 0))
				% RapidFireSimulationService.GUNNER_WORLD_CHECK_INTERVAL
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
	_expect(
		(data_result.get("actions", []) as Array).is_empty(),
		"%s DATA burst must use its descriptor without per-shot enemy actions." % label
	)


func _capture_complete_burst(
	enemy_scene: PackedScene,
	enemy_config: CombatRobotGunnerConfig,
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
	enemy.random_generator.seed = FIXED_SEED
	_fire_complete_burst(enemy, enemy_config)

	var result := {
		"shots": gateway.data_shots.duplicate(true),
		"actions": gateway.enemy_actions.duplicate(true),
		"random_state": enemy.random_generator.state,
		"action_sequence": enemy.action_sequence,
		"live_nodes": _count_live_gunner_bullets(fixture),
		"data_records": _collect_data_records(service),
		"burst_descriptors": gateway.burst_descriptors.duplicate(true),
	}
	await _destroy_fixture(fixture)
	return result


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
	enemy.call(&"_prepare_network_burst")
	_expect(
		not bool(enemy.call(&"_fire_locked_bullet"))
		and gateway.node_shots.is_empty()
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
	enemy.call(&"_prepare_network_burst")
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
	enemy.call(&"_prepare_network_burst")
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


func _count_live_gunner_bullets(fixture: Node) -> int:
	var count := 0
	for child in fixture.get_children():
		var bullet := child as CombatRobotGunnerBullet
		if bullet != null and bullet.pool_active and not bullet.has_hit:
			count += 1
	return count


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
