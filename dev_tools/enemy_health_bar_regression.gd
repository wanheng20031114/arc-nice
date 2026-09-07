extends SceneTree

## Runs the authored bar through lifecycle/health boundaries and measures the
## previous Range step-snapping path against integer, changed-only projection.
var _bars: Array[ProgressBar] = []
var _failures: Array[String] = []
var _value_events := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var packed := load("res://scene/enemy/ui/enemy_health_bar.tscn") as PackedScene
	for index in 300:
		var bar := packed.instantiate() as ProgressBar
		root.add_child(bar)
		_bars.append(bar)
	var subject := _bars[0]
	subject.value_changed.connect(_on_value_changed)
	for state in [[100, 100, 100, false], [50, 100, 50, true], [0, 100, 0, false], [-5, 100, 0, false], [200, 100, 100, false], [1, 0, 1, false], [35, 60, 35, true]]:
		subject.call("set_health", state[0], state[1])
		_check(subject.value == state[2] and subject.visible == state[3], "Health boundary %s" % str(state))
	var changes_before_replay := _value_events
	for iteration in 30:
		subject.call("set_health", 35, 60)
	_check(_value_events == changes_before_replay, "Identical snapshots emitted value_changed")
	_check(subject.step == 0.0, "Integer health still uses decimal snapping")
	var results := {}
	for mode in ["legacy", "optimized"]:
		for bar in _bars:
			bar.step = 1.0 if mode == "legacy" else 0.0
		var started := Time.get_ticks_usec()
		for iteration in 200:
			var health := 70 - iteration % 40
			for bar in _bars:
				if mode == "legacy":
					_legacy_set_health(bar, health, 100)
				else:
					bar.call("set_health", health, 100)
		results[mode + "_60000_changes_usec"] = Time.get_ticks_usec() - started
		started = Time.get_ticks_usec()
		for iteration in 200:
			for bar in _bars:
				if mode == "legacy":
					_legacy_set_health(bar, 50, 100)
				else:
					bar.call("set_health", 50, 100)
		results[mode + "_60000_replays_usec"] = Time.get_ticks_usec() - started
	for bar in _bars:
		bar.queue_free()
	_bars.clear()
	for frame in 3:
		await process_frame
	results["failures"] = _failures
	print("HEALTH_BAR_REGRESSION ", JSON.stringify(results))
	quit(0 if _failures.is_empty() else 1)


func _legacy_set_health(bar: ProgressBar, health: int, maximum: int) -> void:
	bar.max_value = maxi(maximum, 1)
	bar.value = clampi(health, 0, int(bar.max_value))
	bar.visible = health > 0 and health < maximum


func _on_value_changed(_health: float) -> void:
	_value_events += 1


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)
