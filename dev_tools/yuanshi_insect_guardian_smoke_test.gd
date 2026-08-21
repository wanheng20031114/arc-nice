extends SceneTree

const PLAYER_SCENE := preload("res://scene/player/weishidaier/player_weishidaier.tscn")
const BASIC_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_basic.tres")
const GUARDIAN_CONFIG := preload("res://resources/config/enemies/yuanshi_insect_guardian.tres")
const GREEN_SHELL_CONFIG := preload(
	"res://resources/config/enemies/yuanshi_insect_green_shell.tres"
)
const GUARDIAN_AURA_SYSTEM_SCENE := preload(
	"res://scene/enemy/yuanshi_insect/guardian_aura_system.tscn"
)
const STANDARD_GAME_SCENE := preload("res://scene/game_modes/standard/standard_game.tscn")
const TOWER_GAME_SCENE := preload("res://scene/game_modes/tower_defense/tower_defense_game.tscn")
const PLAYER_LIFE_STATUS_HUD_SCENE := preload(
	"res://scene/ui/shared/player_life_status_hud.tscn"
)
const AURA_SCRIPT := preload("res://scene/enemy/yuanshi_insect/yuanshi_insect_aura.gd")
const ENEMY_VISUAL_SHADER_PATH := "res://scene/combat/feedback/shaders/entity_motion_status.gdshader"
const LEGACY_GUARDIAN_DEATH_HALO_MODULATE := Color(0.2, 0.78, 1.0, 0.78)

class NavigationStub extends Node:
	var is_built := true

	func try_get_safe_navigation_step(
		_from_position: Vector2,
		target_position: Vector2,
		_collision_half_extents: Vector2,
		_traversal_types: int
	) -> Dictionary:
		return {
			"status": GridPathfinder.NavigationStepStatus.READY,
			"is_complete_route": true,
			"waypoint": target_position,
			"resolved_from_cell": Vector2i.MAX,
			"next_cell": Vector2i.MAX,
			"used_start_recovery": false,
		}

var failures: Array[String] = []
var test_root: Node2D
var enemy_container: Node2D
var boss_container: Node2D
var guardian_aura_system: Variant = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "YuanshiInsectGuardianSmokeTest"
	root.add_child(test_root)
	current_scene = test_root
	enemy_container = Node2D.new()
	enemy_container.name = "EnemyContainer"
	test_root.add_child(enemy_container)
	boss_container = Node2D.new()
	boss_container.name = "BossContainer"
	test_root.add_child(boss_container)
	guardian_aura_system = GUARDIAN_AURA_SYSTEM_SCENE.instantiate()
	guardian_aura_system.allow_tracked_enemy_fallback_scan = true
	test_root.add_child(guardian_aura_system)

	_test_authored_game_scene_installation()
	_test_resource_contract()
	await _test_death_screen_back_buffer_contract()
	await _test_nested_day_night_material_isolation()
	await _test_authoritative_processing_gate()
	await _test_first_source_refresh_keeps_boundary_overlap()
	await _test_damage_defense_formulas()
	await _test_guardian_aura_visual_configuration()
	await _test_green_shell_keeps_player_area_contract()
	await _test_guardian_chase_and_collision_contract()
	await _test_guardian_aura_matches_legacy_overlap()
	await _test_source_driven_index_and_fixture_fallback()
	await _test_pending_source_refresh_survives_guardian_compaction()
	await _test_boss_container_target_semantics()
	await _test_guardian_aura_defense_lifecycle()
	await _test_multiplayer_proxy_guardian_values()
	await _test_dense_guardian_registration_and_teardown()

	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("YUANSHI_INSECT_GUARDIAN_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_authored_game_scene_installation() -> void:
	for scene_entry in [
		{"label": "standard", "scene": STANDARD_GAME_SCENE},
		{"label": "tower-defense", "scene": TOWER_GAME_SCENE},
	]:
		var packed_scene := scene_entry["scene"] as PackedScene
		var game_instance := packed_scene.instantiate()
		var system := game_instance.get_node_or_null(
			"GuardianAuraSystem"
		) as GuardianAuraSystem
		_expect(
			system != null
			and game_instance.get_node_or_null("EnemyContainer") != null
			and game_instance.get_node_or_null("BossContainer") != null
			and not system.allow_tracked_enemy_fallback_scan,
			"%s game scene must author GuardianAuraSystem beside both target containers."
			% String(scene_entry["label"])
		)
		game_instance.free()


func _test_resource_contract() -> void:
	_expect(
		guardian_aura_system.process_physics_priority == 10,
		"GuardianAuraSystem must run after ordinary enemy physics callbacks."
	)
	_expect(
		guardian_aura_system.is_physics_processing(),
		"GuardianAuraSystem must use fixed physics processing."
	)
	_expect(
		guardian_aura_system.limit_refresh_to_once_per_render_frame,
		"GuardianAuraSystem must shed duplicate physics catch-up work per render frame."
	)
	_expect(
		guardian_aura_system.use_extent_overlap_certificates,
		"GuardianAuraSystem must default to exact broadphase overlap certificates."
	)
	_expect(
		guardian_aura_system.target_containers.size() == 2,
		"GuardianAuraSystem must author EnemyContainer and BossContainer targets."
	)
	_expect(
		guardian_aura_system.use_snapshot_coverage_grid,
		"GuardianAuraSystem must default to the compact snapshot coverage grid."
	)
	_expect(
		GuardianAuraSystem.source_driven_refresh_enabled,
		"GuardianAuraSystem must default to source-driven refresh."
	)
	_expect(
		is_equal_approx(guardian_aura_system.refresh_interval_seconds, 0.2),
		"GuardianAuraSystem must use the measured 5 Hz production refresh."
	)
	_test_render_frame_refresh_limit()
	_expect(
		GUARDIAN_CONFIG is YuanshiInsectGuardianConfig,
		"Guardian config must use YuanshiInsectGuardianConfig."
	)
	_expect(
		GUARDIAN_CONFIG.variant == YuanshiInsectConfig.Variant.GUARDIAN,
		"Guardian enum variant mismatch."
	)
	_expect(BASIC_CONFIG.enemy_scene != null, "Basic Yuanshi insect must use its own scene.")
	_expect(GUARDIAN_CONFIG.enemy_scene != null, "Guardian must use its own scene.")
	_expect(GUARDIAN_CONFIG.max_health >= 16, "Guardian health is not high enough.")

	_expect(GUARDIAN_CONFIG.attack_damage == 10, "Guardian attack damage must be 10.")
	_expect(
		is_equal_approx(GUARDIAN_CONFIG.move_speed, BASIC_CONFIG.move_speed),
		"Guardian must keep normal Yuanshi insect movement speed."
	)
	var basic_scene_enemy := BASIC_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	var guardian_scene_enemy := GUARDIAN_CONFIG.enemy_scene.instantiate() as YuanshiInsect
	_expect(guardian_scene_enemy != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian_scene_enemy == null:
		basic_scene_enemy.free()
		return
	_expect(guardian_scene_enemy.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	var basic_body_node := basic_scene_enemy.get_node("CollisionShape2D") as CollisionShape2D
	var guardian_body_node := guardian_scene_enemy.get_node("CollisionShape2D") as CollisionShape2D
	_expect(
		basic_body_node != null and basic_body_node.shape != null,
		"Basic Yuanshi insect body collision shape must be configured."
	)
	_expect(
		guardian_body_node != null and guardian_body_node.shape != null,
		"Guardian body collision shape must be configured."
	)
	if basic_body_node != null and basic_body_node.shape != null:
		_expect(_get_shape_extent_radius(basic_body_node) > 0.0, "Basic Yuanshi insect body collision extent must be positive.")
	if guardian_body_node != null and guardian_body_node.shape != null:
		_expect(_get_shape_extent_radius(guardian_body_node) > 0.0, "Guardian body collision extent must be positive.")
	basic_scene_enemy.free()
	guardian_scene_enemy.free()
	_expect(
		GUARDIAN_CONFIG.aura_radius > GREEN_SHELL_CONFIG.aura_radius,
		"Guardian aura must be larger than green shell aura."
	)
	_expect(
		GUARDIAN_CONFIG.aura_physical_defense_bonus == 3,
		"Guardian aura must provide exactly +3 physical defense."
	)
	var texture := load("res://resources/texture/enemy/yuanshi_insect/yuanshi_insect_guardian.png") as Texture2D
	var image := texture.get_image() if texture != null else null
	_expect(image != null and image.get_size() == Vector2i(96, 64), "Guardian sprite sheet size is incorrect.")


func _test_death_screen_back_buffer_contract() -> void:
	var life_status_hud := PLAYER_LIFE_STATUS_HUD_SCENE.instantiate() as PlayerLifeStatusHUD
	_expect(
		life_status_hud != null,
		"Guardian screen-texture compatibility must instantiate the shared life HUD."
	)
	if life_status_hud == null:
		return
	test_root.add_child(life_status_hud)
	await process_frame
	var back_buffer := life_status_hud.get_node_or_null(
		"DeathScreenBackBuffer"
	) as BackBufferCopy
	var death_effect := life_status_hud.get_node_or_null(
		"DeathScreenEffect"
	) as ColorRect
	_expect(
		back_buffer != null
		and death_effect != null
		and back_buffer.copy_mode == BackBufferCopy.COPY_MODE_VIEWPORT
		and back_buffer.get_index() < death_effect.get_index()
		and not back_buffer.visible
		and not death_effect.visible,
		"Death overlay must author a disabled full-viewport copy before its screen shader."
	)
	life_status_hud.call("_play_local_death_intro")
	_expect(
		back_buffer != null
		and death_effect != null
		and back_buffer.visible
		and death_effect.visible,
		"Death presentation must refresh the back buffer after guardian emissions."
	)
	life_status_hud.call("_stop_local_death_presentation")
	_expect(
		back_buffer != null
		and death_effect != null
		and not back_buffer.visible
		and not death_effect.visible,
		"Ending death presentation must disable its extra screen copy."
	)
	life_status_hud.queue_free()
	await process_frame


func _test_nested_day_night_material_isolation() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var outer_fixture := _create_nested_guardian_branch(
		"OuterTowerBranch",
		YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS,
		true,
		player
	)
	var inner_fixture := _create_nested_guardian_branch(
		"InnerRogueBranch",
		3,
		false,
		player
	)
	var outer_branch := outer_fixture["branch"] as Node2D
	var inner_branch := inner_fixture["branch"] as Node2D
	var outer_controller := outer_fixture["controller"] as DayNightController
	var inner_controller := inner_fixture["controller"] as DayNightController
	var outer_guardians := outer_fixture["guardians"] as Array
	var inner_guardians := inner_fixture["guardians"] as Array
	outer_controller.set_night_factor_immediate(0.0)
	inner_controller.set_night_factor_immediate(1.0)
	await process_frame
	await process_frame
	_expect(
		_count_guardian_emission_slots(outer_guardians)
		== YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS
		and _count_guardian_emission_slots(inner_guardians) == 0
		and _count_bound_guardian_emissions(inner_guardians) == 0,
		"A hidden nested branch must not consume the visible guardian emission budget."
	)

	outer_branch.hide()
	inner_branch.show()
	await process_frame
	await process_frame
	_expect(
		_count_guardian_emission_slots(outer_guardians) == 0
		and _count_bound_guardian_emissions(outer_guardians) == 0
		and _count_guardian_emission_slots(inner_guardians) == inner_guardians.size(),
		"Entering nested combat must release hidden outer slots for visible guardians."
	)

	# Keep both branches visible for one phase to prove that their shader state is
	# isolated even while the global on-screen budget remains exactly twelve.
	outer_branch.show()
	await process_frame
	await process_frame
	_expect(
		_count_guardian_emission_slots(outer_guardians) == 9
		and _count_guardian_emission_slots(inner_guardians) == 3,
		"Visible nested branches must share exactly twelve on-screen boost slots."
	)
	var day_emission := _find_bound_guardian_emission(outer_guardians)
	var night_emission := _find_bound_guardian_emission(inner_guardians)
	var day_material := (
		day_emission.material as ShaderMaterial
		if day_emission != null
		else null
	)
	var night_material := (
		night_emission.material as ShaderMaterial
		if night_emission != null
		else null
	)
	_expect(
		day_emission != null
		and night_emission != null
		and day_emission.get("_controller") == outer_controller
		and night_emission.get("_controller") == inner_controller
		and day_material != null
		and night_material != null
		and day_material != night_material
		and is_equal_approx(
			float(day_material.get_shader_parameter(&"night_factor")),
			0.0
		)
		and is_equal_approx(
			float(night_material.get_shader_parameter(&"night_factor")),
			1.0
		),
		"Nested combat branches must keep independent day/night emission materials."
	)

	var reentered_guardian: YuanshiInsectAura = null
	for guardian_variant in outer_guardians:
		var guardian := guardian_variant as YuanshiInsectAura
		if not guardian.is_in_group(
			YuanshiInsectAura.GUARDIAN_EMISSION_ACTIVE_GROUP
		):
			reentered_guardian = guardian
			break
	_expect(
		reentered_guardian != null,
		"The full nested budget fixture must leave an outer re-entry candidate."
	)
	if reentered_guardian != null:
		var guardian_parent := reentered_guardian.get_parent()
		guardian_parent.remove_child(reentered_guardian)
		await process_frame
		guardian_parent.add_child(reentered_guardian)
		await process_frame
		await process_frame
		_expect(
			reentered_guardian.is_in_group(
				YuanshiInsectAura.GUARDIAN_EMISSION_CANDIDATE_GROUP
			)
			and not reentered_guardian.is_in_group(
				YuanshiInsectAura.GUARDIAN_EMISSION_ACTIVE_GROUP
			)
			and _count_guardian_emission_slots(outer_guardians) == 9
			and _count_guardian_emission_slots(inner_guardians) == 3,
			"A re-entered guardian must remain eligible while the twelve slots are full."
		)

	inner_branch.hide()
	await process_frame
	await process_frame
	outer_controller.set_night_factor_immediate(0.45)
	await process_frame
	_expect(
		_count_guardian_emission_slots(outer_guardians)
		== YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS
		and _count_guardian_emission_slots(inner_guardians) == 0
		and is_instance_valid(day_emission)
		and day_emission.get("_controller") == outer_controller
		and day_material != null
		and is_equal_approx(
			float(day_material.get_shader_parameter(&"night_factor")),
			0.45
		)
		and (
			day_material.get_shader_parameter(
				&"canvas_modulate_color"
			) as Color
		).is_equal_approx(outer_controller.color),
		"Returning from nested combat must restore all outer slots without resetting its material."
	)
	inner_branch.queue_free()
	outer_branch.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _create_nested_guardian_branch(
	branch_name: String,
	guardian_count: int,
	branch_visible: bool,
	player: Player
) -> Dictionary:
	var branch := Node2D.new()
	branch.name = branch_name
	branch.visible = branch_visible
	test_root.add_child(branch)
	var controller := DayNightController.new()
	controller.name = "DayNightController"
	# The smoke test only needs controller state; avoid two CanvasModulate nodes
	# competing for the same test viewport.
	controller.visible = false
	branch.add_child(controller)
	var branch_enemies := Node2D.new()
	branch_enemies.name = "EnemyContainer"
	branch.add_child(branch_enemies)
	var guardians: Array[YuanshiInsectAura] = []
	for guardian_index in range(guardian_count):
		var guardian := GUARDIAN_CONFIG.enemy_scene.instantiate() as YuanshiInsectAura
		guardian.name = "Guardian%d" % guardian_index
		branch_enemies.add_child(guardian)
		guardian.setup(GUARDIAN_CONFIG, player)
		guardian.set_process(false)
		guardian.set_physics_process(false)
		guardians.append(guardian)
	return {
		"branch": branch,
		"controller": controller,
		"guardians": guardians,
	}


func _count_guardian_emission_slots(guardians: Array) -> int:
	var active_count := 0
	for guardian_variant in guardians:
		var guardian := guardian_variant as YuanshiInsectAura
		var emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		var owns_slot := guardian.is_in_group(
			YuanshiInsectAura.GUARDIAN_EMISSION_ACTIVE_GROUP
		)
		_expect(
			emission != null and emission.visible == owns_slot,
			"Guardian emission visibility must exactly match active slot ownership."
		)
		if owns_slot:
			active_count += 1
	return active_count


func _count_bound_guardian_emissions(guardians: Array) -> int:
	var bound_count := 0
	for guardian_variant in guardians:
		var guardian := guardian_variant as YuanshiInsectAura
		var emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		if emission != null and emission.get("_controller") != null:
			bound_count += 1
	return bound_count


func _find_bound_guardian_emission(guardians: Array) -> Sprite2D:
	for guardian_variant in guardians:
		var guardian := guardian_variant as YuanshiInsectAura
		var emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		if emission != null and emission.get("_controller") != null:
			return emission
	return null


func _test_authoritative_processing_gate() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	guardian_aura_system.set_authoritative_processing_enabled(false)
	_expect(
		not guardian_aura_system.is_physics_processing()
		and guardian_aura_system.tracked_enemy_ids.is_empty(),
		"Client-view GuardianAuraSystem must stop physics work and release tracking."
	)
	var proxy := _spawn_enemy(Vector2.ZERO, BASIC_CONFIG, player)
	proxy.set_physics_process(false)
	await process_frame
	_expect(
		not guardian_aura_system.tracked_enemies.has(proxy.get_instance_id()),
		"Disabled GuardianAuraSystem must not track newly replicated enemies."
	)
	guardian_aura_system.set_authoritative_processing_enabled(true)
	await process_frame
	_expect(
		guardian_aura_system.is_physics_processing()
		and guardian_aura_system.tracked_enemies.has(proxy.get_instance_id()),
		"Re-enabled GuardianAuraSystem must rebuild tracking from authored containers."
	)
	proxy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_render_frame_refresh_limit() -> void:
	var original_limit: bool = guardian_aura_system.limit_refresh_to_once_per_render_frame
	guardian_aura_system.limit_refresh_to_once_per_render_frame = false
	var unrestricted_start: int = guardian_aura_system.refresh_service_step_count
	for _tick in range(8):
		guardian_aura_system.call("_physics_process", 1.0 / 60.0)
	_expect(
		guardian_aura_system.refresh_service_step_count - unrestricted_start == 8,
		"Unrestricted A/B scheduler fixture must execute every physics catch-up tick."
	)

	guardian_aura_system.limit_refresh_to_once_per_render_frame = true
	guardian_aura_system.last_refresh_render_frame = -1
	var limited_start: int = guardian_aura_system.refresh_service_step_count
	for _tick in range(8):
		guardian_aura_system.call("_physics_process", 1.0 / 60.0)
	_expect(
		guardian_aura_system.refresh_service_step_count - limited_start == 1,
		"Render-frame limiter must admit exactly one guardian refresh service step."
	)
	guardian_aura_system.limit_refresh_to_once_per_render_frame = original_limit


func _test_first_source_refresh_keeps_boundary_overlap() -> void:
	var player := _spawn_player(Vector2(240.0, 0.0))
	var guardian := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var boundary_target := _spawn_enemy(Vector2(53.0, 0.0), BASIC_CONFIG, player)
	guardian.set_physics_process(false)
	boundary_target.set_physics_process(false)

	var combat_index := CombatTargetIndex.new()
	combat_index.register_enemy(1, guardian)
	combat_index.register_enemy(2, boundary_target)
	guardian_aura_system.call("_classify_pending_guardians")
	guardian_aura_system.refresh_guardian_debt = 1.0
	guardian_aura_system.call("_service_refresh_target_debt")
	_expect(
		guardian_aura_system.maximum_tracked_target_extent
			>= boundary_target.body_collision_extent_radius
		and guardian_aura_system.has_guardian_source(boundary_target, guardian),
		(
			"The first source-driven refresh must include a ready-time collision "
			+ "extent when the target center is outside the aura but its body overlaps "
			+ "(maximum=%.2f target=%.2f covered=%s)."
		)
		% [
			guardian_aura_system.maximum_tracked_target_extent,
			boundary_target.body_collision_extent_radius,
			guardian_aura_system.has_guardian_source(boundary_target, guardian),
		]
	)

	combat_index.clear()
	guardian.queue_free()
	boundary_target.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_damage_defense_formulas() -> void:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	await physics_frame
	player.invincibility_duration = 0.0
	player.current_health = 20
	player.physical_defense = 2
	player.magic_defense = 25
	player.apply_damage(5)
	_expect(player.current_health == 17, "Player physical defense formula is incorrect.")
	# Damage refreshes derived collectible stats, so set the second isolated
	# formula fixture after the first assertion.
	player.magic_defense = 25
	player.apply_damage(7, EnemyConfig.DamageType.MAGIC)
	_expect(player.current_health == 12, "Player magic defense formula is incorrect.")

	var enemy_config := BASIC_CONFIG.duplicate(true) as YuanshiInsectConfig
	enemy_config.physical_defense = 2
	enemy_config.magic_defense = 25
	var enemy := _spawn_enemy(Vector2.ZERO, enemy_config, player)
	enemy.current_health = 20
	enemy.apply_damage(5)
	_expect(enemy.current_health == 17, "Enemy physical defense formula is incorrect.")
	enemy.apply_damage(7, Vector2.ZERO, EnemyConfig.DamageType.MAGIC)
	_expect(enemy.current_health == 12, "Enemy magic defense formula is incorrect.")

	player.queue_free()
	enemy.queue_free()
	await process_frame
	await physics_frame


func _test_guardian_aura_visual_configuration() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var guardian: Variant = _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	_expect(guardian != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian == null:
		player.queue_free()
		return
	_expect(guardian.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	await _wait_physics_frames(3)

	_expect(guardian.aura_active, "Guardian aura did not start.")
	_expect(not GUARDIAN_CONFIG.aura_particles_enabled, "Guardian aura particles should be disabled.")
	_expect(
		guardian.aura_particles == null
		and guardian.aura_range_outline == null
		and guardian.aura_area == null
		and guardian.aura_area_shape == null,
		"Guardian shared-script aura dependencies must resolve to null without local nodes."
	)
	for absent_node_path in [
		"AuraParticles",
		"AuraRangeFill",
		"AuraRangeOutline",
		"AuraArea",
		"AuraArea/CollisionShape2D",
	]:
		_expect(
			guardian.get_node_or_null(absent_node_path) == null,
			"Guardian must not retain unused local aura node %s." % absent_node_path
		)
	var guardian_halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
	var guardian_light_emission := guardian.get_node_or_null(
		"GuardianLightEmission"
	) as Sprite2D
	var guardian_body_material := guardian.animated_sprite.material as ShaderMaterial
	var authored_lights: Array[Node] = guardian.find_children(
		"*",
		"Light2D",
		true,
		false
	)
	_expect(
		authored_lights.is_empty()
		and guardian.get_node_or_null("GuardianLight") == null,
		"Guardian decoration must not retain any real Light2D nodes."
	)
	_expect(
		guardian_halo != null,
		"Guardian must use a visible self-emission halo for readable glow."
	)
	_expect(
		guardian_body_material == null
		or (
			guardian_body_material.shader != null
			and guardian_body_material.shader.resource_path == ENEMY_VISUAL_SHADER_PATH
		),
		"Guardian body sprite must not draw the glow directly."
	)
	_expect(not guardian.has_node("GuardianGlowSprite"), "Guardian must not use the previous baked glow sprite.")
	if guardian_halo != null:
		var halo_material := guardian_halo.material as CanvasItemMaterial
		_expect(
			guardian_halo.texture != null
			and guardian_halo.texture.resource_path.ends_with("guardian_point_light.png"),
			"Guardian halo sprite must use the same soft radial light texture."
		)
		_expect(
			halo_material != null
			and halo_material.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD,
			"Guardian halo must use additive blending so its transparent fringe cannot darken the ground."
		)
		_expect(
			halo_material != null
			and halo_material.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED,
			"Every guardian halo must remain self-lit without a real Light2D budget."
		)
		_expect(
			guardian_halo.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR,
			"Guardian halo sprite must use linear filtering."
		)
		_expect(
			guardian_halo.scale.x <= 1.0 and guardian_halo.scale.y <= 1.0,
			"Guardian halo sprite must stay close to the body, not become a large background blob."
		)
		_expect(
			guardian_halo.modulate.is_equal_approx(
				LEGACY_GUARDIAN_DEATH_HALO_MODULATE
			),
			"Guardian base halo must preserve the legacy weak cyan intensity."
		)
		_expect(
			guardian_halo.z_index < guardian.animated_sprite.z_index,
			"Guardian halo sprite must render behind the body."
		)
	_expect(
		guardian_light_emission != null
		and guardian_halo != null
		and guardian_light_emission.texture == guardian_halo.texture
		and guardian_light_emission.material is ShaderMaterial
		and (guardian_light_emission.material as ShaderMaterial).shader != null
		and (guardian_light_emission.material as ShaderMaterial).shader.resource_path.ends_with(
			"guardian_light_emission.gdshader"
		)
		and guardian_light_emission.texture_filter
		== CanvasItem.TEXTURE_FILTER_LINEAR
		and guardian_light_emission.scale.is_equal_approx(Vector2(0.95, 0.95))
		and guardian_light_emission.visible
		and guardian_light_emission.z_index > guardian.animated_sprite.z_index,
		"Guardian boost must use the shared receiver-aware self-emission material."
	)
	guardian.apply_damage(1, Vector2.ZERO, EnemyConfig.DamageType.MAGIC)
	if guardian_body_material != null:
		_expect(
			guardian_body_material.get_shader_parameter(&"blink_enabled") != true,
			"Guardian must not start hurt blink when damaged."
		)
	_expect(
		guardian.get_effective_physical_defense() == GUARDIAN_CONFIG.physical_defense,
		"Guardian must not receive its own aura defense."
	)
	guardian.apply_damage(100000, Vector2.ZERO, EnemyConfig.DamageType.MAGIC)
	_expect(
		guardian.is_dead
		and guardian_halo != null
		and guardian_halo.visible
		and guardian_halo.modulate.is_equal_approx(
			LEGACY_GUARDIAN_DEATH_HALO_MODULATE
		)
		and guardian_light_emission != null
		and not guardian_light_emission.visible,
		"Authoritative guardian death must restore the legacy low-intensity halo transition."
	)

	guardian.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_green_shell_keeps_player_area_contract() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var green_shell := _spawn_enemy(Vector2.ZERO, GREEN_SHELL_CONFIG, player)
	green_shell.set_physics_process(false)
	await _wait_physics_frames(3)

	_expect(green_shell.aura_active, "Green-shell player aura did not start.")
	_expect(green_shell.aura_area.collision_mask == 2, "Green-shell aura must still monitor players.")
	_expect(green_shell.aura_area.monitoring, "Green-shell aura monitoring was disabled with guardian aura.")
	_expect(green_shell.aura_area.monitorable, "Green-shell aura must remain monitorable after startup.")
	_expect(not green_shell.aura_area_shape.disabled, "Green-shell aura shape must remain enabled.")
	_expect(
		not green_shell.aura_area.body_entered.get_connections().is_empty(),
		"Green-shell aura must retain its player body callback."
	)

	green_shell.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_guardian_chase_and_collision_contract() -> void:
	var player := _spawn_player(Vector2(96.0, 0.0))
	var guardian: Variant = _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var pathfinder := NavigationStub.new()
	test_root.add_child(pathfinder)
	_expect(guardian != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian == null:
		player.queue_free()
		pathfinder.queue_free()
		return
	guardian.set_pathfinder(pathfinder)
	_expect(guardian.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	await _wait_physics_frames(2)

	var body_shape := guardian.collision_shape.shape as Shape2D
	var touch_shape := guardian.touch_damage_shape.shape as Shape2D
	_expect(body_shape != null, "Guardian body collision shape must be configured.")
	_expect(touch_shape != null, "Guardian touch damage shape must be configured.")
	if body_shape != null:
		_expect(_get_shape_extent_radius(guardian.collision_shape) > 0.0, "Guardian body collision extent must be positive.")
	if touch_shape != null:
		_expect(_get_shape_extent_radius(guardian.touch_damage_shape) > 0.0, "Guardian touch damage extent must be positive.")
	_expect(guardian.collision_shape.shape != guardian.touch_damage_shape.shape, "Guardian body and touch shapes must be independently editable.")

	var start_distance: float = guardian.global_position.distance_to(player.global_position)
	await _wait_physics_frames(12)
	var end_distance: float = guardian.global_position.distance_to(player.global_position)
	_expect(
		end_distance < start_distance - 1.0,
		"Guardian did not move toward the player (%.2f -> %.2f, speed %.2f, physics=%s, mode=%d)."
		% [
			start_distance,
			end_distance,
			guardian.get_effective_move_speed(),
			str(guardian.is_physics_processing()),
			guardian.process_mode,
		]
	)

	guardian.queue_free()
	player.queue_free()
	pathfinder.queue_free()
	await process_frame
	await physics_frame


func _test_guardian_aura_matches_legacy_overlap() -> void:
	var original_source_driven := GuardianAuraSystem.source_driven_refresh_enabled
	GuardianAuraSystem.source_driven_refresh_enabled = false
	var player := _spawn_player(Vector2(240.0, 0.0))
	var guardian := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var target := _spawn_enemy(Vector2.ZERO, BASIC_CONFIG, player)
	guardian.set_physics_process(false)
	target.set_physics_process(false)
	var sample_positions := [
		Vector2(32.0, 0.0),
		Vector2(52.0, 0.0),
		Vector2(57.0, 0.0),
		Vector2(42.0, 24.0),
		Vector2(46.0, 30.0),
		Vector2(-51.0, -8.0),
	]

	for sample_position in sample_positions:
		target.global_position = sample_position
		await physics_frame
		guardian_aura_system.use_snapshot_coverage_grid = true
		guardian_aura_system.force_refresh_all()
		var snapshot_overlap: bool = guardian_aura_system.has_guardian_source(target, guardian)
		guardian_aura_system.use_snapshot_coverage_grid = false
		guardian_aura_system.force_refresh_all()
		var legacy_centralized_overlap: bool = guardian_aura_system.has_guardian_source(
			target,
			guardian
		)
		var legacy_overlap := _legacy_guardian_area_overlaps(guardian, target)
		_expect(
			snapshot_overlap == legacy_centralized_overlap
			and snapshot_overlap == legacy_overlap,
			(
				"Snapshot guardian overlap diverged at %s "
				+ "(snapshot=%s centralized_legacy=%s area_legacy=%s)."
			)
			% [
				sample_position,
				snapshot_overlap,
				legacy_centralized_overlap,
				legacy_overlap,
			]
		)
	guardian_aura_system.use_snapshot_coverage_grid = true
	await _test_offset_shape_larger_than_aura_certificate(guardian, target)

	target.collision_layer = 0
	guardian_aura_system.force_refresh_all()
	_expect(
		not guardian_aura_system.has_guardian_source(target, guardian)
		and not _legacy_guardian_area_overlaps(guardian, target),
		"Collision-layer-disabled enemies must stay outside both centralized and legacy aura queries."
	)
	target.collision_layer = 4
	target.collision_shape.set_deferred("disabled", true)
	await _wait_physics_frames(2)
	guardian_aura_system.force_refresh_all()
	_expect(
		not guardian_aura_system.has_guardian_source(target, guardian)
		and not _legacy_guardian_area_overlaps(guardian, target),
		"Collision-shape-disabled enemies must stay outside both centralized and legacy aura queries."
	)
	target.collision_shape.set_deferred("disabled", false)
	await _wait_physics_frames(2)

	guardian.queue_free()
	target.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame
	GuardianAuraSystem.source_driven_refresh_enabled = original_source_driven


func _test_source_driven_index_and_fixture_fallback() -> void:
	var original_source_driven := GuardianAuraSystem.source_driven_refresh_enabled
	var player := _spawn_player(Vector2(240.0, 0.0))
	var guardian := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var near_target := _spawn_enemy(Vector2(34.0, 0.0), BASIC_CONFIG, player)
	var boundary_target := _spawn_enemy(Vector2(54.0, 0.0), BASIC_CONFIG, player)
	var far_target := _spawn_enemy(Vector2(120.0, 0.0), BASIC_CONFIG, player)
	var ephemeral_target := _spawn_enemy(Vector2(10.0, 0.0), BASIC_CONFIG, player)
	var cohort: Array[Enemy] = [
		guardian,
		near_target,
		boundary_target,
		far_target,
		ephemeral_target,
	]
	for enemy in cohort:
		enemy.set_physics_process(false)
	await _wait_physics_frames(2)

	GuardianAuraSystem.source_driven_refresh_enabled = false
	guardian_aura_system.force_refresh_all()
	var reference_membership := PackedByteArray()
	for target in cohort:
		reference_membership.append(
			1 if guardian_aura_system.has_guardian_source(target, guardian) else 0
		)

	guardian_aura_system.reset_runtime_performance_metrics()
	GuardianAuraSystem.source_driven_refresh_enabled = true
	guardian_aura_system.force_refresh_all()
	var fallback_matches := true
	for target_index in range(cohort.size()):
		var actual: bool = guardian_aura_system.has_guardian_source(
			cohort[target_index],
			guardian
		)
		if actual != (reference_membership[target_index] == 1):
			fallback_matches = false
			break
	_expect(
		fallback_matches
		and guardian_aura_system.source_fallback_scan_count > 0
		and guardian_aura_system.source_index_query_count == 0,
		"Source-driven fixture fallback must exactly match target-driven membership."
	)

	var combat_index := CombatTargetIndex.new()
	for target_index in range(cohort.size()):
		combat_index.register_enemy(target_index + 1, cohort[target_index])
	guardian_aura_system.reset_runtime_performance_metrics()
	guardian_aura_system.force_refresh_all()
	var indexed_matches := true
	for target_index in range(cohort.size()):
		var actual: bool = guardian_aura_system.has_guardian_source(
			cohort[target_index],
			guardian
		)
		if actual != (reference_membership[target_index] == 1):
			indexed_matches = false
			break
	_expect(
		indexed_matches
		and guardian_aura_system.source_index_query_count == 1
		and guardian_aura_system.source_fallback_scan_count == 0,
		"Indexed source refresh must match target-driven membership without a full scan."
	)

	var original_service_budget: int = guardian_aura_system.max_refresh_service_usec
	guardian_aura_system.max_refresh_service_usec = 0
	guardian_aura_system.reset_runtime_performance_metrics()
	guardian_aura_system.refresh_guardian_debt = 1.0
	var deferred_cursor_before: int = guardian_aura_system.refresh_guardian_cursor
	guardian_aura_system.call("_service_refresh_target_debt")
	_expect(
		guardian_aura_system.source_deferred_refresh_count == 1
		and guardian_aura_system.refresh_guardian_debt == 1.0
		and guardian_aura_system.last_refresh_guardian_count == 0
		and guardian_aura_system.refresh_guardian_cursor == deferred_cursor_before
		and guardian_aura_system.pending_source_refresh_id
			== guardian.get_instance_id()
		and guardian_aura_system.pending_source_candidates_require_revalidation
		and guardian_aura_system.source_candidate_scratch.has(ephemeral_target)
		and guardian_aura_system.has_guardian_source(near_target, guardian),
		"A deferred source query must preserve coverage, debt, and cursor ownership."
	)
	# The retained array owns a strong candidate reference across render frames.
	# Remove one candidate before resuming to prove that only this cross-frame path
	# revalidates stale Objects before reading collision state.
	cohort.erase(ephemeral_target)
	ephemeral_target.free()
	guardian_aura_system.max_refresh_service_usec = original_service_budget
	guardian_aura_system.call("_service_refresh_target_debt")
	_expect(
		guardian_aura_system.pending_source_refresh_id == 0
		and guardian_aura_system.refresh_guardian_debt == 0.0
		and guardian_aura_system.last_refresh_guardian_count == 1,
		"A resumed source query must finish without repeating its completed chunk."
	)

	# Production must preserve the last complete coverage and defer when a
	# registration race makes the index temporarily incomplete. It may neither
	# publish partial coverage nor fall back to an O(enemy_count) scan.
	guardian_aura_system.allow_tracked_enemy_fallback_scan = false
	combat_index.unregister_enemy(2, near_target)
	guardian_aura_system.reset_runtime_performance_metrics()
	guardian_aura_system.refresh_guardian_cursor = 0
	guardian_aura_system.refresh_guardian_debt = 1.0
	guardian_aura_system.call("_service_refresh_target_debt")
	_expect(
		guardian_aura_system.source_index_query_count == 0
		and guardian_aura_system.source_fallback_scan_count == 0
		and guardian_aura_system.source_deferred_refresh_count == 1
		and guardian_aura_system.refresh_guardian_debt == 1.0
		and guardian_aura_system.last_refresh_guardian_count == 0
		and guardian_aura_system.refresh_guardian_cursor == 0
		and guardian_aura_system.has_guardian_source(near_target, guardian),
		"An incomplete production index must defer while preserving complete coverage."
	)
	combat_index.register_enemy(2, near_target)
	guardian_aura_system.call("_service_refresh_target_debt")
	_expect(
		guardian_aura_system.source_index_query_count == 1
		and guardian_aura_system.refresh_guardian_debt == 0.0
		and guardian_aura_system.last_refresh_guardian_count == 1,
		"A repaired index must resume the deferred guardian on the next service step."
	)
	guardian_aura_system.allow_tracked_enemy_fallback_scan = true

	combat_index.clear()
	for enemy in cohort:
		enemy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame
	GuardianAuraSystem.source_driven_refresh_enabled = original_source_driven


func _test_pending_source_refresh_survives_guardian_compaction() -> void:
	var original_source_driven := GuardianAuraSystem.source_driven_refresh_enabled
	var original_service_budget: int = guardian_aura_system.max_refresh_service_usec
	GuardianAuraSystem.source_driven_refresh_enabled = true
	var player := _spawn_player(Vector2(240.0, 0.0))
	var predecessor := _spawn_enemy(Vector2(-12.0, 0.0), GUARDIAN_CONFIG, player)
	var pending_guardian := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var trailing_guardian := _spawn_enemy(Vector2(12.0, 0.0), GUARDIAN_CONFIG, player)
	var cohort: Array[Enemy] = [
		predecessor,
		pending_guardian,
		trailing_guardian,
	]
	for target_index in range(20):
		var angle := TAU * float(target_index) / 20.0
		cohort.append(
			_spawn_enemy(
				Vector2(cos(angle), sin(angle)) * 30.0,
				BASIC_CONFIG,
				player
			)
		)
	for enemy in cohort:
		enemy.set_physics_process(false)
	await _wait_physics_frames(2)

	var combat_index := CombatTargetIndex.new()
	for target_index in range(cohort.size()):
		combat_index.register_enemy(target_index + 1, cohort[target_index])
	guardian_aura_system.force_refresh_all()

	var pending_id := pending_guardian.get_instance_id()
	var predecessor_id := predecessor.get_instance_id()
	var pending_config := (
		pending_guardian.config as YuanshiInsectGuardianConfig
	)
	var world_radius := float(
		guardian_aura_system.call(
			"_get_guardian_world_radius",
			pending_guardian,
			pending_config
		)
	)
	guardian_aura_system.reset_runtime_performance_metrics()
	guardian_aura_system.call("_clear_pending_source_refresh")
	var collected := bool(
		guardian_aura_system.call(
			"_collect_source_query_candidates",
			pending_guardian,
			world_radius
		)
	)
	var candidate_count: int = guardian_aura_system.source_candidate_scratch.size()
	var completed_chunk_size := mini(8, candidate_count - 1)
	_expect(
		collected and completed_chunk_size > 0,
		"Guardian compaction fixture must collect more than one candidate."
	)
	if not collected or completed_chunk_size <= 0:
		combat_index.clear()
		for enemy in cohort:
			enemy.queue_free()
		player.queue_free()
		await process_frame
		await physics_frame
		guardian_aura_system.max_refresh_service_usec = original_service_budget
		GuardianAuraSystem.source_driven_refresh_enabled = original_source_driven
		return

	var complete_coverage_before: Dictionary = (
		guardian_aura_system.covered_enemy_ids_by_guardian
		.get(pending_id, {})
		.duplicate()
	)
	guardian_aura_system.desired_covered_enemy_ids_scratch.clear()
	for candidate_index in range(completed_chunk_size):
		var candidate := (
			guardian_aura_system.source_candidate_scratch[candidate_index]
			as Enemy
		)
		if (
			candidate != null
			and complete_coverage_before.has(candidate.get_instance_id())
		):
			guardian_aura_system.desired_covered_enemy_ids_scratch[
				candidate.get_instance_id()
			] = true
	guardian_aura_system.pending_source_refresh_id = pending_id
	guardian_aura_system.pending_source_refresh_candidate_cursor = (
		completed_chunk_size
	)
	guardian_aura_system.pending_source_refresh_position = (
		pending_guardian.global_position
	)
	guardian_aura_system.pending_source_refresh_world_radius = world_radius
	guardian_aura_system.pending_source_refresh_defense_bonus = (
		pending_config.aura_physical_defense_bonus
	)
	guardian_aura_system.source_candidate_visit_count = completed_chunk_size
	guardian_aura_system.refresh_guardian_cursor = int(
		guardian_aura_system.guardian_slot_by_id[pending_id]
	)
	guardian_aura_system.refresh_guardian_debt = 1.0
	var index_queries_before_removal: int = (
		guardian_aura_system.source_index_query_count
	)

	# Removing a source before the pending cursor compacts [A, B, C] to [C, B].
	# B must retain the service slot even though the numeric cursor moves to C.
	enemy_container.remove_child(predecessor)
	# The removed guardian also ceases to be a valid aura target immediately;
	# all other completed membership must remain identical after the resume.
	complete_coverage_before.erase(predecessor_id)
	_expect(
		not guardian_aura_system.guardians.has(predecessor_id)
		and guardian_aura_system.pending_source_refresh_id == pending_id
		and guardian_aura_system.pending_source_refresh_candidate_cursor
			== completed_chunk_size
		and guardian_aura_system.refresh_guardian_cursor
			== int(guardian_aura_system.guardian_slot_by_id[pending_id])
		and guardian_aura_system.source_index_query_count
			== index_queries_before_removal,
		"Removing an earlier guardian must preserve the pending source snapshot."
	)

	guardian_aura_system.max_refresh_service_usec = 1_000_000
	guardian_aura_system.call("_service_refresh_target_debt")
	var resumed_coverage: Dictionary = (
		guardian_aura_system.covered_enemy_ids_by_guardian.get(pending_id, {})
	)
	var coverage_matches := (
		resumed_coverage.size() == complete_coverage_before.size()
	)
	if coverage_matches:
		for enemy_id_variant in complete_coverage_before:
			if not resumed_coverage.has(int(enemy_id_variant)):
				coverage_matches = false
				break
	_expect(
		guardian_aura_system.pending_source_refresh_id == 0
		and guardian_aura_system.refresh_guardian_debt == 0.0
		and guardian_aura_system.last_refresh_guardian_count == 1
		and guardian_aura_system.source_index_query_count
			== index_queries_before_removal
		and guardian_aura_system.source_candidate_visit_count == candidate_count
		and coverage_matches,
		"A compacted pending source must resume first without re-querying or "
		+ "publishing incomplete coverage."
	)

	guardian_aura_system.max_refresh_service_usec = original_service_budget
	combat_index.clear()
	predecessor.queue_free()
	for enemy in cohort:
		if enemy != predecessor:
			enemy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame
	GuardianAuraSystem.source_driven_refresh_enabled = original_source_driven


func _test_boss_container_target_semantics() -> void:
	var player := _spawn_player(Vector2(240.0, 0.0))
	var guardian_source := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var boss_target := _spawn_enemy_in_container(
		boss_container,
		Vector2(20.0, 0.0),
		BASIC_CONFIG,
		player
	)
	var boss_guardian_target := _spawn_enemy_in_container(
		boss_container,
		Vector2(24.0, 0.0),
		GUARDIAN_CONFIG,
		player
	)
	var regular_target := _spawn_enemy(Vector2(18.0, 0.0), BASIC_CONFIG, player)
	guardian_source.set_physics_process(false)
	boss_target.set_physics_process(false)
	boss_guardian_target.set_physics_process(false)
	regular_target.set_physics_process(false)
	await _wait_physics_frames(2)
	guardian_aura_system.force_refresh_all()

	_expect(
		guardian_aura_system.has_guardian_source(boss_target, guardian_source),
		"EnemyContainer guardian did not preserve its legacy coverage of BossContainer targets."
	)
	_expect(
		guardian_aura_system.has_guardian_source(boss_target, guardian_source)
		== _legacy_guardian_area_overlaps(guardian_source, boss_target),
		"BossContainer centralized coverage diverged from the legacy Area2D query."
	)
	_expect(
		boss_target.get_effective_physical_defense() == 3,
		"BossContainer target received the wrong guardian defense value."
	)
	_expect(
		not guardian_aura_system.has_guardian_source(regular_target, boss_guardian_target),
		"A guardian-config target inside BossContainer must not become an aura source."
	)
	_expect(
		guardian_aura_system.get_guardian_count() == 1,
		"Only guardian configs from EnemyContainer may register as sources."
	)

	boss_guardian_target.reparent(enemy_container)
	guardian_aura_system.force_refresh_all()
	_expect(
		guardian_aura_system.get_guardian_count() == 2
		and guardian_aura_system.has_guardian_source(
			regular_target,
			boss_guardian_target
		)
		and regular_target.get_effective_physical_defense() == 6,
		"Reparenting a guardian from BossContainer into EnemyContainer must activate exactly one new source."
	)
	boss_guardian_target.reparent(boss_container)
	_expect(
		guardian_aura_system.get_guardian_count() == 1
		and not guardian_aura_system.has_guardian_source(
			regular_target,
			boss_guardian_target
		)
		and regular_target.get_effective_physical_defense() == 3,
		"Reparenting a guardian back to BossContainer must synchronously remove its source."
	)

	guardian_source.queue_free()
	boss_target.queue_free()
	boss_guardian_target.queue_free()
	regular_target.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_guardian_aura_defense_lifecycle() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var guardian := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	_expect(guardian != null, "Guardian scene must instantiate YuanshiInsect.")
	if guardian == null:
		player.queue_free()
		return
	_expect(guardian.get_script() == AURA_SCRIPT, "Guardian scene must use the aura script.")
	var second_guardian := _spawn_enemy(Vector2(32.0, 0.0), GUARDIAN_CONFIG, player)
	var ally := _spawn_enemy(Vector2(20.0, 0.0), BASIC_CONFIG, player)
	guardian.set_physics_process(false)
	second_guardian.set_physics_process(false)
	ally.set_physics_process(false)
	ally.current_health = 20
	await _wait_physics_frames(2)
	guardian_aura_system.force_refresh_all()
	var cache_probe_source_id := -91001
	var cache_probe_baseline := ally.get_effective_physical_defense()
	ally.add_physical_defense_modifier(cache_probe_source_id, 2)
	_expect(
		ally.get_effective_physical_defense() == cache_probe_baseline + 2,
		"Physical defense cache did not include a new source."
	)
	ally.add_physical_defense_modifier(cache_probe_source_id, 5)
	_expect(
		ally.get_effective_physical_defense() == cache_probe_baseline + 5,
		"Physical defense cache did not replace an existing source."
	)
	ally.remove_physical_defense_modifier(cache_probe_source_id)
	_expect(
		ally.get_effective_physical_defense() == cache_probe_baseline,
		"Physical defense cache did not remove a source."
	)

	_expect(
		not guardian_aura_system.has_guardian_source(guardian, guardian),
		"Guardian aura must ignore its owner."
	)
	_expect(ally.get_effective_physical_defense() == 6, "Guardian aura bonuses from multiple guardians must stack.")

	second_guardian.global_position = Vector2(120.0, 0.0)
	await _wait_physics_frames(16)
	_expect(ally.get_effective_physical_defense() == 3, "Guardian aura stack did not remove one source on exit.")
	ally.apply_damage(4)
	_expect(ally.current_health == 19, "Guardian aura did not reduce physical damage by 3.")

	ally.global_position = Vector2(240.0, 0.0)
	await _wait_physics_frames(16)
	_expect(ally.get_effective_physical_defense() == 0, "Guardian aura defense did not clear on exit.")
	ally.apply_damage(4)
	_expect(ally.current_health == 15, "Enemy kept guardian defense after leaving aura.")

	ally.global_position = Vector2(20.0, 0.0)
	second_guardian.global_position = Vector2(32.0, 0.0)
	await _wait_physics_frames(16)
	_expect(ally.get_effective_physical_defense() == 6, "Guardian aura did not reapply overlapping sources after movement.")
	guardian.apply_damage(
		GUARDIAN_CONFIG.max_health
		+ 100
	)
	_expect(not guardian.is_physics_processing(), "Dead guardian must stop script physics immediately.")
	_expect(
		ally.get_effective_physical_defense() == 3,
		"Dead guardian source was not removed synchronously while another source remained."
	)
	second_guardian.apply_damage(
		GUARDIAN_CONFIG.max_health
		+ 100
	)
	_expect(ally.get_effective_physical_defense() == 0, "Guardian aura defense did not clear on death.")
	var removed_guardian := _spawn_enemy(Vector2(18.0, 0.0), GUARDIAN_CONFIG, player)
	removed_guardian.set_physics_process(false)
	guardian_aura_system.force_refresh_all()
	_expect(ally.get_effective_physical_defense() == 3, "New guardian source was not registered.")
	enemy_container.remove_child(removed_guardian)
	_expect(
		ally.get_effective_physical_defense() == 0,
		"Removing a guardian from EnemyContainer did not clear its source synchronously."
	)
	removed_guardian.queue_free()
	var audited_guardian := _spawn_enemy(Vector2(18.0, 0.0), GUARDIAN_CONFIG, player)
	audited_guardian.set_physics_process(false)
	guardian_aura_system.force_refresh_all()
	_expect(
		ally.get_effective_physical_defense() == 3,
		"Bounded invalid-source audit fixture did not apply its guardian source."
	)
	# Simulate an abnormal lifecycle that bypasses both defeated and child_exiting.
	# Production removals still use those synchronous paths; this verifies the
	# batched cursor remains a bounded safety net without a per-frame full scan.
	audited_guardian.is_dead = true
	await _wait_physics_frames(16)
	_expect(
		ally.get_effective_physical_defense() == 0
		and not guardian_aura_system.tracked_enemies.has(
			audited_guardian.get_instance_id()
		),
		"A missed lifecycle signal must be audited and fully untracked within one refresh interval."
	)
	audited_guardian.queue_free()

	if is_instance_valid(guardian):
		guardian.queue_free()
	if is_instance_valid(second_guardian):
		second_guardian.queue_free()
	ally.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_multiplayer_proxy_guardian_values() -> void:
	var player := _spawn_player(Vector2(180.0, 0.0))
	var first_guardian := _spawn_enemy(Vector2.ZERO, GUARDIAN_CONFIG, player)
	var second_guardian := _spawn_enemy(Vector2(30.0, 0.0), GUARDIAN_CONFIG, player)
	var ally := _spawn_enemy(Vector2(18.0, 0.0), BASIC_CONFIG, player)
	first_guardian.configure_multiplayer_proxy()
	second_guardian.configure_multiplayer_proxy()
	ally.configure_multiplayer_proxy()
	await _wait_physics_frames(2)
	guardian_aura_system.force_refresh_all()

	_expect(
		ally.get_effective_physical_defense() == 6,
		"Multiplayer proxies must derive the same +6 overlapping guardian defense."
	)
	_expect(
		first_guardian.get_node_or_null("AuraArea") == null
		and second_guardian.get_node_or_null("AuraArea") == null,
		"Multiplayer guardian values must not depend on per-guardian Area2D nodes."
	)
	first_guardian.play_multiplayer_death_sequence()
	_expect(
		ally.get_effective_physical_defense() == 3,
		"Proxy guardian death did not synchronously remove exactly one centralized source."
	)
	var proxy_halo := first_guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
	var proxy_light_emission := first_guardian.get_node_or_null(
		"GuardianLightEmission"
	) as Sprite2D
	_expect(
		proxy_halo != null
		and proxy_halo.modulate.is_equal_approx(
			LEGACY_GUARDIAN_DEATH_HALO_MODULATE
		)
		and proxy_light_emission != null
		and not proxy_light_emission.visible,
		"Proxy guardian death must use the same low-intensity self-emission transition."
	)
	await physics_frame

	first_guardian.queue_free()
	second_guardian.queue_free()
	ally.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_offset_shape_larger_than_aura_certificate(
	guardian: YuanshiInsect,
	target: YuanshiInsect
) -> void:
	var original_shape_position := target.collision_shape.position
	target.global_position = guardian.global_position
	target.collision_shape.position = Vector2(GUARDIAN_CONFIG.aura_radius + 24.0, 0.0)
	target.call("_refresh_collision_shape_cache")
	await physics_frame

	guardian_aura_system.use_extent_overlap_certificates = false
	guardian_aura_system.force_refresh_all()
	var exact_overlap: bool = guardian_aura_system.has_guardian_source(target, guardian)
	guardian_aura_system.use_extent_overlap_certificates = true
	guardian_aura_system.force_refresh_all()
	var certified_overlap: bool = guardian_aura_system.has_guardian_source(target, guardian)
	var legacy_overlap := _legacy_guardian_area_overlaps(guardian, target)
	_expect(
		not exact_overlap and not certified_overlap and not legacy_overlap,
		(
			"Containment certificate must not accept an offset body whose "
			+ "conservative extent is larger than the aura "
			+ "(exact=%s certified=%s area=%s)."
		)
		% [exact_overlap, certified_overlap, legacy_overlap]
	)

	target.collision_shape.position = original_shape_position
	target.call("_refresh_collision_shape_cache")
	await physics_frame


func _test_dense_guardian_registration_and_teardown() -> void:
	var player := _spawn_player(Vector2(1000.0, 1000.0))
	await _wait_physics_frames(3)
	var guardians: Array[YuanshiInsect] = []
	for guardian_index in range(64):
		var guardian := _spawn_enemy(
			Vector2(
				float(guardian_index % 8) * 2.0,
				float(guardian_index / 8) * 2.0
			),
			GUARDIAN_CONFIG,
			player
		)
		guardian.set_physics_process(false)
		guardians.append(guardian)
	await _wait_physics_frames(5)

	for guardian in guardians:
		_expect(
			guardian.get_node_or_null("AuraArea") == null,
			"Dense guardian cohorts must not instantiate per-guardian AuraArea nodes."
		)
	_expect(
		guardian_aura_system.get_guardian_count() == guardians.size(),
		"GuardianAuraSystem did not register the dense guardian cohort."
	)
	var boosted_guardians: Array[YuanshiInsect] = []
	var emission_states_are_exact := true
	for guardian in guardians:
		var halo := guardian.get_node_or_null("GuardianLightHalo") as Sprite2D
		var light_emission := guardian.get_node_or_null(
			"GuardianLightEmission"
		) as Sprite2D
		var boosted := light_emission != null and light_emission.visible
		if boosted:
			boosted_guardians.append(guardian)
		if (
			halo == null
			or not halo.visible
			or not halo.modulate.is_equal_approx(
				LEGACY_GUARDIAN_DEATH_HALO_MODULATE
			)
			or not guardian.find_children("*", "Light2D", true, false).is_empty()
		):
			emission_states_are_exact = false
	_expect(
		boosted_guardians.size()
		== YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS
		and emission_states_are_exact,
		"Dense guardians must preserve the legacy 12-boost/remaining-weak visual budget without Light2D."
	)
	var tracked_slots_are_exact := true
	for slot in range(guardian_aura_system.tracked_enemy_ids.size()):
		var enemy_id := int(guardian_aura_system.tracked_enemy_ids[slot])
		if int(guardian_aura_system.tracked_enemy_slot_by_id.get(enemy_id, -1)) != slot:
			tracked_slots_are_exact = false
			break
	var guardian_slots_are_exact := true
	for slot in range(guardian_aura_system.guardian_ids.size()):
		var guardian_id := int(guardian_aura_system.guardian_ids[slot])
		if int(guardian_aura_system.guardian_slot_by_id.get(guardian_id, -1)) != slot:
			guardian_slots_are_exact = false
			break
	_expect(
		tracked_slots_are_exact and guardian_slots_are_exact,
		"Dense guardian registration must keep exact O(1) removal slot mappings."
	)
	if not boosted_guardians.is_empty():
		var released_boosted_guardian := boosted_guardians[0]
		guardians.erase(released_boosted_guardian)
		released_boosted_guardian.queue_free()
		await process_frame
		await process_frame
		var replacement_boost_count := 0
		for guardian in guardians:
			var light_emission := guardian.get_node_or_null(
				"GuardianLightEmission"
			) as Sprite2D
			if light_emission != null and light_emission.visible:
				replacement_boost_count += 1
		_expect(
			replacement_boost_count
			== YuanshiInsectAura.MAX_ACTIVE_GUARDIAN_EMISSION_BOOSTS,
			"Releasing a self-emission slot must promote exactly one weak guardian."
		)

	for guardian in guardians:
		guardian.queue_free()
	player.queue_free()
	await process_frame
	await _wait_physics_frames(3)
	_expect(
		guardian_aura_system.tracked_enemy_ids.is_empty()
		and guardian_aura_system.tracked_enemy_slot_by_id.is_empty()
		and guardian_aura_system.guardian_ids.is_empty()
		and guardian_aura_system.guardian_slot_by_id.is_empty()
		and guardian_aura_system.tracked_enemies.is_empty()
		and guardian_aura_system.guardians.is_empty()
		and guardian_aura_system.aura_sources_by_enemy.is_empty()
		and guardian_aura_system.covered_enemy_ids_by_guardian.is_empty(),
		"Dense guardian teardown must clear all order, slot, source, and reference indexes."
	)


func _legacy_guardian_area_overlaps(guardian: YuanshiInsect, target: Enemy) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	var legacy_shape := CircleShape2D.new()
	legacy_shape.radius = GUARDIAN_CONFIG.aura_radius
	query.shape = legacy_shape
	query.transform = guardian.global_transform
	query.collision_mask = 4
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [guardian.get_rid()]
	var intersections := guardian.get_world_2d().direct_space_state.intersect_shape(query, 32)
	for intersection in intersections:
		if intersection.get("collider") == target:
			return true
	return false


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
	player.global_position = position
	return player


func _spawn_enemy(
	position: Vector2,
	enemy_config: YuanshiInsectConfig,
	player: Player
) -> YuanshiInsect:
	return _spawn_enemy_in_container(enemy_container, position, enemy_config, player)


func _spawn_enemy_in_container(
	spawn_container: Node2D,
	position: Vector2,
	enemy_config: YuanshiInsectConfig,
	player: Player
) -> YuanshiInsect:
	var enemy := enemy_config.enemy_scene.instantiate() as YuanshiInsect
	spawn_container.add_child(enemy)
	enemy.global_position = position
	enemy.setup(enemy_config, player)
	return enemy


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _get_shape_extent_radius(shape_node: CollisionShape2D) -> float:
	if shape_node == null or shape_node.shape == null:
		return 0.0
	var shape_rect := shape_node.shape.get_rect()
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
		shape_rect.position + shape_rect.size,
	]
	var max_radius := 0.0
	for corner in corners:
		max_radius = maxf(max_radius, (shape_node.transform * corner).length())
	return max_radius


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
