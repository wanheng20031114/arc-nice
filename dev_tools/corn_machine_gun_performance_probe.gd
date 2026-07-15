extends SceneTree

# High-density diagnostic for the CornMachineGun hot paths. Timings are
# deliberately informational: the regression gates protect six-shot cadence,
# Host-only raycasts/damage, one network record per burst, caller-owned target
# buffers, and the absence of projectile/node growth.
const CORN_SCENE := preload("res://scene/plant_defense/corn_machine_gun.tscn")
const CORN_CONFIG := preload(
	"res://resources/config/plant_defense/corn_machine_gun.tres"
)
const ENEMY_SCENE := preload("res://scene/enemy/enemy.tscn")

const AUTHORITY_TOWER_COUNT := 128
const PROXY_TOWER_COUNT := 128
const ENEMY_COUNT := 300
const BURST_CATCHUP_SECONDS := 0.30
const TARGET_POSITION := Vector2(80.0, 0.0)

var failures: Array[String] = []
var runtime: CornRuntimeStub = null
var authorities: Array[CornMachineGun] = []
var proxies: Array[CornMachineGun] = []
var enemies: Array[Enemy] = []


class CornRuntimeStub:
	extends Node2D

	var candidates: Array[Enemy] = []
	var expected_queries_per_sweep := 0
	var query_call_count := 0
	var reused_output_buffers := true
	var first_sweep_buffers: Array = []
	var queued_burst_count := 0
	var damage_call_count := 0

	func query_combat_targets_into(
		_center: Vector2,
		_radius: float,
		result: Array[Enemy],
		max_count: int = 0
	) -> void:
		var sweep_slot := (
			query_call_count % expected_queries_per_sweep
			if expected_queries_per_sweep > 0
			else 0
		)
		if query_call_count < expected_queries_per_sweep:
			first_sweep_buffers.append(result)
		elif query_call_count < expected_queries_per_sweep * 2:
			reused_output_buffers = reused_output_buffers and is_same(
				first_sweep_buffers[sweep_slot],
				result
			)
		query_call_count += 1
		result.clear()
		for candidate in candidates:
			result.append(candidate)
		if max_count > 0 and result.size() > max_count:
			result.resize(max_count)

	func queue_corn_machine_gun_burst_visual(
		_plant_net_id: int,
		_action_id: int,
		_direction: Vector2
	) -> void:
		queued_burst_count += 1

	func apply_authoritative_plant_enemy_damage(
		_plant_net_id: int,
		_enemy: Enemy,
		_damage: int,
		_impact_direction: Vector2,
		_damage_type: EnemyConfig.DamageType
	) -> void:
		damage_call_count += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	runtime = CornRuntimeStub.new()
	runtime.name = "CornMachineGunPerformanceFixture"
	root.add_child(runtime)
	current_scene = runtime

	_spawn_frozen_enemies()
	_spawn_towers(AUTHORITY_TOWER_COUNT, false, authorities)
	_spawn_towers(PROXY_TOWER_COUNT, true, proxies)
	await process_frame
	await physics_frame

	_expect(
		enemies.size() == ENEMY_COUNT,
		"Corn density probe must instantiate exactly 300 frozen enemies."
	)
	_expect(
		authorities.size() == AUTHORITY_TOWER_COUNT
		and proxies.size() == PROXY_TOWER_COUNT,
		"Corn density probe must instantiate all 256 authored towers."
	)

	runtime.expected_queries_per_sweep = authorities.size()
	var first_acquisition_ms := _measure_target_acquisition_sweep()
	var second_acquisition_ms := _measure_target_acquisition_sweep()
	_expect(
		runtime.query_call_count == authorities.size() * 2
		and runtime.reused_output_buffers,
		"Every dense Corn tower must reuse its caller-owned candidate array across sweeps."
	)

	var nodes_before_bursts := _count_subtree_nodes(runtime)
	var authority_burst_ms := _measure_authority_bursts()
	var nodes_after_authority := _count_subtree_nodes(runtime)
	var proxy_burst_ms := _measure_proxy_bursts()
	var nodes_after_proxy := _count_subtree_nodes(runtime)
	var expected_shots := authorities.size() * CORN_CONFIG.attack_burst_count
	_expect(
		runtime.queued_burst_count == authorities.size(),
		"Dense Host fire must queue exactly one network visual record per six-shot burst."
	)
	_expect(
		runtime.damage_call_count == expected_shots,
		"Dense Host fire must preserve exactly six authoritative hits per tower."
	)
	_expect(
		nodes_before_bursts == nodes_after_authority
		and nodes_before_bursts == nodes_after_proxy,
		"Corn bursts must reuse authored visuals and create no projectile/effect nodes."
	)

	print(
		(
			"CORN_MACHINE_GUN_DENSITY_PROBE authority_towers=%d proxy_towers=%d "
			+ "enemies=%d acquisition_ms=%.3f/%.3f authority_bursts_ms=%.3f "
			+ "proxy_bursts_ms=%.3f host_rays=%d host_hits=%d queued_actions=%d nodes=%d"
		)
		% [
			authorities.size(),
			proxies.size(),
			enemies.size(),
			first_acquisition_ms,
			second_acquisition_ms,
			authority_burst_ms,
			proxy_burst_ms,
			expected_shots,
			runtime.damage_call_count,
			runtime.queued_burst_count,
			nodes_after_proxy,
		]
	)
	await _finish()


func _spawn_frozen_enemies() -> void:
	for enemy_index in range(ENEMY_COUNT):
		var enemy := ENEMY_SCENE.instantiate() as Enemy
		if enemy == null:
			continue
		runtime.add_child(enemy)
		if enemy_index == 0:
			enemy.global_position = TARGET_POSITION
			enemy.collision_layer = 4
		else:
			# The full candidate population stays inside the attack radius while
			# only the nearest target participates in physics. This isolates the
			# tower's dense query/raycast cost from 299 overlapping broadphase hits.
			enemy.global_position = Vector2(
				90.0 + float((enemy_index - 1) % 20) * 3.0,
				-56.0 + float((enemy_index - 1) / 20) * 8.0
			)
			enemy.collision_layer = 0
		enemy.collision_mask = 0
		enemy.is_dead = false
		enemy.set_process(false)
		enemy.set_physics_process(false)
		enemy.touch_damage_area.monitoring = false
		enemy.touch_damage_area.monitorable = false
		enemy.touch_damage_area.collision_layer = 0
		enemy.touch_damage_area.collision_mask = 0
		enemies.append(enemy)
		runtime.candidates.append(enemy)


func _spawn_towers(
	count: int,
	as_proxy: bool,
	output: Array[CornMachineGun]
) -> void:
	var footprint: Array[Vector2i] = []
	for tower_index in range(count):
		var tower := CORN_SCENE.instantiate() as CornMachineGun
		if tower == null:
			continue
		runtime.add_child(tower)
		tower.global_position = Vector2.ZERO
		tower.set_meta(&"net_id", tower_index + 1 + (10000 if as_proxy else 0))
		tower.setup(CORN_CONFIG, null, footprint, as_proxy)
		tower.attack_timer.stop()
		tower.call("_stop_idle_aim")
		# Audio concurrency is independently smoke-tested. Detaching the stream
		# keeps this CPU diagnostic focused on targeting, raycasts and visuals.
		tower.fire_audio.stream = null
		output.append(tower)


func _measure_target_acquisition_sweep() -> float:
	var started_usec := Time.get_ticks_usec()
	for tower in authorities:
		var target := tower.call("_select_nearest_visible_enemy") as Enemy
		_expect(
			target == enemies[0],
			"Dense target acquisition must keep nearest-visible first-hit semantics."
		)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_authority_bursts() -> float:
	var started_usec := Time.get_ticks_usec()
	for tower in authorities:
		var queries_before := tower.get_hitscan_query_count()
		tower.call("_start_authoritative_burst", Vector2.RIGHT)
		tower.call("_physics_process", BURST_CATCHUP_SECONDS)
		_expect(
			tower.get_hitscan_query_count() - queries_before
			== CORN_CONFIG.attack_burst_count,
			"Every dense Host tower must cast exactly one ray per authored shot."
		)
		_expect(
			not tower.burst_active and not tower.is_physics_processing(),
			"Completed Host bursts must immediately leave the per-frame physics path."
		)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _measure_proxy_bursts() -> float:
	var started_usec := Time.get_ticks_usec()
	for tower in proxies:
		var queries_before := tower.get_hitscan_query_count()
		tower.play_multiplayer_burst(Vector2.RIGHT, 1, 0.0)
		tower.call("_physics_process", BURST_CATCHUP_SECONDS)
		_expect(
			tower.get_hitscan_query_count() == queries_before,
			"Dense proxy playback must never cast a combat ray."
		)
		_expect(
			not tower.burst_active and not tower.is_physics_processing(),
			"Completed proxy bursts must immediately leave the per-frame physics path."
		)
	return float(Time.get_ticks_usec() - started_usec) / 1000.0


func _count_subtree_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_subtree_nodes(child)
	return count


func _finish() -> void:
	for tower in authorities:
		if tower != null and is_instance_valid(tower):
			tower.attack_timer.stop()
			tower.idle_aim_timer.stop()
			tower.fire_audio.stop()
	for tower in proxies:
		if tower != null and is_instance_valid(tower):
			tower.attack_timer.stop()
			tower.idle_aim_timer.stop()
			tower.fire_audio.stop()
	authorities.clear()
	proxies.clear()
	enemies.clear()
	current_scene = null
	if runtime != null and is_instance_valid(runtime):
		runtime.queue_free()
	for _cleanup_index in range(8):
		await process_frame
		await physics_frame
	if failures.is_empty():
		print("CORN_MACHINE_GUN_PERFORMANCE_PROBE_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
