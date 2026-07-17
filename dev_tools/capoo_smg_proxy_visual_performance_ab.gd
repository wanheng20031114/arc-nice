extends SceneTree

const SMG_SCENE := preload("res://scene/enemy/capoo_smg.tscn")
const SMG_CONFIG := preload("res://resources/config/enemies/capoo_smg.tres")

const PROXY_COUNT := 64
const ACTIONS_PER_ROUND := 512
const SAMPLE_PAIRS := 6
const DRAIN_SECONDS := 0.18

var failures: Array[String] = []
var fixture: Node2D = null
var proxies: Array[CapooSMG] = []
var action_id := 0
var original_allocation_free_mode := true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	original_allocation_free_mode = CapooSMG.allocation_free_proxy_visuals_enabled
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

	await _measure_mode(false)
	await _measure_mode(true)
	var legacy_samples := PackedFloat64Array()
	var timer_samples := PackedFloat64Array()
	for pair_index in range(SAMPLE_PAIRS):
		if pair_index % 2 == 0:
			legacy_samples.append(await _measure_mode(false))
			timer_samples.append(await _measure_mode(true))
		else:
			timer_samples.append(await _measure_mode(true))
			legacy_samples.append(await _measure_mode(false))

	var legacy_median := _median(legacy_samples)
	var timer_median := _median(timer_samples)
	_expect(
		_sum_tween_actions() == ACTIONS_PER_ROUND
		and _sum_timer_actions() == 0,
		"Final legacy phase must route every action through its Tween path."
	)
	await _measure_mode(true)
	_expect(
		_sum_timer_actions() == ACTIONS_PER_ROUND
		and _sum_tween_actions() == 0,
		"Allocation-free phase must route every action through one timer state."
	)
	_expect(
		_all_proxies_dormant(),
		"Completed proxy visuals must disable processing and hide every muzzle flash."
	)
	print(
		(
			"CAPOO_SMG_PROXY_VISUAL_AB actions=%d proxies=%d "
			+ "legacy_tweens=%d timer_tweens=0 "
			+ "legacy_dispatch_median_usec=%.0f timer_dispatch_median_usec=%.0f "
			+ "dispatch_speedup=%.3fx"
		)
		% [
			ACTIONS_PER_ROUND,
			PROXY_COUNT,
			ACTIONS_PER_ROUND * 2,
			legacy_median,
			timer_median,
			legacy_median / maxf(timer_median, 1.0),
		]
	)

	CapooSMG.allocation_free_proxy_visuals_enabled = original_allocation_free_mode
	current_scene = null
	fixture.queue_free()
	for _cleanup_frame in range(4):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("CAPOO_SMG_PROXY_VISUAL_PERFORMANCE_AB_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _measure_mode(allocation_free: bool) -> float:
	CapooSMG.allocation_free_proxy_visuals_enabled = allocation_free
	for proxy in proxies:
		proxy.proxy_visual_timer_action_count = 0
		proxy.proxy_visual_tween_action_count = 0
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


func _sum_tween_actions() -> int:
	var total := 0
	for proxy in proxies:
		total += proxy.proxy_visual_tween_action_count
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
