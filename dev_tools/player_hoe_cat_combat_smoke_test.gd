extends SceneTree

const HOE_CAT_SCENE_PATH := "res://scene/player_hoe_cat.tscn"
const SPIRAL_PICKUP := preload("res://resources/config/pickups/pickup_spiral.tres")
const RAPID_PICKUP := preload("res://resources/config/pickups/pickup_rapid.tres")


class TestEnemy:
	extends Enemy

	var total_damage_taken: int = 0

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass

	func apply_damage(
		amount: int,
		_impact_direction: Vector2 = Vector2.ZERO,
		_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	) -> bool:
		if is_dead or amount <= 0:
			return false
		total_damage_taken += amount
		current_health -= amount
		if current_health <= 0:
			is_dead = true
		return true


var failures: Array[String] = []
var test_root: Node2D = null
var player: PlayerHoeCat = null
var front_enemy: TestEnemy = null
var back_enemy: TestEnemy = null
var second_front_enemy: TestEnemy = null
var angle_boundary_enemy: TestEnemy = null
var outside_angle_enemy: TestEnemy = null
var negative_angle_boundary_enemy: TestEnemy = null
var negative_outside_angle_enemy: TestEnemy = null
var radius_boundary_enemy: TestEnemy = null
var outside_radius_enemy: TestEnemy = null
var dense_cone_enemies: Array[TestEnemy] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PlayerHoeCatCombatSmokeRoot"
	root.add_child(test_root)
	current_scene = test_root

	var packed_scene := load(HOE_CAT_SCENE_PATH) as PackedScene
	_expect(packed_scene != null, "Hoe Cat player scene must load.")
	if packed_scene == null:
		await _finish()
		return
	player = packed_scene.instantiate() as PlayerHoeCat
	_expect(player != null, "Hoe Cat scene root must use PlayerHoeCat.")
	if player == null:
		await _finish()
		return
	test_root.add_child(player)
	front_enemy = _spawn_test_enemy(Vector2(6.0, 0.0))
	var duplicate_collision_shape := CollisionShape2D.new()
	var duplicate_circle := CircleShape2D.new()
	duplicate_circle.radius = 0.6
	duplicate_collision_shape.position = Vector2(0.4, 0.0)
	duplicate_collision_shape.shape = duplicate_circle
	front_enemy.add_child(duplicate_collision_shape)
	back_enemy = _spawn_test_enemy(Vector2(-6.0, 0.0))
	second_front_enemy = _spawn_test_enemy(Vector2(4.0, 1.0))
	angle_boundary_enemy = _spawn_test_enemy(Vector2.RIGHT.rotated(deg_to_rad(30.0)) * 7.0)
	outside_angle_enemy = _spawn_test_enemy(Vector2.RIGHT.rotated(deg_to_rad(30.5)) * 7.0)
	negative_angle_boundary_enemy = _spawn_test_enemy(Vector2.RIGHT.rotated(deg_to_rad(-30.0)) * 7.0)
	negative_outside_angle_enemy = _spawn_test_enemy(Vector2.RIGHT.rotated(deg_to_rad(-30.5)) * 7.0)
	# The query radius is measured to the target collision shape, so a radius-1
	# target overlaps up to a centre distance of nine pixels.
	radius_boundary_enemy = _spawn_test_enemy(Vector2(8.95, 0.0))
	outside_radius_enemy = _spawn_test_enemy(Vector2(9.05, 0.0))
	for index in range(70):
		var angle := lerpf(-25.0, 25.0, float(index) / 69.0)
		var radius := 3.0 + float(index % 5) * 0.7
		dense_cone_enemies.append(
			_spawn_test_enemy(Vector2.RIGHT.rotated(deg_to_rad(angle)) * radius)
		)
	await process_frame
	await physics_frame
	_stop_audio_players(player)

	_test_starting_stats_and_attack_speed_contract()
	_test_projectile_only_pickup_is_rejected()
	_test_cardinal_attack_quantization()
	await _test_generic_collectible_hooks_for_both_characters()
	await _test_primary_cone_attack()
	_test_skill_purchase_and_upgrades()
	await _test_whirlwind_damage_and_heal()
	await _test_primary_attack_through_real_input()
	await _test_dynamic_skill_profile()

	await _finish()


func _test_starting_stats_and_attack_speed_contract() -> void:
	_expect(player.get_character_id() == &"hoe_cat", "Hoe Cat character id must be hoe_cat.")
	_expect(player.max_health == 80, "Hoe Cat must start with 80 maximum health.")
	_expect(player.attack_damage == 15, "Hoe Cat must start with 15 attack damage.")
	_expect(is_equal_approx(player.move_speed, 120.0), "Hoe Cat move speed must match Weishidaier at 120.")
	_expect(is_equal_approx(player.get_attack_speed(), 400.0), "Hoe Cat raw attack speed must be 400.")
	_expect(is_equal_approx(player.get_attacks_per_second(), 2.0), "400 Hoe Cat attack speed must equal 2 attacks per second.")
	_expect(is_equal_approx(float(player.call("_get_effective_fire_interval")), 0.5), "400 Hoe Cat attack speed must produce a 0.5 second interval.")
	player.collectible_attack_speed_bonus = 200.0
	_expect(is_equal_approx(player.get_attack_speed(), 600.0), "Hoe Cat attack speed bonus must raise the raw value to 600.")
	_expect(is_equal_approx(player.get_attacks_per_second(), 3.0), "600 Hoe Cat attack speed must equal 3 attacks per second.")
	_expect(is_equal_approx(float(player.call("_get_effective_fire_interval")), 1.0 / 3.0), "600 Hoe Cat attack speed must produce a one-third-second interval.")
	player.collectible_attack_speed_bonus = 0.0
	_expect(not player.uses_ammunition(), "Hoe Cat primary attack must not consume ammunition.")
	_expect(not player.supports_projectile_attack_patterns(), "Hoe Cat must reject projectile-only shot patterns.")
	_expect(player.uses_attack_interval_bar(), "Hoe Cat must expose the attack interval bar.")
	_expect(player.get_node_or_null("BasicSlashEffect") is AnimatedSprite2D, "Basic slash VFX must be prebuilt in the Hoe Cat scene.")
	_expect(player.get_node_or_null("WhirlwindRangeEffect") is AnimatedSprite2D, "Whirlwind range VFX must be prebuilt in the Hoe Cat scene.")
	_expect(player.get_node_or_null("WhirlwindBodyEffect") is AnimatedSprite2D, "Whirlwind body rotation must be prebuilt in the Hoe Cat scene.")
	_expect(player.get_node_or_null("BodySprite/HoeSprite") == null, "Hoe Cat body frames must include the hoe without a runtime-rotated HoeSprite.")
	_expect(player.get_node_or_null("ActionAnimationPlayer") == null, "The obsolete scale-only ActionAnimationPlayer must stay removed.")
	_expect(player.get_node_or_null("PrimaryImpactTimer") is Timer, "PrimaryImpactTimer must be prebuilt in the Hoe Cat scene.")
	_expect(player.get_node_or_null("WhirlwindImpactTimer") is Timer, "WhirlwindImpactTimer must be prebuilt in the Hoe Cat scene.")
	_expect(player.primary_impact_timer.one_shot, "PrimaryImpactTimer must be one-shot.")
	_expect(player.whirlwind_impact_timer.one_shot, "WhirlwindImpactTimer must be one-shot.")
	_expect(player.apply_pickup(RAPID_PICKUP), "Pure Rapid attack-speed pickup must apply to Hoe Cat.")
	_expect(is_equal_approx(float(player.call("_get_effective_fire_interval")), 0.25), "Rapid x2 must reduce Hoe Cat's 0.5-second interval to 0.25 seconds.")
	player.call("_update_pickup_effects", RAPID_PICKUP.duration + 0.1)
	_expect(is_equal_approx(float(player.call("_get_effective_fire_interval")), 0.5), "Hoe Cat attack interval must return to 0.5 seconds after Rapid expires.")
	player.current_ammo = 0
	_expect(not bool(player.call("_try_start_reload")), "Hoe Cat must reject reload even if its inherited ammo value is empty.")
	_expect(not player.is_reloading, "Hoe Cat must never enter the reload state.")


func _test_projectile_only_pickup_is_rejected() -> void:
	var applied := player.apply_pickup(SPIRAL_PICKUP)
	_expect(not applied, "Pure projectile spiral pickup must not apply to Hoe Cat.")
	_expect(
		player.current_shot_pattern == PickupConfig.ShotPattern.NORMAL,
		"Rejected projectile pickup must not change Hoe Cat shot pattern."
	)


func _test_cardinal_attack_quantization() -> void:
	var direction_cases := {
		Vector2(1.0, 0.75): Vector2.RIGHT,
		Vector2(-1.0, 0.75): Vector2.LEFT,
		Vector2(0.75, 1.0): Vector2.DOWN,
		Vector2(0.75, -1.0): Vector2.UP,
	}
	for requested_direction: Vector2 in direction_cases:
		var expected_direction := direction_cases[requested_direction] as Vector2
		var cardinal_direction := player.call(
			"_get_cardinal_attack_direction",
			requested_direction
		) as Vector2
		_expect(
			cardinal_direction == expected_direction,
			"Attack direction %s must quantize to %s."
			% [requested_direction, expected_direction]
		)


func _test_generic_collectible_hooks_for_both_characters() -> void:
	var run_state := root.get_node_or_null("RunState") as RunStateStore
	_expect(run_state != null, "RunState must exist for generic collectible hook coverage.")
	if run_state == null:
		return
	run_state.begin_new_run(&"hoe_cat")
	var hook_collectible := PickupConfig.new()
	hook_collectible.pickup_type = PickupConfig.PickupType.COLLECTIBLE
	hook_collectible.can_store_in_inventory = true
	hook_collectible.collectible_effect_id = "hoe_cat_generic_hook_smoke"
	hook_collectible.trigger_effect_id = PickupConfig.TRIGGER_SHOT_XIRANG
	hook_collectible.trigger_shot_interval = 1
	hook_collectible.trigger_xirang = 7
	hook_collectible.on_hit_effect_id = PickupConfig.HIT_EFFECT_XIRANG
	hook_collectible.on_hit_chance = 1.0
	hook_collectible.on_hit_xirang = 11
	hook_collectible.kill_effect_id = PickupConfig.KILL_EFFECT_XIRANG
	hook_collectible.kill_xirang = 13
	hook_collectible.bullet_pierce_chance = 1.0
	_expect(run_state.try_add_item(hook_collectible), "Synthetic generic-hook collectible must enter the test inventory.")

	player.current_xirang = 0
	player.notify_primary_attack_performed()
	_expect(player.current_xirang == 7, "Hoe Cat primary attack must trigger legacy shot-ID effects through the generic attack hook.")
	player.apply_collectible_attack_hit_effects(front_enemy, 15)
	_expect(player.current_xirang == 18, "Hoe Cat hit must trigger the generic attack-hit hook.")
	front_enemy.is_dead = true
	player.apply_collectible_attack_hit_effects(front_enemy, 15)
	front_enemy.is_dead = false
	_expect(player.current_xirang == 31, "Hoe Cat primary-attack kill must trigger the existing kill hook.")
	_expect(is_zero_approx(float(player.call("_get_inventory_bullet_pierce_chance"))), "Projectile piercing must remain silently inactive for Hoe Cat.")

	var weishidaier_scene := load("res://scene/player_weishidaier.tscn") as PackedScene
	var weishidaier := weishidaier_scene.instantiate() as Player if weishidaier_scene != null else null
	_expect(weishidaier != null, "Weishidaier must instantiate for shared generic-hook regression coverage.")
	if weishidaier == null:
		return
	test_root.add_child(weishidaier)
	await process_frame
	_stop_audio_players(weishidaier)
	weishidaier.current_xirang = 0
	weishidaier.notify_primary_attack_performed()
	_expect(weishidaier.current_xirang == 7, "Weishidaier must use the same generic primary-attack hook.")
	_expect(is_equal_approx(float(weishidaier.call("_get_inventory_bullet_pierce_chance")), 1.0), "Projectile piercing must remain active for Weishidaier.")
	weishidaier.queue_free()
	await process_frame


func _test_primary_cone_attack() -> void:
	player.shooting_timer.stop()
	var diagonal_request := Vector2.RIGHT.rotated(deg_to_rad(20.0))
	var attacked := player.try_authoritative_hoe_primary_attack(diagonal_request)
	_expect(attacked, "Hoe Cat primary attack must execute when its timer is ready.")
	_expect(
		player.last_attack_direction == Vector2.RIGHT,
		"A right-dominant diagonal primary request must quantize to the right cardinal direction."
	)
	_expect(player.body_sprite.animation == &"attack_right", "Quantized primary direction must drive the matching body animation.")
	_expect(is_zero_approx(player.basic_slash_effect.rotation), "Quantized primary direction must drive the matching slash rotation.")
	_expect(front_enemy.total_damage_taken == 0, "Primary damage must not resolve before the 0.1125-second impact timer.")
	_expect(second_front_enemy.total_damage_taken == 0, "Every target must remain undamaged during primary anticipation.")
	_expect(not player.primary_impact_timer.is_stopped(), "Primary attack must arm its impact timer.")
	_expect(
		player.primary_impact_timer.time_left > 0.0
		and player.primary_impact_timer.time_left <= 0.1125 + 0.001,
		"Primary impact timer must be scheduled for 0.1125 seconds."
	)
	_expect(
		player.get_primary_attack_cooldown_ratio() < 0.1,
		"Primary attack interval indicator must restart near zero when anticipation begins."
	)
	_expect(
		not player.try_authoritative_hoe_primary_attack(Vector2.RIGHT),
		"A pending primary impact must reject another swing."
	)
	await player.primary_impact_timer.timeout
	await process_frame
	_expect(player.primary_impact_timer.is_stopped(), "PrimaryImpactTimer must stop after its one-shot impact.")
	_expect(not bool(player.get("_pending_primary_attack")), "Primary pending state must clear at impact.")
	_expect(front_enemy.total_damage_taken == 15, "60-degree primary cone must deal 15 physical damage to the front target.")
	_expect(second_front_enemy.total_damage_taken == 15, "One swing must damage every distinct enemy inside the cone once.")
	_expect(back_enemy.total_damage_taken == 0, "60-degree primary cone must not hit a target behind the player.")
	_expect(angle_boundary_enemy.total_damage_taken == 15, "The +30-degree cone boundary must be included.")
	_expect(outside_angle_enemy.total_damage_taken == 0, "A target beyond +30 degrees must be excluded.")
	_expect(negative_angle_boundary_enemy.total_damage_taken == 15, "The -30-degree cone boundary must be included.")
	_expect(negative_outside_angle_enemy.total_damage_taken == 0, "A target beyond -30 degrees must be excluded.")
	_expect(radius_boundary_enemy.total_damage_taken == 15, "A collider touching the radius-8 query must be included.")
	_expect(outside_radius_enemy.total_damage_taken == 0, "A collider beyond the radius-8 query must be excluded.")
	_expect(
		dense_cone_enemies.all(func(enemy: TestEnemy) -> bool: return enemy.total_damage_taken == 15),
		"A dense cone with more than one physics-query batch must still hit every enemy exactly once."
	)
	_expect(
		test_root.get_children().filter(func(child: Node) -> bool: return child is Bullet).is_empty(),
		"Hoe Cat primary attack must not generate a Bullet node."
	)
	player.call("_update_character_combat_state", 1.0)


func _test_primary_attack_through_real_input() -> void:
	# Normal radius-8 enemy geometry can overlap the authored attack shape while
	# its centre is well beyond 8 px. Exercise input -> physics -> attack end to end.
	player.call("_finish_whirlwind_visual")
	var contact_enemy := _spawn_test_enemy(Vector2(15.6, 0.0), 8.0)
	var beyond_contact_enemy := _spawn_test_enemy(Vector2(18.0, 0.0), 8.0)
	await process_frame
	await physics_frame
	player.shooting_timer.stop()
	player.mouse_fire_held = false
	Input.action_press("shoot_right")
	await physics_frame
	await process_frame
	Input.action_release("shoot_right")
	_expect(
		contact_enemy.total_damage_taken == 0,
		"A real shoot-right input must not deal damage before its authored impact frame."
	)
	_expect(
		beyond_contact_enemy.total_damage_taken == 0,
		"The radius-8 query must not hit a normal enemy beyond shape-overlap range."
	)
	_expect(
		player.body_sprite.animation == &"attack_right" and player.body_sprite.is_playing(),
		"A real shoot-right input must start the directional body attack animation."
	)
	_expect(
		player.basic_slash_effect.visible
		and player.basic_slash_effect.animation == &"slash"
		and player.basic_slash_effect.is_playing(),
		"A real shoot-right input must start the basic slash effect."
	)
	player.call("_update_facing", Vector2.UP, Vector2.ZERO)
	player.call("_update_animation")
	_expect(
		player.body_sprite.animation == &"attack_right",
		"Movement input during a swing must not switch the authored attack direction mid-animation."
	)
	await player.primary_impact_timer.timeout
	await process_frame
	_expect(
		contact_enemy.total_damage_taken == 15,
		"A real shoot-right input must damage a normal radius-8 enemy when PrimaryImpactTimer expires."
	)
	_expect(
		beyond_contact_enemy.total_damage_taken == 0,
		"The delayed radius-8 impact must still exclude a normal enemy beyond shape-overlap range."
	)
	player.body_sprite.frame = 4
	player.body_sprite.stop()
	var completed_attack_frame := player.body_sprite.frame
	player.call("_update_animation")
	_expect(
		not player.body_sprite.is_playing()
		and player.body_sprite.frame == completed_attack_frame,
		"A completed non-looping attack must not restart while its visual lock is still active."
	)
	player.shooting_timer.stop()
	player.call("_update_character_combat_state", 1.0)
	player.call("_update_animation")
	contact_enemy.queue_free()
	beyond_contact_enemy.queue_free()
	await process_frame


func _test_skill_purchase_and_upgrades() -> void:
	player.current_xirang = 200
	_expect(player.try_purchase_skill1(200), "Hoe Cat whirlwind must be purchasable for 200 Xirang.")
	_expect(player.current_xirang == 0, "Whirlwind purchase must consume exactly 200 Xirang.")
	_expect(is_equal_approx(player.skill1_charge_duration, 18.0), "Whirlwind base charge duration must be 18 seconds.")
	var upgrade_costs := [500, 750, 1000, 2000]
	var expected_durations := [16.0, 14.0, 12.0, 10.0]
	for index in range(upgrade_costs.size()):
		player.current_xirang = upgrade_costs[index]
		_expect(player.get_skill1_upgrade_cost() == upgrade_costs[index], "Whirlwind upgrade cost must match the configured four-level sequence.")
		_expect(player.try_upgrade_skill1(), "Each of the four whirlwind upgrades must succeed with enough Xirang.")
		_expect(
			is_equal_approx(player.skill1_charge_duration, expected_durations[index]),
			"Whirlwind charge duration must progress through 16/14/12/10 seconds."
		)
	_expect(player.is_skill1_upgrade_maxed(), "Whirlwind must report maxed after four upgrades.")
	_expect(not player.try_upgrade_skill1_free(), "Whirlwind must reject a fifth upgrade, including a free one.")


func _test_whirlwind_damage_and_heal() -> void:
	player.skill1_charge = player.skill1_charge_duration
	player.current_health = 50
	var used_skill := player.try_authoritative_hoe_whirlwind()
	_expect(used_skill, "Fully charged Hoe Cat whirlwind must execute.")
	_expect(front_enemy.total_damage_taken == 15, "Whirlwind must not damage the front target before its 0.125-second impact.")
	_expect(back_enemy.total_damage_taken == 0, "Whirlwind must not damage the rear target during anticipation.")
	_expect(player.current_health == 50, "Whirlwind healing must wait for the authored impact frame.")
	_expect(is_equal_approx(player.skill1_charge, 0.0), "Whirlwind must consume all skill charge.")
	_expect(not player.controls_locked, "Whirlwind must keep movement controls available during its animation.")
	_expect(not player.whirlwind_impact_timer.is_stopped(), "Whirlwind must arm its impact timer.")
	_expect(
		player.whirlwind_impact_timer.time_left > 0.0
		and player.whirlwind_impact_timer.time_left <= 0.125 + 0.001,
		"Whirlwind impact timer must be scheduled for 0.125 seconds."
	)
	player.shooting_timer.stop()
	_expect(
		not player.try_authoritative_hoe_primary_attack(Vector2.RIGHT),
		"Whirlwind animation must block primary attacks for its 0.5-second duration."
	)
	player.skill1_charge = player.skill1_charge_duration
	_expect(
		not player.try_authoritative_hoe_whirlwind(),
		"Whirlwind animation must block another skill cast for its 0.5-second duration."
	)
	await player.whirlwind_impact_timer.timeout
	await process_frame
	_expect(player.whirlwind_impact_timer.is_stopped(), "WhirlwindImpactTimer must stop after its one-shot impact.")
	_expect(not bool(player.get("_pending_whirlwind_attack")), "Whirlwind pending state must clear at impact.")
	_expect(front_enemy.total_damage_taken == 57, "Whirlwind impact must add 42 physical damage to the front target.")
	_expect(back_enemy.total_damage_taken == 42, "Radius-15 whirlwind impact must hit the target behind the player for 42 damage.")
	_expect(player.current_health == 53, "Whirlwind impact must restore exactly 3 health.")
	player.call("_finish_whirlwind_visual")
	player.current_health = 79
	_expect(player.try_authoritative_hoe_whirlwind(), "Whirlwind must become usable again after its action lock ends.")
	_expect(player.current_health == 79, "The second whirlwind must also defer healing until impact.")
	await player.whirlwind_impact_timer.timeout
	await process_frame
	_expect(player.current_health == 80, "Whirlwind impact healing must not exceed maximum health.")
	player.call("_finish_whirlwind_visual")


func _test_dynamic_skill_profile() -> void:
	var panel_scene := load("res://scene/player_profile_panel.tscn") as PackedScene
	var profile_panel := panel_scene.instantiate() as PlayerProfilePanel if panel_scene != null else null
	_expect(profile_panel != null, "Player profile panel must instantiate for Hoe Cat presentation.")
	if profile_panel == null:
		return
	test_root.add_child(profile_panel)
	await process_frame
	profile_panel.bind_player(player)
	profile_panel.open()
	await process_frame
	_expect(profile_panel.skill_info.visible, "Unlocked Hoe Cat whirlwind must appear in the profile panel.")
	_expect(profile_panel.skill_name_label.text == "旋风斩", "Profile panel must use Hoe Cat's dynamic skill name.")
	_expect(
		profile_panel.skill_description_label.text.contains("280%"),
		"Profile panel must use Hoe Cat's dynamic whirlwind description."
	)
	_expect(
		profile_panel.skill_icon.texture != null
		and profile_panel.skill_icon.texture.resource_path == player.get_skill1_icon_path(),
		"Profile panel must use Hoe Cat's whirlwind icon."
	)
	_expect(
		profile_panel.portrait.texture != null
		and profile_panel.portrait.texture.resource_path
		== PlayerCharacterRegistry.get_config(&"hoe_cat").portrait_texture,
		"Profile panel must read Hoe Cat's portrait from the character config."
	)
	_expect(
		profile_panel.attack_speed_value.text.contains("400")
		and profile_panel.attack_speed_value.text.contains("2.00"),
		"Profile panel must show both 400 attack speed and 2.00 attacks per second."
	)
	var merchant_scene := load("res://scene/zhuangfangyi_merchant.tscn") as PackedScene
	var merchant := merchant_scene.instantiate() as ZhuangfangyiMerchant if merchant_scene != null else null
	_expect(merchant != null, "Skill merchant must instantiate for Hoe Cat presentation.")
	if merchant != null:
		player.apply_skill1_upgrade_state(0)
		var offer_lines := merchant.call("_build_dialogue_lines", player) as Array
		_expect(
			not offer_lines.is_empty()
			and str(offer_lines.back()).contains(player.get_skill1_icon_path())
			and str(offer_lines.back()).contains(player.get_skill1_display_name()),
			"Skill merchant offer must use Hoe Cat's dynamic whirlwind icon and name."
		)
		merchant.free()
	profile_panel.close()
	profile_panel.queue_free()
	await process_frame


func _spawn_test_enemy(spawn_position: Vector2, collision_radius: float = 1.0) -> TestEnemy:
	var enemy := TestEnemy.new()
	enemy.current_health = 1000
	enemy.collision_layer = 4
	enemy.collision_mask = 0
	var animated_sprite := AnimatedSprite2D.new()
	animated_sprite.name = "AnimatedSprite2D"
	enemy.add_child(animated_sprite)
	var speed_trail := Node2D.new()
	speed_trail.name = "MoveSpeedTrailEffect"
	enemy.add_child(speed_trail)
	var shape_node := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = collision_radius
	shape_node.shape = shape
	enemy.add_child(shape_node)
	var touch_area := Area2D.new()
	touch_area.name = "TouchDamageArea"
	enemy.add_child(touch_area)
	var hit_particles := GPUParticles2D.new()
	hit_particles.name = "HitParticles"
	enemy.add_child(hit_particles)
	var hit_audio := AudioStreamPlayer2D.new()
	hit_audio.name = "HitAudio"
	enemy.add_child(hit_audio)
	var death_audio := AudioStreamPlayer2D.new()
	death_audio.name = "DeathAudio"
	enemy.add_child(death_audio)
	test_root.add_child(enemy)
	enemy.position = spawn_position
	return enemy


func _finish() -> void:
	if test_root != null:
		_stop_audio_players(test_root)
		test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("PLAYER_HOE_CAT_COMBAT_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _stop_audio_players(node: Node) -> void:
	if node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D:
		node.call("stop")
	for child in node.get_children():
		_stop_audio_players(child)
