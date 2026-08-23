extends SceneTree

const MpProjectileCoordinator := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MAGE_SCENE := preload("res://scene/enemy/capoo/capoo_mage.tscn")
const SNIPER_SCENE := preload("res://scene/enemy/capoo/capoo_sniper.tscn")
const SMG_SCENE := preload("res://scene/enemy/capoo/capoo_smg.tscn")
const FIREBALL_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball.tscn")
const FIREBALL_IMPACT_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn")
const RETICLE_SCENE := preload("res://scene/enemy/capoo/capoo_sniper_lock_reticle.tscn")
const RETICLE_COORDINATOR_SCRIPT := preload(
	"res://scene/enemy/capoo/capoo_sniper_lock_visual_coordinator.gd"
)
const EnemyWarningPresentationSystemScript := preload(
	"res://scene/combat/presentation/enemy_warning_presentation_system.gd"
)
const SMG_BULLET_SCENE := preload("res://scene/enemy/capoo/capoo_smg_bullet.tscn")
const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const MAGE_CONFIG := preload("res://resources/config/enemies/capoo_mage.tres")
const SNIPER_CONFIG := preload("res://resources/config/enemies/capoo_sniper.tres")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")
const WAVE_09 := preload("res://resources/config/waves/wave_09.tres")
const WAVE_10 := preload("res://resources/config/waves/wave_10.tres")
const WAVE_11 := preload("res://resources/config/waves/wave_11.tres")
const MP_GAME_SCRIPT := preload("res://scene/multiplayer/mp_game.gd")
const COMBAT_RUNTIME_FIXTURE_SCENE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)


var failures: Array[String] = []
var test_root: EnemyGameplayGatewayTestRuntime
var spawned_smg_bullets: Array[CapooAK47Bullet] = []
var spawned_smg_bullet_directions := PackedVector2Array()
var reticle_coordinator: CapooSniperLockVisualCoordinator = null
var warning_system: EnemyWarningPresentationSystemScript = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = (
		COMBAT_RUNTIME_FIXTURE_SCENE.instantiate()
		as EnemyGameplayGatewayTestRuntime
	)
	test_root.name = "CapooVariantSmokeTest"
	root.add_child(test_root)
	test_root.child_entered_tree.connect(_on_child_entered_tree)
	var combat_services := test_root.get_enemy_combat_services()
	warning_system = (
		combat_services.get_enemy_warning_presentation_system()
		if combat_services != null
		else null
	)
	_expect(
		warning_system != null,
		"Capoo fixture must mount the shared enemy warning presentation system."
	)
	_expect(
		test_root.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER,
		"Capoo local combat fixture must declare explicit SINGLEPLAYER authority."
	)
	reticle_coordinator = RETICLE_COORDINATOR_SCRIPT.new() as CapooSniperLockVisualCoordinator
	reticle_coordinator.name = "SniperLockVisualCoordinator"
	test_root.add_child(reticle_coordinator)

	_test_resource_contract()
	_test_shared_sniper_warning_arbitration()
	await _test_reticle_highest_progress_priority()
	await _test_reticle_coordinator_runtime_scope()
	await _test_mage_windup_fireball_and_obstruction()
	await _test_fireball_impact_damage_and_release()
	await _test_sniper_lock_cancel_and_damage()
	await _test_smg_scatter_fire()
	await _test_smg_no_pathfinder_direct_chase_respects_world_wall()
	await _test_proxy_action_visuals()
	_test_multiplayer_projectile_registry()
	_test_wave_entries()
	if warning_system != null:
		_expect(
			int(warning_system.get_metrics()["live_warnings"]) == 0,
			"Capoo smoke teardown must leave zero shared warning handles."
		)

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("CAPOO_VARIANT_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_contract() -> void:
	_expect(MAGE_CONFIG is CapooMageConfig, "Mage config must use CapooMageConfig.")
	_expect(SNIPER_CONFIG is CapooSniperConfig, "Sniper config must use CapooSniperConfig.")
	_expect(SMG_CONFIG is CapooSMGConfig, "SMG config must use CapooSMGConfig.")

	_expect(MAGE_CONFIG.enemy_scene == MAGE_SCENE, "Mage Capoo must use its own scene.")
	_expect(SNIPER_CONFIG.enemy_scene == SNIPER_SCENE, "Sniper Capoo must use its own scene.")
	_expect(SMG_CONFIG.enemy_scene == SMG_SCENE, "SMG Capoo must use its own scene.")
	_expect(
		not _object_has_property(MAGE_CONFIG, &"projectile_scene"),
		"Mage production config must not retain the legacy fireball scene."
	)
	_expect(
		FIREBALL_SCENE != null,
		"Legacy Mage fireball scene must remain available for isolated regression fixtures."
	)
	_expect(SNIPER_CONFIG.lock_reticle_scene == RETICLE_SCENE, "Legacy sniper reticle regression resource must remain available.")
	_expect(SMG_CONFIG.projectile_scene == SMG_BULLET_SCENE, "SMG Capoo must use its short-lived bullet scene.")
	_expect(
		_resource_path(MAGE_CONFIG.attack_audio_stream).ends_with("capoo_mage_fireball_cast.wav"),
		"Mage Capoo must use the fireball cast audio stream."
	)
	_expect(
		_resource_path(SNIPER_CONFIG.attack_audio_stream).ends_with("capoo_sniper_fire.wav"),
		"Sniper Capoo must use the sniper fire audio stream."
	)
	_expect(
		_resource_path(SMG_CONFIG.attack_audio_stream).ends_with("capoo_smg_fire.wav"),
		"SMG Capoo must use its short dedicated fire audio stream."
	)

	_expect(MAGE_CONFIG.max_health == 200, "Mage health mismatch.")
	_expect(MAGE_CONFIG.attack_damage == 35, "Mage damage mismatch.")
	_expect(MAGE_CONFIG.physical_defense == 0 and MAGE_CONFIG.magic_defense == 0, "Mage defense mismatch.")
	_expect(is_equal_approx(MAGE_CONFIG.move_speed, 24.0), "Mage move speed mismatch.")
	_expect(is_equal_approx(MAGE_CONFIG.attack_windup, 1.0), "Mage windup mismatch.")
	_expect(is_equal_approx(MAGE_CONFIG.fireball_radius, 10.5), "Mage fireball radius mismatch.")
	_expect(MAGE_CONFIG.fireball_radius > 8.0, "Mage fireball should be slightly larger than a player body.")

	_expect(SNIPER_CONFIG.max_health == 100, "Sniper health mismatch.")
	_expect(SNIPER_CONFIG.attack_damage == 200, "Sniper damage mismatch.")
	_expect(SNIPER_CONFIG.physical_defense == 20 and SNIPER_CONFIG.magic_defense == 0, "Sniper defense mismatch.")
	_expect(is_equal_approx(SNIPER_CONFIG.move_speed, 80.0), "Sniper move speed mismatch.")
	_expect(is_equal_approx(SNIPER_CONFIG.lock_duration, 3.0), "Sniper lock duration mismatch.")

	_expect(SMG_CONFIG.max_health == 200, "SMG health mismatch.")
	_expect(SMG_CONFIG.attack_damage == 30, "SMG damage mismatch.")
	_expect(is_equal_approx(SMG_CONFIG.move_speed, 100.0), "SMG move speed mismatch.")
	_expect(is_equal_approx(SMG_CONFIG.fire_interval, 0.1), "SMG fire interval must represent 600 attack speed.")
	_expect(
		is_equal_approx(SMG_CONFIG.attack_range, 48.0),
		"SMG attack range must stay at its authored three-tile close range."
	)
	_expect(is_equal_approx(SMG_CONFIG.projectile_lifetime, 0.18), "SMG bullet lifetime must stay short.")
	_expect(is_equal_approx(SMG_CONFIG.spread_angle_degrees, 20.0), "SMG spread angle mismatch.")

	_expect(_texture_size("res://resources/texture/enemy/capoo/capoo_mage.png") == Vector2(1402, 1122), "Mage sprite sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/enemy/capoo/capoo_sniper.png") == Vector2(512, 384), "Sniper sprite sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/enemy/capoo/capoo_smg.png") == Vector2(640, 512), "SMG sprite sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/enemy/capoo/capoo_mage_fireball.png") == Vector2(384, 128), "Fireball sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/enemy/capoo/capoo_smg_bullet.png") == Vector2(48, 8), "SMG bullet sheet size mismatch.")
	_expect(_texture_size("res://resources/texture/enemy/capoo/capoo_sniper_lock_reticle.png") == Vector2(32, 32), "Sniper reticle texture size mismatch.")

	_expect(_has_capoo_frames(MAGE_CONFIG.enemy_scene, "Mage"), "Mage animation contract failed.")
	_expect(_has_mage_original_alpha_regions(), "Mage original alpha AtlasTexture regions failed.")
	_expect(_has_mage_visual_alignment(), "Mage visual alignment contract failed.")
	_expect(_has_capoo_frames(SNIPER_CONFIG.enemy_scene, "Sniper", Vector2(128.0, 96.0)), "Sniper animation contract failed.")
	_expect(_has_capoo_frames(SMG_CONFIG.enemy_scene, "SMG", Vector2(160.0, 128.0)), "SMG animation contract failed.")
	_expect(_has_smg_visual_alignment(), "SMG visual alignment contract failed.")
	_expect(_sprite_frames_count("res://resources/animation/capoo_mage_fireball.tres", &"fly") == 6, "Fireball frame count mismatch.")
	_expect(_sprite_frames_count("res://resources/animation/capoo_mage_fireball.tres", &"impact") == 6, "Fireball impact frame count mismatch.")
	_expect(_fireball_impact_animation_contract(), "Fireball impact animation contract failed.")
	_expect(_has_fireball_impact_audio(), "Fireball impact audio contract failed.")
	_expect(_sprite_frames_count("res://resources/animation/capoo_smg_bullet.tres", &"fly") == 3, "SMG bullet frame count mismatch.")
	_expect(_has_reticle_scene_contract(), "Sniper reticle scene contract failed.")
	_test_legacy_reticle_coordinator_removed_from_production_scenes()


func _test_shared_sniper_warning_arbitration() -> void:
	if warning_system == null:
		return
	var live_before := int(warning_system.get_metrics()["live_warnings"])
	var lower_owner: int = warning_system.acquire_sniper_reticle(4101, 9201)
	var higher_owner: int = warning_system.acquire_sniper_reticle(4102, 9201)
	_expect(
		warning_system.update_sniper_reticle(
			lower_owner,
			Vector2(120.0, 80.0),
			0.8
		)
		and warning_system.update_sniper_reticle(
			higher_owner,
			Vector2(120.0, 80.0),
			0.6
		)
		and warning_system.get_sniper_reticle_winner_handle(9201) == lower_owner,
		"Shared sniper reticle arbitration must prefer the highest progress."
	)
	warning_system.update_sniper_reticle(higher_owner, Vector2(120.0, 80.0), 0.8000001)
	_expect(
		warning_system.get_sniper_reticle_winner_handle(9201) == higher_owner,
		"Approximately equal reticle progress must prefer the larger owner id."
	)
	warning_system.release_warning(lower_owner)
	warning_system.release_warning(higher_owner)
	_expect(
		int(warning_system.get_metrics()["live_warnings"]) == live_before,
		"Shared sniper arbitration fixture leaked warning handles."
	)


func _test_legacy_reticle_coordinator_removed_from_production_scenes() -> void:
	var production_scene_paths: Array[String] = [
		"res://scene/game_modes/standard/standard_game.tscn",
		"res://scene/game_modes/tower_defense/tower_defense_game.tscn",
		"res://scene/game_modes/rogue/combat/rogue_combat_game_01.tscn",
		"res://scene/game_modes/rogue/combat/rogue_combat_game_02.tscn",
		"res://scene/game_modes/rogue/combat/rogue_combat_game_03.tscn",
		"res://scene/game_modes/rogue/combat/rogue_combat_game_04.tscn",
	]
	for scene_path in production_scene_paths:
		var packed_scene := load(scene_path) as PackedScene
		_expect(
			packed_scene != null,
			"Sniper presentation scene fixture failed to load: %s"
			% scene_path
		)
		if packed_scene == null:
			continue
		var scene_state := packed_scene.get_state()
		_expect(
			not _scene_state_has_node_named(
				scene_state,
				&"SniperLockVisualCoordinator"
			),
			"Production scene must not retain the idle legacy sniper coordinator: %s"
			% scene_path
		)
		_expect(
			_scene_state_has_instanced_scene(
				scene_state,
				&"EnemySimulationCoordinator",
				"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
			),
			"Production scene must retain the authored enemy simulation coordinator: %s"
			% scene_path
		)
	var coordinator_scene := load(
		"res://scene/combat/simulation/enemy_simulation_coordinator.tscn"
	) as PackedScene
	var services_scene := load(
		"res://scene/combat/simulation/enemy_combat_services.tscn"
	) as PackedScene
	_expect(
		coordinator_scene != null
		and _scene_state_has_instanced_scene(
			coordinator_scene.get_state(),
			&"EnemyCombatServices",
			"res://scene/combat/simulation/enemy_combat_services.tscn"
		)
		and services_scene != null
		and _scene_state_has_node_named(
			services_scene.get_state(),
			&"EnemyWarningPresentationSystem"
		),
		"The authored simulation coordinator must statically mount the shared warning system."
	)


func _test_reticle_highest_progress_priority() -> void:
	var player := _spawn_player(Vector2.ZERO, 100)
	var slow_reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	var urgent_reticle := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	player.add_child(slow_reticle)
	player.add_child(urgent_reticle)
	await process_frame
	slow_reticle.start(3.0, false)
	urgent_reticle.start(3.0, false)
	_expect(
		not slow_reticle.auto_progress
		and not urgent_reticle.auto_progress
		and not slow_reticle.is_processing()
		and not urgent_reticle.is_processing(),
		"Manually driven sniper reticles must not advance in their own process callback."
	)

	slow_reticle.set_progress(0.35)
	urgent_reticle.set_progress(0.75)
	await process_frame
	_expect(
		slow_reticle.uses_coordinated_arbitration()
		and urgent_reticle.uses_coordinated_arbitration(),
		"Runtime sniper reticles must register with the shared visual coordinator."
	)
	_expect(not slow_reticle.is_progress_display_active(), "Lower sniper reticle progress must stay hidden.")
	_expect(urgent_reticle.is_progress_display_active(), "Highest sniper reticle progress must be visible.")

	urgent_reticle.set_progress(0.2)
	slow_reticle.set_progress(0.6)
	await process_frame
	_expect(slow_reticle.is_progress_display_active(), "Reticle priority did not move to the new highest progress.")
	_expect(not urgent_reticle.is_progress_display_active(), "Reticle with lower updated progress remained visible.")

	slow_reticle.set_progress(0.8)
	urgent_reticle.set_progress(0.8)
	await process_frame
	var tie_winner := (
		urgent_reticle
		if urgent_reticle.get_instance_id() > slow_reticle.get_instance_id()
		else slow_reticle
	)
	_expect(
		tie_winner.is_progress_display_active(),
		"Equal-progress reticles must preserve the highest-instance-id tie break."
	)
	var cancelled_winner := tie_winner
	var remaining_reticle := slow_reticle if cancelled_winner == urgent_reticle else urgent_reticle
	cancelled_winner.get_parent().remove_child(cancelled_winner)
	cancelled_winner.free()
	await process_frame
	_expect(
		remaining_reticle.is_progress_display_active(),
		"Cancelling the winning lock must promote the remaining target reticle."
	)

	player.queue_free()
	await process_frame


func _test_reticle_coordinator_runtime_scope() -> void:
	var runtime_a := Node2D.new()
	var runtime_b := Node2D.new()
	runtime_a.name = "SniperRuntimeA"
	runtime_b.name = "SniperRuntimeB"
	test_root.add_child(runtime_a)
	test_root.add_child(runtime_b)

	var coordinator_a := RETICLE_COORDINATOR_SCRIPT.new() as CapooSniperLockVisualCoordinator
	var coordinator_b := RETICLE_COORDINATOR_SCRIPT.new() as CapooSniperLockVisualCoordinator
	coordinator_a.name = "SniperLockVisualCoordinator"
	coordinator_b.name = "SniperLockVisualCoordinator"
	runtime_a.add_child(coordinator_a)
	runtime_b.add_child(coordinator_b)
	var target_a := Node2D.new()
	var target_b := Node2D.new()
	target_a.name = "TargetA"
	target_b.name = "TargetB"
	runtime_a.add_child(target_a)
	runtime_b.add_child(target_b)

	var reticle_a_low := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	var reticle_a_high := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	var reticle_b_low := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	var reticle_b_high := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	target_a.add_child(reticle_a_low)
	target_a.add_child(reticle_a_high)
	target_b.add_child(reticle_b_low)
	target_b.add_child(reticle_b_high)
	reticle_a_low.set_progress(0.2)
	reticle_a_high.set_progress(0.8)
	reticle_b_low.set_progress(0.3)
	reticle_b_high.set_progress(0.7)
	await process_frame

	_expect(
		coordinator_a.tracked_reticle_count == 2
		and coordinator_b.tracked_reticle_count == 2
		and reticle_a_low.uses_coordinated_arbitration()
		and reticle_b_low.uses_coordinated_arbitration(),
		"Each game runtime must register sniper reticles only with its nearest coordinator."
	)
	_expect(
		reticle_a_high.is_progress_display_active()
		and reticle_b_high.is_progress_display_active(),
		"Independent runtime coordinators must arbitrate their own winners."
	)

	runtime_a.remove_child(coordinator_a)
	coordinator_a.free()
	await process_frame
	_expect(
		not reticle_a_low.uses_coordinated_arbitration()
		and not reticle_a_high.uses_coordinated_arbitration()
		and reticle_a_high.is_progress_display_active(),
		"Coordinator exit must clear local bindings and preserve sibling fallback arbitration."
	)
	_expect(
		reticle_b_low.uses_coordinated_arbitration()
		and reticle_b_high.uses_coordinated_arbitration()
		and coordinator_b.tracked_reticle_count == 2,
		"Removing one game runtime coordinator must not detach a surviving runtime."
	)

	reticle_b_low.set_progress(0.95)
	await process_frame
	_expect(
		reticle_b_low.is_progress_display_active()
		and not reticle_b_high.is_progress_display_active(),
		"A surviving runtime coordinator must continue processing after its sibling exits."
	)
	runtime_a.queue_free()
	runtime_b.queue_free()
	await process_frame


func _test_mage_windup_fireball_and_obstruction() -> void:
	var mage_service := (
		test_root.get_enemy_combat_services()
		.get_capoo_mage_fireball_simulation_service()
	)
	_expect(
		mage_service != null,
		"Mage fixture must mount the shared fireball simulation service."
	)
	if mage_service == null:
		return
	mage_service.clear()
	var blocked_spawns_before := int(mage_service.get_metrics()["spawns"])
	var blocked_player := _spawn_player(Vector2(240.0, 0.0), 200)
	var wall := _spawn_wall(Vector2(120.0, 0.0), 10.0)
	await physics_frame
	var blocked_mage := _spawn_mage(Vector2.ZERO, blocked_player)
	await _wait_physics_frames(12)
	_expect(blocked_mage.combat_state == CapooMage.CombatState.CHASE, "Mage Capoo attacked through a World wall.")
	_expect(
		int(mage_service.get_metrics()["spawns"]) == blocked_spawns_before,
		"Mage Capoo spawned a data fireball through a World wall."
	)
	blocked_mage.queue_free()
	wall.queue_free()
	blocked_player.queue_free()
	await physics_frame

	mage_service.clear()
	var spawns_before := int(mage_service.get_metrics()["spawns"])
	var player := _spawn_player(Vector2(240.0, 0.0), 200)
	var mage := _spawn_mage(Vector2.ZERO, player)
	_expect(
		mage.call("_get_touch_damage_type")
			== EnemyConfig.DamageType.MAGIC,
		"Mage Capoo body contact must use magic damage."
	)
	await _wait_physics_frames(8)
	_expect(mage.combat_state == CapooMage.CombatState.WINDUP, "Mage Capoo did not enter windup.")
	_expect(
		int(mage_service.get_metrics()["spawns"]) == spawns_before,
		"Mage Capoo spawned a data fireball before windup."
	)
	var replacement_player := _spawn_player(Vector2(220.0, 80.0), 200)
	mage.set_target_player(replacement_player)
	_expect(
		mage.attack_target == player,
		"Mage windup must retain the explicit target chosen at attack start."
	)
	var fireball_guard_frames := 0
	while (
		int(mage_service.get_metrics()["spawns"]) == spawns_before
		and fireball_guard_frames < 90
	):
		await physics_frame
		fireball_guard_frames += 1
	_expect(
		int(mage_service.get_metrics()["spawns"]) == spawns_before + 1,
		"Mage Capoo did not spawn exactly one data fireball after windup."
	)
	var fireball_handle := mage_service.get_handle_at_stable_index(0)
	if mage_service.is_handle_live(fireball_handle):
		_expect(
			is_equal_approx(
				mage_service.get_radius(fireball_handle),
				MAGE_CONFIG.fireball_radius
			),
			"Data fireball radius did not use config."
		)
		_expect(
			is_equal_approx(
				mage_service.get_homing_turn_rate(fireball_handle),
				MAGE_CONFIG.fireball_homing_turn_rate
			),
			"Data fireball homing rate did not use config."
		)
		_expect(
			mage_service.get_target(fireball_handle) == player,
			"Data fireball must keep the attack's explicit soft-homing target."
		)
	var post_fire_guard_frames := 0
	while mage.combat_state != CapooMage.CombatState.CHASE and post_fire_guard_frames < 30:
		await physics_frame
		post_fire_guard_frames += 1
	var cooldown_hold_guard_frames := 0
	while (
		not bool(mage.get("_ranged_attack_position_held"))
		and cooldown_hold_guard_frames < 8
	):
		await physics_frame
		cooldown_hold_guard_frames += 1
	var cooldown_position := mage.global_position
	await _wait_physics_frames(6)
	_expect(
		bool(mage.get("_ranged_attack_position_held"))
		and mage.global_position.distance_squared_to(cooldown_position) < 0.01,
		"Mage Capoo must stand at clear attack range throughout cooldown."
	)
	mage_service.clear()
	mage.queue_free()
	player.queue_free()
	replacement_player.queue_free()
	await physics_frame


func _test_fireball_impact_damage_and_release() -> void:
	var original_pool_mode := CapooMageFireball.pooled_impact_effect_enabled
	# This lightweight scene intentionally has no session pool. Exercise the
	# explicit legacy A/B path while the focused impact-pool smoke covers strict
	# production leasing.
	CapooMageFireball.pooled_impact_effect_enabled = false
	var near_player := _spawn_player(Vector2(5.0, 0.0), 100)
	var far_player := _spawn_player(Vector2(48.0, 0.0), 100)
	near_player.physical_defense = 34
	near_player.magic_defense = 50
	await physics_frame
	var fireball := FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(fireball)
	fireball.global_position = Vector2.ZERO
	fireball.bind_gameplay_context(
		test_root,
		test_root.get_multiplayer_gameplay_gateway()
	)
	fireball.setup(
		Vector2.RIGHT,
		MAGE_CONFIG.attack_damage,
		0.0,
		3.0,
		MAGE_CONFIG.fireball_radius,
		null,
		MAGE_CONFIG.fireball_homing_turn_rate,
		DamageSourceSnapshot.create(
			CombatRelationService.HOSTILE_WAVE,
			0,
			1,
			0,
			&"capoo_mage_fireball"
		)
	)
	fireball.call("_explode")
	await process_frame

	_expect(
		near_player.current_health == 83,
		"Fireball must use 50 magic defense (17 damage), not 34 physical defense."
	)
	_expect(far_player.current_health == 100, "Fireball impact damaged a player outside radius.")
	_expect(not is_instance_valid(fireball), "Fireball projectile must release immediately after impact damage.")
	var impact := _find_fireball_impact_effect()
	_expect(impact != null, "Fireball impact must spawn a separate visual effect.")
	if impact != null:
		var impact_sprite := impact.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		_expect(
			impact_sprite != null and impact_sprite.animation == &"impact",
			"Fireball impact effect must play the impact animation."
		)
		_expect(
			impact.global_position.is_equal_approx(Vector2.ZERO),
			"Fireball impact effect must stay centered on hit position."
		)
	_expect(_count_bullet_hit_effects() == 0, "Mage fireball must not spawn the generic bullet hit effect.")

	var release_guard_frames := 0
	while impact != null and is_instance_valid(impact) and release_guard_frames < 180:
		await process_frame
		release_guard_frames += 1
	_expect(impact == null or not is_instance_valid(impact), "Fireball impact visual/audio did not release.")

	var gameplay_session := EnemyGameplayGatewayTestSession.new()
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	test_root.attach_gameplay_session(gameplay_session)
	var network_fireball := FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(network_fireball)
	network_fireball.global_position = Vector2.ZERO
	network_fireball.bind_gameplay_context(
		test_root,
		test_root.get_multiplayer_gameplay_gateway()
	)
	network_fireball.setup(
		Vector2.RIGHT,
		MAGE_CONFIG.attack_damage,
		0.0,
		3.0,
		MAGE_CONFIG.fireball_radius
	)
	network_fireball.setup_multiplayer(902, 1, &"capoo_mage_fireball")
	var network_request_handled := bool(
		network_fireball.call("_try_report_multiplayer_player_hit", near_player)
	)
	_expect(network_request_handled, "Multiplayer mage fireball damage request was not handled.")
	_expect(
		gameplay_session.player_damage_requests.size() == 1
		and gameplay_session.player_damage_requests[0].get("damage_type")
			== EnemyConfig.DamageType.MAGIC,
		"HOST mage fireball must route explicit magic damage through the typed gameplay gateway."
	)
	network_fireball.queue_free()

	var health_before_client_view := near_player.current_health
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	var client_view_fireball := FIREBALL_SCENE.instantiate() as CapooMageFireball
	test_root.add_child(client_view_fireball)
	client_view_fireball.global_position = Vector2.ZERO
	client_view_fireball.bind_gameplay_context(test_root, null)
	client_view_fireball.setup(
		Vector2.RIGHT,
		MAGE_CONFIG.attack_damage,
		0.0,
		3.0,
		MAGE_CONFIG.fireball_radius
	)
	client_view_fireball.setup_multiplayer(903, 1, &"capoo_mage_fireball")
	var client_view_was_handled := bool(
		client_view_fireball.call(
			"_try_report_multiplayer_player_hit",
			near_player
		)
	)
	client_view_fireball.call(
		"_apply_explosion_damage_to_body",
		near_player,
		{}
	)
	_expect(
		not client_view_was_handled
		and near_player.current_health == health_before_client_view,
		"CLIENT_VIEW mage fireball without an injected gateway must fail closed without local damage."
	)
	client_view_fireball.queue_free()
	test_root.detach_gameplay_session(gameplay_session)
	gameplay_session.free()
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
	near_player.queue_free()
	far_player.queue_free()
	await physics_frame
	CapooMageFireball.pooled_impact_effect_enabled = original_pool_mode


func _test_sniper_lock_cancel_and_damage() -> void:
	var blocked_player := _spawn_player(Vector2(360.0, 0.0), 260)
	Enemy.set_performance_metrics_enabled(true)
	var sniper := _spawn_sniper(Vector2.ZERO, blocked_player)
	await _wait_physics_frames(8)
	_expect(sniper.combat_state == CapooSniper.CombatState.LOCK, "Sniper Capoo did not enter lock state.")
	_expect(
		_count_reticles(blocked_player) == 0
		and sniper.get_node_or_null("AimGlow") == null,
		"Production sniper lock must not create a reticle node or retain AimGlow."
	)
	_expect(
		_sniper_warning_handles_live(sniper, true),
		"Sniper lock must acquire shared line and reticle handles."
	)
	var lock_start_metrics := Enemy.get_performance_metrics()
	var lock_start_los_calls := int(lock_start_metrics["ranged_los_calls"])
	_expect(
		lock_start_los_calls >= 1,
		"Sniper lock start must publish its exact ranged LOS commit."
	)
	var wall := _spawn_wall(Vector2(180.0, 0.0), 12.0)
	await _wait_physics_frames(6)
	_expect(
		sniper.combat_state == CapooSniper.CombatState.LOCK
		and _count_reticles(blocked_player) == 0
		and _sniper_warning_handles_live(sniper, true),
		"Sniper lock must keep shared warnings without per-frame World rays."
	)
	var mid_lock_metrics := Enemy.get_performance_metrics()
	_expect(
		int(mid_lock_metrics["ranged_los_calls"]) == lock_start_los_calls,
		"Sniper lock progress unexpectedly cast an additional ranged LOS ray."
	)
	var blocked_health_before := blocked_player.current_health
	sniper.lock_time_left = 0.0
	await physics_frame
	_expect(
		sniper.combat_state == CapooSniper.CombatState.CHASE,
		"Sniper must cancel when the exact pre-fire LOS recheck is blocked."
	)
	_expect(
		_count_reticles(blocked_player) == 0
		and sniper.sniper_line_warning_handle == 0
		and sniper.sniper_reticle_warning_handle == 0
		and blocked_player.current_health == blocked_health_before,
		"A blocked sniper pre-fire recheck must release warnings without damage."
	)
	var blocked_commit_metrics := Enemy.get_performance_metrics()
	_expect(
		int(blocked_commit_metrics["ranged_los_calls"]) == lock_start_los_calls + 1,
		"Sniper pre-fire validation must add exactly one measurable LOS query."
	)
	Enemy.set_performance_metrics_enabled(false)
	sniper.queue_free()
	wall.queue_free()
	blocked_player.queue_free()
	await physics_frame

	var player := _spawn_player(Vector2(360.0, 0.0), 300)
	await process_frame
	player.set("_base_max_health", 300)
	player.max_health = 300
	player.current_health = 300
	player.health_bar.setup(player.max_health, player.current_health)
	var expected_health_after_shot := player.current_health - SNIPER_CONFIG.attack_damage
	var firing_sniper := _spawn_sniper(Vector2.ZERO, player)
	await _wait_physics_frames(8)
	_expect(firing_sniper.combat_state == CapooSniper.CombatState.LOCK, "Sniper Capoo did not lock before damage test.")
	_expect(
		_count_reticles(player) == 0
		and _sniper_warning_handles_live(firing_sniper, true),
		"Damage-test sniper must use shared warning handles without reticle nodes."
	)
	var sniper_guard_frames := 0
	while player.current_health != expected_health_after_shot and sniper_guard_frames < 230:
		await physics_frame
		sniper_guard_frames += 1
	_expect(
		player.current_health == expected_health_after_shot,
		"Sniper lock did not deal exactly 200 damage after three seconds. health=%d expected=%d state=%s lock_left=%.2f reticles=%d invincible=%.2f"
		% [
			player.current_health,
			expected_health_after_shot,
			str(firing_sniper.combat_state),
			firing_sniper.lock_time_left,
			_count_reticles(player),
			player.invincibility_time_left,
		]
	)
	await process_frame
	await physics_frame
	_expect(
		_count_reticles(player) == 0
		and firing_sniper.sniper_line_warning_handle == 0
		and firing_sniper.sniper_reticle_warning_handle == 0,
		"Sniper warning handles remained after firing."
	)
	firing_sniper.queue_free()
	player.queue_free()
	await physics_frame


func _test_smg_scatter_fire() -> void:
	spawned_smg_bullets.clear()
	spawned_smg_bullet_directions.clear()
	var player := _spawn_player(Vector2(40.0, 0.0), 200)
	var smg := _spawn_smg(Vector2.ZERO, player)
	var smg_guard_frames := 0
	while smg.hitscan_shots_fired < 2 and smg_guard_frames < 36:
		await physics_frame
		smg_guard_frames += 1
	_expect(smg.hitscan_shots_fired >= 2, "SMG Capoo did not fire repeatedly while moving.")
	_expect(
		absf(smg.last_shot_direction.angle_to(Vector2.RIGHT))
			<= deg_to_rad(SMG_CONFIG.spread_angle_degrees) + 0.001,
		"SMG hitscan must aim at the nearby target with only the authored scatter."
	)
	_expect(
		spawned_smg_bullets.is_empty(),
		"Production SMG fire must not allocate one Area2D projectile per shot."
	)
	smg.fire_time_left = 0.0
	smg.set_objective_target(null)
	_expect(
		bool(smg.call("_try_fire_scatter", Vector2.RIGHT)),
		"Without a contact or objective, SMG must still use its live player family target."
	)
	smg.fire_time_left = 0.0
	smg.set_target_player(null)
	_expect(
		not bool(smg.call("_try_fire_scatter", Vector2.RIGHT)),
		"SMG must not fire only after contact, objective and family player targets are all absent."
	)
	smg.queue_free()
	player.queue_free()
	await physics_frame


func _test_smg_no_pathfinder_direct_chase_respects_world_wall() -> void:
	spawned_smg_bullets.clear()
	var player := _spawn_player(Vector2(140.0, 0.0), 200)
	var wall := _spawn_wall(Vector2(70.0, 0.0), 20.0)
	await physics_frame
	var smg := _spawn_smg(Vector2.ZERO, player)
	await _wait_physics_frames(12)
	_expect(
		spawned_smg_bullets.is_empty() and smg.hitscan_shots_fired == 0,
		"SMG Capoo must not fire at a far target while its chase line is blocked."
	)
	_expect(
		smg.global_position.distance_squared_to(Vector2.ZERO) < 0.01,
		"SMG Capoo must remain stopped when its no-pathfinder player line is blocked."
	)
	smg.queue_free()
	wall.queue_free()
	player.queue_free()
	await physics_frame


func _test_proxy_action_visuals() -> void:
	var mage_player := _spawn_player(Vector2(240.0, 0.0), 200)
	var mage := _spawn_mage(Vector2.ZERO, mage_player)
	mage.configure_multiplayer_proxy()
	mage.play_multiplayer_enemy_action(&"windup", Vector2.RIGHT, 1)
	await process_frame
	_expect(mage.spell_glow.visible, "Proxy mage windup spell glow did not appear.")
	mage.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 2)
	await process_frame
	_expect(mage.spell_glow.visible, "Proxy mage fire spell glow did not appear.")
	_expect(
		Vector2.RIGHT.rotated(mage.spell_glow.rotation).dot(Vector2.LEFT) > 0.99,
		"Stale proxy mage windup tween must not override newer fire direction."
	)
	mage.play_multiplayer_death_sequence()
	await process_frame
	_expect(not mage.spell_glow.visible, "Proxy mage death must clear spell glow.")
	mage.queue_free()
	mage_player.queue_free()
	await physics_frame

	var smg_player := _spawn_player(Vector2(140.0, 0.0), 200)
	var smg := _spawn_smg(Vector2.ZERO, smg_player)
	smg.configure_multiplayer_proxy()
	_expect(
		CapooSMG.allocation_free_proxy_visuals_enabled,
		"Production SMG proxy visuals must use the allocation-free timer path."
	)
	smg.play_multiplayer_enemy_action(&"fire", Vector2.RIGHT, 1)
	_expect(smg.muzzle_flash.visible, "Proxy SMG muzzle flash did not appear.")
	smg.call("_process", 0.10)
	_expect(
		smg.animated_sprite.animation == SMG_CONFIG.attack_animation_name
		and smg.is_processing(),
		"Proxy SMG attack animation must outlive its shorter muzzle flash."
	)
	smg.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 2)
	smg.call("_process", 0.05)
	_expect(
		Vector2.RIGHT.rotated(smg.muzzle_flash.rotation).dot(Vector2.LEFT) > 0.99,
		"Later proxy SMG fire must replace the previous shot direction."
	)
	_expect(
		smg.animated_sprite.animation == SMG_CONFIG.attack_animation_name
		and smg.is_processing(),
		"Later proxy SMG fire must restart the complete action restore interval."
	)
	_expect(
		smg.proxy_visual_timer_action_count == 2
		and smg.proxy_visual_tween_action_count == 0,
		"Proxy SMG fire must not allocate per-action Tweens in production."
	)
	smg.call("_process", 0.10)
	_expect(
		not smg.muzzle_flash.visible
		and smg.animated_sprite.animation == SMG_CONFIG.move_animation_name
		and not smg.is_processing(),
		"Proxy SMG timer path must hide the flash, restore movement, and go dormant."
	)
	smg.play_multiplayer_enemy_action(&"fire", Vector2.RIGHT, 3)
	smg.set_multiplayer_proxy_visual_active(false)
	_expect(
		not smg.muzzle_flash.visible
		and not smg.is_processing()
		and smg.animated_sprite.animation == SMG_CONFIG.move_animation_name
		and smg.proxy_visual_timer_action_count == 3,
		"Culling an active proxy SMG shot must cancel and restore its visual state."
	)
	smg.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 4)
	_expect(
		not smg.muzzle_flash.visible
		and not smg.is_processing()
		and smg.latest_proxy_action_id == 4
		and smg.proxy_visual_timer_action_count == 3,
		"Offscreen proxy SMG fire must advance ordering without scheduling visuals."
	)
	smg.set_multiplayer_proxy_visual_active(true)
	_expect(
		not smg.muzzle_flash.visible
		and not smg.is_processing()
		and smg.animated_sprite.animation == SMG_CONFIG.move_animation_name,
		"Reactivated proxy SMG must remain in its restored dormant move state."
	)
	smg.play_multiplayer_enemy_action(&"fire", Vector2.LEFT, 5)
	smg.play_multiplayer_death_sequence()
	var death_animation_after_start := smg.animated_sprite.animation
	var action_count_after_death := smg.proxy_visual_timer_action_count
	smg.play_multiplayer_enemy_action(
		&"fire",
		Vector2.RIGHT,
		smg.latest_proxy_action_id + 1
	)
	_expect(
		not smg.muzzle_flash.visible
		and not smg.is_processing()
		and is_zero_approx(smg.proxy_muzzle_flash_time_left)
		and is_zero_approx(smg.proxy_action_restore_time_left)
		and smg.animated_sprite.animation == death_animation_after_start
		and smg.proxy_visual_timer_action_count == action_count_after_death,
		"Proxy SMG death must clear timers and reject every late action."
	)
	smg.queue_free()
	smg_player.queue_free()
	await physics_frame

	CapooSMG.allocation_free_proxy_visuals_enabled = false
	var legacy_smg_player := _spawn_player(Vector2(140.0, 0.0), 200)
	var legacy_smg := _spawn_smg(Vector2.ZERO, legacy_smg_player)
	legacy_smg.configure_multiplayer_proxy()
	legacy_smg.play_multiplayer_enemy_action(&"fire", Vector2.RIGHT, 1)
	_expect(
		legacy_smg.muzzle_flash.visible
		and legacy_smg.proxy_visual_tween_action_count == 1,
		"Legacy SMG A/B fixture must start its Tween visual path."
	)
	legacy_smg.set_multiplayer_proxy_visual_active(false)
	legacy_smg.set_multiplayer_proxy_visual_active(true)
	await create_timer(0.18).timeout
	_expect(
		not legacy_smg.muzzle_flash.visible
		and legacy_smg.animated_sprite.animation == SMG_CONFIG.move_animation_name,
		"Culled legacy SMG Tween callbacks must not revive stale attack visuals."
	)
	legacy_smg.queue_free()
	legacy_smg_player.queue_free()
	CapooSMG.allocation_free_proxy_visuals_enabled = true
	await physics_frame

	var sniper_player := _spawn_player(Vector2(240.0, 0.0), 200)
	var sniper := _spawn_sniper(Vector2.ZERO, sniper_player)
	sniper.configure_multiplayer_proxy()
	sniper.play_multiplayer_enemy_target_action(&"sniper_lock_start", sniper_player, 1)
	sniper.call("_process", 0.2)
	_expect(
		_count_reticles(sniper_player) == 0
		and sniper.get_node_or_null("AimGlow") == null
		and _sniper_warning_handles_live(sniper, true),
		"Proxy sniper lock must use shared handles without per-target visual nodes."
	)

	var updates_before_follow := int(warning_system.get_metrics()["updates"])
	sniper_player.global_position = Vector2(120.0, 180.0)
	sniper.call("_process", 0.2)
	_expect(
		int(warning_system.get_metrics()["updates"]) >= updates_before_follow + 2,
		"Proxy sniper shared line and reticle must follow a moving target player."
	)
	sniper.play_multiplayer_enemy_target_action(&"sniper_lock_cancel", sniper_player, 2)
	await process_frame
	_expect(
		_count_reticles(sniper_player) == 0
		and sniper.sniper_line_warning_handle == 0
		and sniper.sniper_reticle_warning_handle == 0,
		"Proxy sniper cancel must release both shared warning handles."
	)

	sniper.play_multiplayer_enemy_action(
		&"sniper_plant_lock_start",
		Vector2(180.0, 24.0),
		1
	)
	sniper.call("_process", 0.2)
	_expect(
		_count_reticles(sniper_player) == 0
		and _sniper_warning_handles_live(sniper, false),
		"Positional proxy lock must preserve its line-only warning semantics."
	)
	sniper.play_multiplayer_enemy_action(
		&"sniper_plant_lock_cancel",
		Vector2.ZERO,
		2
	)
	_expect(
		sniper.sniper_line_warning_handle == 0
		and sniper.sniper_reticle_warning_handle == 0,
		"Positional proxy cancel must release its shared line handle."
	)

	sniper.play_multiplayer_enemy_target_action(&"sniper_lock_start", sniper_player, 3)
	sniper.call("_process", 0.2)
	_expect(
		_count_reticles(sniper_player) == 0
		and _sniper_warning_handles_live(sniper, true),
		"Proxy sniper death cleanup test must start shared warnings first."
	)
	sniper.play_multiplayer_death_sequence()
	await process_frame
	_expect(
		_count_reticles(sniper_player) == 0
		and sniper.sniper_line_warning_handle == 0
		and sniper.sniper_reticle_warning_handle == 0,
		"Proxy sniper death must release shared warning handles."
	)
	if is_instance_valid(sniper):
		sniper.queue_free()
	sniper_player.queue_free()
	await physics_frame

	var teardown_player := _spawn_player(Vector2(210.0, 0.0), 200)
	var teardown_sniper := _spawn_sniper(Vector2.ZERO, teardown_player)
	teardown_sniper.configure_multiplayer_proxy()
	teardown_sniper.play_multiplayer_enemy_target_action(
		&"sniper_lock_start",
		teardown_player,
		1
	)
	var teardown_line_handle := teardown_sniper.sniper_line_warning_handle
	var teardown_reticle_handle := teardown_sniper.sniper_reticle_warning_handle
	_expect(
		warning_system.is_handle_live(teardown_line_handle)
		and warning_system.is_handle_live(teardown_reticle_handle),
		"Proxy sniper exit-tree cleanup fixture must acquire both warnings first."
	)
	teardown_sniper.queue_free()
	await process_frame
	_expect(
		not warning_system.is_handle_live(teardown_line_handle)
		and not warning_system.is_handle_live(teardown_reticle_handle),
		"Removing a sniper from the tree must release both shared warnings."
	)
	teardown_player.queue_free()
	await physics_frame


func _test_multiplayer_projectile_registry() -> void:
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
	var coordinator := MpProjectileCoordinator.new()
	coordinator.bind_runtime(test_root)
	var fireball := coordinator.instantiate_projectile(
		&"capoo_mage_fireball",
		0,
		Vector2.RIGHT,
		MAGE_CONFIG.attack_damage,
		MAGE_CONFIG.projectile_speed,
		MAGE_CONFIG.projectile_lifetime
	)
	_expect(
		fireball == null,
		"Multiplayer registry must not instantiate a legacy Mage projectile Node."
	)

	var smg_bullet := coordinator.instantiate_projectile(
		&"capoo_smg_bullet",
		0,
		Vector2.RIGHT,
		40,
		SMG_CONFIG.projectile_speed,
		SMG_CONFIG.projectile_lifetime
	) as CapooAK47Bullet
	_expect(smg_bullet != null, "Multiplayer registry did not instantiate capoo_smg_bullet.")
	if smg_bullet != null:
		_expect(smg_bullet.damage == 40, "Registry SMG bullet damage mismatch.")
		_expect(is_equal_approx(smg_bullet.max_lifetime, SMG_CONFIG.projectile_lifetime), "Registry SMG bullet lifetime mismatch.")
		smg_bullet.free()
	coordinator.unbind_runtime(test_root)
	coordinator.free()
	test_root.runtime_mode = CombatRuntimeBase.RuntimeMode.SINGLEPLAYER


func _test_wave_entries() -> void:
	_expect(_count_wave_entries_for_config(WAVE_09, MAGE_CONFIG) == 60, "Wave 9 mage count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_09, SNIPER_CONFIG) == 0, "Wave 9 sniper count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_09, SMG_CONFIG) == 0, "Wave 9 SMG count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_10, MAGE_CONFIG) == 15, "Wave 10 mage count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_10, SNIPER_CONFIG) == 20, "Wave 10 sniper count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_10, SMG_CONFIG) == 0, "Wave 10 SMG count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_11, MAGE_CONFIG) == 30, "Wave 11 mage count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_11, SNIPER_CONFIG) == 20, "Wave 11 sniper count mismatch.")
	_expect(_count_wave_entries_for_config(WAVE_11, SMG_CONFIG) == 50, "Wave 11 SMG count mismatch.")


func _spawn_player(position: Vector2, health: int) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	test_root.bind_player_runtime_context(player)
	player.global_position = position
	player.collision_layer = 2
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", health)
	player.max_health = health
	player.current_health = health
	player.health_bar.setup(player.max_health, player.current_health)
	return player


func _spawn_mage(position: Vector2, player: Player) -> CapooMage:
	var enemy := MAGE_SCENE.instantiate() as CapooMage
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(MAGE_CONFIG, player, null, test_root)
	return enemy


func _spawn_sniper(position: Vector2, player: Player) -> CapooSniper:
	var enemy := SNIPER_SCENE.instantiate() as CapooSniper
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(SNIPER_CONFIG, player, null, test_root)
	return enemy


func _spawn_smg(position: Vector2, player: Player) -> CapooSMG:
	var enemy := SMG_SCENE.instantiate() as CapooSMG
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(SMG_CONFIG, player, null, test_root)
	return enemy


func _spawn_wall(position: Vector2, radius: float) -> StaticBody2D:
	var wall := StaticBody2D.new()
	wall.collision_layer = 1
	wall.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape_node.shape = circle
	wall.add_child(shape_node)
	test_root.add_child(wall)
	wall.global_position = position
	return wall


func _has_capoo_frames(scene: PackedScene, label: String, expected_frame_size := Vector2.ZERO) -> bool:
	var instance := scene.instantiate()
	var animated_sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var frames := animated_sprite.sprite_frames if animated_sprite != null else null
	var ok := frames != null
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		ok = ok and frames.has_animation(animation_name) and frames.get_frame_count(animation_name) == 4
		if frames == null or not frames.has_animation(animation_name):
			continue
		for frame_index in range(frames.get_frame_count(animation_name)):
			var atlas_texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			ok = ok and atlas_texture != null
			if atlas_texture == null or expected_frame_size == Vector2.ZERO:
				continue
			var atlas_size := atlas_texture.atlas.get_size() if atlas_texture.atlas != null else Vector2.ZERO
			var region := atlas_texture.region
			ok = ok and atlas_texture.get_size() == expected_frame_size
			ok = ok and region.position.x >= 0.0 and region.position.y >= 0.0
			ok = ok and region.end.x <= atlas_size.x and region.end.y <= atlas_size.y
	if not ok:
		failures.append("%s scene animation frames are incomplete." % label)
	instance.free()
	return ok


func _has_mage_visual_alignment() -> bool:
	var instance := MAGE_SCENE.instantiate()
	var animated_sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var ok := animated_sprite != null
	ok = ok and animated_sprite.position.is_equal_approx(Vector2(3.0, -2.0))
	ok = ok and is_equal_approx(animated_sprite.scale.x, 0.1)
	ok = ok and is_equal_approx(animated_sprite.scale.y, 0.1)
	if not ok:
		failures.append("Mage visual must keep the alpha-sheet body centered on its collision shape.")
	instance.free()
	return ok


func _has_smg_visual_alignment() -> bool:
	var instance := SMG_SCENE.instantiate()
	var animated_sprite := instance.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var ok := animated_sprite != null
	ok = ok and animated_sprite.position.is_equal_approx(Vector2(9.0, 3.0))
	ok = ok and is_equal_approx(animated_sprite.scale.x, 0.31)
	ok = ok and is_equal_approx(animated_sprite.scale.y, 0.31)
	if not ok:
		failures.append("SMG visual must keep the MP5-SD body centered on its collision shape.")
	instance.free()
	return ok


func _sniper_warning_handles_live(
	sniper: CapooSniper,
	expect_reticle: bool
) -> bool:
	if warning_system == null:
		return false
	if not warning_system.is_handle_live(sniper.sniper_line_warning_handle):
		return false
	return (
		warning_system.is_handle_live(sniper.sniper_reticle_warning_handle)
		if expect_reticle
		else sniper.sniper_reticle_warning_handle == 0
	)


func _has_mage_original_alpha_regions() -> bool:
	var frames := load("res://resources/animation/capoo_mage.tres") as SpriteFrames
	var ok := frames != null
	if frames == null:
		failures.append("Mage original alpha SpriteFrames resource is missing.")
		return false
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		for frame_index in range(4):
			var atlas_texture := frames.get_frame_texture(animation_name, frame_index) as AtlasTexture
			ok = ok and atlas_texture != null
			if atlas_texture == null:
				continue
			var atlas_size := atlas_texture.atlas.get_size() if atlas_texture.atlas != null else Vector2.ZERO
			var region := atlas_texture.region
			ok = ok and atlas_texture.get_size() == Vector2(374.0, 300.0)
			ok = ok and region.position.x >= 0.0 and region.position.y >= 0.0
			ok = ok and region.end.x <= atlas_size.x and region.end.y <= atlas_size.y
	if not ok:
		failures.append("Mage must use margin-padded direct regions from capoo_mage_single_alpha.png without clipping.")
	return ok


func _has_reticle_scene_contract() -> bool:
	var instance := RETICLE_SCENE.instantiate() as CapooSniperLockReticle
	if instance == null:
		return false
	var has_static_mark := instance.get_node_or_null("CenterMark") is Sprite2D
	var has_old_animation := instance.get_node_or_null("Visual") is AnimatedSprite2D
	instance.set_progress(0.5)
	var has_progress := is_equal_approx(instance.progress_ratio, 0.5)
	instance.free()
	return has_static_mark and not has_old_animation and has_progress


func _fireball_impact_animation_contract() -> bool:
	var frames := load("res://resources/animation/capoo_mage_fireball.tres") as SpriteFrames
	var ok := frames != null
	if frames == null:
		failures.append("Fireball SpriteFrames resource is missing.")
		return false
	ok = ok and frames.has_animation(&"impact")
	ok = ok and not frames.get_animation_loop(&"impact")
	ok = ok and frames.get_animation_speed(&"impact") >= 20.0
	for frame_index in range(6):
		var atlas_texture := frames.get_frame_texture(&"impact", frame_index) as AtlasTexture
		ok = ok and atlas_texture != null
		if atlas_texture == null:
			continue
		ok = ok and atlas_texture.region == Rect2(frame_index * 64.0, 64.0, 64.0, 64.0)
	if not ok:
		failures.append("Fireball impact animation must be a non-looping second-row AtlasTexture animation.")
	return ok


func _has_fireball_impact_audio() -> bool:
	var instance := FIREBALL_IMPACT_SCENE.instantiate() as Node2D
	if instance == null:
		return false
	var impact_audio := instance.get_node_or_null("ImpactAudio") as AudioStreamPlayer2D
	var ok := impact_audio != null
	ok = ok and impact_audio.stream != null
	ok = ok and _resource_path(impact_audio.stream).ends_with("capoo_mage_fireball_impact.wav")
	ok = ok and impact_audio.volume_db <= -6.0
	ok = ok and impact_audio.max_polyphony <= 2
	if not ok:
		failures.append("Fireball impact scene must include a restrained ImpactAudio player.")
	instance.free()
	return ok


func _texture_size(path: String) -> Vector2:
	var texture := load(path) as Texture2D
	return texture.get_size() if texture != null else Vector2.ZERO


func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""


func _object_has_property(object: Object, property_name: StringName) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return true
	return false


func _scene_state_has_node_named(
	state: SceneState,
	node_name: StringName
) -> bool:
	if state == null:
		return false
	for node_index in range(state.get_node_count()):
		if state.get_node_name(node_index) == node_name:
			return true
	return false


func _scene_state_has_instanced_scene(
	state: SceneState,
	node_name: StringName,
	expected_scene_path: String
) -> bool:
	if state == null:
		return false
	for node_index in range(state.get_node_count()):
		if state.get_node_name(node_index) != node_name:
			continue
		var instance_scene := state.get_node_instance(node_index) as PackedScene
		return (
			instance_scene != null
			and instance_scene.resource_path == expected_scene_path
		)
	return false


func _sprite_frames_count(path: String, animation_name: StringName) -> int:
	var frames := load(path) as SpriteFrames
	if frames == null or not frames.has_animation(animation_name):
		return 0
	return frames.get_frame_count(animation_name)


func _count_reticles(player: Player) -> int:
	var total := 0
	for child in player.get_children():
		if child is CapooSniperLockReticle:
			total += 1
	return total


func _count_bullet_hit_effects() -> int:
	var total := 0
	for child in test_root.get_children():
		if child is BulletHitEffect:
			total += 1
	return total


func _find_fireball_impact_effect() -> Node2D:
	for child in test_root.get_children():
		if child.name == "CapooMageFireballImpact":
			return child as Node2D
	return null


func _count_wave_entries_for_config(wave_config: WaveConfig, enemy_config: EnemyConfig) -> int:
	var total := 0
	for entry in wave_config.enemy_entries:
		if entry != null and entry.enemy_config == enemy_config:
			total += entry.count
	return total


func _on_child_entered_tree(child: Node) -> void:
	var smg_bullet := child as CapooAK47Bullet
	if smg_bullet != null:
		spawned_smg_bullets.append(smg_bullet)
		spawned_smg_bullet_directions.append(smg_bullet.direction)


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
