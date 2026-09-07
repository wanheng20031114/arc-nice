extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.max_fps = 60
	var scene := load("res://scene/enemy/enemy.tscn") as PackedScene
	var enemy: Node = scene.instantiate()
	root.add_child(enemy)
	enemy.process_mode = Node.PROCESS_MODE_PAUSABLE
	enemy.set_physics_process(false)
	enemy.set("touch_damage_cooldown_left", 0.5)
	for frame in 5:
		await physics_frame
	var before: float = enemy.get("touch_damage_cooldown_left")
	var frame_before := Engine.get_physics_frames()
	paused = true
	await create_timer(0.7, true).timeout
	var during: float = enemy.get("touch_damage_cooldown_left")
	var paused_ticks := Engine.get_physics_frames() - frame_before
	paused = false
	var after: float = enemy.get("touch_damage_cooldown_left")
	var failures: Array[String] = []
	if not is_equal_approx(before, during):
		failures.append("Touch cooldown advanced while SceneTree was paused")
	if not is_equal_approx(before, after):
		failures.append("Resume skipped the remaining touch cooldown")
	var traces: Array[Dictionary] = []
	for hz in [30, 60, 120]:
		Engine.physics_ticks_per_second = hz
		enemy.set("touch_damage_last_physics_delta", 1.0 / float(hz))
		enemy.set("touch_damage_cooldown_left", 0.5)
		for frame in 3:
			await physics_frame
		var remaining_before: float = enemy.get("touch_damage_cooldown_left")
		var deadline_before: int = enemy.call("get_touch_damage_cooldown_deadline_physics_frame")
		var pause_start := Engine.get_physics_frames()
		paused = true
		await create_timer(0.15, true).timeout
		if not is_equal_approx(float(enemy.get("touch_damage_cooldown_left")), remaining_before):
			failures.append("Paused read changed at %d Hz" % hz)
		var pause_length := Engine.get_physics_frames() - pause_start
		paused = false
		var resumed_deadline: int = enemy.call("get_touch_damage_cooldown_deadline_physics_frame")
		if resumed_deadline != deadline_before + pause_length:
			failures.append("Deadline did not move by exactly paused frames at %d Hz" % hz)
		if bool(enemy.call("is_touch_damage_cooldown_ready", resumed_deadline - 1)):
			failures.append("Cooldown became ready one tick too early at %d Hz" % hz)
		if not bool(enemy.call("is_touch_damage_cooldown_ready", resumed_deadline)):
			failures.append("Cooldown missed its exact readiness tick at %d Hz" % hz)
		while Engine.get_physics_frames() < resumed_deadline:
			await physics_frame
		if float(enemy.get("touch_damage_cooldown_left")) != 0.0:
			failures.append("Resumed clock failed to reach zero at %d Hz" % hz)
		# Starting, clearing and restarting during pause must use the frozen clock.
		paused = true
		enemy.set("touch_damage_cooldown_left", 0.3)
		await create_timer(0.1, true).timeout
		if not is_equal_approx(float(enemy.get("touch_damage_cooldown_left")), 0.3):
			failures.append("Cooldown started during pause advanced at %d Hz" % hz)
		enemy.set("touch_damage_cooldown_left", 0.0)
		if not bool(enemy.call("is_touch_damage_cooldown_ready")):
			failures.append("Clearing paused cooldown failed")
		enemy.set("touch_damage_cooldown_left", 0.2)
		paused = false
		if not is_equal_approx(float(enemy.get("touch_damage_cooldown_left")), 0.2):
			failures.append("Rearming paused cooldown failed")
		traces.append({"hz": hz, "paused_ticks": pause_length, "remaining": remaining_before})
	Engine.physics_ticks_per_second = 60
	# Native ALWAYS nodes do not receive the pause transition and keep their clock.
	var always_enemy: Node = scene.instantiate()
	always_enemy.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(always_enemy)
	always_enemy.set_physics_process(false)
	always_enemy.set("touch_damage_cooldown_left", 0.5)
	paused = true
	await create_timer(0.15, true).timeout
	if float(always_enemy.get("touch_damage_cooldown_left")) >= 0.5:
		failures.append("Explicit ALWAYS node was accidentally paused")
	paused = false
	always_enemy.queue_free()
	always_enemy = null
	print("TOUCH_COOLDOWN_PAUSE ", JSON.stringify({"before": before, "during": during, "after": after, "paused_engine_ticks": paused_ticks, "traces": traces, "failures": failures}))
	enemy.queue_free()
	enemy = null
	scene = null
	for frame in 4:
		await process_frame
	await root.get_node("PublicRoomLease").request_application_shutdown(0 if failures.is_empty() else 1)
