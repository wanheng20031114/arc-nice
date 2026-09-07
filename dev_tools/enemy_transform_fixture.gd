extends Node

class LegacyShapeProxy:
	extends CombatContactShapeProxy

	# Previous production implementation, retained only as an equal-dispatch
	# reference for status parity and the isolated microbenchmark.
	func validate_translation_transform(world_transform: Transform2D) -> SupportStatus:
		if not is_supported():
			return support_status
		var basis_status := _validate_basis(world_transform)
		if basis_status != SupportStatus.SUPPORTED:
			return basis_status
		if absf(wrapf(world_transform.get_rotation() - capture_rotation, -PI, PI)) > BASIS_EPSILON:
			return SupportStatus.ROTATION_CHANGED
		if not is_equal_approx(world_transform.x.length(), capture_scale):
			return SupportStatus.SCALE_CHANGED
		return SupportStatus.SUPPORTED

class CountedRelations:
	extends CombatRelationService
	var query_count := 0

	func is_hostile(source_faction: int, target_faction: int) -> bool:
		query_count += 1
		return super.is_hostile(source_faction, target_faction)

## Exact transform validation, native collision and real coordinator lifecycle.
## Geometry microbenchmarks compare the previous mathematical validator against
## the production API; they are not whole-game FPS measurements.
var result: Dictionary = {}
var failures: Array[String] = []
var assertions := 0
var runtime: TowerDefenseGame
var metrics := {}


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_shape_contracts()
	await _check_native_motion()
	await _check_real_registration()
	if "--benchmark" in OS.get_cmdline_user_args():
		_benchmark_translation_validation()
	metrics["assertions"] = assertions
	metrics["failures"] = failures
	print("ENEMY_TRANSFORM_REGRESSION ", JSON.stringify(metrics))
	var output_path := "res://dev_tools/output/enemy_transform_regression.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()


func _check_shape_contracts() -> void:
	var circle := CircleShape2D.new()
	circle.radius = 2.0
	var capsule := CapsuleShape2D.new()
	capsule.radius = 2.0
	capsule.height = 14.0
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(4, 12)
	var polygon := ConvexPolygonShape2D.new()
	polygon.points = PackedVector2Array([Vector2(-3, -2), Vector2(4, -1), Vector2(1, 5)])
	var segment := SegmentShape2D.new()
	segment.a = Vector2(-3, 2)
	segment.b = Vector2(5, -4)
	var shapes: Array[Shape2D] = [circle, capsule, rectangle, polygon, segment]
	for shape in shapes:
		for rotation in [0.0, 0.37, PI]:
			for scale_value in [0.5, 1.0, 2.0]:
				var captured := Transform2D(rotation, Vector2.ONE * scale_value, 0.0, Vector2(7, -11))
				var proxy := CombatContactShapeProxy.create(shape, captured)
				_check(proxy.is_supported(), "Authored convex geometry captures under a conformal basis")
				_check_transform_variants(proxy, captured)
	var compound := CombatContactShapeProxy.create_compound(
		[circle, circle],
		[Transform2D(0, Vector2(-6, 0)), Transform2D(0, Vector2(6, 0))]
	)
	_check(compound.is_supported() and compound.get_compound_child_count() == 2, "Disconnected compound captures two separate shapes")
	_check_transform_variants(compound, Transform2D.IDENTITY)
	var probe_shape := CircleShape2D.new()
	probe_shape.radius = 1.0
	var probe := CombatContactShapeProxy.create(probe_shape)
	var capsule_proxy := CombatContactShapeProxy.create(capsule)
	_check(not compound.overlaps_at(Vector2.ZERO, probe, Vector2.ZERO), "Compound gap is not replaced with its convex hull or AABB")
	_check(compound.overlaps_at(Vector2.ZERO, probe, Vector2(6, 0)), "Compound child overlap is retained")
	_check(not capsule_proxy.overlaps_at(Vector2.ZERO, probe, Vector2(4, 0)), "Capsule long axis does not become a circle")
	_check(capsule_proxy.overlaps_at(Vector2.ZERO, probe, Vector2(0, 8)), "Capsule rounded cap still touches exactly")
	for offset in [Vector2.ZERO, Vector2(101, -77), Vector2(-300, 120)]:
		_check(not compound.overlaps_at(offset, probe, offset), "Translation preserves the disconnected compound gap")
		_check(compound.swept_overlaps(offset + Vector2(-20, 0), offset + Vector2(20, 0), probe, offset, offset), "Fast translated compound cannot tunnel through the probe")
		_check(not compound.swept_overlaps(offset + Vector2(0, -20), offset + Vector2(0, 20), probe, offset, offset), "A sweep through the actual compound gap does not invent contact")
	var unsupported := CombatContactShapeProxy.create(WorldBoundaryShape2D.new())
	_check(unsupported.validate_translation_transform(Transform2D.IDENTITY) == CombatContactShapeProxy.SupportStatus.UNSUPPORTED_SHAPE, "Identical basis cannot admit unsupported shapes")
	var null_proxy := CombatContactShapeProxy.create(null)
	_check(null_proxy.validate_translation_transform(Transform2D.IDENTITY) == CombatContactShapeProxy.SupportStatus.NULL_SHAPE, "Identical basis cannot admit null geometry")
	var original_radius := probe.get_bounding_radius()
	probe_shape.radius = 9.0
	_check(probe.get_bounding_radius() == original_radius, "An immutable proxy never silently adopts edited shape geometry")
	_check(CombatContactShapeProxy.create(probe_shape).get_bounding_radius() == 9.0, "Recapturing edited geometry publishes its new exact radius")


func _check_transform_variants(proxy: CombatContactShapeProxy, captured: Transform2D) -> void:
	var reference := LegacyShapeProxy.new()
	reference.support_status = proxy.support_status
	reference.capture_rotation = proxy.capture_rotation
	reference.capture_scale = proxy.capture_scale
	var variants: Array[Transform2D] = []
	for index in 32:
		variants.append(captured.translated(Vector2(index * 3.125, -index * 0.75)))
	variants.append(captured.rotated_local(0.002))
	variants.append(captured.rotated_local(0.0000001))
	variants.append(captured.scaled_local(Vector2.ONE * 1.2))
	variants.append(captured.scaled_local(Vector2(1.2, 1.0)))
	variants.append(captured * Transform2D.FLIP_X)
	variants.append(Transform2D(captured.x, captured.y + captured.x * 0.2, captured.origin))
	variants.append(Transform2D(captured.x, captured.y, Vector2(INF, 0)))
	variants.append(Transform2D(Vector2(NAN, 0), captured.y, captured.origin))
	variants.append(Transform2D(Vector2.ZERO, Vector2.ZERO, captured.origin))
	# Repeated tiny rotations must still compare against the captured basis;
	# caching the previous accepted result must not accumulate angular drift.
	for index in 8:
		variants.append(captured.rotated_local(index * 0.00005))
	variants.append(captured)
	for transform_value in variants:
		_check(proxy.validate_translation_transform(transform_value) == reference.validate_translation_transform(transform_value), "Translation fast path preserves the previous exact rejection status and tolerance")


func _check_native_motion() -> void:
	var enemy := $MotionRig/Enemy as Enemy
	var objective := $MotionRig/Objective as Node2D
	enemy.process_mode = Node.PROCESS_MODE_INHERIT
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.objective_target = objective
	enemy.cached_navigation_uses_direct_objective_approach = true
	enemy.cached_navigation_move_direction = Vector2.RIGHT
	enemy.cached_navigation_generation = -1
	enemy.cached_navigation_verified_direct_motion_clearance = 5.0
	_check(enemy._can_use_verified_direct_objective_linear_movement(Vector2(2, 0)), "Finite forward motion within a verified corridor is admitted")
	_check(not enemy._can_use_verified_direct_objective_linear_movement(Vector2(5.01, 0)), "A step beyond certified clearance is rejected")
	_check(not enemy._can_use_verified_direct_objective_linear_movement(Vector2(0, 2)), "Motion outside the certified heading is rejected")
	_check(not enemy._can_use_verified_direct_objective_linear_movement(Vector2.ZERO), "Zero motion cannot consume a certificate")
	enemy.cached_navigation_generation = 0
	_check(not enemy._can_use_verified_direct_objective_linear_movement(Vector2(2, 0)), "Navigation generation changes revoke a certificate")
	enemy.cached_navigation_generation = -1
	enemy.objective_target = null
	_check(not enemy._can_use_verified_direct_objective_linear_movement(Vector2(2, 0)), "A removed objective revokes a certificate")
	enemy.objective_target = objective
	enemy.cached_navigation_uses_direct_objective_approach = false
	var health := enemy.current_health
	Enemy.performance_metrics_enabled = true
	Enemy.reset_performance_metrics()
	await get_tree().physics_frame
	for step in 30:
		enemy.velocity = Vector2(600, 0)
		enemy._move_after_confirmed_no_contact(1.0 / 60.0)
	var motion_metrics := Enemy.get_performance_metrics()
	_check(enemy.position.x < 39.0, "A mover without a certificate stops at the real native wall")
	_check(enemy.current_health == health, "A wall collision does not invent combat damage")
	_check(int(motion_metrics["move_and_slide_calls"]) == 30 and int(motion_metrics["verified_direct_move_calls"]) == 0, "All uncertified movement still uses CharacterBody collision resolution")
	Enemy.performance_metrics_enabled = false
	enemy.objective_target = null


func _check_real_registration() -> void:
	(get_node("/root/RunState") as RunStateStore).begin_new_run(&"weishidaier", false)
	runtime = load("res://scene/game_modes/tower_defense/tower_defense_game.tscn").instantiate()
	runtime.auto_start_waves = false
	runtime.day_phase_announcements_enabled = false
	runtime.defer_runtime_activation()
	get_tree().root.add_child(runtime)
	get_tree().current_scene = runtime
	var deadline := Time.get_ticks_msec() + 30000
	while not runtime.is_runtime_preparation_complete() and Time.get_ticks_msec() < deadline:
		if runtime.is_runtime_preparation_failed():
			break
		await get_tree().process_frame
	_check(runtime.is_runtime_preparation_complete(), "Actual tower-defense runtime finishes preparation")
	if runtime.is_runtime_preparation_complete():
		runtime.activate_runtime()
		runtime.process_mode = Node.PROCESS_MODE_DISABLED
		_check_contact_selection()
		var coordinator := runtime.get_enemy_simulation_coordinator()
		coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)
		for config_name in ["capoo_knight", "capoo_swordsman", "capoo_ak47", "stone_golem", "combat_robot_main_battle_elite"]:
			_check_registered_enemy(coordinator, config_name)
			await get_tree().process_frame
		runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	runtime = null
	for frame in 4:
		await get_tree().process_frame


func _check_contact_selection() -> void:
	var enemy := $MotionRig/Enemy as Enemy
	var relation := CountedRelations.new()
	enemy.combat_relation_service = relation
	enemy.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, -1, true)
	var plants: Array[PlantDefense] = []
	for index in 3:
		var config := runtime.plant_system.get_config(&"corn_machine_gun").duplicate() as PlantDefenseConfig
		var plant := runtime.plant_system._instantiate_registered_plant(config, Vector2i(1 + index * 3, 3), runtime.player,
			30 - index * 10, false, -1, 0, -1, false)
		_check(plant != null, "Native building created for target selection")
		plants.append(plant)
		plant.global_position = enemy.global_position + Vector2(10, 0)
		enemy.touching_plants[plant.get_instance_id()] = plant
		enemy.touching_plant_entry_distances[plant.get_instance_id()] = 100.0
	relation.query_count = 0
	_check(enemy._select_touching_plant() == plants[2], "Equal-distance building ties keep the lowest network ID")
	_check(relation.query_count == 1, "A building selection queries the shared faction exactly once")
	plants[0].global_position = enemy.global_position + Vector2(9, 0)
	_check(enemy._select_touching_plant() == plants[0], "A nearer building wins before network-ID ties")
	plants[0].is_dead = true
	_check(enemy._select_touching_plant() == plants[2] and not enemy.touching_plants.has(plants[0].get_instance_id()),
		"Death is checked live and stale building membership is removed")
	plants[0].is_dead = false
	plants[2].is_removing = true
	_check(enemy._select_touching_plant() == plants[1], "Removing buildings are rejected immediately")
	plants[2].is_removing = false
	plants[1].config.placement_surface = PlantDefenseConfig.PlacementSurface.WATER_ONLY
	_check(enemy._select_touching_plant() == null, "Ground-only attackers do not select a water building")
	plants[1].config.placement_surface = PlantDefenseConfig.PlacementSurface.ANY_LAND
	for plant in plants:
		enemy.touching_plants[plant.get_instance_id()] = plant
		enemy.touching_plant_entry_distances[plant.get_instance_id()] = 100.0
	relation.set_hostile(CombatRelationService.HOSTILE_WAVE, CombatRelationService.PLAYER_ALLIED, false)
	_check(enemy._select_touching_plant() == null and not enemy._has_player_contact(), "A directed relation change revokes plant attacks and blocking contact immediately")
	_check(relation.is_hostile(CombatRelationService.PLAYER_ALLIED, CombatRelationService.HOSTILE_WAVE), "The reverse directed relation remains independent")
	relation.set_hostile(CombatRelationService.HOSTILE_WAVE, CombatRelationService.PLAYER_ALLIED, true)
	_check(enemy._select_touching_plant() == plants[0] and enemy._has_player_contact(), "Restoring hostility reuses living contact membership immediately")
	enemy.set_combat_faction_id(CombatRelationService.PLAYER_ALLIED, -1, true)
	_check(enemy._select_touching_plant() == null, "Changing the enemy's faction revokes friendly plant targeting immediately")
	enemy.set_combat_faction_id(CombatRelationService.HOSTILE_WAVE, -1, true)
	var first_player := runtime.player
	var second_player := $MotionRig/SecondPlayer as Player
	first_player.peer_id = 8
	second_player.peer_id = 4
	enemy.touching_players[first_player.get_instance_id()] = first_player
	enemy.touching_players[second_player.get_instance_id()] = second_player
	relation.query_count = 0
	_check(enemy._select_touching_player() == second_player, "Player contact selection keeps the lowest peer-ID ordering")
	_check(relation.query_count == 1, "A player selection queries the shared faction exactly once")
	second_player.peer_id = first_player.peer_id
	var expected := first_player if first_player.get_instance_id() < second_player.get_instance_id() else second_player
	_check(enemy._select_touching_player() == expected, "Equal peer IDs retain stable instance-ID ordering")
	second_player.is_dead = true
	_check(enemy._select_touching_player() == first_player and not enemy.touching_players.has(second_player.get_instance_id()),
		"Dead players are rejected and removed immediately")
	second_player.is_dead = false
	relation.set_hostile(CombatRelationService.HOSTILE_WAVE, CombatRelationService.PLAYER_ALLIED, false)
	_check(enemy._select_touching_player() == null, "A relation change revokes player contact without a cached frame delay")
	first_player.peer_id = 0
	enemy.touching_players.clear()
	enemy.touching_plants.clear()
	enemy.touching_plant_entry_distances.clear()
	enemy.touched_player = null
	enemy.touched_plant = null
	enemy.combat_relation_service = null


func _check_registered_enemy(coordinator: EnemySimulationCoordinator, config_name: String) -> void:
	var config := load("res://resources/config/enemies/" + config_name + ".tres") as EnemyConfig
	var enemy := config.enemy_scene.instantiate() as Enemy
	enemy.config = config
	runtime.enemy_container.add_child(enemy)
	enemy.setup(config, runtime.player, runtime.grid_pathfinder, runtime)
	enemy.global_position = Vector2(200, 150)
	_check(enemy.enemy_simulation_coordinator == coordinator and enemy.enemy_simulation_token > 0,
		config_name + " setup attaches to the real coordinator")
	var token := enemy.enemy_simulation_token
	var registration := coordinator._get_owned_registration(enemy, token)
	if registration == null:
		_check(false, config_name + " has a live registration")
		enemy.free()
		return
	coordinator._admit_layered_contact_proxies_for_tick(Engine.get_physics_frames() + 1, 0)
	if config_name == "combat_robot_main_battle_elite":
		_check(not registration.contact_proxy_registered and not enemy.is_indexed_touch_authority_enabled(),
			"Main-battle elite retains its authored compatibility contact authority")
	else:
		_check(registration.contact_proxy_registered, config_name + " publishes real authored contact proxies")
	if registration.contact_proxy_registered:
		var old_proxy := registration.contact_attacker_proxy
		var original_transform := enemy.transform
		enemy.position += Vector2(1, 2)
		_check(not registration.contact_geometry_dirty and registration.contact_attacker_proxy == old_proxy, config_name + " pure translation preserves immutable geometry")
		enemy.rotation += 0.1
		_check(registration.contact_geometry_dirty, config_name + " changed rotation invalidates geometry synchronously")
		enemy.transform = original_transform
		coordinator._sync_layered_contact_proxy_geometry()
		_check(not registration.contact_geometry_dirty, config_name + " geometry is recaptured at the contact boundary")
		var shape_node := enemy.touch_damage_shapes[0]
		var original_local_transform := shape_node.transform
		shape_node.position += Vector2(3, 1)
		enemy.mark_contact_shape_geometry_changed()
		coordinator._sync_layered_contact_proxy_geometry()
		_check(registration.contact_attacker_proxy != old_proxy, config_name + " authored shape offset changes do not retain a stale proxy")
		shape_node.transform = original_local_transform
		var changed_revision := enemy.get_contact_shape_revision()
		if shape_node.shape is RectangleShape2D:
			(shape_node.shape as RectangleShape2D).size += Vector2.ONE
		elif shape_node.shape is CircleShape2D:
			(shape_node.shape as CircleShape2D).radius += 1.0
		elif shape_node.shape is CapsuleShape2D:
			(shape_node.shape as CapsuleShape2D).height += 1.0
		elif shape_node.shape is SegmentShape2D:
			(shape_node.shape as SegmentShape2D).b += Vector2.ONE
		_check(enemy.get_contact_shape_revision() > changed_revision and registration.contact_geometry_dirty, config_name + " in-place shape edits publish geometry dirtiness")
		_check(not coordinator.mark_enemy_indexed_touch_transform_dirty(enemy, token + 100), config_name + " rejects stale registration tokens")
	_check(coordinator.unregister_enemy(enemy, token), config_name + " ownership releases through the production API")
	_check(not coordinator.mark_enemy_indexed_touch_transform_dirty(enemy, token), config_name + " retired registration cannot re-enter the dirty queue")
	enemy.free()


func _benchmark_translation_validation() -> void:
	var shape := CapsuleShape2D.new()
	shape.radius = 6.0
	shape.height = 22.0
	var captured := Transform2D(0.37, Vector2.ONE * 1.5, 0.0, Vector2(13, -9))
	var proxy := CombatContactShapeProxy.create(shape, captured)
	var reference := LegacyShapeProxy.new()
	reference._capture(shape, captured)
	var transforms: Array[Transform2D] = []
	for index in 64:
		transforms.append(captured.translated(Vector2(index * 1.75, index * 0.625)))
	var measurements := []
	for mode in ["legacy", "optimized", "optimized", "legacy", "legacy", "optimized", "optimized", "legacy"]:
		var tested_proxy: CombatContactShapeProxy = reference if mode == "legacy" else proxy
		var accepted := 0
		var started := Time.get_ticks_usec()
		for iteration in 100000:
			var transform_value := transforms[iteration % transforms.size()]
			var status := tested_proxy.validate_translation_transform(transform_value)
			if status == CombatContactShapeProxy.SupportStatus.SUPPORTED:
				accepted += 1
		measurements.append({"mode": mode, "calls": 100000, "elapsed_usec": Time.get_ticks_usec() - started})
		_check(accepted == 100000, "Microbenchmark executes equal successful validation work")
	metrics["translation_validation_abba"] = measurements


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)
		push_error(message)
