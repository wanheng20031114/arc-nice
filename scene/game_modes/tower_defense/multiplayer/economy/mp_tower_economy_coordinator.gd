extends Node
class_name MpTowerEconomyCoordinator

const OakWarehouseProtocolScript := preload(
	"res://scene/game_modes/tower_defense/economy/warehouse/oak_warehouse_protocol.gd"
)
const ProductionBuildingProtocolScript := preload(
	"res://scene/game_modes/tower_defense/economy/production/production_building_protocol.gd"
)
const PeerReplayResultCacheScript := preload(
	"res://scene/multiplayer/peer_replay_result_cache.gd"
)

const BUILDING_INTERACTION_MAX_DISTANCE := 48.0
const WAREHOUSE_TRANSACTION_RATE_PER_SECOND := 12.0
const WAREHOUSE_TRANSACTION_RATE_BURST := 20.0
const WAREHOUSE_SNAPSHOT_REQUEST_RATE_PER_SECOND := 2.0
const WAREHOUSE_SNAPSHOT_REQUEST_RATE_BURST := 4.0
const WAREHOUSE_TRANSACTION_RESULT_CACHE_SIZE := 256
const PRODUCTION_COMMAND_RATE_PER_SECOND := 8.0
const PRODUCTION_COMMAND_RATE_BURST := 12.0
const PRODUCTION_SNAPSHOT_REQUEST_RATE_PER_SECOND := 2.0
const PRODUCTION_SNAPSHOT_REQUEST_RATE_BURST := 4.0
const PRODUCTION_COMMAND_RESULT_CACHE_SIZE := 256
const PRODUCTION_STATE_BATCH_MAX_BUILDINGS := 24
const RESEARCH_COMMAND_RATE_PER_SECOND := 4.0
const RESEARCH_COMMAND_RATE_BURST := 6.0
const RESEARCH_COMMAND_WIRE_ID_MAX_LENGTH := 128
const CLIENT_PENDING_WAREHOUSE_SNAPSHOT_MAX_ENTRIES := 256
const CLIENT_PENDING_PRODUCTION_STATE_MAX_ENTRIES := 256
const CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES := 512

signal rpc_to_host_requested(method_name: StringName, args: Array)
signal rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array,
	record_outbound: bool
)
signal rpc_broadcast_requested(method_name: StringName, args: Array)
signal inventory_snapshot_broadcast_requested(peer_id: int, snapshot: Dictionary)
signal plant_runtime_state_apply_requested(
	plant: PlantDefense,
	state: Dictionary,
	host_sample_time: float
)
signal transaction_latency_observed(latency_ms: float)

var _runtime: CombatRuntimeBase = null
var _tower_adapter: TowerDefenseMultiplayerModeAdapter = null
var _run_state: RunStateStore = null
var _net_manager: NetManagerStore = null
var _net_time_origin := 0.0

var _warehouse_transaction_rate_buckets: Dictionary = {}
var _warehouse_snapshot_request_rate_buckets: Dictionary = {}
var _warehouse_transaction_result_cache := PeerReplayResultCacheScript.new(
	WAREHOUSE_TRANSACTION_RESULT_CACHE_SIZE
)
var _warehouse_transaction_started_usec: Dictionary = {}
var _pending_warehouse_snapshots: Dictionary = {}
var _pending_warehouse_snapshot_previous_ids: Dictionary = {}
var _pending_warehouse_snapshot_next_ids: Dictionary = {}
var _pending_warehouse_snapshot_oldest_id := 0
var _pending_warehouse_snapshot_newest_id := 0
var _pending_authoritative_warehouse_snapshots: Dictionary = {}

var _production_command_rate_buckets: Dictionary = {}
var _production_snapshot_request_rate_buckets: Dictionary = {}
var _production_command_result_cache := PeerReplayResultCacheScript.new(
	PRODUCTION_COMMAND_RESULT_CACHE_SIZE
)
var _pending_production_state_updates: Dictionary = {}
var _pending_remote_production_states: Dictionary = {}
var _pending_remote_production_state_previous_ids: Dictionary = {}
var _pending_remote_production_state_next_ids: Dictionary = {}
var _pending_remote_production_state_oldest_id := 0
var _pending_remote_production_state_newest_id := 0
var _shared_production_state_flush_scheduled := false

var _research_command_rate_buckets: Dictionary = {}
var _last_research_request_ids: Dictionary = {}
var _research_milestone_connected := false

# CH5 plant lifecycle and CH6 economy packets use independent ordered channels.
# This bounded marker prevents a late economy packet from rebuilding state after
# the plant world has already confirmed removal.
var _removed_plant_ids: Dictionary = {}
var _removed_plant_id_order: Array[int] = []


func bind_runtime(
	runtime_instance: CombatRuntimeBase,
	tower_adapter_instance: TowerDefenseMultiplayerModeAdapter,
	run_state_instance: RunStateStore,
	net_manager_instance: NetManagerStore,
	net_time_origin_seconds: float
) -> void:
	assert(runtime_instance != null, "MpTowerEconomyCoordinator 缺少战斗运行时。")
	assert(tower_adapter_instance != null, "MpTowerEconomyCoordinator 缺少塔防适配器。")
	assert(run_state_instance != null, "MpTowerEconomyCoordinator 缺少 RunState。")
	assert(net_manager_instance != null, "MpTowerEconomyCoordinator 缺少 NetManager。")
	if (
		_runtime == runtime_instance
		and _tower_adapter == tower_adapter_instance
		and _run_state == run_state_instance
		and _net_manager == net_manager_instance
	):
		_net_time_origin = net_time_origin_seconds
		return
	reset_session_state()
	_runtime = runtime_instance
	_tower_adapter = tower_adapter_instance
	_run_state = run_state_instance
	_net_manager = net_manager_instance
	_net_time_origin = net_time_origin_seconds


func unbind_runtime(runtime_instance: CombatRuntimeBase) -> void:
	if _runtime != runtime_instance:
		return
	reset_session_state()
	_runtime = null
	_tower_adapter = null
	_run_state = null
	_net_manager = null


func is_bound() -> bool:
	return (
		_runtime != null
		and is_instance_valid(_runtime)
		and _tower_adapter != null
		and is_instance_valid(_tower_adapter)
		and _run_state != null
		and is_instance_valid(_run_state)
		and _net_manager != null
		and is_instance_valid(_net_manager)
	)


func configure_warehouse_network(
	plant: PlantDefense,
	snapshot_ready: bool,
	apply_pending_snapshots: bool = true
) -> void:
	if not is_bound():
		return
	var warehouse := plant as OakWarehouse
	if warehouse == null:
		return
	var net_id := int(warehouse.get_meta("net_id", warehouse.warehouse_net_id))
	if net_id <= 0:
		return
	notify_plant_available(net_id)
	warehouse.configure_multiplayer_storage(
		net_id,
		_net_manager.get_local_peer_id(),
		snapshot_ready
	)
	if _net_manager.is_host():
		_restore_authoritative_warehouse_from_ledger(warehouse, net_id)
	var command_callback := _on_warehouse_storage_command_requested.bind(warehouse)
	if not warehouse.storage_command_requested.is_connected(command_callback):
		warehouse.storage_command_requested.connect(command_callback)
	var snapshot_callback := _on_warehouse_storage_snapshot_requested.bind(warehouse)
	if not warehouse.storage_snapshot_requested.is_connected(snapshot_callback):
		warehouse.storage_snapshot_requested.connect(snapshot_callback)
	if _net_manager.is_host():
		var changed_callback := _on_authoritative_warehouse_storage_changed.bind(
			warehouse
		)
		if not warehouse.storage_changed.is_connected(changed_callback):
			warehouse.storage_changed.connect(changed_callback)
	if apply_pending_snapshots:
		try_apply_pending_warehouse_snapshots_atomically()
	if (
		_net_manager.is_client()
		and apply_pending_snapshots
		and not warehouse.multiplayer_storage_snapshot_ready
		and not _pending_warehouse_snapshots.has(net_id)
	):
		warehouse.request_multiplayer_storage_snapshot()


func configure_production_network(
	plant: PlantDefense,
	snapshot_ready: bool
) -> void:
	if not is_bound():
		return
	var building := plant as ProductionBuilding
	if building == null:
		return
	var net_id := int(building.get_meta("net_id", building.building_net_id))
	if net_id <= 0:
		return
	notify_plant_available(net_id)
	building.configure_multiplayer_production(
		net_id,
		_net_manager.get_local_peer_id(),
		snapshot_ready
	)
	var command_callback := _on_production_command_requested.bind(building)
	if not building.production_command_requested.is_connected(command_callback):
		building.production_command_requested.connect(command_callback)
	var snapshot_callback := _on_production_snapshot_requested.bind(building)
	if not building.production_snapshot_requested.is_connected(snapshot_callback):
		building.production_snapshot_requested.connect(snapshot_callback)
	if _net_manager.is_host():
		var state_callback := _on_authoritative_production_state_changed.bind(building)
		if not building.production_state_changed.is_connected(state_callback):
			building.production_state_changed.connect(state_callback)
	var pending := take_pending_remote_production_state(net_id)
	if not pending.is_empty():
		plant_runtime_state_apply_requested.emit(
			building,
			pending.get("state", {}) as Dictionary,
			float(pending.get("host_sample_time", 0.0))
		)


func configure_research_network(plant: PlantDefense) -> void:
	if not is_bound():
		return
	var building := plant as ResearchCenter
	if building == null:
		return
	var net_id := int(building.get_meta("net_id", building.building_net_id))
	if net_id <= 0:
		return
	notify_plant_available(net_id)
	building.configure_multiplayer_research(
		net_id,
		_net_manager.get_local_peer_id()
	)
	var callback := _on_research_command_requested.bind(building)
	if not building.research_command_requested.is_connected(callback):
		building.research_command_requested.connect(callback)
	if _net_manager.is_host() and not _research_milestone_connected:
		_research_milestone_connected = (
			_tower_adapter.connect_research_milestone_changed(
				_on_authoritative_research_milestone_changed
			)
		)


func request_plant_runtime_state_apply(
	plant: PlantDefense,
	state: Dictionary,
	host_sample_time: float
) -> void:
	plant_runtime_state_apply_requested.emit(plant, state, host_sample_time)


func handle_authoritative_warehouse_command(
	peer_id: int,
	raw_command: Dictionary
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var command := OakWarehouseProtocolScript.canonicalize_command(
		raw_command,
		peer_id
	)
	if command.is_empty() or not _consume_peer_rate_token(
		_warehouse_transaction_rate_buckets,
		peer_id,
		WAREHOUSE_TRANSACTION_RATE_PER_SECOND,
		WAREHOUSE_TRANSACTION_RATE_BURST
	):
		return
	var request_id := OakWarehouseProtocolScript.get_int_field(
		command,
		"request_id",
		0
	)
	var warehouse_net_id := OakWarehouseProtocolScript.get_int_field(
		command,
		"warehouse_net_id",
		0
	)
	var cached_result := _get_cached_warehouse_transaction_result(
		peer_id,
		warehouse_net_id,
		request_id
	)
	if not cached_result.is_empty():
		_send_warehouse_command_result(peer_id, cached_result)
		return
	var result: Dictionary = {}
	var warehouse := _get_tower_plant(warehouse_net_id) as OakWarehouse
	var player_node := _runtime.get_player_for_peer(peer_id)
	var rejection_reason := &"invalid_command"
	if not OakWarehouseProtocolScript.is_valid_command(command):
		rejection_reason = &"invalid_command"
	elif player_node == null or not is_instance_valid(player_node) or player_node.is_dead:
		rejection_reason = &"invalid_player"
	elif (
		warehouse == null
		or not is_instance_valid(warehouse)
		or warehouse.is_dead
		or warehouse.is_removing
		or not warehouse.is_operational
	):
		rejection_reason = &"warehouse_missing"
	elif not _is_authoritative_nearest_warehouse(player_node, warehouse):
		rejection_reason = &"out_of_range"
	else:
		result = warehouse.apply_transfer_command(command, _run_state)
	if result.is_empty():
		result = OakWarehouseProtocolScript.make_result(
			command,
			false,
			rejection_reason,
			_run_state.get_inventory_revision_for_peer(peer_id),
			warehouse.get_storage_revision() if warehouse != null else 0
		)
		result["inventory_snapshot"] = (
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)
		if warehouse != null:
			result["storage_snapshot"] = warehouse.export_storage_snapshot()
	_cache_warehouse_transaction_result(
		peer_id,
		warehouse_net_id,
		request_id,
		result
	)
	_send_warehouse_command_result(peer_id, result)
	if bool(result.get("success", false)):
		inventory_snapshot_broadcast_requested.emit(
			peer_id,
			_run_state.export_inventory_snapshot_for_peer(peer_id)
		)


func handle_authoritative_warehouse_snapshot_request(
	sender_id: int,
	warehouse_net_id: int
) -> bool:
	if not _is_host_bound() or sender_id <= 0 or warehouse_net_id <= 0:
		return false
	var player_node := _runtime.get_player_for_peer(sender_id)
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or player_node.is_dead
		or not _consume_peer_rate_token(
			_warehouse_snapshot_request_rate_buckets,
			sender_id,
			WAREHOUSE_SNAPSHOT_REQUEST_RATE_PER_SECOND,
			WAREHOUSE_SNAPSHOT_REQUEST_RATE_BURST
		)
	):
		return false
	var warehouse := _get_tower_plant(warehouse_net_id) as OakWarehouse
	if (
		not _is_authoritative_warehouse_interaction_candidate(warehouse)
		or not _is_authoritative_nearest_warehouse(player_node, warehouse)
		or not _net_manager.is_peer_send_ready(sender_id)
	):
		return false
	var inventory_snapshot := _run_state.export_inventory_snapshot_for_peer(
		sender_id
	)
	rpc_to_peer_requested.emit(
		sender_id,
		&"net_inventory_snapshot",
		[sender_id, inventory_snapshot, false],
		true
	)
	rpc_to_peer_requested.emit(
		sender_id,
		&"net_warehouse_storage_snapshot_batch",
		[
			PackedInt32Array([warehouse_net_id]),
			[warehouse.export_storage_snapshot()],
		],
		true
	)
	return true


func handle_authoritative_production_command(
	peer_id: int,
	raw_command: Dictionary
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var command := ProductionBuildingProtocolScript.canonicalize_command(
		raw_command,
		peer_id
	)
	if command.is_empty() or not _consume_peer_rate_token(
		_production_command_rate_buckets,
		peer_id,
		PRODUCTION_COMMAND_RATE_PER_SECOND,
		PRODUCTION_COMMAND_RATE_BURST
	):
		return
	var request_id := ProductionBuildingProtocolScript.get_int_field(
		command,
		"request_id",
		0
	)
	var building_net_id := ProductionBuildingProtocolScript.get_int_field(
		command,
		"building_net_id",
		0
	)
	var cached_result := _get_cached_production_command_result(
		peer_id,
		building_net_id,
		request_id
	)
	if not cached_result.is_empty():
		_send_production_command_result(peer_id, cached_result)
		return
	var building := _get_tower_plant(building_net_id) as ProductionBuilding
	var player_node := _runtime.get_player_for_peer(peer_id)
	var success := false
	var reason := ProductionBuildingProtocolScript.RESULT_INVALID_COMMAND
	if not ProductionBuildingProtocolScript.is_valid_command(command):
		reason = ProductionBuildingProtocolScript.RESULT_INVALID_COMMAND
	elif player_node == null or not is_instance_valid(player_node) or player_node.is_dead:
		reason = ProductionBuildingProtocolScript.RESULT_INVALID_PLAYER
	elif (
		building == null
		or not is_instance_valid(building)
		or building.is_dead
		or building.is_removing
		or not building.is_operational
	):
		reason = ProductionBuildingProtocolScript.RESULT_BUILDING_MISSING
	elif not _is_authoritative_nearest_production_building(player_node, building):
		reason = ProductionBuildingProtocolScript.RESULT_OUT_OF_RANGE
	else:
		reason = building.apply_authoritative_multiplayer_production_command(command)
		success = reason == ProductionBuildingProtocolScript.RESULT_SUCCESS
	var host_sample_time := _get_gameplay_net_time()
	var state := (
		building.export_multiplayer_runtime_state()
		if building != null and is_instance_valid(building)
		else {}
	)
	var result := ProductionBuildingProtocolScript.make_result(
		command,
		success,
		reason,
		building.production_revision if building != null and is_instance_valid(building) else 0,
		state,
		host_sample_time
	)
	_cache_production_command_result(
		peer_id,
		building_net_id,
		request_id,
		result
	)
	_send_production_command_result(peer_id, result)


func handle_authoritative_production_snapshot_request(
	sender_id: int,
	building_net_id: int
) -> bool:
	if not _is_host_bound() or sender_id <= 0 or building_net_id <= 0:
		return false
	var player_node := _runtime.get_player_for_peer(sender_id)
	if (
		player_node == null
		or not is_instance_valid(player_node)
		or player_node.is_dead
		or not _consume_peer_rate_token(
			_production_snapshot_request_rate_buckets,
			sender_id,
			PRODUCTION_SNAPSHOT_REQUEST_RATE_PER_SECOND,
			PRODUCTION_SNAPSHOT_REQUEST_RATE_BURST
		)
	):
		return false
	var building := _get_tower_plant(building_net_id) as ProductionBuilding
	if (
		building == null
		or not is_instance_valid(building)
		or building.is_dead
		or building.is_removing
		or not building.is_operational
		or not _is_authoritative_nearest_production_building(player_node, building)
		or not _net_manager.is_peer_send_ready(sender_id)
	):
		return false
	var sample_time := _get_gameplay_net_time()
	rpc_to_peer_requested.emit(
		sender_id,
		&"net_production_state_batch",
		[
			PackedInt32Array([building_net_id]),
			[building.export_multiplayer_runtime_state()],
			PackedFloat64Array([sample_time]),
		],
		true
	)
	return true


func handle_authoritative_research_command(
	peer_id: int,
	raw_command: Dictionary
) -> void:
	if not _is_host_bound() or peer_id <= 0:
		return
	var command := _canonicalize_research_command(raw_command, peer_id)
	if command.is_empty() or not _consume_peer_rate_token(
		_research_command_rate_buckets,
		peer_id,
		RESEARCH_COMMAND_RATE_PER_SECOND,
		RESEARCH_COMMAND_RATE_BURST
	):
		return
	var request_id := int(command["request_id"])
	var building_net_id := int(command["building_net_id"])
	var operation_wire := String(command["operation"])
	var research_id_wire := String(command["research_id"])
	var research_config: GlobalResearchConfig = (
		GlobalResearchRegistry.get_config_by_wire_id(research_id_wire)
		if operation_wire == "global"
		else null
	)
	var result := ResearchCoordinator.RESULT_UNAVAILABLE
	var peer_request_ids := _last_research_request_ids.get(peer_id, {}) as Dictionary
	var last_request_id := int(peer_request_ids.get(building_net_id, 0))
	var player_node := _runtime.get_player_for_peer(peer_id)
	var building := _get_tower_plant(building_net_id) as ResearchCenter
	if request_id <= last_request_id or (operation_wire == "global" and research_config == null):
		result = ResearchCoordinator.RESULT_UNAVAILABLE
	elif player_node == null or not is_instance_valid(player_node) or player_node.is_dead:
		result = ResearchCoordinator.RESULT_UNAVAILABLE
	elif (
		building == null
		or not is_instance_valid(building)
		or building.is_dead
		or building.is_removing
		or not building.is_operational
		or not _is_authoritative_nearest_research_center(player_node, building)
	):
		result = ResearchCoordinator.RESULT_UNAVAILABLE
	else:
		peer_request_ids[building_net_id] = request_id
		_last_research_request_ids[peer_id] = peer_request_ids
		result = (
			building.try_start_global_research(research_config.research_id)
			if operation_wire == "global"
			else building.try_purchase_player_technology(player_node)
		)
	if _net_manager.is_peer_send_ready(peer_id):
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_research_command_result",
			[
				request_id,
				building_net_id,
				result == ResearchCoordinator.RESULT_SUCCESS,
				result,
			],
			false
		)


## 仓库结果同时提交背包与仓储两个账本。返回值让跨信道协调器能够在
## 玩家身份稍后到达时，明确判断这份原子结果是已提交还是需要整包修复。
func receive_warehouse_command_result(result: Dictionary) -> bool:
	if not is_bound():
		return false
	var metric_key := _get_warehouse_transaction_metric_key(
		int(result.get("warehouse_net_id", 0)),
		int(result.get("request_id", 0))
	)
	if _warehouse_transaction_started_usec.has(metric_key):
		var started_usec := int(_warehouse_transaction_started_usec.get(metric_key, 0))
		_warehouse_transaction_started_usec.erase(metric_key)
		if started_usec > 0:
			transaction_latency_observed.emit(
				float(Time.get_ticks_usec() - started_usec) / 1000.0
			)
	var warehouse_net_id := OakWarehouseProtocolScript.get_int_field(
		result,
		"warehouse_net_id",
		0
	)
	var warehouse := _get_tower_plant(warehouse_net_id) as OakWarehouse
	if (
		warehouse == null
		or not is_instance_valid(warehouse)
		or not warehouse.is_current_multiplayer_storage_result(result)
	):
		return false
	var peer_id := OakWarehouseProtocolScript.get_int_field(result, "peer_id", 0)
	var inventory_snapshot := result.get("inventory_snapshot", {}) as Dictionary
	var storage_snapshot := result.get("storage_snapshot", {}) as Dictionary
	if peer_id <= 0 or inventory_snapshot.is_empty() or storage_snapshot.is_empty():
		return false
	if _net_manager.is_host():
		warehouse.complete_multiplayer_storage_request(result)
		return true
	var prepared_inventory := _run_state.prepare_inventory_snapshot_for_peer(
		peer_id,
		inventory_snapshot
	)
	var prepared_storage := warehouse.prepare_storage_snapshot(storage_snapshot)
	if prepared_inventory.is_empty() or prepared_storage.is_empty():
		return false
	if not commit_prepared_warehouse_transaction(
		_run_state,
		warehouse,
		prepared_inventory,
		prepared_storage
	):
		return false
	warehouse.complete_multiplayer_storage_request(result)
	return true


## 背包与仓库属于一个权威结果。先对两份 prepared 状态做最后一次 CAS
## 复核，再进入不再失败且不发 signal 的写段；两个账本都写完后才统一通知。
static func commit_prepared_warehouse_transaction(
	run_state: RunStateStore,
	warehouse: OakWarehouse,
	prepared_inventory: Dictionary,
	prepared_storage: Dictionary
) -> bool:
	if (
		run_state == null
		or warehouse == null
		or not is_instance_valid(warehouse)
		or not run_state.is_prepared_inventory_snapshot_current(
			prepared_inventory
		)
		or not warehouse.is_prepared_storage_snapshot_current(prepared_storage)
	):
		return false
	run_state.commit_prevalidated_inventory_snapshot_for_peer(prepared_inventory)
	warehouse.commit_prevalidated_storage_snapshot(prepared_storage)
	run_state.notify_inventory_snapshot_committed()
	warehouse.notify_storage_snapshot_committed()
	return true


func receive_production_command_result(result: Dictionary) -> void:
	if (
		not is_bound()
		or typeof(result.get("success")) != TYPE_BOOL
		or typeof(result.get("reason")) not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(result.get("state")) != TYPE_DICTIONARY
		or typeof(result.get("host_sample_time")) not in [TYPE_INT, TYPE_FLOAT]
	):
		return
	var host_sample_time := float(result["host_sample_time"])
	if not is_finite(host_sample_time):
		return
	var building_net_id := ProductionBuildingProtocolScript.get_int_field(
		result,
		"building_net_id",
		0
	)
	if building_net_id <= 0 or _removed_plant_ids.has(building_net_id):
		return
	var building := _get_tower_plant(building_net_id) as ProductionBuilding
	if (
		building == null
		or not is_instance_valid(building)
		or not building.is_current_multiplayer_production_result(result)
	):
		return
	var state := result["state"] as Dictionary
	if not state.is_empty():
		plant_runtime_state_apply_requested.emit(building, state, host_sample_time)
	building.complete_multiplayer_production_request(result)


func receive_production_state_batch(
	net_ids: PackedInt32Array,
	states: Array,
	host_sample_times: PackedFloat64Array
) -> void:
	if (
		not is_bound()
		or _net_manager.is_host()
		or net_ids.is_empty()
		or net_ids.size() > PRODUCTION_STATE_BATCH_MAX_BUILDINGS
		or states.size() != net_ids.size()
		or host_sample_times.size() != net_ids.size()
	):
		return
	var previous_net_id := 0
	for index in net_ids.size():
		var net_id := int(net_ids[index])
		if (
			net_id <= previous_net_id
			or not is_finite(float(host_sample_times[index]))
			or typeof(states[index]) != TYPE_DICTIONARY
		):
			return
		previous_net_id = net_id
	for index in net_ids.size():
		var net_id := int(net_ids[index])
		if _removed_plant_ids.has(net_id):
			continue
		var state := states[index] as Dictionary
		if typeof(state.get("schema")) != TYPE_INT or typeof(state.get("revision")) != TYPE_INT:
			continue
		var building := _get_tower_plant(net_id) as ProductionBuilding
		if building == null or not is_instance_valid(building):
			cache_pending_remote_production_state(
				net_id,
				state,
				float(host_sample_times[index])
			)
			continue
		plant_runtime_state_apply_requested.emit(
			building,
			state.duplicate(true),
			float(host_sample_times[index])
		)


func receive_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> bool:
	return _apply_warehouse_storage_snapshot_batch(warehouse_net_ids, snapshots)


func apply_warehouse_storage_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> bool:
	return _apply_warehouse_storage_snapshot_batch(
		PackedInt32Array([warehouse_net_id]),
		[snapshot]
	)


func cache_pending_warehouse_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> void:
	_cache_pending_warehouse_snapshot(warehouse_net_id, snapshot)


func clear_pending_warehouse_snapshots() -> void:
	_clear_pending_warehouse_snapshots()


func clear_pending_remote_production_states() -> void:
	_clear_pending_remote_production_states()


func receive_research_command_result(
	request_id: int,
	building_net_id: int,
	success: bool,
	reason: StringName
) -> void:
	if not is_bound() or building_net_id <= 0:
		return
	var building := _get_tower_plant(building_net_id) as ResearchCenter
	if building != null and is_instance_valid(building):
		building.complete_multiplayer_research_request(
			request_id,
			success,
			reason
		)


func receive_research_state_updated(
	state: Dictionary,
	changed_player_peer_id: int,
	current_xirang: int
) -> bool:
	if not is_bound() or state.is_empty():
		return false
	var changed_player: Player = null
	if changed_player_peer_id > 0:
		if current_xirang < 0:
			return false
		changed_player = _runtime.get_player_for_peer(changed_player_peer_id)
		if changed_player == null or not is_instance_valid(changed_player):
			return false
	# 研究协调器拥有协议校验与 revision CAS；上层只消费它的真实提交结果。
	if not _tower_adapter.apply_remote_research_runtime_state(state):
		return false
	if changed_player_peer_id <= 0:
		return true
	changed_player.set_xirang_balance(current_xirang)
	return true


func broadcast_warehouse_snapshot(warehouse: OakWarehouse) -> void:
	if not is_bound() or warehouse == null or not is_instance_valid(warehouse):
		return
	rpc_broadcast_requested.emit(
		&"net_warehouse_storage_snapshot_batch",
		[
			PackedInt32Array([warehouse.warehouse_net_id]),
			[warehouse.export_storage_snapshot()],
		]
	)


func capture_shared_warehouse_ledger() -> bool:
	if not _is_host_bound():
		return false
	var warehouses: Array[OakWarehouse] = []
	for plant_snapshot in _tower_adapter.get_multiplayer_plant_snapshots():
		var warehouse := _get_tower_plant(
			int(plant_snapshot.get("net_id", 0))
		) as OakWarehouse
		if warehouse != null:
			warehouses.append(warehouse)
	return SharedWarehouseLedgerBridge.capture_warehouses(
		_run_state,
		warehouses
	)


func notify_plant_removed(net_id: int) -> void:
	if net_id <= 0:
		return
	erase_pending_warehouse_snapshot(net_id)
	erase_pending_remote_production_state(net_id)
	_pending_authoritative_warehouse_snapshots.erase(net_id)
	_pending_production_state_updates.erase(net_id)
	if _removed_plant_ids.has(net_id):
		return
	if (
		_is_host_bound()
		and not SharedWarehouseLedgerBridge.remove_from_ledger(
			_run_state, net_id
		)
	):
		push_warning(
			"MpTowerEconomyCoordinator: 无法移除共享仓库 %d 的持久快照。"
			% net_id
		)
	while (
		_removed_plant_ids.size() >= CLIENT_REMOVED_PLANT_TOMBSTONE_MAX_ENTRIES
		and not _removed_plant_id_order.is_empty()
	):
		_removed_plant_ids.erase(_removed_plant_id_order.pop_front())
	_removed_plant_ids[net_id] = true
	_removed_plant_id_order.append(net_id)


func notify_plant_available(net_id: int) -> void:
	if net_id <= 0 or not _removed_plant_ids.erase(net_id):
		return
	_removed_plant_id_order.erase(net_id)


func erase_pending_warehouse_snapshot(warehouse_net_id: int) -> bool:
	if not _pending_warehouse_snapshots.has(warehouse_net_id):
		return false
	var previous_id := int(
		_pending_warehouse_snapshot_previous_ids.get(warehouse_net_id, 0)
	)
	var next_id := int(
		_pending_warehouse_snapshot_next_ids.get(warehouse_net_id, 0)
	)
	if previous_id > 0:
		_pending_warehouse_snapshot_next_ids[previous_id] = next_id
	else:
		_pending_warehouse_snapshot_oldest_id = next_id
	if next_id > 0:
		_pending_warehouse_snapshot_previous_ids[next_id] = previous_id
	else:
		_pending_warehouse_snapshot_newest_id = previous_id
	_pending_warehouse_snapshot_previous_ids.erase(warehouse_net_id)
	_pending_warehouse_snapshot_next_ids.erase(warehouse_net_id)
	_pending_warehouse_snapshots.erase(warehouse_net_id)
	return true


func try_apply_pending_warehouse_snapshots_atomically() -> bool:
	if not is_bound() or _pending_warehouse_snapshots.is_empty():
		return false
	var pending_ids := _pending_warehouse_snapshots.keys()
	pending_ids.sort()
	var warehouse_net_ids := PackedInt32Array()
	var snapshots: Array = []
	for warehouse_id_variant in pending_ids:
		var warehouse_net_id := int(warehouse_id_variant)
		if _removed_plant_ids.has(warehouse_net_id):
			continue
		var warehouse := _get_tower_plant(warehouse_net_id) as OakWarehouse
		if warehouse == null or not is_instance_valid(warehouse):
			return false
		warehouse_net_ids.append(warehouse_net_id)
		snapshots.append(
			(_pending_warehouse_snapshots[warehouse_net_id] as Dictionary).duplicate(true)
		)
	if warehouse_net_ids.is_empty():
		_clear_pending_warehouse_snapshots()
		return true
	if not _commit_warehouse_storage_snapshot_batch(warehouse_net_ids, snapshots):
		return false
	_clear_pending_warehouse_snapshots()
	return true


func cache_pending_remote_production_state(
	net_id: int,
	state: Dictionary,
	host_sample_time: float
) -> bool:
	if net_id <= 0 or not is_finite(host_sample_time) or _removed_plant_ids.has(net_id):
		return false
	if _pending_remote_production_states.has(net_id):
		var previous := _pending_remote_production_states[net_id] as Dictionary
		var previous_state := previous.get("state", {}) as Dictionary
		var revision := int(state.get("revision", -1))
		var previous_revision := int(previous_state.get("revision", -1))
		var previous_sample_time := float(previous.get("host_sample_time", -INF))
		if (
			revision < previous_revision
			or (revision == previous_revision and host_sample_time <= previous_sample_time)
		):
			return false
		_pending_remote_production_states[net_id] = {
			"state": state.duplicate(true),
			"host_sample_time": host_sample_time,
		}
		return true
	if _pending_remote_production_states.size() >= CLIENT_PENDING_PRODUCTION_STATE_MAX_ENTRIES:
		erase_pending_remote_production_state(
			_pending_remote_production_state_oldest_id
		)
	var previous_id := _pending_remote_production_state_newest_id
	_pending_remote_production_states[net_id] = {
		"state": state.duplicate(true),
		"host_sample_time": host_sample_time,
	}
	_pending_remote_production_state_previous_ids[net_id] = previous_id
	_pending_remote_production_state_next_ids[net_id] = 0
	if previous_id > 0:
		_pending_remote_production_state_next_ids[previous_id] = net_id
	else:
		_pending_remote_production_state_oldest_id = net_id
	_pending_remote_production_state_newest_id = net_id
	return true


func take_pending_remote_production_state(net_id: int) -> Dictionary:
	var pending := _pending_remote_production_states.get(net_id, {}) as Dictionary
	if pending.is_empty():
		return {}
	erase_pending_remote_production_state(net_id)
	return pending


func erase_pending_remote_production_state(net_id: int) -> bool:
	if not _pending_remote_production_states.has(net_id):
		return false
	var previous_id := int(
		_pending_remote_production_state_previous_ids.get(net_id, 0)
	)
	var next_id := int(
		_pending_remote_production_state_next_ids.get(net_id, 0)
	)
	if previous_id > 0:
		_pending_remote_production_state_next_ids[previous_id] = next_id
	else:
		_pending_remote_production_state_oldest_id = next_id
	if next_id > 0:
		_pending_remote_production_state_previous_ids[next_id] = previous_id
	else:
		_pending_remote_production_state_newest_id = previous_id
	_pending_remote_production_state_previous_ids.erase(net_id)
	_pending_remote_production_state_next_ids.erase(net_id)
	_pending_remote_production_states.erase(net_id)
	return true


func clear_peer(peer_id: int) -> void:
	_warehouse_transaction_rate_buckets.erase(peer_id)
	_warehouse_snapshot_request_rate_buckets.erase(peer_id)
	_warehouse_transaction_result_cache.clear_peer(peer_id)
	_production_command_rate_buckets.erase(peer_id)
	_production_snapshot_request_rate_buckets.erase(peer_id)
	_production_command_result_cache.clear_peer(peer_id)
	_research_command_rate_buckets.erase(peer_id)
	_last_research_request_ids.erase(peer_id)


func reset_session_state() -> void:
	_warehouse_transaction_rate_buckets.clear()
	_warehouse_snapshot_request_rate_buckets.clear()
	_warehouse_transaction_result_cache.clear()
	_warehouse_transaction_started_usec.clear()
	_clear_pending_warehouse_snapshots()
	_pending_authoritative_warehouse_snapshots.clear()
	_production_command_rate_buckets.clear()
	_production_snapshot_request_rate_buckets.clear()
	_production_command_result_cache.clear()
	_pending_production_state_updates.clear()
	_clear_pending_remote_production_states()
	_shared_production_state_flush_scheduled = false
	_research_command_rate_buckets.clear()
	_last_research_request_ids.clear()
	_research_milestone_connected = false
	_removed_plant_ids.clear()
	_removed_plant_id_order.clear()


func _on_warehouse_storage_command_requested(
	command: Dictionary,
	warehouse: OakWarehouse
) -> void:
	if warehouse == null or not is_instance_valid(warehouse) or not is_bound():
		return
	var request_id := int(command.get("request_id", 0))
	if request_id > 0:
		_warehouse_transaction_started_usec[
			_get_warehouse_transaction_metric_key(
				int(command.get("warehouse_net_id", 0)),
				request_id
			)
		] = Time.get_ticks_usec()
	if _net_manager.is_host():
		handle_authoritative_warehouse_command(
			_net_manager.get_local_peer_id(),
			command
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_warehouse_command_requested", [command])


func _on_warehouse_storage_snapshot_requested(
	warehouse_net_id: int,
	warehouse: OakWarehouse
) -> void:
	if warehouse == null or not is_instance_valid(warehouse) or warehouse_net_id <= 0:
		return
	if _net_manager.is_host():
		warehouse.apply_storage_snapshot(warehouse.export_storage_snapshot())
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_warehouse_snapshot_requested",
			[warehouse_net_id]
		)


func _on_production_command_requested(
	command: Dictionary,
	building: ProductionBuilding
) -> void:
	if building == null or not is_instance_valid(building) or not is_bound():
		return
	if _net_manager.is_host():
		handle_authoritative_production_command(
			_net_manager.get_local_peer_id(),
			command
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_production_command_requested", [command])


func _on_production_snapshot_requested(
	building_net_id: int,
	building: ProductionBuilding
) -> void:
	if building == null or not is_instance_valid(building) or building_net_id <= 0:
		return
	if _net_manager.is_host():
		building.set_multiplayer_production_snapshot_ready(true)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(
			&"net_production_snapshot_requested",
			[building_net_id]
		)


func _on_research_command_requested(
	command: Dictionary,
	building: ResearchCenter
) -> void:
	if building == null or not is_instance_valid(building) or not is_bound():
		return
	if _net_manager.is_host():
		handle_authoritative_research_command(
			_net_manager.get_local_peer_id(),
			command
		)
	elif _net_manager.is_client():
		rpc_to_host_requested.emit(&"net_research_command_requested", [command])


func _on_authoritative_warehouse_storage_changed(warehouse: OakWarehouse) -> void:
	if not _is_host_bound() or warehouse == null or not is_instance_valid(warehouse):
		return
	var net_id := int(warehouse.get_meta("net_id", warehouse.warehouse_net_id))
	if net_id <= 0:
		return
	_pending_authoritative_warehouse_snapshots[net_id] = (
		warehouse.export_storage_snapshot()
	)
	_persist_authoritative_warehouse_snapshot(warehouse, net_id)
	_schedule_shared_production_state_flush()


func _on_authoritative_production_state_changed(
	replicate: bool,
	building: ProductionBuilding
) -> void:
	if (
		not replicate
		or not _is_host_bound()
		or building == null
		or not is_instance_valid(building)
	):
		return
	var net_id := int(building.get_meta("net_id", building.building_net_id))
	if net_id <= 0:
		return
	_pending_production_state_updates[net_id] = {
		"state": building.export_multiplayer_runtime_state(),
		"host_sample_time": _get_gameplay_net_time(),
	}
	_schedule_shared_production_state_flush()


func _on_authoritative_research_milestone_changed(player_key: int) -> void:
	if not _is_host_bound():
		return
	var current_xirang := -1
	if player_key > 0:
		var changed_player := _runtime.get_player_for_peer(player_key)
		if changed_player != null:
			current_xirang = changed_player.get_xirang()
	rpc_broadcast_requested.emit(
		&"net_research_state_updated",
		[
			_tower_adapter.get_research_runtime_state(),
			player_key,
			current_xirang,
		]
	)


func _schedule_shared_production_state_flush() -> void:
	if _shared_production_state_flush_scheduled:
		return
	_shared_production_state_flush_scheduled = true
	call_deferred(&"_flush_shared_production_network_state")


func _flush_shared_production_network_state() -> void:
	_shared_production_state_flush_scheduled = false
	if not is_inside_tree() or not _is_host_bound():
		_pending_authoritative_warehouse_snapshots.clear()
		_pending_production_state_updates.clear()
		return
	var warehouse_ids := _pending_authoritative_warehouse_snapshots.keys()
	warehouse_ids.sort()
	var warehouse_net_ids := PackedInt32Array()
	var warehouse_snapshots: Array = []
	for warehouse_id_variant in warehouse_ids:
		var warehouse_net_id := int(warehouse_id_variant)
		var snapshot := _pending_authoritative_warehouse_snapshots.get(
			warehouse_net_id,
			{}
		) as Dictionary
		if not snapshot.is_empty():
			warehouse_net_ids.append(warehouse_net_id)
			warehouse_snapshots.append(snapshot.duplicate(true))
	if not warehouse_net_ids.is_empty():
		rpc_broadcast_requested.emit(
			&"net_warehouse_storage_snapshot_batch",
			[warehouse_net_ids, warehouse_snapshots]
		)
	_pending_authoritative_warehouse_snapshots.clear()
	var production_ids := _pending_production_state_updates.keys()
	production_ids.sort()
	var offset := 0
	while offset < production_ids.size():
		var net_ids := PackedInt32Array()
		var states: Array = []
		var sample_times := PackedFloat64Array()
		var chunk_end := mini(
			offset + PRODUCTION_STATE_BATCH_MAX_BUILDINGS,
			production_ids.size()
		)
		for index in range(offset, chunk_end):
			var net_id := int(production_ids[index])
			var update := _pending_production_state_updates.get(net_id, {}) as Dictionary
			net_ids.append(net_id)
			states.append((update.get("state", {}) as Dictionary).duplicate(true))
			sample_times.append(float(update.get("host_sample_time", 0.0)))
		rpc_broadcast_requested.emit(
			&"net_production_state_batch",
			[net_ids, states, sample_times]
		)
		offset = chunk_end
	_pending_production_state_updates.clear()


func _apply_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> bool:
	if (
		not is_bound()
		or warehouse_net_ids.is_empty()
		or warehouse_net_ids.size() > CLIENT_PENDING_WAREHOUSE_SNAPSHOT_MAX_ENTRIES
		or snapshots.size() != warehouse_net_ids.size()
	):
		return false
	var previous_net_id := 0
	var active_net_ids := PackedInt32Array()
	var active_snapshots: Array = []
	for index in warehouse_net_ids.size():
		var warehouse_net_id := int(warehouse_net_ids[index])
		if warehouse_net_id <= previous_net_id or typeof(snapshots[index]) != TYPE_DICTIONARY:
			return false
		previous_net_id = warehouse_net_id
		var snapshot := snapshots[index] as Dictionary
		if not OakWarehouse.is_storage_snapshot_payload_valid(
			snapshot,
			warehouse_net_id
		):
			return false
		if _removed_plant_ids.has(warehouse_net_id):
			continue
		active_net_ids.append(warehouse_net_id)
		active_snapshots.append(snapshot)
	if active_net_ids.is_empty():
		return true
	if (
		not _pending_warehouse_snapshots.is_empty()
		or not _are_warehouse_snapshot_targets_available(active_net_ids)
	):
		if not _cache_pending_warehouse_snapshot_batch(
			active_net_ids,
			active_snapshots
		):
			return false
		try_apply_pending_warehouse_snapshots_atomically()
		return true
	return _commit_warehouse_storage_snapshot_batch(active_net_ids, active_snapshots)


func _are_warehouse_snapshot_targets_available(
	warehouse_net_ids: PackedInt32Array
) -> bool:
	for warehouse_net_id in warehouse_net_ids:
		var warehouse := _get_tower_plant(warehouse_net_id) as OakWarehouse
		if warehouse == null or not is_instance_valid(warehouse):
			return false
	return true


func _commit_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> bool:
	var warehouses: Array[OakWarehouse] = []
	warehouses.resize(warehouse_net_ids.size())
	for index in warehouse_net_ids.size():
		var warehouse_net_id := int(warehouse_net_ids[index])
		var warehouse := _get_tower_plant(warehouse_net_id) as OakWarehouse
		if warehouse == null or not is_instance_valid(warehouse):
			return false
		var already_configured := (
			warehouse.multiplayer_storage_enabled
			and warehouse.warehouse_net_id == warehouse_net_id
			and warehouse.multiplayer_storage_peer_id == _net_manager.get_local_peer_id()
		)
		if not already_configured:
			configure_warehouse_network(warehouse, false, false)
		warehouses[index] = warehouse
	return OakWarehouse.apply_storage_snapshot_batch(warehouses, snapshots)


func _cache_pending_warehouse_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> bool:
	var new_entry_count := 0
	for index in warehouse_net_ids.size():
		var warehouse_net_id := int(warehouse_net_ids[index])
		if _removed_plant_ids.has(warehouse_net_id):
			continue
		if not _pending_warehouse_snapshots.has(warehouse_net_id):
			new_entry_count += 1
			continue
		var previous_snapshot := _pending_warehouse_snapshots[warehouse_net_id] as Dictionary
		var next_snapshot := snapshots[index] as Dictionary
		if int(next_snapshot.get("revision", -1)) < int(previous_snapshot.get("revision", -1)):
			return false
	if (
		_pending_warehouse_snapshots.size() + new_entry_count
		> CLIENT_PENDING_WAREHOUSE_SNAPSHOT_MAX_ENTRIES
	):
		return false
	for index in warehouse_net_ids.size():
		_cache_pending_warehouse_snapshot(
			int(warehouse_net_ids[index]),
			snapshots[index] as Dictionary
		)
	return true


func _cache_pending_warehouse_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> void:
	if (
		warehouse_net_id <= 0
		or snapshot.is_empty()
		or _removed_plant_ids.has(warehouse_net_id)
	):
		return
	if _pending_warehouse_snapshots.has(warehouse_net_id):
		_pending_warehouse_snapshots[warehouse_net_id] = snapshot.duplicate(true)
		return
	if _pending_warehouse_snapshots.size() >= CLIENT_PENDING_WAREHOUSE_SNAPSHOT_MAX_ENTRIES:
		erase_pending_warehouse_snapshot(_pending_warehouse_snapshot_oldest_id)
	var previous_id := _pending_warehouse_snapshot_newest_id
	_pending_warehouse_snapshots[warehouse_net_id] = snapshot.duplicate(true)
	_pending_warehouse_snapshot_previous_ids[warehouse_net_id] = previous_id
	_pending_warehouse_snapshot_next_ids[warehouse_net_id] = 0
	if previous_id > 0:
		_pending_warehouse_snapshot_next_ids[previous_id] = warehouse_net_id
	else:
		_pending_warehouse_snapshot_oldest_id = warehouse_net_id
	_pending_warehouse_snapshot_newest_id = warehouse_net_id


func _canonicalize_research_command(
	raw_command: Dictionary,
	expected_peer_id: int
) -> Dictionary:
	if (
		expected_peer_id <= 0
		or typeof(raw_command.get("schema")) != TYPE_INT
		or int(raw_command["schema"]) != ResearchCenter.MULTIPLAYER_RESEARCH_COMMAND_SCHEMA
		or typeof(raw_command.get("request_id")) != TYPE_INT
		or int(raw_command["request_id"]) <= 0
		or typeof(raw_command.get("building_net_id")) != TYPE_INT
		or int(raw_command["building_net_id"]) <= 0
		or typeof(raw_command.get("peer_id")) != TYPE_INT
		or int(raw_command["peer_id"]) != expected_peer_id
	):
		return {}
	var operation_value: Variant = raw_command.get("operation")
	var research_id_value: Variant = raw_command.get("research_id")
	if (
		typeof(operation_value) not in [TYPE_STRING, TYPE_STRING_NAME]
		or typeof(research_id_value) not in [TYPE_STRING, TYPE_STRING_NAME]
	):
		return {}
	var operation_wire := String(operation_value)
	var research_id_wire := String(research_id_value)
	if (
		operation_wire not in ["global", "player"]
		or research_id_wire.length() > RESEARCH_COMMAND_WIRE_ID_MAX_LENGTH
		or (operation_wire == "player" and not research_id_wire.is_empty())
	):
		return {}
	return {
		"schema": ResearchCenter.MULTIPLAYER_RESEARCH_COMMAND_SCHEMA,
		"request_id": int(raw_command["request_id"]),
		"building_net_id": int(raw_command["building_net_id"]),
		"peer_id": expected_peer_id,
		"operation": operation_wire,
		"research_id": research_id_wire,
	}


func _is_authoritative_nearest_warehouse(
	player_node: Player,
	requested_warehouse: OakWarehouse
) -> bool:
	if player_node == null or not _is_authoritative_warehouse_interaction_candidate(requested_warehouse):
		return false
	if player_node.global_position.distance_squared_to(
		requested_warehouse.global_position
	) > BUILDING_INTERACTION_MAX_DISTANCE * BUILDING_INTERACTION_MAX_DISTANCE:
		return false
	return _find_authoritative_nearest_interaction_building(player_node) == requested_warehouse


func _is_authoritative_nearest_production_building(
	player_node: Player,
	requested_building: ProductionBuilding
) -> bool:
	return _is_authoritative_nearest_building(player_node, requested_building)


func _is_authoritative_nearest_research_center(
	player_node: Player,
	requested_building: ResearchCenter
) -> bool:
	return _is_authoritative_nearest_building(player_node, requested_building)


func _is_authoritative_nearest_building(
	player_node: Player,
	requested_building: PlantDefense
) -> bool:
	if (
		player_node == null
		or not PlantDefense.is_operational_interaction_candidate(requested_building)
		or not requested_building.is_player_within_multiplayer_interaction_distance(
			player_node,
			BUILDING_INTERACTION_MAX_DISTANCE
		)
	):
		return false
	return _find_authoritative_nearest_interaction_building(player_node) == requested_building


func _find_authoritative_nearest_interaction_building(
	player_node: Player
) -> PlantDefense:
	if player_node == null or not is_instance_valid(player_node) or not is_bound():
		return null
	return _tower_adapter.find_nearest_operational_interaction_building(
		player_node.global_position,
		BUILDING_INTERACTION_MAX_DISTANCE
	)


func _is_authoritative_warehouse_interaction_candidate(
	warehouse: OakWarehouse
) -> bool:
	return PlantDefense.is_operational_interaction_candidate(warehouse)


func _get_tower_plant(net_id: int) -> PlantDefense:
	if not is_bound() or net_id <= 0:
		return null
	return _tower_adapter.get_multiplayer_plant_node(net_id)


func _get_warehouse_transaction_metric_key(
	warehouse_net_id: int,
	request_id: int
) -> String:
	return "%d:%d" % [warehouse_net_id, request_id]


func _get_cached_warehouse_transaction_result(
	peer_id: int,
	warehouse_net_id: int,
	request_id: int
) -> Dictionary:
	if warehouse_net_id <= 0 or request_id <= 0:
		return {}
	return _warehouse_transaction_result_cache.get_result(
		peer_id,
		_get_warehouse_transaction_metric_key(warehouse_net_id, request_id)
	)


func _cache_warehouse_transaction_result(
	peer_id: int,
	warehouse_net_id: int,
	request_id: int,
	result: Dictionary
) -> void:
	if peer_id <= 0 or warehouse_net_id <= 0 or request_id <= 0:
		return
	_warehouse_transaction_result_cache.store_result(
		peer_id,
		_get_warehouse_transaction_metric_key(warehouse_net_id, request_id),
		result
	)


func _get_cached_production_command_result(
	peer_id: int,
	building_net_id: int,
	request_id: int
) -> Dictionary:
	if building_net_id <= 0 or request_id <= 0:
		return {}
	return _production_command_result_cache.get_result(
		peer_id,
		"%d:%d" % [building_net_id, request_id]
	)


func _cache_production_command_result(
	peer_id: int,
	building_net_id: int,
	request_id: int,
	result: Dictionary
) -> void:
	if peer_id <= 0 or building_net_id <= 0 or request_id <= 0:
		return
	_production_command_result_cache.store_result(
		peer_id,
		"%d:%d" % [building_net_id, request_id],
		result
	)


func _send_warehouse_command_result(peer_id: int, result: Dictionary) -> void:
	if peer_id == _net_manager.get_local_peer_id():
		receive_warehouse_command_result(result)
	elif _net_manager.is_peer_send_ready(peer_id):
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_warehouse_command_result",
			[result],
			false
		)


func _send_production_command_result(peer_id: int, result: Dictionary) -> void:
	if peer_id == _net_manager.get_local_peer_id():
		receive_production_command_result(result)
	elif _net_manager.is_peer_send_ready(peer_id):
		rpc_to_peer_requested.emit(
			peer_id,
			&"net_production_command_result",
			[result],
			false
		)


func _restore_authoritative_warehouse_from_ledger(
	warehouse: OakWarehouse,
	warehouse_net_id: int
) -> bool:
	if (
		not _is_host_bound()
		or warehouse == null
		or warehouse_net_id <= 0
	):
		return false
	var has_saved_snapshot := not _run_state.get_shared_warehouse_snapshot(
		warehouse_net_id
	).is_empty()
	if SharedWarehouseLedgerBridge.restore_from_ledger(
		_run_state,
		warehouse,
		warehouse_net_id
	):
		return true
	if has_saved_snapshot:
		push_warning(
			"MpTowerEconomyCoordinator: 无法恢复共享仓库 %d 的跨场景快照。"
			% warehouse_net_id
		)
	return false


func _persist_authoritative_warehouse_snapshot(
	warehouse: OakWarehouse,
	warehouse_net_id: int
) -> bool:
	if (
		not _is_host_bound()
		or warehouse == null
		or not is_instance_valid(warehouse)
		or warehouse_net_id <= 0
	):
		return false
	return SharedWarehouseLedgerBridge.persist_to_ledger(
		_run_state,
		warehouse,
		warehouse_net_id
	)


func _consume_peer_rate_token(
	buckets: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst: float
) -> bool:
	if peer_id <= 0 or rate_per_second <= 0.0 or burst <= 0.0:
		return false
	var now := _get_control_time()
	var bucket := buckets.get(peer_id, {}) as Dictionary
	if bucket.is_empty():
		bucket = {"tokens": burst, "last_time": now}
		buckets[peer_id] = bucket
	var tokens := minf(
		burst,
		float(bucket.get("tokens", burst))
		+ maxf(now - float(bucket.get("last_time", now)), 0.0) * rate_per_second
	)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _clear_pending_warehouse_snapshots() -> void:
	_pending_warehouse_snapshots.clear()
	_pending_warehouse_snapshot_previous_ids.clear()
	_pending_warehouse_snapshot_next_ids.clear()
	_pending_warehouse_snapshot_oldest_id = 0
	_pending_warehouse_snapshot_newest_id = 0


func _clear_pending_remote_production_states() -> void:
	_pending_remote_production_states.clear()
	_pending_remote_production_state_previous_ids.clear()
	_pending_remote_production_state_next_ids.clear()
	_pending_remote_production_state_oldest_id = 0
	_pending_remote_production_state_newest_id = 0


func _is_host_bound() -> bool:
	return is_bound() and _net_manager.is_host()


func _get_gameplay_net_time() -> float:
	return (
		GameplayPauseController.get_global_gameplay_time_seconds()
		- _net_time_origin
	)


func _get_control_time() -> float:
	return Time.get_ticks_msec() / 1000.0 - _net_time_origin
