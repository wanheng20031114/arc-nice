extends SceneTree

const PICKUP_SCENE := preload("res://scene/combat/pickups/pickup.tscn")
const PICKUP_CONFIG := preload("res://resources/config/consumables/healing_potion.tres")
const PICKUP_COUNT := 256
const SAMPLE_RENDER_FRAMES := 120

var failures: Array[String] = []
var test_root: Node2D


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	test_root = Node2D.new()
	test_root.name = "PickupLifecycleSmokeTest"
	root.add_child(test_root)
	current_scene = test_root

	_test_scene_authored_timer_contract()
	await _test_timer_driven_blink_and_expiry()
	await _test_consumption_stops_both_timers()
	await _test_lifecycle_boundaries()
	await _test_multiplayer_proxy_timer_semantics()
	await _benchmark_eliminated_render_polling()

	current_scene = null
	test_root.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("PICKUP_LIFECYCLE_SMOKE_TEST_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_scene_authored_timer_contract() -> void:
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	_expect(pickup != null, "Pickup lifecycle fixture must instantiate.")
	if pickup == null:
		return
	var authored_blink_timer := pickup.get_node_or_null("BlinkTimer") as Timer
	var authored_lifetime_timer := pickup.get_node_or_null("LifetimeTimer") as Timer
	_expect(
		authored_blink_timer != null and authored_blink_timer.one_shot,
		"BlinkTimer must be a scene-authored one-shot Timer."
	)
	_expect(
		authored_lifetime_timer != null
		and authored_blink_timer != null
		and authored_blink_timer.process_callback
		== authored_lifetime_timer.process_callback
		and authored_blink_timer.ignore_time_scale
		== authored_lifetime_timer.ignore_time_scale
		and authored_blink_timer.process_mode
		== authored_lifetime_timer.process_mode,
		"BlinkTimer must inherit the same pause, callback and time-scale semantics as LifetimeTimer."
	)
	var pickup_source := FileAccess.get_file_as_string("res://scene/combat/pickups/pickup.gd")
	_expect(
		not pickup_source.contains("func _process("),
		"Pickup must not retain a render-frame lifetime polling callback."
	)
	pickup.free()


func _test_timer_driven_blink_and_expiry() -> void:
	var config := PICKUP_CONFIG.duplicate() as PickupConfig
	config.world_lifetime = 0.24
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	pickup.config = config
	pickup.blink_before_expire = 0.08
	var exit_states: Array[Dictionary] = []
	pickup.tree_exiting.connect(
		func() -> void:
			exit_states.append({
				"lifecycle": pickup.lifecycle,
				"lifetime_stopped": pickup.lifetime_timer.is_stopped(),
				"blink_stopped": pickup.blink_timer.is_stopped(),
			})
	)
	test_root.add_child(pickup)
	await process_frame
	var material := pickup.sprite.material as ShaderMaterial
	_expect(
		not pickup.is_processing()
		and not pickup.is_expiring
		and not pickup.lifetime_timer.is_stopped()
		and not pickup.blink_timer.is_stopped()
		and is_equal_approx(pickup.lifetime_timer.wait_time, 0.24)
		and is_equal_approx(pickup.blink_timer.wait_time, 0.16)
		and material != null
		and not bool(material.get_shader_parameter(&"blink_enabled")),
		"Pickup must wait for its blink deadline with no render processing or premature visual state."
	)

	await pickup.blink_timer.timeout
	_expect(
		pickup.lifecycle == Pickup.Lifecycle.AVAILABLE
		and pickup.is_expiring
		and pickup.blink_timer.is_stopped()
		and not pickup.lifetime_timer.is_stopped()
		and bool(material.get_shader_parameter(&"blink_enabled")),
		"BlinkTimer timeout must enter the warning phase once while LifetimeTimer remains authoritative."
	)
	await pickup.tree_exited
	_expect(
		exit_states.size() == 1
		and int(exit_states[0].get("lifecycle", -1)) == Pickup.Lifecycle.EXPIRED
		and bool(exit_states[0].get("lifetime_stopped", false))
		and bool(exit_states[0].get("blink_stopped", false)),
		"Lifetime expiry must stop both timers and leave through the EXPIRED lifecycle exactly once."
	)


func _test_consumption_stops_both_timers() -> void:
	var pickup := _spawn_pickup(10.0, 4.0)
	await process_frame
	pickup.call("_on_blink_timer_timeout")
	pickup.call("_commit_consumption", 2, true)
	_expect(
		pickup.lifecycle == Pickup.Lifecycle.CONSUMED
		and pickup.is_expiring
		and pickup.lifetime_timer.is_stopped()
		and pickup.blink_timer.is_stopped()
		and not pickup.is_processing()
		and pickup.is_queued_for_deletion(),
		"Consumption must stop both lifecycle timers before queueing the pickup for deletion."
	)
	await process_frame


func _test_lifecycle_boundaries() -> void:
	var no_blink := _spawn_pickup(10.0, 0.0)
	await process_frame
	_expect(
		not no_blink.lifetime_timer.is_stopped()
		and no_blink.blink_timer.is_stopped()
		and not no_blink.is_expiring,
		"A zero blink window must keep the authoritative lifetime without scheduling a warning."
	)
	no_blink.queue_free()

	var immediate_blink := _spawn_pickup(2.0, 4.0)
	await process_frame
	_expect(
		immediate_blink.is_expiring
		and immediate_blink.blink_timer.is_stopped()
		and not immediate_blink.lifetime_timer.is_stopped(),
		"A blink window covering the full lifetime must enter warning state immediately."
	)
	immediate_blink.queue_free()
	await process_frame


func _test_multiplayer_proxy_timer_semantics() -> void:
	var proxy_pickup := _spawn_pickup(10.0, 4.0)
	proxy_pickup.collision_layer = 0
	proxy_pickup.collision_mask = 0
	await process_frame
	_expect(
		proxy_pickup.collision_layer == 0
		and proxy_pickup.collision_mask == 0
		and not proxy_pickup.lifetime_timer.is_stopped()
		and not proxy_pickup.blink_timer.is_stopped()
		and not proxy_pickup.is_processing(),
		"A client-style pickup proxy must retain its local countdown without re-enabling collision or polling."
	)
	proxy_pickup.queue_free()
	await process_frame


func _benchmark_eliminated_render_polling() -> void:
	var pickups: Array[Pickup] = []
	for pickup_index in range(PICKUP_COUNT):
		var pickup := _spawn_pickup(60.0, 4.0)
		pickup.position = Vector2(pickup_index % 32, pickup_index / 32)
		pickups.append(pickup)
	await process_frame

	var observed_gdscript_process_dispatches := 0
	var blink_timeout_count := [0]
	for pickup in pickups:
		pickup.blink_timer.timeout.connect(
			func() -> void: blink_timeout_count[0] += 1
		)
	for _sample_index in range(SAMPLE_RENDER_FRAMES):
		await process_frame
		for pickup in pickups:
			if pickup.is_processing():
				observed_gdscript_process_dispatches += 1
	var legacy_poll_calls := PICKUP_COUNT * SAMPLE_RENDER_FRAMES
	_expect(
		observed_gdscript_process_dispatches == 0
		and int(blink_timeout_count[0]) == 0,
		"Non-blinking pickups must consume zero render-process callbacks before their one-shot deadline."
	)
	print(
		(
			"PICKUP_LIFECYCLE_CALL_AB pickups=%d render_frames=%d "
			+ "legacy_gdscript_process_dispatches=%d "
			+ "event_gdscript_process_dispatches=%d event_timeouts=%d "
			+ "eliminated_gdscript_dispatches=%d"
		)
		% [
			PICKUP_COUNT,
			SAMPLE_RENDER_FRAMES,
			legacy_poll_calls,
			observed_gdscript_process_dispatches,
			int(blink_timeout_count[0]),
			legacy_poll_calls - observed_gdscript_process_dispatches,
		]
	)
	for pickup in pickups:
		pickup.queue_free()
	await process_frame


func _spawn_pickup(world_lifetime: float, blink_window: float) -> Pickup:
	var config := PICKUP_CONFIG.duplicate() as PickupConfig
	config.world_lifetime = world_lifetime
	var pickup := PICKUP_SCENE.instantiate() as Pickup
	pickup.config = config
	pickup.blink_before_expire = blink_window
	test_root.add_child(pickup)
	return pickup


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
