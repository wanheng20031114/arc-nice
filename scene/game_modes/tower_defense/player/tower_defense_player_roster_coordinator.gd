extends Node
class_name TowerDefensePlayerRosterCoordinator

const DEFAULT_PLAYER_CHARACTER_ID := &"weishidaier"
const INITIAL_PLAYER_XIRANG := 1000

signal player_runtime_binding_requested(player: Player)
signal player_died(peer_id: int)
signal player_revived(peer_id: int)
signal enemy_retarget_requested
signal respawn_countdown_changed(peer_id: int, seconds_left: int)
signal respawn_countdown_cleared(peer_id: int)
signal revive_all_requested
## Host 侧由 MpPlayerCoordinator 以健康 revision 广播，覆盖存活与死亡玩家。
signal restore_all_full_health_requested

var runtime_mode := CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
var local_peer_id := 0
var local_player: Player
var peer_players: Dictionary = {}
var player_names: Dictionary = {}
var player_character_ids: Dictionary = {}
var spawn_slot_indices: Dictionary[int, int] = {}
var wave_death_counts: Dictionary = {}
var singleplayer_respawn_time_left := -1.0
var singleplayer_respawn_last_seconds := -1
var starting_package_granted := false

var _player_parent: Node
var _spawn_point: Marker2D
var _run_state: RunStateStore
var _research_coordinator: ResearchCoordinator
var _production_coordinator: ProductionCoordinator
var _default_character_id: StringName
var _spawn_offsets: Array[Vector2] = []
var _respawn_delays: Array[int] = []
var _respawn_invincibility_seconds := 0.0
var _singleplayer_tango_charge_started_at := -1.0
var _tango_minimum_charge_seconds := 0.0
var _tango_maximum_charge_seconds := 0.0
var _tango_threshold_epsilon := 0.0
var _snapshot_encoder := PlayerSnapshotEncoder.new()
var _applying_party_xirang_ledger := false


func setup(
	mode: int,
	peer_id: int,
	player_parent: Node,
	spawn_point: Marker2D,
	run_state: RunStateStore,
	research_coordinator: ResearchCoordinator,
	production_coordinator: ProductionCoordinator,
	shared_peer_players: Dictionary,
	shared_player_names: Dictionary,
	shared_character_ids: Dictionary,
	shared_spawn_slots: Dictionary[int, int],
	shared_wave_death_counts: Dictionary,
	default_character_id: StringName,
	spawn_offsets: Array[Vector2],
	respawn_delays: Array[int],
	respawn_invincibility_seconds: float,
	tango_minimum_charge_seconds: float,
	tango_maximum_charge_seconds: float,
	tango_threshold_epsilon: float
) -> void:
	runtime_mode = mode
	local_peer_id = peer_id
	_player_parent = player_parent
	_spawn_point = spawn_point
	_bind_run_state(run_state)
	_research_coordinator = research_coordinator
	_production_coordinator = production_coordinator
	peer_players = shared_peer_players
	player_names = shared_player_names
	player_character_ids = shared_character_ids
	spawn_slot_indices = shared_spawn_slots
	wave_death_counts = shared_wave_death_counts
	_default_character_id = default_character_id
	_spawn_offsets = spawn_offsets.duplicate()
	_respawn_delays = respawn_delays.duplicate()
	_respawn_invincibility_seconds = respawn_invincibility_seconds
	_tango_minimum_charge_seconds = tango_minimum_charge_seconds
	_tango_maximum_charge_seconds = tango_maximum_charge_seconds
	_tango_threshold_epsilon = tango_threshold_epsilon


func set_runtime_identity(mode: int, peer_id: int) -> void:
	runtime_mode = mode
	local_peer_id = peer_id


func is_bound() -> bool:
	return (
		_player_parent != null
		and _spawn_point != null
		and _run_state != null
		and _research_coordinator != null
		and _production_coordinator != null
	)


func configure_roster(names: Dictionary, character_ids: Dictionary) -> void:
	var names_copy := names.duplicate()
	var character_ids_copy := character_ids.duplicate()
	player_names.clear()
	player_character_ids.clear()
	for key in names_copy:
		player_names[key] = names_copy[key]
	for key in character_ids_copy:
		player_character_ids[key] = character_ids_copy[key]


func get_selected_singleplayer_character_id() -> StringName:
	var character_id := _default_character_id
	if _run_state != null:
		character_id = _run_state.get_selected_character_id()
	if not PlayerCharacterRegistry.is_valid_character_id(character_id):
		return _default_character_id
	return character_id


func configure_singleplayer(character_id: StringName) -> Player:
	_snapshot_encoder.clear()
	var player_instance := _instantiate_player(character_id)
	if player_instance == null:
		return null
	player_instance.set_run_max_health_penalty(
		_run_state.get_max_health_penalty_for_peer(0)
	)
	player_instance.name = "Player"
	player_instance.position = _spawn_point.position
	_player_parent.add_child(player_instance)
	if not player_instance.configure_xirang_ownership(
		Player.XirangOwnership.RUN_PARTY_LEDGER,
		0
	):
		player_instance.queue_free()
		return null
	_bind_player_lifecycle(player_instance, 0)
	local_player = player_instance
	return player_instance


func configure_multiplayer_players() -> Player:
	_snapshot_encoder.clear()
	local_player = null
	peer_players.clear()
	spawn_slot_indices.clear()
	if player_names.is_empty():
		player_names[local_peer_id if local_peer_id > 0 else 1] = "Player"
	var peer_ids: Array[int] = []
	for peer_id_variant in player_names:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		spawn_slot_indices[peer_id] = index
		var player_instance := _instantiate_player(_get_character_id(peer_id))
		if player_instance == null:
			continue
		player_instance.set_run_max_health_penalty(
			_run_state.get_max_health_penalty_for_peer(peer_id)
		)
		player_instance.name = "Player_%d" % peer_id
		player_instance.position = _spawn_point.position + _get_spawn_offset(index)
		_player_parent.add_child(player_instance)
		_configure_multiplayer_control(player_instance, peer_id, str(
			player_names.get(peer_id, "Player %d" % peer_id)
		))
		if not player_instance.configure_xirang_ownership(
			Player.XirangOwnership.RUN_PARTY_LEDGER,
			peer_id
		):
			player_instance.queue_free()
			for configured_player in peer_players.values():
				if configured_player != null and is_instance_valid(configured_player):
					configured_player.queue_free()
			peer_players.clear()
			local_player = null
			return null
		_bind_player_lifecycle(player_instance, peer_id)
		peer_players[peer_id] = player_instance
		if _research_coordinator != null:
			_research_coordinator.register_player(player_instance)
		if peer_id == local_peer_id:
			local_player = player_instance
	if local_player == null and not peer_ids.is_empty():
		local_player = peer_players.get(peer_ids[0]) as Player
	return local_player


func configure_production_output_peers() -> void:
	if _production_coordinator != null:
		_production_coordinator.configure_multiplayer_output_peers(peer_players.keys())


func register_research_players() -> void:
	if _research_coordinator == null:
		return
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_research_coordinator.register_player(local_player)
		return
	for player_variant in peer_players.values():
		var player_instance := player_variant as Player
		if player_instance != null:
			_research_coordinator.register_player(player_instance)


func apply_initial_player_xirang() -> void:
	# Client 的 Player 由 Host 实时快照驱动，不能用本地初始值反写共享账本。
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return
	var initial_balances: Dictionary = {}
	for peer_id in get_active_peer_ids():
		initial_balances[peer_id] = INITIAL_PLAYER_XIRANG
	if initial_balances.is_empty():
		return
	if not _run_state.set_party_xirang_balances(initial_balances):
		push_error("PlayerRosterCoordinator: 无法原子初始化玩家息壤账本。")
		return
	# 账本数值未变化时 RunState 不会重复发信号，仍需显式收敛新建节点。
	_sync_all_player_xirang_from_run_state()


func grant_starting_package(
	progression_config: TowerDefenseProgressionConfig
) -> bool:
	if starting_package_granted:
		return true
	if _run_state == null or progression_config == null:
		return false
	if runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW:
		return false
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		var items := progression_config.get_starting_items(true)
		var amounts := progression_config.get_starting_amounts(true)
		if not _run_state.can_add_item_counts(items, amounts):
			return false
		if not _run_state.try_add_item_counts_if_revision(
			items,
			amounts,
			_run_state.get_inventory_revision()
		):
			return false
		starting_package_granted = true
		return true

	var peer_ids: Array[int] = []
	for peer_id_variant in peer_players:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	if peer_ids.is_empty() or local_peer_id <= 0 or not peer_players.has(local_peer_id):
		return false
	for peer_id in peer_ids:
		# 身份层必须在创建 roster 前整批注册；起步包只消费既有账本，
		# 不能因一次领域操作暗中创造新的多人成员。
		if not _run_state.has_multiplayer_peer_state(peer_id):
			return false
		var include_team_items := peer_id == local_peer_id
		if not _run_state.can_add_item_counts_for_peer(
			peer_id,
			progression_config.get_starting_items(include_team_items),
			progression_config.get_starting_amounts(include_team_items)
		):
			return false
	for peer_id in peer_ids:
		var include_team_items := peer_id == local_peer_id
		if not _run_state.try_add_item_counts_for_peer_if_revision(
			peer_id,
			progression_config.get_starting_items(include_team_items),
			progression_config.get_starting_amounts(include_team_items),
			_run_state.get_inventory_revision_for_peer(peer_id),
			false
		):
			return false
	starting_package_granted = true
	_run_state.notify_inventory_snapshot_committed()
	return true


func remove_multiplayer_player(peer_id: int) -> Player:
	if peer_id <= 0 or peer_id == local_peer_id:
		return null
	if _production_coordinator != null:
		_production_coordinator.deactivate_personal_output_peer(peer_id)
	var player_instance := peer_players.get(peer_id) as Player
	peer_players.erase(peer_id)
	_snapshot_encoder.forget_peer(peer_id)
	enemy_retarget_requested.emit()
	spawn_slot_indices.erase(peer_id)
	player_names.erase(peer_id)
	player_character_ids.erase(peer_id)
	respawn_countdown_cleared.emit(peer_id)
	wave_death_counts.erase(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.queue_free()
	return player_instance


## Tower 的重连投影同时维护 Player、出生槽、生产和科研绑定。客户端 setup
## 已经创建 new-id Player 时必须复用它；只有确实缺少投影时才实例化。
func ensure_reconnected_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	reconnect_state: Dictionary = {}
) -> CombatRuntimeBase.ReconnectedPlayerProjection:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.INVALID_REQUEST
		)
	var old_player := peer_players.get(old_peer_id) as Player
	if (
		old_player != null
		and (
			not is_instance_valid(old_player)
			or old_player.is_queued_for_deletion()
		)
	):
		peer_players.erase(old_peer_id)
		old_player = null
	var player_instance := peer_players.get(new_peer_id) as Player
	if (
		player_instance != null
		and (
			not is_instance_valid(player_instance)
			or player_instance.is_queued_for_deletion()
		)
	):
		peer_players.erase(new_peer_id)
		player_instance = null
	if old_player != null:
		push_error(
			"PlayerRosterCoordinator: 重连时 old=%d 的 Player 尚未退出，拒绝与 new=%d 并存。"
			% [old_peer_id, new_peer_id]
		)
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CONFLICT
		)
	if (
		player_instance != null
		and player_instance.get_character_id() != character_id
	):
		push_error(
			"PlayerRosterCoordinator: 重连目标 %d 的既有角色与认证角色不一致。"
			% new_peer_id
		)
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CONFLICT
		)
	var reused_existing := player_instance != null
	if not reused_existing:
		player_instance = _instantiate_player(character_id)
		if player_instance == null:
			return CombatRuntimeBase.ReconnectedPlayerProjection.new(
				CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
			)

	var resolved_spawn_slot_index := maxi(spawn_slot_index, 0)
	if (
		reused_existing
		and reconnect_state.is_empty()
		and spawn_slot_indices.has(new_peer_id)
	):
		# 新客户端没有 old-id 捕获时，以 setup 已确定的槽位为准。
		resolved_spawn_slot_index = int(spawn_slot_indices[new_peer_id])
	player_names.erase(old_peer_id)
	player_character_ids.erase(old_peer_id)
	spawn_slot_indices.erase(old_peer_id)
	_snapshot_encoder.forget_peer(old_peer_id)
	player_names[new_peer_id] = player_name
	player_character_ids[new_peer_id] = character_id
	spawn_slot_indices[new_peer_id] = resolved_spawn_slot_index
	if reconnect_state.has("wave_death_count"):
		wave_death_counts.erase(old_peer_id)
		wave_death_counts[new_peer_id] = maxi(
			int(reconnect_state["wave_death_count"]),
			0
		)
	player_instance.set_run_max_health_penalty(
		_run_state.get_max_health_penalty_for_peer(new_peer_id)
	)
	player_instance.name = "Player_%d" % new_peer_id
	if (
		state != null
		and runtime_mode != CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
	):
		# 断线快照保存的是离线前瞬时值；跨 Rogue/Fate 后持久账本可能已
		# 前进。Host 恢复时先规范化快照，避免稍后的瞬时状态恢复倒灌旧币值。
		state.current_xirang = _run_state.get_party_xirang_balance(new_peer_id)
	if state != null:
		player_instance.position = state.position
	elif not reused_existing:
		player_instance.position = (
			_spawn_point.position
			+ _get_spawn_offset(resolved_spawn_slot_index)
		)
	if not reused_existing:
		_player_parent.add_child(player_instance)
	_configure_multiplayer_control(
		player_instance,
		new_peer_id,
		str(player_names.get(new_peer_id, "Player %d" % new_peer_id))
	)
	if not player_instance.configure_xirang_ownership(
		Player.XirangOwnership.RUN_PARTY_LEDGER,
		new_peer_id
	):
		if not reused_existing:
			player_instance.queue_free()
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
		)
	_bind_player_lifecycle(player_instance, new_peer_id)
	peer_players[new_peer_id] = player_instance
	if new_peer_id == local_peer_id:
		local_player = player_instance
	_sync_player_xirang_from_run_state(player_instance, new_peer_id)
	if _research_coordinator != null:
		if (
			not reused_existing
			and _research_coordinator.player_technology_levels.has(old_peer_id)
		):
			if not _research_coordinator.remap_player_peer_state(old_peer_id, new_peer_id):
				push_error("PlayerRosterCoordinator: 无法迁移重连玩家科研状态。")
		# register 是按 peer 键覆盖的校准操作，existing current 重放可安全执行。
		_research_coordinator.register_player(player_instance)
	if _production_coordinator != null and not reused_existing:
		# 生产租约只随首次 Player 投影激活；通知重放不得重复触发领域生命周期。
		_production_coordinator.activate_personal_output_peer(new_peer_id)
	return CombatRuntimeBase.ReconnectedPlayerProjection.new(
		(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
			if reused_existing
			else CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATED
		),
		player_instance
	)


func get_player(peer_id: int) -> Player:
	return peer_players.get(peer_id) as Player


func get_player_for_runtime_peer(peer_id: int) -> Player:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER and peer_id == 0:
		return local_player
	return get_player(peer_id)


func get_active_peer_ids() -> Array[int]:
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return [0]
	var peer_ids: Array[int] = []
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		if peer_id > 0:
			peer_ids.append(peer_id)
	peer_ids.sort()
	return peer_ids


func get_all_players() -> Array[Player]:
	var players: Array[Player] = []
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		if local_player != null and is_instance_valid(local_player):
			players.append(local_player)
		return players
	for player_variant in peer_players.values():
		var player_instance := player_variant as Player
		if player_instance != null and is_instance_valid(player_instance):
			players.append(player_instance)
	return players


func get_world_spawn_position(
	peer_id: int,
	fallback_slot_index: int = 0
) -> Vector2:
	if _spawn_point == null:
		return Vector2.ZERO
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER or peer_id <= 0:
		return _spawn_point.global_position
	return _spawn_point.global_position + _get_spawn_offset(
		int(spawn_slot_indices.get(peer_id, maxi(fallback_slot_index, 0)))
	)


func set_combat_action_lock_for_all(
	owner: StringName,
	locked: bool
) -> void:
	for player_instance in get_all_players():
		player_instance.set_combat_action_lock(owner, locked)


func get_fixed_respawn_position(peer_id: int) -> Variant:
	if _spawn_point == null or not spawn_slot_indices.has(peer_id):
		return null
	return _spawn_point.global_position + _get_spawn_offset(spawn_slot_indices[peer_id])


func get_spawn_slot_index(peer_id: int) -> int:
	return int(spawn_slot_indices.get(peer_id, 0))


func get_wave_death_count(peer_id: int) -> int:
	return int(wave_death_counts.get(peer_id, 0))


func apply_network_input_for_peer(
	peer_id: int,
	move_input: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool
) -> void:
	var player_instance := get_player(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.apply_network_input(
			move_input, shoot_input, use_skill1, use_reload
		)


func update_remote_passive_state(delta: float) -> void:
	for peer_id_variant in peer_players:
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		var player_instance := get_player(peer_id)
		if player_instance != null and is_instance_valid(player_instance):
			player_instance.update_multiplayer_authority_passive_state(delta)


func collect_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	return _snapshot_encoder.collect(peer_players)


static func collect_snapshot_states_from(
	players: Dictionary
) -> Array[SnapshotManager.PlayerState]:
	return PlayerSnapshotEncoder.collect_once(players)


func request_tango_charge_started(direction: Vector2) -> bool:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return false
	var tango := local_player as PlayerTango
	if not _is_valid_tango(tango):
		return false
	if not tango.try_authoritative_tango_charge_started(
		_sanitize_tango_direction(tango, direction)
	):
		return false
	_singleplayer_tango_charge_started_at = Time.get_ticks_usec() / 1000000.0
	return true


func request_tango_charge_released(direction: Vector2) -> bool:
	if (
		runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		or _singleplayer_tango_charge_started_at < 0.0
	):
		return false
	var started_at := _singleplayer_tango_charge_started_at
	_singleplayer_tango_charge_started_at = -1.0
	var tango := local_player as PlayerTango
	if not _is_valid_tango(tango):
		return false
	var elapsed := maxf(Time.get_ticks_usec() / 1000000.0 - started_at, 0.0)
	if elapsed + _tango_threshold_epsilon < _tango_minimum_charge_seconds:
		tango.cancel_authoritative_tango_charge()
		return true
	var ratio := clampf(
		(elapsed - _tango_minimum_charge_seconds)
		/ (_tango_maximum_charge_seconds - _tango_minimum_charge_seconds),
		0.0,
		1.0
	)
	var result := tango.try_authoritative_tango_charge_released(
		_sanitize_tango_direction(tango, direction), ratio
	)
	var succeeded := bool(result.get("accepted", false)) and bool(result.get("fired", false))
	if not succeeded:
		tango.cancel_authoritative_tango_charge()
	return succeeded


func request_tango_charge_cancelled() -> bool:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return false
	var had_active_charge := _singleplayer_tango_charge_started_at >= 0.0
	_singleplayer_tango_charge_started_at = -1.0
	var tango := local_player as PlayerTango
	if not _is_valid_tango(tango):
		return false
	tango.cancel_authoritative_tango_charge()
	return had_active_charge


func consume_next_respawn_delay(peer_id: int) -> float:
	var death_count := int(wave_death_counts.get(peer_id, 0))
	var delay_index := mini(death_count, _respawn_delays.size() - 1)
	wave_death_counts[peer_id] = death_count + 1
	return float(_respawn_delays[delay_index])


func reset_wave_death_counts() -> void:
	wave_death_counts.clear()


func clear_result_respawn_state() -> void:
	singleplayer_respawn_time_left = -1.0
	singleplayer_respawn_last_seconds = -1


func force_revive_dead_players(emit_multiplayer: bool) -> void:
	match runtime_mode:
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
			singleplayer_respawn_time_left = -1.0
			singleplayer_respawn_last_seconds = -1
			respawn_countdown_cleared.emit(0)
			if local_player != null and is_instance_valid(local_player) and local_player.is_dead:
				local_player.revive_multiplayer(
					_spawn_point.global_position,
					local_player.max_health,
					_respawn_invincibility_seconds
				)
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
			if not emit_multiplayer:
				return
			for player_variant in peer_players.values():
				var player_instance := player_variant as Player
				if player_instance != null and is_instance_valid(player_instance) and player_instance.is_dead:
					revive_all_requested.emit()
					return


## 从跨场景 RunState 重新应用永久属性与最大生命惩罚后，再把全员恢复到
## 当前有效上限。多人权威由会话层产生健康 revision，避免只改 Host 节点。
func restore_all_players_to_full_health(emit_multiplayer: bool) -> void:
	match runtime_mode:
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
			if local_player == null or not is_instance_valid(local_player):
				return
			var progression := _run_state.export_player_run_progression(0)
			if not local_player.restore_run_scene_entry(progression):
				push_error("Tower 单人玩家无法提交跨场景恢复边界。")
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
			if not emit_multiplayer:
				return
			# Host 先按健康态计算最终上限并清瞬态，随后健康 revision 才把同一
			# 绝对结果广播到所有 Client；任一成员失败则整批不发布。
			for player_instance in get_all_players():
				var progression := _run_state.export_player_run_progression(
					player_instance.peer_id
				)
				if not player_instance.restore_run_scene_entry(progression):
					push_error(
						"Tower 玩家%d无法提交跨场景恢复边界。"
						% player_instance.peer_id
					)
					return
			restore_all_full_health_requested.emit()


func refresh_players_from_run_state() -> void:
	if _run_state == null:
		return
	for player_instance in get_all_players():
		var runtime_peer_id := (
			0
			if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
			else player_instance.peer_id
		)
		var progression := _run_state.export_player_run_progression(runtime_peer_id)
		if not player_instance.apply_run_progression_snapshot(progression, true):
			push_error(
				"Tower 玩家 %d 的本局成长账本缺失或无效。" % runtime_peer_id
			)


func update_singleplayer_respawn(delta: float) -> void:
	if runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER or singleplayer_respawn_time_left < 0.0:
		return
	if local_player == null or not local_player.is_dead:
		singleplayer_respawn_time_left = -1.0
		singleplayer_respawn_last_seconds = -1
		return
	singleplayer_respawn_time_left = maxf(singleplayer_respawn_time_left - delta, 0.0)
	var seconds_left := ceili(singleplayer_respawn_time_left)
	if seconds_left != singleplayer_respawn_last_seconds:
		singleplayer_respawn_last_seconds = seconds_left
		respawn_countdown_changed.emit(0, seconds_left)
	if singleplayer_respawn_time_left > 0.0:
		return
	singleplayer_respawn_time_left = -1.0
	singleplayer_respawn_last_seconds = -1
	local_player.revive_multiplayer(
		_spawn_point.global_position,
		local_player.max_health,
		_respawn_invincibility_seconds
	)


func begin_singleplayer_respawn() -> void:
	var delay := consume_next_respawn_delay(0)
	singleplayer_respawn_time_left = delay
	singleplayer_respawn_last_seconds = ceili(delay)
	respawn_countdown_changed.emit(0, singleplayer_respawn_last_seconds)


func _instantiate_player(character_id: StringName) -> Player:
	var resolved_id := character_id
	if not PlayerCharacterRegistry.is_valid_character_id(resolved_id):
		resolved_id = _default_character_id
	var instance := PlayerCharacterRegistry.instantiate_character(resolved_id) as Player
	if instance == null:
		push_error("PlayerRosterCoordinator: 无法实例化角色 %s" % resolved_id)
		return null
	player_runtime_binding_requested.emit(instance)
	return instance


func _configure_multiplayer_control(
	player_instance: Player,
	peer_id: int,
	display_name: String
) -> void:
	var accepts_local_input := (
		peer_id == local_peer_id
		and runtime_mode in [
			CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
			CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		]
	)
	var predicts_local_movement := (
		runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and peer_id == local_peer_id
	)
	player_instance.configure_multiplayer_control(
		peer_id,
		accepts_local_input,
		display_name,
		predicts_local_movement,
		peer_id == local_peer_id
	)
	player_instance.set_multiplayer_visual_smoothing_enabled(
		runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and peer_id != local_peer_id
	)
	player_instance.physics_interpolation_mode = (
		Node.PHYSICS_INTERPOLATION_MODE_ON
		if accepts_local_input or predicts_local_movement
		else Node.PHYSICS_INTERPOLATION_MODE_OFF
	)
	player_instance.reset_physics_interpolation()
	if (
		(runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW and not predicts_local_movement)
		or (runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY and peer_id != local_peer_id)
	):
		player_instance.set_physics_process(false)


func _bind_player_lifecycle(player_instance: Player, peer_id: int) -> void:
	var died_callback := player_died.emit.bind(peer_id)
	if not player_instance.died.is_connected(died_callback):
		player_instance.died.connect(died_callback)
	var revived_callback := player_revived.emit.bind(peer_id)
	if not player_instance.revived.is_connected(revived_callback):
		player_instance.revived.connect(revived_callback)
	var xirang_callback := _on_player_xirang_changed.bind(peer_id)
	if not player_instance.xirang_changed.is_connected(xirang_callback):
		player_instance.xirang_changed.connect(xirang_callback)


func _bind_run_state(run_state: RunStateStore) -> void:
	if (
		_run_state != null
		and _run_state.party_xirang_ledger_changed.is_connected(
			_on_party_xirang_ledger_changed
		)
	):
		_run_state.party_xirang_ledger_changed.disconnect(
			_on_party_xirang_ledger_changed
		)
	_run_state = run_state
	assert(_run_state != null, "PlayerRosterCoordinator 缺少 RunState。")
	if not _run_state.party_xirang_ledger_changed.is_connected(
		_on_party_xirang_ledger_changed
	):
		_run_state.party_xirang_ledger_changed.connect(
			_on_party_xirang_ledger_changed
		)


func _on_player_xirang_changed(
	current_xirang: int,
	_delta: int,
	peer_id: int
) -> void:
	if (
		_applying_party_xirang_ledger
		or runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		or _run_state == null
		or current_xirang < 0
	):
		return
	var ledger_peer_id := 0 if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER else peer_id
	if ledger_peer_id < 0:
		return
	if not _run_state.set_party_xirang_balance(ledger_peer_id, current_xirang):
		push_error(
			"PlayerRosterCoordinator: 无法提交玩家 %d 的权威息壤镜像。"
			% ledger_peer_id
		)


func _on_party_xirang_ledger_changed(_snapshot: Dictionary) -> void:
	_sync_all_player_xirang_from_run_state()


func _sync_all_player_xirang_from_run_state() -> void:
	if _run_state == null or _applying_party_xirang_ledger:
		return
	_applying_party_xirang_ledger = true
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		_sync_player_xirang_from_run_state(local_player, 0)
	else:
		for peer_id in get_active_peer_ids():
			_sync_player_xirang_from_run_state(get_player(peer_id), peer_id)
	_applying_party_xirang_ledger = false


func _sync_player_xirang_from_run_state(
	player_instance: Player,
	ledger_peer_id: int
) -> void:
	if (
		_run_state == null
		or player_instance == null
		or not is_instance_valid(player_instance)
		or ledger_peer_id < 0
	):
		return
	var authoritative_amount := _run_state.get_party_xirang_balance(ledger_peer_id)
	player_instance.set_xirang_balance(authoritative_amount)


func _get_character_id(peer_id: int) -> StringName:
	var character_id := StringName(
		player_character_ids.get(peer_id, _default_character_id)
	)
	return character_id if PlayerCharacterRegistry.is_valid_character_id(character_id) else _default_character_id


func _get_spawn_offset(index: int) -> Vector2:
	return _spawn_offsets[index % _spawn_offsets.size()]


static func _is_valid_tango(tango: PlayerTango) -> bool:
	return tango != null and is_instance_valid(tango)


static func _sanitize_tango_direction(tango: PlayerTango, direction: Vector2) -> Vector2:
	if direction.is_finite() and direction.length_squared() > 0.0001:
		return direction.normalized()
	match tango.get_multiplayer_facing_id():
		1: return Vector2.LEFT
		2: return Vector2.UP
		3: return Vector2.DOWN
		_: return Vector2.RIGHT
