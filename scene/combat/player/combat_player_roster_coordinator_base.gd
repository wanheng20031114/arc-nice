extends Node
class_name CombatPlayerRosterCoordinatorBase

signal singleplayer_died
signal multiplayer_player_died(peer_id: int)
signal all_players_dead
signal peer_restored(old_peer_id: int, new_peer_id: int)

const DEFAULT_PLAYER_CHARACTER_ID := &"weishidaier"
const MULTIPLAYER_DEFEAT_GRACE_SECONDS := 0.25
const TANGO_MINIMUM_CHARGE_SECONDS := 0.2
const TANGO_MAXIMUM_CHARGE_SECONDS := 2.4
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001
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
	var player_instance := _instantiate_player_character(
		_get_selected_singleplayer_character_id()
	)
	if player_instance == null:
		return
	player_instance.name = "Player"
	player_instance.position = player_spawn.position
	runtime.add_child(player_instance)
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
	for index in range(peer_ids.size()):
		var peer_id := peer_ids[index]
		var player_instance := _instantiate_player_character(
			get_multiplayer_character_id(peer_id)
		)
		if player_instance == null:
			continue
		player_instance.name = "Player_%d" % peer_id
		player_instance.position = player_spawn.position + get_spawn_offset(index)
		runtime.add_child(player_instance)
		_configure_multiplayer_control(player_instance, peer_id)
		_connect_multiplayer_death(player_instance, peer_id)
		runtime.peer_players[peer_id] = player_instance
		if peer_id == runtime.multiplayer_local_peer_id:
			runtime.player = player_instance
	if runtime.player == null and not peer_ids.is_empty():
		runtime.player = runtime.peer_players.get(peer_ids[0]) as Player


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


func restore_multiplayer_player(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName,
	state: SnapshotManager.PlayerState,
	spawn_slot_index: int
) -> Player:
	if (
		new_peer_id <= 0
		or runtime.peer_players.has(new_peer_id)
		or not PlayerCharacterRegistry.is_valid_character_id(character_id)
	):
		return null
	player_names.erase(old_peer_id)
	player_character_ids.erase(old_peer_id)
	_snapshot_encoder.forget_peer(old_peer_id)
	player_names[new_peer_id] = player_name
	player_character_ids[new_peer_id] = character_id
	peer_restored.emit(old_peer_id, new_peer_id)
	var player_instance := _instantiate_player_character(character_id)
	if player_instance == null:
		return null
	player_instance.name = "Player_%d" % new_peer_id
	player_instance.position = (
		state.position
		if state != null
		else player_spawn.position + get_spawn_offset(spawn_slot_index)
	)
	runtime.add_child(player_instance)
	_configure_multiplayer_control(player_instance, new_peer_id)
	_connect_multiplayer_death(player_instance, new_peer_id)
	runtime.peer_players[new_peer_id] = player_instance
	return player_instance


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
	_singleplayer_tango_charge_started_at = Time.get_ticks_usec() / 1000000.0
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
	var elapsed := maxf(Time.get_ticks_usec() / 1000000.0 - started_at, 0.0)
	if elapsed + TANGO_CHARGE_THRESHOLD_EPSILON < TANGO_MINIMUM_CHARGE_SECONDS:
		tango.cancel_authoritative_tango_charge()
		return true
	var charge_ratio := clampf(
		(elapsed - TANGO_MINIMUM_CHARGE_SECONDS)
		/ (TANGO_MAXIMUM_CHARGE_SECONDS - TANGO_MINIMUM_CHARGE_SECONDS),
		0.0,
		1.0
	)
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
	var timer := get_tree().create_timer(MULTIPLAYER_DEFEAT_GRACE_SECONDS)
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
	peer_id: int
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
		str(player_names.get(peer_id, "Player %d" % peer_id)),
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
