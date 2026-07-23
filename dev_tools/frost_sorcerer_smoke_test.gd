extends SceneTree

const FROST_SORCERER_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer.tscn"
)
const FIRE_SORCERER_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer.tscn"
)
const ICE_SPIKE_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.tscn"
)
const FROST_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const FIRE_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)

const TEST_HEALTH := 1000
const CHARACTER_FRAME_SIZE := Vector2(40.0, 40.0)
const ICE_SPIKE_FRAME_SIZE := Vector2(32.0, 32.0)
const EXPECTED_PROJECTILE_MASK := 1 | 2 | 512

var failures: Array[String] = []
var fixture: Node2D = null
var cold_scheduler: Node = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "FrostSorcererSmokeTest"
	root.add_child(fixture)
	current_scene = fixture
	cold_scheduler = root.get_node("ColdStatusScheduler")
	cold_scheduler.call("clear_all")
	cold_scheduler.set_physics_process(false)

	_test_resource_animation_and_node_contracts()
	await _test_one_projectile_attack_generation()
	await _test_straight_one_hundred_pixels_per_second()
	await _test_compensated_shape_sweep_graze()
	await _test_native_area_contact_on_ordinary_steps()
	await _test_player_magic_damage_cold_and_first_contact()
	await _test_building_magic_damage_without_cold()
	await _test_pool_reuse_resets_all_lease_state()

	cold_scheduler.call("clear_all")
	cold_scheduler.set_physics_process(false)
	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("FROST_SORCERER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_animation_and_node_contracts() -> void:
	_expect(
		FROST_SORCERER_CONFIG is FrostSorcererConfig,
		"Frost Sorcerer must use FrostSorcererConfig."
	)
	_expect(
		FROST_SORCERER_CONFIG.display_name == "寒冰术士"
		and FROST_SORCERER_CONFIG.enemy_scene == FROST_SORCERER_SCENE
		and FROST_SORCERER_CONFIG.ice_spike_scene == ICE_SPIKE_SCENE,
		"Frost Sorcerer config must own its authored enemy and ice-spike scenes."
	)
	_expect(
		FROST_SORCERER_CONFIG.attack_damage == 50
		and FIRE_SORCERER_CONFIG.attack_damage == 40
		and FROST_SORCERER_CONFIG.attack_damage
			> FIRE_SORCERER_CONFIG.attack_damage,
		"Frost Sorcerer damage must be 50, explicitly above Fire Sorcerer's 40."
	)
	_expect(
		is_equal_approx(FROST_SORCERER_CONFIG.projectile_speed, 100.0)
		and is_equal_approx(FROST_SORCERER_CONFIG.projectile_lifetime, 7.0),
		"The authored ice spike must travel at 100 px/s for at most seven seconds."
	)

	var enemy := FROST_SORCERER_SCENE.instantiate() as FrostSorcerer
	var fire_enemy := FIRE_SORCERER_SCENE.instantiate() as Node2D
	_expect(enemy != null, "Frost Sorcerer scene must instantiate FrostSorcerer.")
	_expect(fire_enemy != null, "Fire Sorcerer reference scene must instantiate.")
	if enemy != null:
		var sprite := enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		var pivot := enemy.get_node_or_null("SummonPivot") as Node2D
		var marker := enemy.get_node_or_null("SummonPivot/Spawn") as Marker2D
		var preview := (
			enemy.get_node_or_null("SummonPivot/IceSpikePreview")
			as AnimatedSprite2D
		)
		var summon_player := (
			enemy.get_node_or_null("SummonAnimationPlayer")
			as AnimationPlayer
		)
		_expect(
			sprite != null
			and pivot != null
			and marker != null
			and preview != null
			and summon_player != null,
			"Frost scene must author its sprite, one spawn marker, preview, and AnimationPlayer."
		)
		if sprite != null:
			_expect_animation_contract(
				sprite.sprite_frames,
				[&"move", &"windup", &"attack", &"death"],
				CHARACTER_FRAME_SIZE,
				"Frost Sorcerer"
			)
		if fire_enemy != null:
			_expect_same_visual_node_contract(enemy, fire_enemy)
			var fire_sprite := (
				fire_enemy.get_node_or_null("AnimatedSprite2D")
				as AnimatedSprite2D
			)
			if sprite != null and fire_sprite != null:
				_expect_same_character_alpha_bounds(
					sprite.sprite_frames,
					fire_sprite.sprite_frames
				)
		if preview != null:
			_expect_animation_contract(
				preview.sprite_frames,
				[&"spawn", &"fly", &"impact", &"expire"],
				ICE_SPIKE_FRAME_SIZE,
				"Ice-spike preview"
			)
			_expect(
				not preview.visible and preview.scale.length() < 0.001,
				"The authored summon preview must start hidden at zero scale."
			)
		if marker != null and preview != null:
			_expect(
				marker.position == preview.position,
				"The single preview and real projectile must share one spawn offset."
			)
		if pivot != null:
			var marker_count := 0
			for child in pivot.get_children():
				if child is Marker2D:
					marker_count += 1
			_expect(
				marker_count == 1,
				"Frost Sorcerer must author exactly one ice-spike spawn marker."
			)
		if summon_player != null:
			var summon_animation := summon_player.get_animation(&"summon")
			_expect(
				summon_animation != null
				and is_equal_approx(
					summon_animation.length,
					FROST_SORCERER_CONFIG.summon_duration
				),
				"Summon AnimationPlayer duration must match the 0.6 s config windup."
			)
		enemy.free()
	if fire_enemy != null:
		fire_enemy.free()

	var spike := ICE_SPIKE_SCENE.instantiate() as FrostSorcererIceSpike
	_expect(spike != null, "Ice-spike scene must instantiate FrostSorcererIceSpike.")
	if spike != null:
		var spike_sprite := spike.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		var spike_shape := spike.get_node_or_null("CollisionShape2D") as CollisionShape2D
		_expect(
			spike.z_index == 3
			and spike.collision_layer == 128
			and spike.collision_mask == EXPECTED_PROJECTILE_MASK
			and spike.is_in_group(&"runtime_projectiles"),
			"Ice spike must use the enemy-projectile layer, exact target mask, z=3, and telemetry group."
		)
		_expect(
			spike_sprite != null
			and spike_shape != null
			and spike_shape.shape is CapsuleShape2D,
			"Ice spike must author one sprite and one compact capsule collision shape."
		)
		if spike_sprite != null:
			_expect_animation_contract(
				spike_sprite.sprite_frames,
				[&"spawn", &"fly", &"impact", &"expire"],
				ICE_SPIKE_FRAME_SIZE,
				"Ice spike"
			)
		spike.free()

	var projectile_source := FileAccess.get_file_as_string(
		"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.gd"
	)
	_expect(
		not projectile_source.is_empty()
		and projectile_source.contains("motion_sweep.cast")
		and not projectile_source.contains("homing_turn_rate")
		and not projectile_source.contains("_update_homing")
		and not projectile_source.contains("initial_target")
		and not projectile_source.contains("intersect_shape"),
		"Ice-spike source must remain straight and single-target, without homing or AOE queries."
	)


func _test_one_projectile_attack_generation() -> void:
	var player := _spawn_player(Vector2(240.0, 0.0))
	player.collision_layer = 0
	player.collision_mask = 0
	var enemy := FROST_SORCERER_SCENE.instantiate() as FrostSorcerer
	fixture.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(FROST_SORCERER_CONFIG, player, null)
	enemy.set_physics_process(false)
	enemy.initial_attack_stagger_left = 0.0

	var spikes_before := _collect_fixture_spikes().size()
	_expect(
		bool(enemy.call(
			"_try_start_summon",
			player,
			FROST_SORCERER_CONFIG
		)),
		"An unobstructed in-range target must start the Frost summon windup."
	)
	_expect(
		enemy.combat_state == FrostSorcerer.CombatState.SUMMON
		and enemy.summon_preview.visible,
		"Windup must expose the single authored ice-spike preview."
	)
	enemy.call(
		"_update_summon",
		FROST_SORCERER_CONFIG.summon_duration + 0.01
	)
	var spikes := _collect_fixture_spikes()
	_expect(
		spikes.size() == spikes_before + 1,
		"Completing one windup must generate exactly one ice spike."
	)
	if spikes.size() > spikes_before:
		var spawned: FrostSorcererIceSpike = spikes.back()
		spawned.set_physics_process(false)
		_expect(
			spawned.global_position.is_equal_approx(
				enemy.summon_marker.global_position
			)
			and spawned.direction.is_equal_approx(Vector2.RIGHT)
			and spawned.damage == 50
			and is_equal_approx(spawned.speed, 100.0),
			"The one real spike must replace its preview at the marker with configured values."
		)
		spawned.queue_free()
	_expect(
		not enemy.summon_preview.visible
		and enemy.combat_state == FrostSorcerer.CombatState.CHASE
		and is_equal_approx(
			enemy.attack_cooldown_left,
			FROST_SORCERER_CONFIG.attack_interval
		),
		"Real generation must hide the preview and start the post-shot cooldown."
	)

	enemy.queue_free()
	player.queue_free()
	await process_frame


func _test_straight_one_hundred_pixels_per_second() -> void:
	var spike := ICE_SPIKE_SCENE.instantiate() as FrostSorcererIceSpike
	fixture.add_child(spike)
	spike.global_position = Vector2(5000.0, 5000.0)
	spike.setup(Vector2.RIGHT, 20, 100.0, 7.0)
	spike.set_physics_process(false)
	var initial_direction := spike.direction
	var initial_rotation := spike.rotation
	spike.call("_advance_motion", 1.0 / 60.0)
	_expect(
		spike.global_position.is_equal_approx(
			Vector2(5000.0 + 100.0 / 60.0, 5000.0)
		)
		and spike.motion_sweep_query_count == 0,
		"An ordinary 60 Hz step must rely on native Area2D overlap sampling without a redundant ray query."
	)
	spike.call("_advance_motion", 59.0 / 60.0)
	_expect(
		spike.global_position.is_equal_approx(Vector2(5100.0, 5000.0))
		and is_equal_approx(spike.remaining_lifetime, 6.0)
		and spike.motion_sweep_query_count == 1,
		"One clear second must move exactly 100 pixels, with a sweep reserved for the artificial long step."
	)
	_expect(
		spike.direction == initial_direction
		and is_equal_approx(spike.rotation, initial_rotation),
		"The ice spike must not turn or reacquire a target during flight."
	)
	var queries_before_compensation := spike.motion_sweep_query_count
	spike.simulate_compensated_motion(1.0 / 60.0)
	_expect(
		spike.motion_sweep_query_count == queries_before_compensation + 1
		and spike.global_position.is_equal_approx(
			Vector2(5100.0 + 100.0 / 60.0, 5000.0)
		),
		"Network catch-up motion must retain an explicit sweep even for one short compensation step."
	)
	spike.queue_free()
	await process_frame


func _test_compensated_shape_sweep_graze() -> void:
	var start := Vector2(7000.0, 7000.0)
	var graze_body := _spawn_static_body(
		start + Vector2(20.0, 3.5),
		Vector2(2.0, 2.0),
		1
	)
	var spike := ICE_SPIKE_SCENE.instantiate() as FrostSorcererIceSpike
	fixture.add_child(spike)
	spike.global_position = start
	spike.setup(Vector2.RIGHT, 20, 100.0, 7.0)
	spike.set_physics_process(false)
	await physics_frame
	var center_ray := PhysicsRayQueryParameters2D.create(
		start,
		start + Vector2(25.0, 0.0),
		1
	)
	var ray_missed := fixture.get_world_2d().direct_space_state.intersect_ray(
		center_ray
	).is_empty()
	spike.simulate_compensated_motion(0.25)
	_expect(
		ray_missed
		and spike.has_hit
		and spike.global_position.x < start.x + 25.0
		and spike.motion_sweep_query_count > 0,
		"The authored offset capsule sweep must catch a graze that the retired center ray misses."
	)
	spike.queue_free()
	graze_body.queue_free()
	await process_frame


func _test_native_area_contact_on_ordinary_steps() -> void:
	cold_scheduler.call("clear_all")
	var player := _spawn_player(Vector2(2028.0, 2000.0))
	player.magic_defense = 20
	var spike := ICE_SPIKE_SCENE.instantiate() as FrostSorcererIceSpike
	fixture.add_child(spike)
	spike.global_position = Vector2(2000.0, 2000.0)
	spike.setup(Vector2.RIGHT, 20, 100.0, 7.0)

	for _frame_index in range(30):
		await physics_frame
		if spike.has_hit:
			break
	_expect(
		spike.has_hit
		and player.current_health == TEST_HEALTH - 16
		and player.get_cold_stack_count() == 1,
		"Native Area2D body_entered sampling must catch a player during ordinary 60 Hz straight flight."
	)
	_expect(
		spike.motion_sweep_query_count == 0,
		"The ordinary-step native collision path must complete without per-frame ray queries."
	)

	spike.queue_free()
	player.queue_free()
	await process_frame
	cold_scheduler.call("clear_all")


func _test_player_magic_damage_cold_and_first_contact() -> void:
	cold_scheduler.call("clear_all")
	var primary := _spawn_player(Vector2(320.0, 320.0))
	var overlapping_bystander := _spawn_player(Vector2(320.0, 320.0))
	for player in [primary, overlapping_bystander]:
		player.magic_defense = 20
		player.physical_defense = 99

	var spike := _spawn_spike(Vector2.ZERO)
	spike.call("_handle_collision_body", primary)
	_expect(
		primary.current_health == TEST_HEALTH - 40
		and primary.last_damage_taken == 40,
		"Fifty magic damage must become 40 against 20 magic defense."
	)
	_expect(
		primary.get_cold_stack_count() == 1
		and int(cold_scheduler.call("get_stack_count", primary)) == 1,
		"A successful nonlethal player hit must apply one cold stack."
	)
	_expect(
		overlapping_bystander.current_health == TEST_HEALTH
		and overlapping_bystander.get_cold_stack_count() == 0,
		"Ice-spike contact must not apply AOE to an overlapping bystander."
	)

	primary.invincibility_time_left = 0.0
	spike.call("_handle_collision_body", primary)
	spike.call("_handle_collision_body", overlapping_bystander)
	_expect(
		primary.current_health == TEST_HEALTH - 40
		and primary.get_cold_stack_count() == 1
		and overlapping_bystander.current_health == TEST_HEALTH,
		"A consumed ice spike must neither hit twice nor pierce into a second target."
	)
	_expect(
		spike.has_hit
		and spike.collision_layer == 0
		and spike.collision_mask == 0
		and spike.animated_sprite.animation == &"impact",
		"First contact must immediately disable gameplay collision and show impact."
	)

	spike.queue_free()
	primary.queue_free()
	overlapping_bystander.queue_free()
	await process_frame
	cold_scheduler.call("clear_all")


func _test_building_magic_damage_without_cold() -> void:
	cold_scheduler.call("clear_all")
	var building := PlantDefense.new()
	building.max_health = TEST_HEALTH
	building.current_health = TEST_HEALTH
	building.physical_defense = 99
	building.magic_defense = 20
	building.collision_layer = 0
	building.collision_mask = 0
	fixture.add_child(building)

	var spike := _spawn_spike(Vector2.ZERO)
	spike.call("_handle_collision_body", building)
	_expect(
		building.current_health == TEST_HEALTH - 40,
		"A building must still receive the ice spike's mitigated magic damage."
	)
	_expect(
		not bool(cold_scheduler.call("has_cold", building))
		and int(cold_scheduler.call("get_stack_count", building)) == 0,
		"No PlantDefense building may receive cold state."
	)
	_expect(
		spike.has_hit and spike.animated_sprite.animation == &"impact",
		"Building contact must consume the ice spike once."
	)

	spike.queue_free()
	building.queue_free()
	await process_frame


func _test_pool_reuse_resets_all_lease_state() -> void:
	var pool := SessionObjectPool.new()
	pool.name = "FrostProjectilePool"
	fixture.add_child(pool)
	pool.register_scene(ICE_SPIKE_SCENE, 1, 1)
	var first := pool.acquire(ICE_SPIKE_SCENE) as FrostSorcererIceSpike
	_expect(first != null, "The ice-spike scene must be acquirable from SessionObjectPool.")
	if first == null:
		pool.queue_free()
		return
	var first_instance_id := first.get_instance_id()
	first.setup(Vector2.DOWN, 77, 321.0, 0.25)
	first.setup_multiplayer(701, 9, &"dirty_frost_projectile")
	first.has_hit = true
	first.effect_time_left = 0.2
	first.multiplayer_contact_consumed = true
	first.motion_sweep_query_count = 77
	_expect(pool.release(first), "An active ice-spike lease must release to its owner pool.")
	await physics_frame
	await physics_frame

	var reused := pool.acquire(ICE_SPIKE_SCENE) as FrostSorcererIceSpike
	_expect(
		reused != null and reused.get_instance_id() == first_instance_id,
		"The retained pool must reuse its original ice-spike instance."
	)
	if reused != null:
		_expect(
			reused.pool_active
			and not reused.has_hit
			and reused.direction == Vector2.RIGHT
			and is_zero_approx(reused.rotation)
			and reused.damage == 1
			and is_equal_approx(reused.speed, 100.0)
			and is_equal_approx(reused.max_lifetime, 7.0)
			and is_equal_approx(reused.remaining_lifetime, 7.0)
			and is_zero_approx(reused.effect_time_left)
			and not reused.multiplayer_contact_consumed
			and reused.motion_sweep_query_count == 0,
			"Reacquisition must restore authored motion, damage, lifetime, and hit state."
		)
		_expect(
			reused.projectile_id == 0
			and reused.owner_peer_id == 0
			and reused.source_type == FrostSorcererIceSpike.PROJECTILE_TYPE
			and reused.collision_layer == 128
			and reused.collision_mask == EXPECTED_PROJECTILE_MASK
			and reused.monitoring
			and reused.monitorable
			and not reused.collision_shape.disabled,
			"Reacquisition must clear network identity and restore collision monitoring."
		)
		pool.release(reused)
	await physics_frame
	await physics_frame
	pool.queue_free()
	await process_frame


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	fixture.add_child(player)
	player.global_position = position
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_physics_process(false)
	player.set_process(false)
	return player


func _spawn_spike(position: Vector2) -> FrostSorcererIceSpike:
	var spike := ICE_SPIKE_SCENE.instantiate() as FrostSorcererIceSpike
	fixture.add_child(spike)
	spike.global_position = position
	spike.setup(
		Vector2.RIGHT,
		FROST_SORCERER_CONFIG.attack_damage,
		0.0,
		FROST_SORCERER_CONFIG.projectile_lifetime
	)
	spike.set_physics_process(false)
	return spike


func _spawn_static_body(
	position: Vector2,
	shape_size: Vector2,
	collision_layer: int
) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = collision_layer
	body.collision_mask = 0
	var collision_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = shape_size
	collision_shape.shape = rectangle
	body.add_child(collision_shape)
	fixture.add_child(body)
	body.global_position = position
	return body


func _collect_fixture_spikes() -> Array[FrostSorcererIceSpike]:
	var result: Array[FrostSorcererIceSpike] = []
	for child in fixture.get_children():
		var spike := child as FrostSorcererIceSpike
		if spike != null and is_instance_valid(spike):
			result.append(spike)
	return result


func _expect_same_visual_node_contract(
	frost_enemy: Node2D,
	fire_enemy: Node2D
) -> void:
	_expect(
		frost_enemy.transform.is_equal_approx(fire_enemy.transform),
		"Frost and Fire Sorcerer roots must use the same authored transform."
	)
	for path in [
		NodePath("AnimatedSprite2D"),
		NodePath("CollisionShape2D"),
		NodePath("TouchDamageArea"),
		NodePath("TouchDamageArea/CollisionShape2D"),
	]:
		var frost_node := frost_enemy.get_node_or_null(path) as Node2D
		var fire_node := fire_enemy.get_node_or_null(path) as Node2D
		_expect(
			frost_node != null and fire_node != null,
			"Both Sorcerers must author shared visual/body node %s." % path
		)
		if frost_node != null and fire_node != null:
			_expect(
				frost_node.transform.is_equal_approx(fire_node.transform),
				"Frost node %s transform must match Fire Sorcerer." % path
			)

	var frost_sprite := (
		frost_enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	)
	var fire_sprite := (
		fire_enemy.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	)
	if frost_sprite != null and fire_sprite != null:
		_expect(
			frost_sprite.centered == fire_sprite.centered
			and frost_sprite.offset == fire_sprite.offset
			and frost_sprite.texture_filter == fire_sprite.texture_filter
			and frost_sprite.z_index == fire_sprite.z_index,
			"Frost sprite centering, filter, offset, and z-index must match Fire."
		)

	_expect_same_capsule_shape(
		frost_enemy,
		fire_enemy,
		NodePath("CollisionShape2D")
	)
	_expect_same_capsule_shape(
		frost_enemy,
		fire_enemy,
		NodePath("TouchDamageArea/CollisionShape2D")
	)


func _expect_same_capsule_shape(
	frost_enemy: Node2D,
	fire_enemy: Node2D,
	path: NodePath
) -> void:
	var frost_node := frost_enemy.get_node_or_null(path) as CollisionShape2D
	var fire_node := fire_enemy.get_node_or_null(path) as CollisionShape2D
	var frost_capsule := (
		frost_node.shape as CapsuleShape2D if frost_node != null else null
	)
	var fire_capsule := (
		fire_node.shape as CapsuleShape2D if fire_node != null else null
	)
	_expect(
		frost_capsule != null and fire_capsule != null,
		"Both Sorcerers must use a capsule at %s." % path
	)
	if frost_capsule == null or fire_capsule == null:
		return
	_expect(
		is_equal_approx(frost_capsule.radius, fire_capsule.radius)
		and is_equal_approx(frost_capsule.height, fire_capsule.height)
		and frost_node.disabled == fire_node.disabled,
		"Frost capsule %s must match Fire radius, height, and disabled state."
		% path
	)


func _expect_same_character_alpha_bounds(
	frost_frames: SpriteFrames,
	fire_frames: SpriteFrames
) -> void:
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		_expect(
			frost_frames.has_animation(animation_name)
			and fire_frames.has_animation(animation_name),
			"Both Sorcerers must author animation %s." % animation_name
		)
		if (
			not frost_frames.has_animation(animation_name)
			or not fire_frames.has_animation(animation_name)
		):
			continue
		for frame_index in range(4):
			var frost_texture := frost_frames.get_frame_texture(
				animation_name,
				frame_index
			) as AtlasTexture
			var fire_texture := fire_frames.get_frame_texture(
				animation_name,
				frame_index
			) as AtlasTexture
			_expect(
				frost_texture != null and fire_texture != null,
				"Both Sorcerers must use AtlasTexture character frames."
			)
			if frost_texture == null or fire_texture == null:
				continue
			var frost_bounds := _atlas_alpha_bounds(frost_texture)
			var fire_bounds := _atlas_alpha_bounds(fire_texture)
			_expect(
				fire_bounds.has_area() and frost_bounds == fire_bounds,
				(
					"Frost %s frame %d alpha bounds must match Fire: "
					+ "saw %s versus %s."
				)
				% [
					animation_name,
					frame_index,
					str(frost_bounds),
					str(fire_bounds),
				]
			)


func _atlas_alpha_bounds(texture: AtlasTexture) -> Rect2i:
	if texture.atlas == null:
		return Rect2i()
	var atlas_image := texture.atlas.get_image()
	if atlas_image == null:
		return Rect2i()
	var region := Rect2i(
		Vector2i(
			roundi(texture.region.position.x),
			roundi(texture.region.position.y)
		),
		Vector2i(
			roundi(texture.region.size.x),
			roundi(texture.region.size.y)
		)
	)
	var minimum := region.size
	var maximum := Vector2i(-1, -1)
	for local_y in range(region.size.y):
		for local_x in range(region.size.x):
			var pixel := atlas_image.get_pixel(
				region.position.x + local_x,
				region.position.y + local_y
			)
			if pixel.a <= 0.0:
				continue
			minimum.x = mini(minimum.x, local_x)
			minimum.y = mini(minimum.y, local_y)
			maximum.x = maxi(maximum.x, local_x)
			maximum.y = maxi(maximum.y, local_y)
	if maximum.x < 0:
		return Rect2i()
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


func _expect_animation_contract(
	frames: SpriteFrames,
	animation_names: Array[StringName],
	expected_frame_size: Vector2,
	label: String
) -> void:
	_expect(frames != null, "%s SpriteFrames resource is missing." % label)
	if frames == null:
		return
	for animation_name in animation_names:
		_expect(
			frames.has_animation(animation_name),
			"%s animation %s is missing." % [label, animation_name]
		)
		if not frames.has_animation(animation_name):
			continue
		_expect(
			frames.get_frame_count(animation_name) == 4,
			"%s animation %s must contain four authored frames."
			% [label, animation_name]
		)
		for frame_index in range(frames.get_frame_count(animation_name)):
			var texture := frames.get_frame_texture(animation_name, frame_index)
			_expect(
				texture is AtlasTexture
				and texture.get_size() == expected_frame_size,
				"%s %s frame %d must remain native %s, saw %s."
				% [
					label,
					animation_name,
					frame_index,
					str(expected_frame_size),
					str(texture.get_size() if texture != null else Vector2.ZERO),
				]
			)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
