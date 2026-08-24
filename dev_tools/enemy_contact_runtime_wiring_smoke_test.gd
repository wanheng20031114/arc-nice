extends SceneTree

const POLICY := preload(
	"res://scene/combat/simulation/enemy_simulation_policy.gd"
)
const RELATIONS := preload(
	"res://scene/combat/faction/combat_relation_service.gd"
)
const RUNTIME_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)
const FAST_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_fast.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PREDICTIVE_HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/predictive_contact_yuanshi_harness.tscn"
)
const COMPAT_HANDOFF_HARNESS_SCENE := preload(
	"res://dev_tools/fixtures/compat_handoff_capoo_ak47_harness.tscn"
)
const CAPOO_AK47_CONFIG := preload(
	"res://resources/config/enemies/capoo_ak47.tres"
)

const PRODUCTION_SCENES: Array[String] = [
	"res://scene/game_modes/standard/standard_game.tscn",
	"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
	"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
]

var failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_authored_scene_contracts()
	await _test_runtime_ownership_contact_phase_and_rollback()
	await _test_indexed_player_exit_invalidates_nonempty_snapshot()
	_test_freed_indexed_contact_records_cleanup_by_instance_id()
	await _test_indexed_plant_and_relation_dirty_invalidation()
	await _test_in_tick_compat_fallback_preserves_individual_tick()
	await _test_initial_contact_proxy_failure_falls_back()
	await _test_high_speed_opposing_motion_clips_before_crossing()
	await _test_same_direction_pursuit_closes_without_false_stop()
	await _test_third_enemy_objective_remains_shadow_and_reaches_contact()
	await _test_non_mutual_transverse_crossing_is_not_frozen()
	await _test_asymmetric_mutual_shell_converges_without_crossing()
	await _test_same_tick_facing_mirror_recaptures_offset_segment()
	if failures.is_empty():
		print("ENEMY_CONTACT_RUNTIME_WIRING_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_scene_contracts() -> void:
	for scene_path in PRODUCTION_SCENES:
		var source := FileAccess.get_file_as_string(scene_path)
		var has_coordinator := source.contains(
			"[node name=\"EnemySimulationCoordinator\" parent=\".\""
		)
		var has_contact_service := source.contains(
			"[node name=\"EnemyContactService\" parent=\".\""
		) and source.contains(
			"res://scene/combat/contact/enemy_contact_service.tscn"
		)
		_expect(
			has_coordinator and has_contact_service,
			"%s must author both simulation and contact siblings." % scene_path
		)


func _test_runtime_ownership_contact_phase_and_rollback() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	_expect(coordinator != null and service != null, "The runtime fixture must author both services.")
	if coordinator == null or service == null:
		runtime.queue_free()
		await process_frame
		return
	_expect(
		runtime.get_combat_relation_service()
		== runtime.get_combat_relation_service()
		and runtime.get_combat_query_facade()
		== runtime.get_combat_query_facade(),
		"Combat relation and query services must have one stable runtime owner."
	)
	_expect(
		coordinator.mode == POLICY.Mode.LEGACY
		and service.mode == EnemyContactService.Mode.DISABLED
		and not service.automatic_physics_step,
		"The stable LEGACY default must leave shared contact takeover disabled."
	)

	runtime.enable_singleplayer_combat_target_index(true)
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var attacker := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	var target := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	attacker.global_position = Vector2.ZERO
	target.global_position = Vector2.ZERO
	runtime.enemy_container.add_child(attacker)
	runtime.enemy_container.add_child(target)
	attacker.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	target.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	target.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	var attacker_id := coordinator.get_simulation_id(
		attacker,
		attacker.enemy_simulation_token
	)
	var target_id := coordinator.get_simulation_id(
		target,
		target.enemy_simulation_token
	)
	await physics_frame
	await physics_frame
	_expect(
		attacker_id > 0
		and target_id > 0
		and service.owns_enemy(attacker, attacker_id)
		and service.owns_enemy(target, target_id),
		"Layered enemies with authored touch/body shapes must register contact proxies."
	)

	await physics_frame
	var service_metrics: Dictionary = service.get_metrics()
	var coordinator_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		service.mode == EnemyContactService.Mode.HYBRID_ENEMY_CONTACT
		and int(coordinator_metrics["contact_phases"]) > 0
		and int(service_metrics["hybrid_enemy_contact_ticks"]) > 0
		and int(service_metrics["predicted_event_stream_skips_total"]) > 0,
		"Contact must step exactly inside LAYERED_CONTACT between event and decision phases."
	)
	_expect(
		service.has_directed_contact(attacker, target)
		and service.has_directed_contact(target, attacker),
		"Runtime hostile AABB wiring must expose overlapping enemy-enemy contact."
	)
	_expect(
		attacker.is_indexed_touch_authority_enabled()
		and target.is_indexed_touch_authority_enabled()
		and attacker.is_touch_damage_shape_authored_enabled(
			attacker.touch_damage_shape
		)
		and attacker.touch_damage_shape.disabled
		and target.touch_damage_shape.disabled
		and not attacker.collision_shape.disabled
		and not target.collision_shape.disabled
		and not attacker.touch_damage_area.monitoring
		and not target.touch_damage_area.monitoring
		and attacker.touch_damage_area.collision_layer == 0
		and attacker.touch_damage_area.collision_mask == 0
		and attacker.collision_layer == 4,
		"Indexed authority must disable only TouchDamageArea physics shapes while preserving the enabled layer-4 hit body."
	)

	# EnemyContactService must consume its cached proxy/local transform rather
	# than depending on the now-disabled TouchDamageArea physics shape.
	target.global_position = Vector2(1024.0, 0.0)
	target.reset_physics_interpolation()
	await physics_frame
	await physics_frame
	_expect(
		not service.has_directed_contact(attacker, target)
		and not service.has_directed_contact(target, attacker)
		and attacker.touch_damage_shape.disabled
		and target.touch_damage_shape.disabled,
		"Cached contact geometry must publish EXIT while authored touch shapes remain physically disabled."
	)
	target.global_position = attacker.global_position
	target.reset_physics_interpolation()
	await physics_frame
	await physics_frame
	_expect(
		service.has_directed_contact(attacker, target)
		and service.has_directed_contact(target, attacker)
		and attacker.touch_damage_shape.disabled
		and target.touch_damage_shape.disabled,
		"Cached contact geometry must publish ENTER without re-enabling TouchDamageArea shapes."
	)

	coordinator.set_mode(POLICY.Mode.LEGACY)
	service_metrics = service.get_metrics()
	_expect(
		service.mode == EnemyContactService.Mode.DISABLED
		and int(service_metrics["registered_count"]) == 0
		and not service.has_directed_contact(attacker, target),
		"Tick-boundary rollback must clear proxies and restore DISABLED immediately."
	)
	_expect(
		not attacker.is_centrally_simulated()
		and not target.is_centrally_simulated()
		and not attacker.is_indexed_touch_authority_enabled()
		and not target.is_indexed_touch_authority_enabled(),
		"Contact rollback must not interfere with legacy enemy callback restoration."
	)
	await physics_frame
	_expect(
		attacker.touch_damage_area.monitoring
		and not attacker.touch_damage_shape.disabled
		and not attacker.collision_shape.disabled
		and attacker.touch_damage_area.collision_layer == 8
		and attacker.touch_damage_area.collision_mask == 514,
		"LEGACY rollback must restore the authored TouchDamageArea contract."
	)

	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	await physics_frame
	await physics_frame
	_expect(
		attacker.is_indexed_touch_authority_enabled(),
		"Reclaimed LAYERED_CONTACT ownership must re-enable indexed touch."
	)
	coordinator.clear(true)
	await physics_frame
	_expect(
		not attacker.is_centrally_simulated()
		and attacker.is_physics_processing()
		and not attacker.is_indexed_touch_authority_enabled()
		and not attacker.touch_damage_shape.disabled
		and not attacker.collision_shape.disabled
		and attacker.touch_damage_area.monitoring
		and attacker.touch_damage_area.collision_layer == 8
		and attacker.touch_damage_area.collision_mask == 514,
		"Direct clear(true) must atomically restore individual callbacks and authored contact."
	)

	_expect(
		attacker.try_attach_to_enemy_simulation_coordinator(coordinator)
		and target.try_attach_to_enemy_simulation_coordinator(coordinator),
		"Live enemies must be reclaimable after a direct clear."
	)
	await physics_frame
	await physics_frame
	_expect(
		attacker.is_indexed_touch_authority_enabled(),
		"Reattached enemies must pass contact admission again."
	)
	coordinator.clear(false)
	await physics_frame
	_expect(
		not attacker.is_centrally_simulated()
		and not attacker.is_physics_processing()
		and not attacker.is_indexed_touch_authority_enabled()
		and not attacker.touch_damage_shape.disabled
		and not attacker.collision_shape.disabled
		and attacker.touch_damage_area.monitoring
		and attacker.touch_damage_area.collision_layer == 8
		and attacker.touch_damage_area.collision_mask == 514,
		"Direct clear(false) must release ownership and contact without resuming callbacks."
	)

	var authored_touch_shape_disabled := attacker.touch_damage_shape.disabled
	attacker.set_indexed_touch_authority(true)
	attacker.set_indexed_touch_authority(false)
	await process_frame
	_expect(
		attacker.touch_damage_shape.disabled
			== authored_touch_shape_disabled
		and attacker.touch_damage_area.monitoring,
		"A same-frame authority round trip must restore the captured authored shape state; stale deferred commits must be inert."
	)
	attacker.set_indexed_touch_authority(true)
	attacker.set_indexed_touch_authority(false)
	attacker.configure_multiplayer_proxy()
	await process_frame
	_expect(
		not attacker.touch_damage_area.monitoring
		and not attacker.touch_damage_area.monitorable
		and attacker.touch_damage_shape.disabled
		and not attacker.collision_shape.disabled
		and attacker.collision_layer == 4
		and attacker.touch_damage_area.collision_layer == 0
		and attacker.touch_damage_area.collision_mask == 0,
		"A stale deferred Area restore must not overwrite a same-frame proxy transition or disable the layer-4 hit body."
	)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_indexed_player_exit_invalidates_nonempty_snapshot() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)

	var player := PLAYER_SCENE.instantiate() as Player
	player.peer_id = 1
	runtime.add_child(player)
	runtime.bind_player_runtime_context(player)
	runtime.peer_players[player.peer_id] = player
	player.global_position = Vector2.ZERO
	player.reset_physics_interpolation()

	var stationary_config := FAST_CONFIG.duplicate(true) as YuanshiInsectConfig
	stationary_config.move_speed = 0.0
	var enemy := stationary_config.enemy_scene.instantiate() as YuanshiInsect
	enemy.global_position = Vector2.ZERO
	runtime.enemy_container.add_child(enemy)
	enemy.setup(stationary_config, player, runtime.grid_pathfinder, runtime)
	for _settle_tick in range(4):
		await physics_frame
	_expect(
		enemy.is_indexed_touch_authority_enabled()
		and enemy.touch_damage_shape.disabled
		and not enemy.collision_shape.disabled
		and enemy.touching_players.has(player.get_instance_id())
		and not enemy.indexed_touch_player_snapshot_is_empty(),
		"Indexed touch must first publish the real overlapping player snapshot."
	)

	# No enemy Transform, plant geometry, relation or faction changes here. Moving
	# only the player outside the broad phase reproduces the complete-snapshot fast
	# path that previously retained a stale touching_players entry forever.
	player.global_position = Vector2(4096.0, 0.0)
	player.reset_physics_interpolation()
	for _exit_tick in range(3):
		await physics_frame
	_expect(
		not enemy.touching_players.has(player.get_instance_id())
		and enemy.indexed_touch_player_snapshot_is_empty(),
		"A player leaving broad phase must publish EXIT and clear indexed touch state."
	)
	var before_corridor_metrics: Dictionary = coordinator.get_metrics()
	# Move both endpoints while they remain thousands of pixels apart. A Player
	# geometry change must invalidate only its swept neighborhood; it must not turn
	# every moving enemy's Transform notification into a full exact resync.
	player.global_position = Vector2(4080.0, 0.0)
	player.reset_physics_interpolation()
	enemy.global_position = Vector2(1.0, 0.0)
	await physics_frame
	await physics_frame
	var after_corridor_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_corridor_metrics["indexed_touch_dirty_drains"])
			== int(before_corridor_metrics["indexed_touch_dirty_drains"])
		and int(after_corridor_metrics["indexed_touch_empty_corridor_skips"])
			> int(before_corridor_metrics["indexed_touch_empty_corridor_skips"]),
		"A far Player sweep and enemy motion must retain the local empty certificate without an exact resync."
	)

	# CombatTargetIndex and indexed contact independently own root Transform
	# notifications. Unbinding the spatial index must not silence contact dirties.
	runtime.unregister_combat_target(enemy.get_instance_id())
	_expect(
		enemy.combat_target_index_binding == null
		and enemy.indexed_touch_transform_notifications_required,
		"Contact authority must retain Transform notifications after target-index unbind."
	)
	var before_unbound_move_metrics: Dictionary = coordinator.get_metrics()
	# The broad phase is expressed in CollisionShape2D world space. A local shape
	# offset must therefore still meet the moved-enemy relative-sweep path even
	# after this enemy has been removed from CombatTargetIndex.
	player.collision_shape.position += Vector2(96.0, 0.0)
	enemy.global_position = player.collision_shape.global_position
	for _unbound_enter_tick in range(2):
		await physics_frame
	var after_unbound_move_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		enemy.touching_players.has(player.get_instance_id())
		and int(after_unbound_move_metrics["indexed_touch_dirty_drains"])
			> int(before_unbound_move_metrics["indexed_touch_dirty_drains"]),
		"An unindexed enemy must publish Player ENTER from the relative Transform sweep queue."
	)

	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_freed_indexed_contact_records_cleanup_by_instance_id() -> void:
	var enemy := Enemy.new()
	enemy.indexed_touch_authority_enabled = true
	var player := Player.new()
	player.peer_id = 1
	var plant := PlantDefense.new()
	enemy._track_touching_player(player, false)
	enemy._track_touching_plant(plant)
	enemy.touched_player = player
	var player_id := player.get_instance_id()
	var plant_id := plant.get_instance_id()
	_expect(
		enemy.touching_players.has(player_id)
		and enemy.touching_player_death_callbacks.has(player_id)
		and enemy.touching_plants.has(plant_id)
		and enemy.touching_plant_entry_distances.has(plant_id)
		and enemy.touching_plant_removal_callbacks.has(plant_id),
		"Freed-record regression must begin with complete Player and Plant contact bookkeeping."
	)

	player.free()
	plant.free()
	enemy.cached_navigation_move_direction = Vector2.ONE
	enemy.layered_area_decision_urgent = false
	var empty_players: Array[Player] = []
	var empty_plants: Array = []
	var synchronized := enemy.synchronize_indexed_touch_contacts(
		empty_players,
		empty_plants
	)
	_expect(
		synchronized
		and enemy.touching_players.is_empty()
		and enemy.touching_player_death_callbacks.is_empty()
		and enemy.touched_player == null
		and enemy.touching_plants.is_empty()
		and enemy.touching_plant_entry_distances.is_empty()
		and enemy.touching_plant_removal_callbacks.is_empty()
		and enemy.touched_plant == null,
		"A freed Player or Plant must be removed by instance ID without "
			+ "casting the stale Object, including every callback and distance record."
	)
	_expect(
		enemy.cached_navigation_move_direction == Vector2.ZERO
		and enemy.layered_area_decision_urgent,
		"Removing stale contact records must invalidate navigation and wake the layered decision lane."
	)
	enemy.free()


func _test_indexed_plant_and_relation_dirty_invalidation() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var stationary_config := FAST_CONFIG.duplicate(true) as YuanshiInsectConfig
	stationary_config.move_speed = 0.0
	var enemy := stationary_config.enemy_scene.instantiate() as YuanshiInsect
	enemy.global_position = Vector2.ZERO
	runtime.enemy_container.add_child(enemy)
	enemy.setup(stationary_config, null, runtime.grid_pathfinder, runtime)
	for _admission_tick in range(3):
		await physics_frame

	var plant := PlantDefense.new()
	plant.max_health = 100
	plant.current_health = 100
	var plant_shape_node := CollisionShape2D.new()
	var plant_shape := CircleShape2D.new()
	plant_shape.radius = 8.0
	plant_shape_node.shape = plant_shape
	plant.add_child(plant_shape_node)
	runtime.add_child(plant)
	plant.global_position = Vector2.ZERO
	var damageable_index := (
		coordinator.get_combat_services().get_enemy_damageable_spatial_index()
	)
	_expect(
		damageable_index != null
		and damageable_index.register_damageable(plant),
		"The dirty-scheduler plant fixture must register in the production damageable index."
	)
	for _plant_enter_tick in range(2):
		await physics_frame
	_expect(
		enemy.touching_plants.has(plant.get_instance_id())
		and enemy.touch_damage_shape.disabled
		and not enemy.collision_shape.disabled,
		"A plant geometry revision introducing an overlap must enqueue and publish Plant ENTER."
	)

	plant.global_position = Vector2(1024.0, 0.0)
	_expect(
		damageable_index.update_damageable(plant),
		"Moving the indexed plant must advance its geometry revision."
	)
	for _plant_exit_tick in range(2):
		await physics_frame
	_expect(
		not enemy.touching_plants.has(plant.get_instance_id()),
		"A plant geometry revision removing an overlap must enqueue and publish Plant EXIT."
	)

	var before_relation_metrics: Dictionary = coordinator.get_metrics()
	var relations := runtime.get_combat_relation_service()
	_expect(
		relations.set_hostile(3, 4, true),
		"The relation dirty fixture must accept a directed relation mutation."
	)
	await physics_frame
	var after_relation_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_relation_metrics["indexed_touch_dirty_drains"])
			> int(before_relation_metrics["indexed_touch_dirty_drains"]),
		"A relation revision must invalidate stationary indexed-contact certificates."
	)

	var before_faction_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		enemy.set_combat_faction_id(RELATIONS.PLAYER_ALLIED),
		"The faction dirty fixture must accept a runtime faction mutation."
	)
	await physics_frame
	var after_faction_metrics: Dictionary = coordinator.get_metrics()
	_expect(
		int(after_faction_metrics["indexed_touch_dirty_drains"])
			> int(before_faction_metrics["indexed_touch_dirty_drains"]),
		"A faction mutation must enqueue the exact enemy without a cohort scan."
	)

	damageable_index.unregister_damageable(plant)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_in_tick_compat_fallback_preserves_individual_tick() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_AREA)

	var requester := (
		PREDICTIVE_HARNESS_SCENE.instantiate()
		as PredictiveContactYuanshiHarness
	)
	runtime.enemy_container.add_child(requester)
	requester.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	# Keep this fixture access dynamic: a fresh checkout has not populated the
	# editor's global class cache for the newly added harness yet.
	var compat_only = COMPAT_HANDOFF_HARNESS_SCENE.instantiate()
	runtime.enemy_container.add_child(compat_only)
	compat_only.setup(CAPOO_AK47_CONFIG, null, runtime.grid_pathfinder, runtime)
	await physics_frame
	await process_frame
	_expect(
		requester.is_centrally_simulated()
		and not compat_only.is_centrally_simulated()
		and compat_only.is_physics_processing(),
		"LAYERED_AREA must initially leave a COMPAT-only family on its individual callback."
	)

	compat_only.runner_records.clear()
	requester.request_compat_mode_on_next_event = true
	await physics_frame
	var fallback_physics_frame := Engine.get_physics_frames()
	await process_frame
	var old_frame_individual_steps := 0
	for record in compat_only.runner_records:
		if (
			int(record["physics_frame"]) == fallback_physics_frame
			and not bool(record["centralized"])
		):
			old_frame_individual_steps += 1
	_expect(
		coordinator.mode == POLICY.Mode.COMPAT_60
		and old_frame_individual_steps == 1
		and compat_only.is_centrally_simulated(),
		"An in-tick COMPAT fallback must let a later individual family finish the old frame before deferred ownership."
	)

	await physics_frame
	var first_compat_physics_frame := Engine.get_physics_frames()
	await process_frame
	var next_frame_scheduled_steps := 0
	for record in compat_only.runner_records:
		if (
			int(record["physics_frame"]) == first_compat_physics_frame
			and bool(record["centralized"])
		):
			next_frame_scheduled_steps += 1
	_expect(
		next_frame_scheduled_steps == 1,
		"Deferred ownership must dispatch the COMPAT family exactly once on the next 60 Hz tick."
	)

	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_initial_contact_proxy_failure_falls_back() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var enemy := FAST_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	var authored_shape := enemy.touch_damage_shape.shape
	enemy.touch_damage_shape.shape = null
	await physics_frame
	await physics_frame
	var metrics: Dictionary = coordinator.get_metrics()
	_expect(
		coordinator.mode == POLICY.Mode.COMPAT_60
		and enemy.is_centrally_simulated()
		and not enemy.is_indexed_touch_authority_enabled()
		and enemy.touch_damage_area.monitoring
		and int(metrics["contact_registration_rejections"]) > 0,
		"Initial contact-proxy admission failure must preserve Area authority and fall back to COMPAT_60."
	)
	enemy.touch_damage_shape.shape = authored_shape
	coordinator.clear(false)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_high_speed_opposing_motion_clips_before_crossing() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var high_speed_config := FAST_CONFIG.duplicate(true) as YuanshiInsectConfig
	var left := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	var right := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	left.set("forced_move_direction", Vector2.RIGHT)
	right.set("forced_move_direction", Vector2.LEFT)
	left.set("forced_move_speed", 2400.0)
	right.set("forced_move_speed", 2400.0)
	left.global_position = Vector2(-20.0, 0.0)
	right.global_position = Vector2(20.0, 0.0)
	runtime.enemy_container.add_child(left)
	runtime.enemy_container.add_child(right)
	left.setup(high_speed_config, null, runtime.grid_pathfinder, runtime)
	right.setup(high_speed_config, null, runtime.grid_pathfinder, runtime)
	right.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	left.set_objective_target(right)
	right.set_objective_target(left)
	# Keep the test deterministic: advance the authored coordinator manually only
	# after the registration activation frame has elapsed.
	coordinator.set_physics_process(false)
	await physics_frame
	var left_start := left.global_position
	var right_start := right.global_position
	coordinator._physics_process(1.0 / 60.0)
	var first_left := left.global_position
	var first_right := right.global_position
	_expect(
		first_left.x < first_right.x,
		"Opposing 2400 px/s enemies must not exchange sides in their first movement tick."
	)
	_expect(
		first_left.x > left_start.x
		and first_right.x < right_start.x
		and first_left.distance_to(first_right) >= 11.9,
		"Predictive TOI must advance both enemies to, but not through, the authored shell."
	)
	_expect(
		left.velocity == Vector2.ZERO and right.velocity == Vector2.ZERO,
		"A TOI-clipped enemy must report stopped velocity in the same tick."
	)

	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	_expect(
		left.global_position.is_equal_approx(first_left)
		and right.global_position.is_equal_approx(first_right)
		and service.has_directed_contact(left, right)
		and service.has_directed_contact(right, left),
		"The next current snapshot must confirm shell contact without a one-frame overshoot."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_same_direction_pursuit_closes_without_false_stop() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var pursuer := _spawn_harness(runtime, Vector2.ZERO, Vector2.RIGHT, 120.0)
	var target := _spawn_harness(runtime, Vector2(30.0, 0.0), Vector2.RIGHT, 60.0)
	target.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	var non_enemy_objective := Node2D.new()
	non_enemy_objective.position = Vector2(300.0, 0.0)
	runtime.add_child(non_enemy_objective)
	pursuer.set_objective_target(target)
	target.set_objective_target(non_enemy_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	var previous_gap := target.global_position.x - pursuer.global_position.x
	var reached_shell := false
	var pursuer_start_x := pursuer.global_position.x
	for _tick in range(30):
		coordinator._physics_process(1.0 / 60.0)
		var gap := target.global_position.x - pursuer.global_position.x
		if gap > 12.1 and not service.has_directed_contact(pursuer, target):
			_expect(
				is_equal_approx(
					service.get_directed_safe_motion_fraction(pursuer, target),
					1.0
				),
				"A separated moving non-mutual target must remain shadow-only."
			)
		_expect(
			gap > 0.0,
			"A faster same-direction pursuer must never pass through its moving target."
		)
		if not reached_shell:
			_expect(
				gap <= previous_gap + 0.001,
				"Committed same-direction pursuit must close distance monotonically."
			)
		if gap <= 12.1:
			reached_shell = true
		previous_gap = gap
		await physics_frame
	_expect(
		reached_shell
		and pursuer.global_position.x > pursuer_start_x + 5.0
		and int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"A faster pursuer must reach the authored shell instead of freezing at expanded range."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_third_enemy_objective_remains_shadow_and_reaches_contact() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var pursuer := _spawn_harness(runtime, Vector2.ZERO, Vector2.RIGHT, 120.0)
	var middle := _spawn_harness(runtime, Vector2(24.0, 0.0), Vector2.RIGHT, 60.0)
	var leader := _spawn_harness(runtime, Vector2(100.0, 0.0), Vector2.RIGHT, 60.0)
	middle.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	pursuer.set_objective_target(middle)
	middle.set_objective_target(leader)
	var leader_objective := Node2D.new()
	leader_objective.position = Vector2(300.0, 0.0)
	runtime.add_child(leader_objective)
	leader.set_objective_target(leader_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	var reached_current_contact := false
	for _tick in range(30):
		coordinator._physics_process(1.0 / 60.0)
		_expect(
			pursuer.global_position.x < middle.global_position.x,
			"A shadow-only dependency pair must not pass through at normal authored speed."
		)
		if service.has_directed_contact(pursuer, middle):
			reached_current_contact = true
		await physics_frame
	_expect(
		reached_current_contact
		and int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"A->B->C must remain shadow-only yet still reach exact current contact."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_non_mutual_transverse_crossing_is_not_frozen() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var horizontal := _spawn_harness(
		runtime, Vector2(-20.0, 0.0), Vector2.RIGHT, 2400.0
	)
	var vertical := _spawn_harness(
		runtime, Vector2(0.0, -20.0), Vector2.DOWN, 2400.0
	)
	var third := _spawn_harness(
		runtime, Vector2(0.0, 100.0), Vector2.ZERO, 0.0
	)
	vertical.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	horizontal.set_objective_target(vertical)
	vertical.set_objective_target(third)
	var third_objective := Node2D.new()
	third_objective.position = third.position
	runtime.add_child(third_objective)
	third.set_objective_target(third_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	_expect(
		horizontal.global_position.x > 19.5
		and vertical.global_position.y > 19.5
		and is_equal_approx(
			service.get_directed_safe_motion_fraction(horizontal, vertical),
			1.0
		),
		"A non-mutual transverse shadow pair must execute full plans instead of freezing."
	)
	_expect(
		int(service.get_metrics()["uncommitted_pair_shadow_hits_total"]) > 0,
		"A transverse authority skip must be explicitly measured."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_asymmetric_mutual_shell_converges_without_crossing() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var left := _spawn_harness(
		runtime, Vector2(-20.0, 0.0), Vector2.RIGHT, 2400.0
	)
	var right := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	right.set("forced_move_direction", Vector2.LEFT)
	right.set("forced_move_speed", 2400.0)
	right.global_position = Vector2(20.0, 0.0)
	var large_touch := CapsuleShape2D.new()
	large_touch.radius = 5.0
	large_touch.height = 20.0
	right.get_node("TouchDamageArea/CollisionShape2D").shape = large_touch
	runtime.enemy_container.add_child(right)
	right.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	right.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	left.set_objective_target(right)
	right.set_objective_target(left)
	coordinator.set_physics_process(false)
	await physics_frame
	var gaps: Array[float] = []
	for _tick in range(3):
		coordinator._physics_process(1.0 / 60.0)
		gaps.append(right.global_position.x - left.global_position.x)
		_expect(
			left.global_position.x < right.global_position.x,
			"Asymmetric mutual shells must never swap sides across follow-up ticks."
		)
		await physics_frame
	_expect(
		gaps[1] < gaps[0] - 0.01
		and gaps[2] <= gaps[1] + 0.01
		and gaps[2] >= 11.9,
		"After the larger shell stops, the smaller shell must keep closing without oscillation."
	)
	var service := runtime.get_enemy_contact_service()
	_expect(
		service.has_directed_contact(left, right)
		and service.has_directed_contact(right, left),
		"Asymmetric mutual pursuit must finish inside both directed attack shells."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _test_same_tick_facing_mirror_recaptures_offset_segment() -> void:
	var runtime := RUNTIME_SCENE.instantiate() as EnemyGameplayGatewayTestRuntime
	root.add_child(runtime)
	await process_frame
	runtime.enable_singleplayer_combat_target_index(true)
	var coordinator := runtime.get_enemy_simulation_coordinator()
	var service := runtime.get_enemy_contact_service()
	coordinator.set_mode(POLICY.Mode.LAYERED_CONTACT)
	var turner := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	turner.set("forced_move_direction", Vector2.LEFT)
	turner.set("forced_move_speed", 2400.0)
	turner.global_position = Vector2(20.0, 0.0)
	var touch_shape_node := (
		turner.get_node("TouchDamageArea/CollisionShape2D") as CollisionShape2D
	)
	touch_shape_node.position = Vector2(1.0, 0.0)
	var authored_segment := SegmentShape2D.new()
	authored_segment.a = Vector2(-2.0, 0.0)
	authored_segment.b = Vector2(4.0, 0.0)
	touch_shape_node.shape = authored_segment
	var body_shape_node := turner.get_node("CollisionShape2D") as CollisionShape2D
	body_shape_node.position = Vector2(1.0, 0.0)
	runtime.enemy_container.add_child(turner)
	turner.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	turner.set_combat_faction_id(RELATIONS.PLAYER_ALLIED)
	var target := _spawn_harness(
		runtime, Vector2.ZERO, Vector2.ZERO, 0.0
	)
	var target_objective := Node2D.new()
	target_objective.position = target.position
	runtime.add_child(target_objective)
	turner.set_objective_target(target)
	target.set_objective_target(target_objective)
	coordinator.set_physics_process(false)
	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	var mirrored_segment := touch_shape_node.shape as SegmentShape2D
	_expect(
		turner.facing_left
		and is_equal_approx(touch_shape_node.position.x, -1.0)
		and mirrored_segment != null
		and mirrored_segment.a.is_equal_approx(Vector2(2.0, 0.0))
		and mirrored_segment.b.is_equal_approx(Vector2(-4.0, 0.0)),
		"Decision must commit offset/Segment facing geometry before planned contact sampling."
	)
	_expect(
		absf(turner.global_position.x - 7.0) <= 0.01
		and int(service.get_metrics()["shape_proxy_updates_total"]) >= 1,
		(
			"Same-tick TOI must use the recaptured mirrored segment, not its stale +X core "
			+ "(source_x=%.3f, target_x=%.3f, fraction=%.5f, proxy_updates=%d)."
		) % [
			turner.global_position.x,
			target.global_position.x,
			service.get_directed_safe_motion_fraction(turner, target),
			int(service.get_metrics()["shape_proxy_updates_total"]),
		]
	)
	await physics_frame
	coordinator._physics_process(1.0 / 60.0)
	_expect(
		service.has_directed_contact(turner, target)
		and turner.global_position.x >= target.global_position.x,
		"The mirrored offset shell must become exact current contact without crossing."
	)
	coordinator.set_mode(POLICY.Mode.LEGACY)
	runtime.queue_free()
	await process_frame
	await physics_frame


func _spawn_harness(
	runtime: EnemyGameplayGatewayTestRuntime,
	spawn_position: Vector2,
	move_direction: Vector2,
	move_speed: float
) -> YuanshiInsect:
	var enemy := PREDICTIVE_HARNESS_SCENE.instantiate() as YuanshiInsect
	enemy.set("forced_move_direction", move_direction)
	enemy.set("forced_move_speed", move_speed)
	enemy.global_position = spawn_position
	runtime.enemy_container.add_child(enemy)
	enemy.setup(FAST_CONFIG, null, runtime.grid_pathfinder, runtime)
	return enemy


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
