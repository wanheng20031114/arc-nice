extends SceneTree

const FIREBALL_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball.tscn")
const IMPACT_SCENE := preload("res://scene/enemy/capoo/capoo_mage_fireball_impact.tscn")
const IMPACT_AUDIO := preload("res://resources/audio/capoo_mage_fireball_impact.wav")
const EXPLOSION_AUDIO_LIMITER := preload("res://scene/combat/audio/explosion_audio_limiter.gd")
const SPATIAL_AUDIO_VOICE_LIMITER := preload(
	"res://scene/combat/audio/spatial_audio_voice_limiter.gd"
)

const POOL_PREWARM := 2
const POOL_CAPACITY := 2
const COMPLETION_GUARD_FRAMES := 180


class PoolRuntime:
	extends CombatRuntimeTestFixture

	var session_object_pool: SessionObjectPool = null

	func configure_pool(_scene: PackedScene, prewarm_count: int, capacity: int) -> void:
		session_object_pool = SessionObjectPool.new()
		session_object_pool.name = "SessionObjectPool"
		add_child(session_object_pool)
		session_object_pool.register_scene(_scene, prewarm_count, capacity)

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

	func release_session_object(instance: Node) -> bool:
		return session_object_pool != null and session_object_pool.release(instance)


var failures: Array[String] = []
var runtime: PoolRuntime = null
var fireball: CapooMageFireball = null
var original_pool_mode := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_pool_mode = CapooMageFireball.pooled_impact_effect_enabled
	CapooMageFireball.pooled_impact_effect_enabled = true

	runtime = PoolRuntime.new()
	runtime.name = "CapooMageImpactPoolSmokeRuntime"
	runtime.install_base_runtime_nodes()
	root.add_child(runtime)
	_expect(
		SPATIAL_AUDIO_VOICE_LIMITER.register_audio_scope(runtime),
		"Impact pool fixture must declare its explicit spatial-audio scope."
	)
	current_scene = runtime
	runtime.configure_pool(IMPACT_SCENE, POOL_PREWARM, POOL_CAPACITY)

	var camera := Camera2D.new()
	camera.name = "Camera2D"
	camera.enabled = true
	runtime.add_child(camera)
	camera.global_position = Vector2.ZERO

	fireball = FIREBALL_SCENE.instantiate() as CapooMageFireball
	fireball.bind_gameplay_context(
		runtime,
		runtime.get_multiplayer_gameplay_gateway()
	)
	runtime.add_child(fireball)
	fireball.global_position = Vector2.ZERO
	await process_frame

	_verify_prewarm_is_dormant()
	await _verify_strict_capacity_and_reuse()
	await _verify_offscreen_omission()
	await _verify_rejected_audio_does_not_hold_lease()
	await _verify_preempted_audio_does_not_hold_lease()
	await _verify_direct_ab_path()

	CapooMageFireball.pooled_impact_effect_enabled = original_pool_mode
	runtime.queue_free()
	await process_frame
	await physics_frame

	if failures.is_empty():
		print("CAPOO_MAGE_IMPACT_POOL_SMOKE_TEST_OK")
		quit()
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _verify_prewarm_is_dormant() -> void:
	var metrics := _impact_metrics()
	_expect(int(metrics.get("created", -1)) == POOL_PREWARM, "Impact pool did not prewarm two nodes.")
	_expect(int(metrics.get("inactive", -1)) == POOL_PREWARM, "Prewarmed impacts must be inactive.")
	for child in runtime.session_object_pool.get_children():
		var impact := child as CapooMageFireballImpact
		if impact == null:
			continue
		var sprite := impact.get_node("AnimatedSprite2D") as AnimatedSprite2D
		var audio := impact.get_node("ImpactAudio") as AudioStreamPlayer2D
		_expect(not sprite.is_playing() and not sprite.visible, "Prewarmed impact animation auto-played.")
		_expect(not audio.playing, "Prewarmed impact audio auto-played.")


func _verify_strict_capacity_and_reuse() -> void:
	_spawn_impact(Vector2.ZERO)
	_spawn_impact(Vector2(8.0, 0.0))
	_spawn_impact(Vector2(16.0, 0.0))
	var saturated := _impact_metrics()
	_expect(int(saturated.get("created", -1)) == POOL_CAPACITY, "Strict impact pool grew past capacity.")
	_expect(int(saturated.get("in_use", -1)) == POOL_CAPACITY, "Expected two active impact leases.")
	_expect(int(saturated.get("dropped", -1)) == 1, "A saturated strict acquire must be counted.")
	_expect(_count_active_impacts() == POOL_CAPACITY, "Saturated request spawned an overflow impact.")

	await _wait_for_pool_idle()
	var idle := _impact_metrics()
	_expect(int(idle.get("inactive", -1)) == POOL_CAPACITY, "Completed impacts did not return to pool.")
	_expect(int(idle.get("pending_release", -1)) == 0, "Impact release quarantine did not drain.")

	_spawn_impact(Vector2(4.0, 0.0))
	var reused := _impact_metrics()
	_expect(int(reused.get("created", -1)) == POOL_CAPACITY, "Reusing an impact created a new node.")
	_expect(int(reused.get("in_use", -1)) == 1, "Returned impact could not be reacquired.")
	await _wait_for_pool_idle()


func _verify_offscreen_omission() -> void:
	var before := _impact_metrics()
	_spawn_impact(Vector2(100000.0, 100000.0))
	var after := _impact_metrics()
	_expect(int(after.get("in_use", -1)) == 0, "Offscreen impact consumed a pool lease.")
	_expect(
		int(after.get("dropped", -1)) == int(before.get("dropped", -1)),
		"Offscreen omission incorrectly counted as pool saturation."
	)


func _verify_rejected_audio_does_not_hold_lease() -> void:
	var blockers: Array[AudioStreamPlayer2D] = []
	for blocker_index in range(EXPLOSION_AUDIO_LIMITER.MAX_SIMULTANEOUS_EXPLOSIONS):
		var blocker := AudioStreamPlayer2D.new()
		blocker.stream = IMPACT_AUDIO
		blocker.bus = &"SFX"
		blocker.max_distance = 220.0
		runtime.add_child(blocker)
		blocker.global_position = Vector2.ZERO
		EXPLOSION_AUDIO_LIMITER.play(blocker, runtime)
		blockers.append(blocker)

	_spawn_impact(Vector2.ZERO)
	var impact := _first_active_impact()
	_expect(impact != null, "Audio rejection fixture did not acquire an impact.")
	if impact != null:
		var impact_audio := impact.get_node("ImpactAudio") as AudioStreamPlayer2D
		_expect(not impact_audio.playing, "Over-budget impact audio was not rejected by shared limiter.")
	await _wait_for_pool_idle()
	_expect(
		int(_impact_metrics().get("in_use", -1)) == 0,
		"Rejected audio kept an otherwise completed impact lease alive."
	)

	for blocker in blockers:
		EXPLOSION_AUDIO_LIMITER.stop(blocker)
		blocker.queue_free()
	await process_frame


func _verify_preempted_audio_does_not_hold_lease() -> void:
	_spawn_impact(Vector2(200.0, 0.0))
	var farther_impact := _first_active_impact()
	_expect(farther_impact != null, "Audio preemption fixture did not acquire its farther impact.")
	var farther_audio: AudioStreamPlayer2D = null
	if farther_impact != null:
		farther_audio = farther_impact.get_node("ImpactAudio") as AudioStreamPlayer2D
		_expect(farther_audio.playing, "Farther impact audio did not claim its initial voice.")

	var blockers: Array[AudioStreamPlayer2D] = []
	for blocker_index in range(EXPLOSION_AUDIO_LIMITER.MAX_SIMULTANEOUS_EXPLOSIONS - 1):
		var blocker := AudioStreamPlayer2D.new()
		blocker.stream = IMPACT_AUDIO
		blocker.bus = &"SFX"
		blocker.max_distance = 220.0
		runtime.add_child(blocker)
		blocker.global_position = Vector2(180.0, float(blocker_index))
		EXPLOSION_AUDIO_LIMITER.play(blocker, runtime)
		blockers.append(blocker)

	_spawn_impact(Vector2.ZERO)
	if farther_audio != null:
		_expect(not farther_audio.playing, "Nearer impact did not preempt the farther limited voice.")
	await _wait_for_pool_idle()
	_expect(
		int(_impact_metrics().get("in_use", -1)) == 0,
		"Preempted audio kept a completed impact lease alive."
	)

	for blocker in blockers:
		EXPLOSION_AUDIO_LIMITER.stop(blocker)
		blocker.queue_free()
	await process_frame


func _verify_direct_ab_path() -> void:
	CapooMageFireball.pooled_impact_effect_enabled = false
	_spawn_impact(Vector2.ZERO)
	var direct_impact: CapooMageFireballImpact = null
	for child in runtime.get_children():
		if (
			child is CapooMageFireballImpact
			and not child.has_meta(SessionObjectPool.POOL_OWNER_META)
		):
			direct_impact = child as CapooMageFireballImpact
			break
	_expect(direct_impact != null, "A/B direct-instantiation path did not spawn an impact.")
	if direct_impact != null:
		_expect(
			not direct_impact.has_meta(SessionObjectPool.POOL_OWNER_META),
			"A/B direct-instantiation path unexpectedly leased from the pool."
		)
	_expect(int(_impact_metrics().get("in_use", -1)) == 0, "Direct A/B path consumed a pool lease.")
	var guard := 0
	while direct_impact != null and is_instance_valid(direct_impact) and guard < COMPLETION_GUARD_FRAMES:
		await process_frame
		guard += 1
	_expect(
		direct_impact == null or not is_instance_valid(direct_impact),
		"Direct A/B impact did not free itself after playback."
	)
	CapooMageFireball.pooled_impact_effect_enabled = true


func _spawn_impact(position: Vector2) -> void:
	fireball.global_position = position
	fireball.call("_spawn_impact_effect")


func _wait_for_pool_idle() -> void:
	var guard := 0
	while guard < COMPLETION_GUARD_FRAMES:
		var metrics := _impact_metrics()
		if (
			int(metrics.get("in_use", 0)) == 0
			and int(metrics.get("pending_release", 0)) == 0
		):
			return
		await process_frame
		guard += 1
	_expect(false, "Impact pool did not become idle within the guard window.")


func _impact_metrics() -> Dictionary:
	return runtime.session_object_pool.get_metrics(IMPACT_SCENE.resource_path)


func _count_active_impacts() -> int:
	var total := 0
	for child in _get_impact_candidates():
		if (
			child is CapooMageFireballImpact
			and bool(child.get_meta(SessionObjectPool.POOL_ACTIVE_META, false))
		):
			total += 1
	return total


func _first_active_impact() -> CapooMageFireballImpact:
	for child in _get_impact_candidates():
		if (
			child is CapooMageFireballImpact
			and bool(child.get_meta(SessionObjectPool.POOL_ACTIVE_META, false))
		):
			return child as CapooMageFireballImpact
	return null


func _get_impact_candidates() -> Array[Node]:
	var result: Array[Node] = []
	result.append_array(runtime.session_object_pool.get_children())
	for child in runtime.get_children():
		if child is CapooMageFireballImpact:
			result.append(child)
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
