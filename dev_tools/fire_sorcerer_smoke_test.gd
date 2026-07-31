extends SceneTree

const FIRE_SORCERER_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer.tscn"
)
const FIREBALL_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const FIRE_SORCERER_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const MAGE_CONFIG := preload(
	"res://resources/config/enemies/capoo_mage.tres"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PLAYER_CONFIG := preload(
	"res://resources/config/players/player_weishidaier.tres"
)

const CHARACTER_FRAME_LIMIT := Vector2(40.0, 40.0)
const FIREBALL_FRAME_LIMIT := Vector2(40.0, 40.0)
const MOVE_TEXTURE_PATH := "res://resources/texture/fire_sorcerer_move.png"
const MOVE_FRAME_COUNT := 8
const MOVE_ANIMATION_SPEED := 12.0
const TEST_HEALTH := 1000
const TEST_DELTA := 1.0 / 60.0

var failures: Array[String] = []
var test_root: Node2D = null


class DirectPathfinder:
	extends Node

	var is_built := true

	func try_get_safe_navigation_step(
		_from_position: Vector2,
		target_position: Vector2,
		_half_extents: Vector2,
		_terrain_types: int
	) -> Dictionary:
		return {
			"status": GridPathfinder.NavigationStepStatus.READY,
			"is_complete_route": true,
			"waypoint": target_position,
			"resolved_from_cell": Vector2i.ZERO,
			"next_cell": Vector2i.RIGHT,
			"used_start_recovery": false,
		}


class TargetRuntime:
	extends Node2D

	var nearest_target: Node2D = null
	var query_count := 0

	func find_nearest_enemy_attack_target_world(
		from_position: Vector2,
		max_distance: float
	) -> Node2D:
		query_count += 1
		if nearest_target == null or not is_instance_valid(nearest_target):
			return null
		if (
			from_position.distance_squared_to(nearest_target.global_position)
			> max_distance * max_distance
		):
			return null
		return nearest_target


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "FireSorcererSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_and_scene_contract()
	await _test_defense_contract()
	await _test_three_fireball_windup_and_cooldown_origin()
	await _test_magic_first_contact_without_aoe()
	await _test_strong_homing()
	await _test_low_frequency_target_refresh()
	await _test_seven_second_visual_expiry()
	await _test_nearest_assigned_target_selection()
	await _test_runtime_nearest_target_selection()
	await _test_ranged_standoff_and_resume()
	await _test_proxy_preview_timeout()

	root.get_node("BurnStatusScheduler").call("clear_all")
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("FIRE_SORCERER_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_and_scene_contract() -> void:
	_expect(
		FIRE_SORCERER_CONFIG is FireSorcererConfig,
		"Fire Sorcerer config must use FireSorcererConfig."
	)
	_expect(
		FIRE_SORCERER_CONFIG.display_name == "火焰术士",
		"Fire Sorcerer display name mismatch."
	)
	_expect(
		FIRE_SORCERER_CONFIG.enemy_scene == FIRE_SORCERER_SCENE,
		"Fire Sorcerer must own an independent enemy scene."
	)
	_expect(
		FIRE_SORCERER_CONFIG.volley_scene == FIREBALL_VOLLEY_SCENE,
		"Fire Sorcerer must own an independent three-fireball volley scene."
	)
	_expect(
		FIRE_SORCERER_CONFIG.max_health == 200,
		"Fire Sorcerer health must be 200."
	)
	_expect(
		FIRE_SORCERER_CONFIG.attack_damage == 40,
		"Every Fire Sorcerer fireball must use 40 base damage."
	)
	_expect(
		FIRE_SORCERER_CONFIG.physical_defense == 20
		and FIRE_SORCERER_CONFIG.magic_defense == 80,
		"Fire Sorcerer defenses must be 20 physical and 80 magic."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.move_speed, 24.0),
		"Fire Sorcerer movement speed mismatch."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.attack_range, 672.0)
		and FIRE_SORCERER_CONFIG.attack_range > MAGE_CONFIG.attack_range
		and is_equal_approx(MAGE_CONFIG.attack_range, 640.0),
		"Fire Sorcerer range must be 672, above Mage Capoo's 640."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.summon_duration, 0.6),
		"Fire Sorcerer summon windup must be 0.6 seconds."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.attack_interval, 3.0),
		"Fire Sorcerer post-generation cooldown must be 3 seconds."
	)
	_expect(
		is_equal_approx(
			FIRE_SORCERER_CONFIG.initial_attack_stagger_window,
			0.9
		),
		"Large Fire Sorcerer cohorts must use the authored 0.9 s first-attack stagger."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.burn_duration, 5.0)
		and FIRE_SORCERER_CONFIG.burn_level == 5,
		"Fire Sorcerer hits must apply five seconds of level-5 burn."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.projectile_lifetime, 7.0),
		"Fire Sorcerer projectile lifetime must be 7 seconds."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.projectile_speed, 100.0)
		and is_equal_approx(
			FIRE_SORCERER_CONFIG.projectile_speed
				- PLAYER_CONFIG.starting_move_speed,
			-20.0
		),
		"Fire Sorcerer projectile speed must be 100, exactly 20 below the "
		+ "player's default movement speed."
	)
	_expect(
		is_equal_approx(
			FireSorcererFireballVolley.IMPACT_VISUAL_DURATION,
			4.0 / 12.0
		)
		and is_equal_approx(
			FireSorcererFireballVolley.EXPIRE_VISUAL_DURATION,
			4.0 / 12.0
		),
		"Four-frame impact and expiry animations must remain visible for a full 12 FPS cycle."
	)
	_expect(
		is_equal_approx(FIRE_SORCERER_CONFIG.homing_turn_rate, 6.0)
		and FIRE_SORCERER_CONFIG.homing_turn_rate
			> MAGE_CONFIG.fireball_homing_turn_rate * 5.0,
		"Fire Sorcerer homing must be substantially stronger than Mage Capoo."
	)

	var character_texture := load(
		"res://resources/texture/fire_sorcerer.png"
	) as Texture2D
	var fireball_texture := load(
		"res://resources/texture/fire_sorcerer_fireball.png"
	) as Texture2D
	_expect(
		character_texture != null
		and character_texture.get_size() == Vector2(160.0, 160.0),
		"Character sheet must be a native 4x4 grid of 40x40 frames."
	)
	_expect(
		fireball_texture != null
		and fireball_texture.get_size() == Vector2(128.0, 128.0),
		"Fireball sheet must be a native 4x4 grid whose cells stay below 40x40."
	)

	var instance := FIRE_SORCERER_SCENE.instantiate() as FireSorcerer
	_expect(instance != null, "Fire Sorcerer scene failed to instantiate.")
	if instance != null:
		var sprite := (
			instance.get_node_or_null("AnimatedSprite2D")
			as AnimatedSprite2D
		)
		_expect(
			sprite != null
			and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
			and sprite.scale == Vector2.ONE,
			"Fire Sorcerer must use nearest filtering and lossless scale 1."
		)
		_expect(
			instance.call("_get_touch_damage_type")
				== EnemyConfig.DamageType.MAGIC,
			"Fire Sorcerer body contact must use magic damage."
		)
		if sprite != null:
			_expect_animation_frames_within_limit(
				sprite.sprite_frames,
				[&"move", &"windup", &"attack", &"death"],
				CHARACTER_FRAME_LIMIT,
				"Fire Sorcerer"
			)
		var markers: Array[Marker2D] = [
			instance.get_node_or_null("SummonPivot/SpawnA") as Marker2D,
			instance.get_node_or_null("SummonPivot/SpawnB") as Marker2D,
			instance.get_node_or_null("SummonPivot/SpawnC") as Marker2D,
		]
		var previews: Array[AnimatedSprite2D] = [
			instance.get_node_or_null(
				"SummonPivot/FireballPreviewA"
			) as AnimatedSprite2D,
			instance.get_node_or_null(
				"SummonPivot/FireballPreviewB"
			) as AnimatedSprite2D,
			instance.get_node_or_null(
				"SummonPivot/FireballPreviewC"
			) as AnimatedSprite2D,
		]
		var unique_marker_positions := {}
		for marker_index in range(markers.size()):
			var marker := markers[marker_index]
			var preview := previews[marker_index]
			_expect(
				marker != null and preview != null,
				"All three summon markers and preview sprites must be scene-authored."
			)
			if marker == null or preview == null:
				continue
			unique_marker_positions[marker.position] = true
			_expect(
				preview.position == marker.position
				and preview.texture_filter
					== CanvasItem.TEXTURE_FILTER_NEAREST,
				"Preview %d must align with its marker and use nearest filtering."
				% marker_index
			)
			_expect_animation_frames_within_limit(
				preview.sprite_frames,
				[&"spawn"],
				FIREBALL_FRAME_LIMIT,
				"Fireball preview"
			)
		_expect(
			unique_marker_positions.size() == 3,
			"Three summon fireballs must occupy three distinct authored positions."
		)
		var animation_player := (
			instance.get_node_or_null("SummonAnimationPlayer")
			as AnimationPlayer
		)
		_expect(
			animation_player != null
			and animation_player.has_animation(&"summon")
			and is_equal_approx(
				animation_player.get_animation(&"summon").length,
				FIRE_SORCERER_CONFIG.summon_duration
			),
			"The scene-authored scale windup must match summon duration."
		)
		instance.free()

	var volley := (
		FIREBALL_VOLLEY_SCENE.instantiate()
		as FireSorcererFireballVolley
	)
	_expect(volley != null, "Fireball volley scene failed to instantiate.")
	if volley != null:
		var unique_positions := {}
		for ball_name in ["FireballA", "FireballB", "FireballC"]:
			var area := volley.get_node_or_null(ball_name) as Area2D
			var ball_sprite := (
				volley.get_node_or_null(
					"%s/VisualRoot/AnimatedSprite2D" % ball_name
				) as AnimatedSprite2D
			)
			_expect(
				area != null and ball_sprite != null,
				"Volley must scene-author all three Area2D fireballs."
			)
			if area == null or ball_sprite == null:
				continue
			unique_positions[area.position] = true
			_expect(
				ball_sprite.texture_filter
					== CanvasItem.TEXTURE_FILTER_NEAREST,
				"Fireball sprites must use nearest filtering."
			)
			_expect_animation_frames_within_limit(
				ball_sprite.sprite_frames,
				[&"fly", &"spawn", &"impact", &"expire"],
				FIREBALL_FRAME_LIMIT,
				"Fireball"
			)
		_expect(
			unique_positions.size() == FireSorcererFireballVolley.BALL_COUNT,
			"Volley scene must preserve three distinct fireball offsets."
		)
		_expect(
			is_equal_approx(volley.burn_duration, 5.0)
			and volley.burn_level == 5,
			"The normal volley must author the level-5 burn profile."
		)
		volley.free()


func _test_defense_contract() -> void:
	var enemy := _spawn_sorcerer(Vector2.ZERO, null, null)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.hit_audio.stream = null
	enemy.current_health = FIRE_SORCERER_CONFIG.max_health
	enemy.apply_damage(
		100,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		enemy.current_health == 120 and enemy.last_damage_taken == 80,
		"20 physical defense must reduce 100 physical damage to 80."
	)
	enemy.apply_damage(
		100,
		Vector2.ZERO,
		EnemyConfig.DamageType.MAGIC,
		false
	)
	_expect(
		enemy.current_health == 100 and enemy.last_damage_taken == 20,
		"80 magic defense must reduce 100 magic damage to 20."
	)
	enemy.queue_free()
	await process_frame


func _test_three_fireball_windup_and_cooldown_origin() -> void:
	var player := _spawn_player(Vector2(240.0, 0.0))
	player.collision_layer = 0
	player.collision_mask = 0
	var enemy := _spawn_sorcerer(Vector2.ZERO, player, null)
	enemy.set_physics_process(false)
	await physics_frame

	var volleys_before := _collect_volleys().size()
	_expect(
		bool(enemy.call(
			"_try_start_summon",
			player,
			FIRE_SORCERER_CONFIG
		)),
		"An unobstructed target inside 672 px must start summon windup."
	)
	_expect(
		enemy.combat_state == FireSorcerer.CombatState.SUMMON
		and enemy.animated_sprite.animation == &"windup"
		and is_zero_approx(enemy.attack_cooldown_left),
		"Windup must begin before the post-generation cooldown."
	)
	for preview in enemy.summon_previews:
		_expect(
			preview.visible and preview.scale.length() < 0.001,
			"Every preview fireball must begin visible at scale zero."
		)
	_expect(
		_collect_volleys().size() == volleys_before,
		"Real fireballs must not exist at the beginning of windup."
	)

	enemy.summon_animation_player.advance(
		FIRE_SORCERER_CONFIG.summon_duration * 0.5
	)
	var growing_preview_count := 0
	for preview in enemy.summon_previews:
		if (
			preview.scale.x > 0.0
			and preview.scale.x < 1.0
			and preview.scale.y > 0.0
			and preview.scale.y < 1.0
		):
			growing_preview_count += 1
	_expect(
		growing_preview_count == 3,
		"All three preview fireballs must visibly grow from 0 toward 1."
	)

	enemy.call(
		"_update_summon",
		FIRE_SORCERER_CONFIG.summon_duration - 0.01
	)
	_expect(
		_collect_volleys().size() == volleys_before
		and is_zero_approx(enemy.attack_cooldown_left),
		"Neither the volley nor its 3 s cooldown may begin before windup completes."
	)
	enemy.call("_update_summon", 0.02)
	var volleys := _collect_volleys()
	_expect(
		volleys.size() == volleys_before + 1,
		"Completing windup must create exactly one three-fireball volley root."
	)
	_expect(
		enemy.combat_state == FireSorcerer.CombatState.CHASE
		and enemy.animated_sprite.animation == &"attack"
		and is_equal_approx(
			enemy.attack_cooldown_left,
			FIRE_SORCERER_CONFIG.attack_interval
		),
		"The 3 s cooldown must start only after real fireballs are generated."
	)
	enemy.animated_sprite.animation_finished.emit()
	_expect(
		enemy.animated_sprite.animation == &"move",
		"The authority animation must return to move after the non-looping "
		+ "staff attack finishes."
	)
	var spawned_volley: FireSorcererFireballVolley = volleys.back()
	spawned_volley.set_physics_process(false)
	_expect(
		spawned_volley.global_position.is_equal_approx(
			enemy.summon_pivot.global_position
		),
		"Real fireballs must replace the previews at the staff summon pivot."
	)
	var expected_offsets := {}
	for marker in enemy.summon_markers:
		expected_offsets[marker.position] = true
	var actual_offsets := {}
	for ball in spawned_volley.ball_areas:
		actual_offsets[ball.position] = true
	_expect(
		actual_offsets == expected_offsets,
		"Generated fireballs must preserve the three preview marker offsets."
	)
	for preview in enemy.summon_previews:
		_expect(
			not preview.visible and preview.scale.length() < 0.001,
			"Preview fireballs must hide after the real volley appears."
		)

	enemy.call(
		"_update_attack_cooldown",
		FIRE_SORCERER_CONFIG.attack_interval - 0.01
	)
	_expect(
		enemy.attack_cooldown_left > 0.0,
		"Post-generation cooldown must remain active until the full 3 seconds."
	)
	enemy.call("_update_attack_cooldown", 0.02)
	_expect(
		is_zero_approx(enemy.attack_cooldown_left)
		and FIRE_SORCERER_CONFIG.summon_duration
			+ FIRE_SORCERER_CONFIG.attack_interval
			> FIRE_SORCERER_CONFIG.attack_interval,
		"Overall attack cycle must exceed 3 seconds because windup is additional."
	)

	spawned_volley.queue_free()
	enemy.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_magic_first_contact_without_aoe() -> void:
	var primary := _spawn_player(Vector2(320.0, 320.0))
	var secondary := _spawn_player(Vector2(320.0, 320.0))
	for player in [primary, secondary]:
		player.collision_layer = 0
		player.collision_mask = 0
		player.magic_defense = 20
		player.physical_defense = 49
		player.invincibility_duration = 0.0
		player.invincibility_time_left = 0.0

	var volley := _spawn_volley(
		Vector2.ZERO,
		Vector2.RIGHT,
		FIRE_SORCERER_CONFIG.attack_damage,
		0.0,
		FIRE_SORCERER_CONFIG.projectile_lifetime,
		null,
		FIRE_SORCERER_CONFIG.homing_turn_rate
	)
	volley.call("_on_ball_body_entered", primary, 0)
	_expect(
		primary.current_health == TEST_HEALTH - 32
		and primary.last_damage_taken == 32,
		"40 magic damage must become 32 against 20 magic defense; "
		+ "physical defense must not be used."
	)
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	_expect(
		bool(burn_scheduler.call(
			"has_burn",
			primary,
			&"fire_sorcerer_fireball_volley"
		))
		and int(burn_scheduler.call("get_source_count", primary)) == 1,
		"A successful normal fireball hit must register one refreshed burn family."
	)
	_expect(
		secondary.current_health == TEST_HEALTH,
		"First contact must not damage an overlapping bystander (no AOE)."
	)
	_expect(
		not bool(volley.call("_is_ball_active", 0))
		and bool(volley.call("_is_ball_active", 1))
		and bool(volley.call("_is_ball_active", 2))
		and volley.ball_sprites[0].animation == &"impact",
		"Only the contacted fireball must enter its compact impact visual."
	)

	primary.invincibility_time_left = 0.0
	volley.call("_on_ball_body_entered", primary, 0)
	_expect(
		primary.current_health == TEST_HEALTH - 32,
		"The same fireball must never damage a target twice after first contact."
	)
	volley.call("_on_ball_body_entered", secondary, 1)
	_expect(
		secondary.current_health == TEST_HEALTH - 32
		and bool(volley.call("_is_ball_active", 2)),
		"Each remaining fireball must independently deal one first-contact hit."
	)
	# apply_damage refreshes config-derived defenses after the initial hit; set
	# the differentiated probe defense again so the periodic path remains
	# observably magic rather than physical.
	primary.magic_defense = 20
	secondary.magic_defense = 20
	burn_scheduler.call("_advance_active_burns", 1.01)
	_expect(
		primary.current_health == TEST_HEALTH - 36
		and secondary.current_health == TEST_HEALTH - 36,
		"Level-5 burn must tick as 4 magic damage against 20 magic defense."
	)
	volley.call(
		"_update_effects",
		FireSorcererFireballVolley.IMPACT_VISUAL_DURATION - 0.01
	)
	_expect(
		volley.ball_sprites[0].visible
		and volley.ball_sprites[1].visible
		and volley.pool_active,
		"Impact visuals must retain all four 12 FPS frames before one-third second."
	)
	volley.call("_update_effects", 0.02)
	_expect(
		not volley.ball_sprites[0].visible
		and not volley.ball_sprites[1].visible
		and volley.pool_active,
		"Impact visuals must retire individually without deleting the live third ball."
	)

	volley.queue_free()
	primary.queue_free()
	secondary.queue_free()
	await process_frame
	await physics_frame


func _test_strong_homing() -> void:
	var target := _spawn_player(Vector2(0.0, 240.0))
	target.collision_layer = 0
	target.collision_mask = 0
	var volley := _spawn_volley(
		Vector2.ZERO,
		Vector2.RIGHT,
		50,
		FIRE_SORCERER_CONFIG.projectile_speed,
		7.0,
		target,
		FIRE_SORCERER_CONFIG.homing_turn_rate
	)
	var positions_before := PackedVector2Array()
	for ball in volley.ball_areas:
		positions_before.append(ball.global_position)
	volley.call("_advance_ball_positions", TEST_DELTA)
	var maximum_turn := FIRE_SORCERER_CONFIG.homing_turn_rate * TEST_DELTA
	for ball_index in range(FireSorcererFireballVolley.BALL_COUNT):
		var turned_direction := volley.ball_directions[ball_index]
		var turned_angle := Vector2.RIGHT.angle_to(turned_direction)
		_expect(
			turned_angle > 0.09
			and turned_angle <= maximum_turn + 0.0001,
			"Fireball %d must use the strong bounded 6 rad/s homing turn."
			% ball_index
		)
		_expect(
			volley.ball_areas[ball_index].global_position.y
				> positions_before[ball_index].y,
			"Fireball %d must immediately curve toward the elevated target."
			% ball_index
		)

	volley.queue_free()
	target.queue_free()
	await process_frame
	await physics_frame


func _test_low_frequency_target_refresh() -> void:
	var expired_target := _spawn_player(Vector2(0.0, 240.0))
	var replacement_target := _spawn_player(Vector2(0.0, -240.0))
	for player in [expired_target, replacement_target]:
		player.collision_layer = 0
		player.collision_mask = 0
	var runtime := TargetRuntime.new()
	test_root.add_child(runtime)
	runtime.nearest_target = replacement_target
	var volley := _spawn_volley(
		Vector2.ZERO,
		Vector2.RIGHT,
		50,
		FIRE_SORCERER_CONFIG.projectile_speed,
		7.0,
		expired_target,
		FIRE_SORCERER_CONFIG.homing_turn_rate,
		runtime
	)
	expired_target.is_dead = true
	volley.call("_advance_motion", TEST_DELTA)
	_expect(
		volley.target == replacement_target
		and runtime.query_count == 1,
		"An invalid fireball target must immediately reacquire the nearest "
		+ "reachable player or plant once for the whole volley."
	)
	for ball_direction in volley.ball_directions:
		_expect(
			ball_direction.y < 0.0,
			"Reacquired fireballs must curve toward the replacement target."
		)
	volley.call("_advance_motion", TEST_DELTA)
	_expect(
		runtime.query_count == 1,
		"All three fireballs must share a throttled target refresh instead of "
		+ "querying once per ball or physics frame."
	)
	volley.call(
		"_advance_motion",
		FireSorcererFireballVolley.TARGET_REFRESH_INTERVAL + 0.01
	)
	_expect(
		runtime.query_count == 1,
		"A live homing target must not trigger periodic world queries."
	)
	replacement_target.is_dead = true
	runtime.nearest_target = null
	volley.call("_advance_motion", TEST_DELTA)
	_expect(
		volley.target == null
		and runtime.query_count == 2,
		"Losing a replacement target must perform one immediate shared retry."
	)
	volley.call("_advance_motion", TEST_DELTA)
	_expect(
		runtime.query_count == 2,
		"An unresolved replacement must throttle retries for the whole volley."
	)
	var retry_target := _spawn_player(Vector2(240.0, 0.0))
	retry_target.collision_layer = 0
	retry_target.collision_mask = 0
	runtime.nearest_target = retry_target
	volley.call(
		"_advance_motion",
		FireSorcererFireballVolley.TARGET_REFRESH_INTERVAL + 0.01
	)
	_expect(
		volley.target == retry_target
		and runtime.query_count == 3,
		"An unresolved volley must reacquire the nearest reachable target on "
		+ "its next 0.35 s retry."
	)

	volley.queue_free()
	runtime.queue_free()
	expired_target.queue_free()
	replacement_target.queue_free()
	retry_target.queue_free()
	await process_frame
	await physics_frame


func _test_seven_second_visual_expiry() -> void:
	var nearby := _spawn_player(Vector2.ZERO)
	nearby.collision_layer = 0
	nearby.collision_mask = 0
	var volley := _spawn_volley(
		Vector2.ZERO,
		Vector2.RIGHT,
		50,
		0.0,
		FIRE_SORCERER_CONFIG.projectile_lifetime,
		null,
		FIRE_SORCERER_CONFIG.homing_turn_rate
	)
	volley.call("_physics_process", 6.99)
	_expect(
		volley.active_ball_mask
			== FireSorcererFireballVolley.ALL_BALLS_ACTIVE_MASK
		and volley.visible_effect_mask == 0
		and not volley.is_queued_for_deletion(),
		"All fireballs must remain live immediately before 7 seconds."
	)
	volley.call("_physics_process", 0.02)
	_expect(
		volley.active_ball_mask == 0
		and volley.visible_effect_mask
			== FireSorcererFireballVolley.ALL_BALLS_ACTIVE_MASK,
		"At 7 seconds every surviving fireball must enter visual expiry."
	)
	for sprite in volley.ball_sprites:
		_expect(
			sprite.visible and sprite.animation == &"expire",
			"Lifetime expiry must visibly play the non-AOE extinguish animation."
		)
	_expect(
		nearby.current_health == TEST_HEALTH,
		"Seven-second visual expiry must not create an AOE damage event."
	)
	volley.call(
		"_physics_process",
		FireSorcererFireballVolley.EXPIRE_VISUAL_DURATION + 0.01
	)
	_expect(
		volley.is_queued_for_deletion() and not volley.pool_active,
		"Volley root must retire after its expiry visuals complete."
	)

	nearby.queue_free()
	await process_frame
	await physics_frame


func _test_nearest_assigned_target_selection() -> void:
	var player := _spawn_player(Vector2(160.0, 0.0))
	var plant := PlantDefense.new()
	plant.max_health = TEST_HEALTH
	plant.current_health = TEST_HEALTH
	test_root.add_child(plant)
	plant.global_position = Vector2(240.0, 0.0)
	var enemy := _spawn_sorcerer(Vector2.ZERO, player, null)
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	_expect(
		enemy.call("_get_preferred_ranged_combat_target") == plant,
		"An explicit proactive objective must win over a nearer family-range player."
	)
	plant.global_position = Vector2(80.0, 0.0)
	_expect(
		enemy.call("_get_preferred_ranged_combat_target") == plant,
		"Fire Sorcerer must prefer the nearer assigned plant over the player."
	)
	plant.is_removing = true
	_expect(
		enemy.call("_get_preferred_ranged_combat_target") == player,
		"An invalidated nearest plant must immediately fall back to the live player."
	)

	enemy.queue_free()
	plant.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_runtime_nearest_target_selection() -> void:
	var player := _spawn_player(Vector2(320.0, 0.0))
	player.collision_layer = 0
	player.collision_mask = 0
	var nearest_plant := PlantDefense.new()
	nearest_plant.max_health = TEST_HEALTH
	nearest_plant.current_health = TEST_HEALTH
	test_root.add_child(nearest_plant)
	nearest_plant.global_position = Vector2(96.0, 0.0)
	var runtime := TargetRuntime.new()
	test_root.add_child(runtime)
	runtime.nearest_target = nearest_plant
	var pathfinder := DirectPathfinder.new()
	runtime.add_child(pathfinder)
	var enemy := _spawn_sorcerer(Vector2.ZERO, player, pathfinder)
	enemy.set_physics_process(false)
	var navigation_gate := Node2D.new()
	runtime.add_child(navigation_gate)
	navigation_gate.global_position = Vector2(640.0, 0.0)
	enemy.set_objective_target(navigation_gate)
	await physics_frame

	_expect(
		bool(enemy.call(
			"_try_start_summon",
			player,
			FIRE_SORCERER_CONFIG
		))
		and enemy.summon_target == nearest_plant
		and runtime.query_count == 1,
		"Attack startup must query the runtime once and choose an unassigned "
		+ "nearer plant inside the full 672 px attack radius."
	)
	enemy.call("_cancel_summon")
	_expect(
		bool(enemy.call(
			"_try_start_summon",
			player,
			FIRE_SORCERER_CONFIG
		))
		and enemy.summon_target == nearest_plant
		and runtime.query_count == 1,
		"Repeated startup inside 0.35 s must reuse the per-sorcerer nearest "
		+ "target cache."
	)

	enemy.queue_free()
	pathfinder.queue_free()
	runtime.queue_free()
	navigation_gate.queue_free()
	nearest_plant.queue_free()
	player.queue_free()
	await process_frame
	await physics_frame


func _test_ranged_standoff_and_resume() -> void:
	var pathfinder := DirectPathfinder.new()
	test_root.add_child(pathfinder)
	var player := _spawn_player(Vector2(600.0, 0.0))
	player.collision_layer = 0
	player.collision_mask = 0
	var enemy := _spawn_sorcerer(Vector2.ZERO, player, pathfinder)
	enemy.set_physics_process(false)
	enemy.navigation_update_interval_frames = 1
	enemy.attack_cooldown_left = 1.0
	await physics_frame
	_expect(
		bool(enemy.call(
			"_has_ranged_combat_line",
			player,
			1,
			true
		)),
		"Standoff fixture must have an unobstructed ranged line."
	)
	var held_position := enemy.global_position
	enemy.call("_physics_process", TEST_DELTA)
	_expect(
		bool(enemy.get("_ranged_attack_position_held"))
		and enemy.velocity == Vector2.ZERO
		and enemy.global_position.is_equal_approx(held_position),
		"Fire Sorcerer must stop advancing inside clear 672 px attack range."
	)

	player.global_position = Vector2(700.0, 0.0)
	enemy.call("_physics_process", TEST_DELTA)
	_expect(
		not bool(enemy.get("_ranged_attack_position_held"))
		and enemy.velocity.x > 0.0
		and enemy.global_position.x > held_position.x,
		"Leaving attack range must release standoff and resume navigation movement."
	)

	enemy.queue_free()
	player.queue_free()
	pathfinder.queue_free()
	await process_frame
	await physics_frame


func _test_proxy_preview_timeout() -> void:
	var enemy := _spawn_sorcerer(Vector2.ZERO, null, null)
	enemy.set_physics_process(false)
	enemy.is_multiplayer_proxy = true
	enemy.play_multiplayer_enemy_action(&"summon", Vector2.RIGHT, 20)
	_expect(
		_all_summon_previews_have_visibility(enemy, true),
		"A multiplayer summon action must show all three preview fireballs."
	)
	enemy.call("_expire_proxy_summon_preview", 19)
	_expect(
		_all_summon_previews_have_visibility(enemy, true),
		"A stale timeout must not clear a newer multiplayer summon action."
	)
	enemy.call("_expire_proxy_summon_preview", 20)
	_expect(
		_all_summon_previews_have_visibility(enemy, false)
		and enemy.animated_sprite.animation == &"move",
		"A lost fire/cancel packet must self-clear previews and restore movement."
	)

	enemy.queue_free()
	await process_frame
	await physics_frame


func _all_summon_previews_have_visibility(
	enemy: FireSorcerer,
	expected_visibility: bool
) -> bool:
	for preview in enemy.summon_previews:
		if preview.visible != expected_visibility:
			return false
	return true


func _expect_animation_frames_within_limit(
	frames: SpriteFrames,
	animation_names: Array[StringName],
	frame_limit: Vector2,
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
		var expected_frame_count := (
			MOVE_FRAME_COUNT if animation_name == &"move" else 4
		)
		_expect(
			frames.get_frame_count(animation_name) == expected_frame_count,
			"%s animation %s must contain %d authored frames."
			% [label, animation_name, expected_frame_count]
		)
		if animation_name == &"move":
			_expect(
				is_equal_approx(
					frames.get_animation_speed(&"move"),
					MOVE_ANIMATION_SPEED
				)
				and frames.get_animation_loop(&"move"),
				"Fire Sorcerer move must loop at 12 fps."
			)
		for frame_index in range(frames.get_frame_count(animation_name)):
			var frame_texture := frames.get_frame_texture(
				animation_name,
				frame_index
			)
			var frame_size := (
				frame_texture.get_size()
				if frame_texture != null
				else Vector2.ZERO
			)
			_expect(
				frame_texture is AtlasTexture
				and frame_size.x <= frame_limit.x
				and frame_size.y <= frame_limit.y,
				"%s %s frame %d exceeds the 40x40 limit: %s."
				% [label, animation_name, frame_index, frame_size]
			)
			if animation_name == &"move" and frame_texture is AtlasTexture:
				var atlas_texture := frame_texture as AtlasTexture
				_expect(
					atlas_texture.atlas != null
					and atlas_texture.atlas.get_size() == Vector2(320.0, 40.0)
					and atlas_texture.atlas.resource_path == MOVE_TEXTURE_PATH
					and atlas_texture.region == Rect2(
						float(frame_index * 40), 0.0, 40.0, 40.0
					),
					"Fire Sorcerer move frame %d must use the independent strip."
					% frame_index
				)


func _spawn_player(position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	test_root.add_child(player)
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


func _spawn_sorcerer(
	position: Vector2,
	player: Player,
	pathfinder: Node
) -> FireSorcerer:
	var enemy := FIRE_SORCERER_SCENE.instantiate() as FireSorcerer
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(FIRE_SORCERER_CONFIG, player, pathfinder)
	return enemy


func _spawn_volley(
	position: Vector2,
	initial_direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	target: Node2D,
	turn_rate: float,
	target_runtime: Node = null
) -> FireSorcererFireballVolley:
	var volley := (
		FIREBALL_VOLLEY_SCENE.instantiate()
		as FireSorcererFireballVolley
	)
	test_root.add_child(volley)
	volley.global_position = position
	volley.setup(
		initial_direction,
		damage,
		speed,
		lifetime,
		target,
		turn_rate,
		target_runtime
	)
	volley.set_physics_process(false)
	return volley


func _collect_volleys() -> Array[FireSorcererFireballVolley]:
	var volleys: Array[FireSorcererFireballVolley] = []
	for child in test_root.get_children():
		var volley := child as FireSorcererFireballVolley
		if volley != null and not volley.is_queued_for_deletion():
			volleys.append(volley)
	return volleys


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
