extends RefCounted


## 生成器与内容测试共用同一份语义签名，避免把 ResourceSaver 的内部 id 当成内容差异。
static func get_wave_signature(wave_config: WaveConfig) -> String:
	var enemy_entries: Array[Dictionary] = []
	for entry in wave_config.enemy_entries:
		enemy_entries.append({
			"enemy_config": (
				entry.enemy_config.resource_path
				if entry != null and entry.enemy_config != null
				else ""
			),
			"count": entry.count if entry != null else 0,
			"xirang_kill_reward_override": (
				entry.xirang_kill_reward_override if entry != null else -1
			),
		})
	var exits: Array[Dictionary] = []
	for flow_exit in wave_config.exits:
		exits.append({
			"exit_name": String(flow_exit.exit_name) if flow_exit != null else "",
			"target_step_id": (
				String(flow_exit.get_target_step_id()) if flow_exit != null else ""
			),
			"condition_key": String(flow_exit.condition_key) if flow_exit != null else "",
		})
	return JSON.stringify({
		"wave_name": wave_config.wave_name,
		"enemy_entries": enemy_entries,
		"spawn_point_mask": wave_config.spawn_point_mask,
		"spawn_point_order": wave_config.spawn_point_order,
		"spawn_order": wave_config.spawn_order,
		"spawn_interval": wave_config.spawn_interval,
		"spawn_count_per_tick": wave_config.spawn_count_per_tick,
		"max_alive_enemies": wave_config.max_alive_enemies,
		"music": _resource_path(wave_config.music),
		"post_wave_music": _resource_path(wave_config.post_wave_music),
		"step_id": String(wave_config.step_id),
		"display_name": wave_config.display_name,
		"post_clear_rest_duration": wave_config.post_clear_rest_duration,
		"exits": exits,
		"editor_position": [wave_config.editor_position.x, wave_config.editor_position.y],
	})


static func has_test_label(wave_config: WaveConfig) -> bool:
	return (
		wave_config.wave_name.contains("测试")
		or wave_config.display_name.contains("测试")
	)


static func _resource_path(resource: Resource) -> String:
	return resource.resource_path if resource != null else ""
