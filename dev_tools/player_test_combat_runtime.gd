extends CombatRuntimeBase
class_name PlayerTestCombatRuntime

## Lightweight concrete combat root for focused player/projectile tests. It
## supplies the same typed runtime/gateway boundary as production without
## booting campaign, UI, music, or multiplayer session orchestration.


func _init() -> void:
	runtime_mode = RuntimeMode.SINGLEPLAYER
	_add_named_child(Node2D.new(), &"EnemyContainer")
	_add_named_child(Node.new(), &"GridPathfinder")
	_add_named_child(Node.new(), &"CapooProjectileMotionSystem")
	_add_named_child(
		CombatRobotDroneMotionSystem.new(),
		&"CombatRobotDroneMotionSystem"
	)
	_add_named_child(DayNightController.new(), &"DayNightController")
	_add_named_child(
		MultiplayerGameplayGateway.new(),
		&"MultiplayerGameplayGateway"
	)
	_add_named_child(MultiplayerModeAdapter.new(), &"MultiplayerModeAdapter")


func _add_named_child(child: Node, child_name: StringName) -> void:
	child.name = child_name
	add_child(child)


func configure_multiplayer(
	_mode: int,
	_local_peer_id: int,
	_player_names: Dictionary,
	_player_character_ids: Dictionary = {}
) -> void:
	pass


func get_player_for_peer(requested_peer_id: int) -> Player:
	for candidate in _collect_runtime_players():
		if candidate.peer_id == requested_peer_id:
			return candidate
	return null


func get_enemy_for_net_id(net_id: int) -> Enemy:
	for enemy in get_all_combat_targets():
		if int(enemy.get_meta("net_id", 0)) == net_id:
			return enemy
	return null


func get_pickup_for_net_id(_net_id: int) -> Pickup:
	return null


func remove_multiplayer_player(_peer_id: int) -> void:
	pass


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	return []


func collect_enemy_snapshot_states() -> Array[SnapshotManager.EnemyState]:
	return []


func apply_remote_flow_state(
	_step_id: StringName,
	_state: int,
	_seconds: int
) -> void:
	pass


func get_flow_state_snapshot() -> Dictionary:
	return {}


func apply_remote_boss_started(
	_net_id: int,
	_boss_config: BossConfig,
	_spawn_position: Vector2
) -> void:
	pass


func apply_remote_defeat() -> void:
	pass


func apply_remote_victory() -> void:
	pass


func apply_remote_enemy_count(_alive_count: int) -> void:
	pass


func apply_remote_merchant_active(_active: bool) -> void:
	pass


func play_remote_enemy_spawn_effect(_spawn_global_position: Vector2) -> void:
	pass


func try_purchase_skill1_for_peer(_peer_id: int) -> int:
	return 0


func apply_skill1_purchase_state(
	_peer_id: int,
	_current_xirang: int,
	_skill1_unlocked: bool,
	_skill1_upgrade_level: int = -1,
	_skill1_charge_duration: float = -1.0
) -> void:
	pass


func show_local_skill1_purchase_result(_result_code: int) -> void:
	pass


func try_refresh_luoxi_collectibles_for_peer(_peer_id: int) -> int:
	return 0


func get_luoxi_collectible_refresh_count(_peer_id: int) -> int:
	return 0


func try_claim_luoxi_collectible_for_peer(
	_peer_id: int,
	_config_path_or_choice: Variant
) -> int:
	return 0


func has_luoxi_collectible_claimed(_peer_id: int) -> bool:
	return false


func record_luoxi_collectible_claim(_peer_id: int) -> void:
	pass


func mark_luoxi_collectible_claimed(_peer_id: int) -> void:
	pass


func show_local_luoxi_collectible_result(_result_code: int) -> void:
	pass


func show_local_luoxi_refresh_result(
	_result_code: int,
	_refresh_count: int,
	_current_xirang: int
) -> void:
	pass


func show_debug_collectible_grant_result(
	_config_path: String,
	_success: bool
) -> void:
	pass


func get_all_combat_targets() -> Array[Enemy]:
	var result: Array[Enemy] = []
	_collect_enemies_recursive(self, result)
	return result


func query_combat_targets(
	center: Vector2,
	radius: float,
	max_count: int = 0
) -> Array[Enemy]:
	var result := get_all_combat_targets()
	var safe_radius := maxf(radius, 0.0)
	if safe_radius > 0.0:
		var radius_squared := safe_radius * safe_radius
		result = result.filter(
			func(enemy: Enemy) -> bool:
				return center.distance_squared_to(enemy.global_position) <= radius_squared
		)
	result.sort_custom(
		func(a: Enemy, b: Enemy) -> bool:
			var a_distance := center.distance_squared_to(a.global_position)
			var b_distance := center.distance_squared_to(b.global_position)
			if not is_equal_approx(a_distance, b_distance):
				return a_distance < b_distance
			return a.get_instance_id() < b.get_instance_id()
	)
	if max_count > 0 and result.size() > max_count:
		result.resize(max_count)
	return result


func query_combat_targets_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.assign(query_combat_targets(center, radius, 0))


func pick_random_combat_target(center: Vector2, radius: float = 0.0) -> Enemy:
	var candidates := query_combat_targets(center, radius, 0)
	if candidates.is_empty():
		return null
	return candidates[randi() % candidates.size()]


func _collect_enemies_recursive(node: Node, result: Array[Enemy]) -> void:
	for child in node.get_children():
		var enemy := child as Enemy
		if enemy != null and not enemy.is_dead:
			result.append(enemy)
		_collect_enemies_recursive(child, result)


func _collect_runtime_players() -> Array[Player]:
	var result: Array[Player] = []
	_collect_players_recursive(self, result)
	return result


func _collect_players_recursive(node: Node, result: Array[Player]) -> void:
	for child in node.get_children():
		var candidate := child as Player
		if candidate != null:
			result.append(candidate)
		_collect_players_recursive(child, result)
