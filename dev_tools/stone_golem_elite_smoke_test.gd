extends SceneTree

const ELITE_SCENE := preload("res://scene/enemy/artificial_creation/stone_golem_elite.tscn")
const BASE_SCENE := preload("res://scene/enemy/artificial_creation/stone_golem.tscn")
const ELITE_CONFIG := preload(
	"res://resources/config/enemies/stone_golem_elite.tres"
)
const BASE_CONFIG := preload("res://resources/config/enemies/stone_golem.tres")
const ELITE_TEXTURE_PATH := "res://resources/texture/stone_golem_elite.png"
const BASE_TEXTURE_PATH := "res://resources/texture/stone_golem.png"
const DETAIL_OVERLAY_PATH := (
	"res://dev_assets/source_images/stone_golem_elite/"
	+ "stone_golem_elite_detail_overlay.png"
)
const FRAME_SIZE := 64
const GRID_SIZE := 4
const TEST_HEALTH := 2000
const MIN_DETAIL_PIXELS_PER_FRAME := 8
const MAX_DETAIL_PIXELS_PER_FRAME := 45
const EXPECTED_CHANGED_PIXELS := 278
const DARK_OUTLINE_LUMA := 72.0 / 255.0
const RUBY_PALETTE := [
	0x521D20FF,
	0x7A2326FF,
	0xAE2E2DFF,
	0xE0483CFF,
	0xF59976FF,
]
const MOSS_PALETTE := [
	0x374533FF,
	0x59602FFF,
	0x798726FF,
	0x868E2DFF,
]

var failures: Array[String] = []
var test_root: Node2D


class TestPlant:
	extends PlantDefense


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "StoneGolemEliteSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_resource_independence_and_stats()
	_test_pixel_contract()
	await _test_contact_does_not_bypass_slam()
	await _test_shorter_windup_and_slam()

	current_scene = null
	test_root.queue_free()
	await process_frame
	await physics_frame
	for _cleanup_frame in range(4):
		await process_frame

	if failures.is_empty():
		print("STONE_GOLEM_ELITE_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_resource_independence_and_stats() -> void:
	_expect(
		ELITE_CONFIG is StoneGolemEliteConfig,
		"Elite config must use StoneGolemEliteConfig."
	)
	_expect(
		ELITE_CONFIG is StoneGolemConfig,
		"Elite config must retain the complete stone-golem slam contract."
	)
	_expect(
		ELITE_CONFIG.resource_path != BASE_CONFIG.resource_path,
		"Elite and base configs must be independent resources."
	)
	_expect(ELITE_CONFIG.display_name == "精英石头人", "Display name mismatch.")
	_expect(ELITE_CONFIG.enemy_scene == ELITE_SCENE, "Elite scene mismatch.")
	_expect(ELITE_CONFIG.enemy_scene != BASE_SCENE, "Elite scene must be independent.")
	_expect(ELITE_CONFIG.max_health == 1800, "Elite health must be 1800.")
	_expect(ELITE_CONFIG.attack_damage == 150, "Elite attack must be 150.")
	_expect(ELITE_CONFIG.physical_defense == 75, "Elite physical defense must be 75.")
	_expect(ELITE_CONFIG.magic_defense == 0, "Elite magic defense must be 0.")
	_expect(
		is_equal_approx(ELITE_CONFIG.move_speed, BASE_CONFIG.move_speed),
		"Elite and base stone golems must have the same movement speed."
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.attack_windup, 0.6)
		and ELITE_CONFIG.attack_windup < BASE_CONFIG.attack_windup,
		"Elite windup must be the shorter authored 0.6 seconds."
	)
	_expect(
		is_equal_approx(ELITE_CONFIG.attack_interval, BASE_CONFIG.attack_interval)
		and is_equal_approx(ELITE_CONFIG.slam_radius, BASE_CONFIG.slam_radius)
		and ELITE_CONFIG.slam_damage_type == EnemyConfig.DamageType.PHYSICAL,
		"Unchanged slam cadence, radius, and physical type must match the base."
	)

	var elite := ELITE_SCENE.instantiate() as StoneGolemElite
	var base := BASE_SCENE.instantiate() as StoneGolem
	_expect(elite != null, "Elite scene must instantiate StoneGolemElite.")
	_expect(base != null, "Base comparison scene must instantiate StoneGolem.")
	if elite == null or base == null:
		if elite != null:
			elite.free()
		if base != null:
			base.free()
		return

	var elite_sprite := elite.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var base_sprite := base.get_node("AnimatedSprite2D") as AnimatedSprite2D
	var elite_body := elite.get_node("CollisionShape2D") as CollisionShape2D
	var elite_touch := (
		elite.get_node("TouchDamageArea/CollisionShape2D")
		as CollisionShape2D
	)
	var base_body := base.get_node("CollisionShape2D") as CollisionShape2D
	var warning := elite.get_node("WindupWarning") as Polygon2D
	var impact := elite.get_node("SlamImpactRing") as Line2D
	_expect(
		elite.get_script().resource_path
		== "res://scene/enemy/artificial_creation/stone_golem_elite.gd",
		"Elite scene must own its dedicated script."
	)
	_expect(
		elite_sprite.sprite_frames != base_sprite.sprite_frames
		and elite_sprite.sprite_frames.resource_path
		== "res://resources/animation/stone_golem_elite.tres",
		"Elite SpriteFrames must be independent from the base animation."
	)
	_expect(
		elite_sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST
		and elite_sprite.scale == Vector2.ONE
		and elite_sprite.position == base_sprite.position,
		"Elite sprite must preserve nearest, integer scale, and reviewed offset."
	)
	_expect(
		elite.navigation_update_interval_frames
		== base.navigation_update_interval_frames
		and elite.navigation_update_interval_frames == 8,
		"Elite must retain the profiled slow-golem navigation cadence."
	)
	_expect(
		elite_body.shape is RectangleShape2D
		and elite_touch.shape is RectangleShape2D
		and elite_body.shape != elite_touch.shape
		and elite_body.shape != base_body.shape,
		"Elite body and touch shapes must be independent scene resources."
	)
	var body_rect := elite_body.shape as RectangleShape2D
	var touch_rect := elite_touch.shape as RectangleShape2D
	_expect(
		body_rect.size == Vector2(20.0, 20.0)
		and touch_rect.size == Vector2(20.0, 20.0)
		and elite_body.position == elite_touch.position,
		"Elite collision and core must retain the 20x20 medium footprint."
	)
	_expect(
		warning.position == Vector2.ZERO
		and impact.position == Vector2.ZERO
		and warning.color.r > warning.color.g * 2.0
		and impact.default_color.r > impact.default_color.g * 2.0,
		"Elite telegraphs must stay query-centered and use the authored red tint."
	)

	var frames := elite_sprite.sprite_frames
	for animation_name in [&"move", &"windup", &"attack", &"death"]:
		_expect(
			frames.has_animation(animation_name)
			and frames.get_frame_count(animation_name) == 4,
			"Elite %s animation must own four frames." % animation_name
		)
		for frame_index in range(frames.get_frame_count(animation_name)):
			var frame_texture := frames.get_frame_texture(
				animation_name,
				frame_index
			) as AtlasTexture
			_expect(
				frame_texture != null
				and frame_texture.get_size() == Vector2(64.0, 64.0)
				and frame_texture.atlas.resource_path == ELITE_TEXTURE_PATH,
				"Elite %s frame %d must use its independent 64px texture."
				% [animation_name, frame_index]
			)
	_expect(
		frames.get_animation_loop(&"move")
		and not frames.get_animation_loop(&"windup")
		and not frames.get_animation_loop(&"attack")
		and not frames.get_animation_loop(&"death"),
		"Only elite movement may loop."
	)
	_expect(
		is_equal_approx(
			float(frames.get_frame_count(&"windup"))
			/ frames.get_animation_speed(&"windup"),
			ELITE_CONFIG.attack_windup
		),
		"Elite windup animation duration must match gameplay windup."
	)
	elite.free()
	base.free()


func _test_pixel_contract() -> void:
	var base_texture := load(BASE_TEXTURE_PATH) as Texture2D
	var elite_texture := load(ELITE_TEXTURE_PATH) as Texture2D
	var base_image := base_texture.get_image() if base_texture != null else null
	var elite_image := elite_texture.get_image() if elite_texture != null else null
	var overlay_image := Image.new()
	var overlay_error := overlay_image.load_png_from_buffer(
		FileAccess.get_file_as_bytes(DETAIL_OVERLAY_PATH)
	)
	_expect(
		base_image != null
		and elite_image != null
		and overlay_error == OK
		and base_image.get_size() == Vector2i(256, 256)
		and elite_image.get_size() == Vector2i(256, 256)
		and overlay_image.get_size() == Vector2i(256, 256),
		"Base, elite, and detail overlay must be native 256x256 assets."
	)
	if (
		base_image == null
		or elite_image == null
		or overlay_error != OK
		or base_image.get_size() != elite_image.get_size()
		or base_image.get_size() != overlay_image.get_size()
	):
		return

	var changed_pixels := 0
	for row in range(GRID_SIZE):
		for column in range(GRID_SIZE):
			var frame_detail_pixels := 0
			for local_y in range(FRAME_SIZE):
				for local_x in range(FRAME_SIZE):
					var global_x := column * FRAME_SIZE + local_x
					var global_y := row * FRAME_SIZE + local_y
					var base_color := base_image.get_pixel(global_x, global_y)
					var elite_color := elite_image.get_pixel(global_x, global_y)
					var overlay_color := overlay_image.get_pixel(
						global_x,
						global_y
					)
					_expect(
						is_equal_approx(base_color.a, elite_color.a),
						"Elite alpha changed at %d,%d." % [global_x, global_y]
					)
					_expect(
						is_zero_approx(overlay_color.a)
						or is_equal_approx(overlay_color.a, 1.0),
						"Elite detail overlay alpha must stay binary."
					)
					var boundary := _is_frame_boundary(
						base_image,
						column,
						row,
						local_x,
						local_y
					)
					var base_rgba := base_color.to_rgba32()
					var elite_rgba := elite_color.to_rgba32()
					var overlay_rgba := overlay_color.to_rgba32()
					var changed := base_rgba != elite_rgba
					var overlay_authored := overlay_color.a > 0.5
					_expect(
						changed == overlay_authored,
						"Elite diff must exactly equal its authored detail mask "
						+ "at %d,%d." % [global_x, global_y]
					)
					if overlay_authored:
						_expect(
							overlay_rgba == elite_rgba,
							"Elite detail overlay/result mismatch at %d,%d."
							% [global_x, global_y]
						)
					if base_color.a <= 0.0:
						continue
					var dark_outline := (
						_color_luma(base_color) <= DARK_OUTLINE_LUMA
						and base_rgba not in MOSS_PALETTE
					)
					if boundary or dark_outline:
						_expect(
							not changed,
							"Elite changed protected contour/outline at %d,%d."
							% [global_x, global_y]
						)
					if changed:
						changed_pixels += 1
						frame_detail_pixels += 1
						_expect(
							not boundary
							and not dark_outline
							and elite_rgba in RUBY_PALETTE,
							"Elite changed a non-ruby or protected pixel at %d,%d."
							% [global_x, global_y]
						)
			_expect(
				frame_detail_pixels >= MIN_DETAIL_PIXELS_PER_FRAME
				and frame_detail_pixels <= MAX_DETAIL_PIXELS_PER_FRAME,
				"Elite frame %d,%d detail density must stay sparse: %d."
				% [column, row, frame_detail_pixels]
			)
	_expect(
		changed_pixels == EXPECTED_CHANGED_PIXELS,
		"Elite sheet must contain exactly %d reviewed detail pixels, got %d."
		% [EXPECTED_CHANGED_PIXELS, changed_pixels]
	)


func _test_contact_does_not_bypass_slam() -> void:
	var plant := _spawn_test_plant(Vector2.ZERO, 50)
	var enemy := _spawn_elite(Vector2.ZERO)
	enemy.set_physics_process(false)
	await _wait_physics_frames(2)
	_expect(
		enemy.touching_plants.has(plant.get_instance_id()),
		"Elite stone-golem contact fixture must register the plant."
	)
	_expect(
		not bool(enemy.call("_uses_inherited_touch_damage"))
		and plant.current_health == TEST_HEALTH
		and is_zero_approx(enemy.touch_damage_cooldown_left),
		"Elite stone golems must reserve damage for their authored slam."
	)
	enemy.call("_try_deal_touch_damage")
	enemy.call("_try_deal_touch_damage")
	_expect(
		plant.current_health == TEST_HEALTH
		and is_zero_approx(enemy.touch_damage_cooldown_left),
		"Elite contact dispatch must not bypass the slam state machine."
	)
	enemy.queue_free()
	plant.queue_free()
	await _wait_physics_frames(2)


func _test_shorter_windup_and_slam() -> void:
	var plant := _spawn_test_plant(Vector2(36.0, 0.0), 50)
	var enemy := _spawn_elite(Vector2.ZERO)
	enemy.set_physics_process(false)
	enemy.set_objective_target(plant)
	enemy.attack_cooldown_left = 0.0
	await _wait_physics_frames(2)
	var health_before := plant.current_health
	_expect(
		bool(enemy.call("_try_start_windup")),
		"Elite must start its authored short windup."
	)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.WINDUP
		and enemy.animated_sprite.animation == &"windup"
		and enemy.windup_warning.visible
		and enemy.windup_warning.color.r > enemy.windup_warning.color.g * 2.0,
		"Elite windup must use its independent animation and red warning."
	)
	enemy.call("_update_windup", ELITE_CONFIG.attack_windup - 0.01)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.WINDUP
		and plant.current_health == health_before,
		"Elite slam must not commit before the full 0.6 second windup."
	)
	enemy.call("_update_windup", 0.02)
	_expect(
		enemy.combat_state == CapooKnight.CombatState.SLASH
		and enemy.animated_sprite.animation == &"attack",
		"Elite must enter its attack animation after the shorter windup."
	)
	enemy.call("_update_slash", ELITE_CONFIG.slash_damage_delay - 0.01)
	_expect(
		plant.current_health == health_before,
		"Elite slam must still wait for its authored damage frame."
	)
	enemy.call("_update_slash", 0.02)
	_expect(
		plant.current_health == health_before - 100,
		"150 physical slam damage must become 100 against 50 defense."
	)
	_expect(
		enemy.slash_damage_done
		and enemy.slam_impact_ring.visible
		and enemy.call("_get_slam_damage_source_type")
		== &"stone_golem_elite_slam",
		"Elite slam must commit once with its independent source identity."
	)
	enemy.queue_free()
	plant.queue_free()
	await _wait_physics_frames(2)


func _spawn_elite(position: Vector2) -> StoneGolemElite:
	var enemy := ELITE_SCENE.instantiate() as StoneGolemElite
	test_root.add_child(enemy)
	enemy.global_position = position
	enemy.setup(ELITE_CONFIG, null)
	return enemy


func _spawn_test_plant(position: Vector2, physical_defense: int) -> TestPlant:
	var plant := TestPlant.new()
	plant.collision_layer = 1 << 9
	plant.collision_mask = 0
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 1.0
	shape_node.shape = circle
	plant.add_child(shape_node)
	test_root.add_child(plant)
	plant.global_position = position
	plant.max_health = TEST_HEALTH
	plant.current_health = TEST_HEALTH
	plant.physical_defense = physical_defense
	plant.magic_defense = 0
	plant.is_dead = false
	plant.is_removing = false
	plant.is_multiplayer_proxy = false
	return plant


func _is_frame_boundary(
	image: Image,
	column: int,
	row: int,
	local_x: int,
	local_y: int
) -> bool:
	var global_x := column * FRAME_SIZE + local_x
	var global_y := row * FRAME_SIZE + local_y
	if image.get_pixel(global_x, global_y).a <= 0.0:
		return false
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			if offset_x == 0 and offset_y == 0:
				continue
			var neighbor_x := local_x + offset_x
			var neighbor_y := local_y + offset_y
			if (
				neighbor_x < 0
				or neighbor_y < 0
				or neighbor_x >= FRAME_SIZE
				or neighbor_y >= FRAME_SIZE
			):
				return true
			if (
				image.get_pixel(
					column * FRAME_SIZE + neighbor_x,
					row * FRAME_SIZE + neighbor_y
				).a
				<= 0.0
			):
				return true
	return false


func _color_luma(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722


func _wait_physics_frames(frame_count: int) -> void:
	for _frame_index in range(frame_count):
		await physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
