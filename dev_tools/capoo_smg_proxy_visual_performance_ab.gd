extends SceneTree

const SMG_SCENE := preload("res://scene/enemy/capoo/capoo_smg.tscn")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")

const PROXY_COUNT := 64
const ACTIONS_PER_ROUND := 512
const SAMPLE_PAIRS := 6
const DRAIN_SECONDS := 0.18

var failures: Array[String] = []
var fixture: Node2D = null
var proxies: Array[CapooSMG] = []
var action_id := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	fixture = Node2D.new()
	fixture.name = "CapooSmgProxyVisualPerformanceAB"
	root.add_child(fixture)
	current_scene = fixture
	for proxy_index in range(PROXY_COUNT):
		var proxy := SMG_SCENE.instantiate() as CapooSMG
		fixture.add_child(proxy)
		proxy.global_position = Vector2(
			float(proxy_index % 16) * 20.0,
			float(proxy_index / 16) * 20.0
		)
		proxy.setup(SMG_CONFIG, null)
		proxy.configure_multiplayer_proxy()
		proxies.append(proxy)
	await process_frame

	await _measure_round()
	var timer_samples := PackedFloat64Array()
	for _sample_index in range(SAMPLE_PAIRS):
		timer_samples.append(await _measure_round())

	var timer_median := _median(timer_samples)
	_expect(
		_sum_timer_actions() == ACTIONS_PER_ROUND
		and timer_median > 0.0,
		"Every proxy action must use the allocation-free timer state."
	)
	_expect(
		_all_proxies_dormant(),
		"Completed proxy visuals must disable processing and hide every muzzle flash."
	)
	print(
		(
			"CAPOO_SMG_PROXY_VISUAL_DATA actions=%d proxies=%d "
			+ "timer_dispatch_median_usec=%.0f"
		)
		% [
			ACTIONS_PER_ROUND,
			PROXY_COUNT,
			timer_median,
		]
	)

	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("CAPOO_SMG_PROXY_VISUAL_PERFORMANCE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_round() -> float:
	for proxy in proxies:
		proxy.proxy_visual_timer_action_count = 0
	var started_usec := Time.get_ticks_usec()
	for request_index in range(ACTIONS_PER_ROUND):
		var proxy := proxies[request_index % proxies.size()]
		action_id += 1
		var direction := Vector2.LEFT if request_index % 2 == 0 else Vector2.RIGHT
		proxy.play_multiplayer_enemy_action(&"fire", direction, action_id)
	var elapsed_usec := float(Time.get_ticks_usec() - started_usec)
	await create_timer(DRAIN_SECONDS).timeout
	return elapsed_usec


func _sum_timer_actions() -> int:
	var total := 0
	for proxy in proxies:
		total += proxy.proxy_visual_timer_action_count
	return total


func _all_proxies_dormant() -> bool:
	for proxy in proxies:
		if proxy.is_processing() or proxy.muzzle_flash.visible:
			return false
	return true


func _median(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
