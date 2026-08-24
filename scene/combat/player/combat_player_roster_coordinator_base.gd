extends Node
class_name CombatPlayerRosterCoordinatorBase

signal singleplayer_died
signal multiplayer_player_died(peer_id: int)
signal all_players_dead
signal peer_restored(old_peer_id: int, new_peer_id: int)

const DEFAULT_PLAYER_CHARACTER_ID := &"weishidaier"
const MULTIPLAYER_DEFEAT_GRACE_SECONDS := 0.25
const INITIAL_PLAYER_XIRANG := 1000
const SPAWN_OFFSETS := [
	Vector2.ZERO,
	Vector2(18.0, 0.0),
	Vector2(0.0, 18.0),
	Vector2(18.0, 18.0),
	Vector2(-18.0, 0.0),
	Vector2(0.0, -18.0),
	Vector2(-18.0, -18.0),
	Vector2(18.0, -18.0),
]

var runtime: WaveCombatRuntimeBase = null
var player_spawn: Marker2D = null
var run_state: RunStateStore = null
var player_names: Dictionary = {}
var player_character_ids: Dictionary = {}
var defeat_check_pending: bool = false
var _singleplayer_tango_charge_started_at: float = -1.0
var _snapshot_encoder := PlayerSnapshotEncoder.new()


func bind_dependencies(
	runtime_instance: WaveCombatRuntimeBase,
	spawn_marker: Marker2D,
	run_state_store: RunStateStore
) -> void:
	runtime = runtime_instance
	player_spawn = spawn_marker
	run_state = run_state_store


func is_bound() -> bool:
	return runtime != null and player_spawn != null and run_state != null


func configure_peer_metadata(
	names: Dictionary,
	character_ids: Dictionary
) -> void:
	player_names = names.duplicate()
	player_character_ids = character_ids.duplicate()


func configure_singleplayer_player() -> void:
	_snapshot_encoder.clear()
	runtime.player = null
	var player_instance := _instantiate_player_character(
		_get_selected_singleplayer_character_id()
	)
	if player_instance == null:
		return
	player_instance.name = "Player"
	player_instance.position = player_spawn.position
	runtime.add_child(player_instance)
	if not _restore_player_for_combat_scene_entry(player_instance, 0):
		# 成长账本是角色发布前置条件；失败时绝不能让作者基础 Player 进入运行时。
		player_instance.queue_free()
		return
	runtime.player = player_instance


func connect_singleplayer_death_signal() -> void:
	if runtime.player != null and not runtime.player.died.is_connected(_on_singleplayer_died):
		runtime.player.died.connect(_on_singleplayer_died)


func configure_multiplayer_players() -> void:
	_snapshot_encoder.clear()
	runtime.player = null
	runtime.peer_players.clear()
	if player_names.is_empty():
		player_names[
			runtime.multiplayer_local_peer_id
			if runtime.multiplayer_local_peer_id > 0
			else 1
		] = "Player"
	var peer_ids: Array[int] = []
	for peer_id_variant in player_names:
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	var staged_players: Dictionary[int, Player] = {}
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		var player_instance := _instantiate_player_character(
			get_multiplayer_character_id(peer_id)
		)
		if player_instance == null:
			_discard_staged_multiplayer_players(staged_players)
			return
		player_instance.name = "Player_%d" % peer_id
		player_instance.position = player_spawn.position + get_spawn_offset(index)
		runtime.add_child(player_instance)
		_configure_multiplayer_control(
			player_instance,
			peer_id,
			str(player_names.get(peer_id, "Player %d" % peer_id))
		)
		if not _restore_player_for_combat_scene_entry(player_instance, peer_id):
			player_instance.queue_free()
			_discard_staged_multiplayer_players(staged_players)
			return
		_connect_multiplayer_death(player_instance, peer_id)
		staged_players[peer_id] = player_instance
	# 多人 roster 只有全部稳定成员都完成账本投影后才一次发布，避免半套队伍
	# 让 runtime preparation 误判为已就绪。
	for peer_id in peer_ids:
		var player_instance := staged_players[peer_id]
		runtime.peer_players[peer_id] = player_instance
		if peer_id == runtime.multiplayer_local_peer_id:
			runtime.player = player_instance
	if runtime.player == null and not peer_ids.is_empty():
		runtime.player = runtime.peer_players.get(peer_ids[0]) as Player


func _discard_staged_multiplayer_players(
	staged_players: Dictionary[int, Player]
) -> void:
	for player_instance in staged_players.values():
		if player_instance != null and is_instance_valid(player_instance):
			player_instance.queue_free()
	staged_players.clear()
	runtime.peer_players.clear()
	runtime.player = null


func apply_initial_xirang() -> void:
	var players: Array[Player] = []
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		if runtime.player != null:
			players.append(runtime.player)
	else:
		for peer_id_variant in runtime.peer_players:
			var player_instance := runtime.peer_players[peer_id_variant] as Player
			if player_instance != null and is_instance_valid(player_instance):
				players.append(player_instance)
	for player_instance in players:
		player_instance.set_xirang_balance(INITIAL_PLAYER_XIRANG)


func apply_network_input_for_peer(
	peer_id: int,
	move_input: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool = false
) -> void:
	var player_instance := get_player_for_peer(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.apply_network_input(
			move_input,
			shoot_input,
			use_skill1,
			use_reload
		)


func update_remote_player_passive_state(delta: float) -> void:
	for peer_id_variant in runtime.peer_players:
		var peer_id := int(peer_id_variant)
		if peer_id == runtime.multiplayer_local_peer_id:
			continue
		var player_instance := runtime.peer_players[peer_id] as Player
		if player_instance != null and is_instance_valid(player_instance):
			player_instance.update_multiplayer_authority_passive_state(delta)


func remove_multiplayer_player(peer_id: int) -> void:
	if peer_id <= 0 or peer_id == runtime.multiplayer_local_peer_id:
		return
	var player_instance := get_player_for_peer(peer_id)
	runtime.peer_players.erase(peer_id)
	_snapshot_encoder.forget_peer(peer_id)
	player_names.erase(peer_id)
	player_character_ids.erase(peer_id)
	if player_instance != null and is_instance_valid(player_instance):
		player_instance.queue_free()
	if runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		run_multiplayer_defeat_check_after_grace()


## 重连 Player 是持久身份的场景投影：已有 new-id 节点时复用并校准，
## 尚未创建时才实例化。这样 CH0 身份通知可安全重放，也不会复制 Player。
func ensure_reconnected_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int
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
	var old_player := runtime.peer_players.get(old_peer_id) as Player
	if (
		old_player != null
		and (
			not is_instance_valid(old_player)
			or old_player.is_queued_for_deletion()
		)
	):
		runtime.peer_players.erase(old_peer_id)
		old_player = null
	var player_instance := runtime.peer_players.get(new_peer_id) as Player
	if (
		player_instance != null
		and (
			not is_instance_valid(player_instance)
			or player_instance.is_queued_for_deletion()
		)
	):
		runtime.peer_players.erase(new_peer_id)
		player_instance = null
	if old_player != null:
		push_error(
			"Combat player roster: 重连时 old=%d 的 Player 尚未退出，拒绝与 new=%d 并存。"
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
			"Combat player roster: 重连目标 %d 的既有角色与认证角色不一致。"
			% new_peer_id
		)
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CONFLICT
		)
	var reused_existing := player_instance != null
	if not reused_existing:
		player_instance = _instantiate_player_character(character_id)
		if player_instance == null:
			return CombatRuntimeBase.ReconnectedPlayerProjection.new(
				CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
			)

	player_instance.name = "Player_%d" % new_peer_id
	if state != null:
		player_instance.position = state.position
	elif not reused_existing:
		player_instance.position = (
			player_spawn.position + get_spawn_offset(spawn_slot_index)
		)
	if not reused_existing:
		runtime.add_child(player_instance)
	_configure_multiplayer_control(player_instance, new_peer_id, player_name)
	if (
		runtime.player_persistent_modifier_projector != null
		and not runtime.player_persistent_modifier_projector.apply_to_player(
			player_instance,
			new_peer_id
		)
	):
		if not reused_existing:
			runtime.remove_child(player_instance)
			player_instance.free()
		return CombatRuntimeBase.ReconnectedPlayerProjection.new(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATE_FAILED
		)
	# 只有持久 owner 也完成投影后才提交 roster 元数据；任一失败
	# 都不会留下只有场景身份、没有研究/命运的半套 Player。
	player_names.erase(old_peer_id)
	player_character_ids.erase(old_peer_id)
	_snapshot_encoder.forget_peer(old_peer_id)
	player_names[new_peer_id] = player_name
	player_character_ids[new_peer_id] = character_id
	_connect_multiplayer_death(player_instance, new_peer_id)
	runtime.peer_players[new_peer_id] = player_instance
	if new_peer_id == runtime.multiplayer_local_peer_id:
		runtime.player = player_instance
	if not reused_existing:
		peer_restored.emit(old_peer_id, new_peer_id)
	return CombatRuntimeBase.ReconnectedPlayerProjection.new(
		(
			CombatRuntimeBase.ReconnectedPlayerProjectionStatus.EXISTING_CURRENT
			if reused_existing
			else CombatRuntimeBase.ReconnectedPlayerProjectionStatus.CREATED
		),
		player_instance
	)


func get_player_for_peer(peer_id: int) -> Player:
	return runtime.peer_players.get(peer_id) as Player if runtime != null else null


func collect_player_snapshot_states() -> Array[SnapshotManager.PlayerState]:
	return _snapshot_encoder.collect(runtime.peer_players)


func get_spawn_offset(index: int) -> Vector2:
	return SPAWN_OFFSETS[index % SPAWN_OFFSETS.size()]


func request_tango_charge_started(direction: Vector2) -> bool:
	if runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return false
	var tango := runtime.player as PlayerTango
	if tango == null or not is_instance_valid(tango):
		return false
	var safe_direction := _sanitize_tango_charge_direction(tango, direction)
	if not tango.try_authoritative_tango_charge_started(safe_direction):
		return false
	_singleplayer_tango_charge_started_at = (
		GameplayPauseController.get_global_gameplay_time_seconds()
	)
	return true


func request_tango_charge_released(direction: Vector2) -> bool:
	if (
		runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER
		or _singleplayer_tango_charge_started_at < 0.0
	):
		return false
	var started_at := _singleplayer_tango_charge_started_at
	_singleplayer_tango_charge_started_at = -1.0
	var tango := runtime.player as PlayerTango
	if tango == null or not is_instance_valid(tango):
		return false
	var elapsed := maxf(
		GameplayPauseController.get_global_gameplay_time_seconds() - started_at,
		0.0
	)
	var charge_ratio := tango.resolve_authoritative_tango_charge_release_ratio(
		elapsed
	)
	if charge_ratio < 0.0:
		tango.cancel_authoritative_tango_charge()
		return true
	var result := tango.try_authoritative_tango_charge_released(
		_sanitize_tango_charge_direction(tango, direction),
		charge_ratio
	)
	var succeeded := bool(result.get("accepted", false)) and bool(
		result.get("fired", false)
	)
	if not succeeded:
		tango.cancel_authoritative_tango_charge()
	return succeeded


func request_tango_charge_cancelled() -> bool:
	if runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.SINGLEPLAYER:
		return false
	var had_active_charge := _singleplayer_tango_charge_started_at >= 0.0
	_singleplayer_tango_charge_started_at = -1.0
	var tango := runtime.player as PlayerTango
	if tango == null or not is_instance_valid(tango):
		return false
	tango.cancel_authoritative_tango_charge()
	return had_active_charge


func handle_singleplayer_died() -> void:
	singleplayer_died.emit()


func handle_multiplayer_player_died(peer_id: int) -> void:
	multiplayer_player_died.emit(peer_id)


func schedule_multiplayer_defeat_check() -> void:
	if runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	if defeat_check_pending:
		return
	defeat_check_pending = true
	var timer := get_tree().create_timer(MULTIPLAYER_DEFEAT_GRACE_SECONDS, false)
	timer.timeout.connect(run_multiplayer_defeat_check_after_grace)


func run_multiplayer_defeat_check_after_grace() -> void:
	defeat_check_pending = false
	if runtime.runtime_mode != CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY:
		return
	for peer_id_variant in runtime.peer_players:
		var candidate := runtime.peer_players[peer_id_variant] as Player
		if candidate != null and is_instance_valid(candidate) and not candidate.is_dead:
			return
	all_players_dead.emit()


func _get_selected_singleplayer_character_id() -> StringName:
	var character_id := run_state.get_selected_character_id()
	return (
		character_id
		if PlayerCharacterRegistry.is_valid_character_id(character_id)
		else DEFAULT_PLAYER_CHARACTER_ID
	)


func get_multiplayer_character_id(peer_id: int) -> StringName:
	var character_id := StringName(
		player_character_ids.get(peer_id, DEFAULT_PLAYER_CHARACTER_ID)
	)
	return (
		character_id
		if PlayerCharacterRegistry.is_valid_character_id(character_id)
		else DEFAULT_PLAYER_CHARACTER_ID
	)


func _instantiate_player_character(character_id: StringName) -> Player:
	var resolved_id := character_id
	if not PlayerCharacterRegistry.is_valid_character_id(resolved_id):
		resolved_id = DEFAULT_PLAYER_CHARACTER_ID
	var instance := PlayerCharacterRegistry.instantiate_character(resolved_id) as Player
	if instance == null:
		push_error("Combat player roster 无法实例化角色 %s" % resolved_id)
	else:
		runtime.bind_player_runtime_context(instance)
	return instance


func _configure_multiplayer_control(
	player_instance: Player,
	peer_id: int,
	display_name: String
) -> void:
	var accepts_local_input := (
		peer_id == runtime.multiplayer_local_peer_id
		and runtime.runtime_mode in [
			CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY,
			CombatRuntimeBase.RuntimeMode.CLIENT_VIEW,
		]
	)
	var predicts_local_movement := (
		runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW
		and peer_id == runtime.multiplayer_local_peer_id
	)
	player_instance.configure_multiplayer_control(
		peer_id,
		accepts_local_input,
		display_name,
		predicts_local_movement,
		peer_id == runtime.multiplayer_local_peer_id
	)
	player_instance.set_multiplayer_visual_smoothing_enabled(
		runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
		and peer_id != runtime.multiplayer_local_peer_id
	)
	if (
		(runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.CLIENT_VIEW and not predicts_local_movement)
		or (
			runtime.runtime_mode == CombatRuntimeBase.RuntimeMode.HOST_AUTHORITY
			and peer_id != runtime.multiplayer_local_peer_id
		)
	):
		player_instance.set_physics_process(false)


func _restore_player_for_combat_scene_entry(
	player_instance: Player,
	ledger_peer_id: int
) -> bool:
	if player_instance == null or not is_instance_valid(player_instance):
		return false
	var progression := run_state.export_player_run_progression(ledger_peer_id)
	if progression.is_empty():
		push_error(
			"Combat player roster 缺少玩家 %d 的本局成长账本。" % ledger_peer_id
		)
		return false
	return player_instance.restore_run_scene_entry(
		progression,
		runtime.player_persistent_modifier_projector
	)


func _connect_multiplayer_death(player_instance: Player, peer_id: int) -> void:
	var callback := handle_multiplayer_player_died.bind(peer_id)
	if not player_instance.died.is_connected(callback):
		player_instance.died.connect(callback)


func _on_singleplayer_died() -> void:
	handle_singleplayer_died()


func _sanitize_tango_charge_direction(
	player_instance: Player,
	direction: Vector2
) -> Vector2:
	if (
		is_finite(direction.x)
		and is_finite(direction.y)
		and direction.length_squared() > 0.0001
	):
		return direction.normalized()
	match player_instance.get_multiplayer_facing_id():
		1:
			return Vector2.LEFT
		2:
			return Vector2.UP
		3:
			return Vector2.DOWN
		_:
			return Vector2.RIGHT
