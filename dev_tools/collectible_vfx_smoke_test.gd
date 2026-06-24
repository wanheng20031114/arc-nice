extends SceneTree

const MOON_AMULET := preload("res://resources/config/collectibles/collectible_moon_amulet.tres")
const MOON_SHIELD_SCENE := preload("res://scene/collectible_moon_shield.tscn")
const MOON_SHIELD_VISUAL_SCENE := preload("res://scene/collectible_moon_shield_visual.tscn")
const LIGHTNING_SCENE := preload("res://scene/collectible_lightning_effect.tscn")
const FROST_AREA_SCENE := preload("res://scene/collectible_frost_area_effect.tscn")
const MOON_SHIELD_FRAMES := preload("res://resources/animation/moon_shield_vfx.tres")
const LIGHTNING_FRAMES := preload("res://resources/animation/thunder_lightning_vfx.tres")
const FROST_FRAMES := preload("res://resources/animation/frost_area_vfx.tres")

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "CollectibleVfxSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	await _test_vfx_resources()

	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame

	if failures.is_empty():
		print("COLLECTIBLE_VFX_SMOKE_TEST_OK")
		quit()
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_vfx_resources() -> void:
	_expect(is_equal_approx(MOON_AMULET.skill_effect_radius, 64.0), "Moon amulet radius must stay at the reduced 64 px value.")
	_expect(MOON_SHIELD_FRAMES.has_animation(&"pulse"), "Moon shield frames must expose the pulse animation.")
	_expect(MOON_SHIELD_FRAMES.get_frame_count(&"pulse") == 4, "Moon shield animation must contain four frames.")
	_expect(LIGHTNING_FRAMES.has_animation(&"strike"), "Lightning frames must expose the strike animation.")
	_expect(LIGHTNING_FRAMES.get_frame_count(&"strike") == 6, "Lightning animation must contain six frames.")
	_expect(not LIGHTNING_FRAMES.get_animation_loop(&"strike"), "Lightning animation must not loop.")
	_expect(FROST_FRAMES.has_animation(&"burst"), "Frost area frames must expose the burst animation.")
	_expect(FROST_FRAMES.get_frame_count(&"burst") == 4, "Frost area animation must contain four generated frames.")
	_expect(not FROST_FRAMES.get_animation_loop(&"burst"), "Frost area animation must not loop.")

	var shield := MOON_SHIELD_SCENE.instantiate() as CollectibleMoonShield
	shield.setup(null, 64.0, 0.2)
	test_root.add_child(shield)
	await process_frame
	var shield_circle := shield.collision_shape.shape as CircleShape2D
	_expect(shield_circle != null and is_equal_approx(shield_circle.radius, 64.0), "Gameplay moon shield collision radius must match the configured radius.")
	_expect(shield.visual.scale.is_equal_approx(Vector2.ONE), "Moon shield visual must be unscaled at a 64 px radius.")
	shield.queue_free()
	await process_frame
	await physics_frame

	var shield_visual := MOON_SHIELD_VISUAL_SCENE.instantiate() as CollectibleMoonShieldVisual
	shield_visual.setup(32.0, 0.2)
	test_root.add_child(shield_visual)
	await process_frame
	_expect(shield_visual.visual.scale.is_equal_approx(Vector2(0.5, 0.5)), "Remote moon shield visual must scale from the requested radius.")
	shield_visual.queue_free()
	await process_frame
	await physics_frame

	var owner := Node2D.new()
	owner.position = Vector2(40.0, 20.0)
	test_root.add_child(owner)
	var following_visual := MOON_SHIELD_VISUAL_SCENE.instantiate() as CollectibleMoonShieldVisual
	following_visual.setup(64.0, 0.2)
	owner.add_child(following_visual)
	following_visual.position = Vector2.ZERO
	await process_frame
	owner.position = Vector2(96.0, 48.0)
	await process_frame
	_expect(
		following_visual.global_position.is_equal_approx(owner.global_position),
		"Remote moon shield visual must follow its owner node."
	)
	owner.queue_free()
	await process_frame
	await physics_frame

	var lightning := LIGHTNING_SCENE.instantiate() as CollectibleLightningEffect
	lightning.setup(0.24, 160.0)
	test_root.add_child(lightning)
	await process_frame
	_expect(lightning.visual.position.is_equal_approx(Vector2(0.0, -80.0)), "Lightning visual bottom must align to the effect origin.")
	lightning.setup(0.24, 80.0)
	_expect(lightning.visual.scale.is_equal_approx(Vector2(0.5, 0.5)), "Lightning visual must scale from the requested strike height.")
	_expect(lightning.visual.position.is_equal_approx(Vector2(0.0, -40.0)), "Scaled lightning must keep the bottom strike point at the origin.")
	lightning.queue_free()
	await process_frame
	await physics_frame

	var frost_area := FROST_AREA_SCENE.instantiate()
	frost_area.call("setup", 72.0, 0.12)
	test_root.add_child(frost_area)
	await process_frame
	_expect(is_equal_approx(float(frost_area.get("effect_radius")), 72.0), "Frost area visual must keep the requested radius.")
	_expect(is_equal_approx(float(frost_area.get("lifetime")), 0.12), "Frost area visual must keep the requested duration.")
	await create_timer(0.18).timeout
	_expect(not is_instance_valid(frost_area), "Frost area visual must free itself after its animation finishes.")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
