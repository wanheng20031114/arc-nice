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
	_run_state = run_state
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
	var player_instance := _instantiate_player(character_id)
	if player_instance == null:
		return null
	player_instance.set_run_max_health_penalty(
		_run_state.get_max_health_penalty_for_peer(0)
	)
	player_instance.name = "Player"
	player_instance.position = _spawn_point.position
	_player_parent.add_child(player_instance)
	_bind_player_lifecycle(player_instance, 0)
	local_player = player_instance
	return player_instance


func configure_multiplayer_players() -> Player:
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
	var players: Array[Player] = []
	if runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		if local_player != null:
			players.append(local_player)
	else:
		for player_variant in peer_players.values():
			var player_instance := player_variant as Player
			if player_instance != null and is_instance_valid(player_instance):
				players.append(player_instance)
	for player_instance in players:
		if player_instance.current_xirang == INITIAL_PLAYER_XIRANG:
			continue
		player_instance.current_xirang = INITIAL_PLAYER_XIRANG
		player_instance.xirang_changed.emit(player_instance.current_xirang, 0)


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
		_run_state.ensure_multiplayer_peer_state(peer_id)
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
	enemy_retarget_requested.emit()
	spawn_slot_indices.erase(peer_id)
	player_names.erase(peer_id)
	player_character_ids.erase(peer_id)
	respawn_countdown_cleared.emit(peer_id)
	wave_death_counts.erase(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.queue_free()
	return player_instance


func prepare_restore_metadata(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	spawn_slot_index: int
) -> bool:
	if (
		new_peer_id <= 0
		or peer_players.has(new_peer_id)
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return false
	player_names.erase(old_peer_id)
	player_character_ids.erase(old_peer_id)
	spawn_slot_indices.erase(old_peer_id)
	player_names[new_peer_id] = player_name
	player_character_ids[new_peer_id] = character_id
	spawn_slot_indices[new_peer_id] = maxi(spawn_slot_index, 0)
	return true


func restore_multiplayer_player_runtime(
	old_peer_id: int,
	new_peer_id: int,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int,
	reconnect_state: Dictionary = {}
) -> Player:
	var wave_death_count := int(reconnect_state.get("wave_death_count", 0))
	if wave_death_count > 0:
		wave_death_counts[new_peer_id] = wave_death_count
	var player_instance := _instantiate_player(character_id)
	if player_instance == null:
		return null
	player_instance.set_run_max_health_penalty(
		_run_state.get_max_health_penalty_for_peer(new_peer_id)
	)
	player_instance.name = "Player_%d" % new_peer_id
	player_instance.position = (
		state.position
		if state != null
		else _spawn_point.position + _get_spawn_offset(spawn_slot_index)
	)
	_player_parent.add_child(player_instance)
	_configure_multiplayer_control(
		player_instance,
		new_peer_id,
		str(player_names.get(new_peer_id, "Player %d" % new_peer_id))
	)
	_bind_player_lifecycle(player_instance, new_peer_id)
	peer_players[new_peer_id] = player_instance
	if _research_coordinator != null:
		if _research_coordinator.player_technology_levels.has(old_peer_id):
			if not _research_coordinator.remap_player_peer_state(old_peer_id, new_peer_id):
				push_error("PlayerRosterCoordinator: 无法迁移重连玩家科研状态。")
		_research_coordinator.register_player(player_instance)
	if _production_coordinator != null:
		_production_coordinator.activate_personal_output_peer(new_peer_id)
	return player_instance


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


func set_combat_actions_locked_for_all(locked: bool) -> void:
	for player_instance in get_all_players():
		if player_instance.is_dead:
			continue
		player_instance.set_combat_actions_locked(locked)
		player_instance.set_controls_locked(false)


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
	return collect_snapshot_states_from(peer_players)


static func collect_snapshot_states_from(
	players: Dictionary
) -> Array[SnapshotManager.PlayerState]:
	var states: Array[SnapshotManager.PlayerState] = []
	for peer_id_variant in players:
		var peer_id := int(peer_id_variant)
		var player_instance := players.get(peer_id) as Player
		if player_instance == null or not is_instance_valid(player_instance):
			continue
		var state := SnapshotManager.PlayerState.new()
		state.peer_id = peer_id
		state.character_id = player_instance.get_character_id()
		state.position = player_instance.global_position
		state.velocity = player_instance.velocity
		state.facing = player_instance.get_multiplayer_facing_id()
		state.anim_state = player_instance.get_multiplayer_anim_state()
		state.current_health = player_instance.current_health
		state.max_health = player_instance.max_health
		state.current_xirang = player_instance.current_xirang
		state.is_dead = player_instance.is_dead
		state.invincibility_time_left = player_instance.invincibility_time_left
		state.skill1_unlocked = player_instance.skill1_unlocked
		state.skill1_charge = player_instance.skill1_charge
		state.skill1_charge_duration = player_instance.skill1_charge_duration
		state.skill1_upgrade_level = player_instance.skill1_upgrade_level
		state.form_mode = player_instance.get_multiplayer_form_mode()
		state.shot_pattern = player_instance.get_multiplayer_shot_pattern()
		state.ammo_capacity = player_instance.get_multiplayer_ammo_capacity()
		state.current_ammo = player_instance.get_multiplayer_current_ammo()
		state.is_reloading = player_instance.get_multiplayer_is_reloading()
		state.reload_progress = player_instance.get_multiplayer_reload_progress()
		state.primary_cooldown_ratio = clampf(
			player_instance.get_primary_cooldown_ratio(), 0.0, 1.0
		)
		state.effective_move_speed_multiplier = (
			player_instance.get_authoritative_effective_move_speed_ratio()
		)
		state.void_battery_charged = player_instance.has_void_battery_charge()
		states.append(state)
	return states


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
	refresh_players_from_run_state()
	match runtime_mode:
		CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
			if local_player == null or not is_instance_valid(local_player):
				return
			local_player.revive_multiplayer(
				local_player.global_position,
				local_player.max_health,
				_respawn_invincibility_seconds
			)
		CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
			if emit_multiplayer:
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
		player_instance.set_run_max_health_penalty(
			_run_state.get_max_health_penalty_for_peer(runtime_peer_id)
		)
		player_instance.configure_run_stat_bonuses(
			_run_state.get_player_stat_bonuses(runtime_peer_id),
			true
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
