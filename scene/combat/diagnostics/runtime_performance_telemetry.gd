extends Node
class_name RuntimePerformanceTelemetry

const CapooRPGRocketSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_rpg_rocket_simulation_service.gd"
)
const CapooMageFireballSimulationServiceScript := preload(
	"res://scene/combat/simulation/capoo_mage_fireball_simulation_service.gd"
)

const PROJECTILE_GROUP := &"runtime_projectiles"
const DEFAULT_MAX_FRAME_SAMPLES := 3600
const DEFAULT_MAX_SPAWN_BATCH_SAMPLES := 2048
const DEFAULT_COUNT_SAMPLE_INTERVAL_SECONDS := 0.25
const PERCENTILE_KEYS := {
	"p50_ms": 0.50,
	"p95_ms": 0.95,
	"p99_ms": 0.99,
}
const PROJECTILE_SCRIPT_PATHS := {
	"res://scene/combat/projectiles/bullet.gd": true,
	"res://scene/combat/collectibles/collectible_arrow_projectile.gd": true,
	"res://scene/enemy/capoo/capoo_ak47_bullet.gd": true,
	"res://scene/enemy/mechanical_life/combat_robot_gunner_bullet.gd": true,
	"res://scene/enemy/sorcerer/fire_sorcerer_fireball_volley.gd": true,
	"res://scene/enemy/sorcerer/frost_sorcerer_ice_spike.gd": true,
	"res://scene/enemy/yuanshi_insect/yuanshi_insect_fire_projectile.gd": true,
	"res://scene/plant_defense/agave_cannonball.gd": true,
	"res://scene/plant_defense/bamboo_mortar_shell.gd": true,
	"res://scene/player/tango/tango_laser_bullet.gd": true,
	"res://scene/player/tiyi/tiyi_sniper_bullet.gd": true,
	"res://scene/player/weishidaier/weishidaier_skill1_bomb.gd": true,
	"res://scene/boss/linglan/linglan_skill1_sakura_bullet.gd": true,
	"res://scene/boss/linglan/linglan_skill2_sakura_rocket.gd": true,
	"res://scene/boss/linglan/linglan_skill3_light_orb.gd": true,
	"res://scene/boss/linglan/linglan_skill4_light_orb.gd": true,
}

@export_range(1, 36000, 1, "or_greater") var max_frame_samples := (
	DEFAULT_MAX_FRAME_SAMPLES
)
@export_range(1, 10000, 1, "or_greater") var max_spawn_batch_samples := (
	DEFAULT_MAX_SPAWN_BATCH_SAMPLES
)
@export_range(0.05, 10.0, 0.05, "or_greater") var count_sample_interval_seconds := (
	DEFAULT_COUNT_SAMPLE_INTERVAL_SECONDS
)

var runtime_root: Node = null
var is_recording := false
var current_active_enemies := 0
var current_active_projectiles := 0
var peak_active_enemies := 0
var peak_active_projectiles := 0

var _frame_time_samples_ms: Array[float] = []
var _spawn_batch_samples_ms: Array[float] = []
var _frame_sample_write_index := 0
var _spawn_sample_write_index := 0
var _count_sample_time_left := 0.0
var _last_frame_tick_usec := -1


func _ready() -> void:
	set_process(false)


func start(target_runtime_root: Node) -> void:
	runtime_root = target_runtime_root
	is_recording = runtime_root != null and is_instance_valid(runtime_root)
	_count_sample_time_left = 0.0
	_last_frame_tick_usec = Time.get_ticks_usec() if is_recording else -1
	set_process(is_recording)
	if is_recording:
		sample_runtime_counts(runtime_root)


func stop() -> void:
	is_recording = false
	runtime_root = null
	_last_frame_tick_usec = -1
	set_process(false)


func reset() -> void:
	_frame_time_samples_ms.clear()
	_spawn_batch_samples_ms.clear()
	_frame_sample_write_index = 0
	_spawn_sample_write_index = 0
	_count_sample_time_left = 0.0
	_last_frame_tick_usec = Time.get_ticks_usec() if is_recording else -1
	current_active_enemies = 0
	current_active_projectiles = 0
	peak_active_enemies = 0
	peak_active_projectiles = 0


func _process(delta: float) -> void:
	if not is_recording:
		return
	if runtime_root == null or not is_instance_valid(runtime_root):
		stop()
		return

	var now_usec := Time.get_ticks_usec()
	var frame_time_ms := maxf(delta, 0.0) * 1000.0
	if _last_frame_tick_usec >= 0:
		frame_time_ms = float(maxi(now_usec - _last_frame_tick_usec, 0)) / 1000.0
	_last_frame_tick_usec = now_usec
	record_frame_time_ms(frame_time_ms)
	_count_sample_time_left -= maxf(delta, 0.0)
	if _count_sample_time_left > 0.0:
		return
	_count_sample_time_left = maxf(count_sample_interval_seconds, 0.05)
	sample_runtime_counts(runtime_root)


func record_frame_time_ms(frame_time_ms: float) -> void:
	if frame_time_ms < 0.0 or not is_finite(frame_time_ms):
		return
	_append_bounded_sample(
		_frame_time_samples_ms,
		frame_time_ms,
		maxi(max_frame_samples, 1),
		true
	)


func begin_enemy_spawn_batch() -> int:
	return Time.get_ticks_usec()


func end_enemy_spawn_batch(started_at_usec: int) -> float:
	var elapsed_usec := maxi(Time.get_ticks_usec() - started_at_usec, 0)
	var elapsed_ms := float(elapsed_usec) / 1000.0
	record_enemy_spawn_batch_time_ms(elapsed_ms)
	return elapsed_ms


func record_enemy_spawn_batch_time_ms(batch_time_ms: float) -> void:
	if batch_time_ms < 0.0 or not is_finite(batch_time_ms):
		return
	_append_bounded_sample(
		_spawn_batch_samples_ms,
		batch_time_ms,
		maxi(max_spawn_batch_samples, 1),
		false
	)


func sample_runtime_counts(target_root: Node = null) -> Dictionary:
	var inspected_root := target_root if target_root != null else runtime_root
	var counts := {
		"active_enemies": 0,
		"active_projectiles": 0,
	}
	if inspected_root == null or not is_instance_valid(inspected_root):
		return counts

	_accumulate_runtime_counts(inspected_root, counts)
	current_active_enemies = int(counts["active_enemies"])
	current_active_projectiles = int(counts["active_projectiles"])
	peak_active_enemies = maxi(peak_active_enemies, current_active_enemies)
	peak_active_projectiles = maxi(
		peak_active_projectiles,
		current_active_projectiles
	)
	return counts


func get_summary() -> Dictionary:
	return {
		"frame_time": _summarize_samples(_frame_time_samples_ms),
		"enemy_spawn_batch": _summarize_samples(_spawn_batch_samples_ms),
		"current": {
			"active_enemies": current_active_enemies,
			"active_projectiles": current_active_projectiles,
		},
		"peak": {
			"active_enemies": peak_active_enemies,
			"active_projectiles": peak_active_projectiles,
		},
	}


func format_summary(prefix: String = "RUNTIME_PERFORMANCE_TELEMETRY") -> String:
	var summary := get_summary()
	var frame := summary["frame_time"] as Dictionary
	var spawn := summary["enemy_spawn_batch"] as Dictionary
	var current := summary["current"] as Dictionary
	var peak := summary["peak"] as Dictionary
	return (
		"%s frame_samples=%d frame_p50_ms=%.3f frame_p95_ms=%.3f "
		+ "frame_p99_ms=%.3f frame_max_ms=%.3f spawn_samples=%d "
		+ "spawn_p50_ms=%.3f spawn_p95_ms=%.3f spawn_p99_ms=%.3f "
		+ "spawn_max_ms=%.3f active_enemies=%d active_projectiles=%d "
		+ "peak_enemies=%d peak_projectiles=%d"
	) % [
		prefix,
		int(frame["sample_count"]),
		float(frame["p50_ms"]),
		float(frame["p95_ms"]),
		float(frame["p99_ms"]),
		float(frame["max_ms"]),
		int(spawn["sample_count"]),
		float(spawn["p50_ms"]),
		float(spawn["p95_ms"]),
		float(spawn["p99_ms"]),
		float(spawn["max_ms"]),
		int(current["active_enemies"]),
		int(current["active_projectiles"]),
		int(peak["active_enemies"]),
		int(peak["active_projectiles"]),
	]


func _append_bounded_sample(
	target: Array[float],
	value: float,
	capacity: int,
	is_frame_sample: bool
) -> void:
	var write_index := _frame_sample_write_index if is_frame_sample else _spawn_sample_write_index
	if target.size() > capacity:
		target.resize(capacity)
		write_index = 0
	if target.size() < capacity:
		target.append(value)
	else:
		target[write_index] = value
		write_index = (write_index + 1) % capacity
	if is_frame_sample:
		_frame_sample_write_index = write_index
	else:
		_spawn_sample_write_index = write_index


func _summarize_samples(samples: Array[float]) -> Dictionary:
	var summary := {
		"sample_count": samples.size(),
		"p50_ms": 0.0,
		"p95_ms": 0.0,
		"p99_ms": 0.0,
		"max_ms": 0.0,
	}
	if samples.is_empty():
		return summary

	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	for percentile_key: String in PERCENTILE_KEYS:
		summary[percentile_key] = _nearest_rank_percentile(
			sorted_samples,
			float(PERCENTILE_KEYS[percentile_key])
		)
	summary["max_ms"] = sorted_samples.back()
	return summary


func _nearest_rank_percentile(sorted_samples: Array[float], percentile: float) -> float:
	if sorted_samples.is_empty():
		return 0.0
	var rank := ceili(clampf(percentile, 0.0, 1.0) * sorted_samples.size())
	var index := clampi(rank - 1, 0, sorted_samples.size() - 1)
	return sorted_samples[index]


func _accumulate_runtime_counts(node: Node, counts: Dictionary) -> void:
	if _is_active_enemy(node):
		counts["active_enemies"] = int(counts["active_enemies"]) + 1
	if _is_active_projectile(node):
		counts["active_projectiles"] = int(counts["active_projectiles"]) + 1
	var rpg_service := node as CapooRPGRocketSimulationServiceScript
	if rpg_service != null:
		counts["active_projectiles"] = (
			int(counts["active_projectiles"]) + rpg_service.get_live_count()
		)
	var mage_service := node as CapooMageFireballSimulationServiceScript
	if mage_service != null:
		counts["active_projectiles"] = (
			int(counts["active_projectiles"]) + mage_service.get_live_count()
		)
	for child in node.get_children():
		_accumulate_runtime_counts(child, counts)


func _is_active_enemy(node: Node) -> bool:
	var enemy := node as Enemy
	return (
		enemy != null
		and not enemy.is_dead
		and not enemy.is_queued_for_deletion()
		and _is_pool_instance_active(enemy)
	)


func _is_active_projectile(node: Node) -> bool:
	if node.is_queued_for_deletion() or not _is_pool_instance_active(node):
		return false
	if node.is_in_group(PROJECTILE_GROUP):
		return true
	var script := node.get_script() as Script
	return script != null and PROJECTILE_SCRIPT_PATHS.has(script.resource_path)




func _is_pool_instance_active(node: Node) -> bool:
	return not node.has_meta(&"pool_active") or bool(node.get_meta(&"pool_active"))
