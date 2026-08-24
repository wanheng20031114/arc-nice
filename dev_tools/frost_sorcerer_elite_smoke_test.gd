extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer_elite.tres"
)
const BASE_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const ELITE_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer_elite.tscn"
)
const BASE_SCENE := preload(
	"res://scene/enemy/sorcerer/frost_sorcerer.tscn"
)
const COMBAT_RUNTIME_FIXTURE := preload(
	"res://dev_tools/fixtures/enemy_gameplay_gateway_test_runtime.tscn"
)

const BASE_TEXTURE_PATH := "res://resources/texture/enemy/sorcerer/frost_sorcerer.png"
const ELITE_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/frost_sorcerer_elite.png"
)
const BASE_MOVE_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/frost_sorcerer_move.png"
)
const ELITE_MOVE_TEXTURE_PATH := (
	"res://resources/texture/enemy/sorcerer/frost_sorcerer_elite_move.png"
)
const EXPECTED_CHANGED_PIXEL_COUNT := 1594
const MOVE_FRAME_COUNT := 8
const MOVE_ANIMATION_SPEED := 12.0
const MOVE_GROUND_Y := 38
const MAX_MOVE_CENTROID_X_DRIFT := 1.0
const CYAN_PALETTE_MAP := {
	Color8(30, 145, 201, 255): Color8(12, 205, 220, 255),
	Color8(90, 158, 192, 255): Color8(8, 166, 190, 255),
	Color8(86, 200, 242, 255): Color8(35, 236, 242, 255),
	Color8(84, 217, 251, 255): Color8(69, 246, 250, 255),
	Color8(126, 224, 251, 255): Color8(184, 251, 255, 255),
	Color8(181, 234, 249, 255): Color8(222, 254, 255, 255),
}

var failures: Array[String] = []
var test_root: EnemyGameplayGatewayTestRuntime = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = (
		COMBAT_RUNTIME_FIXTURE.instantiate()
		as EnemyGameplayGatewayTestRuntime
	)
	test_root.name = "FrostSorcererEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_contract()
	await _test_scene_and_projectile_values()
	_test_pixel_contract()

	test_root.prepare_for_scene_teardown()
	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("FROST_SORCERER_ELITE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	_expect(
		ELITE_CONFIG is FrostSorcererEliteConfig,
		"Elite config must use FrostSorcererEliteConfig."
	)
	_expect(
		ELITE_CONFIG.display_name == "精英冰霜术士",
		"Elite display name mismatch."
	)
	_expect(
		ELITE_CONFIG.enemy_scene == ELITE_SCENE
		and ELITE_CONFIG.enemy_scene != BASE_SCENE,
		"Elite Frost Sorcerer must own an independent enemy scene."
	)
	_expect(
		ELITE_CONFIG.max_health == BASE_CONFIG.max_health + 100
		and ELITE_CONFIG.max_health == 300,
		"Elite health must be base + 100: 300."
	)
	_expect(
		ELITE_CONFIG.attack_damage == BASE_CONFIG.attack_damage + 30
		and ELITE_CONFIG.attack_damage == 80,
		"Elite attack damage must be base + 30: 80."
	)
	_expect(
		is_equal_approx(
			ELITE_CONFIG.attack_interval,
			BASE_CONFIG.attack_interval - 1.0
		)
		and is_equal_approx(ELITE_CONFIG.attack_interval, 2.0),
		"Elite attack cooldown must be exactly one second shorter: 2.0."
	)
	_expect(
		is_equal_approx(
			ELITE_CONFIG.projectile_speed,
			BASE_CONFIG.projectile_speed + 25.0
		)
		and is_equal_approx(ELITE_CONFIG.projectile_speed, 125.0),
		"Elite ice-spike speed must be base + 25: 125."
	)
	_expect(
		ELITE_CONFIG.ice_spike_scene == BASE_CONFIG.ice_spike_scene,
		"Elite must reuse the established ice-spike behavior and visuals."
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.attack_range, BASE_CONFIG.attack_range)
		and is_equal_approx(
			ELITE_CONFIG.summon_duration,
			BASE_CONFIG.summon_duration
		)
		and is_equal_approx(
			ELITE_CONFIG.initial_attack_stagger_window,
			BASE_CONFIG.initial_attack_stagger_window
		)
		and is_equal_approx(
			ELITE_CONFIG.projectile_lifetime,
			BASE_CONFIG.projectile_lifetime
		)
		and ELITE_CONFIG.physical_defense == BASE_CONFIG.physical_defense
		and ELITE_CONFIG.magic_defense == BASE_CONFIG.magic_defense
		and is_equal_approx(ELITE_CONFIG.move_speed, BASE_CONFIG.move_speed)
		and ELITE_CONFIG.home_damage == BASE_CONFIG.home_damage
		and ELITE_CONFIG.xirang_kill_reward == BASE_CONFIG.xirang_kill_reward
		and ELITE_CONFIG.drop_table == BASE_CONFIG.drop_table
		and ELITE_CONFIG.category_tags == BASE_CONFIG.category_tags,
		"Unspecified elite values must remain base-identical."
	)


func _test_scene_and_projectile_values() -> void:
	var enemy := ELITE_SCENE.instantiate() as FrostSorcerer
	var base_enemy := BASE_SCENE.instantiate() as FrostSorcerer
	_expect(enemy != null, "Elite scene must instantiate FrostSorcerer.")
	_expect(base_enemy != null, "Base Frost Sorcerer fixture must instantiate.")
	if enemy == null or base_enemy == null:
		if enemy != null:
			enemy.free()
		if base_enemy != null:
			base_enemy.free()
		return

	var sprite := enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var base_sprite := (
		base_enemy.get_node("AnimatedSprite2D") as AnimatedSprite2D
	)
	_expect(
		sprite.sprite_frames != base_sprite.sprite_frames
		and sprite.sprite_frames.resource_path
		== "res://resources/animation/frost_sorcerer_elite.tres",
		"Elite character must use independent SpriteFrames."
	)
	_expect(
		sprite.position == base_sprite.position
		and sprite.scale == base_sprite.scale
		and sprite.texture_filter == base_sprite.texture_filter,
		"Elite render transform must remain base-identical."
	)
	_expect_character_animation_contract(
		sprite.sprite_frames,
		ELITE_MOVE_TEXTURE_PATH,
		"Elite Frost Sorcerer"
	)
	_expect_character_animation_contract(
		base_sprite.sprite_frames,
		BASE_MOVE_TEXTURE_PATH,
		"Base Frost Sorcerer"
	)
	var preview := (
		enemy.get_node("SummonPivot/IceSpikePreview") as AnimatedSprite2D
	)
	var base_preview := (
		base_enemy.get_node("SummonPivot/IceSpikePreview")
		as AnimatedSprite2D
	)
	_expect(
		preview.sprite_frames == base_preview.sprite_frames
		and preview.position == base_preview.position,
		"Elite preview must reuse the approved ice-spike frames and offset."
	)
	_expect(
		enemy.call("_get_ice_spike_projectile_type")
		== &"frost_sorcerer_ice_spike",
		"Reused ice spikes must keep the established network projectile type."
	)
	_expect(
		_capsule_matches(enemy, base_enemy, NodePath("CollisionShape2D"))
		and _capsule_matches(
			enemy,
			base_enemy,
			NodePath("TouchDamageArea/CollisionShape2D")
		),
		"Elite body and touch capsules must remain base-identical."
	)

	test_root.add_child(enemy)
	enemy.setup(ELITE_CONFIG, null, null, test_root)
	enemy.set_physics_process(false)
	var summon_target := Node2D.new()
	summon_target.name = "EliteSummonTarget"
	test_root.add_child(summon_target)
	summon_target.global_position = Vector2(100.0, 0.0)
	enemy.summon_target = summon_target
	_expect(
		enemy.current_health == 300
		and enemy.config == ELITE_CONFIG
		and enemy.config.max_health == 300,
		"Elite setup must apply 300 health."
	)
	enemy.summon_direction = Vector2.RIGHT
	enemy.call("_finish_summon_and_fire", ELITE_CONFIG)
	var spike := _find_spawned_spike()
	_expect(spike != null, "Elite attack must spawn one ice spike.")
	if spike != null:
		spike.set_physics_process(false)
		_expect(
			spike.damage == 80
			and is_equal_approx(spike.speed, 125.0)
			and is_equal_approx(spike.max_lifetime, 7.0)
			and spike.source_type == &"frost_sorcerer_ice_spike",
			"Elite ice spike must carry 80 damage and 125 speed."
		)
	_expect(
		is_equal_approx(enemy.attack_cooldown_left, 2.0),
		"Elite cooldown must begin at 2.0 after the spike is created."
	)

	base_enemy.free()
	if spike != null:
		spike.queue_free()
	enemy.queue_free()
	summon_target.queue_free()
	await process_frame


func _capsule_matches(
	elite_enemy: Node,
	base_enemy: Node,
	path: NodePath
) -> bool:
	var elite_node := elite_enemy.get_node(path) as CollisionShape2D
	var base_node := base_enemy.get_node(path) as CollisionShape2D
	var elite_shape := elite_node.shape as CapsuleShape2D
	var base_shape := base_node.shape as CapsuleShape2D
	return (
		elite_shape != null
		and base_shape != null
		and elite_shape != base_shape
		and is_equal_approx(elite_shape.radius, base_shape.radius)
		and is_equal_approx(elite_shape.height, base_shape.height)
		and elite_node.position == base_node.position
	)


func _find_spawned_spike() -> FrostSorcererIceSpike:
	for child in test_root.get_children():
		var spike := child as FrostSorcererIceSpike
		if spike != null:
			return spike
	return null


func _test_pixel_contract() -> void:
	var base := Image.load_from_file(
		ProjectSettings.globalize_path(BASE_TEXTURE_PATH)
	)
	var elite := Image.load_from_file(
		ProjectSettings.globalize_path(ELITE_TEXTURE_PATH)
	)
	_expect(
		base != null
		and elite != null
		and base.get_size() == Vector2i(160, 160)
		and elite.get_size() == Vector2i(160, 160),
		"Base and Elite Frost Sorcerer atlases must remain 160×160."
	)
	if base == null or elite == null:
		return
	if (
		base.get_size() != Vector2i(160, 160)
		or elite.get_size() != Vector2i(160, 160)
	):
		return

	var changed_pixels := 0
	for y in range(160):
		for x in range(160):
			var base_pixel := base.get_pixel(x, y)
			var elite_pixel := elite.get_pixel(x, y)
			_expect(
				is_equal_approx(base_pixel.a, elite_pixel.a),
				"Elite alpha changed at %d,%d." % [x, y]
			)
			if base_pixel == elite_pixel:
				continue
			changed_pixels += 1
			_expect(
				CYAN_PALETTE_MAP.has(base_pixel)
				and CYAN_PALETTE_MAP[base_pixel] == elite_pixel,
				"Elite cyan mapping escaped its approved palette at %d,%d."
				% [x, y]
			)
	_expect(
		changed_pixels == EXPECTED_CHANGED_PIXEL_COUNT,
		"Elite atlas must contain exactly %d cyan/pale-cyan pixels."
		% EXPECTED_CHANGED_PIXEL_COUNT
	)

	var base_move := Image.load_from_file(
		ProjectSettings.globalize_path(BASE_MOVE_TEXTURE_PATH)
	)
	var elite_move := Image.load_from_file(
		ProjectSettings.globalize_path(ELITE_MOVE_TEXTURE_PATH)
	)
	_expect(
		base_move != null
		and elite_move != null
		and base_move.get_size() == Vector2i(320, 40)
		and elite_move.get_size() == Vector2i(320, 40),
		"Base and Elite move strips must remain independent 320x40 textures."
	)
	if (
		base_move == null
		or elite_move == null
		or base_move.get_size() != Vector2i(320, 40)
		or elite_move.get_size() != Vector2i(320, 40)
	):
		return
	var changed_move_pixels := 0
	for y in range(40):
		for x in range(320):
			var base_move_pixel := base_move.get_pixel(x, y)
			var elite_move_pixel := elite_move.get_pixel(x, y)
			_expect(
				is_equal_approx(base_move_pixel.a, elite_move_pixel.a),
				"Elite move alpha changed at %d,%d." % [x, y]
			)
			if base_move_pixel == elite_move_pixel:
				continue
			changed_move_pixels += 1
			_expect(
				CYAN_PALETTE_MAP.has(base_move_pixel)
				and CYAN_PALETTE_MAP[base_move_pixel] == elite_move_pixel,
				"Elite move cyan mapping escaped its approved palette at %d,%d."
				% [x, y]
			)
	_expect(
		changed_move_pixels > 0,
		"Elite move strip must contain visible approved cyan differentiation."
	)


func _expect_character_animation_contract(
	frames: SpriteFrames,
	move_texture_path: String,
	label: String
) -> void:
	_expect(frames != null, "%s SpriteFrames resource is missing." % label)
	if frames == null:
		return

	_expect(frames.has_animation(&"move"), "%s move animation is missing." % label)
	if frames.has_animation(&"move"):
		_expect(
			frames.get_frame_count(&"move") == MOVE_FRAME_COUNT,
			"%s move animation must contain eight authored frames." % label
		)
		_expect(
			is_equal_approx(
				frames.get_animation_speed(&"move"),
				MOVE_ANIMATION_SPEED
			)
			and frames.get_animation_loop(&"move"),
			"%s move animation must loop at 12 fps." % label
		)
		var centroid_x_values: Array[float] = []
		var frame_zero_metrics: Dictionary = {}
		for frame_index in range(frames.get_frame_count(&"move")):
			var texture := frames.get_frame_texture(
				&"move",
				frame_index
			) as AtlasTexture
			var has_unit_duration := is_equal_approx(
				frames.get_frame_duration(&"move", frame_index),
				1.0
			)
			_expect(
				texture != null
				and texture.get_size() == Vector2(40.0, 40.0)
				and texture.atlas != null
				and texture.atlas.get_size() == Vector2(320.0, 40.0)
				and texture.atlas.resource_path == move_texture_path
				and texture.region == Rect2(
					float(frame_index * 40),
					0.0,
					40.0,
					40.0
				)
				and has_unit_duration,
				"%s move frame %d must use cell %d of the independent 320x40 strip."
				% [label, frame_index, frame_index]
			)
			if texture == null or texture.atlas == null:
				continue
			var metrics := _atlas_alpha_metrics(texture)
			_expect(
				int(metrics.get("visible_pixels", 0)) > 0,
				"%s move frame %d must not be empty." % [label, frame_index]
			)
			_expect(
				int(metrics.get("bottom_y", -1)) == MOVE_GROUND_Y,
				"%s move frame %d must share foot baseline y=%d."
				% [label, frame_index, MOVE_GROUND_Y]
			)
			if int(metrics.get("visible_pixels", 0)) > 0:
				centroid_x_values.append(float(metrics["centroid_x"]))
			if frame_index == 0:
				frame_zero_metrics = metrics
		if centroid_x_values.size() == MOVE_FRAME_COUNT:
			var minimum_centroid_x := centroid_x_values[0]
			var maximum_centroid_x := centroid_x_values[0]
			for centroid_x in centroid_x_values:
				minimum_centroid_x = minf(minimum_centroid_x, centroid_x)
				maximum_centroid_x = maxf(maximum_centroid_x, centroid_x)
			_expect(
				maximum_centroid_x - minimum_centroid_x
				<= MAX_MOVE_CENTROID_X_DRIFT + 0.001,
				(
					"%s move alpha centroid must drift no more than %.1f px "
					+ "horizontally; saw %.3f px."
				)
				% [
					label,
					MAX_MOVE_CENTROID_X_DRIFT,
					maximum_centroid_x - minimum_centroid_x,
				]
			)
		if not frame_zero_metrics.is_empty():
			_expect(
				int(frame_zero_metrics.get("ground_contact_groups", 0)) >= 2
				and int(frame_zero_metrics.get("ground_contact_pixels", 0)) >= 6
				and int(frame_zero_metrics.get("ground_contact_span", 0)) >= 8,
				(
					"%s move frame 0 must be a naturally grounded contact pose "
					+ "with two separated feet."
				)
				% label
			)

	for animation_name in [&"windup", &"attack", &"death"]:
		_expect(
			frames.has_animation(animation_name)
			and frames.get_frame_count(animation_name) == 4,
			"%s %s animation must contain four frames."
			% [label, String(animation_name)]
		)
		if not frames.has_animation(animation_name):
			continue
		for frame_index in range(frames.get_frame_count(animation_name)):
			var texture := frames.get_frame_texture(
				animation_name,
				frame_index
			) as AtlasTexture
			_expect(
				texture != null
				and texture.get_size() == Vector2(40.0, 40.0)
				and texture.atlas != null
				and texture.atlas.get_size() == Vector2(160.0, 160.0)
				and int(
					_atlas_alpha_metrics(texture).get("visible_pixels", 0)
				) > 0,
				(
					"%s %s frame %d must remain a native 40x40 cell "
					+ "in the 160x160 character atlas."
				)
				% [label, String(animation_name), frame_index]
			)


func _atlas_alpha_metrics(texture: AtlasTexture) -> Dictionary:
	var atlas_image := texture.atlas.get_image()
	if atlas_image == null:
		return {}
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
	if (
		region.position.x < 0
		or region.position.y < 0
		or region.end.x > atlas_image.get_width()
		or region.end.y > atlas_image.get_height()
	):
		return {}
	var alpha_total := 0.0
	var weighted_x := 0.0
	var visible_pixels := 0
	var bottom_y := -1
	for local_y in range(region.size.y):
		for local_x in range(region.size.x):
			var alpha := atlas_image.get_pixel(
				region.position.x + local_x,
				region.position.y + local_y
			).a
			if alpha <= 0.0:
				continue
			visible_pixels += 1
			alpha_total += alpha
			weighted_x += float(local_x) * alpha
			bottom_y = maxi(bottom_y, local_y)
	if alpha_total <= 0.0:
		return {
			"visible_pixels": 0,
			"bottom_y": -1,
		}

	var ground_contact_groups := 0
	var ground_contact_pixels := 0
	var ground_min_x := region.size.x
	var ground_max_x := -1
	var previous_was_visible := false
	for local_x in range(region.size.x):
		var is_visible := atlas_image.get_pixel(
			region.position.x + local_x,
			region.position.y + bottom_y
		).a > 0.0
		if is_visible:
			ground_contact_pixels += 1
			ground_min_x = mini(ground_min_x, local_x)
			ground_max_x = maxi(ground_max_x, local_x)
			if not previous_was_visible:
				ground_contact_groups += 1
		previous_was_visible = is_visible
	return {
		"visible_pixels": visible_pixels,
		"centroid_x": weighted_x / alpha_total,
		"bottom_y": bottom_y,
		"ground_contact_groups": ground_contact_groups,
		"ground_contact_pixels": ground_contact_pixels,
		"ground_contact_span": (
			ground_max_x - ground_min_x + 1 if ground_max_x >= 0 else 0
		),
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
