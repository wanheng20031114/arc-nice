extends Node

var result: Dictionary = {}
var failures: Array[String] = []
var assertions := 0
var runtime: TowerDefenseGame


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
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
	_check(runtime.is_runtime_preparation_complete(), "Actual tower runtime finishes preparation")
	if runtime.is_runtime_preparation_complete():
		runtime.activate_runtime()
		runtime.player.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
		runtime.process_mode = Node.PROCESS_MODE_DISABLED
		for config_name in ["slime_golden", "cardboard_monster_large"]:
			await _check_family(config_name)
		runtime.prepare_for_scene_teardown()
	runtime.queue_free()
	runtime = null
	for frame in 4:
		await get_tree().process_frame
	var metrics := {"assertions": assertions, "failures": failures}
	print("INDEXED_TOUCH_LIFECYCLE_REGRESSION ", JSON.stringify(metrics))
	var file := FileAccess.open("res://dev_tools/output/indexed_touch_lifecycle_regression.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	result["exit_code"] = 0 if failures.is_empty() else 1
	queue_free()


func _check_family(config_name: String) -> void:
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)
	runtime.player.global_position = Vector2(-600, -600)
	var config := load("res://resources/config/enemies/" + config_name + ".tres").duplicate() as EnemyConfig
	config.attack_damage = 0
	var enemy := config.enemy_scene.instantiate() as Enemy
	enemy.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	enemy.config = config
	runtime.enemy_container.add_child(enemy)
	enemy.touch_damage_area.disable_mode = CollisionObject2D.DISABLE_MODE_KEEP_ACTIVE
	enemy.setup(config, runtime.player, runtime.grid_pathfinder, runtime)
	enemy.position = Vector2(120, 120)
	var registration := coordinator._get_owned_registration(enemy, enemy.enemy_simulation_token)
	_check(registration != null and enemy.supports_indexed_touch_authority(), config_name + " retains its existing indexed capability")
	_check(enemy.touch_damage_shapes.size() == 1 and enemy.body_collision_shapes.size() == 1, config_name + " tests the deployed single-shape gate")
	_admit(coordinator, registration, enemy)
	await get_tree().process_frame
	_check_area(enemy, false, config_name + " admitted")
	_check(coordinator.suspend_enemy(enemy, registration.token), config_name + " direct owner suspension accepted")
	_check(not registration.contact_proxy_registered and not enemy.indexed_touch_authority_enabled,
		config_name + " suspension immediately releases both proxy and indexed snapshot ownership")
	await get_tree().process_frame
	_check_area(enemy, true, config_name + " suspended")
	# The restored native sensor must really detect its authored player body,
	# rather than merely reporting restored boolean flags.
	runtime.player.max_health = 1000000
	runtime.player.current_health = 1000000
	runtime.player.global_position = enemy.global_position
	runtime.player.reset_physics_interpolation()
	for frame in 4:
		await get_tree().physics_frame
	await get_tree().process_frame
	_check(enemy.touch_damage_area.overlaps_body(runtime.player), config_name + " suspended native Area detects a real player overlap")
	_check(enemy.touching_players.has(runtime.player.get_instance_id()), config_name + " restored native signal updates the live contact dictionary")
	runtime.player.global_position = Vector2(-600, -600)
	runtime.player.reset_physics_interpolation()
	_check(coordinator.resume_enemy(enemy, registration.token), config_name + " direct owner resumption accepted")
	_admit(coordinator, registration, enemy)
	await get_tree().process_frame
	_check_area(enemy, false, config_name + " resumed")
	_check(enemy.touching_players.is_empty(), config_name + " fresh admission replaces the old native contact snapshot")
	# Unregister/reregister preserves a new ownership token. A delayed callback
	# carrying the retired token must never disable the replacement sensor.
	var old_token := registration.token
	_check(coordinator.unregister_enemy(enemy, old_token), config_name + " explicit unregister accepted")
	await get_tree().process_frame
	_check_area(enemy, true, config_name + " unregistered")
	enemy.on_enemy_simulation_coordinator_released(coordinator, old_token, true)
	_check(enemy.try_attach_to_enemy_simulation_coordinator(coordinator), config_name + " live enemy registers afresh")
	registration = coordinator._get_owned_registration(enemy, enemy.enemy_simulation_token)
	_check(registration.token != old_token, config_name + " replacement has a new token")
	_admit(coordinator, registration, enemy)
	_check(not coordinator.suspend_enemy(enemy, old_token), config_name + " retired token cannot suspend replacement")
	await get_tree().process_frame
	_check_area(enemy, false, config_name + " stale callback rejected")
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)
	await get_tree().process_frame
	_check_area(enemy, true, config_name + " LEGACY rollback")
	coordinator.set_mode(EnemySimulationPolicy.Mode.LAYERED_CONTACT)
	registration = coordinator._get_owned_registration(enemy, enemy.enemy_simulation_token)
	_admit(coordinator, registration, enemy)
	enemy.is_dead = true
	_check(coordinator.suspend_enemy(enemy, registration.token), config_name + " dead owner releases indexed proxy")
	await get_tree().process_frame
	_check(not enemy.indexed_touch_authority_enabled, config_name + " dead suspended owner drops indexed ownership")
	_check(not enemy.touch_damage_area.monitoring and enemy.touch_damage_shapes[0].disabled,
		config_name + " deferred release keeps dead contact sensors disabled")
	enemy.free()
	coordinator.set_mode(EnemySimulationPolicy.Mode.LEGACY)


func _admit(coordinator: EnemySimulationCoordinator, registration: EnemySimulationCoordinator.Registration, enemy: Enemy) -> void:
	coordinator._admit_layered_contact_proxies_for_tick(Engine.get_physics_frames() + 1, 0)
	coordinator._refresh_layered_relation_revision(true)
	coordinator._refresh_indexed_touch_player_candidates()
	coordinator._indexed_touch_has_registered_plants_this_tick = coordinator._damageable_spatial_index.has_registered_damageables()
	coordinator._indexed_touch_plant_geometry_revision_this_tick = coordinator._damageable_spatial_index.get_geometry_revision()
	_check(registration != null and registration.indexed_touch_authority_capable and registration.contact_attacker_shape != null,
		"Existing single-shape registration admits through its original exact geometry gate")
	_check(coordinator._sync_indexed_touch_contacts(registration, enemy), "Existing single-shape snapshot synchronizes")
	_check(enemy.indexed_touch_authority_enabled, "Indexed sensor owns the synchronized contact snapshot")


func _check_area(enemy: Enemy, native_enabled: bool, label: String) -> void:
	_check(enemy.touch_damage_area.monitoring == (native_enabled and enemy.authored_touch_area_monitoring), label + " restores authored monitoring")
	_check(enemy.touch_damage_area.monitorable == (native_enabled and enemy.authored_touch_area_monitorable), label + " restores authored monitorable")
	_check(enemy.touch_damage_area.collision_layer == (enemy.authored_touch_area_collision_layer if native_enabled else 0), label + " restores authored layer")
	_check(enemy.touch_damage_area.collision_mask == (enemy.authored_touch_area_collision_mask if native_enabled else 0), label + " restores authored mask")
	_check(enemy.touch_damage_shapes[0].disabled == (not native_enabled), label + " restores its original active shape")
	_check(not enemy.body_collision_shapes[0].disabled, label + " does not disable CharacterBody collision")


func _check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures.append(message)
		push_error(message)
