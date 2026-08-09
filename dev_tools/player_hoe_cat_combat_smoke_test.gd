extends SceneTree

const HOE_CAT_SCENE_PATH := "res://scene/player/hoe_cat/player_hoe_cat.tscn"
const SPIRAL_PICKUP := preload("res://resources/config/pickup_triggered_items/snow_wolf_pojun.tres")
const RAPID_PICKUP := preload("res://resources/config/pickup_triggered_items/rapid_magazine.tres")
const PICKUP_SCENE := preload("res://scene/combat/pickups/pickup.tscn")
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")
const PLAYER_TEST_RUNTIME := preload(
	"res://dev_tools/player_test_combat_runtime.gd"
)
const TEST_PRIMARY_DIRECTION := Vector2(0.9396926, 0.34202015)


class TestEnemy:
	extends Enemy

	var total_damage_taken: int = 0
	var last_requested_damage: int = 0
	var last_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL

	func _ready() -> void:
		pass

	func _physics_process(_delta: float) -> void:
		pass

	func _on_combat_damage_applied(result: DamageResult) -> void:
		# Observe the unified sink after Enemy has resolved and committed health;
		# the test double must not reconstruct mitigation or death independently.
		last_requested_damage = result.requested_amount
		last_damage_type = result.request.damage_type as EnemyConfig.DamageType
		total_damage_taken += result.applied_damage


var failures: Array[String] = []
var test_root: PlayerTestCombatRuntime = null
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
var whirlwind_radius_boundary_enemy: TestEnemy = null
var whirlwind_outside_radius_enemy: TestEnemy = null
var dense_cone_enemies: Array[TestEnemy] = []
var snow_wolf_pickup_consumed: bool = false
var snow_wolf_pickup_applied_immediately: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = PLAYER_TEST_RUNTIME.new() as PlayerTestCombatRuntime
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
	player.bind_combat_runtime(test_root)
	front_enemy = _spawn_test_enemy(TEST_PRIMARY_DIRECTION * 6.0)
	var duplicate_collision_shape := CollisionShape2D.new()
	var duplicate_circle := CircleShape2D.new()
	duplicate_circle.radius = 0.6
	duplicate_collision_shape.position = Vector2(0.4, 0.0)
	duplicate_collision_shape.shape = duplicate_circle
	front_enemy.add_child(duplicate_collision_shape)
	back_enemy = _spawn_test_enemy(-TEST_PRIMARY_DIRECTION * 6.0)
	second_front_enemy = _spawn_test_enemy(
		TEST_PRIMARY_DIRECTION.rotated(deg_to_rad(5.0)) * 4.2
	)
	# Exercise the 60-degree cone at the outer edge of the radius-48 reach.
	# Radius-1 targets at centre distance 48.5 still overlap the query shape.
	angle_boundary_enemy = _spawn_test_enemy(
		TEST_PRIMARY_DIRECTION.rotated(deg_to_rad(30.0)) * 48.5
	)
	outside_angle_enemy = _spawn_test_enemy(
		TEST_PRIMARY_DIRECTION.rotated(deg_to_rad(30.5)) * 48.5
	)
	negative_angle_boundary_enemy = _spawn_test_enemy(
		TEST_PRIMARY_DIRECTION.rotated(deg_to_rad(-30.0)) * 48.5
	)
	negative_outside_angle_enemy = _spawn_test_enemy(
		TEST_PRIMARY_DIRECTION.rotated(deg_to_rad(-30.5)) * 48.5
	)
	# The query radius is measured to the target collision shape, so a radius-1
	# target overlaps up to a centre distance of forty-nine pixels.
	radius_boundary_enemy = _spawn_test_enemy(TEST_PRIMARY_DIRECTION * 48.95)
	outside_radius_enemy = _spawn_test_enemy(TEST_PRIMARY_DIRECTION * 49.05)
	# The 360-degree skill uses a 62.4 radius. Radius-1 targets therefore
	# overlap until their centres reach 63.4 pixels, including behind the player.
	whirlwind_radius_boundary_enemy = _spawn_test_enemy(
		-TEST_PRIMARY_DIRECTION * 63.35
	)
	whirlwind_outside_radius_enemy = _spawn_test_enemy(
		-TEST_PRIMARY_DIRECTION * 63.45
	)
	for index in range(70):
		var angle := lerpf(-25.0, 25.0, float(index) / 69.0)
		var radius := 3.0 + float(index % 5) * 0.7
		dense_cone_enemies.append(
			_spawn_test_enemy(TEST_PRIMARY_DIRECTION.rotated(deg_to_rad(angle)) * radius)
		)
	await process_frame
	await physics_frame
	_stop_audio_players(player)

	_test_starting_stats_and_attack_speed_contract()
	await _test_attack_upgrade_progression()
	await _test_snow_wolf_sword_pickup()
	_test_snow_wolf_dense_contact_bookkeeping()
	_test_free_attack_direction_preservation()
	await _test_generic_collectible_hooks_for_both_characters()
	await _test_primary_cone_attack()
	_test_starting_skill_and_upgrades()
	await _test_whirlwind_interrupts_pending_primary_attack()
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
	_expect(player.get_node_or_null("ArmedEffectSprite") == null, "Hoe Cat must not carry Weishidaier's armed-effect placeholder.")
	_expect(player.get_node_or_null("AmmoBar") == null, "Hoe Cat must not carry a hidden ammunition bar.")
	var primary_audio := player.get_node_or_null(
		"PrimaryAttackAudio"
	) as AudioStreamPlayer2D
	var primary_audio_stream := (
		primary_audio.stream as AudioStreamWAV
		if primary_audio != null
		else null
	)
	_expect(primary_audio != null, "Hoe Cat primary audio must use a character-neutral node name.")
	_expect(
		primary_audio_stream != null
		and primary_audio_stream.resource_path
		== "res://resources/audio/hoe_cat_sword_slash_light.wav"
		and is_equal_approx(primary_audio_stream.get_length(), 0.25),
		"Hoe Cat must use its dedicated 0.25-second front-trimmed light sword cue."
	)
	_expect(player.get_node_or_null("Skill1Audio") is AudioStreamPlayer2D, "Hoe Cat skill audio must use a character-neutral node name.")
	_expect(
		player.basic_attack_query_shape != null
		and is_equal_approx(player.basic_attack_query_shape.radius, 48.0),
		"Hoe Cat primary attack query must use the authored radius of 48."
	)
	_expect(
		player.whirlwind_query_shape != null
		and is_equal_approx(player.whirlwind_query_shape.radius, 62.4)
		and is_equal_approx(
			player.whirlwind_query_shape.radius,
			player.basic_attack_query_shape.radius * 1.3
		),
		"Whirlwind query radius must be exactly 1.3 times the primary radius."
	)
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
	_expect(not bool(player.call("_try_start_reload")), "Hoe Cat must reject reload because it has no ammunition resource.")
	_expect(not player.get_multiplayer_is_reloading(), "Hoe Cat must never enter the reload state.")


func _test_attack_upgrade_progression() -> void:
	var packed_scene := load(HOE_CAT_SCENE_PATH) as PackedScene
	var upgrade_player := packed_scene.instantiate() as PlayerHoeCat
	_expect(upgrade_player != null, "Hoe Cat must instantiate for attack progression testing.")
	if upgrade_player == null:
		return
	test_root.add_child(upgrade_player)
	upgrade_player.bind_combat_runtime(test_root)
	await process_frame
	_stop_audio_players(upgrade_player)
	var expected_attack_damage := [21, 26, 32, 37, 43, 48, 54, 59, 65, 70]
	for upgrade_index in range(expected_attack_damage.size()):
		upgrade_player.upgrade_attack()
		_expect(
			upgrade_player.attack_damage == expected_attack_damage[upgrade_index],
			"Hoe Cat attack upgrade level %d must reach %d attack damage."
			% [upgrade_index + 1, expected_attack_damage[upgrade_index]]
		)
	_expect(
		upgrade_player.attack_damage == 70,
		"Ten Hoe Cat attack upgrades must raise attack damage from 15 to 70."
	)
	upgrade_player.queue_free()
	await process_frame


func _test_snow_wolf_sword_pickup() -> void:
	var orbit := player.get_node_or_null("SnowWolfSwordOrbit") as HoeCatSnowWolfSwordOrbit
	var visual_root := player.get_node_or_null("SnowWolfSwordOrbit/VisualRoot") as Node2D
	var sword_a := player.get_node_or_null(
		"SnowWolfSwordOrbit/VisualRoot/SwordA"
	) as Sprite2D
	var sword_b := player.get_node_or_null(
		"SnowWolfSwordOrbit/VisualRoot/SwordB"
	) as Sprite2D
	var sword_c := player.get_node_or_null(
		"SnowWolfSwordOrbit/VisualRoot/SwordC"
	) as Sprite2D
	var sword_d := player.get_node_or_null(
		"SnowWolfSwordOrbit/VisualRoot/SwordD"
	) as Sprite2D
	var shape_a_node := player.get_node_or_null(
		"SnowWolfSwordOrbit/SwordAShape"
	) as CollisionShape2D
	var shape_b_node := player.get_node_or_null(
		"SnowWolfSwordOrbit/SwordBShape"
	) as CollisionShape2D
	var shape_c_node := player.get_node_or_null(
		"SnowWolfSwordOrbit/SwordCShape"
	) as CollisionShape2D
	var shape_d_node := player.get_node_or_null(
		"SnowWolfSwordOrbit/SwordDShape"
	) as CollisionShape2D
	_expect(orbit != null, "Snow Wolf Po Jun orbit must be prebuilt in the Hoe Cat scene.")
	_expect(visual_root != null, "Snow Wolf Po Jun must use a separate visual root.")
	_expect(
		sword_a != null and sword_b != null and sword_c != null and sword_d != null,
		"Snow Wolf Po Jun must prebuild four sword sprites."
	)
	_expect(
		shape_a_node != null
		and shape_b_node != null
		and shape_c_node != null
		and shape_d_node != null,
		"Snow Wolf Po Jun must prebuild four sword collision shapes."
	)
	if (
		orbit == null
		or visual_root == null
		or sword_a == null
		or sword_b == null
		or sword_c == null
		or sword_d == null
		or shape_a_node == null
		or shape_b_node == null
		or shape_c_node == null
		or shape_d_node == null
	):
		return
	var shape_a := shape_a_node.shape as RectangleShape2D
	var shape_b := shape_b_node.shape as RectangleShape2D
	var shape_c := shape_c_node.shape as RectangleShape2D
	var shape_d := shape_d_node.shape as RectangleShape2D
	_expect(orbit.collision_layer == 0, "Orbit swords must not occupy a collision layer.")
	_expect(orbit.collision_mask == 4, "Orbit swords must only scan EnemyBody layer 4.")
	_expect(not orbit.monitorable, "Orbit swords must not be monitorable by other areas.")
	_expect(
		shape_a != null
		and shape_b != null
		and shape_c != null
		and shape_d != null
		and shape_a.size == Vector2(22.0, 6.0)
		and shape_b.size == Vector2(22.0, 6.0)
		and shape_c.size == Vector2(22.0, 6.0)
		and shape_d.size == Vector2(22.0, 6.0),
		"All four sword hitboxes must use the authored 22x6 footprint."
	)
	_expect(
		is_equal_approx(sword_a.position.length(), 72.0)
		and is_equal_approx(sword_b.position.length(), 72.0)
		and is_equal_approx(sword_c.position.length(), 72.0)
		and is_equal_approx(sword_d.position.length(), 72.0)
		and sword_a.position.is_equal_approx(Vector2(72.0, 0.0))
		and sword_c.position.is_equal_approx(Vector2(0.0, 72.0))
		and sword_b.position.is_equal_approx(Vector2(-72.0, 0.0))
		and sword_d.position.is_equal_approx(Vector2(0.0, -72.0)),
		"The four swords must sit 90 degrees apart on a radius-72 orbit."
	)
	_expect(
		is_equal_approx(sword_a.rotation, PI / 2.0)
		and is_equal_approx(sword_c.rotation, PI)
		and is_equal_approx(sword_b.rotation, -PI / 2.0)
		and is_equal_approx(sword_d.rotation, 0.0),
		"The four sword tips must follow the orbit tangent at 90-degree intervals."
	)
	_expect(
		sword_a.texture != null
		and sword_a.texture.get_size() == Vector2(24.0, 24.0)
		and sword_a.texture == sword_b.texture
		and sword_a.texture == sword_c.texture
		and sword_a.texture == sword_d.texture,
		"All four swords must reuse the same native 24x24 pixel texture."
	)
	_expect(
		sword_a.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and sword_b.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and sword_c.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and sword_d.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
		"Orbit sword textures must use nearest-neighbor sampling."
	)
	_expect(
		is_equal_approx(orbit.contact_damage_interval, 0.5)
		and orbit.contact_damage == 30
		and is_equal_approx(orbit.angular_speed, TAU * 2.0),
		"Orbit swords must deal base 30 damage every 0.5 seconds and complete two turns each second."
	)

	var ground_pickup := PICKUP_SCENE.instantiate() as Pickup
	_expect(ground_pickup != null, "Snow Wolf Po Jun ground pickup must instantiate.")
	if ground_pickup == null:
		return
	snow_wolf_pickup_consumed = false
	snow_wolf_pickup_applied_immediately = false
	ground_pickup.config = SPIRAL_PICKUP
	ground_pickup.consumed.connect(_on_snow_wolf_pickup_consumed)
	test_root.add_child(ground_pickup)
	await process_frame
	ground_pickup.call("_on_body_entered", player)
	_expect(snow_wolf_pickup_consumed, "Hoe Cat must consume Snow Wolf Po Jun from the ground.")
	_expect(
		snow_wolf_pickup_applied_immediately,
		"Snow Wolf Po Jun must apply immediately instead of falling through to inventory."
	)
	_expect(ground_pickup.is_queued_for_deletion(), "Consumed Snow Wolf Po Jun must leave the ground.")
	await process_frame
	await physics_frame
	_expect(orbit.is_active() and orbit.visible, "Snow Wolf Po Jun must reveal the four orbit swords.")
	_expect(orbit.monitoring, "Single-player orbit swords must enable authoritative collision.")
	_expect(
		not shape_a_node.disabled
		and not shape_b_node.disabled
		and not shape_c_node.disabled
		and not shape_d_node.disabled,
		"Authoritative orbit sword hitboxes must be enabled while the pickup is active."
	)
	_expect(
		absf(orbit.duration_left - SPIRAL_PICKUP.duration) <= 0.1,
		"Snow Wolf Po Jun must retain the authored five-second duration."
	)
	_expect(
		player.get_multiplayer_form_mode() == PickupConfig.PlayerFormMode.ARMED,
		"Active Hoe Cat orbit swords must reuse ARMED for multiplayer snapshots."
	)
	_expect(
		player.get_multiplayer_shot_pattern() == PickupConfig.ShotPattern.NORMAL,
		"Hoe Cat Snow Wolf Po Jun must not enable projectile spiral shots."
	)

	orbit.set_physics_process(false)
	orbit.rotation = 0.0
	await physics_frame
	var authored_contact_enemy := _spawn_authored_test_enemy(
		Vector2(0.0, 72.0),
		5
	)
	await physics_frame
	await process_frame
	var sword_overlaps := orbit.get_overlapping_bodies()
	_expect(
		sword_overlaps.has(authored_contact_enemy),
		(
			"The authored sword Area2D must physically overlap the authored Enemy scene "
			+ "at the added vertical sword's radius-72 center."
		)
	)
	_expect(
		authored_contact_enemy != null
		and authored_contact_enemy.current_health == 975
		and authored_contact_enemy.last_damage_taken == 25,
		"An authored enemy with five physical defense must take 25 from the sword's 30 damage."
	)

	var contact_enemy := _spawn_test_enemy(Vector2(180.0, 0.0))
	contact_enemy.add_physical_defense_modifier(1001, 5)
	var first_contact_elapsed := orbit.elapsed
	orbit.call("_on_body_entered", contact_enemy)
	_expect(
		contact_enemy.last_requested_damage == 30,
		"First sword contact must submit exactly 30 base damage."
	)
	_expect(
		contact_enemy.total_damage_taken == 25,
		"Thirty physical sword damage must become 25 against five physical defense."
	)
	_expect(
		contact_enemy.last_damage_type == EnemyConfig.DamageType.PHYSICAL,
		"Snow Wolf Po Jun sword damage must be physical."
	)
	var contact_enemy_id := contact_enemy.get_instance_id()
	var first_contact_deadline := float(
		orbit.enemy_next_damage_times.get(contact_enemy_id, -1.0)
	)
	var elapsed_before_refresh := orbit.elapsed
	orbit.activate(SPIRAL_PICKUP.duration, true)
	_expect(
		is_equal_approx(orbit.elapsed, elapsed_before_refresh)
		and orbit.overlapping_enemies.has(contact_enemy_id)
		and is_equal_approx(
			float(orbit.enemy_next_damage_times.get(contact_enemy_id, -1.0)),
			first_contact_deadline
		)
		and contact_enemy.total_damage_taken == 25,
		"Refreshing active swords must preserve orbit phase, contact tracking, and cooldown."
	)
	var second_contact_enemy := _spawn_test_enemy(Vector2(-180.0, 0.0))
	orbit.call("_on_body_entered", second_contact_enemy)
	_expect(
		second_contact_enemy.total_damage_taken == 30,
		"Per-enemy cooldowns must allow two enemies to take damage in the same frame."
	)
	orbit.call("_on_body_exited", contact_enemy)
	orbit.call("_on_body_entered", contact_enemy)
	_expect(
		contact_enemy.total_damage_taken == 25,
		"Leaving and immediately re-entering must not bypass the 0.5-second cooldown."
	)
	orbit.elapsed = first_contact_elapsed + 0.49
	orbit.call("_try_damage_enemy", contact_enemy)
	_expect(contact_enemy.total_damage_taken == 25, "A contact must not tick again at 0.49 seconds.")
	orbit.elapsed = first_contact_elapsed + 0.5
	orbit.call("_try_damage_enemy", contact_enemy)
	_expect(contact_enemy.total_damage_taken == 50, "A sustained contact must tick again at 0.5 seconds.")
	orbit.call("_on_body_exited", contact_enemy)
	orbit.elapsed = first_contact_elapsed + 1.0
	orbit.call("_prune_expired_damage_cooldowns")
	_expect(
		not orbit.enemy_next_damage_times.has(contact_enemy_id)
		and not orbit.detached_cooldown_enemy_ids.has(contact_enemy_id),
		"An exited enemy's cooldown bookkeeping must be reclaimed after it expires."
	)

	player.call("_set_character_visual_offset", Vector2(4.0, -3.0))
	_expect(
		visual_root.position == Vector2(4.0, -3.0)
		and orbit.position == Vector2.ZERO,
		"Multiplayer visual smoothing must offset only sword sprites, not authoritative hitboxes."
	)
	player.call("_set_character_visual_offset", Vector2.ZERO)

	orbit.duration_left = 0.1
	orbit.call("_physics_process", 0.11)
	await process_frame
	_expect(not orbit.is_active() and not orbit.visible, "Orbit swords must disappear when the pickup expires.")
	_expect(not orbit.monitoring, "Expired orbit swords must stop collision monitoring.")
	_expect(
		shape_a_node.disabled
		and shape_b_node.disabled
		and shape_c_node.disabled
		and shape_d_node.disabled,
		"Expired orbit sword shapes must leave the physics broad phase."
	)
	_expect(
		player.get_multiplayer_form_mode() == PickupConfig.PlayerFormMode.NORMAL,
		"Expired Hoe Cat orbit swords must restore the normal multiplayer form."
	)
	player.call(
		"_apply_multiplayer_character_realtime_state",
		PickupConfig.PlayerFormMode.ARMED,
		PickupConfig.ShotPattern.NORMAL,
		-1,
		-1,
		false,
		0.0
	)
	await process_frame
	_expect(
		orbit.is_active() and orbit.visible and not orbit.monitoring,
		"A remote ARMED/NORMAL snapshot must restore visual-only orbit swords."
	)
	_expect(
		shape_a_node.disabled
		and shape_b_node.disabled
		and shape_c_node.disabled
		and shape_d_node.disabled,
		"Remote visual-only orbit swords must keep all four physics shapes disabled."
	)
	var damage_before_visual_only_contact := contact_enemy.total_damage_taken
	orbit.call("_on_body_entered", contact_enemy)
	_expect(
		contact_enemy.total_damage_taken == damage_before_visual_only_contact,
		"Remote visual-only orbit swords must never submit enemy damage."
	)
	player.call(
		"_apply_multiplayer_character_realtime_state",
		PickupConfig.PlayerFormMode.NORMAL,
		PickupConfig.ShotPattern.NORMAL,
		-1,
		-1,
		false,
		0.0
	)
	_expect(
		not orbit.is_active() and not orbit.visible,
		"A remote NORMAL snapshot must remove the orbit sword presentation."
	)
	if authored_contact_enemy != null:
		authored_contact_enemy.queue_free()
	contact_enemy.queue_free()
	second_contact_enemy.queue_free()
	await process_frame


func _on_snow_wolf_pickup_consumed(
	_pickup: Pickup,
	_collector_peer_id: int,
	applied_immediately: bool
) -> void:
	snow_wolf_pickup_consumed = true
	snow_wolf_pickup_applied_immediately = applied_immediately


func _test_snow_wolf_dense_contact_bookkeeping() -> void:
	var orbit := player.get_node(
		"SnowWolfSwordOrbit"
	) as HoeCatSnowWolfSwordOrbit
	var dense_contacts: Array[TestEnemy] = []
	orbit.deactivate()
	orbit.elapsed = 0.0
	for index in range(300):
		var enemy := TestEnemy.new()
		enemy.current_health = 1000
		dense_contacts.append(enemy)
		var enemy_id := enemy.get_instance_id()
		orbit.overlapping_enemies[enemy_id] = enemy
		orbit.enemy_next_damage_times[enemy_id] = 1000.0
	var benchmark_started_usec := Time.get_ticks_usec()
	for _frame in range(600):
		orbit.elapsed += 1.0 / 60.0
		orbit.call("_update_overlapping_enemy_damage")
		orbit.call("_prune_expired_damage_cooldowns")
	var benchmark_elapsed_usec := maxi(
		Time.get_ticks_usec() - benchmark_started_usec,
		0
	)
	_expect(
		orbit.overlapping_enemies.size() == 300
		and orbit.enemy_next_damage_times.size() == 300
		and orbit.detached_cooldown_enemy_ids.is_empty(),
		"Dense sword bookkeeping must retain 300 live contacts without false pruning."
	)
	print(
		"SNOW_WOLF_SWORD_DENSE_BOOKKEEPING_300_AVG_USEC=%.2f"
		% (float(benchmark_elapsed_usec) / 600.0)
	)
	for enemy in dense_contacts:
		enemy.is_dead = true
	orbit.call("_update_overlapping_enemy_damage")
	_expect(
		orbit.overlapping_enemies.is_empty()
		and orbit.enemy_next_damage_times.is_empty()
		and orbit.detached_cooldown_enemy_ids.is_empty(),
		"Dead dense contacts must be reclaimed without retaining cooldown entries."
	)
	for enemy in dense_contacts:
		enemy.free()


func _test_free_attack_direction_preservation() -> void:
	var direction_cases: Array[Vector2] = [
		Vector2(1.0, 0.75),
		Vector2(-1.0, 0.75),
		Vector2(0.75, 1.0),
		Vector2(0.75, -1.0),
	]
	for requested_direction in direction_cases:
		var expected_direction := requested_direction.normalized()
		var safe_direction := player.call(
			"_get_safe_attack_direction",
			requested_direction
		) as Vector2
		_expect(
			safe_direction.is_equal_approx(expected_direction),
			"Attack direction %s must preserve its normalized free-aim vector %s."
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

	var weishidaier_scene := load("res://scene/player/weishidaier/player_weishidaier.tscn") as PackedScene
	var weishidaier := weishidaier_scene.instantiate() as Player if weishidaier_scene != null else null
	_expect(weishidaier != null, "Weishidaier must instantiate for shared generic-hook regression coverage.")
	if weishidaier == null:
		return
	test_root.add_child(weishidaier)
	weishidaier.bind_combat_runtime(test_root)
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
	var diagonal_request := TEST_PRIMARY_DIRECTION
	var attacked := player.try_authoritative_hoe_primary_attack(diagonal_request)
	_expect(attacked, "Hoe Cat primary attack must execute when its timer is ready.")
	_expect(
		player.primary_attack_audio.playing,
		"Hoe Cat light sword cue must begin with the swing instead of waiting for impact."
	)
	_expect(
		player.last_attack_direction.is_equal_approx(diagonal_request),
		"A diagonal primary request must remain the exact free-aim attack axis."
	)
	_expect(player.body_sprite.animation == &"attack_right", "Free aim must retain the nearest matching body animation row.")
	_expect(
		is_equal_approx(player.basic_slash_effect.rotation, deg_to_rad(20.0)),
		"Slash VFX must rotate to the exact 20-degree attack axis."
	)
	_expect(
		(player.get("_pending_primary_direction") as Vector2).is_equal_approx(diagonal_request),
		"Delayed damage must preserve the same exact 20-degree attack axis."
	)
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
	_expect(angle_boundary_enemy.total_damage_taken == 15, "The +30-degree cone boundary must be included at radius 48.")
	_expect(outside_angle_enemy.total_damage_taken == 0, "A target beyond +30 degrees must be excluded even inside the radius-48 query.")
	_expect(negative_angle_boundary_enemy.total_damage_taken == 15, "The -30-degree cone boundary must be included at radius 48.")
	_expect(negative_outside_angle_enemy.total_damage_taken == 0, "A target beyond -30 degrees must be excluded even inside the radius-48 query.")
	_expect(radius_boundary_enemy.total_damage_taken == 15, "A collider touching the radius-48 query must be included.")
	_expect(outside_radius_enemy.total_damage_taken == 0, "A collider beyond the radius-48 query must be excluded.")
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
	# Normal radius-8 enemy geometry can overlap the authored radius-48 attack
	# shape while its centre is well beyond 48 px. Exercise input -> physics ->
	# attack end to end at the expanded boundary.
	player.call("_finish_whirlwind_visual")
	var input_direction := Vector2.ONE.normalized()
	var contact_enemy := _spawn_test_enemy(input_direction * 55.6, 8.0)
	var beyond_contact_enemy := _spawn_test_enemy(input_direction * 56.4, 8.0)
	await process_frame
	await physics_frame
	player.shooting_timer.stop()
	player.mouse_fire_held = false
	Input.action_press("shoot_right")
	Input.action_press("shoot_down")
	await physics_frame
	await process_frame
	Input.action_release("shoot_right")
	Input.action_release("shoot_down")
	_expect(
		contact_enemy.total_damage_taken == 0,
		"A real diagonal input must not deal damage before its authored impact frame."
	)
	_expect(
		beyond_contact_enemy.total_damage_taken == 0,
		"The radius-48 query must not hit a normal enemy beyond shape-overlap range."
	)
	_expect(
		player.body_sprite.animation == &"attack_right" and player.body_sprite.is_playing(),
		"A 45-degree input must select the nearest directional body attack animation."
	)
	_expect(
		player.last_attack_direction.is_equal_approx(input_direction)
		and is_equal_approx(player.basic_slash_effect.rotation, PI * 0.25),
		"Real diagonal input must preserve a 45-degree damage axis and VFX rotation."
	)
	_expect(
		player.basic_slash_effect.visible
		and player.basic_slash_effect.animation == &"slash"
		and player.basic_slash_effect.is_playing(),
		"A real diagonal input must start the freely rotated basic slash effect."
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
		"A real diagonal input must damage a normal radius-8 enemy at the radius-48 boundary when PrimaryImpactTimer expires."
	)
	_expect(
		beyond_contact_enemy.total_damage_taken == 0,
		"The delayed radius-48 impact must still exclude a normal enemy beyond shape-overlap range."
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


func _test_starting_skill_and_upgrades() -> void:
	_expect(player.has_skill1(), "Hoe Cat must start with whirlwind unlocked.")
	_expect(is_equal_approx(player.skill1_charge_duration, 16.0), "Whirlwind base charge duration must be 16 seconds.")
	var upgrade_costs := [200, 500, 1000, 5000, 10000, 20000]
	var expected_durations := [14.0, 12.0, 10.0, 8.0, 6.0, 4.0]
	for index in range(upgrade_costs.size()):
		player.current_xirang = upgrade_costs[index]
		_expect(player.get_skill1_upgrade_cost() == upgrade_costs[index], "Whirlwind upgrade cost must match the configured six-level sequence.")
		_expect(player.try_upgrade_skill1(), "Each of the six whirlwind upgrades must succeed with enough Xirang.")
		_expect(
			is_equal_approx(player.skill1_charge_duration, expected_durations[index]),
			"Whirlwind charge duration must progress through 14/12/10/8/6/4 seconds."
		)
	_expect(player.is_skill1_upgrade_maxed(), "Whirlwind must report maxed after six upgrades.")
	_expect(not player.try_upgrade_skill1_free(), "Whirlwind must reject a seventh upgrade, including a free one.")


func _test_whirlwind_interrupts_pending_primary_attack() -> void:
	var packed_scene := load(HOE_CAT_SCENE_PATH) as PackedScene
	var interrupt_player := packed_scene.instantiate() as PlayerHoeCat if packed_scene != null else null
	_expect(interrupt_player != null, "Hoe Cat must instantiate for primary-to-skill priority coverage.")
	if interrupt_player == null:
		return
	interrupt_player.position = Vector2(500.0, 0.0)
	test_root.add_child(interrupt_player)
	interrupt_player.bind_combat_runtime(test_root)
	var interrupt_target := _spawn_test_enemy(interrupt_player.position + Vector2.RIGHT * 6.0)
	await process_frame
	await physics_frame
	_stop_audio_players(interrupt_player)
	interrupt_player.unlock_skill1()
	interrupt_player.skill1_charge = interrupt_player.skill1_charge_duration
	interrupt_player.shooting_timer.stop()
	_expect(
		interrupt_player.try_authoritative_hoe_primary_attack(Vector2.RIGHT),
		"Hoe Cat must begin a primary swing before skill-priority coverage."
	)
	_expect(
		bool(interrupt_player.get("_pending_primary_attack"))
		and not interrupt_player.primary_impact_timer.is_stopped(),
		"A primary swing must hold its damage until the authored impact timer."
	)
	_expect(
		bool(interrupt_player.call("_try_use_skill1")),
		"A fully charged whirlwind must interrupt an in-progress primary swing."
	)
	_expect(
		not bool(interrupt_player.get("_pending_primary_attack"))
		and interrupt_player.primary_impact_timer.is_stopped()
		and int(interrupt_player.get("_pending_primary_damage")) == 0,
		"Whirlwind priority must cancel the pending primary payload and impact timer."
	)
	_expect(
		is_zero_approx(float(interrupt_player.get("_primary_visual_time_left")))
		and not interrupt_player.basic_slash_effect.visible
		and float(interrupt_player.get("_whirlwind_visual_time_left")) > 0.0,
		"Whirlwind priority must replace the primary presentation immediately."
	)
	interrupt_player.call("_on_primary_impact_timer_timeout")
	_expect(
		interrupt_target.total_damage_taken == 0,
		"A canceled primary timeout must not apply damage after whirlwind takes priority."
	)
	await interrupt_player.whirlwind_impact_timer.timeout
	await process_frame
	_expect(
		interrupt_target.total_damage_taken == 45,
		"Only the prioritized whirlwind impact may damage the interrupted swing target."
	)
	interrupt_player.call("_finish_whirlwind_visual")
	interrupt_player.queue_free()
	interrupt_target.queue_free()
	await process_frame


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
	_expect(front_enemy.total_damage_taken == 60, "Whirlwind impact must add 45 physical damage to the front target.")
	_expect(back_enemy.total_damage_taken == 45, "Radius-62.4 whirlwind impact must hit the target behind the player for 45 damage.")
	_expect(
		whirlwind_radius_boundary_enemy.total_damage_taken == 45,
		"Whirlwind must hit a radius-1 target whose centre is 63.35 pixels away."
	)
	_expect(
		whirlwind_outside_radius_enemy.total_damage_taken == 0,
		"Whirlwind must reject a radius-1 target whose centre is 63.45 pixels away."
	)
	_expect(player.current_health == 55, "Whirlwind impact must restore exactly 5 health.")
	player.call("_finish_whirlwind_visual")
	player.current_health = 79
	_expect(player.try_authoritative_hoe_whirlwind(), "Whirlwind must become usable again after its action lock ends.")
	_expect(player.current_health == 79, "The second whirlwind must also defer healing until impact.")
	await player.whirlwind_impact_timer.timeout
	await process_frame
	_expect(player.current_health == 80, "Whirlwind impact healing must not exceed maximum health.")
	player.call("_finish_whirlwind_visual")


func _test_dynamic_skill_profile() -> void:
	var panel_scene := load(
		"res://scene/game_modes/standard/ui/standard_player_profile_panel.tscn"
	) as PackedScene
	var profile_panel := (
		panel_scene.instantiate() as StandardPlayerProfilePanel
		if panel_scene != null
		else null
	)
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
		profile_panel.skill_description_label.text.contains("半径62.4")
		and profile_panel.skill_description_label.text.contains("300%")
		and profile_panel.skill_description_label.text.contains("5点"),
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
		profile_panel.attack_speed_value.text == "400",
		"Profile panel must show only the 400 attack-speed value."
	)
	var merchant_scene := load("res://scene/merchants/zhuangfangyi/zhuangfangyi_merchant.tscn") as PackedScene
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


func _spawn_authored_test_enemy(
	spawn_position: Vector2,
	physical_defense: int
) -> Enemy:
	var enemy := ENEMY_SCENE.instantiate() as Enemy
	_expect(enemy != null, "The authored base Enemy scene must instantiate.")
	if enemy == null:
		return null
	var enemy_config := EnemyConfig.new()
	enemy_config.max_health = 1000
	enemy_config.attack_damage = 0
	enemy_config.physical_defense = physical_defense
	enemy_config.magic_defense = 0
	enemy_config.move_speed = 0.0
	enemy_config.xirang_kill_reward = 0
	enemy_config.drop_table = null
	enemy.config = enemy_config
	enemy.position = spawn_position
	test_root.add_child(enemy)
	enemy.set_process(false)
	enemy.set_physics_process(false)
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
