extends Node
class_name MpTowerFateCoordinator

const XIAOCONG_TRANSACTION_RATE_PER_SECOND := 6.0
const XIAOCONG_TRANSACTION_RATE_BURST := 10.0
const COLLECTIBLE_CHOICE_MIN_INDEX := 0
const COLLECTIBLE_CHOICE_MAX_INDEX := 3

signal rpc_to_host_requested(method_name: StringName, args: Array)
signal rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
)
signal rpc_broadcast_requested(method_name: StringName, args: Array)

var _runtime: CombatRuntimeBase = null
var _tower_adapter: TowerDefenseMultiplayerModeAdapter = null
var _net_manager: NetManagerStore = null
var _net_time_origin := 0.0
var _transaction_rate_buckets: Dictionary = {}


func bind_runtime(
	runtime_instance: CombatRuntimeBase,
	tower_adapter_instance: TowerDefenseMultiplayerModeAdapter,
	net_manager_instance: NetManagerStore,
	net_time_origin_seconds: float
) -> void:
	assert(runtime_instance != null, "MpTowerFateCoordinator 缺少战斗运行时。")
	assert(tower_adapter_instance != null, "MpTowerFateCoordinator 缺少塔防模式适配器。")
	assert(net_manager_instance != null, "MpTowerFateCoordinator 缺少 NetManager。")
	if (
		_runtime == runtime_instance
		and _tower_adapter == tower_adapter_instance
		and _net_manager == net_manager_instance
	):
		_net_time_origin = net_time_origin_seconds
		return
	reset_session_state()
	_runtime = runtime_instance
	_tower_adapter = tower_adapter_instance
	_net_manager = net_manager_instance
	_net_time_origin = net_time_origin_seconds


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	reset_session_state()
	_runtime = null
	_tower_adapter = null
	_net_manager = null


func is_bound() -> bool:
	return (
		_runtime != null
		and is_instance_valid(_runtime)
		and _tower_adapter != null
		and is_instance_valid(_tower_adapter)
		and _net_manager != null
		and is_instance_valid(_net_manager)
	)


func request_local_interaction() -> void:
	if not is_bound():
		return
	if _net_manager.is_host():
		_tower_adapter.request_xiaocong_interaction(
			_net_manager.get_local_peer_id()
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_xiaocong_interaction_requested", [])


func request_local_vote(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	if not is_bound() or not is_valid_vote_payload(option_id, permanent_buff_id):
		return
	if _net_manager.is_host():
		_tower_adapter.request_xiaocong_fate_vote(
			_net_manager.get_local_peer_id(),
			option_id,
			permanent_buff_id
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_xiaocong_fate_vote_requested",
			[String(option_id), String(permanent_buff_id)]
		)


func request_local_collectible_choice(choice_index: int) -> void:
	if not is_bound() or not _is_valid_collectible_choice(choice_index):
		return
	if _net_manager.is_host():
		_tower_adapter.request_xiaocong_collectible_choice(
			_net_manager.get_local_peer_id(),
			choice_index
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_xiaocong_collectible_choice_requested",
			[choice_index]
		)


static func is_valid_vote_payload(
	option_id: StringName,
	permanent_buff_id: StringName
) -> bool:
	if TowerDefenseFateRegistry.get_option_config(option_id) == null:
		return false
	if option_id == TowerDefenseFateRegistry.OPTION_PERMANENT_CONTRACT:
		return (
			TowerDefenseFateRegistry.get_permanent_buff_config(permanent_buff_id)
			!= null
		)
	if option_id == TowerDefenseFateRegistry.OPTION_CRITICAL_CORE:
		return (
			permanent_buff_id.is_empty()
			or TowerDefenseFateRegistry.get_permanent_buff_config(permanent_buff_id)
			!= null
		)
	return permanent_buff_id.is_empty()


func handle_remote_interaction(peer_id: int) -> void:
	if not _admit_domain_request(peer_id):
		return
	_tower_adapter.request_xiaocong_interaction(peer_id)


func handle_remote_vote(
	peer_id: int,
	option_id: String,
	permanent_buff_id: String
) -> void:
	if (
		option_id.length() > TowerDefenseFateRegistry.MAX_WIRE_ID_LENGTH
		or permanent_buff_id.length() > TowerDefenseFateRegistry.MAX_WIRE_ID_LENGTH
	):
		return
	var typed_option_id := StringName(option_id)
	var typed_buff_id := StringName(permanent_buff_id)
	if not is_valid_vote_payload(typed_option_id, typed_buff_id):
		return
	if not _admit_domain_request(peer_id):
		return
	_tower_adapter.request_xiaocong_fate_vote(
		peer_id,
		typed_option_id,
		typed_buff_id
	)


func handle_remote_collectible_choice(peer_id: int, choice_index: int) -> void:
	if not _is_valid_collectible_choice(choice_index):
		return
	if not _admit_domain_request(peer_id):
		return
	_tower_adapter.request_xiaocong_collectible_choice(peer_id, choice_index)


func handle_host_fate_state_changed(state: Dictionary) -> void:
	if not _is_host_bound() or not is_inside_tree():
		return
	rpc_broadcast_requested.emit(
		&"net_xiaocong_fate_state_changed",
		[state.duplicate(true)]
	)


func send_fate_state_to_peer(peer_id: int) -> void:
	if (
		not _is_host_bound()
		or peer_id <= 0
		or not _net_manager.is_peer_send_ready(peer_id)
	):
		return
	var snapshot := _tower_adapter.get_xiaocong_fate_state_snapshot()
	if snapshot.is_empty():
		return
	rpc_to_peer_requested.emit(
		peer_id,
		&"net_xiaocong_fate_state_changed",
		[snapshot.duplicate(true)]
	)


func receive_fate_state(state: Dictionary, sender_id: int) -> void:
	if (
		not is_bound()
		or not _net_manager.is_client()
		or sender_id != _net_manager.get_host_peer_id()
	):
		return
	_tower_adapter.apply_remote_xiaocong_fate_state(state)


func clear_peer(peer_id: int) -> void:
	_transaction_rate_buckets.erase(peer_id)


func reset_session_state() -> void:
	_transaction_rate_buckets.clear()


func _admit_domain_request(peer_id: int) -> bool:
	if (
		not _is_host_bound()
		or peer_id <= 0
		or _runtime.get_player_for_peer(peer_id) == null
	):
		return false
	return _consume_peer_rate_token(peer_id)


func _consume_peer_rate_token(peer_id: int) -> bool:
	var now := _get_net_time()
	var bucket := _transaction_rate_buckets.get(peer_id, {}) as Dictionary
	if bucket.is_empty():
		bucket = {
			"tokens": XIAOCONG_TRANSACTION_RATE_BURST,
			"last_time": now,
		}
		_transaction_rate_buckets[peer_id] = bucket
	var tokens := minf(
		XIAOCONG_TRANSACTION_RATE_BURST,
		float(bucket.get("tokens", XIAOCONG_TRANSACTION_RATE_BURST))
		+ maxf(now - float(bucket.get("last_time", now)), 0.0)
		* XIAOCONG_TRANSACTION_RATE_PER_SECOND
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _is_valid_collectible_choice(choice_index: int) -> bool:
	return (
		choice_index >= COLLECTIBLE_CHOICE_MIN_INDEX
		and choice_index <= COLLECTIBLE_CHOICE_MAX_INDEX
	)


func _is_host_bound() -> bool:
	return is_bound() and _net_manager.is_host()


func _get_net_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin
