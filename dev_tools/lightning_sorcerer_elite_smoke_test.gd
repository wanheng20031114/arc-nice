extends SceneTree

const ELITE_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer_elite.tres"
)
const BASE_CONFIG := preload(
	"res://resources/config/enemies/lightning_sorcerer.tres"
)
const ELITE_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_elite.tscn"
)
const BASE_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer.tscn"
)
const PLAYER_SCENE := preload(
	"res://scene/player/weishidaier/player_weishidaier.tscn"
)
const TargetWarningScript := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_target_warning.gd"
)

const BASE_TEXTURE_PATH := "res://resources/texture/lightning_sorcerer.png"
const ELITE_TEXTURE_PATH := (
	"res://resources/texture/lightning_sorcerer_elite.png"
)
const BASE_MOVE_TEXTURE_PATH := (
	"res://resources/texture/lightning_sorcerer_move.png"
)
const ELITE_MOVE_TEXTURE_PATH := (
	"res://resources/texture/lightning_sorcerer_elite_move.png"
)
const ELITE_ANIMATION_PATH := (
	"res://resources/animation/lightning_sorcerer_elite.tres"
)
const TEST_HEALTH := 1000
const EXPECTED_ATTACK_RANGE := 7.0 * 16.0
const EXPECTED_CHAIN_RANGE := 4.0 * 16.0
const MOVE_FRAME_COUNT := 8
const MOVE_ANIMATION_SPEED := 12.0
const EXPECTED_ATLAS_CHANGED_PIXELS := 762
const EXPECTED_MOVE_CHANGED_PIXELS := 327
const EXPECTED_ATLAS_CHANGED_PER_FRAME: Array[int] = [
	49, 43, 58, 48,
	48, 52, 65, 48,
	49, 27, 37, 48,
	44, 39, 69, 38,
]
const EXPECTED_MOVE_CHANGED_PER_FRAME: Array[int] = [
	54, 42, 41, 48, 41, 24, 31, 46,
]
const APPROVED_PURPLE_RGB := {
	0x44146D: true,
	0x6D27AF: true,
}
const APPROVED_YELLOW_EDGE_RGB := {
	0x9A7121: true,
	0xDFB82A: true,
	0xF8D838: true,
	0xFBE246: true,
	0xFDEC50: true,
	0xF8EFAB: true,
	0xFDF9AD: true,
}


class TargetRuntime:
	extends Node2D

	var candidates: Array[Node2D] = []
	var query_count := 0


	func find_nearest_enemy_attack_target_world(
		from_position: Vector2,
		max_distance: float,
		excluded_instance_ids: Dictionary = {}
	) -> Node2D:
		query_count += 1
		var nearest: Node2D = null
		var nearest_distance_squared := max_distance * max_distance
		var nearest_instance_id := 0
		for candidate in candidates:
			if candidate == null or not is_instance_valid(candidate):
				continue
			var instance_id := int(candidate.get_instance_id())
			if excluded_instance_ids.has(instance_id):
				continue
			var player := candidate as Player
			if player == null or player.is_dead:
				continue
			var distance_squared := from_position.distance_squared_to(
				candidate.global_position
			)
			if distance_squared > nearest_distance_squared:
				continue
			if (
				nearest == null
				or distance_squared < nearest_distance_squared
				or (
					is_equal_approx(
						distance_squared,
						nearest_distance_squared
					)
					and instance_id < nearest_instance_id
				)
			):
				nearest = candidate
				nearest_distance_squared = distance_squared
				nearest_instance_id = instance_id
		return nearest


var failures: Array[String] = []
var fixture: Node2D = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "LightningSorcererEliteSmokeTest"
	root.add_child(fixture)
	current_scene = fixture

	_test_config_contract()
	_test_scene_and_animation_contract()
	await _test_five_target_chain()
	await _test_windup_and_cooldown()
	_test_pixel_contract()

	current_scene = null
	fixture.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("LIGHTNING_SORCERER_ELITE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_config_contract() -> void:
	_expect(
		ELITE_CONFIG is LightningSorcererEliteConfig,
		"Elite config must use LightningSorcererEliteConfig."
	)
	_expect(
		ELITE_CONFIG.display_name == "精英雷电术士",
		"Elite display name mismatch."
	)
	_expect(
		ELITE_CONFIG.enemy_scene == ELITE_SCENE
		and ELITE_CONFIG.enemy_scene != BASE_SCENE,
		"Elite Lightning Sorcerer must own an independent enemy scene."
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
		is_equal_approx(ELITE_CONFIG.attack_range, EXPECTED_ATTACK_RANGE)
		and is_equal_approx(ELITE_CONFIG.attack_range, BASE_CONFIG.attack_range)
		and is_equal_approx(ELITE_CONFIG.chain_range, EXPECTED_CHAIN_RANGE)
		and is_equal_approx(
			ELITE_CONFIG.chain_range,
			BASE_CONFIG.chain_range + 16.0
		)
		and ELITE_CONFIG.max_chain_bounces == 4,
		"Elite must attack at seven cells and chain four times within four cells."
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.windup_duration, 0.6)
		and is_equal_approx(
			ELITE_CONFIG.windup_duration,
			BASE_CONFIG.windup_duration
		),
		"Elite windup must remain 0.6 seconds."
	)
	_expect(
		ELITE_CONFIG.physical_defense == BASE_CONFIG.physical_defense
		and ELITE_CONFIG.magic_defense == BASE_CONFIG.magic_defense
		and is_equal_approx(ELITE_CONFIG.move_speed, BASE_CONFIG.move_speed)
		and ELITE_CONFIG.home_damage == BASE_CONFIG.home_damage
		and ELITE_CONFIG.xirang_kill_reward == BASE_CONFIG.xirang_kill_reward
		and ELITE_CONFIG.drop_table == BASE_CONFIG.drop_table
		and ELITE_CONFIG.category_tags == BASE_CONFIG.category_tags
		and is_equal_approx(
			ELITE_CONFIG.initial_attack_stagger_window,
			BASE_CONFIG.initial_attack_stagger_window
		),
		"Unspecified elite values must remain base-identical."
	)


func _test_scene_and_animation_contract() -> void:
	var enemy := ELITE_SCENE.instantiate() as LightningSorcerer
	var base_enemy := BASE_SCENE.instantiate() as LightningSorcerer
	_expect(enemy != null, "Elite scene must instantiate LightningSorcerer.")
	_expect(base_enemy != null, "Base Lightning Sorcerer fixture must instantiate.")
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
		and sprite.sprite_frames.resource_path == ELITE_ANIMATION_PATH,
		"Elite character must use independent SpriteFrames."
	)
	_expect(
		sprite.position == base_sprite.position
		and sprite.scale == base_sprite.scale
		and sprite.texture_filter == base_sprite.texture_filter,
		"Elite render transform must remain base-identical."
	)
	_expect_animation_contract(
		sprite.sprite_frames,
		ELITE_TEXTURE_PATH,
		ELITE_MOVE_TEXTURE_PATH,
		"Elite Lightning Sorcerer"
	)
	_expect_animation_contract(
		base_sprite.sprite_frames,
		BASE_TEXTURE_PATH,
		BASE_MOVE_TEXTURE_PATH,
		"Base Lightning Sorcerer"
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
	var staff_tip := enemy.get_node("CastPivot/StaffTip") as Marker2D
	var base_staff_tip := base_enemy.get_node("CastPivot/StaffTip") as Marker2D
	_expect(
		staff_tip.position == base_staff_tip.position
		and staff_tip.position == Vector2(24.0, 1.0),
		"Elite staff endpoint must remain base-identical."
	)

	enemy.free()
	base_enemy.free()


func _test_five_target_chain() -> void:
	var runtime := _create_runtime("EliteFiveTargetChain")
	var targets: Array[Player] = []
	for target_index in range(6):
		targets.append(_spawn_player(
			runtime,
			Vector2(100.0 + float(target_index) * EXPECTED_CHAIN_RANGE, 0.0)
		))
	runtime.candidates.assign(targets)
	var enemy := _spawn_enemy(runtime, targets[0])
	var world_path := enemy.call(
		"_resolve_chain_hits",
		targets[0],
		ELITE_CONFIG,
		enemy.call("_get_multiplayer_damage_source_id", 1)
	) as PackedVector2Array

	_expect(
		world_path.size() == 6,
		"Initial hit plus four bounces must hit at most five targets."
	)
	for target_index in range(5):
		_expect(
			targets[target_index].current_health == TEST_HEALTH - 80,
			"Elite chain target %d must take the full 80 magic damage."
			% target_index
		)
	_expect(
		targets[5].current_health == TEST_HEALTH,
		"The sixth candidate must remain untouched after four bounces."
	)
	for path_index in range(2, world_path.size()):
		_expect(
			is_equal_approx(
				world_path[path_index - 1].distance_to(world_path[path_index]),
				EXPECTED_CHAIN_RANGE
			),
			"A target exactly four cells away must remain chainable."
		)
	_expect(
		runtime.query_count == 4,
		"One completed elite chain must perform exactly four follow-up queries."
	)
	runtime.queue_free()
	await process_frame


func _test_windup_and_cooldown() -> void:
	var runtime := _create_runtime("EliteWindup")
	var target := _spawn_player(runtime, Vector2(100.0, 0.0))
	runtime.candidates.append(target)
	var enemy := _spawn_enemy(runtime, target)
	var target_warning := enemy.get_node("TargetWarning") as TargetWarningScript
	enemy.initial_attack_stagger_left = 0.0
	_expect(
		bool(enemy.call("_try_start_windup", target, ELITE_CONFIG)),
		"An unobstructed target inside seven cells must start the elite windup."
	)
	_expect(
		is_equal_approx(enemy.windup_time_left, 0.6)
		and target.current_health == TEST_HEALTH
		and target_warning.is_warning_active()
		and is_equal_approx(
			target_warning.get_chain_danger_radius(),
			EXPECTED_CHAIN_RANGE
		),
		"Elite windup must warn for 0.6 seconds with a four-cell chain radius."
	)
	enemy.call("_update_windup", 0.59)
	_expect(
		target.current_health == TEST_HEALTH,
		"Elite windup must not deal damage before 0.6 seconds."
	)
	enemy.call("_update_windup", 0.02)
	_expect(
		target.current_health == TEST_HEALTH - 80
		and enemy.combat_state == LightningSorcerer.CombatState.CHASE
		and is_equal_approx(enemy.attack_cooldown_left, 2.0),
		"Elite strike must deal 80 damage and begin its two-second cooldown."
	)
	runtime.queue_free()
	await process_frame


func _test_pixel_contract() -> void:
	var atlas_metrics := _compare_texture_pair(
		BASE_TEXTURE_PATH,
		ELITE_TEXTURE_PATH,
		Vector2i(160, 160),
		"character atlas"
	)
	var move_metrics := _compare_texture_pair(
		BASE_MOVE_TEXTURE_PATH,
		ELITE_MOVE_TEXTURE_PATH,
		Vector2i(320, 40),
		"move strip"
	)
	_expect(
		int(atlas_metrics.get("changed_pixels", 0))
		== EXPECTED_ATLAS_CHANGED_PIXELS,
		"Elite character atlas must contain exactly %d approved purple pixels."
		% EXPECTED_ATLAS_CHANGED_PIXELS
	)
	_expect(
		int(move_metrics.get("changed_pixels", 0))
		== EXPECTED_MOVE_CHANGED_PIXELS,
		"Elite move strip must contain exactly %d approved purple pixels."
		% EXPECTED_MOVE_CHANGED_PIXELS
	)
	_expect_edge_frame_contract(
		atlas_metrics,
		EXPECTED_ATLAS_CHANGED_PER_FRAME,
		"character atlas"
	)
	_expect_edge_frame_contract(
		move_metrics,
		EXPECTED_MOVE_CHANGED_PER_FRAME,
		"move strip"
	)


func _compare_texture_pair(
	base_path: String,
	elite_path: String,
	expected_size: Vector2i,
	label: String
) -> Dictionary:
	var base := Image.load_from_file(ProjectSettings.globalize_path(base_path))
	var elite := Image.load_from_file(ProjectSettings.globalize_path(elite_path))
	_expect(
		base != null
		and elite != null
		and base.get_size() == expected_size
		and elite.get_size() == expected_size,
		"Base and Elite Lightning Sorcerer %s must remain %dx%d."
		% [label, expected_size.x, expected_size.y]
	)
	if (
		base == null
		or elite == null
		or base.get_size() != expected_size
		or elite.get_size() != expected_size
	):
		return {}

	var frame_columns := int(expected_size.x / 40)
	var frame_rows := int(expected_size.y / 40)
	var changed_per_frame: Array[int] = []
	changed_per_frame.resize(frame_columns * frame_rows)
	var changed_pixels := 0
	for y in range(expected_size.y):
		for x in range(expected_size.x):
			var base_pixel := base.get_pixel(x, y)
			var elite_pixel := elite.get_pixel(x, y)
			var frame_index := int(y / 40) * frame_columns + int(x / 40)
			_expect(
				is_equal_approx(base_pixel.a, elite_pixel.a),
				"Elite %s alpha changed at %d,%d." % [label, x, y]
			)
			if base_pixel == elite_pixel:
				continue
			changed_pixels += 1
			changed_per_frame[frame_index] += 1
			_expect(
				APPROVED_YELLOW_EDGE_RGB.has(_rgb_key(base_pixel)),
				"Elite %s purple must replace an existing yellow garment-edge pixel at %d,%d."
				% [label, x, y]
			)
			_expect(
				APPROVED_PURPLE_RGB.has(_rgb_key(elite_pixel)),
				"Elite %s escaped the approved purple palette at %d,%d."
				% [label, x, y]
			)
	return {
		"changed_pixels": changed_pixels,
		"changed_per_frame": changed_per_frame,
	}


func _expect_edge_frame_contract(
	metrics: Dictionary,
	expected_changed_per_frame: Array[int],
	label: String
) -> void:
	var changed_per_frame := (
		metrics.get("changed_per_frame", []) as Array[int]
	)
	_expect(
		changed_per_frame == expected_changed_per_frame,
		"Elite %s yellow-edge replacement changed in at least one animation frame."
		% label
	)


func _rgb_key(color: Color) -> int:
	return (
		clampi(roundi(color.r * 255.0), 0, 255) << 16
		| clampi(roundi(color.g * 255.0), 0, 255) << 8
		| clampi(roundi(color.b * 255.0), 0, 255)
	)


func _expect_animation_contract(
	frames: SpriteFrames,
	character_texture_path: String,
	move_texture_path: String,
	label: String
) -> void:
	_expect(frames != null, "%s SpriteFrames resource is missing." % label)
	if frames == null:
		return
	_expect(
		frames.has_animation(&"move")
		and frames.get_frame_count(&"move") == MOVE_FRAME_COUNT
		and is_equal_approx(
			frames.get_animation_speed(&"move"),
			MOVE_ANIMATION_SPEED
		)
		and frames.get_animation_loop(&"move"),
		"%s move animation must loop with eight frames at 12 fps." % label
	)
	if frames.has_animation(&"move"):
		for frame_index in range(frames.get_frame_count(&"move")):
			var texture := frames.get_frame_texture(
				&"move",
				frame_index
			) as AtlasTexture
			_expect(
				texture != null
				and texture.atlas != null
				and texture.atlas.resource_path == move_texture_path
				and texture.atlas.get_size() == Vector2(320.0, 40.0)
				and texture.region == Rect2(
					float(frame_index * 40),
					0.0,
					40.0,
					40.0
				),
				"%s move frame %d must use its independent 320x40 strip."
				% [label, frame_index]
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
				and texture.atlas != null
				and texture.atlas.resource_path == character_texture_path
				and texture.atlas.get_size() == Vector2(160.0, 160.0)
				and texture.get_size() == Vector2(40.0, 40.0),
				"%s %s frame %d must use a 40x40 atlas cell."
				% [label, String(animation_name), frame_index]
			)


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


func _create_runtime(runtime_name: String) -> TargetRuntime:
	var runtime := TargetRuntime.new()
	runtime.name = runtime_name
	fixture.add_child(runtime)
	var pathfinder := Node.new()
	pathfinder.name = "GridPathfinder"
	runtime.add_child(pathfinder)
	return runtime


func _spawn_enemy(
	runtime: TargetRuntime,
	target: Player
) -> LightningSorcerer:
	var enemy := ELITE_SCENE.instantiate() as LightningSorcerer
	runtime.add_child(enemy)
	enemy.global_position = Vector2.ZERO
	enemy.setup(ELITE_CONFIG, target, runtime.get_node("GridPathfinder"))
	enemy.set_physics_process(false)
	return enemy


func _spawn_player(runtime: TargetRuntime, position: Vector2) -> Player:
	var player := PLAYER_SCENE.instantiate() as Player
	runtime.add_child(player)
	player.global_position = position
	player.invincibility_duration = 0.0
	player.invincibility_time_left = 0.0
	player.magic_defense = 0
	player.set("_base_max_health", TEST_HEALTH)
	player.max_health = TEST_HEALTH
	player.current_health = TEST_HEALTH
	player.health_bar.setup(TEST_HEALTH, TEST_HEALTH)
	player.set_physics_process(false)
	player.set_process(false)
	return player


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
