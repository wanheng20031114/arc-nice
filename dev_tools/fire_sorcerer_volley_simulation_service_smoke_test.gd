extends SceneTree

const ServiceScript := preload(
	"res://scene/combat/simulation/fire_sorcerer_volley_simulation_service.gd"
)
const SERVICE_SOURCE_PATH := (
	"res://scene/combat/simulation/fire_sorcerer_volley_simulation_service.gd"
)

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_generation_reuse_and_stable_compaction()
	await _test_next_tick_three_ball_homing_modes_completion_and_teardown()
	_test_production_collision_damage_and_gateway_boundaries()
	if failures.is_empty():
		print("FIRE_SORCERER_VOLLEY_SIMULATION_SERVICE_SMOKE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_generation_reuse_and_stable_compaction() -> void:
	var service := ServiceScript.new()
	_expect(service.reserve_capacity(3), "Reserve must preallocate volley and ball SoA.")
	var first := _register_basic(service, ServiceScript.Mode.DATA, ServiceScript.Profile.NORMAL, 1001, 1.0)
	var survivor := _register_basic(service, ServiceScript.Mode.DATA, ServiceScript.Profile.ELITE, 1002, 1.0)
	var first_slot := service.get_handle_slot(first)
	var first_generation := service.get_handle_generation(first)
	_expect(first > 0 and survivor > 0, "Reserved rows must register valid handles.")
	_expect(service.release_volley(first), "A live handle must release once.")
	service.advance_authoritative(0.0)
	_expect(
		not service.is_handle_live(first)
		and service.get_dense_record_count() == 1
		and service.get_handle_at_stable_index(0) == survivor,
		"Frame-end compaction must remove a tombstone without reordering survivors."
	)
	var reused := _register_basic(service, ServiceScript.Mode.REPLICA, ServiceScript.Profile.NORMAL, 1003, 1.0)
	_expect(
		service.get_handle_slot(reused) == first_slot
		and service.get_handle_generation(reused) != first_generation
		and not service.is_handle_live(first),
		"A reused logical slot must advance generation and keep stale handles invalid."
	)
	service.prepare_for_runtime_teardown()
	service.free()


func _test_next_tick_three_ball_homing_modes_completion_and_teardown() -> void:
	var service := ServiceScript.new()
	_expect(service.reserve_volley_capacity(5), "Kernel reserve must succeed.")
	var target := Player.new()
	target.position = Vector2(0.0, 100.0)
	var positions := PackedVector2Array([Vector2.ZERO, Vector2(0.0, 20.0), Vector2(0.0, 40.0)])
	var directions := PackedVector2Array([Vector2.RIGHT, Vector2.RIGHT, Vector2.RIGHT])
	var data_handle := service.register_volley(
		ServiceScript.Mode.DATA, ServiceScript.Profile.NORMAL, positions, directions,
		10.0, 0.2, 2.0, 7, 77, 2001, target, 2.5, 4
	)
	var second_data_handle := service.register_volley(
		ServiceScript.Mode.DATA, ServiceScript.Profile.NORMAL, positions, directions,
		10.0, 0.2, 0.0, 7, 77, 2002
	)
	var replica_handle := service.register_volley(
		ServiceScript.Mode.REPLICA, ServiceScript.Profile.ELITE, positions, directions,
		10.0, 0.2, 0.0, 7, 77, 2003
	)
	service.advance_authoritative(0.1)
	_expect(
		service.get_ball_position(data_handle, 0).is_equal_approx(Vector2.ZERO)
		and service.get_slot_state(data_handle) == ServiceScript.SlotState.PENDING_ACTIVATION,
		"Registration-frame simulation must remain inert."
	)
	await physics_frame
	service.advance_authoritative(0.1)
	var homed_direction := service.get_ball_direction(data_handle, 0)
	_expect(
		service.get_active_ball_mask(data_handle) == 0b111
		and service.get_visible_effect_mask(data_handle) == 0
		and homed_direction.angle() > 0.19
		and homed_direction.angle() < 0.21,
		"Independent masks and max-turn-rate homing must advance on the next tick."
	)
	_expect(
		service.get_slot_mode(second_data_handle) == ServiceScript.Mode.DATA
		and service.get_slot_mode(replica_handle) == ServiceScript.Mode.REPLICA
		and service.get_slot_profile(replica_handle) == ServiceScript.Profile.ELITE,
		"DATA/REPLICA and NORMAL/ELITE identities must remain per record."
	)
	service.advance_authoritative(0.11)
	_expect(
		service.get_active_ball_mask(data_handle) == 0
		and service.get_visible_effect_mask(data_handle) == 0b111
		and service.get_completion_count() == 9,
		"Lifetime must independently transition all three balls in all three modes."
	)
	var completions_are_visual_only := true
	for index in range(service.get_completion_count()):
		completions_are_visual_only = completions_are_visual_only and (
			service.get_completion_effect_kind(index) == ServiceScript.EffectKind.EXPIRE
			and not service.get_completion_damage_applied(index)
			and service.get_completion_ball_index(index) == index % 3
		)
	_expect(completions_are_visual_only, "Time-only completions must be stable and damage-free.")
	service.advance_authoritative(0.23)
	_expect(
		service.get_terminal_completion_count() == 3
		and not service.is_handle_live(data_handle)
		and not service.is_handle_live(second_data_handle)
		and not service.is_handle_live(replica_handle),
		"All-effect completion must publish stable terminal records and stale handles."
	)
	var metrics := service.get_metrics()
	_expect(
		int(metrics["homing_updates"]) >= 3 and int(metrics["damage_applications"]) == 0,
		"Core metrics must expose homing work without inventing unbound damage."
	)
	service.prepare_for_runtime_teardown()
	service.prepare_for_runtime_teardown()
	var teardown := service.get_metrics()
	_expect(
		bool(teardown["teardown_prepared"])
		and int(teardown["teardown_count"]) == 1
		and int(teardown["dense_records"]) == 0
		and not bool(teardown["bound"]),
		"Teardown must be idempotent and release packed storage and typed context."
	)
	service.free()
	target.free()


func _test_production_collision_damage_and_gateway_boundaries() -> void:
	var source := FileAccess.get_file_as_string(SERVICE_SOURCE_PATH)
	var player_priority := source.find("if _find_endpoint_player")
	var plant_priority := source.find("if _find_endpoint_plant", player_priority)
	var enemy_priority := source.find("return _find_endpoint_enemy", plant_priority)
	_expect(
		player_priority >= 0 and plant_priority > player_priority and enemy_priority > plant_priority,
		"Endpoint target priority must remain Player, then Plant, then Enemy."
	)
	_expect(
		source.contains("runtime: CombatRuntimeBase")
		and source.contains("coordinator: EnemySimulationCoordinator")
		and source.contains("_combat_target_index: CombatTargetIndex")
		and source.contains("_combat_relation_service: CombatRelationService"),
		"Binding must use concrete production combat types."
	)
	_expect(
		source.contains("player.collision_shape.shape")
		and source.contains("damageable_overlaps_shape")
		and source.contains("query_hostile_world_aabb_unordered_into")
		and source.contains("enemy.body_collision_shapes"),
		"Player, indexed Plant, and indexed Enemy contacts need exact shape posteriors."
	)
	_expect(
		source.contains("_is_source_enemy_for_slot")
		and source.contains("_is_target_hostile_for_slot")
		and source.contains("_combat_relation_service.is_hostile"),
		"Every endpoint must exclude source enemies and revalidate faction hostility."
	)
	_expect(
		source.contains("player.apply_combat_damage(request).accepted")
		and source.contains("plant.apply_combat_damage(request).accepted")
		and source.contains("enemy.apply_combat_damage(request).accepted")
		and source.contains("EnemyConfig.DamageType.MAGIC")
		and source.contains("CombatTypes.DamageFlag.RANGED"),
		"Direct Player/Plant/Enemy paths must use stable ranged magic DamageRequests."
	)
	_expect(
		source.contains("gateway.request_player_damage")
		and source.contains("gateway.try_consume_fire_sorcerer_fireball_contact")
		and source.contains("CombatRuntimeBase.RuntimeMode.SINGLEPLAYER")
		and source.contains("contact_consumed"),
		"Host Player damage must cross the typed gateway after per-ball contact consumption."
	)
	_expect(
		source.contains("_source_instigator_entity_ids[dense_slot] = int(_source_enemy_ids[dense_slot])")
		and not source.contains("_combat_runtime.call")
		and source.contains("_combat_runtime.find_nearest_hostile_enemy_attack_target_world"),
		"Fallback snapshots and retargeting must preserve typed stable-source semantics."
	)


func _register_basic(
	service: Node,
	mode: int,
	profile: int,
	projectile_id: int,
	lifetime: float
) -> int:
	return service.register_volley(
		mode,
		profile,
		PackedVector2Array([Vector2.ZERO, Vector2(0, 20), Vector2(0, 40)]),
		PackedVector2Array([Vector2.RIGHT, Vector2.RIGHT, Vector2.RIGHT]),
		10.0,
		lifetime,
		0.0,
		3,
		41,
		projectile_id
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
