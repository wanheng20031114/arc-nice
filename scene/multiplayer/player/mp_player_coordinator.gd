extends Node
class_name MpPlayerCoordinator

signal life_rpc_broadcast_requested(method_name: StringName, arguments: Array)
signal player_action_rpc_to_host_requested(
	method_name: StringName,
	arguments: Array
)
signal player_action_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
)
signal player_action_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
)
signal realtime_rpc_to_host_requested(
	method_name: StringName,
	arguments: Array
)
signal player_snapshot_send_requested(
	peer_id: int,
	host_timestamp: float,
	data: PackedByteArray,
	entity_count: int
)
signal stale_player_peer_detected(peer_id: int)
signal player_state_correction_requested(
	peer_id: int,
	corrected_position: Vector2,
	corrected_velocity: Vector2
)
signal authoritative_teleport_broadcast_requested(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int
)
signal tiyi_high_noon_damage_requested(
	owner_player: PlayerTiyi,
	enemy_net_id: int,
	enemy: Enemy
)

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const GAME_RUNTIME_CLIENT_VIEW := 2
const SHARED_SNAPSHOT_COHORT_ID := -1
const PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS := 0.5
const PLAYER_REVIVE_INVINCIBILITY_SECONDS := 3.0
const HIT_DEDUP_RETENTION_SECONDS := 30.0
const INPUT_BUTTON_RELOAD := 2
const INPUT_BUTTON_DASH := 4
const INPUT_CHANGE_EPSILON := 0.001
const DASH_INPUT_REDUNDANCY_PACKETS := 3
const DASH_COOLDOWN_NETWORK_TOLERANCE_SECONDS := 0.35
const PLAYER_STATE_MAX_ACCEPTED_JUMP_DISTANCE := 2048.0
const PLAYER_STATE_POSITION_TOLERANCE := 24.0
const PLAYER_STATE_MAX_VALIDATION_SECONDS := 0.25
const PLAYER_STATE_SPEED_TOLERANCE_MULTIPLIER := 1.75
const PLAYER_ACTION_INGRESS_RATE_PER_SECOND := 24.0
const PLAYER_ACTION_INGRESS_RATE_BURST := 32.0
const HOE_ACTION_PRIMARY := &"primary"
const HOE_ACTION_WHIRLWIND := &"whirlwind"
const TANGO_CHARGE_MINIMUM_SECONDS := 0.2
const TANGO_CHARGE_MAXIMUM_SECONDS := 2.4
const TANGO_BARRAGE_MAXIMUM_SECONDS := 5.0
const TANGO_CHARGE_THRESHOLD_EPSILON := 0.0001
const TANGO_CHARGE_PHASE_START := "start"
const TANGO_CHARGE_PHASE_RELEASE := "release"
const TANGO_CHARGE_PHASE_CANCEL := "cancel"
const TANGO_ELECTRIC_SURGE_DURATION_SECONDS := 8.0
const TANGO_ELECTRIC_SURGE_TIME_TOLERANCE_SECONDS := 0.25
const TIYI_HIGH_NOON_MAX_TARGETS := 25
const FIRE_SLIME_TOUCH_TYPE: StringName = &"fire_slime_touch"
const FROST_SLIME_TOUCH_TYPE: StringName = &"frost_slime_touch"
const FROST_SORCERER_ICE_SPIKE_TYPE: StringName = &"frost_sorcerer_ice_spike"
## Protocol-v62 appends these presentation/status acknowledgements to the
## existing reliable player-damage confirmation. They are deliberately scoped
## to the main-battle robot because the payload carries no arbitrary source id.
const CONFIRMED_STATUS_MAIN_BATTLE_BURN := 1 << 0
const CONFIRMED_STATUS_MAIN_BATTLE_SLOW := 1 << 1
const CONFIRMED_STATUS_MASK_KNOWN := (
	CONFIRMED_STATUS_MAIN_BATTLE_BURN
	| CONFIRMED_STATUS_MAIN_BATTLE_SLOW
)
const TANGO_ELECTRIC_SURGE_FIELD_SCENE := preload(
	"res://scene/player/tango/tango_electric_surge_field.tscn"
)


class HostSnapshotBatch:
	extends RefCounted

	var peer_ids: Array[int] = []
	var host_timestamp := 0.0
	var data := PackedByteArray()
	var entity_count := 0

	func is_empty() -> bool:
		return peer_ids.is_empty() or data.is_empty() or entity_count <= 0


var _runtime: CombatRuntimeBase = null
var _realtime_net_manager: NetManagerStore = null
var _session_coordinator: MpSessionCoordinator = null
var _net_manager: NetManagerStore = null
var _mode_adapter: MultiplayerModeAdapter = null
var _projectile_coordinator: MpProjectileCoordinator = null
var _get_net_time_callable := Callable()
var _cancel_tango_for_revive_schedule_callable := Callable()
var _cancel_actions_for_revive_callable := Callable()
var _clear_tiyi_lifecycle_state_callable := Callable()
var _get_revive_anchor_position_callable := Callable()
var _commit_revive_position_callable := Callable()
var _action_net_manager: NetManagerStore = null
var _get_action_net_time_callable := Callable()
var _is_embedded_participant_suspended_callable := Callable()
var _snapshot_manager := SnapshotManager.new()
var _visual_interpolators: Dictionary[int, NetInterpolator] = {}
var _teleport_cutoff_sequences: Dictionary[int, int] = {}
var _pending_authoritative_teleports: Dictionary[int, Dictionary] = {}
var _character_mismatch_warnings: Dictionary[int, bool] = {}
var _latest_client_states: Dictionary[int, Dictionary] = {}
var _applied_health_revisions: Dictionary[int, int] = {}
var _last_keyframe_time_by_peer: Dictionary[int, float] = {}
var _snapshot_cohort_peers: Dictionary[int, bool] = {}
var _host_snapshot_sequence := 0
var _snapshot_encode_count := 0
var _processed_player_hit_ids: Dictionary = {}
var _player_health_revisions: Dictionary = {}
var _dead_player_revive_times: Dictionary = {}
var _dead_player_revive_last_seconds: Dictionary = {}
var _revive_random_generator := RandomNumberGenerator.new()
var _local_dash_request_sequence := 0
var _pending_dash_request_sequence := 0
var _pending_dash_direction := Vector2.ZERO
var _pending_dash_start_move_input := Vector2.ZERO
var _pending_dash_input_packets := 0
var _local_hoe_action_request_id := 0
var _local_tango_charge_request_id := 0
var _local_tango_active_request_id := 0
var _local_tango_release_pending := false
var _local_tango_electric_surge_request_id := 0
var _local_tiyi_activation_request_id := 0
var _last_player_state_sequences: Dictionary[int, int] = {}
var _last_dash_request_sequences: Dictionary[int, int] = {}
var _last_dash_confirmed_sequences: Dictionary[int, int] = {}
var _last_dash_accepted_times: Dictionary[int, float] = {}
var _hoe_action_sequences_by_peer: Dictionary[int, int] = {}
var _last_hoe_action_request_ids: Dictionary[int, int] = {}
var _tango_charge_sequences_by_peer: Dictionary[int, int] = {}
var _last_tango_charge_request_ids: Dictionary[int, int] = {}
var _active_tango_charges_by_peer: Dictionary[int, Dictionary] = {}
var _tango_electric_surge_sequences_by_peer: Dictionary[int, int] = {}
var _last_tango_electric_surge_request_ids: Dictionary[int, int] = {}
var _active_tango_electric_surges_by_peer: Dictionary[int, Dictionary] = {}
var _last_tango_electric_surge_seen_by_peer: Dictionary[int, int] = {}
var _tiyi_activation_sequences_by_peer: Dictionary[int, int] = {}
var _active_tiyi_activations_by_peer: Dictionary[int, int] = {}
var _tiyi_target_ids_by_peer: Dictionary[int, PackedInt32Array] = {}
var _pending_tiyi_target_updates: Dictionary[int, Dictionary] = {}
var _pending_remote_tiyi_target_updates: Dictionary[int, Dictionary] = {}
var _last_tiyi_activation_seen_by_peer: Dictionary[int, int] = {}
var _accepted_player_state_positions: Dictionary[int, Vector2] = {}
var _accepted_player_state_times: Dictionary[int, float] = {}
var _player_action_ingress_rate_buckets: Dictionary[int, Dictionary] = {}
var _realtime_input_sequence := 0
var _has_sent_realtime_input := false
var _last_sent_move_input := Vector2.ZERO
var _last_sent_shoot_input := Vector2.ZERO
var _input_frames_since_last_send := _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
var _client_shoot_input_was_passive_tango_aim := false


func bind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	assert(runtime_instance != null, "MpPlayerCoordinator 缺少战斗运行时。")
	if _runtime == runtime_instance:
		return
	if _runtime != null:
		reset_session_state()
	_runtime = runtime_instance


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	_runtime = null
	_clear_realtime_dependencies()
	_clear_life_dependencies()
	_clear_player_action_dependencies()
	reset_session_state()


func is_bound() -> bool:
	return _runtime != null and is_instance_valid(_runtime)


func bind_realtime_dependencies(
	net_manager_instance: NetManagerStore,
	session_coordinator_instance: MpSessionCoordinator
) -> void:
	assert(
		net_manager_instance != null,
		"MpPlayerCoordinator 缺少实时同步 NetManagerStore。"
	)
	assert(
		session_coordinator_instance != null,
		"MpPlayerCoordinator 缺少实时同步 MpSessionCoordinator。"
	)
	_realtime_net_manager = net_manager_instance
	_session_coordinator = session_coordinator_instance


func has_realtime_dependencies() -> bool:
	return (
		is_bound()
		and _realtime_net_manager != null
		and is_instance_valid(_realtime_net_manager)
		and _session_coordinator != null
		and is_instance_valid(_session_coordinator)
	)


func update_client_realtime_input(
	frame: int,
	client_host_game_ready: bool
) -> void:
	if (
		not has_realtime_dependencies()
		or not _realtime_net_manager.is_client()
		or not client_host_game_ready
	):
		return
	_input_frames_since_last_send += 1
	var buttons := 0
	if Input.is_action_just_pressed("reload"):
		buttons |= INPUT_BUTTON_RELOAD
	if has_pending_dash_input_packet():
		buttons |= INPUT_BUTTON_DASH
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0 or buttons != 0:
		send_client_input_if_needed(buttons)
		if (buttons & INPUT_BUTTON_DASH) != 0:
			consume_pending_dash_input_packet()


func send_client_input_if_needed(buttons: int) -> bool:
	if not has_realtime_dependencies() or not _realtime_net_manager.is_client():
		return false
	var move_input := Input.get_vector(
		"move_left",
		"move_right",
		"move_up",
		"move_down"
	)
	var player_node := _runtime.player
	if player_node == null or not is_instance_valid(player_node):
		return false
	_client_shoot_input_was_passive_tango_aim = false
	var combat_actions_locked := player_node.are_combat_actions_locked()
	var shoot_input := (
		Vector2.ZERO
		if combat_actions_locked
		else get_client_shoot_input()
	)
	var uses_passive_tango_mouse_aim := (
		_client_shoot_input_was_passive_tango_aim
	)
	if combat_actions_locked:
		buttons &= ~INPUT_BUTTON_RELOAD
	if player_node.is_dead:
		_last_sent_move_input = Vector2.ZERO
		_last_sent_shoot_input = Vector2.ZERO
		return false
	var input_changed := (
		not _has_sent_realtime_input
		or move_input.distance_squared_to(_last_sent_move_input)
		> INPUT_CHANGE_EPSILON
		or shoot_input.distance_squared_to(_last_sent_shoot_input)
		> INPUT_CHANGE_EPSILON
	)
	var keepalive_due := (
		_input_frames_since_last_send
		>= _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
	)
	var active_input_state := is_client_input_state_active(
		move_input,
		shoot_input,
		player_node.velocity,
		uses_passive_tango_mouse_aim
	)
	if (
		not input_changed
		and not keepalive_due
		and buttons == 0
		and not active_input_state
	):
		return false
	_realtime_input_sequence += 1
	_has_sent_realtime_input = true
	_last_sent_move_input = move_input
	_last_sent_shoot_input = shoot_input
	_input_frames_since_last_send = 0
	realtime_rpc_to_host_requested.emit(
		&"_rpc_client_player_state",
		[
			_realtime_input_sequence,
			player_node.global_position,
			player_node.velocity,
			move_input,
			shoot_input,
			buttons,
			get_pending_dash_request_sequence(),
			get_pending_dash_direction(),
			get_pending_dash_start_move_input(),
		]
	)
	return true


func get_client_shoot_input() -> Vector2:
	var shoot_input := Input.get_vector(
		"shoot_left",
		"shoot_right",
		"shoot_up",
		"shoot_down"
	)
	if shoot_input != Vector2.ZERO:
		return shoot_input
	if not is_bound() or _runtime.player == null:
		return Vector2.ZERO
	var passive_tango_aim := uses_passive_tango_mouse_aim(
		_runtime.player
	)
	if (
		not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		and not passive_tango_aim
	):
		return Vector2.ZERO
	_client_shoot_input_was_passive_tango_aim = passive_tango_aim
	return _runtime.player.global_position.direction_to(
		_runtime.player.get_global_mouse_position()
	)


func uses_passive_tango_mouse_aim(player_node: Player) -> bool:
	var tango_player := player_node as PlayerTango
	return tango_player != null and tango_player.uses_passive_tango_mouse_aim()


func is_client_input_state_active(
	move_input: Vector2,
	shoot_input: Vector2,
	velocity: Vector2,
	uses_passive_tango_aim: bool
) -> bool:
	return (
		move_input != Vector2.ZERO
		or (shoot_input != Vector2.ZERO and not uses_passive_tango_aim)
		or velocity.length_squared() > INPUT_CHANGE_EPSILON
	)


func get_realtime_input_sequence() -> int:
	return _realtime_input_sequence


func bind_player_action_dependencies(
	net_manager_instance: NetManagerStore,
	get_net_time_callable: Callable,
	is_embedded_participant_suspended_callable: Callable
) -> void:
	assert(net_manager_instance != null, "MpPlayerCoordinator 缺少动作 NetManager。")
	assert(
		get_net_time_callable.is_valid(),
		"MpPlayerCoordinator 缺少动作网络时钟。"
	)
	assert(
		is_embedded_participant_suspended_callable.is_valid(),
		"MpPlayerCoordinator 缺少内嵌参战者状态入口。"
	)
	_action_net_manager = net_manager_instance
	_get_action_net_time_callable = get_net_time_callable
	_is_embedded_participant_suspended_callable = (
		is_embedded_participant_suspended_callable
	)


func has_player_action_dependencies() -> bool:
	return (
		is_bound()
		and _action_net_manager != null
		and is_instance_valid(_action_net_manager)
		and _get_action_net_time_callable.is_valid()
		and _is_embedded_participant_suspended_callable.is_valid()
	)


func notify_local_player_dash_started(
	direction: Vector2,
	start_move_input: Vector2,
	client_host_game_ready: bool
) -> void:
	if not has_player_action_dependencies() or not client_host_game_ready:
		return
	if not _is_finite_vector2(direction) or not _is_finite_vector2(start_move_input):
		return
	if direction.length_squared() <= 0.001 or start_move_input.length_squared() <= 0.001:
		return
	var peer_id := _get_action_local_peer_id()
	var player_node := _runtime.get_player_for_peer(peer_id)
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or not player_node.is_dashing()
	):
		return
	var safe_direction := direction.normalized()
	var safe_start_move_input := start_move_input.limit_length(1.0)
	if safe_direction.dot(safe_start_move_input.normalized()) < 0.8:
		return
	_local_dash_request_sequence += 1
	_pending_dash_request_sequence = _local_dash_request_sequence
	_pending_dash_direction = safe_direction
	_pending_dash_start_move_input = safe_start_move_input
	_pending_dash_input_packets = DASH_INPUT_REDUNDANCY_PACKETS
	if _action_net_manager.is_host():
		_pending_dash_input_packets = 0
		_broadcast_player_dash_confirmed(
			peer_id,
			safe_direction,
			_pending_dash_request_sequence
		)
	elif _action_net_manager.is_client():
		player_action_rpc_to_host_requested.emit(
			&"net_player_dash_requested",
			[
				_pending_dash_request_sequence,
				safe_direction,
				safe_start_move_input,
			]
		)


func has_pending_dash_input_packet() -> bool:
	return _pending_dash_input_packets > 0


func get_pending_dash_request_sequence() -> int:
	return _pending_dash_request_sequence


func get_pending_dash_direction() -> Vector2:
	return _pending_dash_direction


func get_pending_dash_start_move_input() -> Vector2:
	return _pending_dash_start_move_input


func consume_pending_dash_input_packet() -> void:
	if _pending_dash_input_packets <= 0:
		return
	_pending_dash_input_packets -= 1
	if _pending_dash_input_packets <= 0:
		_clear_pending_dash_input()


func request_hoe_primary_attack(
	direction: Vector2,
	client_host_game_ready: bool
) -> bool:
	if not has_player_action_dependencies() or not client_host_game_ready:
		return false
	var peer_id := _get_action_local_peer_id()
	var hoe_player := _get_hoe_player(peer_id)
	if hoe_player == null:
		return false
	var safe_direction := _sanitize_hoe_action_direction(hoe_player, direction)
	if _action_net_manager.is_host():
		return apply_authoritative_hoe_action(
			peer_id,
			HOE_ACTION_PRIMARY,
			safe_direction
		)
	if not _action_net_manager.is_client():
		return false
	_local_hoe_action_request_id += 1
	hoe_player.play_predicted_hoe_action(
		HOE_ACTION_PRIMARY,
		safe_direction,
		_local_hoe_action_request_id
	)
	player_action_rpc_to_host_requested.emit(
		&"net_hoe_primary_attack_requested",
		[safe_direction, _local_hoe_action_request_id]
	)
	return true


func request_hoe_whirlwind(client_host_game_ready: bool) -> bool:
	if not has_player_action_dependencies() or not client_host_game_ready:
		return false
	var peer_id := _get_action_local_peer_id()
	var hoe_player := _get_hoe_player(peer_id)
	if hoe_player == null:
		return false
	if _action_net_manager.is_host():
		return apply_authoritative_hoe_action(
			peer_id,
			HOE_ACTION_WHIRLWIND,
			Vector2.ZERO
		)
	if not _action_net_manager.is_client():
		return false
	_local_hoe_action_request_id += 1
	hoe_player.play_predicted_hoe_action(
		HOE_ACTION_WHIRLWIND,
		Vector2.ZERO,
		_local_hoe_action_request_id
	)
	player_action_rpc_to_host_requested.emit(
		&"net_hoe_whirlwind_requested",
		[_local_hoe_action_request_id]
	)
	return true


func request_tango_electric_surge(client_host_game_ready: bool) -> bool:
	if not has_player_action_dependencies() or not client_host_game_ready:
		return false
	var peer_id := _get_action_local_peer_id()
	var tango_player := _get_tango_player(peer_id)
	if (
		tango_player == null
		or tango_player.is_electric_surge_active()
		or _active_tango_electric_surges_by_peer.has(peer_id)
	):
		return false
	_local_tango_electric_surge_request_id += 1
	var request_id := _local_tango_electric_surge_request_id
	if _action_net_manager.is_host():
		return apply_authoritative_tango_electric_surge_request(
			peer_id,
			request_id
		)
	if not _action_net_manager.is_client():
		return false
	player_action_rpc_to_host_requested.emit(
		&"net_tango_electric_surge_requested",
		[request_id]
	)
	return true


func spawn_authoritative_tango_electric_surge_field(
	owner_player: Player,
	activation_id: int,
	origin: Vector2
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or owner_player == null
		or not is_instance_valid(owner_player)
		or not (owner_player is PlayerTango)
		or activation_id <= 0
		or not _is_finite_vector2(origin)
	):
		return false
	var owner_peer_id := owner_player.peer_id
	if owner_peer_id <= 0 or _runtime.get_player_for_peer(owner_peer_id) != owner_player:
		return false
	var field := (
		TANGO_ELECTRIC_SURGE_FIELD_SCENE.instantiate()
		as TangoElectricSurgeField
	)
	if field == null:
		return false
	var gameplay_gateway := _runtime.get_multiplayer_gameplay_gateway()
	if gameplay_gateway == null:
		field.free()
		return false
	field.bind_gameplay_context(_runtime, gameplay_gateway)
	field.finished.connect(
		_on_authoritative_tango_electric_surge_field_finished.bind(
			owner_peer_id,
			activation_id
		),
		CONNECT_ONE_SHOT
	)
	_runtime.add_child(field)
	field.global_position = origin
	field.setup(
		owner_player,
		activation_id,
		TANGO_ELECTRIC_SURGE_DURATION_SECONDS,
		true
	)
	return true


func spawn_remote_tango_electric_surge_visual_field(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float
) -> bool:
	if (
		not is_bound()
		or activation_id <= 0
		or not _is_finite_vector2(origin)
		or not is_finite(remaining_seconds)
		or remaining_seconds <= 0.0
	):
		return false
	var field := (
		TANGO_ELECTRIC_SURGE_FIELD_SCENE.instantiate()
		as TangoElectricSurgeField
	)
	if field == null:
		return false
	var gameplay_gateway := _runtime.get_multiplayer_gameplay_gateway()
	if gameplay_gateway == null:
		field.free()
		return false
	field.bind_gameplay_context(_runtime, gameplay_gateway)
	_runtime.add_child(field)
	field.global_position = origin
	field.setup_multiplayer_visual_only(
		activation_id,
		minf(remaining_seconds, TANGO_ELECTRIC_SURGE_DURATION_SECONDS)
	)
	return true


func handle_tango_electric_surge_request(sender_id: int, request_id: int) -> void:
	if (
		not consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	apply_authoritative_tango_electric_surge_request(sender_id, request_id)


func apply_authoritative_tango_electric_surge_request(
	peer_id: int,
	request_id: int
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or request_id <= 0
	):
		return false
	var last_request_id := int(
		_last_tango_electric_surge_request_ids.get(peer_id, 0)
	)
	if request_id <= last_request_id:
		return false
	_last_tango_electric_surge_request_ids[peer_id] = request_id
	if _active_tango_electric_surges_by_peer.has(peer_id):
		return false
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		return false
	var activation_id := int(
		_tango_electric_surge_sequences_by_peer.get(peer_id, 0)
	) + 1
	var auto_fire_charge_sequence := int(
		_tango_charge_sequences_by_peer.get(peer_id, 0)
	) + 1
	var origin := tango_player.global_position
	if not tango_player.try_start_authoritative_electric_surge(
		activation_id,
		origin,
		auto_fire_charge_sequence
	):
		return false
	# 电场接管整段射击状态；先可靠终止普通蓄力，再广播电涌开始。
	if _active_tango_charges_by_peer.has(peer_id):
		cancel_authoritative_tango_charge(peer_id, true)
	_tango_charge_sequences_by_peer[peer_id] = auto_fire_charge_sequence
	var started_at := _get_action_net_time()
	var buff_active := tango_player.is_electric_surge_active()
	_tango_electric_surge_sequences_by_peer[peer_id] = activation_id
	_active_tango_electric_surges_by_peer[peer_id] = {
		"activation_id": activation_id,
		"origin": origin,
		"started_at": started_at,
		"duration": TANGO_ELECTRIC_SURGE_DURATION_SECONDS,
		"request_id": request_id,
		"charge_sequence": auto_fire_charge_sequence,
	}
	player_action_rpc_broadcast_requested.emit(
		&"net_tango_electric_surge_started",
		[
			peer_id,
			activation_id,
			origin,
			TANGO_ELECTRIC_SURGE_DURATION_SECONDS,
			started_at,
			buff_active,
			request_id,
			auto_fire_charge_sequence,
		]
	)
	return true


func receive_tango_electric_surge_started(
	sender_id: int,
	peer_id: int,
	activation_id: int,
	origin: Vector2,
	remaining_seconds_at_send: float,
	host_sent_at: float,
	buff_active: bool,
	request_id: int,
	auto_fire_charge_sequence: int
) -> void:
	var transport_age_seconds := 0.0
	if (
		has_realtime_dependencies()
		and _session_coordinator.has_host_time_offset()
		and (
			sender_id <= 0
			or sender_id == _realtime_net_manager.get_host_peer_id()
		)
		and is_finite(host_sent_at)
	):
		var local_sent_at := (
			_session_coordinator.map_host_timestamp_to_client_time(
				host_sent_at,
				false
			)
		)
		transport_age_seconds = maxf(
			_session_coordinator.get_net_time() - local_sent_at,
			0.0
		)
	apply_tango_electric_surge_started(
		sender_id,
		peer_id,
		activation_id,
		origin,
		remaining_seconds_at_send,
		host_sent_at,
		buff_active,
		request_id,
		auto_fire_charge_sequence,
		transport_age_seconds
	)


func apply_tango_electric_surge_started(
	sender_id: int,
	peer_id: int,
	activation_id: int,
	origin: Vector2,
	remaining_seconds_at_send: float,
	host_sent_at: float,
	buff_active: bool,
	request_id: int,
	auto_fire_charge_sequence: int,
	transport_age_seconds: float = 0.0
) -> void:
	if not has_player_action_dependencies():
		return
	var host_peer_id := _action_net_manager.get_host_peer_id()
	if sender_id > 0 and sender_id != host_peer_id:
		return
	var last_seen_activation_id := int(
		_last_tango_electric_surge_seen_by_peer.get(peer_id, 0)
	)
	if (
		peer_id <= 0
		or activation_id <= 0
		or request_id <= 0
		or auto_fire_charge_sequence <= 0
		or not _is_finite_vector2(origin)
		or not is_finite(remaining_seconds_at_send)
		or not is_finite(host_sent_at)
		or remaining_seconds_at_send < 0.0
		or remaining_seconds_at_send
			> TANGO_ELECTRIC_SURGE_DURATION_SECONDS
			+ TANGO_ELECTRIC_SURGE_TIME_TOLERANCE_SECONDS
		or activation_id < last_seen_activation_id
	):
		return
	var tango_player := _get_tango_player(peer_id)
	var is_recovery_replay := activation_id == last_seen_activation_id
	var recovery_record: Dictionary = {}
	if is_recovery_replay:
		recovery_record = _active_tango_electric_surges_by_peer.get(
			peer_id,
			{}
		) as Dictionary
		if int(recovery_record.get("activation_id", 0)) != activation_id:
			return
		buff_active = buff_active and bool(recovery_record.get("buff_active", true))
		recovery_record["buff_active"] = buff_active
		recovery_record["charge_sequence"] = maxi(
			int(recovery_record.get("charge_sequence", 0)),
			auto_fire_charge_sequence
		)
		_active_tango_electric_surges_by_peer[peer_id] = recovery_record
	var remaining := clampf(
		remaining_seconds_at_send,
		0.0,
		TANGO_ELECTRIC_SURGE_DURATION_SECONDS
	)
	if is_finite(transport_age_seconds):
		remaining = maxf(remaining - maxf(transport_age_seconds, 0.0), 0.0)
	if is_recovery_replay:
		if remaining <= 0.0:
			_active_tango_electric_surges_by_peer.erase(peer_id)
			if bool(recovery_record.get("owner_disconnected", false)):
				_clear_tango_electric_surge_sequence_guards(peer_id)
			if tango_player != null:
				tango_player.cancel_remote_electric_surge(activation_id)
			return
		if buff_active and tango_player != null:
			tango_player.play_remote_electric_surge_started(
				activation_id,
				origin,
				remaining,
				false,
				auto_fire_charge_sequence
			)
		elif tango_player != null:
			tango_player.cancel_remote_electric_surge(activation_id)
		return
	if remaining <= 0.0:
		return
	_last_tango_electric_surge_seen_by_peer[peer_id] = activation_id
	_tango_electric_surge_sequences_by_peer[peer_id] = maxi(
		int(_tango_electric_surge_sequences_by_peer.get(peer_id, 0)),
		activation_id
	)
	_tango_charge_sequences_by_peer[peer_id] = maxi(
		int(_tango_charge_sequences_by_peer.get(peer_id, 0)),
		auto_fire_charge_sequence
	)
	_active_tango_electric_surges_by_peer[peer_id] = {
		"activation_id": activation_id,
		"origin": origin,
		"remaining_seconds_at_send": remaining_seconds_at_send,
		"host_sent_at": host_sent_at,
		"request_id": request_id,
		"charge_sequence": auto_fire_charge_sequence,
		"buff_active": buff_active,
		"owner_disconnected": tango_player == null,
	}
	spawn_remote_tango_electric_surge_visual_field(
		activation_id,
		origin,
		remaining
	)
	if buff_active and tango_player != null:
		tango_player.play_remote_electric_surge_started(
			activation_id,
			origin,
			remaining,
			false,
			auto_fire_charge_sequence
		)


func apply_tango_electric_surge_finished(
	sender_id: int,
	peer_id: int,
	activation_id: int
) -> void:
	if not has_player_action_dependencies() or peer_id <= 0 or activation_id <= 0:
		return
	var host_peer_id := _action_net_manager.get_host_peer_id()
	if sender_id > 0 and sender_id != host_peer_id:
		return
	var record := _active_tango_electric_surges_by_peer.get(peer_id, {}) as Dictionary
	if int(record.get("activation_id", 0)) != activation_id:
		return
	_active_tango_electric_surges_by_peer.erase(peer_id)
	if bool(record.get("owner_disconnected", false)):
		_clear_tango_electric_surge_sequence_guards(peer_id)
	var tango_player := _get_tango_player(peer_id)
	if tango_player != null:
		tango_player.cancel_remote_electric_surge(activation_id)


func finish_authoritative_tango_electric_surge(
	peer_id: int,
	activation_id: int
) -> void:
	var record := _active_tango_electric_surges_by_peer.get(peer_id, {}) as Dictionary
	if int(record.get("activation_id", 0)) != activation_id:
		return
	_active_tango_electric_surges_by_peer.erase(peer_id)
	player_action_rpc_broadcast_requested.emit(
		&"net_tango_electric_surge_finished",
		[peer_id, activation_id]
	)
	if bool(record.get("owner_disconnected", false)):
		_clear_tango_electric_surge_sequence_guards(peer_id)


func send_active_tango_electric_surges_to_peer(target_peer_id: int) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or target_peer_id <= 0
	):
		return
	var now := _get_action_net_time()
	var owner_peer_ids: Array[int] = []
	for owner_peer_id_variant in _active_tango_electric_surges_by_peer.keys():
		owner_peer_ids.append(int(owner_peer_id_variant))
	owner_peer_ids.sort()
	for owner_peer_id in owner_peer_ids:
		var record := _active_tango_electric_surges_by_peer.get(
			owner_peer_id,
			{}
		) as Dictionary
		var started_at := float(record.get("started_at", now))
		var duration := float(
			record.get("duration", TANGO_ELECTRIC_SURGE_DURATION_SECONDS)
		)
		var remaining_seconds := clampf(
			duration - maxf(now - started_at, 0.0),
			0.0,
			duration
		)
		if remaining_seconds <= 0.0:
			continue
		var owner_player := _get_tango_player(owner_peer_id)
		var buff_active := (
			owner_player != null and owner_player.is_electric_surge_active()
		)
		player_action_rpc_to_peer_requested.emit(
			target_peer_id,
			&"net_tango_electric_surge_started",
			[
				owner_peer_id,
				int(record.get("activation_id", 0)),
				record.get("origin", Vector2.ZERO) as Vector2,
				remaining_seconds,
				now,
				buff_active,
				int(record.get("request_id", 1)),
				int(record.get("charge_sequence", 0)),
			]
		)


func send_authoritative_positions_to_peer(target_peer_id: int) -> void:
	if (
		target_peer_id <= 0
		or not has_player_action_dependencies()
		or not _action_net_manager.is_host()
	):
		return
	for state_peer_id_variant in _runtime.peer_players.keys():
		var state_peer_id := int(state_peer_id_variant)
		var player_node := _runtime.get_player_for_peer(state_peer_id)
		if (
			state_peer_id <= 0
			or player_node == null
			or not is_instance_valid(player_node)
		):
			continue
		player_action_rpc_to_peer_requested.emit(
			target_peer_id,
			&"net_player_authoritative_teleported",
			[
				state_peer_id,
				player_node.global_position,
				get_host_snapshot_sequence(),
			]
		)


func apply_authoritative_tango_charge_snapshot_ratios(
	states: Array[SnapshotManager.PlayerState],
	sample_time: float
) -> void:
	for state in states:
		if state == null or state.character_id != &"tango":
			continue
		state.primary_cooldown_ratio = 0.0
		var charge := _active_tango_charges_by_peer.get(
			state.peer_id,
			{}
		) as Dictionary
		if charge.is_empty():
			continue
		var started_at := float(charge.get("started_at", sample_time))
		state.primary_cooldown_ratio = clampf(
			maxf(sample_time - started_at, 0.0) / TANGO_CHARGE_MAXIMUM_SECONDS,
			0.0,
			1.0
		)


func request_tango_charge_started(
	direction: Vector2,
	client_host_game_ready: bool
) -> bool:
	if (
		not has_player_action_dependencies()
		or not client_host_game_ready
		or _local_tango_active_request_id > 0
	):
		return false
	var peer_id := _get_action_local_peer_id()
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		return false
	var safe_direction := _sanitize_tango_charge_direction(tango_player, direction)
	_local_tango_charge_request_id += 1
	var request_id := _local_tango_charge_request_id
	if _action_net_manager.is_host():
		var accepted := apply_authoritative_tango_charge_started(
			peer_id,
			safe_direction,
			request_id
		)
		if accepted and tango_player.is_tango_charge_active():
			_local_tango_active_request_id = request_id
		return accepted
	if not _action_net_manager.is_client():
		return false
	_local_tango_active_request_id = request_id
	_local_tango_release_pending = false
	player_action_rpc_to_host_requested.emit(
		&"net_tango_charge_started_requested",
		[safe_direction, request_id]
	)
	return true


func request_tango_charge_released(
	direction: Vector2,
	client_host_game_ready: bool
) -> bool:
	if (
		not has_player_action_dependencies()
		or not client_host_game_ready
		or _local_tango_active_request_id <= 0
		or _local_tango_release_pending
	):
		return false
	var peer_id := _get_action_local_peer_id()
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		return false
	var safe_direction := _sanitize_tango_charge_direction(tango_player, direction)
	var request_id := _local_tango_active_request_id
	_local_tango_release_pending = true
	if _action_net_manager.is_host():
		var handled := apply_authoritative_tango_charge_released(
			peer_id,
			safe_direction,
			request_id
		)
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
		return handled
	if not _action_net_manager.is_client():
		_local_tango_release_pending = false
		return false
	player_action_rpc_to_host_requested.emit(
		&"net_tango_charge_released_requested",
		[safe_direction, request_id]
	)
	return true


func request_tango_charge_cancelled(client_host_game_ready: bool) -> bool:
	if (
		not has_player_action_dependencies()
		or not client_host_game_ready
		or _local_tango_active_request_id <= 0
		or _local_tango_release_pending
	):
		return false
	var peer_id := _get_action_local_peer_id()
	if _get_tango_player(peer_id) == null:
		return false
	var request_id := _local_tango_active_request_id
	_local_tango_release_pending = true
	if _action_net_manager.is_host():
		var handled := apply_authoritative_tango_charge_cancelled(peer_id, request_id)
		if not handled:
			_local_tango_release_pending = false
		return handled
	if not _action_net_manager.is_client():
		_local_tango_release_pending = false
		return false
	player_action_rpc_to_host_requested.emit(
		&"net_tango_charge_cancelled_requested",
		[request_id]
	)
	return true


func handle_tango_charge_started_request(
	sender_id: int,
	direction: Vector2,
	request_id: int
) -> void:
	if (
		not consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	apply_authoritative_tango_charge_started(sender_id, direction, request_id)


func handle_tango_charge_released_request(
	sender_id: int,
	direction: Vector2,
	request_id: int
) -> void:
	if (
		not consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	apply_authoritative_tango_charge_released(sender_id, direction, request_id)


func handle_tango_charge_cancelled_request(sender_id: int, request_id: int) -> void:
	if (
		not consume_remote_player_action_admission(sender_id)
		or request_id <= 0
	):
		return
	apply_authoritative_tango_charge_cancelled(sender_id, request_id)


func apply_authoritative_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or request_id <= 0
	):
		return false
	var last_request_id := int(_last_tango_charge_request_ids.get(peer_id, 0))
	if request_id <= last_request_id:
		return false
	_last_tango_charge_request_ids[peer_id] = request_id
	if not _is_finite_vector2(direction) or _active_tango_charges_by_peer.has(peer_id):
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	var safe_direction := _sanitize_tango_charge_direction(tango_player, direction)
	if not tango_player.try_authoritative_tango_charge_started(safe_direction):
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	var charge_sequence := int(_tango_charge_sequences_by_peer.get(peer_id, 0)) + 1
	_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	if (
		tango_player.is_electric_surge_active()
		and tango_player.is_tango_barrage_active()
	):
		player_action_rpc_broadcast_requested.emit(
			&"net_tango_charge_released",
			[peer_id, safe_direction, 1.0, charge_sequence, request_id]
		)
		return true
	if not tango_player.is_tango_charge_active():
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_START)
		return false
	_active_tango_charges_by_peer[peer_id] = {
		"request_id": request_id,
		"sequence": charge_sequence,
		"started_at": _get_action_net_time(),
	}
	player_action_rpc_broadcast_requested.emit(
		&"net_tango_charge_started",
		[peer_id, safe_direction, charge_sequence, request_id]
	)
	return true


func apply_authoritative_tango_charge_released(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or request_id <= 0
	):
		return false
	var charge := _active_tango_charges_by_peer.get(peer_id, {}) as Dictionary
	if charge.is_empty() or int(charge.get("request_id", 0)) != request_id:
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var charge_sequence := int(charge.get("sequence", 0))
	if not _is_finite_vector2(direction) or charge_sequence <= 0:
		cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	var elapsed := maxf(
		_get_action_net_time() - float(charge.get("started_at", 0.0)),
		0.0
	)
	if elapsed + TANGO_CHARGE_THRESHOLD_EPSILON < TANGO_CHARGE_MINIMUM_SECONDS:
		cancel_authoritative_tango_charge(peer_id, true, request_id)
		return true
	var charge_ratio := clampf(
		(elapsed - TANGO_CHARGE_MINIMUM_SECONDS)
		/ (TANGO_CHARGE_MAXIMUM_SECONDS - TANGO_CHARGE_MINIMUM_SECONDS),
		0.0,
		1.0
	)
	var safe_direction := _sanitize_tango_charge_direction(tango_player, direction)
	var result := tango_player.try_authoritative_tango_charge_released(
		safe_direction,
		charge_ratio
	)
	if not bool(result.get("accepted", false)) or not bool(result.get("fired", false)):
		cancel_authoritative_tango_charge(peer_id, true, request_id)
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_RELEASE)
		return false
	_active_tango_charges_by_peer.erase(peer_id)
	player_action_rpc_broadcast_requested.emit(
		&"net_tango_charge_released",
		[peer_id, safe_direction, charge_ratio, charge_sequence, request_id]
	)
	return true


func apply_authoritative_tango_charge_cancelled(peer_id: int, request_id: int) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or request_id <= 0
	):
		return false
	var charge := _active_tango_charges_by_peer.get(peer_id, {}) as Dictionary
	if charge.is_empty() or int(charge.get("request_id", 0)) != request_id:
		_send_tango_charge_rejected(peer_id, request_id, TANGO_CHARGE_PHASE_CANCEL)
		return false
	cancel_authoritative_tango_charge(peer_id, true, request_id)
	return true


func cancel_authoritative_tango_charge(
	peer_id: int,
	broadcast_cancel: bool,
	request_id: int = 0
) -> void:
	var charge := _active_tango_charges_by_peer.get(peer_id, {}) as Dictionary
	if charge.is_empty():
		return
	var charge_sequence := int(charge.get("sequence", 0))
	var resolved_request_id := int(charge.get("request_id", request_id))
	_active_tango_charges_by_peer.erase(peer_id)
	if (
		peer_id == _get_action_local_peer_id()
		and resolved_request_id == _local_tango_active_request_id
	):
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
	var tango_player := _get_tango_player(peer_id)
	if tango_player != null:
		tango_player.cancel_authoritative_tango_charge()
	if broadcast_cancel and charge_sequence > 0:
		player_action_rpc_broadcast_requested.emit(
			&"net_tango_charge_cancelled",
			[peer_id, charge_sequence, resolved_request_id]
		)


func update_authoritative_tango_charge_lifecycle() -> void:
	if _active_tango_charges_by_peer.is_empty() or not is_bound():
		return
	var cancelled_peer_ids: Array[int] = []
	for peer_id_variant in _active_tango_charges_by_peer.keys():
		var peer_id := int(peer_id_variant)
		var tango_player := _get_tango_player(peer_id)
		if tango_player != null and tango_player.is_tango_charge_active():
			continue
		cancelled_peer_ids.append(peer_id)
	for peer_id in cancelled_peer_ids:
		cancel_authoritative_tango_charge(peer_id, true)


func apply_tango_charge_started(
	sender_id: int,
	peer_id: int,
	direction: Vector2,
	charge_sequence: int,
	request_id: int
) -> void:
	if (
		not has_player_action_dependencies()
		or sender_id != _action_net_manager.get_host_peer_id()
		or peer_id <= 0
		or charge_sequence <= 0
		or request_id <= 0
		or not _is_finite_vector2(direction)
		or charge_sequence <= int(_tango_charge_sequences_by_peer.get(peer_id, 0))
	):
		return
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		return
	var safe_direction := _sanitize_tango_charge_direction(tango_player, direction)
	_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	if peer_id == _get_action_local_peer_id():
		if request_id != _local_tango_active_request_id:
			return
		tango_player.reconcile_predicted_tango_charge_started(
			safe_direction,
			charge_sequence
		)
		return
	tango_player.play_remote_tango_charge_started(safe_direction, charge_sequence)


func apply_tango_charge_released(
	sender_id: int,
	peer_id: int,
	direction: Vector2,
	charge_ratio: float,
	charge_sequence: int,
	request_id: int
) -> void:
	if (
		not has_player_action_dependencies()
		or sender_id != _action_net_manager.get_host_peer_id()
	):
		return
	var last_charge_sequence := int(_tango_charge_sequences_by_peer.get(peer_id, 0))
	if (
		peer_id <= 0
		or charge_sequence <= 0
		or request_id <= 0
		or not _is_finite_vector2(direction)
		or not is_finite(charge_ratio)
		or charge_ratio < 0.0
		or charge_ratio > 1.0
		or charge_sequence < last_charge_sequence
	):
		return
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		return
	if charge_sequence > last_charge_sequence:
		_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	var safe_direction := _sanitize_tango_charge_direction(tango_player, direction)
	if peer_id == _get_action_local_peer_id():
		if request_id != _local_tango_active_request_id:
			return
		tango_player.reconcile_predicted_tango_barrage_started(
			safe_direction,
			charge_ratio,
			charge_sequence
		)
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
		return
	tango_player.play_remote_tango_barrage_started(
		safe_direction,
		charge_ratio,
		charge_sequence
	)


func apply_tango_charge_cancelled(
	sender_id: int,
	peer_id: int,
	charge_sequence: int,
	request_id: int
) -> void:
	if (
		not has_player_action_dependencies()
		or sender_id != _action_net_manager.get_host_peer_id()
	):
		return
	var last_charge_sequence := int(_tango_charge_sequences_by_peer.get(peer_id, 0))
	if (
		peer_id <= 0
		or charge_sequence <= 0
		or request_id <= 0
		or charge_sequence < last_charge_sequence
	):
		return
	var tango_player := _get_tango_player(peer_id)
	if tango_player == null:
		return
	if charge_sequence > last_charge_sequence:
		_tango_charge_sequences_by_peer[peer_id] = charge_sequence
	if peer_id == _get_action_local_peer_id():
		if request_id != _local_tango_active_request_id:
			return
		tango_player.play_remote_tango_charge_cancelled(charge_sequence)
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
		return
	tango_player.play_remote_tango_charge_cancelled(charge_sequence)


func apply_tango_charge_rejected(
	sender_id: int,
	peer_id: int,
	request_id: int,
	phase_text: String
) -> void:
	if (
		not has_player_action_dependencies()
		or sender_id != _action_net_manager.get_host_peer_id()
		or peer_id != _get_action_local_peer_id()
		or request_id <= 0
		or (
			phase_text != TANGO_CHARGE_PHASE_START
			and phase_text != TANGO_CHARGE_PHASE_RELEASE
			and phase_text != TANGO_CHARGE_PHASE_CANCEL
		)
		or request_id != _local_tango_active_request_id
	):
		return
	_local_tango_active_request_id = 0
	_local_tango_release_pending = false
	var tango_player := _get_tango_player(peer_id)
	if tango_player != null:
		tango_player.reject_predicted_tango_charge()


func has_local_tango_prediction() -> bool:
	return _local_tango_active_request_id > 0


func has_active_tango_charge(peer_id: int) -> bool:
	return _active_tango_charges_by_peer.has(peer_id)


func has_active_tango_electric_surge(peer_id: int) -> bool:
	return _active_tango_electric_surges_by_peer.has(peer_id)


func get_active_tango_electric_surge_record(peer_id: int) -> Dictionary:
	return (
		_active_tango_electric_surges_by_peer.get(peer_id, {}) as Dictionary
	).duplicate(true)


func get_tango_charge_sequence(peer_id: int) -> int:
	return int(_tango_charge_sequences_by_peer.get(peer_id, 0))


func observe_tango_charge_sequence(peer_id: int, charge_sequence: int) -> int:
	if peer_id <= 0 or charge_sequence <= 0:
		return get_tango_charge_sequence(peer_id)
	var next_sequence := maxi(get_tango_charge_sequence(peer_id), charge_sequence)
	_tango_charge_sequences_by_peer[peer_id] = next_sequence
	return next_sequence


func get_tango_laser_barrage_maximum_seconds(
	owner_peer_id: int,
	charge_ratio: float
) -> float:
	var charge_sequence := get_tango_charge_sequence(owner_peer_id)
	var active_surge_record := _active_tango_electric_surges_by_peer.get(
		owner_peer_id,
		{}
	) as Dictionary
	if (
		not active_surge_record.is_empty()
		and charge_sequence > 0
		and int(active_surge_record.get("charge_sequence", 0)) == charge_sequence
		and charge_ratio >= 1.0 - TANGO_CHARGE_THRESHOLD_EPSILON
	):
		return TANGO_ELECTRIC_SURGE_DURATION_SECONDS
	return TANGO_BARRAGE_MAXIMUM_SECONDS


func mark_tango_owner_disconnected(peer_id: int) -> void:
	var surge_record := _active_tango_electric_surges_by_peer.get(
		peer_id,
		{}
	) as Dictionary
	if surge_record.is_empty():
		return
	surge_record["owner_disconnected"] = true
	_active_tango_electric_surges_by_peer[peer_id] = surge_record


func cancel_tango_charge_for_life_transition(peer_id: int) -> void:
	if _active_tango_charges_by_peer.has(peer_id):
		cancel_authoritative_tango_charge(peer_id, true)


func _send_tango_charge_rejected(
	peer_id: int,
	request_id: int,
	phase_text: String
) -> void:
	if (
		not has_player_action_dependencies()
		or peer_id <= 0
		or request_id <= 0
		or peer_id == _action_net_manager.get_host_peer_id()
	):
		return
	player_action_rpc_to_peer_requested.emit(
		peer_id,
		&"net_tango_charge_rejected",
		[peer_id, request_id, phase_text]
	)


func _on_authoritative_tango_electric_surge_field_finished(
	_field: Node,
	owner_peer_id: int,
	activation_id: int
) -> void:
	finish_authoritative_tango_electric_surge(owner_peer_id, activation_id)


func _clear_tango_electric_surge_sequence_guards(peer_id: int) -> void:
	_tango_electric_surge_sequences_by_peer.erase(peer_id)
	_last_tango_electric_surge_request_ids.erase(peer_id)
	_last_tango_electric_surge_seen_by_peer.erase(peer_id)
	_tango_charge_sequences_by_peer.erase(peer_id)
	_last_tango_charge_request_ids.erase(peer_id)


func _get_tango_player(peer_id: int) -> PlayerTango:
	if not is_bound() or peer_id <= 0:
		return null
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return null
	return player_node as PlayerTango


func _sanitize_tango_charge_direction(
	tango_player: PlayerTango,
	direction: Vector2
) -> Vector2:
	if _is_finite_vector2(direction) and direction.length_squared() > 0.0001:
		return direction.normalized()
	if tango_player == null:
		return Vector2.RIGHT
	match tango_player.get_multiplayer_facing_id():
		1:
			return Vector2.LEFT
		2:
			return Vector2.UP
		3:
			return Vector2.DOWN
		_:
			return Vector2.RIGHT


func request_tiyi_high_noon(client_host_game_ready: bool) -> bool:
	if not has_player_action_dependencies() or not client_host_game_ready:
		return false
	var peer_id := _get_action_local_peer_id()
	var tiyi_player := _get_tiyi_player(peer_id)
	if (
		tiyi_player == null
		or tiyi_player.is_high_noon_active()
		or _active_tiyi_activations_by_peer.has(peer_id)
	):
		return false
	if _action_net_manager.is_host():
		var activation_id := int(
			_tiyi_activation_sequences_by_peer.get(peer_id, 0)
		) + 1
		return apply_authoritative_tiyi_high_noon_request(
			peer_id,
			activation_id
		)
	if not _action_net_manager.is_client():
		return false
	_local_tiyi_activation_request_id += 1
	player_action_rpc_to_host_requested.emit(
		&"net_tiyi_high_noon_requested",
		[_local_tiyi_activation_request_id]
	)
	return true


func notify_tiyi_high_noon_targets_changed(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or int(_active_tiyi_activations_by_peer.get(peer_id, 0))
			!= activation_id
	):
		return
	var sanitized_target_ids := sanitize_tiyi_target_ids(target_ids)
	_tiyi_target_ids_by_peer[peer_id] = sanitized_target_ids
	_pending_tiyi_target_updates[peer_id] = {
		"activation_id": activation_id,
		"target_ids": sanitized_target_ids,
	}


func resolve_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	_hit_positions: PackedVector2Array
) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or int(_active_tiyi_activations_by_peer.get(peer_id, 0))
			!= activation_id
	):
		return
	var tiyi_player := _get_tiyi_player(peer_id)
	if tiyi_player == null:
		cancel_authoritative_tiyi_high_noon(peer_id, activation_id, true)
		return
	var locked_ids := _tiyi_target_ids_by_peer.get(
		peer_id,
		PackedInt32Array()
	) as PackedInt32Array
	var locked_lookup: Dictionary[int, bool] = {}
	for locked_id in locked_ids:
		locked_lookup[int(locked_id)] = true
	var resolved_ids := PackedInt32Array()
	var resolved_positions := PackedVector2Array()
	var resolved_enemies: Array[Enemy] = []
	var seen_ids: Dictionary[int, bool] = {}
	for target_index in range(mini(target_ids.size(), TIYI_HIGH_NOON_MAX_TARGETS)):
		var enemy_net_id := int(target_ids[target_index])
		if (
			enemy_net_id <= 0
			or seen_ids.has(enemy_net_id)
			or not locked_lookup.has(enemy_net_id)
		):
			continue
		var enemy := _get_authoritative_tiyi_enemy(enemy_net_id)
		if enemy == null:
			continue
		seen_ids[enemy_net_id] = true
		resolved_ids.append(enemy_net_id)
		resolved_positions.append(enemy.global_position)
		resolved_enemies.append(enemy)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_pending_tiyi_target_updates.erase(peer_id)
	player_action_rpc_broadcast_requested.emit(
		&"net_tiyi_high_noon_finished",
		[peer_id, activation_id, resolved_ids, resolved_positions]
	)
	for target_index in range(resolved_enemies.size()):
		var enemy := resolved_enemies[target_index]
		if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
			continue
		tiyi_high_noon_damage_requested.emit(
			tiyi_player,
			int(resolved_ids[target_index]),
			enemy
		)


func cancel_tiyi_high_noon(peer_id: int, activation_id: int) -> void:
	cancel_authoritative_tiyi_high_noon(peer_id, activation_id, true)


func handle_tiyi_high_noon_request(sender_id: int, activation_id: int) -> void:
	if (
		not consume_remote_player_action_admission(sender_id)
		or activation_id <= 0
	):
		return
	apply_authoritative_tiyi_high_noon_request(sender_id, activation_id)


func apply_authoritative_tiyi_high_noon_request(
	peer_id: int,
	activation_id: int
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or activation_id <= 0
	):
		return false
	var tiyi_player := _get_tiyi_player(peer_id)
	if (
		tiyi_player == null
		or _active_tiyi_activations_by_peer.has(peer_id)
		or activation_id <= int(
			_tiyi_activation_sequences_by_peer.get(peer_id, 0)
		)
		or not tiyi_player.try_start_authoritative_high_noon(activation_id)
	):
		return false
	_tiyi_activation_sequences_by_peer[peer_id] = activation_id
	_active_tiyi_activations_by_peer[peer_id] = activation_id
	_tiyi_target_ids_by_peer[peer_id] = PackedInt32Array()
	player_action_rpc_broadcast_requested.emit(
		&"net_tiyi_high_noon_started",
		[peer_id, activation_id]
	)
	tiyi_player.sync_authoritative_high_noon_targets()
	return true


func apply_tiyi_high_noon_started(
	sender_id: int,
	peer_id: int,
	activation_id: int
) -> void:
	if (
		not _is_tiyi_authority_sender(sender_id)
		or peer_id <= 0
		or activation_id <= 0
		or _active_tiyi_activations_by_peer.has(peer_id)
		or activation_id <= int(_last_tiyi_activation_seen_by_peer.get(peer_id, 0))
	):
		return
	var tiyi_player := _get_tiyi_player(peer_id)
	if tiyi_player == null or tiyi_player.is_high_noon_active():
		return
	_last_tiyi_activation_seen_by_peer[peer_id] = activation_id
	_active_tiyi_activations_by_peer[peer_id] = activation_id
	_tiyi_target_ids_by_peer[peer_id] = PackedInt32Array()
	tiyi_player.play_remote_high_noon_started(activation_id)
	var pending_update := _pending_remote_tiyi_target_updates.get(
		peer_id,
		{}
	) as Dictionary
	var pending_activation_id := int(pending_update.get("activation_id", 0))
	if pending_activation_id != activation_id:
		if pending_activation_id > 0 and pending_activation_id < activation_id:
			_pending_remote_tiyi_target_updates.erase(peer_id)
		return
	_pending_remote_tiyi_target_updates.erase(peer_id)
	var pending_target_ids := pending_update.get(
		"target_ids",
		PackedInt32Array()
	) as PackedInt32Array
	_tiyi_target_ids_by_peer[peer_id] = pending_target_ids
	tiyi_player.apply_remote_high_noon_targets(
		activation_id,
		pending_target_ids
	)


func apply_tiyi_high_noon_targets(
	sender_id: int,
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	if (
		not _is_tiyi_authority_sender(sender_id)
		or peer_id <= 0
		or activation_id <= 0
	):
		return
	var sanitized_target_ids := sanitize_tiyi_target_ids(target_ids, false)
	var active_activation_id := int(
		_active_tiyi_activations_by_peer.get(peer_id, 0)
	)
	if active_activation_id != activation_id:
		if (
			active_activation_id == 0
			and activation_id > int(
				_last_tiyi_activation_seen_by_peer.get(peer_id, 0)
			)
		):
			_pending_remote_tiyi_target_updates[peer_id] = {
				"activation_id": activation_id,
				"target_ids": sanitized_target_ids,
			}
		return
	var tiyi_player := _get_tiyi_player(peer_id)
	if tiyi_player == null:
		return
	_tiyi_target_ids_by_peer[peer_id] = sanitized_target_ids
	tiyi_player.apply_remote_high_noon_targets(
		activation_id,
		sanitized_target_ids
	)


func apply_tiyi_high_noon_finished(
	sender_id: int,
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	if (
		not _is_tiyi_authority_sender(sender_id)
		or peer_id <= 0
		or activation_id <= 0
		or int(_active_tiyi_activations_by_peer.get(peer_id, 0))
			!= activation_id
	):
		return
	var tiyi_player := _get_tiyi_player(peer_id)
	if tiyi_player == null:
		return
	var target_count := mini(
		mini(target_ids.size(), hit_positions.size()),
		TIYI_HIGH_NOON_MAX_TARGETS
	)
	var sanitized_target_ids := PackedInt32Array()
	var sanitized_hit_positions := PackedVector2Array()
	var seen_ids: Dictionary[int, bool] = {}
	for target_index in range(target_count):
		var enemy_net_id := int(target_ids[target_index])
		var hit_position := hit_positions[target_index]
		if (
			enemy_net_id <= 0
			or seen_ids.has(enemy_net_id)
			or not _is_finite_vector2(hit_position)
		):
			continue
		seen_ids[enemy_net_id] = true
		sanitized_target_ids.append(enemy_net_id)
		sanitized_hit_positions.append(hit_position)
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_clear_tiyi_remote_target_update_through(peer_id, activation_id)
	tiyi_player.play_remote_high_noon_finished(
		activation_id,
		sanitized_target_ids,
		sanitized_hit_positions
	)


func apply_tiyi_high_noon_cancelled(
	sender_id: int,
	peer_id: int,
	activation_id: int
) -> void:
	if (
		not _is_tiyi_authority_sender(sender_id)
		or peer_id <= 0
		or activation_id <= 0
		or int(_active_tiyi_activations_by_peer.get(peer_id, 0))
			!= activation_id
	):
		return
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_clear_tiyi_remote_target_update_through(peer_id, activation_id)
	var tiyi_player := _get_tiyi_player(peer_id)
	if tiyi_player != null:
		tiyi_player.cancel_remote_high_noon(activation_id)


func cancel_authoritative_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	broadcast_cancel: bool
) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or activation_id <= 0
		or int(_active_tiyi_activations_by_peer.get(peer_id, 0))
			!= activation_id
	):
		return
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_pending_tiyi_target_updates.erase(peer_id)
	if broadcast_cancel:
		player_action_rpc_broadcast_requested.emit(
			&"net_tiyi_high_noon_cancelled",
			[peer_id, activation_id]
		)


func flush_tiyi_target_updates() -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or _pending_tiyi_target_updates.is_empty()
	):
		return
	var peer_ids: Array[int] = []
	for peer_id_variant in _pending_tiyi_target_updates.keys():
		peer_ids.append(int(peer_id_variant))
	peer_ids.sort()
	for peer_id in peer_ids:
		var update := _pending_tiyi_target_updates.get(peer_id, {}) as Dictionary
		player_action_rpc_broadcast_requested.emit(
			&"net_tiyi_high_noon_targets",
			[
				peer_id,
				int(update.get("activation_id", 0)),
				update.get(
					"target_ids",
					PackedInt32Array()
				) as PackedInt32Array,
			]
		)
	_pending_tiyi_target_updates.clear()


func send_active_tiyi_high_noon_to_peer(target_peer_id: int) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or target_peer_id <= 0
	):
		return
	var owner_peer_ids: Array[int] = []
	for owner_peer_id_variant in _active_tiyi_activations_by_peer.keys():
		owner_peer_ids.append(int(owner_peer_id_variant))
	owner_peer_ids.sort()
	for owner_peer_id in owner_peer_ids:
		var activation_id := int(
			_active_tiyi_activations_by_peer.get(owner_peer_id, 0)
		)
		if activation_id <= 0:
			continue
		player_action_rpc_to_peer_requested.emit(
			target_peer_id,
			&"net_tiyi_high_noon_started",
			[owner_peer_id, activation_id]
		)
		player_action_rpc_to_peer_requested.emit(
			target_peer_id,
			&"net_tiyi_high_noon_targets",
			[
				owner_peer_id,
				activation_id,
				get_tiyi_high_noon_target_ids(owner_peer_id),
			]
		)


func sanitize_tiyi_target_ids(
	target_ids: PackedInt32Array,
	require_host_enemy: bool = true
) -> PackedInt32Array:
	var sanitized_ids := PackedInt32Array()
	var seen_ids: Dictionary[int, bool] = {}
	for target_id_variant in target_ids:
		if sanitized_ids.size() >= TIYI_HIGH_NOON_MAX_TARGETS:
			break
		var enemy_net_id := int(target_id_variant)
		if enemy_net_id <= 0 or seen_ids.has(enemy_net_id):
			continue
		if require_host_enemy and _get_authoritative_tiyi_enemy(enemy_net_id) == null:
			continue
		seen_ids[enemy_net_id] = true
		sanitized_ids.append(enemy_net_id)
	return sanitized_ids


func has_active_tiyi_high_noon(peer_id: int) -> bool:
	return _active_tiyi_activations_by_peer.has(peer_id)


func get_active_tiyi_high_noon_activation_id(peer_id: int) -> int:
	return int(_active_tiyi_activations_by_peer.get(peer_id, 0))


func get_tiyi_high_noon_target_ids(peer_id: int) -> PackedInt32Array:
	var target_ids := _tiyi_target_ids_by_peer.get(
		peer_id,
		PackedInt32Array()
	) as PackedInt32Array
	return target_ids.duplicate()


func cancel_tiyi_for_life_transition(peer_id: int) -> void:
	var activation_id := get_active_tiyi_high_noon_activation_id(peer_id)
	if activation_id > 0:
		cancel_authoritative_tiyi_high_noon(peer_id, activation_id, true)


func clear_tiyi_lifecycle_state(peer_id: int) -> void:
	_active_tiyi_activations_by_peer.erase(peer_id)
	_tiyi_target_ids_by_peer.erase(peer_id)
	_pending_tiyi_target_updates.erase(peer_id)
	_pending_remote_tiyi_target_updates.erase(peer_id)


func _clear_tiyi_remote_target_update_through(
	peer_id: int,
	activation_id: int
) -> void:
	var pending_update := _pending_remote_tiyi_target_updates.get(
		peer_id,
		{}
	) as Dictionary
	if int(pending_update.get("activation_id", 0)) <= activation_id:
		_pending_remote_tiyi_target_updates.erase(peer_id)


func _is_tiyi_authority_sender(sender_id: int) -> bool:
	return (
		has_player_action_dependencies()
		and (
			sender_id <= 0
			or sender_id == _action_net_manager.get_host_peer_id()
		)
	)


func _get_tiyi_player(peer_id: int) -> PlayerTiyi:
	if not is_bound() or peer_id <= 0:
		return null
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return null
	return player_node as PlayerTiyi


func _get_authoritative_tiyi_enemy(enemy_net_id: int) -> Enemy:
	if not is_bound() or enemy_net_id <= 0:
		return null
	var enemy := _runtime.get_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy) or enemy.is_dead:
		return null
	return enemy


func handle_client_player_state(
	sender_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2,
	move_input: Vector2,
	shoot_input: Vector2,
	buttons: int,
	dash_request_sequence: int,
	dash_direction: Vector2,
	dash_start_move_input: Vector2
) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or sender_id <= 0
	):
		return
	var player_node := _runtime.get_player_for_peer(sender_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if player_node.is_dead or player_node.controls_locked:
		player_state_correction_requested.emit(
			sender_id,
			player_node.global_position,
			player_node.velocity
		)
		return
	if not accept_client_player_state(
		sender_id,
		sequence,
		reported_position,
		reported_velocity
	):
		player_state_correction_requested.emit(
			sender_id,
			player_node.global_position,
			player_node.velocity
		)
		return
	var combat_actions_locked := player_node.are_combat_actions_locked()
	if combat_actions_locked:
		shoot_input = Vector2.ZERO
	var use_reload := (
		(buttons & INPUT_BUTTON_RELOAD) != 0
		and not combat_actions_locked
	)
	if (buttons & INPUT_BUTTON_DASH) != 0:
		var dash_movement_evidence := dash_start_move_input
		if dash_movement_evidence.length_squared() <= 0.001:
			dash_movement_evidence = move_input
		if dash_movement_evidence.length_squared() <= 0.001:
			dash_movement_evidence = reported_velocity
		try_accept_client_dash_request(
			sender_id,
			player_node,
			dash_request_sequence,
			dash_direction,
			dash_movement_evidence
		)
	apply_accepted_client_player_state(
		sender_id,
		player_node,
		reported_position,
		reported_velocity,
		shoot_input,
		false,
		use_reload
	)


func accept_client_player_state(
	peer_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2
) -> bool:
	if not has_player_action_dependencies():
		return false
	var last_sequence := int(_last_player_state_sequences.get(peer_id, 0))
	if sequence <= last_sequence:
		return false
	_last_player_state_sequences[peer_id] = sequence
	if not _is_finite_vector2(reported_position) or not _is_finite_vector2(reported_velocity):
		return false
	var now := _get_action_net_time()
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if not _accepted_player_state_positions.has(peer_id):
		if (
			player_node.global_position.distance_to(reported_position)
			> PLAYER_STATE_POSITION_TOLERANCE * 4.0
		):
			return false
		remember_accepted_player_pose(peer_id, reported_position, now)
		return true
	var previous_position := _accepted_player_state_positions[peer_id]
	var previous_time := float(_accepted_player_state_times.get(peer_id, now))
	var elapsed := clampf(
		now - previous_time,
		1.0 / 120.0,
		PLAYER_STATE_MAX_VALIDATION_SECONDS
	)
	var effective_speed := maxf(player_node.move_speed, 1.0)
	var allowed_distance := (
		effective_speed * elapsed * PLAYER_STATE_SPEED_TOLERANCE_MULTIPLIER
		+ PLAYER_STATE_POSITION_TOLERANCE
	)
	var last_dash_time := float(_last_dash_accepted_times.get(peer_id, -INF))
	if now - last_dash_time <= DASH_COOLDOWN_NETWORK_TOLERANCE_SECONDS:
		allowed_distance += maxf(player_node.get_dash_distance(), 0.0)
	allowed_distance = minf(allowed_distance, PLAYER_STATE_MAX_ACCEPTED_JUMP_DISTANCE)
	var movement_delta := reported_position - previous_position
	if movement_delta.length() > allowed_distance:
		return false
	if reported_velocity.length() > effective_speed * 3.0 + PLAYER_STATE_POSITION_TOLERANCE:
		return false
	if (
		movement_delta.length_squared() > 0.001
		and player_node.test_move(player_node.global_transform, movement_delta)
	):
		return false
	remember_accepted_player_pose(peer_id, reported_position, now)
	return true


func apply_accepted_client_player_state(
	sender_id: int,
	player_node: Player,
	reported_position: Vector2,
	reported_velocity: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool = false
) -> void:
	if sender_id <= 0 or player_node == null or not is_instance_valid(player_node):
		return
	player_node.apply_remote_multiplayer_state(
		reported_position,
		reported_velocity,
		shoot_input,
		use_skill1,
		use_reload
	)
	remember_latest_client_state(
		true,
		sender_id,
		reported_position,
		reported_velocity,
		player_node.get_multiplayer_facing_id(),
		player_node.get_multiplayer_anim_state()
	)


func handle_dash_request(
	sender_id: int,
	dash_request_sequence: int,
	direction: Vector2,
	start_move_input: Vector2
) -> void:
	if not consume_remote_player_action_admission(sender_id):
		return
	try_accept_client_dash_request(
		sender_id,
		_runtime.get_player_for_peer(sender_id),
		dash_request_sequence,
		direction,
		start_move_input
	)


func try_accept_client_dash_request(
	peer_id: int,
	player_node: Player,
	dash_request_sequence: int,
	direction: Vector2,
	movement_evidence: Vector2
) -> bool:
	if not has_player_action_dependencies() or peer_id <= 0 or dash_request_sequence <= 0:
		return false
	if player_node == null or not is_instance_valid(player_node):
		return false
	if dash_request_sequence <= int(_last_dash_request_sequences.get(peer_id, 0)):
		return false
	if not _is_finite_vector2(direction) or not _is_finite_vector2(movement_evidence):
		return false
	if direction.length_squared() <= 0.001 or movement_evidence.length_squared() <= 0.001:
		return false
	var safe_direction := direction.normalized()
	if safe_direction.dot(movement_evidence.normalized()) < 0.8:
		return false
	var accepted_at := _get_action_net_time()
	var minimum_dash_interval := maxf(
		player_node.get_dash_cooldown() - DASH_COOLDOWN_NETWORK_TOLERANCE_SECONDS,
		0.0
	)
	if _last_dash_accepted_times.has(peer_id):
		var last_accepted_at := float(_last_dash_accepted_times[peer_id])
		if accepted_at - last_accepted_at < minimum_dash_interval:
			return false
	if not player_node.start_multiplayer_dash_protection(safe_direction):
		return false
	_last_dash_request_sequences[peer_id] = dash_request_sequence
	_last_dash_accepted_times[peer_id] = accepted_at
	_broadcast_player_dash_confirmed(peer_id, safe_direction, dash_request_sequence)
	return true


func apply_dash_confirmation(
	player_peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	if (
		not has_player_action_dependencies()
		or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW
	):
		return
	if player_peer_id == _get_action_local_peer_id():
		if dash_request_sequence == _pending_dash_request_sequence:
			_clear_pending_dash_input()
		return
	if dash_request_sequence <= int(
		_last_dash_confirmed_sequences.get(player_peer_id, 0)
	):
		return
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_last_dash_confirmed_sequences[player_peer_id] = dash_request_sequence
	player_node.play_remote_dash_visual(direction)


func handle_hoe_primary_request(
	sender_id: int,
	direction: Vector2,
	request_id: int
) -> void:
	if not consume_remote_player_action_admission(sender_id):
		return
	apply_authoritative_hoe_action(
		sender_id,
		HOE_ACTION_PRIMARY,
		direction,
		request_id
	)


func handle_hoe_whirlwind_request(sender_id: int, request_id: int) -> void:
	if not consume_remote_player_action_admission(sender_id):
		return
	apply_authoritative_hoe_action(
		sender_id,
		HOE_ACTION_WHIRLWIND,
		Vector2.ZERO,
		request_id
	)


func apply_authoritative_hoe_action(
	peer_id: int,
	action_kind: StringName,
	direction: Vector2,
	request_id: int = 0
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
	):
		return false
	var hoe_player := _get_hoe_player(peer_id)
	if hoe_player == null:
		return false
	if request_id > 0:
		var last_request_id := int(_last_hoe_action_request_ids.get(peer_id, 0))
		if request_id <= last_request_id:
			return false
		_last_hoe_action_request_ids[peer_id] = request_id
	var safe_direction := _sanitize_hoe_action_direction(hoe_player, direction)
	var succeeded := false
	match action_kind:
		HOE_ACTION_PRIMARY:
			succeeded = hoe_player.try_authoritative_hoe_primary_attack(safe_direction)
		HOE_ACTION_WHIRLWIND:
			succeeded = hoe_player.try_authoritative_hoe_whirlwind()
		_:
			return false
	if not succeeded:
		if request_id > 0 and peer_id != _get_action_local_peer_id():
			player_action_rpc_to_peer_requested.emit(
				peer_id,
				&"net_hoe_action_confirmed",
				[
					peer_id,
					String(action_kind),
					safe_direction,
					int(_hoe_action_sequences_by_peer.get(peer_id, 0)),
					request_id,
					false,
					_get_player_primary_cooldown_ratio(hoe_player),
					hoe_player.skill1_charge,
				]
			)
		return false
	var action_sequence := int(_hoe_action_sequences_by_peer.get(peer_id, 0)) + 1
	_hoe_action_sequences_by_peer[peer_id] = action_sequence
	player_action_rpc_broadcast_requested.emit(
		&"net_hoe_action_confirmed",
		[
			peer_id,
			String(action_kind),
			safe_direction,
			action_sequence,
			request_id,
			true,
			_get_player_primary_cooldown_ratio(hoe_player),
			hoe_player.skill1_charge,
		]
	)
	return true


func apply_hoe_action_confirmation(
	sender_id: int,
	peer_id: int,
	action_kind_text: String,
	direction: Vector2,
	action_sequence: int,
	request_id: int,
	accepted: bool,
	cooldown_ratio: float,
	skill_charge: float
) -> void:
	if (
		not has_player_action_dependencies()
		or sender_id != _action_net_manager.get_host_peer_id()
		or peer_id <= 0
		or action_sequence < 0
	):
		return
	var action_kind := StringName(action_kind_text)
	if action_kind != HOE_ACTION_PRIMARY and action_kind != HOE_ACTION_WHIRLWIND:
		return
	var hoe_player := _get_hoe_player(peer_id)
	if hoe_player == null:
		return
	var safe_direction := _sanitize_hoe_action_direction(hoe_player, direction)
	if peer_id == _get_action_local_peer_id() and request_id > 0:
		hoe_player.reconcile_predicted_hoe_action(
			request_id,
			accepted,
			action_kind,
			cooldown_ratio,
			skill_charge
		)
		return
	if accepted:
		hoe_player.play_remote_hoe_action(
			action_kind,
			safe_direction,
			action_sequence
		)


func consume_remote_player_action_admission(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or bool(_is_embedded_participant_suspended_callable.call(peer_id))
		or _runtime.get_player_for_peer(peer_id) == null
	):
		return false
	return _consume_player_action_rate_token(peer_id, now_seconds)


func commit_authoritative_player_teleport(
	peer_id: int,
	target_position: Vector2
) -> bool:
	if not has_player_action_dependencies() or peer_id <= 0 or not _is_finite_vector2(target_position):
		return false
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if not apply_authoritative_teleport_to_player(player_node, target_position):
		return false
	if peer_id != _runtime.multiplayer_local_peer_id:
		var now := _get_action_net_time()
		remember_accepted_player_pose(peer_id, target_position, now)
		remember_latest_client_state(
			true,
			peer_id,
			target_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)
	return true


func handle_authoritative_player_teleport_request(
	peer_id: int,
	target_position: Vector2
) -> bool:
	if (
		not is_inside_tree()
		or not has_player_action_dependencies()
		or not _action_net_manager.is_host()
	):
		return false
	if not commit_authoritative_player_teleport(peer_id, target_position):
		return false
	authoritative_teleport_broadcast_requested.emit(
		peer_id,
		target_position,
		_host_snapshot_sequence
	)
	return true


func remember_accepted_player_pose(
	peer_id: int,
	player_position: Vector2,
	net_time: float
) -> void:
	if peer_id <= 0:
		return
	_accepted_player_state_positions[peer_id] = player_position
	_accepted_player_state_times[peer_id] = net_time


func get_accepted_player_position(peer_id: int) -> Variant:
	return _accepted_player_state_positions.get(peer_id)


func get_player_revive_anchor_position(
	peer_id: int,
	player_node: Player,
	host_peer_id: int
) -> Vector2:
	if peer_id != host_peer_id and _accepted_player_state_positions.has(peer_id):
		return _accepted_player_state_positions[peer_id]
	return player_node.global_position


func _broadcast_player_dash_confirmed(
	peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	if (
		not has_player_action_dependencies()
		or not _action_net_manager.is_host()
		or peer_id <= 0
		or dash_request_sequence <= 0
	):
		return
	player_action_rpc_broadcast_requested.emit(
		&"net_player_dash_confirmed",
		[peer_id, direction.normalized(), dash_request_sequence]
	)


func _consume_player_action_rate_token(
	peer_id: int,
	now_seconds: float
) -> bool:
	var now := _get_action_net_time() if now_seconds < 0.0 else now_seconds
	var bucket: Dictionary
	if _player_action_ingress_rate_buckets.has(peer_id):
		bucket = _player_action_ingress_rate_buckets[peer_id]
	else:
		bucket = {
			"tokens": PLAYER_ACTION_INGRESS_RATE_BURST,
			"last_time": now,
		}
		_player_action_ingress_rate_buckets[peer_id] = bucket
	var tokens := float(
		bucket.get("tokens", PLAYER_ACTION_INGRESS_RATE_BURST)
	)
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(
		PLAYER_ACTION_INGRESS_RATE_BURST,
		tokens
		+ maxf(now - last_time, 0.0) * PLAYER_ACTION_INGRESS_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _get_hoe_player(peer_id: int) -> PlayerHoeCat:
	if not is_bound() or peer_id <= 0:
		return null
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return null
	return player_node as PlayerHoeCat


func _sanitize_hoe_action_direction(
	player_node: PlayerHoeCat,
	direction: Vector2
) -> Vector2:
	if _is_finite_vector2(direction) and direction.length_squared() > 0.0001:
		return direction.normalized()
	if player_node == null:
		return Vector2.RIGHT
	match player_node.get_multiplayer_facing_id():
		1:
			return Vector2.LEFT
		2:
			return Vector2.UP
		3:
			return Vector2.DOWN
		_:
			return Vector2.RIGHT


func _get_player_primary_cooldown_ratio(player_node: Player) -> float:
	if player_node == null or not is_instance_valid(player_node):
		return 0.0
	return clampf(player_node.get_primary_cooldown_ratio(), 0.0, 1.0)


func _get_action_local_peer_id() -> int:
	if _action_net_manager != null:
		var local_peer_id := _action_net_manager.get_local_peer_id()
		if local_peer_id > 0:
			return local_peer_id
	return int(_runtime.multiplayer_local_peer_id) if is_bound() else 0


func _get_action_net_time() -> float:
	if not _get_action_net_time_callable.is_valid():
		return 0.0
	return float(_get_action_net_time_callable.call())


func _clear_pending_dash_input() -> void:
	_pending_dash_input_packets = 0
	_pending_dash_request_sequence = 0
	_pending_dash_direction = Vector2.ZERO
	_pending_dash_start_move_input = Vector2.ZERO


func bind_life_dependencies(
	net_manager_instance: NetManagerStore,
	mode_adapter_instance: MultiplayerModeAdapter,
	projectile_coordinator_instance: MpProjectileCoordinator,
	get_net_time_callable: Callable,
	cancel_tango_for_revive_schedule_callable: Callable,
	cancel_actions_for_revive_callable: Callable,
	clear_tiyi_lifecycle_state_callable: Callable,
	get_revive_anchor_position_callable: Callable,
	commit_revive_position_callable: Callable
) -> void:
	assert(net_manager_instance != null, "MpPlayerCoordinator 缺少 NetManager。")
	assert(mode_adapter_instance != null, "MpPlayerCoordinator 缺少模式适配器。")
	assert(
		projectile_coordinator_instance != null,
		"MpPlayerCoordinator 缺少弹体协调器。"
	)
	assert(get_net_time_callable.is_valid(), "MpPlayerCoordinator 缺少网络时钟。")
	assert(
		cancel_tango_for_revive_schedule_callable.is_valid(),
		"MpPlayerCoordinator 缺少死亡阶段主动技能清理入口。"
	)
	assert(
		cancel_actions_for_revive_callable.is_valid(),
		"MpPlayerCoordinator 缺少复活阶段主动技能清理入口。"
	)
	assert(
		clear_tiyi_lifecycle_state_callable.is_valid(),
		"MpPlayerCoordinator 缺少客户端提伊生命状态清理入口。"
	)
	assert(
		get_revive_anchor_position_callable.is_valid(),
		"MpPlayerCoordinator 缺少复活锚点读取入口。"
	)
	assert(
		commit_revive_position_callable.is_valid(),
		"MpPlayerCoordinator 缺少复活位置提交入口。"
	)
	_net_manager = net_manager_instance
	_mode_adapter = mode_adapter_instance
	_projectile_coordinator = projectile_coordinator_instance
	_get_net_time_callable = get_net_time_callable
	_cancel_tango_for_revive_schedule_callable = (
		cancel_tango_for_revive_schedule_callable
	)
	_cancel_actions_for_revive_callable = cancel_actions_for_revive_callable
	_clear_tiyi_lifecycle_state_callable = clear_tiyi_lifecycle_state_callable
	_get_revive_anchor_position_callable = get_revive_anchor_position_callable
	_commit_revive_position_callable = commit_revive_position_callable


func randomize_revive_generator() -> void:
	_revive_random_generator.randomize()


func has_life_dependencies() -> bool:
	return (
		is_bound()
		and _net_manager != null
		and is_instance_valid(_net_manager)
		and _mode_adapter != null
		and is_instance_valid(_mode_adapter)
		and _projectile_coordinator != null
		and is_instance_valid(_projectile_coordinator)
		and _get_net_time_callable.is_valid()
	)


func request_multiplayer_player_damage(
	source_id: int,
	target_peer_id: int,
	damage: int,
	source_type: StringName,
	damage_type_or_source_direction: Variant = EnemyConfig.DamageType.PHYSICAL,
	source_direction_or_is_ranged: Variant = Vector2.ZERO,
	is_ranged: bool = false,
	contact_preconsumed: bool = false
) -> bool:
	if (
		not has_life_dependencies()
		or source_id <= 0
		or target_peer_id <= 0
		or damage <= 0
	):
		return false
	var resolved_damage_type: EnemyConfig.DamageType = EnemyConfig.DamageType.PHYSICAL
	var source_direction := Vector2.ZERO
	var resolved_is_ranged := is_ranged
	if damage_type_or_source_direction is Vector2:
		source_direction = damage_type_or_source_direction as Vector2
		if source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	elif damage_type_or_source_direction is int:
		resolved_damage_type = int(
			damage_type_or_source_direction
		) as EnemyConfig.DamageType
		if source_direction_or_is_ranged is Vector2:
			source_direction = source_direction_or_is_ranged as Vector2
		elif source_direction_or_is_ranged is bool:
			resolved_is_ranged = bool(source_direction_or_is_ranged)
	var is_frost_ice_spike := source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	var is_fire_slime_touch := source_type == FIRE_SLIME_TOUCH_TYPE
	var is_frost_slime_touch := source_type == FROST_SLIME_TOUCH_TYPE
	if is_frost_ice_spike:
		var authoritative_damage := (
			_projectile_coordinator.get_frost_ice_spike_record_damage(
				source_id,
				source_type
			)
		)
		if authoritative_damage <= 0:
			return false
		damage = authoritative_damage
		resolved_damage_type = EnemyConfig.DamageType.MAGIC
	elif is_fire_slime_touch or is_frost_slime_touch:
		resolved_damage_type = EnemyConfig.DamageType.MAGIC
	var impact_direction := Vector2.ZERO
	if source_direction.is_finite() and source_direction.length_squared() > 0.001:
		impact_direction = -source_direction.normalized()
	var hit_key := _get_multiplayer_player_hit_key(
		source_id,
		target_peer_id,
		source_type
	)
	var now := _get_net_time()
	var player_node := _runtime.get_player_for_peer(target_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	if _is_recent_player_hit_cached(hit_key, now):
		return true
	var fire_source_bit := _get_fire_sorcerer_fireball_source_bit(source_type)
	var contact_was_consumed := false
	if fire_source_bit != 0:
		contact_was_consumed = (
			_projectile_coordinator.is_fire_sorcerer_fireball_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_fire_sorcerer_fireball_contact(
				source_id,
				source_type
			)
		)
		if not contact_was_consumed:
			return true
	elif is_frost_ice_spike:
		contact_was_consumed = (
			_projectile_coordinator.is_frost_ice_spike_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_frost_sorcerer_ice_spike_contact(
				source_id,
				source_type
			)
		)
		if not contact_was_consumed:
			return true
	if _net_manager.is_client():
		if target_peer_id != _net_manager.get_local_peer_id():
			return true
		if player_node.is_dead:
			return true
		_remember_player_hit(hit_key, now)
		return true
	if _net_manager.is_host():
		if player_node.is_dead:
			return true
		apply_player_hit_report(
			source_id,
			target_peer_id,
			damage,
			source_type,
			impact_direction,
			resolved_damage_type,
			CombatTypes.DamageFlag.RANGED if resolved_is_ranged else 0,
			contact_was_consumed
		)
		return true
	return false


func request_multiplayer_player_burn_tick(
	player_peer_id: int,
	source_family: StringName
) -> bool:
	var trusted_family := CombatAttackRegistry.get_burn_family(source_family)
	var trusted_burn_level := CombatAttackRegistry.get_burn_tick_damage(
		trusted_family
	)
	if trusted_family == &"" or trusted_burn_level <= 0:
		return false
	return request_multiplayer_player_damage_over_time_tick(
		player_peer_id,
		&"burn",
		trusted_family,
		trusted_burn_level
	)


func request_multiplayer_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int
) -> bool:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or player_peer_id <= 0
		or source_family == &""
		or tick_damage <= 0
	):
		return false
	var damage_type := EnemyConfig.DamageType.PHYSICAL
	match status_id:
		&"burn":
			var trusted_family := CombatAttackRegistry.get_burn_family(source_family)
			var trusted_burn_level := CombatAttackRegistry.get_burn_tick_damage(
				trusted_family
			)
			if (
				trusted_family == &""
				or trusted_burn_level <= 0
				or tick_damage != trusted_burn_level
			):
				return false
			damage_type = EnemyConfig.DamageType.MAGIC
		&"bleed":
			damage_type = EnemyConfig.DamageType.PHYSICAL
		_:
			return false
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or player_node.is_dead
	):
		return false
	var request := DamageRequest.new(tick_damage, int(damage_type))
	request.with_source(null, 0, source_family)
	request.flags = (
		CombatTypes.DamageFlag.PERIODIC
		| CombatTypes.DamageFlag.BYPASS_INVULNERABILITY
		| CombatTypes.DamageFlag.BYPASS_DODGE
		| CombatTypes.DamageFlag.NO_HIT_INVINCIBILITY
	)
	var result := player_node.apply_combat_damage(request)
	if not result.accepted:
		return false
	var confirmed_damage := result.applied_damage
	var confirmed_dead := result.lethal
	_show_confirmed_player_damage_number(
		player_node,
		confirmed_damage,
		Vector2.ZERO,
		damage_type
	)
	if confirmed_dead and player_node is PlayerTiyi:
		_clear_tiyi_projectiles(player_peer_id)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		schedule_player_revive(player_peer_id)
	var event_arguments := [
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		Vector2.ZERO,
		int(damage_type),
		false,
	]
	life_rpc_broadcast_requested.emit(
		&"net_player_damage_applied",
		event_arguments
	)
	apply_player_damage_confirmation(
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		Vector2.ZERO,
		int(damage_type),
		false
	)
	return true


func apply_luoxi_direct_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or target_player == null
		or not is_instance_valid(target_player)
		or target_player.peer_id <= 0
		or target_player.is_dead
		or amount <= 0
	):
		return 0
	var applied_loss := target_player.apply_direct_health_loss(
		amount,
		minimum_health
	)
	if applied_loss <= 0:
		return 0
	_show_confirmed_player_damage_number(
		target_player,
		applied_loss,
		Vector2.ZERO,
		EnemyConfig.DamageType.PHYSICAL
	)
	var confirmed_dead := target_player.is_dead
	if confirmed_dead and target_player is PlayerTiyi:
		_clear_tiyi_projectiles(target_player.peer_id)
	var health_revision := _next_player_health_revision(target_player.peer_id)
	if confirmed_dead:
		schedule_player_revive(target_player.peer_id)
	var event_arguments := [
		target_player.peer_id,
		target_player.current_health,
		confirmed_dead,
		health_revision,
		applied_loss,
		Vector2.ZERO,
		int(EnemyConfig.DamageType.PHYSICAL),
		false,
		false,
		CombatTypes.DamageRejectionReason.NONE,
	]
	life_rpc_broadcast_requested.emit(
		&"net_player_damage_applied",
		event_arguments
	)
	apply_player_damage_confirmation(
		target_player.peer_id,
		target_player.current_health,
		confirmed_dead,
		health_revision,
		applied_loss,
		Vector2.ZERO,
		int(EnemyConfig.DamageType.PHYSICAL),
		false,
		false,
		CombatTypes.DamageRejectionReason.NONE
	)
	return applied_loss


func reject_untrusted_player_hit_report(
	_sender_id: int,
	_source_id: int,
	_player_peer_id: int,
	_attack_wire_id: int,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	pass


func apply_player_hit_report(
	source_id: int,
	player_peer_id: int,
	damage: int,
	source_type: StringName,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	damage_flags: int,
	contact_preconsumed: bool = false
) -> DamageResult:
	var request := _build_player_damage_request(
		damage,
		int(damage_type),
		source_id,
		source_type,
		impact_direction,
		CombatTypes.has_flag(damage_flags, CombatTypes.DamageFlag.RANGED)
	)
	if (
		_net_manager == null
		or not is_instance_valid(_net_manager)
		or not _net_manager.is_host()
	):
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.NOT_AUTHORITY
		)
	if not has_life_dependencies() or source_id <= 0 or player_peer_id <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_REQUEST
		)
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.TARGET_UNAVAILABLE
		)
	if damage <= 0:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.INVALID_AMOUNT,
			player_node.current_health
		)
	var is_fire_sorcerer_fireball := (
		_get_fire_sorcerer_fireball_source_bit(source_type) != 0
	)
	var is_frost_ice_spike := source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	var is_fire_slime_touch := source_type == FIRE_SLIME_TOUCH_TYPE
	var is_frost_slime_touch := source_type == FROST_SLIME_TOUCH_TYPE
	if is_frost_ice_spike:
		var authoritative_damage := (
			_projectile_coordinator.get_frost_ice_spike_record_damage(
				source_id,
				source_type
			)
		)
		if authoritative_damage <= 0:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.UNTRUSTED_SOURCE,
				player_node.current_health
			)
		damage = authoritative_damage
		request.amount = damage
	var hit_key := _get_multiplayer_player_hit_key(
		source_id,
		player_peer_id,
		source_type
	)
	var now := _get_net_time()
	if _is_recent_player_hit_cached(hit_key, now):
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.DUPLICATE_EVENT,
			player_node.current_health
		)
	if player_node.is_dead:
		return DamageResult.rejected(
			request,
			CombatTypes.DamageRejectionReason.TARGET_DEAD,
			player_node.current_health
		)
	if is_fire_sorcerer_fireball:
		var contact_consumed := (
			_projectile_coordinator.is_fire_sorcerer_fireball_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_fire_sorcerer_fireball_contact(
				source_id,
				source_type
			)
		)
		if not contact_consumed:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.DUPLICATE_EVENT,
				player_node.current_health
			)
	elif is_frost_ice_spike:
		var contact_consumed := (
			_projectile_coordinator.is_frost_ice_spike_contact_consumed(
				source_id,
				source_type
			)
			if contact_preconsumed
			else _projectile_coordinator.try_consume_frost_sorcerer_ice_spike_contact(
				source_id,
				source_type
			)
		)
		if not contact_consumed:
			return DamageResult.rejected(
				request,
				CombatTypes.DamageRejectionReason.DUPLICATE_EVENT,
				player_node.current_health
			)
	_remember_player_hit(hit_key, now)
	var result := player_node.apply_combat_damage(request)
	var confirmed_dead := result.lethal
	var confirmed_damage := result.applied_damage
	var confirmed_impact_direction := Vector2.ZERO
	if impact_direction.is_finite() and impact_direction.length_squared() > 0.001:
		confirmed_impact_direction = impact_direction.normalized()
	var confirmed_damage_type := (
		EnemyConfig.DamageType.MAGIC
		if (
			is_frost_ice_spike
			or is_fire_slime_touch
			or is_frost_slime_touch
			or damage_type == EnemyConfig.DamageType.MAGIC
		)
		else EnemyConfig.DamageType.PHYSICAL
	)
	var confirmed_cold_applied := false
	var confirmed_status_mask := 0
	if result.accepted and confirmed_damage > 0 and not confirmed_dead:
		var burn_family := CombatAttackRegistry.get_burn_family(source_type)
		var burn_level := CombatAttackRegistry.get_burn_tick_damage(burn_family)
		if burn_family != &"" and burn_level > 0:
			var burn_applied := player_node.apply_burn_status(
				burn_family,
				CombatAttackRegistry.get_burn_duration(burn_family),
				burn_level
			)
			if (
				burn_applied
				and burn_family
					== CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY
			):
				confirmed_status_mask |= CONFIRMED_STATUS_MAIN_BATTLE_BURN
		if CombatAttackRegistry.applies_cold(source_type):
			confirmed_cold_applied = player_node.apply_cold_status()
		var slow_family := (
			CombatAttackRegistry.get_timed_move_slow_family(source_type)
		)
		if slow_family != &"":
			var slow_applied := player_node.apply_timed_move_slow(
				slow_family,
				CombatAttackRegistry.get_timed_move_slow_duration(source_type),
				CombatAttackRegistry.get_timed_move_slow_multiplier(source_type)
			)
			if (
				slow_applied
				and slow_family
					== CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY
			):
				confirmed_status_mask |= CONFIRMED_STATUS_MAIN_BATTLE_SLOW
	_show_confirmed_player_damage_number(
		player_node,
		confirmed_damage,
		confirmed_impact_direction,
		confirmed_damage_type
	)
	if confirmed_dead and player_node is PlayerTiyi:
		_clear_tiyi_projectiles(player_peer_id)
	var health_revision := _next_player_health_revision(player_peer_id)
	if confirmed_dead:
		schedule_player_revive(player_peer_id)
	if (
		not _NetConstants.is_valid_network_combat_value(result.health_after)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
	):
		push_error("MpPlayerCoordinator: 玩家伤害结果超出网络 signed int32 契约，已拒绝发送。")
		return result
	life_rpc_broadcast_requested.emit(
		&"net_player_damage_applied",
		[
			player_peer_id,
			result.health_after,
			confirmed_dead,
			health_revision,
			confirmed_damage,
			confirmed_impact_direction,
			int(confirmed_damage_type),
			result.accepted and not confirmed_dead,
			confirmed_cold_applied,
			result.rejection_reason,
			confirmed_status_mask,
		]
	)
	apply_player_damage_confirmation(
		player_peer_id,
		result.health_after,
		confirmed_dead,
		health_revision,
		confirmed_damage,
		confirmed_impact_direction,
		int(confirmed_damage_type),
		result.accepted and not confirmed_dead,
		confirmed_cold_applied,
		result.rejection_reason,
		confirmed_status_mask
	)
	return result


func apply_player_damage_confirmation(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	grant_hit_invincibility: bool = true,
	apply_confirmed_cold: bool = false,
	combat_outcome: int = 0,
	confirmed_status_mask: int = 0
) -> void:
	if (
		player_peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_damage)
		or not _NetConstants.is_valid_network_combat_value(confirmed_status_mask)
		or not is_bound()
	):
		return
	var player_node := _runtime.get_player_for_peer(player_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(player_peer_id, 0)):
		return
	_player_health_revisions[player_peer_id] = health_revision
	var applied_life_state := _try_apply_player_health_event(
		player_node,
		player_peer_id,
		current_health,
		is_dead,
		health_revision
	)
	if (
		combat_outcome == CombatTypes.DamageRejectionReason.DODGED
		and confirmed_damage <= 0
		and not is_dead
		and _net_manager != null
		and _net_manager.is_client()
	):
		player_node.play_confirmed_dodge_feedback()
	if apply_confirmed_cold and confirmed_damage > 0 and not is_dead:
		player_node.apply_cold_status()
	# Health snapshots and reliable damage confirmations use independent revision
	# watermarks. A newer snapshot may already own life state while this first
	# reliable confirmation still owns its exactly-once presentation statuses.
	if (
		confirmed_damage > 0
		and not is_dead
		and _net_manager != null
		and _net_manager.is_client()
	):
		var trusted_status_mask := (
			confirmed_status_mask & CONFIRMED_STATUS_MASK_KNOWN
		)
		if (
			trusted_status_mask & CONFIRMED_STATUS_MAIN_BATTLE_BURN
		) != 0:
			player_node.apply_burn_status(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_FAMILY,
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_DURATION_SECONDS,
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_BURN_TICK_DAMAGE
			)
		if (
			trusted_status_mask & CONFIRMED_STATUS_MAIN_BATTLE_SLOW
		) != 0:
			player_node.apply_timed_move_slow(
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_FAMILY,
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_DURATION_SECONDS,
				CombatAttackRegistry.COMBAT_ROBOT_MAIN_BATTLE_SLOW_MULTIPLIER
			)
	_show_confirmed_player_damage_number(
		player_node,
		clampi(confirmed_damage, 0, player_node.max_health),
		impact_direction.normalized()
		if impact_direction.is_finite() and impact_direction.length_squared() > 0.001
		else Vector2.ZERO,
		EnemyConfig.DamageType.MAGIC
		if damage_type == EnemyConfig.DamageType.MAGIC
		else EnemyConfig.DamageType.PHYSICAL
	)
	if is_dead and applied_life_state and player_node is PlayerTiyi:
		_clear_tiyi_lifecycle_state_callable.call(player_peer_id)
		_clear_tiyi_projectiles(player_peer_id)
	if (
		grant_hit_invincibility
		and applied_life_state
		and int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
		and player_peer_id == _get_client_view_local_peer_id()
		and not player_node.is_dead
		and player_node.current_health < player_node.max_health
	):
		player_node.start_multiplayer_invincibility(
			player_node.invincibility_duration
		)


func _show_confirmed_player_damage_number(
	player_node: Player,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> void:
	if (
		not is_bound()
		or player_node == null
		or not is_instance_valid(player_node)
		or confirmed_damage <= 0
	):
		return
	_runtime.show_damage_number(
		confirmed_damage,
		player_node.global_position,
		impact_direction,
		damage_type,
		DamageNumberPool.DisplayPriority.IMPORTANT
	)


func apply_multiplayer_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or target_player == null
		or not is_instance_valid(target_player)
		or heal_amount <= 0
		or target_player.peer_id <= 0
	):
		return false
	if not target_player._try_heal(heal_amount, false):
		return false
	report_multiplayer_player_healing(
		target_player,
		target_player.last_healing_received
	)
	return true


func report_multiplayer_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or target_player == null
		or not is_instance_valid(target_player)
		or confirmed_healing <= 0
		or target_player.peer_id <= 0
		or target_player.is_dead
	):
		return
	var health_revision := _next_player_health_revision(target_player.peer_id)
	if (
		not _NetConstants.is_valid_network_combat_value(target_player.current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_healing)
	):
		push_error("MpPlayerCoordinator: 玩家治疗结果超出网络 signed int32 契约，已拒绝发送。")
		return
	target_player.queue_healing_number(confirmed_healing)
	life_rpc_broadcast_requested.emit(
		&"net_player_healed",
		[
			target_player.peer_id,
			target_player.current_health,
			health_revision,
			confirmed_healing,
		]
	)


func apply_player_heal_confirmation(
	peer_id: int,
	current_health: int,
	health_revision: int,
	confirmed_healing: int
) -> void:
	if (
		peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not _NetConstants.is_valid_network_combat_value(confirmed_healing)
		or not is_bound()
	):
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	if player_node.is_dead:
		return
	_player_health_revisions[peer_id] = health_revision
	_try_apply_player_health_event(
		player_node,
		peer_id,
		current_health,
		false,
		health_revision
	)
	player_node.queue_healing_number(confirmed_healing)


func apply_authoritative_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return apply_multiplayer_player_heal(target_player, heal_amount)


func schedule_player_revive(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if _cancel_tango_for_revive_schedule_callable.is_valid():
		_cancel_tango_for_revive_schedule_callable.call(peer_id)
	if (
		not has_life_dependencies()
		or not _mode_adapter.allows_player_respawn(peer_id)
		or _dead_player_revive_times.has(peer_id)
		or _mode_adapter.is_terminal_combat_state()
	):
		return
	erase_latest_client_state(peer_id)
	var revive_delay := _mode_adapter.consume_next_player_respawn_delay(peer_id)
	revive_delay = maxf(revive_delay, 0.0)
	_dead_player_revive_times[peer_id] = _get_net_time() + revive_delay
	_dead_player_revive_last_seconds[peer_id] = -1
	var seconds_left := int(ceil(revive_delay))
	life_rpc_broadcast_requested.emit(
		&"net_player_revive_countdown",
		[peer_id, seconds_left]
	)
	apply_player_revive_countdown(peer_id, seconds_left)


func update_player_revives() -> void:
	if (
		not has_life_dependencies()
		or not _net_manager.is_host()
		or _mode_adapter.is_terminal_combat_state()
	):
		return
	var now := _get_net_time()
	var due_peers: Array[int] = []
	var disallowed_peers: Array[int] = []
	for peer_id_variant in _dead_player_revive_times:
		var peer_id := int(peer_id_variant)
		if not _mode_adapter.allows_player_respawn(peer_id):
			disallowed_peers.append(peer_id)
			continue
		var revive_at := float(_dead_player_revive_times[peer_id])
		var seconds_left := maxi(ceili(revive_at - now), 0)
		if seconds_left != int(
			_dead_player_revive_last_seconds.get(peer_id, -1)
		):
			_dead_player_revive_last_seconds[peer_id] = seconds_left
			life_rpc_broadcast_requested.emit(
				&"net_player_revive_countdown",
				[peer_id, seconds_left]
			)
			apply_player_revive_countdown(peer_id, seconds_left)
		if now >= revive_at:
			due_peers.append(peer_id)
	for peer_id in disallowed_peers:
		_dead_player_revive_times.erase(peer_id)
		_dead_player_revive_last_seconds.erase(peer_id)
		_mode_adapter.clear_player_respawn_countdown(peer_id)
	if due_peers.is_empty():
		return
	var revive_positions := _collect_living_player_revive_positions()
	for peer_id in due_peers:
		var revive_position: Variant = _resolve_multiplayer_revive_position(
			peer_id,
			revive_positions
		)
		if revive_position is Vector2:
			_revive_player_peer(peer_id, revive_position as Vector2)


func revive_all_players() -> void:
	if not has_life_dependencies() or not _net_manager.is_host():
		return
	clear_pending_revives()
	var revive_positions := _collect_living_player_revive_positions()
	for peer_id_variant in _runtime.peer_players:
		var peer_id := int(peer_id_variant)
		if not _mode_adapter.allows_player_respawn(peer_id):
			continue
		var player_node := _runtime.peer_players[peer_id_variant] as Player
		if (
			player_node == null
			or not is_instance_valid(player_node)
			or not player_node.is_dead
		):
			continue
		var revive_position: Variant = _resolve_multiplayer_revive_position(
			peer_id,
			revive_positions
		)
		if revive_position is Vector2:
			_revive_player_peer(peer_id, revive_position as Vector2)


## 探索边界必须同时处理存活与死亡玩家，并为每位在线玩家推进一次健康
## revision。绝对最大生命一并发送，确保最大生命惩罚/永久属性在重连及
## 独立可靠信道乱序下仍由 Host 收敛。
func restore_all_players_to_full_health() -> void:
	if not has_life_dependencies() or not _net_manager.is_host():
		return
	clear_pending_revives()
	for peer_id_variant in _runtime.peer_players:
		restore_player_to_full_health(int(peer_id_variant))


## 为跨过探索满血边界后才重连的单个玩家补发同一套绝对状态。调用者须先
## 从 RunState 刷新该玩家的永久属性；这里只负责生命权威与网络修订。
func restore_player_to_full_health(peer_id: int) -> bool:
	if not has_life_dependencies() or not _net_manager.is_host() or peer_id <= 0:
		return false
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	var maximum_health := maxi(player_node.max_health, 1)
	if not _NetConstants.is_valid_network_combat_value(maximum_health):
		push_error(
			"MpPlayerCoordinator: 全员生命恢复超出网络 signed int32 契约，已拒绝发送。"
		)
		return false
	_cancel_actions_for_revive_callable.call(peer_id)
	_clear_tiyi_lifecycle_state_callable.call(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	var restore_position := player_node.global_position
	var health_revision := _next_player_health_revision(peer_id)
	if not _NetConstants.is_valid_network_combat_value(health_revision):
		push_error(
			"MpPlayerCoordinator: 满血恢复健康修订超出网络 signed int32 契约，已拒绝发送。"
		)
		return false
	player_node.apply_multiplayer_full_health_restore(
		restore_position,
		maximum_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS
	)
	life_rpc_broadcast_requested.emit(
		&"net_player_full_health_restored",
		[
			peer_id,
			restore_position,
			maximum_health,
			PLAYER_REVIVE_INVINCIBILITY_SECONDS,
			health_revision,
		]
	)
	return true


func apply_player_full_health_restored(
	peer_id: int,
	restore_position: Vector2,
	maximum_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	if (
		peer_id <= 0
		or maximum_health <= 0
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not is_finite(invincible_seconds)
		or invincible_seconds < 0.0
		or not is_bound()
		or health_revision <= int(_player_health_revisions.get(peer_id, 0))
	):
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_player_health_revisions[peer_id] = health_revision
	mark_health_revision_applied(peer_id, health_revision)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_clear_tiyi_lifecycle_state_callable.call(peer_id)
	player_node.apply_multiplayer_full_health_restore(
		restore_position,
		maximum_health,
		invincible_seconds
	)
	_mode_adapter.clear_player_respawn_countdown(peer_id)
	if (
		int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
		and peer_id != _get_client_view_local_peer_id()
	):
		reset_visual_interpolator_to_state(
			peer_id,
			restore_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			_get_net_time()
		)


func apply_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	if not is_bound() or peer_id <= 0:
		return
	if _mode_adapter == null or not _mode_adapter.allows_player_respawn(peer_id):
		if _mode_adapter != null:
			_mode_adapter.clear_player_respawn_countdown(peer_id)
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if _mode_adapter is TowerDefenseMultiplayerModeAdapter:
		_mode_adapter.update_player_respawn_countdown(peer_id, seconds_left)
	else:
		player_node.set_multiplayer_revive_countdown(seconds_left)


func apply_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	if (
		peer_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
		or not is_bound()
		or _mode_adapter == null
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if health_revision <= int(_player_health_revisions.get(peer_id, 0)):
		return
	_player_health_revisions[peer_id] = health_revision
	mark_health_revision_applied(peer_id, health_revision)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_clear_tiyi_lifecycle_state_callable.call(peer_id)
	player_node.revive_multiplayer(
		revive_position,
		current_health,
		invincible_seconds
	)
	_mode_adapter.clear_player_respawn_countdown(peer_id)
	if (
		int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
		and peer_id != _get_client_view_local_peer_id()
	):
		reset_visual_interpolator_to_state(
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			_get_net_time()
		)


func clear_pending_revives() -> void:
	_dead_player_revive_times.clear()
	_dead_player_revive_last_seconds.clear()


func get_health_revisions_for_snapshot() -> Dictionary:
	return _player_health_revisions


func get_health_revision(peer_id: int) -> int:
	return int(_player_health_revisions.get(peer_id, 0))


func has_pending_revive(peer_id: int) -> bool:
	return _dead_player_revive_times.has(peer_id)


func capture_reconnect_life_state(peer_id: int) -> Dictionary:
	return {
		"revive_at": float(_dead_player_revive_times.get(peer_id, -1.0)),
		"revive_last_seconds": int(
			_dead_player_revive_last_seconds.get(peer_id, -1)
		),
		"health_revision": get_health_revision(peer_id),
		"applied_health_revision": get_applied_health_revision(peer_id),
	}


func restore_reconnect_life_state(
	peer_id: int,
	reconnect_state: Dictionary,
	is_host: bool
) -> void:
	if peer_id <= 0:
		return
	_player_health_revisions[peer_id] = int(
		reconnect_state.get("health_revision", 0)
	)
	set_applied_health_revision(
		peer_id,
		int(reconnect_state.get("applied_health_revision", 0))
	)
	var revive_at := float(reconnect_state.get("revive_at", -1.0))
	if (
		is_host
		and revive_at >= 0.0
		and _mode_adapter != null
		and _mode_adapter.allows_player_respawn(peer_id)
	):
		_dead_player_revive_times[peer_id] = revive_at
		_dead_player_revive_last_seconds[peer_id] = int(
			reconnect_state.get("revive_last_seconds", -1)
		)


func prune_recent_player_hit_events(now: float) -> void:
	var expired_keys: Array = []
	for key in _processed_player_hit_ids:
		if float(_processed_player_hit_ids[key]) <= now:
			expired_keys.append(key)
	for key in expired_keys:
		_processed_player_hit_ids.erase(key)


func _revive_player_peer(peer_id: int, revive_position: Vector2) -> void:
	if (
		not has_life_dependencies()
		or peer_id <= 0
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		_dead_player_revive_times.erase(peer_id)
		_dead_player_revive_last_seconds.erase(peer_id)
		if _mode_adapter != null:
			_mode_adapter.clear_player_respawn_countdown(peer_id)
		return
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	_cancel_actions_for_revive_callable.call(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	var now := _get_net_time()
	_commit_revive_position_callable.call(peer_id, revive_position, now)
	var health_revision := _next_player_health_revision(peer_id)
	player_node.revive_multiplayer(
		revive_position,
		player_node.max_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS
	)
	if (
		not _NetConstants.is_valid_network_combat_value(player_node.current_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpPlayerCoordinator: 玩家复活生命值超出网络 signed int32 契约，已拒绝发送。")
		return
	var host_peer_id := _net_manager.get_host_peer_id()
	if peer_id != host_peer_id:
		remember_latest_client_state(
			true,
			peer_id,
			revive_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state()
		)
		player_state_correction_requested.emit(
			peer_id,
			revive_position,
			Vector2.ZERO
		)
	life_rpc_broadcast_requested.emit(
		&"net_player_revived",
		[
			peer_id,
			revive_position,
			player_node.current_health,
			PLAYER_REVIVE_INVINCIBILITY_SECONDS,
			health_revision,
		]
	)
	apply_player_revived(
		peer_id,
		revive_position,
		player_node.current_health,
		PLAYER_REVIVE_INVINCIBILITY_SECONDS,
		health_revision
	)


func _collect_living_player_revive_positions() -> Array[Vector2]:
	var positions: Array[Vector2] = []
	if not is_bound():
		return positions
	for peer_id_variant in _runtime.peer_players:
		var peer_id := int(peer_id_variant)
		var player_node := _runtime.peer_players[peer_id_variant] as Player
		if (
			player_node == null
			or not is_instance_valid(player_node)
			or player_node.is_dead
		):
			continue
		var anchor: Variant = _get_revive_anchor_position_callable.call(
			peer_id,
			player_node
		)
		positions.append(
			anchor as Vector2 if anchor is Vector2 else player_node.global_position
		)
	return positions


func _pick_multiplayer_revive_position(
	revive_positions: Array[Vector2]
) -> Vector2:
	if revive_positions.is_empty():
		return Vector2.ZERO
	return revive_positions[
		_revive_random_generator.randi_range(0, revive_positions.size() - 1)
	]


func _resolve_multiplayer_revive_position(
	peer_id: int,
	living_player_positions: Array[Vector2]
) -> Variant:
	if (
		not has_life_dependencies()
		or peer_id <= 0
		or not _mode_adapter.allows_player_respawn(peer_id)
	):
		return null
	var fixed_position: Variant = (
		_mode_adapter.get_fixed_multiplayer_respawn_position(peer_id)
	)
	if fixed_position is Vector2:
		return fixed_position
	if living_player_positions.is_empty():
		return null
	return _pick_multiplayer_revive_position(living_player_positions)


func _build_player_damage_request(
	damage: int,
	damage_type: int,
	source_id: int,
	source_type: StringName,
	impact_direction: Vector2,
	is_ranged: bool
) -> DamageRequest:
	var request := DamageRequest.new(damage, damage_type)
	request.with_source(null, source_id, source_type)
	request.with_directions(impact_direction, -impact_direction)
	request.with_flag(CombatTypes.DamageFlag.RANGED, is_ranged)
	return request


func _next_player_health_revision(peer_id: int) -> int:
	var next_revision := int(_player_health_revisions.get(peer_id, 0)) + 1
	_player_health_revisions[peer_id] = next_revision
	mark_health_revision_applied(peer_id, next_revision)
	return next_revision


func _try_apply_player_health_event(
	player_node: Player,
	peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int
) -> bool:
	if (
		player_node == null
		or peer_id <= 0
		or health_revision < get_applied_health_revision(peer_id)
	):
		return false
	player_node.set_multiplayer_health_state(current_health, is_dead)
	mark_health_revision_applied(peer_id, health_revision)
	return true


func _get_multiplayer_player_hit_key(
	source_id: int,
	target_peer_id: int,
	source_type: StringName
) -> String:
	if (
		_get_fire_sorcerer_fireball_source_bit(source_type) != 0
		or source_type == FROST_SORCERER_ICE_SPIKE_TYPE
	):
		return "%d:%s" % [source_id, String(source_type)]
	return "%d:%d:%s" % [source_id, target_peer_id, String(source_type)]


func _get_fire_sorcerer_fireball_source_bit(source_type: StringName) -> int:
	match source_type:
		&"fire_sorcerer_fireball_a", \
		&"fire_sorcerer_elite_fireball_a":
			return 1
		&"fire_sorcerer_fireball_b", \
		&"fire_sorcerer_elite_fireball_b":
			return 2
		&"fire_sorcerer_fireball_c", \
		&"fire_sorcerer_elite_fireball_c":
			return 4
		_:
			return 0


func _is_recent_player_hit_cached(hit_key: String, now: float) -> bool:
	var expires_at_variant: Variant = _processed_player_hit_ids.get(hit_key)
	if expires_at_variant == null:
		return false
	var expires_at := float(expires_at_variant)
	if expires_at > now:
		return true
	_processed_player_hit_ids.erase(hit_key)
	return false


func _remember_player_hit(hit_key: String, now: float) -> void:
	_processed_player_hit_ids[hit_key] = now + HIT_DEDUP_RETENTION_SECONDS


func _clear_tiyi_projectiles(peer_id: int) -> void:
	_projectile_coordinator.clear_projectiles_for_peer(peer_id)
	_projectile_coordinator.clear_projectile_records_for_peer(peer_id)


func _get_client_view_local_peer_id() -> int:
	if _net_manager != null:
		var local_peer_id := _net_manager.get_local_peer_id()
		if local_peer_id > 0:
			return local_peer_id
	return int(_runtime.multiplayer_local_peer_id) if is_bound() else 0


func _get_realtime_local_peer_id() -> int:
	if _realtime_net_manager != null:
		var local_peer_id := _realtime_net_manager.get_local_peer_id()
		if local_peer_id > 0:
			return local_peer_id
	return int(_runtime.multiplayer_local_peer_id) if is_bound() else 0


func _get_net_time() -> float:
	if not _get_net_time_callable.is_valid():
		return 0.0
	return float(_get_net_time_callable.call())


func _clear_life_dependencies() -> void:
	_net_manager = null
	_mode_adapter = null
	_projectile_coordinator = null
	_get_net_time_callable = Callable()
	_cancel_tango_for_revive_schedule_callable = Callable()
	_cancel_actions_for_revive_callable = Callable()
	_clear_tiyi_lifecycle_state_callable = Callable()
	_get_revive_anchor_position_callable = Callable()
	_commit_revive_position_callable = Callable()


func _clear_player_action_dependencies() -> void:
	_action_net_manager = null
	_get_action_net_time_callable = Callable()
	_is_embedded_participant_suspended_callable = Callable()


func _clear_realtime_dependencies() -> void:
	_realtime_net_manager = null
	_session_coordinator = null


func sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	var ready_lookup: Dictionary[int, bool] = {}
	for peer_id in ready_peer_ids:
		if peer_id > 0:
			ready_lookup[peer_id] = true
	for peer_id_variant in _snapshot_cohort_peers.keys():
		var peer_id := int(peer_id_variant)
		if ready_lookup.has(peer_id):
			continue
		_snapshot_cohort_peers.erase(peer_id)
		_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)


func update_host_realtime_snapshots(
	frame: int,
	ready_peer_ids: Array[int]
) -> void:
	if (
		not has_realtime_dependencies()
		or not _realtime_net_manager.is_host()
		or frame % _NetConstants.PLAYER_SNAPSHOT_INTERVAL_FRAMES != 0
	):
		return
	broadcast_host_player_snapshots(ready_peer_ids)


func broadcast_host_player_snapshots(ready_peer_ids: Array[int]) -> int:
	if (
		not has_realtime_dependencies()
		or not _realtime_net_manager.is_host()
		or ready_peer_ids.is_empty()
	):
		return 0
	var states := _runtime.collect_player_snapshot_states()
	if states.is_empty():
		return 0
	var snapshot_time := _session_coordinator.get_net_time()
	apply_authoritative_tango_charge_snapshot_ratios(states, snapshot_time)
	var batch := build_host_snapshot_batch(
		states,
		ready_peer_ids,
		snapshot_time,
		get_health_revisions_for_snapshot()
	)
	if batch == null or batch.is_empty():
		return 0
	for peer_id in batch.peer_ids:
		player_snapshot_send_requested.emit(
			peer_id,
			batch.host_timestamp,
			batch.data,
			batch.entity_count
		)
	return batch.peer_ids.size()


func receive_authoritative_player_snapshot(
	host_timestamp: float,
	data: PackedByteArray
) -> void:
	if (
		not has_realtime_dependencies()
		or not _realtime_net_manager.is_client()
		or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW
	):
		return
	var snapshot_time := _session_coordinator.map_host_timestamp_to_client_time(
		host_timestamp
	)
	var stale_peer_ids := apply_authoritative_snapshot(
		snapshot_time,
		data,
		_get_realtime_local_peer_id(),
		has_local_tango_prediction()
	)
	for peer_id in stale_peer_ids:
		stale_player_peer_detected.emit(peer_id)


func interpolate_client_players() -> void:
	if (
		not has_realtime_dependencies()
		or not _realtime_net_manager.is_client()
		or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW
	):
		return
	interpolate_remote_players(
		_session_coordinator.get_net_time(),
		_get_realtime_local_peer_id()
	)


func build_host_snapshot_batch(
	states: Array[SnapshotManager.PlayerState],
	ready_peer_ids: Array[int],
	host_timestamp: float,
	health_revisions: Dictionary
) -> HostSnapshotBatch:
	if not is_bound() or ready_peer_ids.is_empty() or states.is_empty():
		return null
	_apply_latest_client_states(states)
	_host_snapshot_sequence += 1
	for state in states:
		if state == null:
			continue
		state.sequence = _host_snapshot_sequence
		state.health_revision = int(health_revisions.get(state.peer_id, 0))
	var force_keyframe := _snapshot_cohort_requires_keyframe(
		ready_peer_ids,
		host_timestamp
	)
	var data := _snapshot_manager.encode_player_snapshots_for_cohort(
		SHARED_SNAPSHOT_COHORT_ID,
		states,
		force_keyframe
	)
	if data.is_empty():
		return null
	_snapshot_encode_count += 1
	_commit_snapshot_cohort_send(
		ready_peer_ids,
		host_timestamp,
		force_keyframe
	)
	var batch := HostSnapshotBatch.new()
	batch.peer_ids.assign(ready_peer_ids)
	batch.host_timestamp = host_timestamp
	batch.data = data
	batch.entity_count = states.size()
	return batch


func apply_authoritative_snapshot(
	snapshot_time: float,
	data: PackedByteArray,
	local_peer_id: int,
	local_tango_prediction_active: bool
) -> PackedInt32Array:
	var stale_peer_ids := PackedInt32Array()
	if not is_bound() or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return stale_peer_ids
	var states := _snapshot_manager.decode_player_snapshots_with_baseline(data)
	var snapshot_has_full_roster := _is_complete_snapshot_batch(data, states.size())
	var seen_player_ids: Dictionary[int, bool] = {}
	for state in states:
		var player_state := state as SnapshotManager.PlayerState
		if player_state == null or player_state.peer_id <= 0:
			continue
		seen_player_ids[player_state.peer_id] = true
		var player_node := _runtime.get_player_for_peer(player_state.peer_id)
		if player_node != null and is_instance_valid(player_node):
			try_apply_pending_authoritative_teleport(
				player_state.peer_id,
				local_peer_id,
				snapshot_time
			)
			player_node = _runtime.get_player_for_peer(player_state.peer_id)
		var accept_motion := accept_snapshot_motion_after_teleport(
			player_state.peer_id,
			player_state.sequence
		)
		if player_node != null and is_instance_valid(player_node):
			if player_node.get_character_id() != player_state.character_id:
				_warn_character_snapshot_mismatch(
					player_state.peer_id,
					player_node.get_character_id(),
					player_state.character_id
				)
				continue
			_apply_primary_cooldown_ratio(
				player_node,
				player_state.primary_cooldown_ratio,
				player_state.facing,
				player_state.peer_id == local_peer_id
				and local_tango_prediction_active
			)
		if player_state.peer_id == local_peer_id:
			_apply_realtime_snapshot(player_node, player_state)
			continue
		if not accept_motion:
			_apply_realtime_snapshot(player_node, player_state)
			continue
		var interpolator := _visual_interpolators.get(
			player_state.peer_id
		) as NetInterpolator
		if interpolator == null:
			interpolator = _create_interpolator()
			_visual_interpolators[player_state.peer_id] = interpolator
		interpolator.push_snapshot(
			snapshot_time,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			0,
			false
		)
		_apply_realtime_snapshot(player_node, player_state)
	if not snapshot_has_full_roster or seen_player_ids.is_empty():
		return stale_peer_ids
	var resolved_local_peer_id := local_peer_id
	if resolved_local_peer_id <= 0:
		resolved_local_peer_id = _runtime.multiplayer_local_peer_id
	for peer_id_variant in _runtime.peer_players.keys():
		var peer_id := int(peer_id_variant)
		if peer_id == resolved_local_peer_id or seen_player_ids.has(peer_id):
			continue
		stale_peer_ids.append(peer_id)
	return stale_peer_ids


func interpolate_remote_players(current_time: float, local_peer_id: int) -> void:
	if not is_bound() or int(_runtime.runtime_mode) != GAME_RUNTIME_CLIENT_VIEW:
		return
	for peer_id_variant in _visual_interpolators:
		var peer_id := int(peer_id_variant)
		if peer_id == local_peer_id:
			continue
		var interpolator := _visual_interpolators.get(peer_id) as NetInterpolator
		var player_node := _runtime.get_player_for_peer(peer_id)
		if interpolator == null or player_node == null or not is_instance_valid(player_node):
			continue
		var frame_state := interpolator.get_current_state(current_time)
		player_node.apply_multiplayer_snapshot_motion(
			interpolator.get_interpolated_position(current_time),
			interpolator.get_interpolated_velocity(current_time),
			frame_state.facing,
			frame_state.anim_state
		)


func remember_latest_client_state(
	is_host: bool,
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int
) -> void:
	if not is_host or peer_id <= 0:
		return
	_latest_client_states[peer_id] = {
		"position": player_position,
		"velocity": player_velocity,
		"facing": facing_id,
		"anim_state": anim_state,
	}


func erase_latest_client_state(peer_id: int) -> void:
	_latest_client_states.erase(peer_id)


func has_latest_client_state(peer_id: int) -> bool:
	return _latest_client_states.has(peer_id)


func get_latest_client_state(peer_id: int) -> Dictionary:
	return (_latest_client_states.get(peer_id, {}) as Dictionary).duplicate(true)


func queue_authoritative_teleport(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int,
	local_peer_id: int,
	snapshot_time: float
) -> bool:
	if (
		peer_id <= 0
		or snapshot_sequence_cutoff < 0
		or not _is_finite_vector2(target_position)
	):
		return false
	_teleport_cutoff_sequences[peer_id] = maxi(
		snapshot_sequence_cutoff,
		int(_teleport_cutoff_sequences.get(peer_id, -1))
	)
	_pending_authoritative_teleports[peer_id] = {
		"position": target_position,
		"snapshot_sequence_cutoff": snapshot_sequence_cutoff,
	}
	try_apply_pending_authoritative_teleport(
		peer_id,
		local_peer_id,
		snapshot_time
	)
	return true


func try_apply_pending_authoritative_teleport(
	peer_id: int,
	local_peer_id: int,
	snapshot_time: float
) -> bool:
	if not is_bound() or peer_id <= 0:
		return false
	var pending := _pending_authoritative_teleports.get(peer_id, {}) as Dictionary
	if pending.is_empty():
		return false
	var player_node := _runtime.get_player_for_peer(peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return false
	var target_position := pending.get("position", Vector2.ZERO) as Vector2
	apply_authoritative_teleport_to_player(player_node, target_position)
	if int(_runtime.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW and peer_id != local_peer_id:
		reset_visual_interpolator_to_state(
			peer_id,
			target_position,
			Vector2.ZERO,
			player_node.get_multiplayer_facing_id(),
			player_node.get_multiplayer_anim_state(),
			snapshot_time
		)
	_pending_authoritative_teleports.erase(peer_id)
	return true


func accept_snapshot_motion_after_teleport(
	peer_id: int,
	snapshot_sequence: int
) -> bool:
	var cutoff := int(_teleport_cutoff_sequences.get(peer_id, -1))
	if cutoff < 0:
		return true
	if snapshot_sequence <= cutoff:
		return false
	_teleport_cutoff_sequences.erase(peer_id)
	return true


func reset_visual_interpolator_to_state(
	peer_id: int,
	player_position: Vector2,
	player_velocity: Vector2,
	facing_id: int,
	anim_state: int,
	snapshot_time: float
) -> void:
	if peer_id <= 0:
		return
	var interpolator := _visual_interpolators.get(peer_id) as NetInterpolator
	if interpolator == null:
		interpolator = _create_interpolator()
		_visual_interpolators[peer_id] = interpolator
	interpolator.clear()
	interpolator.push_snapshot(
		snapshot_time,
		player_position,
		player_velocity,
		facing_id,
		anim_state,
		0,
		false
	)


func apply_authoritative_teleport_to_player(
	player_node: Player,
	target_position: Vector2
) -> bool:
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or not _is_finite_vector2(target_position)
	):
		return false
	var smoothing_was_enabled := player_node.is_multiplayer_visual_smoothing_enabled()
	if smoothing_was_enabled:
		player_node.set_multiplayer_visual_smoothing_enabled(false)
	player_node.global_position = target_position
	player_node.velocity = Vector2.ZERO
	player_node.reset_physics_interpolation()
	if smoothing_was_enabled:
		player_node.set_multiplayer_visual_smoothing_enabled(true)
	return true


func apply_local_state_correction(
	corrected_position: Vector2,
	corrected_velocity: Vector2
) -> void:
	if not is_bound() or _runtime.player == null:
		return
	_runtime.player.global_position = corrected_position
	_runtime.player.velocity = corrected_velocity


func restore_reconnected_player_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState,
	snapshot_time: float,
	is_host: bool,
	local_peer_id: int,
	local_tango_prediction_active: bool
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	# Potion/consumable runtime state intentionally does not survive reconnect.
	# Clear the captured transient bit before it reaches the replacement Player.
	player_state.void_battery_charged = false
	player_node.apply_multiplayer_snapshot_motion(
		player_state.position,
		player_state.velocity,
		player_state.facing,
		player_state.anim_state
	)
	_apply_primary_cooldown_ratio(
		player_node,
		player_state.primary_cooldown_ratio,
		player_state.facing,
		player_state.peer_id == local_peer_id and local_tango_prediction_active
	)
	_apply_realtime_snapshot(player_node, player_state)
	if is_host:
		remember_latest_client_state(
			true,
			player_state.peer_id,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state
		)
	else:
		reset_visual_interpolator_to_state(
			player_state.peer_id,
			player_state.position,
			player_state.velocity,
			player_state.facing,
			player_state.anim_state,
			snapshot_time
		)


func get_host_snapshot_sequence() -> int:
	return _host_snapshot_sequence


func get_snapshot_encode_count() -> int:
	return _snapshot_encode_count


func get_snapshot_cohort_size() -> int:
	return _snapshot_cohort_peers.size()


func get_applied_health_revision(peer_id: int) -> int:
	return int(_applied_health_revisions.get(peer_id, 0))


func set_applied_health_revision(peer_id: int, health_revision: int) -> void:
	if peer_id <= 0 or health_revision < 0:
		return
	_applied_health_revisions[peer_id] = health_revision


func mark_health_revision_applied(peer_id: int, health_revision: int) -> void:
	if peer_id <= 0 or health_revision < 0:
		return
	_applied_health_revisions[peer_id] = maxi(
		get_applied_health_revision(peer_id),
		health_revision
	)


func get_visual_interpolator(peer_id: int) -> NetInterpolator:
	return _visual_interpolators.get(peer_id) as NetInterpolator


func has_visual_interpolator(peer_id: int) -> bool:
	return _visual_interpolators.has(peer_id)


func get_visual_interpolator_count() -> int:
	return _visual_interpolators.size()


func has_pending_authoritative_teleport(peer_id: int) -> bool:
	return _pending_authoritative_teleports.has(peer_id)


func clear_peer(peer_id: int) -> void:
	if peer_id <= 0:
		return
	var preserve_tango_surge_world_state := (
		_active_tango_electric_surges_by_peer.has(peer_id)
	)
	if preserve_tango_surge_world_state:
		mark_tango_owner_disconnected(peer_id)
	_snapshot_manager.clear_peer_delta_cache(peer_id)
	_snapshot_cohort_peers.erase(peer_id)
	_last_keyframe_time_by_peer.erase(peer_id)
	if _snapshot_cohort_peers.is_empty():
		_snapshot_manager.clear_player_send_baseline(SHARED_SNAPSHOT_COHORT_ID)
	_visual_interpolators.erase(peer_id)
	_teleport_cutoff_sequences.erase(peer_id)
	_pending_authoritative_teleports.erase(peer_id)
	_character_mismatch_warnings.erase(peer_id)
	_latest_client_states.erase(peer_id)
	_applied_health_revisions.erase(peer_id)
	_player_health_revisions.erase(peer_id)
	_dead_player_revive_times.erase(peer_id)
	_dead_player_revive_last_seconds.erase(peer_id)
	_last_player_state_sequences.erase(peer_id)
	_last_dash_request_sequences.erase(peer_id)
	_last_dash_confirmed_sequences.erase(peer_id)
	_last_dash_accepted_times.erase(peer_id)
	_hoe_action_sequences_by_peer.erase(peer_id)
	_last_hoe_action_request_ids.erase(peer_id)
	_last_tango_charge_request_ids.erase(peer_id)
	_active_tango_charges_by_peer.erase(peer_id)
	if not preserve_tango_surge_world_state:
		_tango_charge_sequences_by_peer.erase(peer_id)
		_tango_electric_surge_sequences_by_peer.erase(peer_id)
		_last_tango_electric_surge_request_ids.erase(peer_id)
		_active_tango_electric_surges_by_peer.erase(peer_id)
		_last_tango_electric_surge_seen_by_peer.erase(peer_id)
	_tiyi_activation_sequences_by_peer.erase(peer_id)
	clear_tiyi_lifecycle_state(peer_id)
	_last_tiyi_activation_seen_by_peer.erase(peer_id)
	if peer_id == _get_action_local_peer_id():
		_local_tango_active_request_id = 0
		_local_tango_release_pending = false
	_accepted_player_state_positions.erase(peer_id)
	_accepted_player_state_times.erase(peer_id)
	_player_action_ingress_rate_buckets.erase(peer_id)


func reset_session_state() -> void:
	_snapshot_manager.reset_delta_cache()
	_visual_interpolators.clear()
	_teleport_cutoff_sequences.clear()
	_pending_authoritative_teleports.clear()
	_character_mismatch_warnings.clear()
	_latest_client_states.clear()
	_applied_health_revisions.clear()
	_last_keyframe_time_by_peer.clear()
	_snapshot_cohort_peers.clear()
	_processed_player_hit_ids.clear()
	_player_health_revisions.clear()
	_dead_player_revive_times.clear()
	_dead_player_revive_last_seconds.clear()
	_realtime_input_sequence = 0
	_has_sent_realtime_input = false
	_last_sent_move_input = Vector2.ZERO
	_last_sent_shoot_input = Vector2.ZERO
	_input_frames_since_last_send = (
		_NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
	)
	_client_shoot_input_was_passive_tango_aim = false
	_local_dash_request_sequence = 0
	_clear_pending_dash_input()
	_local_hoe_action_request_id = 0
	_local_tango_charge_request_id = 0
	_local_tango_active_request_id = 0
	_local_tango_release_pending = false
	_local_tango_electric_surge_request_id = 0
	_local_tiyi_activation_request_id = 0
	_last_player_state_sequences.clear()
	_last_dash_request_sequences.clear()
	_last_dash_confirmed_sequences.clear()
	_last_dash_accepted_times.clear()
	_hoe_action_sequences_by_peer.clear()
	_last_hoe_action_request_ids.clear()
	_tango_charge_sequences_by_peer.clear()
	_last_tango_charge_request_ids.clear()
	_active_tango_charges_by_peer.clear()
	_tango_electric_surge_sequences_by_peer.clear()
	_last_tango_electric_surge_request_ids.clear()
	_active_tango_electric_surges_by_peer.clear()
	_last_tango_electric_surge_seen_by_peer.clear()
	_tiyi_activation_sequences_by_peer.clear()
	_active_tiyi_activations_by_peer.clear()
	_tiyi_target_ids_by_peer.clear()
	_pending_tiyi_target_updates.clear()
	_pending_remote_tiyi_target_updates.clear()
	_last_tiyi_activation_seen_by_peer.clear()
	_accepted_player_state_positions.clear()
	_accepted_player_state_times.clear()
	_player_action_ingress_rate_buckets.clear()
	_host_snapshot_sequence = 0
	_snapshot_encode_count = 0


func _apply_latest_client_states(states: Array[SnapshotManager.PlayerState]) -> void:
	if _latest_client_states.is_empty():
		return
	for state in states:
		if state == null or state.is_dead:
			continue
		var latest := _latest_client_states.get(state.peer_id, {}) as Dictionary
		if latest.is_empty():
			continue
		state.position = latest.get("position", state.position) as Vector2
		state.velocity = latest.get("velocity", state.velocity) as Vector2
		state.facing = int(latest.get("facing", state.facing))
		state.anim_state = int(latest.get("anim_state", state.anim_state))


func _snapshot_cohort_requires_keyframe(
	ready_peer_ids: Array[int],
	snapshot_time: float
) -> bool:
	if ready_peer_ids.is_empty():
		return false
	if _snapshot_cohort_peers.size() != ready_peer_ids.size():
		return true
	for peer_id in ready_peer_ids:
		if (
			not _snapshot_cohort_peers.has(peer_id)
			or not _last_keyframe_time_by_peer.has(peer_id)
		):
			return true
		var last_keyframe_time := float(
			_last_keyframe_time_by_peer.get(peer_id, -INF)
		)
		if snapshot_time - last_keyframe_time >= PLAYER_DELTA_KEYFRAME_INTERVAL_SECONDS:
			return true
	return false


func _commit_snapshot_cohort_send(
	ready_peer_ids: Array[int],
	snapshot_time: float,
	was_keyframe: bool
) -> void:
	_snapshot_cohort_peers.clear()
	for peer_id in ready_peer_ids:
		if peer_id <= 0:
			continue
		_snapshot_cohort_peers[peer_id] = true
		if was_keyframe:
			_last_keyframe_time_by_peer[peer_id] = snapshot_time


func _apply_primary_cooldown_ratio(
	player_node: Player,
	ratio: float,
	facing_id: int,
	suppress_local_tango_snapshot: bool
) -> void:
	if player_node == null or not is_instance_valid(player_node):
		return
	var tango_player := player_node as PlayerTango
	if tango_player != null:
		if suppress_local_tango_snapshot:
			return
		tango_player.apply_multiplayer_tango_charge_snapshot(
			clampf(ratio, 0.0, 1.0),
			facing_id
		)
		return
	player_node.apply_multiplayer_primary_cooldown_ratio(clampf(ratio, 0.0, 1.0))


func _apply_realtime_snapshot(
	player_node: Player,
	player_state: SnapshotManager.PlayerState
) -> void:
	if player_node == null or player_state == null or not is_instance_valid(player_node):
		return
	var apply_snapshot_health := (
		player_state.health_revision
		>= get_applied_health_revision(player_state.peer_id)
	)
	player_node.apply_multiplayer_realtime_state(
		player_state.current_health if apply_snapshot_health else player_node.current_health,
		player_state.max_health if apply_snapshot_health else player_node.max_health,
		player_state.current_xirang,
		player_state.is_dead if apply_snapshot_health else player_node.is_dead,
		(
			player_state.invincibility_time_left
			if apply_snapshot_health
			else player_node.invincibility_time_left
		),
		player_state.skill1_unlocked,
		player_state.skill1_charge,
		player_state.skill1_charge_duration,
		player_state.form_mode,
		player_state.shot_pattern,
		player_state.skill1_upgrade_level,
		player_state.ammo_capacity,
		player_state.current_ammo,
		player_state.is_reloading,
		player_state.reload_progress
	)
	player_node.apply_multiplayer_effective_move_speed_multiplier(
		player_state.effective_move_speed_multiplier
	)
	player_node.apply_authoritative_void_battery_state(
		player_state.void_battery_charged
	)
	if apply_snapshot_health:
		mark_health_revision_applied(
			player_state.peer_id,
			player_state.health_revision
		)


func _warn_character_snapshot_mismatch(
	peer_id: int,
	local_character_id: StringName,
	host_character_id: StringName
) -> void:
	if _character_mismatch_warnings.has(peer_id):
		return
	_character_mismatch_warnings[peer_id] = true
	push_warning(
		"MpPlayerCoordinator: peer %d 角色不一致 local=%s host=%s，忽略该角色快照。"
		% [peer_id, local_character_id, host_character_id]
	)


func _is_complete_snapshot_batch(data: PackedByteArray, decoded_count: int) -> bool:
	if data.is_empty():
		return false
	var expected_count := int(data[0])
	return expected_count > 0 and decoded_count == expected_count


func _create_interpolator() -> NetInterpolator:
	return NetInterpolator.new(
		1.0 / float(_NetConstants.PLAYER_SNAPSHOT_HZ),
		_NetConstants.PLAYER_INTERPOLATION_DELAY_FACTOR,
		_NetConstants.PLAYER_MAX_EXTRAPOLATION_SECONDS
	)


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)
