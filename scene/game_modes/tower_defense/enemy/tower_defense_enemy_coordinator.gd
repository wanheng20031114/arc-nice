extends Node
class_name TowerDefenseEnemyCoordinator

signal wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
)
signal wave_completed
signal enemy_reached_home(enemy: Enemy, gate_cell: Vector2i)
signal enemy_spawned(enemy: Enemy)
signal enemy_removed(enemy_id: int)

var enemy_spawn_points: Array[Marker2D] = []
var enemy_spawn_points_by_name: Dictionary[StringName, Marker2D] = {}
var active_wave_spawn_points: Array[Marker2D] = []
var pending_enemy_configs: Array[EnemyConfig] = []
var pending_enemy_xirang_kill_rewards: Array[int] = []
var active_wave_enemy_ids: Dictionary = {}
var hud_alive_enemy_ids: Dictionary = {}
var pending_multiplayer_enemy_escape_ids: Dictionary = {}

var spawn_point_configuration_valid := true
var pending_enemy_config_index := 0
var next_multiplayer_enemy_net_id := 1
var enemy_retarget_time_left := 0.0
var enemy_retarget_sweep_remaining := 0
var enemy_retarget_cursor := 0

var _random_generator: RandomNumberGenerator


func setup(
	random_generator: RandomNumberGenerator,
	spawn_points: Array[Marker2D],
	spawn_points_by_name: Dictionary[StringName, Marker2D],
	wave_spawn_points: Array[Marker2D],
	queued_configs: Array[EnemyConfig],
	queued_rewards: Array[int],
	active_ids: Dictionary,
	hud_ids: Dictionary,
	pending_escape_ids: Dictionary
) -> void:
	assert(random_generator != null, "EnemyCoordinator 必须复用运行时 RNG。")
	_random_generator = random_generator
	enemy_spawn_points = spawn_points
	enemy_spawn_points_by_name = spawn_points_by_name
	active_wave_spawn_points = wave_spawn_points
	pending_enemy_configs = queued_configs
	pending_enemy_xirang_kill_rewards = queued_rewards
	active_wave_enemy_ids = active_ids
	hud_alive_enemy_ids = hud_ids
	pending_multiplayer_enemy_escape_ids = pending_escape_ids


func collect_spawn_points(spawn_points_root: Node2D) -> void:
	enemy_spawn_points.clear()
	enemy_spawn_points_by_name.clear()
	active_wave_spawn_points.clear()
	spawn_point_configuration_valid = true
	if spawn_points_root == null:
		push_error("EnemyCoordinator 缺少 EnemySpawnPoints 根节点。")
		spawn_point_configuration_valid = false
		return
	for child in spawn_points_root.get_children():
		var spawn_point := child as Marker2D
		if spawn_point == null:
			continue
		var spawn_name := StringName(spawn_point.name)
		if enemy_spawn_points_by_name.has(spawn_name):
			push_error("EnemySpawnPoints 包含重复名称：%s" % String(spawn_name))
			spawn_point_configuration_valid = false
			continue
		enemy_spawn_points.append(spawn_point)
		enemy_spawn_points_by_name[spawn_name] = spawn_point
	if enemy_spawn_points.is_empty():
		push_warning("EnemySpawnPoints 下没有可用的 Marker2D 刷新点。")


func inspect_spawn_points(wave_config: WaveConfig) -> Dictionary:
	var points: Array[Marker2D] = []
	if wave_config == null or not spawn_point_configuration_valid:
		return {"valid": false, "points": points, "error": ""}
	var enabled_names := wave_config.get_enabled_spawn_point_names()
	if enabled_names.is_empty():
		return {
			"valid": false,
			"points": points,
			"error": "波次 %s 没有启用任何出生点。" % wave_config.get_flow_display_name(),
		}
	for spawn_name in enabled_names:
		var marker := enemy_spawn_points_by_name.get(spawn_name) as Marker2D
		if marker == null:
			return {
				"valid": false,
				"points": points,
				"error": (
					"波次 %s 引用了场景中不存在的出生点 %s。"
					% [wave_config.get_flow_display_name(), String(spawn_name)]
				),
			}
		points.append(marker)
	return {"valid": true, "points": points, "error": ""}


func resolve_spawn_points(wave_config: WaveConfig) -> bool:
	active_wave_spawn_points.clear()
	var resolution := inspect_spawn_points(wave_config)
	if not bool(resolution.get("valid", false)):
		var error_message := str(resolution.get("error", ""))
		if not error_message.is_empty():
			push_error(error_message)
		return false
	active_wave_spawn_points.assign(resolution.get("points", []))
	return not active_wave_spawn_points.is_empty()


func begin_wave(
	wave_config: WaveConfig,
	progression_config: TowerDefenseProgressionConfig,
	player_count: int,
	resolve_enemy_config: Callable
) -> int:
	assert(_random_generator != null, "EnemyCoordinator 尚未 setup。")
	assert(resolve_enemy_config.is_valid(), "EnemyCoordinator 缺少命运配置解析器。")
	clear_queue()
	if wave_config == null or progression_config == null:
		return 0
	if wave_config.spawn_order == WaveConfig.SpawnOrder.ENTRY_ROUND_ROBIN:
		_build_entry_round_robin_queue(
			wave_config, progression_config, player_count, resolve_enemy_config
		)
	else:
		_build_shuffled_queue(
			wave_config, progression_config, player_count, resolve_enemy_config
		)
	return pending_enemy_configs.size()


func _build_shuffled_queue(
	wave_config: WaveConfig,
	progression_config: TowerDefenseProgressionConfig,
	player_count: int,
	resolve_enemy_config: Callable
) -> void:
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var scaled_count := progression_config.get_scaled_enemy_count(
			maxi(entry.count, 0), maxi(player_count, 1)
		)
		for _enemy_index in range(scaled_count):
			var resolved := resolve_enemy_config.call(entry.enemy_config) as EnemyConfig
			pending_enemy_configs.append(resolved)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(resolved)
			)
	for source_index in range(pending_enemy_configs.size() - 1, 0, -1):
		var target_index := _random_generator.randi_range(0, source_index)
		var config := pending_enemy_configs[source_index]
		pending_enemy_configs[source_index] = pending_enemy_configs[target_index]
		pending_enemy_configs[target_index] = config
		var reward := pending_enemy_xirang_kill_rewards[source_index]
		pending_enemy_xirang_kill_rewards[source_index] = (
			pending_enemy_xirang_kill_rewards[target_index]
		)
		pending_enemy_xirang_kill_rewards[target_index] = reward


func _build_entry_round_robin_queue(
	wave_config: WaveConfig,
	progression_config: TowerDefenseProgressionConfig,
	player_count: int,
	resolve_enemy_config: Callable
) -> void:
	var entries: Array[WaveEnemyEntry] = []
	var remaining_counts: Array[int] = []
	var remaining_total := 0
	for entry in wave_config.enemy_entries:
		if entry == null or entry.enemy_config == null:
			continue
		var scaled_count := maxi(
			progression_config.get_scaled_enemy_count(
				maxi(entry.count, 0), maxi(player_count, 1)
			), 0
		)
		if scaled_count <= 0:
			continue
		entries.append(entry)
		remaining_counts.append(scaled_count)
		remaining_total += scaled_count
	while remaining_total > 0:
		for entry_index in range(entries.size()):
			if remaining_counts[entry_index] <= 0:
				continue
			var entry := entries[entry_index]
			var resolved := resolve_enemy_config.call(entry.enemy_config) as EnemyConfig
			pending_enemy_configs.append(resolved)
			pending_enemy_xirang_kill_rewards.append(
				entry.resolve_xirang_kill_reward(resolved)
			)
			remaining_counts[entry_index] -= 1
			remaining_total -= 1


func tick(
	max_alive_enemies: int,
	spawn_count_per_tick: int,
	spawn_enemy: Callable
) -> int:
	assert(spawn_enemy.is_valid(), "EnemyCoordinator 缺少刷怪命令。")
	var spawned_count := 0
	var spawn_limit := maxi(spawn_count_per_tick, 1)
	for _spawn_index in range(spawn_limit):
		if not has_pending_queue() or active_wave_enemy_ids.size() >= maxi(max_alive_enemies, 1):
			break
		if not bool(spawn_enemy.call(
			pending_enemy_configs[pending_enemy_config_index],
			pending_enemy_xirang_kill_rewards[pending_enemy_config_index]
		)):
			break
		pending_enemy_config_index += 1
		spawned_count += 1
	return spawned_count


func has_pending_queue() -> bool:
	return pending_enemy_config_index < pending_enemy_configs.size()


func clear_queue() -> void:
	pending_enemy_configs.clear()
	pending_enemy_xirang_kill_rewards.clear()
	pending_enemy_config_index = 0


func pick_spawn_point() -> Marker2D:
	if active_wave_spawn_points.is_empty():
		return null
	return active_wave_spawn_points[
		_random_generator.randi_range(0, active_wave_spawn_points.size() - 1)
	]


func get_spawn_marker(marker_name: StringName, spawn_points_root: Node2D) -> Marker2D:
	if marker_name == &"":
		return null
	var marker := enemy_spawn_points_by_name.get(marker_name) as Marker2D
	if marker != null:
		return marker
	if spawn_points_root == null:
		return null
	return spawn_points_root.get_node_or_null(NodePath(String(marker_name))) as Marker2D


func register_external_enemy(enemy: Enemy) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	active_wave_enemy_ids[enemy.get_instance_id()] = true
	enemy_spawned.emit(enemy)


func has_active_enemy(enemy_id: int) -> bool:
	return active_wave_enemy_ids.has(enemy_id)


func remove_active_enemy(enemy_id: int) -> bool:
	return active_wave_enemy_ids.erase(enemy_id)


func clear_active_enemies() -> void:
	active_wave_enemy_ids.clear()


func has_active_enemies() -> bool:
	return not active_wave_enemy_ids.is_empty()


func add_hud_enemy(enemy_id: int) -> bool:
	if hud_alive_enemy_ids.has(enemy_id):
		return false
	hud_alive_enemy_ids[enemy_id] = true
	return true


func remove_hud_enemy(enemy_id: int) -> bool:
	return hud_alive_enemy_ids.erase(enemy_id)


func clear_hud_enemies() -> void:
	hud_alive_enemy_ids.clear()


func hud_enemy_count() -> int:
	return hud_alive_enemy_ids.size()


func add_pending_escape(net_id: int) -> void:
	pending_multiplayer_enemy_escape_ids[net_id] = true


func consume_pending_escape(net_id: int) -> bool:
	return pending_multiplayer_enemy_escape_ids.erase(net_id)


func get_enemy(net_id: int, enemies_by_net_id: Dictionary) -> Enemy:
	if not enemies_by_net_id.has(net_id):
		return null
	var enemy_variant: Variant = enemies_by_net_id.get(net_id)
	if enemy_variant == null or not is_instance_valid(enemy_variant):
		enemies_by_net_id.erase(net_id)
		return null
	return enemy_variant as Enemy


func get_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> Dictionary:
	return {
		"wave_number": wave_number,
		"defeated": defeated,
		"escaped": escaped,
		"resolved": resolved,
		"total": total,
	}


func report_progress(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	wave_progress_changed.emit(wave_number, defeated, escaped, resolved, total)


func report_wave_completed() -> void:
	wave_completed.emit()


func report_enemy_reached_home(enemy: Enemy, gate_cell: Vector2i) -> void:
	enemy_reached_home.emit(enemy, gate_cell)


func report_enemy_removed(enemy_id: int) -> void:
	enemy_removed.emit(enemy_id)


func update_targets(
	delta: float,
	enemy_container: Node,
	boss_enemy: Enemy,
	retarget_interval: float,
	max_per_frame: int,
	assign_targets: Callable
) -> void:
	assert(assign_targets.is_valid(), "EnemyCoordinator 缺少目标分配器。")
	enemy_retarget_time_left = maxf(enemy_retarget_time_left - delta, 0.0)
	if enemy_retarget_time_left <= 0.0 and enemy_retarget_sweep_remaining <= 0:
		enemy_retarget_time_left = retarget_interval
		enemy_retarget_sweep_remaining = enemy_container.get_child_count()
		if (
			boss_enemy != null
			and is_instance_valid(boss_enemy)
			and not boss_enemy.is_dead
			and not boss_enemy.is_advancing_to_home()
		):
			assign_targets.call(boss_enemy, boss_enemy.global_position)
	process_retarget_budget(enemy_container, max_per_frame, assign_targets)


func process_retarget_budget(
	enemy_container: Node,
	max_per_frame: int,
	assign_targets: Callable
) -> void:
	var processed_count := 0
	while enemy_retarget_sweep_remaining > 0 and processed_count < max_per_frame:
		var enemy_count := enemy_container.get_child_count()
		if enemy_count <= 0:
			enemy_retarget_sweep_remaining = 0
			enemy_retarget_cursor = 0
			return
		if enemy_retarget_cursor >= enemy_count:
			enemy_retarget_cursor = 0
		var enemy := enemy_container.get_child(enemy_retarget_cursor) as Enemy
		enemy_retarget_cursor = (enemy_retarget_cursor + 1) % enemy_count
		enemy_retarget_sweep_remaining -= 1
		processed_count += 1
		if enemy == null or enemy.is_dead:
			continue
		assign_targets.call(enemy, enemy.global_position)


func request_retarget() -> void:
	enemy_retarget_time_left = 0.0
