extends SceneTree

const EFFECT_SCENE := preload(
	"res://scene/enemy/sorcerer/lightning_sorcerer_lightning_vfx.tscn"
)
const NIGHT_FLASH_POOL_SCENE := preload(
	"res://scene/lighting/night_vfx_flash_pool.tscn"
)

const EXPECTED_PREWARM_COUNT := 64
const EXPECTED_RETAINED_CAPACITY := 96
const COMPLETION_GUARD_FRAMES := 90


class PoolRuntime:
	extends Node2D

	var session_object_pool: SessionObjectPool = null

	func setup() -> void:
		var camera := Camera2D.new()
		camera.name = "Camera2D"
		camera.enabled = true
		add_child(camera)
		camera.global_position = Vector2.ZERO

		var flash_pool := NIGHT_FLASH_POOL_SCENE.instantiate()
		add_child(flash_pool)

		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		GameRuntimeBase.register_common_visual_effect_pools(session_object_pool)

	func has_session_object_pool_scene(scene: PackedScene) -> bool:
		return session_object_pool != null and session_object_pool.is_registered(scene)

	func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
		if session_object_pool == null:
			return null
		return (
			session_object_pool.try_acquire(scene)
			if strict
			else session_object_pool.acquire(scene)
		)


var failures: Array[String] = []
var runtime: PoolRuntime = null


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = PoolRuntime.new()
	runtime.name = "LightningSorcererVfxSmokeRuntime"
	root.add_child(runtime)
	current_scene = runtime
	runtime.setup()
	await process_frame

	_verify_authored_scene_contract()
	_verify_pool_registration()
	await _verify_chain_playback_and_reuse()
	_verify_offscreen_omission()

	runtime.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("LIGHTNING_SORCERER_VFX_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_authored_scene_contract() -> void:
	var source := FileAccess.get_file_as_string(
		"res://scene/enemy/sorcerer/lightning_sorcerer_lightning_vfx.gd"
	)
	_expect(
		source.count("draw_multiline(") == 2,
		"Lightning VFX must keep exactly two batched multiline draw calls."
	)
	_expect(
		source.count("draw_polyline(") == 0,
		"Lightning VFX must not regress to one draw call per chain link."
	)
	_expect(
		LightningSorcererLightningVfx.CORE_COLOR.r > 1.0
		and LightningSorcererLightningVfx.CORE_COLOR.r <= 1.5
		and LightningSorcererLightningVfx.FLASH_PEAK_ENERGY <= 0.7
		and LightningSorcererLightningVfx.FLASH_TEXTURE_SCALE <= 0.34,
		"Lightning must keep a visible but bounded HDR core and night-light radius."
	)
	var direct := EFFECT_SCENE.instantiate() as LightningSorcererLightningVfx
	_expect(direct != null, "Lightning VFX scene did not instantiate with its typed script.")
	if direct == null:
		return
	_expect(direct.get_child_count() == 0, "Lightning VFX must not create dynamic child nodes.")
	_expect(direct.top_level, "Lightning VFX must keep world coordinates independent from its pool parent.")
	var additive := direct.material as CanvasItemMaterial
	_expect(additive != null, "Lightning VFX must author its additive material in the scene.")
	if additive != null:
		_expect(
			additive.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD,
			"Lightning VFX material must use additive blending."
		)
		_expect(
			additive.light_mode == CanvasItemMaterial.LIGHT_MODE_UNSHADED,
			"Lightning VFX material must stay visible without receiving night lights."
		)
	direct.queue_free()


func _verify_pool_registration() -> void:
	var metrics := _metrics()
	_expect(
		int(metrics.get("created", -1)) == EXPECTED_PREWARM_COUNT,
		"Lightning VFX pool must prewarm 64 dormant nodes."
	)
	_expect(
		int(metrics.get("inactive", -1)) == EXPECTED_PREWARM_COUNT,
		"Every prewarmed lightning VFX must remain inactive."
	)
	_expect(
		int(metrics.get("retained_capacity", -1)) == EXPECTED_RETAINED_CAPACITY,
		"Lightning VFX pool must retain at most 96 nodes."
	)


func _verify_chain_playback_and_reuse() -> void:
	var path := PackedVector2Array([
		Vector2(-24.0, -8.0),
		Vector2(40.0, 0.0),
		Vector2(72.0, 18.0),
		Vector2(104.0, -10.0),
		Vector2(136.0, 12.0),
		Vector2(168.0, -4.0),
	])
	_expect(
		LightningSorcererLightningVfx.try_spawn(runtime, path, 0.052),
		"A visible chain path did not acquire its strict VFX lease."
	)
	var effect := _first_active_effect()
	_expect(effect != null, "The leased chain VFX was not active under SessionObjectPool.")
	if effect != null:
		_expect(effect.get_path_point_count() == 6, "Chain VFX must retain staff origin plus five hit points.")
		_expect(effect.get_segment_count() == 5, "Six path points must produce exactly five lightning links.")
		_expect(effect.get_started_segment_count() == 3, "A 52 ms late join must enter the third 25 ms link trace.")
		for segment_index in range(effect.get_segment_count()):
			var segment := effect.get_segment_points(segment_index)
			_expect(segment.size() >= 3, "Every authored chain link must contain a finite jagged polyline.")
			if segment.size() >= 2:
				_expect(
					segment[0].is_equal_approx(path[segment_index] - path[0]),
					"Jagged lightning changed a link's exact start endpoint."
				)
				_expect(
					segment[segment.size() - 1].is_equal_approx(path[segment_index + 1] - path[0]),
					"Jagged lightning changed a link's exact finish endpoint."
				)

	var flash_pool := runtime.get_node("NightVfxFlashPool") as NightVfxFlashPool
	_expect(
		flash_pool.get_active_flash_count() == 1,
		"One complete chain must request exactly one budgeted night flash."
	)
	var active_flash_position := Vector2.INF
	for child in flash_pool.get_children():
		var flash := child as NightVfxFlash2D
		if flash != null and flash.is_flash_active():
			active_flash_position = flash.global_position
			break
	_expect(
		active_flash_position.is_equal_approx(path[1]),
		"The one night flash must be centered on the initial hit, not every bounce."
	)

	await _wait_for_pool_idle()
	var idle_metrics := _metrics()
	_expect(int(idle_metrics.get("in_use", -1)) == 0, "Completed chain VFX did not return its lease.")
	_expect(
		int(idle_metrics.get("pending_release", -1)) == 0,
		"Lightning VFX release quarantine did not drain."
	)
	_expect(
		LightningSorcererLightningVfx.try_spawn(runtime, path),
		"A returned lightning VFX lease could not be reacquired."
	)
	_expect(
		int(_metrics().get("created", -1)) == EXPECTED_PREWARM_COUNT,
		"Reusing lightning VFX unexpectedly created another node."
	)
	await _wait_for_pool_idle()


func _verify_offscreen_omission() -> void:
	var before := _metrics()
	var offscreen_path := PackedVector2Array([
		Vector2(100000.0, 100000.0),
		Vector2(100064.0, 100000.0),
	])
	_expect(
		not LightningSorcererLightningVfx.try_spawn(runtime, offscreen_path),
		"A fully offscreen chain must be omitted before taking a pool lease."
	)
	var after := _metrics()
	_expect(int(after.get("in_use", -1)) == 0, "Offscreen omission consumed a lightning VFX lease.")
	_expect(
		int(after.get("dropped", -1)) == int(before.get("dropped", -1)),
		"Offscreen omission must not be counted as pool saturation."
	)


func _wait_for_pool_idle() -> void:
	var guard := 0
	while guard < COMPLETION_GUARD_FRAMES:
		var metrics := _metrics()
		if (
			int(metrics.get("in_use", 0)) == 0
			and int(metrics.get("pending_release", 0)) == 0
		):
			return
		await process_frame
		await physics_frame
		guard += 1
	_expect(false, "Lightning VFX pool did not become idle within the guard window.")


func _metrics() -> Dictionary:
	return runtime.session_object_pool.get_metrics(EFFECT_SCENE.resource_path)


func _first_active_effect() -> LightningSorcererLightningVfx:
	for child in runtime.session_object_pool.get_children():
		if (
			child is LightningSorcererLightningVfx
			and bool(child.get_meta(SessionObjectPool.POOL_ACTIVE_META, false))
		):
			return child as LightningSorcererLightningVfx
	return null


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
