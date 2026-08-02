extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer_elite.tres"
)
const BASE_CONFIG := preload(
	"res://resources/config/enemies/fire_sorcerer.tres"
)
const ELITE_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite.tscn"
)
const BASE_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer.tscn"
)
const ELITE_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_elite_fireball_volley.tscn"
)
const BASE_VOLLEY_SCENE := preload(
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const PLAYER_CONFIG := preload(
	"res://resources/config/players/player_weishidaier.tres"
)

const BASE_CHARACTER_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/fire_sorcerer.png"
)
const ELITE_CHARACTER_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/fire_sorcerer_elite.png"
)
const BASE_MOVE_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/fire_sorcerer_move.png"
)
const ELITE_MOVE_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/fire_sorcerer_elite_move.png"
)
const MOVE_FRAME_COUNT := 8
const MOVE_ANIMATION_SPEED := 12.0
const BASE_FIREBALL_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/fire_sorcerer_fireball.png"
)
const ELITE_FIREBALL_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/fire_sorcerer_elite_fireball.png"
)
const GOLD_COLORS := {
	Color8(132, 76, 8, 255): true,
	Color8(218, 145, 20, 255): true,
	Color8(255, 214, 92, 255): true,
}
const EXPECTED_GOLD_PIXEL_COUNT := 560
const EXPECTED_BLUE_SPELL_PIXEL_COUNT := 364
const EXPECTED_FIREBALL_OPAQUE_PIXEL_COUNT := 1053
const TEST_HEALTH := 1000

var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "FireSorcererEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_contract()
	await _test_enemy_scene_and_defenses()
	await _test_volley_scene_and_magic_damage()
	_test_pixel_contract()

	root.get_node("BurnStatusScheduler").call("clear_all")
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("FIRE_SORCERER_ELITE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	_expect(
		ELITE_CONFIG is FireSorcererEliteConfig,
		"Elite config must use FireSorcererEliteConfig."
	)
	_expect(
		ELITE_CONFIG.display_name == "精英火焰术士",
		"Elite display name mismatch."
	)
	_expect(
		ELITE_CONFIG.enemy_scene == ELITE_SCENE
		and ELITE_CONFIG.enemy_scene != BASE_SCENE,
		"Elite must own an independent enemy scene."
	)
	_expect(
		ELITE_CONFIG.volley_scene == ELITE_VOLLEY_SCENE
		and ELITE_CONFIG.volley_scene != BASE_VOLLEY_SCENE,
		"Elite must own an independent blue-fire volley scene."
	)
	_expect(
		ELITE_CONFIG.max_health == 300,
		"Elite health must be 1.5x the base value: 300."
	)
	_expect(
		ELITE_CONFIG.attack_damage == 70
		and ELITE_CONFIG.attack_damage == BASE_CONFIG.attack_damage + 30,
		"Elite attack damage must remain base + 30 after both lose 10: 70."
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.burn_duration, 5.0)
		and ELITE_CONFIG.burn_level == 10
		and BASE_CONFIG.burn_level == 5,
		"Elite hits must apply five seconds of level-10 burn."
	)
	_expect(
		ELITE_CONFIG.physical_defense == 40,
		"Elite physical defense must be base + 20: 40."
	)
	_expect(
		ELITE_CONFIG.magic_defense == BASE_CONFIG.magic_defense
		and ELITE_CONFIG.magic_defense == 80,
		"Elite magic defense must remain 80."
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.projectile_speed, 115.0)
		and is_equal_approx(
			ELITE_CONFIG.projectile_speed
				- BASE_CONFIG.projectile_speed,
			15.0
		),
		"Elite blue fireballs must be exactly 15 faster: 115."
	)
	_expect(
		is_equal_approx(
			ELITE_CONFIG.move_speed,
			BASE_CONFIG.move_speed
		)
		and is_equal_approx(ELITE_CONFIG.move_speed, 24.0),
		"Elite movement speed must remain 24."
	)
	_expect(
		is_equal_approx(
			ELITE_CONFIG.attack_range,
			BASE_CONFIG.attack_range
		)
		and is_equal_approx(
			ELITE_CONFIG.summon_duration,
			BASE_CONFIG.summon_duration
		)
		and is_equal_approx(
			ELITE_CONFIG.attack_interval,
			BASE_CONFIG.attack_interval
		)
		and is_equal_approx(
			ELITE_CONFIG.initial_attack_stagger_window,
			BASE_CONFIG.initial_attack_stagger_window
		)
		and is_equal_approx(
			ELITE_CONFIG.projectile_lifetime,
			BASE_CONFIG.projectile_lifetime
		)
		and is_equal_approx(
			ELITE_CONFIG.homing_turn_rate,
			BASE_CONFIG.homing_turn_rate
		),
		"Unspecified elite combat timings must remain base-identical."
	)
	_expect(
		ELITE_CONFIG.home_damage == BASE_CONFIG.home_damage
		and ELITE_CONFIG.xirang_kill_reward
			== BASE_CONFIG.xirang_kill_reward
		and ELITE_CONFIG.drop_table == BASE_CONFIG.drop_table
		and ELITE_CONFIG.category_tags == BASE_CONFIG.category_tags,
		"Unspecified elite reward/home/drop values must remain unchanged."
	)


func _test_enemy_scene_and_defenses() -> void:
	var enemy := ELITE_SCENE.instantiate() as FireSorcerer
	_expect(enemy != null, "Elite enemy scene failed to instantiate.")
	if enemy == null:
		return
	test_root.add_child(enemy)
	enemy.setup(ELITE_CONFIG, null, null)
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.hit_audio.stream = null

	var sprite := enemy.get_node_or_null(
		"AnimatedSprite2D"
	) as AnimatedSprite2D
	_expect(
		sprite != null
		and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and sprite.position == Vector2(3.0, -7.0)
		and sprite.scale == Vector2.ONE,
		"Elite character must keep the base native-pixel render transform."
	)
	if sprite != null:
		_expect(
			sprite.sprite_frames.resource_path
				== "res://resources/animation/fire_sorcerer_elite.tres",
			"Elite character must use independent SpriteFrames."
		)
		for animation_name in [&"move", &"windup", &"attack", &"death"]:
			var expected_frame_count := (
				MOVE_FRAME_COUNT if animation_name == &"move" else 4
			)
			_expect(
				sprite.sprite_frames.has_animation(animation_name)
				and sprite.sprite_frames.get_frame_count(
					animation_name
				) == expected_frame_count,
				"Elite character animation %s must contain %d frames."
				% [String(animation_name), expected_frame_count]
			)
		if sprite.sprite_frames.has_animation(&"move"):
			_expect(
				is_equal_approx(
					sprite.sprite_frames.get_animation_speed(&"move"),
					MOVE_ANIMATION_SPEED
				)
				and sprite.sprite_frames.get_animation_loop(&"move"),
				"Elite move must loop at 12 fps."
			)
			for frame_index in range(MOVE_FRAME_COUNT):
				var move_texture := sprite.sprite_frames.get_frame_texture(
					&"move", frame_index
				) as AtlasTexture
				_expect(
					move_texture != null
					and move_texture.atlas != null
					and move_texture.atlas.get_size() == Vector2(320.0, 40.0)
					and move_texture.atlas.resource_path == ELITE_MOVE_TEXTURE_PATH
					and move_texture.region == Rect2(
						float(frame_index * 40), 0.0, 40.0, 40.0
					),
					"Elite move frame %d must use the independent strip."
					% frame_index
				)

	var body_shape := (
		enemy.get_node("CollisionShape2D") as CollisionShape2D
	).shape as CapsuleShape2D
	var touch_shape := (
		enemy.get_node("TouchDamageArea/CollisionShape2D")
		as CollisionShape2D
	).shape as CapsuleShape2D
	_expect(
		body_shape != null
		and touch_shape != null
		and is_equal_approx(body_shape.radius, 5.5)
		and is_equal_approx(body_shape.height, 18.0)
		and is_equal_approx(touch_shape.radius, 5.5)
		and is_equal_approx(touch_shape.height, 18.0),
		"Elite body/touch collision must match the base 5.5×18 capsule."
	)

	var expected_marker_positions := [
		Vector2(24.0, 1.0),
		Vector2(15.0, -5.0),
		Vector2(23.0, 13.0),
	]
	_expect(
		enemy.summon_markers.size() == 3
		and enemy.summon_previews.size() == 3,
		"Elite must scene-author exactly three blue-fire previews."
	)
	for marker_index in range(enemy.summon_markers.size()):
		var marker := enemy.summon_markers[marker_index]
		var preview := enemy.summon_previews[marker_index]
		_expect(
			marker.position == expected_marker_positions[marker_index]
			and preview.position == marker.position,
			"Elite preview %d must preserve the base authored offset."
			% marker_index
		)
		_expect(
			preview.sprite_frames.resource_path
				== "res://resources/animation/fire_sorcerer_elite_fireball.tres",
			"Elite preview %d must use blue-fire SpriteFrames."
			% marker_index
		)
	_expect(
		enemy.call("_get_fireball_projectile_type")
			== &"fire_sorcerer_elite_fireball_volley",
		"Elite enemy must register its independent projectile type."
	)
	_expect(
		enemy.call("_get_touch_damage_type")
			== EnemyConfig.DamageType.MAGIC,
		"Elite body contact must use magic damage."
	)

	enemy.current_health = ELITE_CONFIG.max_health
	enemy.apply_damage(
		100,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL,
		false
	)
	_expect(
		enemy.current_health == 240
		and enemy.last_damage_taken == 60,
		"40 physical defense must reduce 100 physical damage to 60."
	)
	enemy.apply_damage(
		100,
		Vector2.ZERO,
		EnemyConfig.DamageType.MAGIC,
		false
	)
	_expect(
		enemy.current_health == 220
		and enemy.last_damage_taken == 20,
		"80 magic defense must reduce 100 magic damage to 20."
	)

	enemy.queue_free()
	await process_frame


func _test_volley_scene_and_magic_damage() -> void:
	var primary := _spawn_player(Vector2(320.0, 320.0))
	var bystander := _spawn_player(Vector2(320.0, 320.0))
	for player in [primary, bystander]:
		player.magic_defense = 20
		player.physical_defense = 99

	var volley := (
		ELITE_VOLLEY_SCENE.instantiate()
		as FireSorcererFireballVolley
	)
	_expect(volley != null, "Elite blue-fire volley failed to instantiate.")
	if volley == null:
		primary.queue_free()
		bystander.queue_free()
		return
	test_root.add_child(volley)
	volley.setup(
		Vector2.RIGHT,
		ELITE_CONFIG.attack_damage,
		ELITE_CONFIG.projectile_speed,
		ELITE_CONFIG.projectile_lifetime,
		null,
		ELITE_CONFIG.homing_turn_rate
	)
	volley.set_physics_process(false)

	_expect(
		volley.ball_areas.size() == 3
		and volley.ball_sprites.size() == 3
		and volley.active_ball_mask
			== FireSorcererFireballVolley.ALL_BALLS_ACTIVE_MASK,
		"Elite volley must contain exactly three active fireballs."
	)
	_expect(
		volley.damage == 70
		and is_equal_approx(volley.speed, 115.0)
		and is_equal_approx(volley.max_lifetime, 7.0)
		and is_equal_approx(volley.homing_turn_rate, 6.0)
		and is_equal_approx(volley.burn_duration, 5.0)
		and volley.burn_level == 10,
		"Elite volley setup must preserve 70 damage, 115 speed, and level-10 burn."
	)
	_expect(
		volley.call("_get_default_projectile_source_type")
			== &"fire_sorcerer_elite_fireball_volley",
		"Elite volley must restore its independent root source type."
	)
	for ball_index in range(3):
		var area := volley.ball_areas[ball_index]
		var collision := (
			volley.ball_collision_shapes[ball_index].shape
			as CircleShape2D
		)
		_expect(
			area.position
				== [
					Vector2(24.0, 1.0),
					Vector2(15.0, -5.0),
					Vector2(23.0, 13.0),
				][ball_index]
			and area.collision_layer == 128
			and area.collision_mask == 515
			and collision != null
			and is_equal_approx(collision.radius, 3.5)
			and volley.ball_collision_shapes[ball_index].position
				== Vector2(5.0, 0.0),
			"Elite fireball %d must preserve base volume/collision."
			% ball_index
		)
		_expect(
			volley.ball_sprites[ball_index].sprite_frames.resource_path
				== "res://resources/animation/fire_sorcerer_elite_fireball.tres",
			"Elite fireball %d must use independent blue-fire frames."
			% ball_index
		)
		_expect(
			volley.call("_get_ball_source_type", ball_index)
				== [
					&"fire_sorcerer_elite_fireball_a",
					&"fire_sorcerer_elite_fireball_b",
					&"fire_sorcerer_elite_fireball_c",
				][ball_index],
			"Elite fireball %d source identity mismatch." % ball_index
		)

	volley.call("_on_ball_body_entered", primary, 0)
	_expect(
		primary.current_health == TEST_HEALTH - 56
		and primary.last_damage_taken == 56,
		"70 magic damage must become 56 against 20 magic defense."
	)
	var burn_scheduler := root.get_node("BurnStatusScheduler")
	_expect(
		bool(burn_scheduler.call(
			"has_burn",
			primary,
			&"fire_sorcerer_elite_fireball_volley"
		))
		and int(burn_scheduler.call("get_source_count", primary)) == 1,
		"An Elite blue-fire hit must register one Elite burn family."
	)
	_expect(
		bystander.current_health == TEST_HEALTH,
		"Elite blue fireball must remain first-contact only without AOE."
	)
	primary.invincibility_time_left = 0.0
	volley.call("_on_ball_body_entered", primary, 0)
	_expect(
		primary.current_health == TEST_HEALTH - 56,
		"One elite fireball must never damage twice."
	)
	primary.magic_defense = 20
	burn_scheduler.call("_advance_active_burns", 1.01)
	_expect(
		primary.current_health == TEST_HEALTH - 64,
		"Level-10 burn must tick as 8 magic damage against 20 magic defense."
	)

	volley.queue_free()
	primary.queue_free()
	bystander.queue_free()
	await process_frame
	await physics_frame


func _test_pixel_contract() -> void:
	# Read the source PNGs directly. Imported textures apply alpha-border color
	# fixing, which intentionally changes fully transparent RGB values and would
	# make an exact pixel-contract check depend on importer implementation.
	var base_character := Image.load_from_file(
		ProjectSettings.globalize_path(BASE_CHARACTER_TEXTURE_PATH)
	)
	var elite_character := Image.load_from_file(
		ProjectSettings.globalize_path(ELITE_CHARACTER_TEXTURE_PATH)
	)
	var base_move := Image.load_from_file(
		ProjectSettings.globalize_path(BASE_MOVE_TEXTURE_PATH)
	)
	var elite_move := Image.load_from_file(
		ProjectSettings.globalize_path(ELITE_MOVE_TEXTURE_PATH)
	)
	var base_fireball := Image.load_from_file(
		ProjectSettings.globalize_path(BASE_FIREBALL_TEXTURE_PATH)
	)
	var elite_fireball := Image.load_from_file(
		ProjectSettings.globalize_path(ELITE_FIREBALL_TEXTURE_PATH)
	)
	_expect(
		base_character != null
		and elite_character != null
		and base_character.get_size() == Vector2i(160, 160)
		and elite_character.get_size() == Vector2i(160, 160),
		"Elite character sheet must remain 160×160."
	)
	_expect(
		base_move != null
		and elite_move != null
		and base_move.get_size() == Vector2i(320, 40)
		and elite_move.get_size() == Vector2i(320, 40),
		"Base and Elite move strips must remain independent 320×40 textures."
	)
	_expect(
		base_fireball != null
		and elite_fireball != null
		and base_fireball.get_size() == Vector2i(128, 128)
		and elite_fireball.get_size() == Vector2i(128, 128),
		"Elite blue-fire sheet must remain 128×128."
	)
	if (
		base_character == null
		or elite_character == null
		or base_move == null
		or elite_move == null
		or base_fireball == null
		or elite_fireball == null
	):
		return

	var changed_character_pixels := 0
	var gold_pixels := 0
	var blue_spell_pixels := 0
	for y in range(160):
		for x in range(160):
			var base_pixel := base_character.get_pixel(x, y)
			var elite_pixel := elite_character.get_pixel(x, y)
			_expect(
				is_equal_approx(base_pixel.a, elite_pixel.a),
				"Elite character alpha changed at %d,%d." % [x, y]
			)
			if base_pixel == elite_pixel:
				continue
			changed_character_pixels += 1
			if GOLD_COLORS.has(elite_pixel):
				gold_pixels += 1
			else:
				blue_spell_pixels += 1
	_expect(
		changed_character_pixels
			== EXPECTED_GOLD_PIXEL_COUNT
				+ EXPECTED_BLUE_SPELL_PIXEL_COUNT
		and gold_pixels == EXPECTED_GOLD_PIXEL_COUNT
		and blue_spell_pixels == EXPECTED_BLUE_SPELL_PIXEL_COUNT,
		"Elite character changes must equal the approved gold/blue overlays."
	)

	var changed_move_pixels := 0
	for y in range(40):
		for x in range(320):
			var base_move_pixel := base_move.get_pixel(x, y)
			var elite_move_pixel := elite_move.get_pixel(x, y)
			_expect(
				is_equal_approx(base_move_pixel.a, elite_move_pixel.a),
				"Elite move alpha changed at %d,%d." % [x, y]
			)
			if base_move_pixel != elite_move_pixel:
				changed_move_pixels += 1
	_expect(
		changed_move_pixels > 0,
		"Elite move must retain visible gold/blue differentiation."
	)

	var fireball_opaque_pixels := 0
	for y in range(128):
		for x in range(128):
			var base_pixel := base_fireball.get_pixel(x, y)
			var elite_pixel := elite_fireball.get_pixel(x, y)
			_expect(
				is_equal_approx(base_pixel.a, elite_pixel.a),
				"Elite fireball alpha changed at %d,%d." % [x, y]
			)
			if elite_pixel.a <= 0.0:
				continue
			fireball_opaque_pixels += 1
			_expect(
				elite_pixel.b >= elite_pixel.r
				and elite_pixel.g >= elite_pixel.r,
				"Elite fireball pixel is not blue/cyan at %d,%d."
				% [x, y]
			)
	_expect(
		fireball_opaque_pixels == EXPECTED_FIREBALL_OPAQUE_PIXEL_COUNT,
		"Elite blue-fire opaque pixel count must remain base-identical."
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
	_expect(
		is_equal_approx(PLAYER_CONFIG.starting_move_speed, 120.0),
		"Player speed fixture changed unexpectedly."
	)
	return player


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
