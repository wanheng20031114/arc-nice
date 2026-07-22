extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer_elite.tres"
)
const BASE_CONFIG := preload(
	"res://resources/config/enemies/frost_sorcerer.tres"
)
const ELITE_SCENE := preload(
	"res://scene/enemy/frost_sorcerer_elite.tscn"
)
const BASE_SCENE := preload(
	"res://scene/enemy/frost_sorcerer.tscn"
)

const BASE_TEXTURE_PATH := "res://resources/texture/frost_sorcerer.png"
const ELITE_TEXTURE_PATH := (
	"res://resources/texture/frost_sorcerer_elite.png"
)
const EXPECTED_CHANGED_PIXEL_COUNT := 1594
const CYAN_PALETTE_MAP := {
	Color8(30, 145, 201, 255): Color8(12, 205, 220, 255),
	Color8(90, 158, 192, 255): Color8(8, 166, 190, 255),
	Color8(86, 200, 242, 255): Color8(35, 236, 242, 255),
	Color8(84, 217, 251, 255): Color8(69, 246, 250, 255),
	Color8(126, 224, 251, 255): Color8(184, 251, 255, 255),
	Color8(181, 234, 249, 255): Color8(222, 254, 255, 255),
}

var failures: Array[String] = []
var test_root: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "FrostSorcererEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_config_contract()
	await _test_scene_and_projectile_values()
	_test_pixel_contract()

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
		ELITE_CONFIG.attack_damage == BASE_CONFIG.attack_damage + 20
		and ELITE_CONFIG.attack_damage == 40,
		"Elite attack damage must be base + 20: 40."
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
		and ELITE_CONFIG.drop_tags == BASE_CONFIG.drop_tags,
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
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		_expect(
			sprite.sprite_frames.has_animation(animation_name)
			and sprite.sprite_frames.get_frame_count(animation_name) == 4,
			"Elite %s animation must contain four frames."
			% String(animation_name)
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
	enemy.setup(ELITE_CONFIG, null, null)
	enemy.set_physics_process(false)
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
			spike.damage == 40
			and is_equal_approx(spike.speed, 125.0)
			and is_equal_approx(spike.max_lifetime, 7.0)
			and spike.source_type == &"frost_sorcerer_ice_spike",
			"Elite ice spike must carry 40 damage and 125 speed."
		)
	_expect(
		is_equal_approx(enemy.attack_cooldown_left, 2.0),
		"Elite cooldown must begin at 2.0 after the spike is created."
	)

	base_enemy.free()
	if spike != null:
		spike.queue_free()
	enemy.queue_free()
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


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
