extends MultiplayerGameplaySession

const _NetConstants := preload("res://scene/multiplayer/net_constants.gd")
const MpProjectileCoordinatorScript := preload(
	"res://scene/multiplayer/projectile/mp_projectile_coordinator.gd"
)
const MpWorldFlowCoordinatorScript := preload(
	"res://scene/multiplayer/world_flow/mp_world_flow_coordinator.gd"
)
const MpTowerEconomyCoordinatorScript := preload(
	"res://scene/multiplayer/tower_economy/mp_tower_economy_coordinator.gd"
)
const MpMerchantTransactionsCoordinatorScript := preload(
	"res://scene/multiplayer/merchant_transactions/mp_merchant_transactions_coordinator.gd"
)
const MpTowerFateCoordinatorScript := preload(
	"res://scene/multiplayer/tower_fate/mp_tower_fate_coordinator.gd"
)
const MpCollectiblePresentationCoordinatorScript := preload(
	"res://scene/multiplayer/collectible_presentation/mp_collectible_presentation_coordinator.gd"
)
const MpNetworkDiagnosticsCoordinatorScript := preload(
	"res://scene/multiplayer/network_diagnostics/mp_network_diagnostics_coordinator.gd"
)
const LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET := (
	MpProjectileCoordinatorScript.LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET
)
const CombatTargetIndexScript := preload("res://scene/combat_target_index.gd")
const INPUT_BUTTON_RELOAD := MpPlayerCoordinator.INPUT_BUTTON_RELOAD
const INPUT_BUTTON_DASH := MpPlayerCoordinator.INPUT_BUTTON_DASH
const TANGO_BARRAGE_MAXIMUM_SECONDS := MpPlayerCoordinator.TANGO_BARRAGE_MAXIMUM_SECONDS
const GAME_RUNTIME_HOST_AUTHORITY := 1
const GAME_RUNTIME_CLIENT_VIEW := 2
const STATE_DISCONNECTED := 0
const STATE_IN_GAME := 5
const INPUT_CHANGE_EPSILON := 0.001
const RECENT_EVENT_PRUNE_INTERVAL_SECONDS := 5.0
const CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE := 224.0
const FIRE_SORCERER_FIREBALL_VOLLEY_TYPE: StringName = (
	&"fire_sorcerer_fireball_volley"
)
const FIRE_SORCERER_ELITE_FIREBALL_VOLLEY_TYPE: StringName = (
	&"fire_sorcerer_elite_fireball_volley"
)
const FIRE_SLIME_TOUCH_TYPE: StringName = &"fire_slime_touch"
const LIGHTNING_SORCERER_CHAIN_MIN_POINTS := 2
const LIGHTNING_SORCERER_CHAIN_MAX_POINTS := 6
const TIYI_SNIPER_PROJECTILE_TYPE: StringName = &"tiyi_sniper_bullet"
const TANGO_LASER_PROJECTILE_TYPE: StringName = &"tango_laser_bullet"
# Application payload budget. Keep room for Godot RPC, ENet, UDP/IP headers before MTU pressure.
const HOST_STARTUP_SNAPSHOT_GRACE_SECONDS := 0.5
const COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS := 0.05
const ENEMY_TERMINAL_DEFEATED := 0
const ENEMY_TERMINAL_ESCAPED := 1
const ENEMY_TERMINAL_REMOVED := 2
# Multiplayer protocol map:
# - CH_AUTH: authentication, loading barrier, and complete-state repair.
# - CH_INPUT: client input and predicted pose reports.
# - CH_PLAYER_STATE / CH_ENEMY_STATE: independent realtime snapshots.
# - CH_PROJECTILE: projectile intents and replicated projectile presentation.
# - CH_WORLD_EVENT: durable spawn, terminal, plant, terrain, base, and flow events.
# - CH_TRANSACTION: inventory, Luoxi, economy, and shared-warehouse commands.
# - CH_FEEDBACK: discardable combat numbers, status visuals, and progress batches.
# Host owns enemy AI, player damage confirmation, death, revive, pickups, upgrades, and wave lifecycle.

@onready var net_manager: NetManagerStore = get_node("/root/NetManager") as NetManagerStore
@onready var run_state: RunStateStore = get_node("/root/RunState") as RunStateStore
@onready var session_coordinator: MpSessionCoordinator = $SessionCoordinator
@onready var player_coordinator: MpPlayerCoordinator = $PlayerCoordinator
@onready var enemy_coordinator: MpEnemyCoordinator = $EnemyCoordinator
@onready var projectile_coordinator: MpProjectileCoordinatorScript = $ProjectileCoordinator
@onready var world_flow_coordinator: MpWorldFlowCoordinatorScript = $WorldFlowCoordinator
@onready var transactions_coordinator: MpTransactionsCoordinator = $TransactionsCoordinator
@onready var tower_economy_coordinator: MpTowerEconomyCoordinatorScript = $TowerEconomyCoordinator
@onready var tower_world_coordinator: MpTowerWorldCoordinator = $TowerWorldCoordinator
@onready var merchant_transactions_coordinator: MpMerchantTransactionsCoordinatorScript = (
	$MerchantTransactionsCoordinator
)
@onready var tower_fate_coordinator: MpTowerFateCoordinatorScript = $TowerFateCoordinator
@onready var collectible_presentation_coordinator: MpCollectiblePresentationCoordinatorScript = (
	$CollectiblePresentationCoordinator
)
@onready var network_diagnostics_coordinator: MpNetworkDiagnosticsCoordinatorScript = (
	$NetworkDiagnosticsCoordinator
)
@onready var public_room_keepalive_request: HTTPRequest = $PublicRoomKeepaliveRequest

var game: CombatRuntimeBase = null
var _gameplay_gateway: MultiplayerGameplayGateway = null
var _mode_adapter: MultiplayerModeAdapter = null
var tower_mode_adapter: TowerDefenseMultiplayerModeAdapter = null
var _linglan_boss_runtime_port: LinglanBossRuntimePort = null
var input_sequence: int = 0
var _has_sent_input: bool = false
var _last_sent_move_input: Vector2 = Vector2.ZERO
var _last_sent_shoot_input: Vector2 = Vector2.ZERO
var _input_frames_since_last_send: int = _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
var _client_shoot_input_was_passive_tango_aim := false
var _last_tango_volley_visual_state_by_peer: Dictionary = {}
var _next_collectible_effect_event_id: int = 1
var _processed_collectible_effect_event_ids: Dictionary = {}
var _disconnected_player_reconnect_states: Dictionary[int, Dictionary] = {}
var _recent_event_prune_time_left: float = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
var _host_startup_snapshot_grace_time_left: float = 0.0
var _client_host_game_ready: bool = false
var _combat_feedback_flush_time_left: float = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
var _embedded_runtime_active := false
var _embedded_participant_peer_ids: Dictionary[int, bool] = {}
var _suspended_embedded_participant_peer_ids: Dictionary[int, bool] = {}


func _ready() -> void:
	session_coordinator.bind_transport_dependencies(
		net_manager,
		public_room_keepalive_request
	)
	player_coordinator.randomize_revive_generator()
	merchant_transactions_coordinator.randomize_offer_generator()
	if not enemy_coordinator.remote_enemy_spawned.is_connected(_on_remote_enemy_spawned):
		enemy_coordinator.remote_enemy_spawned.connect(_on_remote_enemy_spawned)
	if not enemy_coordinator.remote_enemy_escape_requested.is_connected(
		_on_remote_enemy_escape_requested
	):
		enemy_coordinator.remote_enemy_escape_requested.connect(
			_on_remote_enemy_escape_requested
		)
	_connect_world_flow_coordinator_signals()
	set_multiplayer_authority(_get_host_peer_id())
	if not net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.connect(_on_connection_state_changed)
	if not net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.connect(_on_net_player_left)
	if not net_manager.player_reconnected.is_connected(_on_net_player_reconnected):
		net_manager.player_reconnected.connect(_on_net_player_reconnected)
	if net_manager.is_host():
		if not _setup_game(GAME_RUNTIME_HOST_AUTHORITY):
			call_deferred("_return_to_lobby")
			return
		_host_startup_snapshot_grace_time_left = HOST_STARTUP_SNAPSHOT_GRACE_SECONDS
		_client_host_game_ready = true
	elif net_manager.is_client():
		if not _setup_game(GAME_RUNTIME_CLIENT_VIEW):
			call_deferred("_return_to_lobby")
			return
		_client_host_game_ready = bool(net_manager.get("host_game_ready"))
	else:
		push_warning("MpGame 启动时没有有效的多人连接，返回大厅。")
		call_deferred("_return_to_lobby")
		return
	if embedded_runtime:
		_client_host_game_ready = false
		_announce_embedded_runtime_when_prepared()
	else:
		_report_game_loaded_when_prepared()


func _connect_world_flow_coordinator_signals() -> void:
	var signal_bindings: Array[Array] = [
		[
			world_flow_coordinator.pickup_spawn_broadcast_requested,
			_on_world_flow_pickup_spawn_broadcast_requested,
		],
		[
			world_flow_coordinator.pickup_remove_broadcast_requested,
			_on_world_flow_pickup_remove_broadcast_requested,
		],
		[
			world_flow_coordinator.merchant_active_broadcast_requested,
			_on_world_flow_merchant_active_broadcast_requested,
		],
		[
			world_flow_coordinator.wave_progress_broadcast_requested,
			_on_world_flow_wave_progress_broadcast_requested,
		],
		[
			world_flow_coordinator.flow_state_broadcast_requested,
			_on_world_flow_state_broadcast_requested,
		],
		[
			world_flow_coordinator.boss_started_broadcast_requested,
			_on_world_flow_boss_started_broadcast_requested,
		],
		[
			world_flow_coordinator.defeat_broadcast_requested,
			_on_world_flow_defeat_broadcast_requested,
		],
		[
			world_flow_coordinator.victory_broadcast_requested,
			_on_world_flow_victory_broadcast_requested,
		],
		[
			world_flow_coordinator.terminal_flow_started,
			_clear_pending_player_revives,
		],
	]
	for binding in signal_bindings:
		var source: Signal = binding[0]
		var target: Callable = binding[1]
		if not source.is_connected(target):
			source.connect(target)


func _on_player_life_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_player_life_state_correction_requested(
	peer_id: int,
	corrected_position: Vector2,
	corrected_velocity: Vector2
) -> void:
	_record_outbound_rpc(
		&"net_player_state_corrected",
		[corrected_position, corrected_velocity]
	)
	net_player_state_corrected.rpc_id(
		peer_id,
		corrected_position,
		corrected_velocity
	)


func _on_player_action_rpc_to_host_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	if not net_manager.is_client():
		return
	_record_outbound_rpc(method_name, arguments)
	var rpc_arguments: Array = [_get_host_peer_id(), method_name]
	rpc_arguments.append_array(arguments)
	callv(&"rpc_id", rpc_arguments)


func _on_player_action_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	arguments: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_record_outbound_rpc(method_name, arguments)
	var rpc_arguments: Array = [peer_id, method_name]
	rpc_arguments.append_array(arguments)
	callv(&"rpc_id", rpc_arguments)


func _on_player_action_rpc_broadcast_requested(
	method_name: StringName,
	arguments: Array
) -> void:
	_rpc_to_connected_clients(method_name, arguments)


func _on_tiyi_high_noon_damage_requested(
	owner_player: PlayerTiyi,
	enemy_net_id: int,
	enemy: Enemy
) -> void:
	if (
		not net_manager.is_host()
		or owner_player == null
		or not is_instance_valid(owner_player)
		or enemy_net_id <= 0
		or enemy == null
		or not is_instance_valid(enemy)
		or enemy.is_dead
	):
		return
	var resolved_damage := owner_player.get_high_noon_damage_against_enemy(enemy)
	var impact_direction := -owner_player.global_position.direction_to(
		enemy.global_position
	)
	_apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		resolved_damage,
		impact_direction,
		EnemyConfig.DamageType.MAGIC,
		false
	)


func _exit_tree() -> void:
	if net_manager != null and net_manager.is_host():
		_capture_shared_warehouse_ledger()
	if net_manager != null and net_manager.connection_state_changed.is_connected(_on_connection_state_changed):
		net_manager.connection_state_changed.disconnect(_on_connection_state_changed)
	if net_manager != null and net_manager.player_left.is_connected(_on_net_player_left):
		net_manager.player_left.disconnect(_on_net_player_left)
	if (
		net_manager != null
		and net_manager.player_reconnected.is_connected(_on_net_player_reconnected)
	):
		net_manager.player_reconnected.disconnect(_on_net_player_reconnected)
	if game != null:
		if (
			_mode_adapter != null
			and _mode_adapter.return_to_lobby_requested.is_connected(
				_on_game_return_to_lobby_requested
			)
		):
			_mode_adapter.return_to_lobby_requested.disconnect(
				_on_game_return_to_lobby_requested
			)
		if _gameplay_gateway != null:
			_gameplay_gateway.detach_multiplayer_session(self)
		if _mode_adapter != null:
			_mode_adapter.detach_multiplayer_session(self)
		if session_coordinator != null:
			session_coordinator.unbind_runtime(game)
		if player_coordinator != null:
			player_coordinator.unbind_runtime(game)
		if enemy_coordinator != null:
			enemy_coordinator.unbind_runtime(game)
		if projectile_coordinator != null:
			projectile_coordinator.unbind_runtime(game)
		if world_flow_coordinator != null:
			world_flow_coordinator.unbind_runtime(game)
		if transactions_coordinator != null:
			transactions_coordinator.unbind_session(self)
		if tower_economy_coordinator != null:
			tower_economy_coordinator.unbind_runtime(game)
		if tower_world_coordinator != null:
			tower_world_coordinator.unbind_session(self)
		if merchant_transactions_coordinator != null:
			merchant_transactions_coordinator.unbind_runtime(game)
		if tower_fate_coordinator != null:
			tower_fate_coordinator.unbind_runtime(game)
		if collectible_presentation_coordinator != null:
			collectible_presentation_coordinator.unbind_runtime(game)
	else:
		if session_coordinator != null:
			session_coordinator.reset_session_state()
		if player_coordinator != null:
			player_coordinator.reset_session_state()
		if enemy_coordinator != null:
			enemy_coordinator.reset_session_state()
		if projectile_coordinator != null:
			projectile_coordinator.reset_session_state()
		if world_flow_coordinator != null:
			world_flow_coordinator.reset_session_state()
		if transactions_coordinator != null:
			transactions_coordinator.reset_session_state()
		if tower_economy_coordinator != null:
			tower_economy_coordinator.reset_session_state()
		if tower_world_coordinator != null:
			tower_world_coordinator.reset_session_state()
		if merchant_transactions_coordinator != null:
			merchant_transactions_coordinator.reset_session_state()
		if tower_fate_coordinator != null:
			tower_fate_coordinator.reset_session_state()
		if collectible_presentation_coordinator != null:
			collectible_presentation_coordinator.reset_session_state()
	_gameplay_gateway = null
	_mode_adapter = null
	tower_mode_adapter = null
	_linglan_boss_runtime_port = null
	if session_coordinator != null:
		session_coordinator.unbind_transport_dependencies()
	if tower_economy_coordinator != null:
		tower_economy_coordinator.reset_session_state()
	if tower_world_coordinator != null:
		tower_world_coordinator.reset_session_state()
	if merchant_transactions_coordinator != null:
		merchant_transactions_coordinator.reset_session_state()
	if tower_fate_coordinator != null:
		tower_fate_coordinator.reset_session_state()
	if collectible_presentation_coordinator != null:
		collectible_presentation_coordinator.reset_session_state()
	if network_diagnostics_coordinator != null:
		network_diagnostics_coordinator.reset_session_state()


func _physics_process(delta: float) -> void:
	if embedded_runtime and not _embedded_runtime_active:
		return
	if int(net_manager.connection_state) != STATE_IN_GAME:
		return
	_update_recent_event_cache_prune(delta)
	_update_snapshot_packet_warning_timer(delta)
	_update_batched_network_events(delta)
	var frame: int = net_manager.get_physics_frame_count()
	if net_manager.is_host():
		_update_authoritative_tango_charge_lifecycle()
		_host_physics_tick(frame, delta)
	elif net_manager.is_client():
		_client_physics_tick(frame)


func _report_game_loaded_when_prepared() -> void:
	if game == null:
		return
	if not game.is_runtime_preparation_complete():
		await game.runtime_preparation_completed
	if not is_inside_tree() or int(net_manager.connection_state) != 4:
		return
	net_manager.report_game_loaded()


func _announce_embedded_runtime_when_prepared() -> void:
	if game == null:
		return
	if not game.is_runtime_preparation_complete():
		await game.runtime_preparation_completed
	if not is_inside_tree() or not embedded_runtime:
		return
	embedded_runtime_prepared.emit()


func activate_embedded_runtime() -> bool:
	if (
		not embedded_runtime
		or _embedded_runtime_active
		or game == null
		or not game.is_runtime_preparation_complete()
		or int(net_manager.connection_state) != STATE_IN_GAME
	):
		return false
	_embedded_runtime_active = true
	_client_host_game_ready = true
	if net_manager.is_host():
		_host_startup_snapshot_grace_time_left = (
			HOST_STARTUP_SNAPSHOT_GRACE_SECONDS
		)
	game.activate_runtime()
	if net_manager.is_client():
		_request_runtime_state_from_host()
	return true


## Freezes the peer roster before an embedded combat runtime enters the tree.
## Route spectators share the multiplayer session but must never acquire combat
## players, snapshots, transactions, or settlement state from this MpGame.
func configure_embedded_participant_roster(
	peer_ids: PackedInt32Array
) -> bool:
	if not embedded_runtime or is_inside_tree() or peer_ids.is_empty():
		return false
	var next_roster: Dictionary[int, bool] = {}
	for peer_id in peer_ids:
		if peer_id <= 0 or next_roster.has(peer_id):
			return false
		next_roster[peer_id] = true
	_embedded_participant_peer_ids = next_roster
	return true


## Removes one connected peer from the current embedded battle without
## disconnecting it from the shared route session. This is used only when a
## late-reconnecting client cannot rebuild its local combat runtime; keeping a
## Player here would continue snapshots and transactions toward a route-only
## spectator that can no longer consume them.
func suspend_embedded_participant_for_current_combat(
	peer_id: int,
	previous_peer_id: int = -1
) -> bool:
	if not embedded_runtime or peer_id <= 0:
		return false
	# MpGame and the route coordinator receive the same reconnect signal. By the
	# time the coordinator performs a spectator downgrade, this roster may still
	# contain the old identity or may already have completed old -> new remapping.
	var roster_peer_id := -1
	if (
		previous_peer_id > 0
		and _embedded_participant_peer_ids.has(previous_peer_id)
	):
		roster_peer_id = previous_peer_id
	elif _embedded_participant_peer_ids.has(peer_id):
		roster_peer_id = peer_id
	if roster_peer_id <= 0:
		return false
	if roster_peer_id != peer_id:
		_embedded_participant_peer_ids.erase(roster_peer_id)
		_embedded_participant_peer_ids[peer_id] = true
		_suspended_embedded_participant_peer_ids.erase(roster_peer_id)
		_clear_peer_network_state(roster_peer_id)
	_suspended_embedded_participant_peer_ids[peer_id] = true
	_clear_peer_network_state(peer_id)
	if game != null:
		game.remove_multiplayer_player(peer_id)
	return true


func is_embedded_runtime_active() -> bool:
	return embedded_runtime and _embedded_runtime_active


func get_game_runtime() -> CombatRuntimeBase:
	return game


func is_runtime_preparation_complete() -> bool:
	return game != null and game.is_runtime_preparation_complete()


func get_runtime_preparation_progress() -> Dictionary:
	if game == null:
		return {"stage": "正在创建多人战场", "completed": 0, "total": 1}
	return game.get_runtime_preparation_progress()


func _process(delta: float) -> void:
	if embedded_runtime and not _embedded_runtime_active:
		return
	session_coordinator.update_transport(delta)
	if net_manager.is_client() or net_manager.is_host():
		_client_interpolate_entities()
	if net_manager.is_client() and game != null:
		tower_world_coordinator.update_client(delta)
		enemy_coordinator.update_proxy_visual_budget(delta)
		world_flow_coordinator.update_client_enemy_count()


func request_multiplayer_upgrade(stat_type: int) -> void:
	transactions_coordinator.request_upgrade(stat_type)


func request_multiplayer_inventory_item_use(slot_index: int) -> void:
	transactions_coordinator.request_inventory_item_use(slot_index)


func request_multiplayer_inventory_item_discard(slot_index: int) -> void:
	transactions_coordinator.request_inventory_item_discard(slot_index)


func request_multiplayer_simple_crafting(
	recipe_id: StringName,
	ui_request_token: int
) -> void:
	transactions_coordinator.request_simple_crafting(recipe_id, ui_request_token)


func cancel_multiplayer_simple_crafting_request(ui_request_token: int) -> void:
	transactions_coordinator.cancel_simple_crafting_request(ui_request_token)


func begin_inventory_building_placement(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> bool:
	if (
		not _has_tower_mode()
	):
		return false
	return tower_mode_adapter.begin_inventory_building_placement(
		slot_index,
		expected_inventory_revision
	)


func request_multiplayer_skill1_purchase() -> void:
	transactions_coordinator.request_skill1_purchase()


func _on_transaction_upgrade_request_to_host(stat_type: int) -> void:
	net_upgrade_selected.rpc_id(_get_host_peer_id(), stat_type)


func _on_transaction_inventory_item_use_request_to_host(
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	net_inventory_item_use_requested.rpc_id(
		_get_host_peer_id(),
		slot_index,
		expected_inventory_revision
	)


func _on_transaction_inventory_item_discard_request_to_host(
	slot_index: int,
	expected_inventory_revision: int
) -> void:
	net_inventory_item_discard_requested.rpc_id(
		_get_host_peer_id(),
		slot_index,
		expected_inventory_revision
	)


func _on_transaction_simple_crafting_request_to_host(
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
) -> void:
	net_simple_crafting_requested.rpc_id(
		_get_host_peer_id(),
		request_id,
		recipe_id,
		expected_inventory_revision
	)


func _on_transaction_skill1_purchase_request_to_host() -> void:
	net_skill1_purchase_requested.rpc_id(_get_host_peer_id())


func _on_transaction_upgrade_confirmation_broadcast_requested(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_upgrade_confirmed",
		[peer_id, stat_type, level, current_xirang, success, free_upgrade]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_upgrade_confirmation(
			peer_id,
			stat_type,
			level,
			current_xirang,
			success,
			free_upgrade
		)


func _on_transaction_inventory_item_used_broadcast_requested(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_inventory_item_used",
		[
			peer_id,
			slot_index,
			config_path,
			success,
			inventory_snapshot,
			force_inventory_repair,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_inventory_item_used(
			peer_id,
			slot_index,
			config_path,
			success,
			inventory_snapshot,
			force_inventory_repair
		)


func _on_transaction_inventory_item_discarded_broadcast_requested(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_inventory_item_discarded",
		[
			peer_id,
			slot_index,
			success,
			inventory_snapshot,
			force_inventory_repair,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_inventory_item_discarded(
			peer_id,
			slot_index,
			success,
			inventory_snapshot,
			force_inventory_repair
		)


func _on_transaction_simple_crafting_result_broadcast_requested(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result_code: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool
) -> void:
	_rpc_to_connected_clients(
		&"net_simple_crafting_result",
		[
			peer_id,
			request_id,
			recipe_id,
			result_code,
			inventory_snapshot,
			force_inventory_repair,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_simple_crafting_result(
			peer_id,
			request_id,
			recipe_id,
			result_code,
			inventory_snapshot,
			force_inventory_repair
		)


func _on_transaction_skill1_purchase_confirmation_broadcast_requested(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int,
	skill1_charge_duration: float
) -> void:
	_rpc_to_connected_clients(
		&"net_skill1_purchase_confirmed",
		[
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration,
		]
	)
	if peer_id == _get_local_peer_id():
		transactions_coordinator.receive_skill1_purchase_confirmation(
			peer_id,
			current_xirang,
			skill1_unlocked,
			result_code,
			skill1_upgrade_level,
			skill1_charge_duration
		)


func _on_tower_economy_rpc_to_host_requested(
	method_name: StringName,
	args: Array
) -> void:
	if not net_manager.is_client():
		return
	var rpc_args: Array = [_get_host_peer_id(), method_name]
	rpc_args.append_array(args)
	callv(&"rpc_id", rpc_args)


func _on_tower_economy_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array,
	record_outbound: bool
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	if record_outbound:
		_record_outbound_rpc(method_name, args)
	var rpc_args: Array = [peer_id, method_name]
	rpc_args.append_array(args)
	callv(&"rpc_id", rpc_args)


func _on_tower_economy_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func _on_tower_economy_inventory_snapshot_broadcast_requested(
	peer_id: int,
	snapshot: Dictionary
) -> void:
	_rpc_to_connected_clients(&"net_inventory_snapshot", [peer_id, snapshot])


func _on_tower_economy_plant_runtime_state_apply_requested(
	plant: PlantDefense,
	state: Dictionary,
	host_sample_time: float
) -> void:
	_apply_plant_runtime_state(plant, state, host_sample_time)


func _on_tower_economy_transaction_latency_observed(
	latency_ms: float
) -> void:
	network_diagnostics_coordinator.record_transaction_latency_ms(latency_ms)


func _on_merchant_transactions_rpc_to_host_requested(
	method_name: StringName,
	args: Array
) -> void:
	if not net_manager.is_client():
		return
	var rpc_args: Array = [_get_host_peer_id(), method_name]
	rpc_args.append_array(args)
	callv(&"rpc_id", rpc_args)


func _on_merchant_transactions_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_record_outbound_rpc(method_name, args)
	var rpc_args: Array = [peer_id, method_name]
	rpc_args.append_array(args)
	callv(&"rpc_id", rpc_args)


func _on_merchant_transactions_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func _on_tower_fate_rpc_to_host_requested(
	method_name: StringName,
	args: Array
) -> void:
	if not net_manager.is_client():
		return
	_record_outbound_rpc(method_name, args)
	var rpc_args: Array = [_get_host_peer_id(), method_name]
	rpc_args.append_array(args)
	callv(&"rpc_id", rpc_args)


func _on_tower_fate_rpc_to_peer_requested(
	peer_id: int,
	method_name: StringName,
	args: Array
) -> void:
	if peer_id <= 0 or not net_manager.is_host():
		return
	_record_outbound_rpc(method_name, args)
	var rpc_args: Array = [peer_id, method_name]
	rpc_args.append_array(args)
	callv(&"rpc_id", rpc_args)


func _on_tower_fate_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func _on_collectible_presentation_rpc_broadcast_requested(
	method_name: StringName,
	args: Array
) -> void:
	_rpc_to_connected_clients(method_name, args)


func request_multiplayer_start_wave() -> void:
	if not world_flow_coordinator.supports_wave_progress():
		return
	if net_manager.is_host():
		world_flow_coordinator.request_authoritative_wave_start(
			_get_local_peer_id()
		)
	else:
		net_tower_defense_start_wave_requested.rpc_id(_get_host_peer_id())


func _on_local_xiaocong_interaction_requested() -> void:
	tower_fate_coordinator.request_local_interaction()


func _on_local_xiaocong_vote_requested(
	option_id: StringName,
	permanent_buff_id: StringName
) -> void:
	tower_fate_coordinator.request_local_vote(option_id, permanent_buff_id)


func _on_local_xiaocong_collectible_requested(choice_index: int) -> void:
	tower_fate_coordinator.request_local_collectible_choice(choice_index)


func _is_valid_xiaocong_vote_payload(
	option_id: StringName,
	permanent_buff_id: StringName
) -> bool:
	return MpTowerFateCoordinatorScript.is_valid_vote_payload(
		option_id,
		permanent_buff_id
	)


func notify_local_player_dash_started(direction: Vector2, start_move_input: Vector2) -> void:
	player_coordinator.notify_local_player_dash_started(
		direction,
		start_move_input,
		_client_host_game_ready
	)


func request_hoe_primary_attack(direction: Vector2) -> bool:
	return player_coordinator.request_hoe_primary_attack(
		direction,
		_client_host_game_ready
	)


func request_hoe_whirlwind() -> bool:
	return player_coordinator.request_hoe_whirlwind(_client_host_game_ready)


func request_tango_electric_surge() -> bool:
	return player_coordinator.request_tango_electric_surge(
		_client_host_game_ready
	)


func spawn_authoritative_tango_electric_surge_field(
	owner_player: Player,
	activation_id: int,
	origin: Vector2
) -> bool:
	return player_coordinator.spawn_authoritative_tango_electric_surge_field(
		owner_player,
		activation_id,
		origin
	)


func spawn_remote_tango_electric_surge_visual_field(
	activation_id: int,
	origin: Vector2,
	remaining_seconds: float
) -> bool:
	return player_coordinator.spawn_remote_tango_electric_surge_visual_field(
		activation_id,
		origin,
		remaining_seconds
	)


func request_tango_charge_started(direction: Vector2) -> bool:
	return player_coordinator.request_tango_charge_started(
		direction,
		_client_host_game_ready
	)


func request_tango_charge_released(direction: Vector2) -> bool:
	return player_coordinator.request_tango_charge_released(
		direction,
		_client_host_game_ready
	)


func request_tango_charge_cancelled() -> bool:
	return player_coordinator.request_tango_charge_cancelled(
		_client_host_game_ready
	)


func request_tiyi_high_noon() -> bool:
	return player_coordinator.request_tiyi_high_noon(
		_client_host_game_ready
	)


func notify_tiyi_high_noon_targets_changed(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	player_coordinator.notify_tiyi_high_noon_targets_changed(
		peer_id,
		activation_id,
		target_ids
	)


func resolve_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	_hit_positions: PackedVector2Array
) -> void:
	player_coordinator.resolve_tiyi_high_noon(
		peer_id,
		activation_id,
		target_ids,
		_hit_positions
	)


func cancel_tiyi_high_noon(peer_id: int, activation_id: int) -> void:
	player_coordinator.cancel_tiyi_high_noon(peer_id, activation_id)


func uses_authoritative_luoxi_offers() -> bool:
	return merchant_transactions_coordinator.uses_authoritative_luoxi_offers()


func request_luoxi_collectible_offer() -> void:
	merchant_transactions_coordinator.request_luoxi_collectible_offer()


func request_luoxi_collectible_choice(
	choice_index: int,
	_legacy_config_path: String = "",
	offer_revision: int = 0
) -> void:
	merchant_transactions_coordinator.request_luoxi_collectible_choice(
		choice_index,
		offer_revision
	)


func request_luoxi_collectible_refresh(offer_revision: int = 0) -> void:
	merchant_transactions_coordinator.request_luoxi_collectible_refresh(
		offer_revision
	)


func request_luoxi_special_game_start() -> void:
	merchant_transactions_coordinator.request_luoxi_special_game_start()


func supports_luoxi_special_game() -> bool:
	return merchant_transactions_coordinator.supports_luoxi_special_game()


func request_luoxi_special_game_card_reveal(
	session_revision: int,
	card_index: int
) -> void:
	merchant_transactions_coordinator.request_luoxi_special_game_card_reveal(
		session_revision,
		card_index
	)


func request_luoxi_special_game_finish(session_revision: int) -> void:
	merchant_transactions_coordinator.request_luoxi_special_game_finish(
		session_revision
	)


func has_luoxi_collectible_claimed(peer_id: int) -> bool:
	return merchant_transactions_coordinator.has_luoxi_collectible_claimed(peer_id)


func broadcast_collectible_visual_effect(
	effect_type: StringName,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float
) -> void:
	collectible_presentation_coordinator.broadcast_visual_effect(
		effect_type,
		spawn_position,
		radius,
		color,
		duration
	)


func broadcast_collectible_follow_visual_effect(
	effect_type: StringName,
	owner_peer_id: int,
	radius: float,
	duration: float
) -> void:
	collectible_presentation_coordinator.broadcast_follow_visual_effect(
		effect_type,
		owner_peer_id,
		radius,
		duration
	)


func request_multiplayer_cheat_xirang() -> void:
	merchant_transactions_coordinator.request_cheat_xirang()


func request_debug_collectible(config_path: String) -> void:
	if merchant_transactions_coordinator == null:
		return
	merchant_transactions_coordinator.request_debug_collectible(config_path)


func _on_tower_world_plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	if not _has_tower_mode() or not net_manager.is_client():
		return
	net_plant_placement_requested.rpc_id(
		_get_host_peer_id(),
		request_id,
		plant_id,
		anchor
	)


func _on_tower_world_inventory_plant_placement_request_to_host(
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	if not _has_tower_mode() or not net_manager.is_client():
		return
	net_inventory_plant_placement_requested.rpc_id(
		_get_host_peer_id(),
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


func _on_tower_world_terrain_snapshot_request_to_host(known_revision: int) -> void:
	if not _has_tower_mode() or not net_manager.is_client():
		return
	net_terrain_snapshot_requested.rpc_id(_get_host_peer_id(), known_revision)


func _on_tower_world_base_health_send_requested(
	target_peer_id: int,
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	if target_peer_id > 0:
		net_base_health_changed.rpc_id(
			target_peer_id,
			current_health,
			maximum_health,
			revision
		)
		return
	_rpc_to_connected_clients(
		&"net_base_health_changed",
		[current_health, maximum_health, revision]
	)


func _on_tower_world_terrain_snapshot_chunk_send_requested(
	target_peer_id: int,
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host() or target_peer_id <= 0:
		return
	_record_outbound_rpc(
		&"net_terrain_snapshot_chunk",
		[
			snapshot_id,
			revision,
			chunk_index,
			chunk_count,
			cell_xy,
			terrain_types,
		]
	)
	net_terrain_snapshot_chunk.rpc_id(
		target_peer_id,
		snapshot_id,
		revision,
		chunk_index,
		chunk_count,
		cell_xy,
		terrain_types
	)


func _on_tower_world_terrain_delta_broadcast_requested(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_terrain_delta",
		[revision, cell_xy, terrain_types]
	)


func _on_tower_world_test_arena_manual_night_send_requested(
	target_peer_id: int,
	enabled: bool
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	if target_peer_id > 0:
		net_test_arena_manual_night_changed.rpc_id(target_peer_id, enabled)
		return
	_rpc_to_connected_clients(
		&"net_test_arena_manual_night_changed",
		[enabled]
	)


func _on_tower_world_plant_projectile_visual_broadcast_requested(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_plant_projectile_visual",
		[spawn_position, direction, speed, explosion_radius, lifetime]
	)


func _on_tower_world_bamboo_mortar_visual_batch_broadcast_requested(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_bamboo_mortar_visual_batch",
		[
			plant_net_ids,
			action_ids,
			stages,
			spawn_positions,
			landing_positions,
			committed_windup_durations,
			host_action_times,
		]
	)


func _on_tower_world_hydrangea_rain_visual_broadcast_requested(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_hydrangea_rain_visual",
		[plant_net_id, action_id, target_position, host_action_time]
	)


func _on_tower_world_corn_machine_gun_burst_batch_broadcast_requested(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_corn_machine_gun_burst_batch",
		[plant_net_ids, action_ids, directions, host_action_times]
	)


func _consume_peer_rate_token(
	buckets: Dictionary,
	peer_id: int,
	rate_per_second: float,
	burst: float,
	now_seconds: float = -1.0
) -> bool:
	if peer_id <= 0 or rate_per_second <= 0.0 or burst <= 0.0:
		return false
	var now := _get_net_time() if now_seconds < 0.0 else now_seconds
	var bucket: Dictionary
	if buckets.has(peer_id):
		bucket = buckets[peer_id] as Dictionary
	else:
		bucket = {"tokens": burst, "last_time": now}
		buckets[peer_id] = bucket
	var tokens := float(bucket.get("tokens", burst))
	var last_time := float(bucket.get("last_time", now))
	tokens = minf(burst, tokens + maxf(now - last_time, 0.0) * rate_per_second)
	var accepted := tokens >= 1.0
	if accepted:
		tokens -= 1.0
	# Mutate the per-peer state in place. Projectile requests can legitimately
	# reach hundreds per second, so replacing this Dictionary on every token would
	# turn the safety gate itself into a steady allocation hot path.
	bucket["tokens"] = tokens
	bucket["last_time"] = now
	return accepted


func _consume_remote_player_action_admission(
	peer_id: int,
	now_seconds: float = -1.0
) -> bool:
	return player_coordinator.consume_remote_player_action_admission(
		peer_id,
		now_seconds
	)


func _is_embedded_participant_suspended(peer_id: int) -> bool:
	return (
		embedded_runtime
		and _suspended_embedded_participant_peer_ids.has(peer_id)
	)


func _has_tower_mode() -> bool:
	return (
		tower_mode_adapter != null
		and is_instance_valid(tower_mode_adapter)
	)


func _get_tower_plant(net_id: int) -> PlantDefense:
	if not _has_tower_mode() or tower_world_coordinator == null:
		return null
	return tower_world_coordinator.get_plant(net_id)


func _get_tower_plant_snapshots() -> Array[Dictionary]:
	if not _has_tower_mode() or tower_world_coordinator == null:
		return []
	return tower_world_coordinator.build_live_plant_records()


func broadcast_plant_projectile_visual(
	plant_net_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	tower_world_coordinator.broadcast_plant_projectile_visual(
		plant_net_id,
		spawn_position,
		direction,
		speed,
		explosion_radius,
		lifetime
	)


func queue_bamboo_mortar_visual(
	plant_net_id: int,
	action_id: int,
	stage: int,
	spawn_position: Vector2,
	landing_position: Vector2,
	committed_windup_duration_seconds: float
) -> void:
	tower_world_coordinator.queue_bamboo_mortar_visual(
		plant_net_id,
		action_id,
		stage,
		spawn_position,
		landing_position,
		committed_windup_duration_seconds,
		_get_net_time()
	)


func queue_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	action_elapsed_seconds: float
) -> void:
	tower_world_coordinator.queue_hydrangea_rain_visual(
		plant_net_id,
		action_id,
		target_position,
		action_elapsed_seconds,
		_get_net_time()
	)


func queue_corn_machine_gun_burst_visual(
	plant_net_id: int,
	action_id: int,
	direction: Vector2
) -> void:
	tower_world_coordinator.queue_corn_machine_gun_burst_visual(
		plant_net_id,
		action_id,
		direction,
		_get_net_time()
	)


func apply_authoritative_plant_enemy_damage(
	damage_source_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	return tower_world_coordinator.apply_authoritative_plant_enemy_damage(
		damage_source_id,
		enemy,
		damage,
		impact_direction,
		damage_type
	)


func request_bamboo_mortar_target(
	owner: Node2D,
	minimum_range: float,
	maximum_range: float,
	callback: Callable
) -> bool:
	return tower_world_coordinator.request_bamboo_mortar_target(
		owner,
		minimum_range,
		maximum_range,
		callback
	)


func cancel_bamboo_mortar_target_request(owner: Node) -> void:
	tower_world_coordinator.cancel_bamboo_mortar_target_request(owner)


func select_bamboo_mortar_target_sync_for_fixture(
	center: Vector2,
	minimum_range: float,
	maximum_range: float
) -> Enemy:
	return tower_world_coordinator.select_bamboo_mortar_target_sync_for_fixture(
		center,
		minimum_range,
		maximum_range
	)


func queue_bamboo_mortar_explosion(
	landing_position: Vector2,
	inner_radius: float,
	outer_radius: float,
	inner_damage: int,
	outer_damage: int,
	damage_source_id: int
) -> bool:
	return tower_world_coordinator.queue_bamboo_mortar_explosion(
		landing_position,
		inner_radius,
		outer_radius,
		inner_damage,
		outer_damage,
		damage_source_id
	)


func apply_authoritative_plant_enemy_damage_batch(
	damage_source_id: int,
	enemy: Enemy,
	damage_amounts: PackedInt64Array,
	hit_counts: PackedInt32Array,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType
) -> bool:
	return tower_world_coordinator.apply_authoritative_plant_enemy_damage_batch(
		damage_source_id,
		enemy,
		damage_amounts,
		hit_counts,
		impact_direction,
		damage_type
	)


func get_bamboo_mortar_combat_metrics() -> Dictionary:
	return tower_world_coordinator.get_bamboo_mortar_combat_metrics()


func _configure_warehouse_network(
	plant: PlantDefense,
	snapshot_ready: bool,
	apply_pending_snapshots: bool = true
) -> void:
	tower_economy_coordinator.configure_warehouse_network(
		plant,
		snapshot_ready,
		apply_pending_snapshots
	)


func _configure_production_network(
	plant: PlantDefense,
	snapshot_ready: bool
) -> void:
	tower_economy_coordinator.configure_production_network(
		plant,
		snapshot_ready
	)


func _configure_research_network(plant: PlantDefense) -> void:
	tower_economy_coordinator.configure_research_network(plant)


func _capture_shared_warehouse_ledger() -> bool:
	return tower_economy_coordinator.capture_shared_warehouse_ledger()


func _broadcast_inventory_snapshot(peer_id: int) -> void:
	var snapshot := run_state.export_inventory_snapshot_for_peer(peer_id)
	_rpc_to_connected_clients(&"net_inventory_snapshot", [peer_id, snapshot])


func _on_host_multiplayer_inventory_changed(peer_id: int) -> void:
	if not net_manager.is_host() or peer_id <= 0:
		return
	_broadcast_inventory_snapshot(peer_id)


func _broadcast_warehouse_snapshot(warehouse: OakWarehouse) -> void:
	tower_economy_coordinator.broadcast_warehouse_snapshot(warehouse)



func is_client_view_runtime() -> bool:
	if game != null:
		return int(game.runtime_mode) == GAME_RUNTIME_CLIENT_VIEW
	return net_manager != null and net_manager.is_client()


func _setup_game(mode: int) -> bool:
	if embedded_runtime and _embedded_participant_peer_ids.is_empty():
		push_error("MpGame: 内嵌战斗缺少冻结的参战玩家名单。")
		return false
	var game_mode := int(net_manager.get("current_game_mode"))
	var game_scene_path := _get_game_scene_path_for_mode(game_mode)
	var game_scene := load(game_scene_path) as PackedScene
	if game_scene == null:
		push_error("MpGame: 无法加载所选多人游戏场景：%s" % game_scene_path)
		return false
	game = game_scene.instantiate() as CombatRuntimeBase
	if game == null:
		push_error("MpGame: 无法实例化所选多人游戏场景。")
		return false
	game.defer_runtime_activation()

	var local_peer_id: int = _get_local_peer_id()
	if local_peer_id <= 0 and net_manager.is_host():
		local_peer_id = _get_host_peer_id()
	if embedded_runtime and not _embedded_participant_peer_ids.has(local_peer_id):
		push_error("MpGame: 路线观战者不得创建内嵌战斗运行时。")
		_discard_unparented_game_runtime()
		return false
	var runtime_player_names := _filter_embedded_peer_map(
		net_manager.connected_players
	)
	var runtime_character_ids := _filter_embedded_peer_map(
		net_manager.call("get_player_character_map") as Dictionary
	)
	game.configure_multiplayer(
		mode,
		local_peer_id,
		runtime_player_names,
		runtime_character_ids
	)
	_gameplay_gateway = game.get_multiplayer_gameplay_gateway()
	_mode_adapter = game.get_multiplayer_mode_adapter()
	var gameplay_gateway := _gameplay_gateway
	var mode_adapter := _mode_adapter
	_linglan_boss_runtime_port = game.get_node_or_null(
		"LinglanBossRuntimePort"
	) as LinglanBossRuntimePort
	if gameplay_gateway == null or mode_adapter == null:
		push_error("MpGame: 运行时缺少静态 Multiplayer Gateway/ModeAdapter。")
		_discard_unparented_game_runtime()
		return false
	if not mode_adapter.accepts_game_mode_id(game_mode):
		push_error(
			"MpGame: 游戏模式 %d 与运行时 MultiplayerModeAdapter 不匹配。"
			% game_mode
		)
		_discard_unparented_game_runtime()
		return false
	if net_manager == null:
		push_error("MpGame: 多人协调器缺少强类型 NetManagerStore。")
		_discard_unparented_game_runtime()
		return false
	session_coordinator.bind_runtime(game)
	player_coordinator.bind_runtime(game)
	enemy_coordinator.bind_runtime(game)
	projectile_coordinator.bind_runtime(game)
	world_flow_coordinator.bind_runtime(
		game,
		mode_adapter,
		enemy_coordinator,
		gameplay_gateway
	)
	player_coordinator.bind_life_dependencies(
		net_manager,
		mode_adapter,
		projectile_coordinator,
		_get_net_time,
		_cancel_player_life_tango_for_revive_schedule,
		_cancel_player_life_actions_for_revive,
		_clear_player_life_tiyi_lifecycle_state,
		_get_player_life_revive_anchor_position,
		_commit_player_life_revive_position
	)
	player_coordinator.bind_player_action_dependencies(
		net_manager,
		_get_net_time,
		_is_embedded_participant_suspended
	)
	gameplay_gateway.attach_multiplayer_session(self)
	mode_adapter.attach_multiplayer_session(self)
	tower_mode_adapter = mode_adapter as TowerDefenseMultiplayerModeAdapter
	var tower_adapter := tower_mode_adapter
	transactions_coordinator.bind_session(
		self,
		game,
		mode_adapter,
		net_manager,
		run_state,
		_suspended_embedded_participant_peer_ids
	)
	merchant_transactions_coordinator.bind_runtime(
		game,
		mode_adapter,
		run_state,
		net_manager,
		session_coordinator.get_net_time_origin()
	)
	collectible_presentation_coordinator.bind_runtime(
		game,
		self,
		net_manager,
		session_coordinator.get_net_time_origin()
	)
	if tower_adapter != null:
		tower_economy_coordinator.bind_runtime(
			game,
			tower_adapter,
			run_state,
			net_manager,
			session_coordinator.get_net_time_origin()
		)
		tower_world_coordinator.bind_session(
			self,
			game,
			tower_adapter,
			net_manager,
			transactions_coordinator,
			enemy_coordinator
		)
		tower_fate_coordinator.bind_runtime(
			game,
			tower_adapter,
			net_manager,
			session_coordinator.get_net_time_origin()
		)
	else:
		tower_economy_coordinator.reset_session_state()
		tower_world_coordinator.reset_session_state()
		tower_fate_coordinator.reset_session_state()
	if net_manager.is_host():
		gameplay_gateway.enemy_spawned.connect(_on_host_enemy_spawned)
		gameplay_gateway.enemy_defeated.connect(_on_host_enemy_defeated)
		gameplay_gateway.enemy_removed.connect(_on_host_enemy_removed)
		gameplay_gateway.enemy_escaped.connect(_on_host_enemy_escaped)
		gameplay_gateway.pickup_collected.connect(_on_host_pickup_collected)
		if _linglan_boss_runtime_port != null:
			_linglan_boss_runtime_port.airdrop_started.connect(
				_on_host_linglan_airdrop_started
			)
		mode_adapter.revive_all_requested.connect(_on_host_revive_all_requested)
		gameplay_gateway.player_teleport_requested.connect(
			_on_host_player_teleport_requested
		)
		if tower_adapter != null:
			tower_adapter.xiaocong_fate_state_changed.connect(
				_on_host_xiaocong_fate_state_changed
			)
			tower_adapter.inventory_changed.connect(
				_on_host_multiplayer_inventory_changed
			)
	mode_adapter.profile_upgrade_requested.connect(
		request_multiplayer_upgrade
	)
	mode_adapter.profile_inventory_item_use_requested.connect(
		request_multiplayer_inventory_item_use
	)
	mode_adapter.profile_inventory_item_discard_requested.connect(
		request_multiplayer_inventory_item_discard
	)
	mode_adapter.profile_simple_crafting_requested.connect(
		request_multiplayer_simple_crafting
	)
	mode_adapter.profile_simple_crafting_cancel_requested.connect(
		cancel_multiplayer_simple_crafting_request
	)
	if tower_adapter != null:
		tower_adapter.xiaocong_interaction_requested.connect(
			_on_local_xiaocong_interaction_requested
		)
		tower_adapter.xiaocong_vote_requested.connect(
			_on_local_xiaocong_vote_requested
		)
		tower_adapter.xiaocong_collectible_requested.connect(
			_on_local_xiaocong_collectible_requested
		)
	mode_adapter.return_to_lobby_requested.connect(
		_on_game_return_to_lobby_requested
	)
	add_child(game)
	run_state.set_active_multiplayer_peer(local_peer_id)
	if net_manager.is_host() and _has_tower_mode():
		tower_world_coordinator.broadcast_base_health_snapshot()
	return true


func _discard_unparented_game_runtime() -> void:
	if game != null and merchant_transactions_coordinator != null:
		merchant_transactions_coordinator.unbind_runtime(game)
	if game != null and tower_fate_coordinator != null:
		tower_fate_coordinator.unbind_runtime(game)
	if game != null and collectible_presentation_coordinator != null:
		collectible_presentation_coordinator.unbind_runtime(game)
	if game != null and tower_economy_coordinator != null:
		tower_economy_coordinator.unbind_runtime(game)
	if game != null and world_flow_coordinator != null:
		world_flow_coordinator.unbind_runtime(game)
	if game != null and session_coordinator != null:
		session_coordinator.unbind_runtime(game)
	if game != null and player_coordinator != null:
		player_coordinator.unbind_runtime(game)
	if game != null and enemy_coordinator != null:
		enemy_coordinator.unbind_runtime(game)
	if game != null and projectile_coordinator != null:
		projectile_coordinator.unbind_runtime(game)
	if transactions_coordinator != null:
		transactions_coordinator.unbind_session(self)
	if tower_world_coordinator != null:
		tower_world_coordinator.unbind_session(self)
	if game != null and is_instance_valid(game) and game.get_parent() == null:
		game.free()
	game = null
	_gameplay_gateway = null
	_mode_adapter = null
	tower_mode_adapter = null
	_linglan_boss_runtime_port = null


func _get_game_scene_path_for_mode(game_mode: int) -> String:
	if not runtime_scene_path_override.strip_edges().is_empty():
		return runtime_scene_path_override
	var definition := GameModeCatalog.get_definition(game_mode)
	return definition.multiplayer_runtime_scene_path if definition != null else ""


func _request_runtime_state_from_host() -> void:
	if not session_coordinator.try_begin_client_runtime_state_request(
		net_manager.is_client(),
		_client_host_game_ready
	):
		return
	tower_world_coordinator.begin_runtime_state_request()
	net_runtime_state_requested.rpc_id(
		_get_host_peer_id(),
		not world_flow_coordinator.has_received_flow_state()
	)


func _send_runtime_state_to_peer(peer_id: int, include_flow_state: bool) -> void:
	if not net_manager.is_host() or game == null or peer_id <= 0:
		return
	if net_manager.has_method("is_peer_send_ready"):
		if not bool(net_manager.call("is_peer_send_ready", peer_id)):
			return
	network_diagnostics_coordinator.record_state_repair()
	tower_world_coordinator.request_terrain_snapshot_for_peer(peer_id)
	_send_live_plant_roster_to_peer(peer_id)
	for state_peer_id_variant in game.peer_players.keys():
		var state_peer_id := int(state_peer_id_variant)
		if state_peer_id <= 0 or not run_state.has_multiplayer_peer_state(state_peer_id):
			continue
		net_inventory_snapshot.rpc_id(
			peer_id,
			state_peer_id,
			run_state.export_inventory_snapshot_for_peer(state_peer_id),
			true
		)
	merchant_transactions_coordinator.send_offer_state_if_present(peer_id)
	_send_live_enemy_roster_to_peer(peer_id)
	_send_live_pickup_roster_to_peer(peer_id)
	if _has_tower_mode():
		tower_world_coordinator.request_base_health_snapshot_for_peer(peer_id)
	var progress_snapshot := world_flow_coordinator.get_wave_progress_snapshot()
	if not progress_snapshot.is_empty():
		net_tower_defense_wave_progress_keyframe.rpc_id(
			peer_id,
			int(progress_snapshot.get("wave_number", 1)),
			int(progress_snapshot.get("defeated", 0)),
			int(progress_snapshot.get("escaped", 0)),
			int(progress_snapshot.get("resolved", 0)),
			int(progress_snapshot.get("total", 0))
		)
	if _has_tower_mode():
		tower_fate_coordinator.send_fate_state_to_peer(peer_id)
		if tower_mode_adapter.is_fate_interlude_active():
			_send_authoritative_player_positions_to_peer(peer_id)
	if _has_tower_mode():
		tower_world_coordinator.request_test_arena_manual_night_for_peer(
			peer_id
		)
	if include_flow_state:
		var flow_snapshot := world_flow_coordinator.get_flow_state_snapshot()
		if not flow_snapshot.is_empty():
			net_flow_state_changed.rpc_id(
				peer_id,
				String(flow_snapshot.get("step_id", &"")),
				int(flow_snapshot.get("state", CombatFlowState.State.PRE_WAVE)),
				int(flow_snapshot.get("countdown_seconds", 0))
			)
	player_coordinator.send_active_tango_electric_surges_to_peer(peer_id)
	player_coordinator.send_active_tiyi_high_noon_to_peer(peer_id)
	_send_runtime_world_manifest_to_peer(peer_id)


func _send_authoritative_player_positions_to_peer(target_peer_id: int) -> void:
	if game == null or target_peer_id <= 0:
		return
	for state_peer_id_variant in game.peer_players.keys():
		var state_peer_id := int(state_peer_id_variant)
		var player_node := game.get_player_for_peer(state_peer_id)
		if (
			state_peer_id <= 0
			or player_node == null
			or not is_instance_valid(player_node)
		):
			continue
		net_player_authoritative_teleported.rpc_id(
			target_peer_id,
			state_peer_id,
			player_node.global_position,
			player_coordinator.get_host_snapshot_sequence()
		)


func _send_live_plant_roster_to_peer(peer_id: int) -> void:
	if not _has_tower_mode():
		return
	var warehouse_snapshots_by_net_id: Dictionary = {}
	for plant_snapshot in _get_tower_plant_snapshots():
		var plant_net_id := int(plant_snapshot.get("net_id", 0))
		var plant := _get_tower_plant(plant_net_id)
		_configure_warehouse_network(plant, true)
		_configure_production_network(plant, true)
		_configure_research_network(plant)
		var runtime_state := _export_plant_runtime_state(plant)
		var host_sample_time := _get_net_time()
		net_plant_spawned.rpc_id(
			peer_id,
			0,
			int(plant_snapshot.get("owner_peer_id", 0)),
			plant_net_id,
			String(plant_snapshot.get("plant_id", &"")),
			plant_snapshot.get("anchor", Vector2i.ZERO) as Vector2i,
			int(plant_snapshot.get("current_health", 0)),
			int(plant_snapshot.get("maximum_health", 1)),
			int(plant_snapshot.get("health_revision", 0)),
			runtime_state,
			host_sample_time
		)
		var warehouse := plant as OakWarehouse
		if warehouse != null and is_instance_valid(warehouse):
			warehouse_snapshots_by_net_id[plant_net_id] = (
				warehouse.export_storage_snapshot()
			)
	var warehouse_ids := warehouse_snapshots_by_net_id.keys()
	warehouse_ids.sort()
	if not warehouse_ids.is_empty():
		var warehouse_net_ids := PackedInt32Array()
		var warehouse_snapshots: Array = []
		for warehouse_id_variant in warehouse_ids:
			var warehouse_net_id := int(warehouse_id_variant)
			warehouse_net_ids.append(warehouse_net_id)
			warehouse_snapshots.append(
				warehouse_snapshots_by_net_id[warehouse_net_id]
			)
		_record_outbound_rpc(
			&"net_warehouse_storage_snapshot_batch",
			[warehouse_net_ids, warehouse_snapshots]
		)
		net_warehouse_storage_snapshot_batch.rpc_id(
			peer_id,
			warehouse_net_ids,
			warehouse_snapshots
		)
	if _has_tower_mode():
		net_research_state_updated.rpc_id(
			peer_id,
			tower_mode_adapter.get_research_runtime_state(),
			0,
			-1
		)


func _send_live_enemy_roster_to_peer(peer_id: int) -> void:
	for batch in enemy_coordinator.build_live_spawn_batches(_get_net_time()):
		_record_outbound_rpc(
			&"net_enemy_spawned_batch",
			[batch.net_ids, batch.config_paths, batch.positions, batch.spawn_times]
		)
		net_enemy_spawned_batch.rpc_id(
			peer_id,
			batch.net_ids,
			batch.config_paths,
			batch.positions,
			batch.spawn_times
		)


func _send_live_pickup_roster_to_peer(peer_id: int) -> void:
	for record in world_flow_coordinator.build_live_pickup_records():
		var net_id := int(record.get("net_id", 0))
		var config_path := String(record.get("config_path", ""))
		var spawn_position := record.get("position", Vector2.ZERO) as Vector2
		_record_outbound_rpc(
			&"net_pickup_spawned",
			[
				net_id,
				config_path,
				spawn_position.x,
				spawn_position.y,
			]
		)
		net_pickup_spawned.rpc_id(
			peer_id,
			net_id,
			config_path,
			spawn_position.x,
			spawn_position.y
		)


func _send_runtime_world_manifest_to_peer(peer_id: int) -> void:
	var live_enemy_ids := PackedInt32Array()
	var live_pickup_ids := PackedInt32Array()
	var live_plant_ids := PackedInt32Array()
	var sorted_enemy_ids: Array[int] = []
	for net_id_variant in game.multiplayer_enemies_by_net_id.keys():
		sorted_enemy_ids.append(int(net_id_variant))
	sorted_enemy_ids.sort()
	for net_id in sorted_enemy_ids:
		var enemy_variant: Variant = game.multiplayer_enemies_by_net_id.get(net_id)
		if enemy_variant == null or not is_instance_valid(enemy_variant):
			continue
		var enemy := enemy_variant as Enemy
		if enemy != null and is_instance_valid(enemy) and not enemy.is_dead:
			live_enemy_ids.append(net_id)
	var sorted_pickup_ids: Array[int] = []
	for net_id_variant in game.multiplayer_pickups.keys():
		sorted_pickup_ids.append(int(net_id_variant))
	sorted_pickup_ids.sort()
	for net_id in sorted_pickup_ids:
		var pickup_variant: Variant = game.multiplayer_pickups.get(net_id)
		if pickup_variant == null or not is_instance_valid(pickup_variant):
			continue
		var pickup := pickup_variant as Pickup
		if pickup != null and is_instance_valid(pickup):
			live_pickup_ids.append(net_id)
	if _has_tower_mode():
		live_plant_ids = tower_world_coordinator.build_live_plant_ids()
	_record_outbound_rpc(
		&"net_runtime_world_manifest",
		[live_enemy_ids, live_pickup_ids, live_plant_ids]
	)
	net_runtime_world_manifest.rpc_id(
		peer_id,
		live_enemy_ids,
		live_pickup_ids,
		live_plant_ids
	)


func _host_physics_tick(frame: int, _delta: float) -> void:
	if game == null:
		return
	player_coordinator.update_player_revives()
	if _host_startup_snapshot_grace_time_left > 0.0:
		_host_startup_snapshot_grace_time_left = maxf(
			_host_startup_snapshot_grace_time_left - _delta,
			0.0
		)
		return
	var client_peer_ids := _get_connected_client_peer_ids()
	_sync_snapshot_cohort_readiness(client_peer_ids)
	if frame % _NetConstants.PLAYER_SNAPSHOT_INTERVAL_FRAMES == 0:
		_host_broadcast_player_snapshots(client_peer_ids)
	var enemy_snapshot_interval_frames := _get_enemy_snapshot_interval_frames()
	if frame % enemy_snapshot_interval_frames == 0:
		_host_broadcast_enemy_snapshots(client_peer_ids)
	_flush_pending_enemy_spawns()


func _get_enemy_snapshot_interval_frames() -> int:
	return enemy_coordinator.get_snapshot_interval_frames()


func _host_broadcast_player_snapshots(client_peer_ids: Array[int] = []) -> void:
	if client_peer_ids.is_empty():
		client_peer_ids = _get_connected_client_peer_ids()
		_sync_snapshot_cohort_readiness(client_peer_ids)
	if client_peer_ids.is_empty():
		return
	var states: Array[SnapshotManager.PlayerState] = game.collect_player_snapshot_states()
	if states.is_empty():
		return
	var snapshot_time := _get_net_time()
	player_coordinator.apply_authoritative_tango_charge_snapshot_ratios(
		states,
		snapshot_time
	)
	var batch := player_coordinator.build_host_snapshot_batch(
		states,
		client_peer_ids,
		snapshot_time,
		player_coordinator.get_health_revisions_for_snapshot()
	)
	if batch == null or batch.is_empty():
		return
	for peer_id in batch.peer_ids:
		_record_snapshot_packet_size(
			&"player",
			batch.data.size(),
			batch.entity_count
		)
		_rpc_receive_player_snapshot.rpc_id(
			peer_id,
			batch.host_timestamp,
			batch.data
		)
func _host_broadcast_enemy_snapshots(client_peer_ids: Array[int] = []) -> void:
	if client_peer_ids.is_empty():
		client_peer_ids = _get_connected_client_peer_ids()
		_sync_snapshot_cohort_readiness(client_peer_ids)
	if client_peer_ids.is_empty():
		return
	var states: Array[SnapshotManager.EnemyState] = game.collect_enemy_snapshot_states()
	var batch := enemy_coordinator.build_host_snapshot_batch(
		states,
		client_peer_ids,
		_get_net_time()
	)
	if batch == null or batch.is_empty():
		return
	for chunk in batch.chunks:
		for peer_id in batch.peer_ids:
			_record_snapshot_packet_size(&"enemy", chunk.data.size(), chunk.entity_count)
			_rpc_receive_enemy_snapshot.rpc_id(
				peer_id,
				batch.host_timestamp,
				chunk.data,
				batch.batch_id,
				chunk.chunk_index,
				batch.chunk_count,
				batch.snapshot_hz
			)


func _sync_snapshot_cohort_readiness(ready_peer_ids: Array[int]) -> void:
	player_coordinator.sync_snapshot_cohort_readiness(ready_peer_ids)
	enemy_coordinator.sync_snapshot_cohort_readiness(ready_peer_ids)


func _get_connected_client_peer_ids() -> Array[int]:
	var result: Array[int] = []
	if net_manager == null:
		return result
	var connected_players := net_manager.get("connected_players") as Dictionary
	var host_peer_id := _get_host_peer_id()
	for peer_id_variant in connected_players:
		var peer_id := int(peer_id_variant)
		if peer_id <= 0 or peer_id == host_peer_id:
			continue
		if embedded_runtime and not _embedded_participant_peer_ids.has(peer_id):
			continue
		if (
			embedded_runtime
			and _suspended_embedded_participant_peer_ids.has(peer_id)
		):
			continue
		if (
			embedded_runtime
			and (
				game == null
				or game.get_player_for_peer(peer_id) == null
			)
		):
			continue
		if (
			net_manager.has_method("is_peer_send_ready")
			and not bool(net_manager.call("is_peer_send_ready", peer_id))
		):
			continue
		result.append(peer_id)
	return result


func _filter_embedded_peer_map(source: Dictionary) -> Dictionary:
	if not embedded_runtime:
		return source
	var filtered: Dictionary = {}
	for peer_id in _embedded_participant_peer_ids:
		if source.has(peer_id):
			filtered[peer_id] = source[peer_id]
	return filtered


# The coordinator first creates this stable RPC path on every participant,
# then opens its prepare/activate barrier. StandardGame._ready() can emit merchant or
# inventory signals before that barrier; suppress those transient packets so
# they never target a client path that has not been created yet. Activation's
# runtime-state request repairs every authoritative state channel.
func _rpc_to_connected_clients(method_name: StringName, args: Array = []) -> void:
	if embedded_runtime and not _embedded_runtime_active:
		return
	var peer_ids := _get_connected_client_peer_ids()
	for peer_id in peer_ids:
		var rpc_args: Array = [peer_id, method_name]
		rpc_args.append_array(args)
		callv("rpc_id", rpc_args)
	if not peer_ids.is_empty():
		_record_outbound_rpc(method_name, args, peer_ids.size())


func _record_outbound_rpc(
	method_name: StringName,
	args: Array,
	packet_count: int = 1
) -> void:
	_get_network_diagnostics_coordinator().record_outbound_rpc(
		method_name,
		args,
		packet_count
	)


func set_rpc_payload_diagnostics_enabled(enabled: bool) -> void:
	_get_network_diagnostics_coordinator().set_rpc_payload_diagnostics_enabled(enabled)


func _get_rpc_traffic_channel(method_name: StringName) -> int:
	return MpNetworkDiagnosticsCoordinatorScript.get_rpc_traffic_channel(method_name)


func _update_snapshot_packet_warning_timer(delta: float) -> void:
	_get_network_diagnostics_coordinator().update_snapshot_packet_warning_timer(delta)


func _record_snapshot_packet_size(
	snapshot_type: StringName,
	packet_bytes: int,
	entity_count: int
) -> void:
	_get_network_diagnostics_coordinator().record_snapshot_packet_size(
		snapshot_type,
		packet_bytes,
		entity_count
	)


func get_snapshot_packet_metrics() -> Dictionary:
	var enemy_metrics := enemy_coordinator.get_snapshot_metrics()
	var pool_metrics: Dictionary = {}
	if game != null:
		var object_pool := game.get_node_or_null("SessionObjectPool") as SessionObjectPool
		if object_pool != null:
			pool_metrics = object_pool.get_all_metrics()
	return _get_network_diagnostics_coordinator().get_snapshot_packet_metrics(
		player_coordinator.get_snapshot_encode_count(),
		player_coordinator.get_snapshot_cohort_size(),
		enemy_metrics,
		pool_metrics
	)


func _get_network_diagnostics_coordinator() -> MpNetworkDiagnosticsCoordinatorScript:
	if network_diagnostics_coordinator != null:
		return network_diagnostics_coordinator
	# Packed-scene contract tests may call diagnostics before _ready assigns the
	# cached @onready reference. The fixed NodePath still enforces static assembly.
	return get_node(^"NetworkDiagnosticsCoordinator") as MpNetworkDiagnosticsCoordinatorScript


func _client_physics_tick(frame: int) -> void:
	if not _client_host_game_ready:
		return
	_input_frames_since_last_send += 1
	var buttons := 0
	if Input.is_action_just_pressed("reload"):
		buttons |= INPUT_BUTTON_RELOAD
	if player_coordinator.has_pending_dash_input_packet():
		buttons |= INPUT_BUTTON_DASH
	if frame % _NetConstants.INPUT_SEND_INTERVAL_FRAMES == 0 or buttons != 0:
		_client_send_input_if_needed(buttons)
		if (buttons & INPUT_BUTTON_DASH) != 0:
			player_coordinator.consume_pending_dash_input_packet()


func _client_send_input_if_needed(buttons: int) -> void:
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var player_node: Player = null
	if game != null:
		player_node = game.player
	if player_node == null:
		return
	_client_shoot_input_was_passive_tango_aim = false
	var shoot_input := (
		Vector2.ZERO
		if player_node.are_combat_actions_locked()
		else _get_client_shoot_input()
	)
	var uses_passive_tango_mouse_aim := _client_shoot_input_was_passive_tango_aim
	if player_node.are_combat_actions_locked():
		buttons &= ~INPUT_BUTTON_RELOAD
	if player_node.is_dead:
		_last_sent_move_input = Vector2.ZERO
		_last_sent_shoot_input = Vector2.ZERO
		return
	var input_changed := (
		not _has_sent_input
		or move_input.distance_squared_to(_last_sent_move_input) > INPUT_CHANGE_EPSILON
		or shoot_input.distance_squared_to(_last_sent_shoot_input) > INPUT_CHANGE_EPSILON
	)
	var keepalive_due := (
		_input_frames_since_last_send >= _NetConstants.INPUT_KEEPALIVE_INTERVAL_FRAMES
	)
	var active_input_state := _is_client_input_state_active(
		move_input,
		shoot_input,
		player_node.velocity,
		uses_passive_tango_mouse_aim
	)
	if not input_changed and not keepalive_due and buttons == 0 and not active_input_state:
		return
	input_sequence += 1
	_has_sent_input = true
	_last_sent_move_input = move_input
	_last_sent_shoot_input = shoot_input
	_input_frames_since_last_send = 0
	_rpc_client_player_state.rpc_id(
		_get_host_peer_id(),
		input_sequence,
		player_node.global_position,
		player_node.velocity,
		move_input,
		shoot_input,
		buttons,
		player_coordinator.get_pending_dash_request_sequence(),
		player_coordinator.get_pending_dash_direction(),
		player_coordinator.get_pending_dash_start_move_input()
	)


func _get_client_shoot_input() -> Vector2:
	var shoot_input := Input.get_vector("shoot_left", "shoot_right", "shoot_up", "shoot_down")
	if shoot_input != Vector2.ZERO:
		return shoot_input
	if game == null or game.player == null:
		return Vector2.ZERO
	var uses_passive_tango_mouse_aim := _uses_passive_tango_mouse_aim(game.player)
	if (
		not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		and not uses_passive_tango_mouse_aim
	):
		return Vector2.ZERO
	_client_shoot_input_was_passive_tango_aim = uses_passive_tango_mouse_aim
	return game.player.global_position.direction_to(game.player.get_global_mouse_position())


func _uses_passive_tango_mouse_aim(player_node: Player) -> bool:
	return (
		player_node != null
		and player_node.has_method("uses_passive_tango_mouse_aim")
		and bool(player_node.call("uses_passive_tango_mouse_aim"))
	)


func _is_client_input_state_active(
	move_input: Vector2,
	shoot_input: Vector2,
	velocity: Vector2,
	uses_passive_tango_mouse_aim: bool
) -> bool:
	return (
		move_input != Vector2.ZERO
		or (shoot_input != Vector2.ZERO and not uses_passive_tango_mouse_aim)
		or velocity.length_squared() > INPUT_CHANGE_EPSILON
	)


func _client_interpolate_entities() -> void:
	if game == null:
		return
	var current_time := _get_net_time()
	var local_peer_id: int = _get_client_view_local_peer_id()
	player_coordinator.interpolate_remote_players(current_time, local_peer_id)
	enemy_coordinator.interpolate_remote_enemies(current_time)


@rpc("authority", "call_remote", "unreliable_ordered", 2)
func _rpc_receive_player_snapshot(host_timestamp: float, data: PackedByteArray) -> void:
	if game == null or not is_client_view_runtime():
		return
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	var stale_peer_ids := player_coordinator.apply_authoritative_snapshot(
		snapshot_time,
		data,
		_get_client_view_local_peer_id(),
		player_coordinator.has_local_tango_prediction()
	)
	for peer_id in stale_peer_ids:
		_clear_peer_network_state(peer_id)
		game.remove_multiplayer_player(peer_id)


@rpc("authority", "call_remote", "unreliable", 3)
func _rpc_receive_enemy_snapshot(
	host_timestamp: float,
	data: PackedByteArray,
	batch_id: int = 0,
	chunk_index: int = 0,
	chunk_count: int = 1,
	snapshot_hz: int = _NetConstants.ENEMY_SNAPSHOT_HZ
) -> void:
	var snapshot_time := _map_host_timestamp_to_client_time(host_timestamp)
	enemy_coordinator.apply_authoritative_snapshot(
		snapshot_time,
		data,
		batch_id,
		chunk_index,
		chunk_count,
		snapshot_hz
	)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _rpc_client_player_state(
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
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_client_player_state(
		sender_id,
		sequence,
		reported_position,
		reported_velocity,
		move_input,
		shoot_input,
		buttons,
		dash_request_sequence,
		dash_direction,
		dash_start_move_input
	)


func _apply_accepted_client_player_state(
	sender_id: int,
	player_node: Player,
	reported_position: Vector2,
	reported_velocity: Vector2,
	shoot_input: Vector2,
	use_skill1: bool,
	use_reload: bool = false
) -> void:
	player_coordinator.apply_accepted_client_player_state(
		sender_id,
		player_node,
		reported_position,
		reported_velocity,
		shoot_input,
		use_skill1,
		use_reload
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_player_dash_requested(
	dash_request_sequence: int,
	direction: Vector2,
	start_move_input: Vector2
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_dash_request(
		sender_id,
		dash_request_sequence,
		direction,
		start_move_input
	)


func _try_accept_client_dash_request(
	peer_id: int,
	player_node: Player,
	dash_request_sequence: int,
	direction: Vector2,
	movement_evidence: Vector2
) -> bool:
	return player_coordinator.try_accept_client_dash_request(
		peer_id,
		player_node,
		dash_request_sequence,
		direction,
		movement_evidence
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_dash_confirmed(
	player_peer_id: int,
	direction: Vector2,
	dash_request_sequence: int
) -> void:
	player_coordinator.apply_dash_confirmation(
		player_peer_id,
		direction,
		dash_request_sequence
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_primary_attack_requested(direction: Vector2, request_id: int = 0) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_hoe_primary_request(
		sender_id,
		direction,
		request_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_hoe_whirlwind_requested(request_id: int = 0) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_hoe_whirlwind_request(sender_id, request_id)


func _apply_authoritative_hoe_action(
	peer_id: int,
	action_kind: StringName,
	direction: Vector2,
	request_id: int = 0
) -> bool:
	return player_coordinator.apply_authoritative_hoe_action(
		peer_id,
		action_kind,
		direction,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_hoe_action_confirmed(
	peer_id: int,
	action_kind_text: String,
	direction: Vector2,
	action_sequence: int,
	request_id: int = 0,
	accepted: bool = true,
	cooldown_ratio: float = 0.0,
	skill_charge: float = -1.0
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_hoe_action_confirmation(
		sender_id,
		peer_id,
		action_kind_text,
		direction,
		action_sequence,
		request_id,
		accepted,
		cooldown_ratio,
		skill_charge
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_electric_surge_requested(request_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_tango_electric_surge_request(sender_id, request_id)


func _apply_authoritative_tango_electric_surge_request(
	peer_id: int,
	request_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tango_electric_surge_request(
		peer_id,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_electric_surge_started(
	peer_id: int,
	activation_id: int,
	origin: Vector2,
	remaining_seconds_at_send: float,
	host_sent_at: float,
	buff_active: bool,
	request_id: int,
	auto_fire_charge_sequence: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var transport_age_seconds := 0.0
	if session_coordinator.has_host_time_offset():
		if (
			(sender_id <= 0 or sender_id == _get_host_peer_id())
			and is_finite(host_sent_at)
		):
			var local_sent_at := _map_host_timestamp_to_client_time(
				host_sent_at,
				false
			)
			transport_age_seconds = maxf(_get_net_time() - local_sent_at, 0.0)
	player_coordinator.apply_tango_electric_surge_started(
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


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_electric_surge_finished(peer_id: int, activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_electric_surge_finished(
		sender_id,
		peer_id,
		activation_id
	)


func _finish_authoritative_tango_electric_surge(
	peer_id: int,
	activation_id: int
) -> void:
	player_coordinator.finish_authoritative_tango_electric_surge(
		peer_id,
		activation_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_started_requested(direction: Vector2, request_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_tango_charge_started_request(
		sender_id,
		direction,
		request_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_released_requested(direction: Vector2, request_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_tango_charge_released_request(
		sender_id,
		direction,
		request_id
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tango_charge_cancelled_requested(request_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_tango_charge_cancelled_request(sender_id, request_id)


func _apply_authoritative_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tango_charge_started(
		peer_id,
		direction,
		request_id
	)


func _apply_authoritative_tango_charge_released(
	peer_id: int,
	direction: Vector2,
	request_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tango_charge_released(
		peer_id,
		direction,
		request_id
	)


func _apply_authoritative_tango_charge_cancelled(peer_id: int, request_id: int) -> bool:
	return player_coordinator.apply_authoritative_tango_charge_cancelled(
		peer_id,
		request_id
	)


func _cancel_authoritative_tango_charge(
	peer_id: int,
	broadcast_cancel: bool,
	request_id: int = 0
) -> void:
	player_coordinator.cancel_authoritative_tango_charge(
		peer_id,
		broadcast_cancel,
		request_id
	)


func _update_authoritative_tango_charge_lifecycle() -> void:
	player_coordinator.update_authoritative_tango_charge_lifecycle()


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_started(
	peer_id: int,
	direction: Vector2,
	charge_sequence: int,
	request_id: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_started(
		sender_id,
		peer_id,
		direction,
		charge_sequence,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_released(
	peer_id: int,
	direction: Vector2,
	charge_ratio: float,
	charge_sequence: int,
	request_id: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_released(
		sender_id,
		peer_id,
		direction,
		charge_ratio,
		charge_sequence,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_cancelled(
	peer_id: int,
	charge_sequence: int,
	request_id: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_cancelled(
		sender_id,
		peer_id,
		charge_sequence,
		request_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tango_charge_rejected(peer_id: int, request_id: int, phase_text: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tango_charge_rejected(
		sender_id,
		peer_id,
		request_id,
		phase_text
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tiyi_high_noon_requested(activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.handle_tiyi_high_noon_request(sender_id, activation_id)


func _apply_authoritative_tiyi_high_noon_request(
	peer_id: int,
	activation_id: int
) -> bool:
	return player_coordinator.apply_authoritative_tiyi_high_noon_request(
		peer_id,
		activation_id
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_started(peer_id: int, activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_started(
		sender_id,
		peer_id,
		activation_id
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tiyi_high_noon_targets(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_targets(
		sender_id,
		peer_id,
		activation_id,
		target_ids
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_finished(
	peer_id: int,
	activation_id: int,
	target_ids: PackedInt32Array,
	hit_positions: PackedVector2Array
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_finished(
		sender_id,
		peer_id,
		activation_id,
		target_ids,
		hit_positions
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tiyi_high_noon_cancelled(peer_id: int, activation_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.apply_tiyi_high_noon_cancelled(
		sender_id,
		peer_id,
		activation_id
	)


func _cancel_authoritative_tiyi_high_noon(
	peer_id: int,
	activation_id: int,
	broadcast_cancel: bool
) -> void:
	player_coordinator.cancel_authoritative_tiyi_high_noon(
		peer_id,
		activation_id,
		broadcast_cancel
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_state_corrected(corrected_position: Vector2, corrected_velocity: Vector2) -> void:
	player_coordinator.apply_local_state_correction(
		corrected_position,
		corrected_velocity
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_authoritative_teleported(
	peer_id: int,
	target_position: Vector2,
	snapshot_sequence_cutoff: int
) -> void:
	player_coordinator.queue_authoritative_teleport(
		peer_id,
		target_position,
		snapshot_sequence_cutoff,
		_get_client_view_local_peer_id(),
		_get_net_time()
	)


func _commit_authoritative_player_teleport(
	peer_id: int,
	target_position: Vector2
) -> bool:
	return player_coordinator.commit_authoritative_player_teleport(
		peer_id,
		target_position
	)


func _accept_client_player_state(
	peer_id: int,
	sequence: int,
	reported_position: Vector2,
	reported_velocity: Vector2
) -> bool:
	return player_coordinator.accept_client_player_state(
		peer_id,
		sequence,
		reported_position,
		reported_velocity
	)

func register_local_projectile(
	projectile: Node,
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	target_enemy_net_id: int = 0
) -> void:
	if projectile == null:
		return
	if net_manager == null or not net_manager.is_multiplayer_active():
		return
	if not _NetConstants.is_valid_network_combat_value(damage):
		push_error("MpGame: 投射物伤害超出网络 signed int32 契约，已拒绝发送。")
		return
	var projectile_id: int = projectile_coordinator.register_local_projectile(
		projectile,
		projectile_type,
		owner_peer_id,
		damage,
		lifetime,
		pierces_enemies,
		net_manager.is_host(),
		_get_net_time()
	)
	if projectile_id <= 0:
		return
	var host_fire_timestamp := _get_net_time()
	if net_manager.is_host():
		_rpc_to_connected_clients(
			&"net_projectile_fired",
			[
				projectile_id,
				String(projectile_type),
				owner_peer_id,
				spawn_position,
				direction,
				damage,
				speed,
				lifetime,
				pierces_enemies,
				target_peer_id,
				host_fire_timestamp,
				target_enemy_net_id,
			]
		)
	else:
		_rpc_projectile_fired_from_client.rpc_id(
			_get_host_peer_id(),
			projectile_id,
			String(projectile_type),
			owner_peer_id,
			spawn_position,
			direction,
			damage,
			speed,
			lifetime,
			pierces_enemies,
			target_peer_id,
			host_fire_timestamp,
			target_enemy_net_id
		)


func register_local_tango_laser_volley(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	charge_ratio: float,
	barrage_remaining_seconds: float
) -> bool:
	var charge_sequence := player_coordinator.get_tango_charge_sequence(
		owner_peer_id
	)
	var maximum_internal_barrage_seconds := (
		player_coordinator.get_tango_laser_barrage_maximum_seconds(
			owner_peer_id,
			charge_ratio
		)
	)
	if (
		net_manager == null
		or not net_manager.is_multiplayer_active()
		or not net_manager.is_host()
	):
		return false
	var projectile_ids: PackedInt64Array = (
		projectile_coordinator.register_local_tango_laser_volley(
		projectiles,
		spawn_positions,
		direction,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		charge_sequence,
		charge_ratio,
		barrage_remaining_seconds,
		maximum_internal_barrage_seconds,
		_get_net_time()
		)
	)
	if projectile_ids.is_empty():
		return false
	var host_fire_timestamp := _get_net_time()
	# The reliable Electric Surge event owns the eight-second automatic-fire
	# lifetime. Keep the established volley payload within its ordinary five-second
	# contract; surge-aware replicas use batches only to reconcile aim/cadence.
	var network_barrage_remaining_seconds := minf(
		barrage_remaining_seconds,
		TANGO_BARRAGE_MAXIMUM_SECONDS
	)
	_rpc_to_connected_clients(
		&"net_tango_laser_volley",
		[
			projectile_ids,
			spawn_positions,
			direction.normalized(),
			owner_peer_id,
			charge_sequence,
			charge_ratio,
			network_barrage_remaining_seconds,
			damage,
			speed,
			lifetime,
			host_fire_timestamp,
		]
	)
	return true


func register_local_linglan_skill1_ring(
	projectiles: Array[Node],
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float
) -> void:
	var projectile_count := projectiles.size()
	if (
		projectile_count <= 0
		or spawn_positions.size() != projectile_count
		or directions.size() != projectile_count
		or net_manager == null
		or not net_manager.is_multiplayer_active()
		or not net_manager.is_host()
	):
		return
	var projectile_ids: PackedInt64Array = (
		projectile_coordinator.register_local_linglan_skill1_ring(
		projectiles,
		owner_peer_id,
		damage,
		lifetime,
		_get_net_time()
		)
	)
	if projectile_ids.size() != projectile_count:
		return
	var host_fire_timestamp := _get_net_time()
	if projectile_ids.size() <= LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET:
		_rpc_to_connected_clients(
			&"net_linglan_skill1_ring_batch",
			[
				projectile_ids,
				spawn_positions,
				directions,
				owner_peer_id,
				damage,
				speed,
				lifetime,
				host_fire_timestamp,
			]
		)
		return

	for chunk_start in range(
		0,
		projectile_ids.size(),
		LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET
	):
		var chunk_end := mini(
			chunk_start + LINGLAN_SKILL1_RING_MAX_PROJECTILES_PER_PACKET,
			projectile_ids.size()
		)
		_rpc_to_connected_clients(
			&"net_linglan_skill1_ring_batch",
			[
				projectile_ids.slice(chunk_start, chunk_end),
				spawn_positions.slice(chunk_start, chunk_end),
				directions.slice(chunk_start, chunk_end),
				owner_peer_id,
				damage,
				speed,
				lifetime,
				host_fire_timestamp,
			]
		)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_projectile_fired_from_client(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	_client_fire_timestamp: float = -1.0,
	target_enemy_net_id: int = 0
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not net_manager.is_host():
		return
	if not _NetConstants.is_valid_network_combat_value(damage):
		return
	if not projectile_coordinator.accept_client_projectile_request_identity(
		sender_id,
		projectile_id,
		owner_peer_id,
		_is_embedded_participant_suspended(sender_id),
		_get_net_time()
	):
		return
	var accepted_direction := _get_valid_client_projectile_direction(direction)
	if accepted_direction == Vector2.ZERO:
		return
	var accepted_projectile_type := StringName(projectile_type)
	if (
		accepted_projectile_type != TIYI_SNIPER_PROJECTILE_TYPE
		and not _is_client_projectile_spawn_position_allowed(
			accepted_projectile_type,
			owner_peer_id,
			spawn_position
		)
	):
		return
	var accepted_parameters := _get_authoritative_client_projectile_parameters(
		accepted_projectile_type,
		owner_peer_id
	)
	if accepted_parameters.is_empty():
		return
	var accepted_spawn_position := _get_authoritative_client_projectile_spawn_position(
		accepted_projectile_type,
		owner_peer_id,
		spawn_position,
		accepted_direction
	)
	if not _is_finite_vector2(accepted_spawn_position):
		return
	var accepted_damage := int(accepted_parameters["damage"])
	if not _NetConstants.is_valid_network_combat_value(accepted_damage):
		push_error("MpGame: 权威投射物伤害超出网络 signed int32 契约，已拒绝发送。")
		return
	var accepted_speed := float(accepted_parameters["speed"])
	var accepted_lifetime := float(accepted_parameters["lifetime"])
	var accepted_pierces_enemies := bool(
		accepted_parameters.get("pierces_enemies", false)
	)
	var accepted_target_enemy_net_id := _resolve_authoritative_homing_target(
		owner_peer_id,
		accepted_direction,
		bool(accepted_parameters.get("homes_to_enemy", false))
	)
	var host_fire_timestamp := _get_net_time()
	_rpc_to_connected_clients(
		&"net_projectile_fired",
		[
			projectile_id,
			projectile_type,
			owner_peer_id,
			accepted_spawn_position,
			accepted_direction,
			accepted_damage,
			accepted_speed,
			accepted_lifetime,
			accepted_pierces_enemies,
			target_peer_id,
			host_fire_timestamp,
			accepted_target_enemy_net_id,
		]
	)
	net_projectile_fired(
		projectile_id,
		projectile_type,
		owner_peer_id,
		accepted_spawn_position,
		accepted_direction,
		accepted_damage,
		accepted_speed,
		accepted_lifetime,
		accepted_pierces_enemies,
		target_peer_id,
		host_fire_timestamp,
		accepted_target_enemy_net_id
	)


func _resolve_authoritative_homing_target(
	owner_peer_id: int,
	direction: Vector2,
	should_home: bool
) -> int:
	return projectile_coordinator.resolve_authoritative_homing_target(
		owner_peer_id,
		direction,
		should_home
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_projectile_fired(
	projectile_id: int,
	projectile_type: String,
	owner_peer_id: int,
	spawn_position: Vector2,
	direction: Vector2,
	damage: int,
	speed: float,
	lifetime: float,
	pierces_enemies: bool = false,
	target_peer_id: int = 0,
	host_fire_timestamp: float = -1.0,
	target_enemy_net_id: int = 0
) -> void:
	var projectile_type_name := StringName(projectile_type)
	projectile_coordinator.receive_projectile_fired(
		projectile_id,
		projectile_type_name,
		owner_peer_id,
		spawn_position,
		direction,
		damage,
		speed,
		lifetime,
		pierces_enemies,
		target_peer_id,
		target_enemy_net_id,
		_get_projectile_time_compensation_age(
			host_fire_timestamp,
			lifetime,
			projectile_type_name
		),
		_get_net_time()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_tango_laser_volley(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	charge_sequence: int,
	charge_ratio: float,
	barrage_remaining_seconds: float,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> void:
	if not _is_valid_tango_laser_volley_payload(
		projectile_ids,
		spawn_positions,
		direction,
		owner_peer_id,
		charge_sequence,
		charge_ratio,
		barrage_remaining_seconds,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	):
		return
	var current_charge_sequence := player_coordinator.get_tango_charge_sequence(
		owner_peer_id
	)
	var previous_visual_state := (
		_last_tango_volley_visual_state_by_peer.get(owner_peer_id, {})
		as Dictionary
	)
	var previous_visual_sequence := int(
		previous_visual_state.get("sequence", 0)
	)
	var previous_visual_timestamp := float(
		previous_visual_state.get("host_fire_timestamp", -1.0)
	)
	var should_apply_visual_state := (
		charge_sequence > current_charge_sequence
		or (
			charge_sequence == current_charge_sequence
			and (
				charge_sequence > previous_visual_sequence
				or host_fire_timestamp > previous_visual_timestamp
			)
		)
	)
	if charge_sequence > current_charge_sequence:
		player_coordinator.observe_tango_charge_sequence(
			owner_peer_id,
			charge_sequence
		)
	var barrage_age := _get_unbounded_host_event_age(host_fire_timestamp)
	var visual_remaining := barrage_remaining_seconds - barrage_age
	if should_apply_visual_state:
		_last_tango_volley_visual_state_by_peer[owner_peer_id] = {
			"sequence": charge_sequence,
			"host_fire_timestamp": host_fire_timestamp,
		}
		var owner_player: Player = null
		if game != null:
			owner_player = game.get_player_for_peer(owner_peer_id)
		if (
			owner_player != null
			and is_instance_valid(owner_player)
			and owner_player.has_method("apply_remote_tango_barrage_snapshot")
		):
			owner_player.call(
				"apply_remote_tango_barrage_snapshot",
				direction,
				charge_ratio,
				charge_sequence,
				visual_remaining
			)
		if (
			owner_player != null
			and is_instance_valid(owner_player)
			and barrage_age <= lifetime
			and owner_player.has_method("play_remote_tango_volley_audio")
		):
			owner_player.call("play_remote_tango_volley_audio")
	var next_charge_sequence: int = projectile_coordinator.receive_tango_laser_volley(
		projectile_ids,
		spawn_positions,
		direction,
		owner_peer_id,
		charge_sequence,
		current_charge_sequence,
		charge_ratio,
		barrage_remaining_seconds,
		damage,
		speed,
		lifetime,
		host_fire_timestamp,
		barrage_age,
		_get_net_time()
	)
	if next_charge_sequence > current_charge_sequence:
		player_coordinator.observe_tango_charge_sequence(
			owner_peer_id,
			next_charge_sequence
		)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_linglan_skill1_ring_batch(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	directions: PackedVector2Array,
	owner_peer_id: int,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> void:
	projectile_coordinator.receive_linglan_skill1_ring(
		projectile_ids,
		spawn_positions,
		directions,
		owner_peer_id,
		damage,
		speed,
		lifetime,
		host_fire_timestamp,
		_get_unbounded_host_event_age(host_fire_timestamp),
		_get_net_time()
	)


func _get_projectile_time_compensation_age(
	host_fire_timestamp: float,
	lifetime: float,
	projectile_type: StringName = &""
) -> float:
	if host_fire_timestamp < 0.0:
		return 0.0
	var age := _get_unbounded_host_event_age(host_fire_timestamp)
	return projectile_coordinator.get_projectile_time_compensation_age(
		age,
		lifetime,
		projectile_type
	)


func _get_unbounded_host_event_age(host_event_timestamp: float) -> float:
	if host_event_timestamp < 0.0:
		return 0.0
	var mapped_fire_time := host_event_timestamp
	if net_manager == null or not net_manager.is_host():
		mapped_fire_time = _map_host_timestamp_to_client_time(
			host_event_timestamp,
			false
		)
	return maxf(_get_net_time() - mapped_fire_time, 0.0)


func _get_authoritative_client_projectile_parameters(
	projectile_type: StringName,
	owner_peer_id: int
) -> Dictionary:
	return projectile_coordinator.get_authoritative_client_projectile_parameters(
		projectile_type,
		owner_peer_id
	)


func _get_fire_sorcerer_burn_family(
	source_type: StringName
) -> StringName:
	var burn_family := CombatAttackRegistry.get_burn_family(source_type)
	if burn_family == FIRE_SLIME_TOUCH_TYPE:
		return &""
	return burn_family


func _get_fire_sorcerer_burn_level(source_type: StringName) -> int:
	return CombatAttackRegistry.get_burn_tick_damage(source_type)


## 每颗火球的协议 source type 在本进程内只接受一次首碰。
## Host 记录是最终权威；Client 使用同一入口抑制本地重复预测。
func try_consume_fire_sorcerer_fireball_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.try_consume_fire_sorcerer_fireball_contact(
		projectile_id,
		source_type
	)


func try_consume_frost_sorcerer_ice_spike_contact(
	projectile_id: int,
	source_type: StringName
) -> bool:
	return projectile_coordinator.try_consume_frost_sorcerer_ice_spike_contact(
		projectile_id,
		source_type
	)


func _get_player_projectile_damage_type(
	projectile_type: StringName
) -> EnemyConfig.DamageType:
	if projectile_type == TIYI_SNIPER_PROJECTILE_TYPE:
		return EnemyConfig.DamageType.MAGIC
	return EnemyConfig.DamageType.PHYSICAL


func _get_valid_client_projectile_direction(direction: Vector2) -> Vector2:
	return projectile_coordinator.get_valid_client_projectile_direction(direction)


func _is_client_projectile_spawn_position_allowed(
	projectile_type: StringName,
	owner_peer_id: int,
	spawn_position: Vector2
) -> bool:
	return projectile_coordinator.is_client_projectile_spawn_position_allowed(
		projectile_type,
		owner_peer_id,
		spawn_position,
		player_coordinator.get_accepted_player_position(owner_peer_id),
		CLIENT_PROJECTILE_SPAWN_POSITION_TOLERANCE
	)


func _get_authoritative_client_projectile_spawn_position(
	projectile_type: StringName,
	owner_peer_id: int,
	reported_spawn_position: Vector2,
	accepted_direction: Vector2
) -> Vector2:
	return projectile_coordinator.get_authoritative_client_projectile_spawn_position(
		projectile_type,
		owner_peer_id,
		reported_spawn_position,
		accepted_direction
	)


func _is_finite_vector2(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)


func _is_valid_enemy_lightning_chain_points(points: PackedVector2Array) -> bool:
	var point_count := points.size()
	if (
		point_count < LIGHTNING_SORCERER_CHAIN_MIN_POINTS
		or point_count > LIGHTNING_SORCERER_CHAIN_MAX_POINTS
	):
		return false
	for point in points:
		if not _is_finite_vector2(point):
			return false
	return true


func _is_valid_tango_laser_volley_payload(
	projectile_ids: PackedInt64Array,
	spawn_positions: PackedVector2Array,
	direction: Vector2,
	owner_peer_id: int,
	charge_sequence: int,
	charge_ratio: float,
	barrage_remaining_seconds: float,
	damage: int,
	speed: float,
	lifetime: float,
	host_fire_timestamp: float
) -> bool:
	return projectile_coordinator.is_valid_tango_laser_volley_payload(
		projectile_ids,
		spawn_positions,
		direction,
		owner_peer_id,
		charge_sequence,
		charge_ratio,
		barrage_remaining_seconds,
		damage,
		speed,
		lifetime,
		host_fire_timestamp
	)


func _prune_projectile_records(now: float) -> void:
	projectile_coordinator.prune_records(now)


func _update_recent_event_cache_prune(delta: float) -> void:
	_recent_event_prune_time_left = maxf(_recent_event_prune_time_left - delta, 0.0)
	if _recent_event_prune_time_left > 0.0:
		return
	_recent_event_prune_time_left = RECENT_EVENT_PRUNE_INTERVAL_SECONDS
	_prune_recent_event_caches(_get_net_time())


func _prune_recent_event_caches(now: float) -> void:
	player_coordinator.prune_recent_player_hit_events(now)
	collectible_presentation_coordinator.prune_recent_effect_events(now)
	_prune_projectile_records(now)


func request_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	damage: int,
	impact_direction: Vector2
) -> void:
	if net_manager != null and net_manager.is_host():
		_apply_enemy_hit_report(projectile_id, owner_peer_id, enemy_net_id, damage, impact_direction)
	# Client projectile replicas are visual/predictive only. The Host has already
	# rebuilt the accepted projectile and settles its own collision callback.


func apply_multiplayer_collectible_enemy_damage(
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.MAGIC,
	show_hit_particles: bool = true
) -> bool:
	if net_manager == null or not net_manager.is_host():
		return false
	if enemy == null or not is_instance_valid(enemy):
		return false
	var enemy_net_id := int(enemy.get_meta("net_id", 0))
	if enemy_net_id <= 0:
		var request := DamageRequest.new(damage, damage_type)
		request.with_source(null, 0, &"collectible_effect")
		request.with_directions(impact_direction)
		request.with_flag(
			CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
			not show_hit_particles
		)
		return enemy.apply_combat_damage(request).accepted
	return _apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		damage,
		impact_direction,
		damage_type as EnemyConfig.DamageType,
		show_hit_particles
	)


@rpc("any_peer", "call_remote", "reliable", 4)
func _rpc_enemy_hit_report(
	_projectile_id: int,
	_owner_peer_id: int,
	_enemy_net_id: int,
	_damage: int,
	_impact_direction: Vector2
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	enemy_coordinator.receive_enemy_hit_report(
		sender_id,
		_projectile_id,
		_owner_peer_id,
		_enemy_net_id,
		_damage,
		_impact_direction
	)


func _apply_enemy_hit_report(
	projectile_id: int,
	owner_peer_id: int,
	enemy_net_id: int,
	reported_damage: int,
	impact_direction: Vector2
) -> void:
	var now := _get_net_time()
	var admission: MpProjectileCoordinatorScript.EnemyHitAdmission = (
		projectile_coordinator.prepare_enemy_hit(
		projectile_id,
		owner_peer_id,
		enemy_net_id,
		reported_damage,
		now
		)
	)
	if admission == null:
		return
	var projectile_type: StringName = admission.projectile_type
	var authoritative_damage: int = admission.authoritative_damage
	var enemy := _get_host_enemy_for_net_id(enemy_net_id)
	if enemy == null or not is_instance_valid(enemy):
		return
	var owner_player: Player = null
	if game != null:
		owner_player = game.get_player_for_peer(owner_peer_id)
	if (
		owner_player != null
		and is_instance_valid(owner_player)
		and (
			projectile_type == &"player_bullet"
			or projectile_type == TIYI_SNIPER_PROJECTILE_TYPE
			or projectile_type == TANGO_LASER_PROJECTILE_TYPE
			or projectile_type == &"skill1_bomb"
		)
	):
		authoritative_damage = owner_player.resolve_attack_damage_against_enemy(
			authoritative_damage,
			enemy
		)
	if not _apply_confirmed_enemy_damage(
		enemy_net_id,
		enemy,
		authoritative_damage,
		impact_direction,
		_get_player_projectile_damage_type(projectile_type)
	):
		return
	projectile_coordinator.commit_enemy_hit(
		projectile_id,
		enemy_net_id,
		admission.consumes_first_confirmed_hit,
		now
	)
	if projectile_type == TIYI_SNIPER_PROJECTILE_TYPE:
		var projectile_record: Dictionary = projectile_coordinator.get_projectile_record(
			projectile_id
		)
		var authoritative_hit_position := enemy.global_position
		var authoritative_direction := _get_valid_client_projectile_direction(-impact_direction)
		var projectile_node := (
			projectile_coordinator.get_projectile(projectile_id) as Node2D
		)
		if projectile_node != null:
			authoritative_hit_position = projectile_node.global_position
			var projectile_direction_variant: Variant = projectile_node.get("direction")
			if projectile_direction_variant is Vector2:
				var projectile_direction := _get_valid_client_projectile_direction(
					projectile_direction_variant as Vector2
				)
				if projectile_direction != Vector2.ZERO:
					authoritative_direction = projectile_direction
		if authoritative_direction == Vector2.ZERO:
			authoritative_direction = Vector2.RIGHT
		_rpc_to_connected_clients(
			&"net_tiyi_sniper_hit_confirmed",
			[
				projectile_id,
				enemy_net_id,
				authoritative_hit_position,
				authoritative_direction,
				bool(projectile_record.get("pierces_enemies", false)),
			]
		)
	if (
		(
			projectile_type == &"player_bullet"
			or projectile_type == TIYI_SNIPER_PROJECTILE_TYPE
			or projectile_type == TANGO_LASER_PROJECTILE_TYPE
		)
		and owner_player != null
		and is_instance_valid(owner_player)
	):
		owner_player.apply_collectible_attack_hit_effects(enemy, authoritative_damage)


@rpc("authority", "call_remote", "reliable", 4)
func net_tiyi_sniper_hit_confirmed(
	projectile_id: int,
	enemy_net_id: int,
	hit_position: Vector2,
	direction: Vector2,
	continues_piercing: bool
) -> void:
	if projectile_id <= 0 or enemy_net_id <= 0 or not _is_finite_vector2(hit_position):
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id > 0 and sender_id != _get_host_peer_id():
		return
	projectile_coordinator.apply_tiyi_sniper_hit_confirmation(
		projectile_id,
		enemy_net_id,
		hit_position,
		direction,
		continues_piercing,
		self
	)


func _apply_confirmed_enemy_damage(
	enemy_net_id: int,
	enemy: Enemy,
	damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool = true
) -> bool:
	if enemy_net_id <= 0 or enemy == null or not is_instance_valid(enemy):
		return false
	var request := DamageRequest.new(damage, int(damage_type))
	request.with_directions(impact_direction)
	request.with_flag(
		CombatTypes.DamageFlag.SUPPRESS_HIT_PARTICLES,
		not show_hit_particles
	)
	enemy_coordinator.set_active_damage_feedback_context(
		enemy_net_id,
		impact_direction,
		damage_type,
		show_hit_particles
	)
	var result := enemy.apply_combat_damage(request)
	enemy_coordinator.clear_active_damage_feedback_context(enemy_net_id)
	if not result.accepted:
		return false
	if result.lethal:
		# The synchronous defeated signal already sent a reliable terminal
		# event containing this final confirmed hit.
		return true
	_queue_enemy_damage_feedback(
		enemy_net_id,
		result.health_after,
		enemy.health_revision,
		result.applied_damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)
	return true


func _queue_enemy_damage_feedback(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: EnemyConfig.DamageType,
	show_hit_particles: bool
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or enemy_net_id <= 0:
		return
	enemy_coordinator.queue_damage_feedback(
		enemy_net_id,
		current_health,
		health_revision,
		confirmed_damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)


func _update_batched_network_events(delta: float) -> void:
	if not net_manager.is_host():
		return
	_combat_feedback_flush_time_left -= maxf(delta, 0.0)
	if _combat_feedback_flush_time_left <= 0.0:
		_combat_feedback_flush_time_left = COMBAT_FEEDBACK_FLUSH_INTERVAL_SECONDS
		_flush_enemy_damage_feedback()
	if tower_world_coordinator != null:
		tower_world_coordinator.update_host(delta)
	if world_flow_coordinator.update_host(delta):
		_flush_tiyi_target_updates()


func _flush_tiyi_target_updates() -> void:
	player_coordinator.flush_tiyi_target_updates()


func _flush_enemy_damage_feedback() -> void:
	for batch in enemy_coordinator.drain_damage_feedback_batches():
		_rpc_to_connected_clients(
			&"net_enemy_damage_feedback_batch",
			[
				batch.net_ids,
				batch.health_values,
				batch.health_revisions,
				batch.damage_values,
				batch.directions,
				batch.damage_types,
				batch.particle_flags,
			]
		)


func _on_tower_world_plant_health_batch_broadcast_requested(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
) -> void:
	if not _has_tower_mode() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_plant_health_batch",
		[
			net_ids,
			health_values,
			maximum_values,
			revisions,
			damage_values,
			healing_values,
			directions,
			damage_types,
			world_positions,
		]
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	maximum_values: PackedInt32Array,
	revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	healing_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	world_positions: PackedVector2Array
) -> void:
	tower_world_coordinator.receive_plant_health_batch(
		net_ids,
		health_values,
		maximum_values,
		revisions,
		damage_values,
		healing_values,
		directions,
		damage_types,
		world_positions
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_feedback_batch(
	net_ids: PackedInt32Array,
	health_values: PackedInt32Array,
	health_revisions: PackedInt32Array,
	damage_values: PackedInt32Array,
	directions: PackedVector2Array,
	damage_types: PackedByteArray,
	particle_flags: PackedByteArray
) -> void:
	enemy_coordinator.apply_damage_feedback_batch(
		net_ids,
		health_values,
		health_revisions,
		damage_values,
		directions,
		damage_types,
		particle_flags
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_enemy_damage_applied(
	enemy_net_id: int,
	current_health: int,
	health_revision: int,
	is_dead: bool,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL,
	show_hit_particles: bool = true
) -> void:
	enemy_coordinator.apply_damage_event(
		enemy_net_id,
		current_health,
		health_revision,
		is_dead,
		confirmed_damage,
		impact_direction,
		damage_type,
		show_hit_particles
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
	return player_coordinator.request_multiplayer_player_damage(
		source_id,
		target_peer_id,
		damage,
		source_type,
		damage_type_or_source_direction,
		source_direction_or_is_ranged,
		is_ranged,
		contact_preconsumed
	)



func request_multiplayer_player_burn_tick(
	player_peer_id: int,
	source_family: StringName
) -> bool:
	return player_coordinator.request_multiplayer_player_burn_tick(
		player_peer_id,
		source_family
	)


## Host-only sink used by authoritative Player status schedulers. This is a
## local method, not an RPC: clients cannot submit arbitrary periodic damage.
func request_multiplayer_player_damage_over_time_tick(
	player_peer_id: int,
	status_id: StringName,
	source_family: StringName,
	tick_damage: int
) -> bool:
	return player_coordinator.request_multiplayer_player_damage_over_time_tick(
		player_peer_id,
		status_id,
		source_family,
		tick_damage
	)



## Host-only replication path for Luoxi's explicit HP-loss card effects.
## The Player method deliberately bypasses ordinary combat mitigation; this
## wrapper only publishes the already-applied authoritative health result.
func apply_luoxi_direct_health_loss(
	target_player: Player,
	amount: int,
	minimum_health: int = 0
) -> int:
	return player_coordinator.apply_luoxi_direct_health_loss(
		target_player,
		amount,
		minimum_health
	)



func request_player_hit_report(
	_source_id: int,
	_player_peer_id: int,
	_source_type: StringName,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	# Protocol-v25 compatibility shell. Client hit claims remain disabled.
	return


@rpc("any_peer", "call_remote", "reliable", 5)
func _rpc_player_hit_report(
	_source_id: int,
	_player_peer_id: int,
	_attack_wire_id: int,
	_impact_direction: Vector2,
	_damage_flags: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	player_coordinator.reject_untrusted_player_hit_report(
		sender_id,
		_source_id,
		_player_peer_id,
		_attack_wire_id,
		_impact_direction,
		_damage_flags
	)



@rpc("authority", "call_remote", "reliable", 5)
func net_player_damage_applied(
	player_peer_id: int,
	current_health: int,
	is_dead: bool,
	health_revision: int,
	confirmed_damage: int,
	impact_direction: Vector2,
	damage_type: int,
	grant_hit_invincibility: bool = true,
	apply_confirmed_cold: bool = false,
	combat_outcome: int = 0
) -> void:
	player_coordinator.apply_player_damage_confirmation(
		player_peer_id,
		current_health,
		is_dead,
		health_revision,
		confirmed_damage,
		impact_direction,
		damage_type,
		grant_hit_invincibility,
		apply_confirmed_cold,
		combat_outcome
	)



func apply_multiplayer_player_heal(target_player: Player, heal_amount: int) -> bool:
	return player_coordinator.apply_multiplayer_player_heal(
		target_player,
		heal_amount
	)


## Receives an already-applied authoritative heal.
func report_multiplayer_player_healing(
	target_player: Player,
	confirmed_healing: int
) -> void:
	player_coordinator.report_multiplayer_player_healing(
		target_player,
		confirmed_healing
	)


func apply_multiplayer_collectible_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return player_coordinator.apply_multiplayer_player_heal(
		target_player,
		heal_amount
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_healed(
	peer_id: int,
	current_health: int,
	health_revision: int,
	confirmed_healing: int
) -> void:
	player_coordinator.apply_player_heal_confirmation(
		peer_id,
		current_health,
		health_revision,
		confirmed_healing
	)



# Protocol v25 retains these compatibility shells for older relay deployments.
# Xirang orbs no longer exist; all annotated endpoints remain deliberate no-ops.
@rpc("authority", "call_remote", "reliable", 5)
func net_xirang_orb_spawned(orb_id: int, amount: int, spawn_position: Vector2) -> void:
	pass


@rpc("any_peer", "call_remote", "reliable", 6)
func _rpc_xirang_orb_collected(orb_id: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 6)
func net_xirang_granted_all(orb_id: int, amount: int, revision: int) -> void:
	pass


@rpc("authority", "call_remote", "reliable", 5)
func net_xirang_orb_removed(orb_id: int) -> void:
	pass

func get_local_multiplayer_player() -> Player:
	if game == null:
		return null
	return game.player


func get_combat_target_by_net_id(enemy_net_id: int) -> Enemy:
	var enemy: Enemy
	if net_manager.is_host():
		enemy = _get_host_enemy_for_net_id(enemy_net_id)
	else:
		enemy = _get_valid_client_enemy_for_net_id(enemy_net_id)
	return enemy if CombatTargetIndexScript.is_enemy_queryable(enemy) else null


func get_all_combat_targets() -> Array[Enemy]:
	if game == null:
		return []
	if net_manager.is_host():
		return game.get_all_combat_targets()
	return enemy_coordinator.get_all_client_combat_targets()


func pick_random_combat_target(center: Vector2, radius: float = 0.0) -> Enemy:
	if game == null:
		return null
	return game.pick_random_combat_target(center, radius)


func find_nearest_combat_target(
	center: Vector2,
	radius: float,
	excluded_instance_ids: Dictionary = {}
) -> Enemy:
	if (
		game == null
		or not center.is_finite()
		or not is_finite(radius)
		or radius < 0.0
	):
		return null
	if net_manager.is_host():
		return game.find_nearest_combat_target(
			center,
			radius,
			excluded_instance_ids
		)
	return enemy_coordinator.find_nearest_client_combat_target(
		center,
		radius,
		excluded_instance_ids
	)


func query_combat_targets(center: Vector2, radius: float, max_count: int = 0) -> Array[Enemy]:
	var result: Array[Enemy] = []
	query_combat_targets_into(center, radius, result, max_count)
	return result


func query_combat_targets_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy],
	max_count: int = 0
) -> void:
	result.clear()
	if game == null:
		return
	if net_manager.is_host():
		game.query_combat_targets_into(center, radius, result, max_count)
		return
	enemy_coordinator.query_client_combat_targets_into(
		center,
		radius,
		result,
		max_count,
		true
	)


func query_combat_targets_unordered_into(
	center: Vector2,
	radius: float,
	result: Array[Enemy]
) -> void:
	result.clear()
	if game == null:
		return
	if net_manager.is_host():
		game.query_combat_targets_unordered_into(center, radius, result)
		return
	enemy_coordinator.query_client_combat_targets_into(
		center,
		radius,
		result,
		0,
		false
	)


func query_living_players_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[Player]
) -> void:
	result.clear()
	if game == null:
		return
	game.query_living_players_in_radius_into(center, radius, result)


func query_living_plants_in_radius_into(
	center: Vector2,
	radius: float,
	result: Array[PlantDefense]
) -> void:
	result.clear()
	if not _has_tower_mode():
		return
	tower_mode_adapter.query_living_plants_in_radius_into(
		center,
		radius,
		result
	)


func apply_authoritative_player_heal(
	target_player: Player,
	heal_amount: int
) -> bool:
	return player_coordinator.apply_authoritative_player_heal(
		target_player,
		heal_amount
	)


func has_session_object_pool_scene(scene: PackedScene) -> bool:
	return game != null and game.has_session_object_pool_scene(scene)


func acquire_session_object(scene: PackedScene, strict: bool = false) -> Node:
	if game == null:
		return null
	return game.acquire_session_object(scene, strict)


func release_session_object(instance: Node) -> bool:
	return game != null and game.release_session_object(instance)


func grant_xirang_kill_reward(amount: int) -> bool:
	if game == null or not net_manager.is_host():
		return false
	return game.grant_xirang_kill_reward(amount)


func is_host_multiplayer_authority() -> bool:
	return net_manager != null and net_manager.is_host()


func _get_host_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return enemy_coordinator.get_host_enemy(enemy_net_id)


func _get_valid_client_enemy_for_net_id(enemy_net_id: int) -> Enemy:
	return enemy_coordinator.get_valid_client_enemy(enemy_net_id)

func _cancel_player_life_tango_for_revive_schedule(peer_id: int) -> void:
	player_coordinator.cancel_tango_charge_for_life_transition(peer_id)


func _cancel_player_life_actions_for_revive(peer_id: int) -> void:
	player_coordinator.cancel_tiyi_for_life_transition(peer_id)
	player_coordinator.cancel_tango_charge_for_life_transition(peer_id)


func _clear_player_life_tiyi_lifecycle_state(peer_id: int) -> void:
	player_coordinator.clear_tiyi_lifecycle_state(peer_id)


func _get_player_life_revive_anchor_position(
	peer_id: int,
	player_node: Player
) -> Vector2:
	return player_coordinator.get_player_revive_anchor_position(
		peer_id,
		player_node,
		_get_host_peer_id()
	)


func _commit_player_life_revive_position(
	peer_id: int,
	revive_position: Vector2,
	net_time: float
) -> void:
	player_coordinator.remember_accepted_player_pose(
		peer_id,
		revive_position,
		net_time
	)


func _on_host_revive_all_requested() -> void:
	player_coordinator.revive_all_players()


@rpc("authority", "call_remote", "reliable", 5)
func net_player_revive_countdown(peer_id: int, seconds_left: int) -> void:
	player_coordinator.apply_player_revive_countdown(peer_id, seconds_left)


@rpc("authority", "call_remote", "reliable", 5)
func net_player_revived(
	peer_id: int,
	revive_position: Vector2,
	current_health: int,
	invincible_seconds: float,
	health_revision: int
) -> void:
	player_coordinator.apply_player_revived(
		peer_id,
		revive_position,
		current_health,
		invincible_seconds,
		health_revision
	)



func _on_host_enemy_spawned(
	net_id: int,
	enemy_config: EnemyConfig,
	spawn_position: Vector2
) -> void:
	if enemy_config == null or not is_inside_tree() or not net_manager.is_host():
		return
	enemy_coordinator.queue_host_spawn(
		net_id,
		enemy_config,
		spawn_position,
		_get_net_time()
	)


func _on_remote_enemy_spawned(enemy: Enemy) -> void:
	if enemy == null or not _has_tower_mode():
		return
	tower_mode_adapter.configure_runtime_enemy_modifiers(enemy)


func _on_remote_enemy_escape_requested(net_id: int) -> void:
	if not _has_tower_mode():
		return
	tower_mode_adapter.apply_remote_enemy_escape(net_id)


func _flush_pending_enemy_spawns() -> void:
	if not net_manager.is_host():
		return
	for batch in enemy_coordinator.drain_host_spawn_batches():
		_rpc_to_connected_clients(
			&"net_enemy_spawned_batch",
			[batch.net_ids, batch.config_paths, batch.positions, batch.spawn_times]
		)


func _on_host_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	if not is_inside_tree() or not net_manager.is_host() or net_id <= 0:
		return
	_broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_DEFEATED, defeat_position)


func _on_host_enemy_removed(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_REMOVED, Vector2.ZERO)


func _on_host_enemy_escaped(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host() or net_id <= 0:
		return
	_broadcast_enemy_terminal(net_id, ENEMY_TERMINAL_ESCAPED, Vector2.ZERO)


func _broadcast_enemy_terminal(net_id: int, reason: int, event_position: Vector2) -> void:
	var terminal := enemy_coordinator.build_host_terminal_event(
		net_id,
		reason,
		event_position
	)
	if terminal.is_empty():
		return
	_rpc_to_connected_clients(
		&"net_enemy_terminal",
		[
			int(terminal.get("net_id", 0)),
			int(terminal.get("reason", ENEMY_TERMINAL_REMOVED)),
			terminal.get("event_position", Vector2.ZERO) as Vector2,
			int(terminal.get("current_health", 0)),
			int(terminal.get("health_revision", 0)),
			int(terminal.get("damage", 0)),
			terminal.get("impact_direction", Vector2.ZERO) as Vector2,
			int(terminal.get("damage_type", EnemyConfig.DamageType.PHYSICAL)),
			bool(terminal.get("show_hit_particles", false)),
		]
	)


func _on_host_xiaocong_fate_state_changed(state: Dictionary) -> void:
	tower_fate_coordinator.handle_host_fate_state_changed(state)


func _on_host_player_teleport_requested(
	peer_id: int,
	target_position: Vector2
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	if not _commit_authoritative_player_teleport(peer_id, target_position):
		return
	_rpc_to_connected_clients(
		&"net_player_authoritative_teleported",
		[
			peer_id,
			target_position,
			player_coordinator.get_host_snapshot_sequence(),
		]
	)


func _on_host_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: StringName,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	if not _has_tower_mode() or not is_inside_tree() or not net_manager.is_host():
		return
	if (
		net_id <= 0
		or not _NetConstants.is_valid_network_combat_value(current_health)
		or not _NetConstants.is_valid_network_combat_value(maximum_health)
		or not _NetConstants.is_valid_network_combat_value(health_revision)
	):
		push_error("MpGame: 植物生成生命值超出网络 signed int32 契约，已拒绝发送。")
		return
	tower_economy_coordinator.notify_plant_available(net_id)
	var plant := _get_tower_plant(net_id)
	_configure_warehouse_network(plant, true)
	_configure_production_network(plant, true)
	_configure_research_network(plant)
	var runtime_state := _export_plant_runtime_state(plant)
	var host_sample_time := _get_net_time()
	_rpc_to_connected_clients(
		&"net_plant_spawned",
		[
			request_id,
			owner_peer_id,
			net_id,
			String(plant_id),
			anchor,
			current_health,
			maximum_health,
			health_revision,
			runtime_state,
			host_sample_time,
		]
	)
	var warehouse := plant as OakWarehouse
	if warehouse != null:
		_broadcast_warehouse_snapshot(warehouse)


func _on_tower_world_plant_placement_rejection_send_requested(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
) -> void:
	_send_plant_placement_rejected(requester_peer_id, request_id, reason)


func _send_plant_placement_rejected(
	requester_peer_id: int,
	request_id: int,
	reason: StringName
) -> void:
	if not _has_tower_mode() or game == null or requester_peer_id <= 0:
		return
	if requester_peer_id == _get_local_peer_id():
		tower_mode_adapter.apply_remote_plant_placement_rejected(
			request_id,
			reason
		)
		return
	var typed_net_manager := net_manager as NetManagerStore
	if typed_net_manager == null or not typed_net_manager.is_peer_send_ready(
		requester_peer_id
	):
		return
	net_plant_placement_rejected.rpc_id(
		requester_peer_id,
		request_id,
		String(reason)
	)


func _on_host_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or net_id <= 0
		or status_revision <= 0
	):
		return
	_rpc_to_connected_clients(
		&"net_plant_damage_status_changed",
		[net_id, status_mask, status_revision]
	)


func _on_host_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if (
		not _has_tower_mode()
		or not is_inside_tree()
		or not net_manager.is_host()
		or net_id <= 0
	):
		return
	tower_economy_coordinator.notify_plant_removed(net_id)
	_rpc_to_connected_clients(&"net_plant_removed", [net_id, was_destroyed])


func _export_plant_runtime_state(plant: PlantDefense) -> Dictionary:
	if plant == null or not is_instance_valid(plant):
		return {}
	var runtime_state := plant.export_multiplayer_runtime_state().duplicate(true)
	runtime_state["damage_status_mask"] = plant.get_damage_status_mask()
	runtime_state["damage_status_revision"] = plant.damage_status_revision
	return runtime_state


func _apply_plant_runtime_state(
	plant: PlantDefense,
	runtime_state: Dictionary,
	host_sample_time: float
) -> void:
	if plant == null or not is_instance_valid(plant) or not is_finite(host_sample_time):
		return
	var corrected_state := runtime_state.duplicate(true)
	if (
		corrected_state.has("damage_status_mask")
		and corrected_state.has("damage_status_revision")
	):
		plant.apply_remote_damage_status_mask(
			int(corrected_state.get("damage_status_mask", 0)),
			int(corrected_state.get("damage_status_revision", 0))
		)
	var mapped_sample_time := _map_host_timestamp_to_client_time(host_sample_time, false)
	var sample_age := maxf(_get_net_time() - mapped_sample_time, 0.0)
	if corrected_state.has("spread_elapsed_seconds"):
		var spread_elapsed := float(corrected_state.get("spread_elapsed_seconds", 0.0))
		if not is_finite(spread_elapsed):
			return
		corrected_state["spread_elapsed_seconds"] = maxf(spread_elapsed, 0.0) + sample_age
	for elapsed_key in [
		"windup_elapsed_seconds",
		"projectile_elapsed_seconds",
		"cycle_elapsed_seconds",
		"rain_elapsed_seconds",
		"ground_effect_elapsed_seconds",
	]:
		if not corrected_state.has(elapsed_key):
			continue
		var elapsed_seconds := float(corrected_state.get(elapsed_key, 0.0))
		if not is_finite(elapsed_seconds):
			return
		corrected_state[elapsed_key] = maxf(elapsed_seconds, 0.0) + sample_age
	var production_building := plant as ProductionBuilding
	if production_building != null:
		production_building.apply_multiplayer_runtime_state_with_host_sample(
			corrected_state,
			Time.get_ticks_msec() / 1000.0 - sample_age,
			host_sample_time
		)
	else:
		plant.apply_multiplayer_runtime_state(
			corrected_state,
			Time.get_ticks_msec() / 1000.0
		)


func broadcast_enemy_action(
	net_id: int,
	action_name: StringName,
	direction: Vector2,
	action_position: Vector2,
	action_id: int
) -> void:
	if not net_manager.is_host() or net_id <= 0 or action_id <= 0:
		return
	_rpc_to_connected_clients(
		&"net_enemy_action",
		[net_id, String(action_name), direction, action_position, action_id, _get_net_time()]
	)


func broadcast_enemy_target_action(
	net_id: int,
	action_name: StringName,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int
) -> void:
	if not net_manager.is_host() or net_id <= 0 or action_id <= 0:
		return
	_rpc_to_connected_clients(
		&"net_enemy_target_action",
		[net_id, String(action_name), target_peer_id, action_position, action_id, _get_net_time()]
	)


func broadcast_enemy_lightning_chain(points: PackedVector2Array) -> void:
	if (
		not net_manager.is_host()
		or not _is_valid_enemy_lightning_chain_points(points)
	):
		return
	_rpc_to_connected_clients(&"net_enemy_lightning_chain", [points])


func _on_world_flow_pickup_remove_broadcast_requested(net_id: int) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_pickup_removed", [net_id])


func _on_world_flow_pickup_spawn_broadcast_requested(
	net_id: int,
	config_path: String,
	spawn_position: Vector2
) -> void:
	if config_path.is_empty() or not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(
		&"net_pickup_spawned",
		[net_id, config_path, spawn_position.x, spawn_position.y]
	)


func _on_host_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	pickup_config: PickupConfig,
	applied_immediately: bool
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	var config_path := pickup_config.resource_path if pickup_config != null else ""
	var inventory_snapshot := {}
	if (
		not applied_immediately
		and collector_peer_id > 0
		and run_state.has_multiplayer_peer_state(collector_peer_id)
	):
		inventory_snapshot = run_state.export_inventory_snapshot_for_peer(
			collector_peer_id
		)
	_rpc_to_connected_clients(
		&"net_pickup_collected",
		[
			net_id,
			collector_peer_id,
			config_path,
			applied_immediately,
			inventory_snapshot,
		]
	)


func _on_world_flow_merchant_active_broadcast_requested(active: bool) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	if active:
		merchant_transactions_coordinator.clear_offer_states()
	_rpc_to_connected_clients(&"net_merchant_active_changed", [active])


func _on_world_flow_state_broadcast_requested(
	step_id: StringName,
	state: int,
	countdown_seconds: int
) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_flow_state_changed", [String(step_id), state, countdown_seconds])


func _on_world_flow_wave_progress_broadcast_requested(
	progress: Dictionary,
	reliable: bool
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or progress.is_empty():
		return
	_rpc_to_connected_clients(
		(
			&"net_tower_defense_wave_progress_keyframe"
			if reliable
			else &"net_tower_defense_wave_progress_changed"
		),
		[
			int(progress.get("wave_number", 1)),
			int(progress.get("defeated", 0)),
			int(progress.get("escaped", 0)),
			int(progress.get("resolved", 0)),
			int(progress.get("total", 0)),
		]
	)


func _on_world_flow_boss_started_broadcast_requested(
	net_id: int,
	boss_config_path: String,
	spawn_position: Vector2
) -> void:
	if not is_inside_tree() or not net_manager.is_host() or boss_config_path.is_empty():
		return
	_rpc_to_connected_clients(
		&"net_boss_started",
		[net_id, boss_config_path, spawn_position]
	)


func _on_host_linglan_airdrop_started(
	enemy_config: EnemyConfig,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if (
		not is_inside_tree()
		or not net_manager.is_host()
		or enemy_config == null
		or enemy_config.resource_path.is_empty()
	):
		return
	_rpc_to_connected_clients(
		&"net_linglan_airdrop_started",
		[
			enemy_config.resource_path,
			landing_position,
			warning_duration,
			drop_height,
			drop_duration,
		]
	)


func _on_world_flow_defeat_broadcast_requested(failure_reason: String) -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_game_defeated", [failure_reason])


func _on_world_flow_victory_broadcast_requested() -> void:
	if not is_inside_tree() or not net_manager.is_host():
		return
	_rpc_to_connected_clients(&"net_game_victory")


func _clear_pending_player_revives() -> void:
	player_coordinator.clear_pending_revives()


func _on_game_return_to_lobby_requested() -> void:
	if net_manager != null and net_manager.has_method("disconnect_from_game") and net_manager.is_multiplayer_active():
		net_manager.disconnect_from_game()
		return
	_return_to_lobby()


@rpc("any_peer", "call_remote", "reliable", 0)
func net_runtime_state_requested(include_flow_state: bool = true) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not net_manager.is_host() or game == null:
		return
	_handle_authoritative_runtime_state_request(sender_id, include_flow_state)


func _handle_authoritative_runtime_state_request(
	sender_id: int,
	include_flow_state: bool
) -> bool:
	if not session_coordinator.admit_authoritative_runtime_state_request(
		net_manager.is_host(),
		sender_id,
		_get_net_time()
	):
		return false
	_send_runtime_state_to_peer(sender_id, include_flow_state)
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func net_terrain_snapshot_requested(known_revision: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	tower_world_coordinator.handle_remote_terrain_snapshot_request(
		sender_id,
		known_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_snapshot_chunk(
	snapshot_id: int,
	revision: int,
	chunk_index: int,
	chunk_count: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	tower_world_coordinator.receive_terrain_snapshot_chunk(
		snapshot_id,
		revision,
		chunk_index,
		chunk_count,
		cell_xy,
		terrain_types
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_terrain_delta(
	revision: int,
	cell_xy: PackedInt32Array,
	terrain_types: PackedInt32Array
) -> void:
	tower_world_coordinator.receive_terrain_delta(
		revision,
		cell_xy,
		terrain_types
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_runtime_world_manifest(
	live_enemy_ids: PackedInt32Array,
	live_pickup_ids: PackedInt32Array,
	live_plant_ids: PackedInt32Array
) -> void:
	if game == null or net_manager.is_host():
		return
	var manifest := session_coordinator.parse_runtime_world_manifest(
		live_enemy_ids,
		live_pickup_ids,
		live_plant_ids
	)
	enemy_coordinator.remove_enemies_missing_from_manifest(manifest.enemy_id_set)
	for net_id_variant in game.multiplayer_pickups.keys():
		var net_id := int(net_id_variant)
		if not manifest.pickup_id_set.has(net_id):
			net_pickup_removed(net_id)
	if _has_tower_mode():
		for plant_net_id in manifest.positive_plant_ids:
			tower_economy_coordinator.notify_plant_available(plant_net_id)
		var removed_plant_ids := (
			tower_world_coordinator.find_live_plant_ids_missing_from_manifest(
				manifest.plant_id_set
			)
		)
		for plant_net_id in removed_plant_ids:
			tower_economy_coordinator.notify_plant_removed(plant_net_id)
		tower_world_coordinator.reconcile_runtime_manifest(
			manifest.plant_id_set,
			manifest.positive_plant_ids,
			removed_plant_ids
		)
		_try_apply_pending_warehouse_snapshots_atomically()
		# CH5 manifests have no total order with CH6 warehouse/production state or
		# CH7 health batches. A pending id that has no local replica yet may belong
		# to a Host spawn still in flight on CH5. Only prune replicas whose existence
		# has already been established locally; unknown payloads remain bounded until
		# spawn consumption, explicit removal, or their own FIFO eviction.


@rpc("any_peer", "call_remote", "reliable", 5)
func net_plant_placement_requested(
	request_id: int,
	plant_id: String,
	anchor: Vector2i
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not _has_tower_mode() or not net_manager.is_host() or game == null:
		return
	tower_world_coordinator.handle_remote_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor
	)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_inventory_plant_placement_requested(
	request_id: int,
	plant_id: String,
	anchor: Vector2i,
	slot_index: int,
	expected_inventory_revision: int,
	item_config_path: String
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not _has_tower_mode() or not net_manager.is_host() or game == null:
		return
	tower_world_coordinator.handle_remote_inventory_plant_placement_request(
		sender_id,
		request_id,
		plant_id,
		anchor,
		slot_index,
		expected_inventory_revision,
		item_config_path
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_command_requested(command: Dictionary) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(sender_id)
	):
		return
	tower_economy_coordinator.handle_authoritative_warehouse_command(
		sender_id,
		command
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_warehouse_snapshot_requested(warehouse_net_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
	):
		return
	tower_economy_coordinator.handle_authoritative_warehouse_snapshot_request(
		sender_id,
		warehouse_net_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_production_command_requested(command: Dictionary) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(sender_id)
	):
		return
	tower_economy_coordinator.handle_authoritative_production_command(
		sender_id,
		command
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_research_command_requested(command: Dictionary) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(sender_id)
	):
		return
	tower_economy_coordinator.handle_authoritative_research_command(
		sender_id,
		command
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_production_snapshot_requested(building_net_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not _has_tower_mode()
		or not net_manager.is_host()
		or game == null
		or sender_id <= 0
	):
		return
	tower_economy_coordinator.handle_authoritative_production_snapshot_request(
		sender_id,
		building_net_id
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_command_result(result: Dictionary) -> void:
	tower_economy_coordinator.receive_warehouse_command_result(result)


@rpc("authority", "call_remote", "reliable", 6)
func net_production_command_result(result: Dictionary) -> void:
	tower_economy_coordinator.receive_production_command_result(result)


@rpc("authority", "call_remote", "reliable", 6)
func net_production_state_batch(
	net_ids: PackedInt32Array,
	states: Array,
	host_sample_times: PackedFloat64Array
) -> void:
	tower_economy_coordinator.receive_production_state_batch(
		net_ids,
		states,
		host_sample_times
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_snapshot(
	peer_id: int,
	snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	transactions_coordinator.receive_inventory_snapshot(
		peer_id,
		snapshot,
		force_inventory_repair
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> void:
	if not _has_tower_mode():
		return
	if not tower_economy_coordinator.receive_warehouse_storage_snapshot_batch(
		warehouse_net_ids,
		snapshots
	):
		push_error("MpGame: rejected an invalid authoritative warehouse snapshot batch.")


@rpc("authority", "call_remote", "reliable", 6)
func net_research_command_result(
	request_id: int,
	building_net_id: int,
	success: bool,
	reason: StringName
) -> void:
	tower_economy_coordinator.receive_research_command_result(
		request_id,
		building_net_id,
		success,
		reason
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_research_state_updated(
	state: Dictionary,
	changed_player_peer_id: int,
	current_xirang: int
) -> void:
	tower_economy_coordinator.receive_research_state_updated(
		state,
		changed_player_peer_id,
		current_xirang
	)


func _apply_warehouse_storage_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> bool:
	return tower_economy_coordinator.apply_warehouse_storage_snapshot(
		warehouse_net_id,
		snapshot
	)


func _apply_warehouse_storage_snapshot_batch(
	warehouse_net_ids: PackedInt32Array,
	snapshots: Array
) -> bool:
	return tower_economy_coordinator.receive_warehouse_storage_snapshot_batch(
		warehouse_net_ids,
		snapshots
	)


func _try_apply_pending_warehouse_snapshots_atomically() -> bool:
	return tower_economy_coordinator.try_apply_pending_warehouse_snapshots_atomically()


func _cache_pending_warehouse_snapshot(
	warehouse_net_id: int,
	snapshot: Dictionary
) -> void:
	tower_economy_coordinator.cache_pending_warehouse_snapshot(
		warehouse_net_id,
		snapshot
	)



func _erase_pending_warehouse_snapshot(warehouse_net_id: int) -> bool:
	return tower_economy_coordinator.erase_pending_warehouse_snapshot(
		warehouse_net_id
	)


func _clear_pending_warehouse_snapshots() -> void:
	tower_economy_coordinator.clear_pending_warehouse_snapshots()


func _cache_pending_remote_production_state(
	net_id: int,
	state: Dictionary,
	host_sample_time: float
) -> bool:
	return tower_economy_coordinator.cache_pending_remote_production_state(
		net_id,
		state,
		host_sample_time
	)


func _take_pending_remote_production_state(net_id: int) -> Dictionary:
	return tower_economy_coordinator.take_pending_remote_production_state(net_id)


func _erase_pending_remote_production_state(net_id: int) -> bool:
	return tower_economy_coordinator.erase_pending_remote_production_state(net_id)


func _clear_pending_remote_production_states() -> void:
	tower_economy_coordinator.clear_pending_remote_production_states()



@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned(
	net_id: int,
	config_path: String,
	pos_x: float,
	pos_y: float,
	host_spawn_timestamp: float
) -> void:
	var spawn_position: Vector2 = Vector2(pos_x, pos_y)
	var mapped_spawn_time: float = _map_host_timestamp_to_client_time(host_spawn_timestamp, false)
	enemy_coordinator.receive_enemy_spawn(
		net_id,
		config_path,
		spawn_position,
		mapped_spawn_time,
		_get_net_time()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_spawned_batch(
	net_ids: PackedInt32Array,
	config_paths: PackedStringArray,
	positions: PackedVector2Array,
	spawn_times: PackedFloat64Array
) -> void:
	var record_count := mini(
		net_ids.size(),
		mini(config_paths.size(), mini(positions.size(), spawn_times.size()))
	)
	for record_index in range(record_count):
		var mapped_spawn_time := _map_host_timestamp_to_client_time(
			spawn_times[record_index],
			false
		)
		enemy_coordinator.receive_enemy_spawn(
			net_ids[record_index],
			config_paths[record_index],
			positions[record_index],
			mapped_spawn_time,
			_get_net_time()
		)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_terminal(
	net_id: int,
	reason: int,
	event_position: Vector2,
	current_health: int = 0,
	health_revision: int = 0,
	confirmed_damage: int = 0,
	impact_direction: Vector2 = Vector2.ZERO,
	damage_type: int = EnemyConfig.DamageType.PHYSICAL,
	show_hit_particles: bool = false
) -> void:
	enemy_coordinator.receive_enemy_terminal(
		net_id,
		reason,
		event_position,
		current_health,
		health_revision,
		confirmed_damage,
		impact_direction,
		damage_type,
		show_hit_particles
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_defeated(net_id: int, defeat_position: Vector2) -> void:
	enemy_coordinator.receive_enemy_defeated(net_id, defeat_position)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_removed(net_id: int) -> void:
	enemy_coordinator.receive_enemy_removed(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_enemy_escaped(net_id: int) -> void:
	if not _has_tower_mode():
		return
	enemy_coordinator.receive_enemy_escaped(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_base_health_changed(
	current_health: int,
	maximum_health: int,
	revision: int
) -> void:
	tower_world_coordinator.receive_base_health_changed(
		current_health,
		maximum_health,
		revision
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_tower_defense_wave_progress_changed(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	world_flow_coordinator.receive_wave_progress(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_tower_defense_wave_progress_keyframe(
	wave_number: int,
	defeated: int,
	escaped: int,
	resolved: int,
	total: int
) -> void:
	net_tower_defense_wave_progress_changed(
		wave_number,
		defeated,
		escaped,
		resolved,
		total
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_xiaocong_fate_state_changed(state: Dictionary) -> void:
	tower_fate_coordinator.receive_fate_state(
		state,
		multiplayer.get_remote_sender_id()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_test_arena_manual_night_changed(enabled: bool) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	tower_world_coordinator.receive_test_arena_manual_night_changed(
		sender_id,
		enabled
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_spawned(
	request_id: int,
	owner_peer_id: int,
	net_id: int,
	plant_id: String,
	anchor: Vector2i,
	current_health: int,
	maximum_health: int,
	health_revision: int,
	runtime_state: Dictionary,
	host_sample_time: float
) -> void:
	var plant := tower_world_coordinator.receive_plant_spawn(
		request_id,
		owner_peer_id,
		net_id,
		plant_id,
		anchor,
		current_health,
		maximum_health,
		health_revision
	)
	if plant == null or not is_instance_valid(plant):
		return
	tower_economy_coordinator.notify_plant_available(net_id)
	_configure_production_network(plant, false)
	_configure_research_network(plant)
	_apply_plant_runtime_state(plant, runtime_state, host_sample_time)
	var production_building := plant as ProductionBuilding
	if (
		production_building != null
		and not production_building.multiplayer_production_snapshot_ready
	):
		production_building.request_multiplayer_production_snapshot()
	_configure_warehouse_network(plant, false)
	tower_world_coordinator.apply_pending_remote_plant_health(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_placement_rejected(request_id: int, reason: String) -> void:
	tower_world_coordinator.receive_plant_placement_rejected(request_id, reason)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_plant_health_changed(
	net_id: int,
	current_health: int,
	maximum_health: int,
	health_revision: int
) -> void:
	tower_world_coordinator.receive_plant_health_changed(
		net_id,
		current_health,
		maximum_health,
		health_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_damage_status_changed(
	net_id: int,
	status_mask: int,
	status_revision: int
) -> void:
	tower_world_coordinator.receive_plant_damage_status_changed(
		net_id,
		status_mask,
		status_revision
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_plant_removed(net_id: int, was_destroyed: bool = false) -> void:
	if not _has_tower_mode() or game == null or net_manager.is_host():
		return
	tower_economy_coordinator.notify_plant_removed(net_id)
	tower_world_coordinator.receive_plant_removed(net_id, was_destroyed)
	_try_apply_pending_warehouse_snapshots_atomically()


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_plant_projectile_visual(
	spawn_position: Vector2,
	direction: Vector2,
	speed: float,
	explosion_radius: float,
	lifetime: float
) -> void:
	tower_world_coordinator.receive_plant_projectile_visual(
		spawn_position,
		direction,
		speed,
		explosion_radius,
		lifetime
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_bamboo_mortar_visual_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	stages: PackedByteArray,
	spawn_positions: PackedVector2Array,
	landing_positions: PackedVector2Array,
	committed_windup_durations: PackedFloat32Array,
	host_action_times: PackedFloat64Array
) -> void:
	tower_world_coordinator.receive_bamboo_mortar_visual_batch(
		plant_net_ids,
		action_ids,
		stages,
		spawn_positions,
		landing_positions,
		committed_windup_durations,
		host_action_times,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_hydrangea_rain_visual(
	plant_net_id: int,
	action_id: int,
	target_position: Vector2,
	host_action_time: float
) -> void:
	tower_world_coordinator.receive_hydrangea_rain_visual(
		plant_net_id,
		action_id,
		target_position,
		host_action_time,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 4)
func net_corn_machine_gun_burst_batch(
	plant_net_ids: PackedInt32Array,
	action_ids: PackedInt32Array,
	directions: PackedVector2Array,
	host_action_times: PackedFloat64Array
) -> void:
	tower_world_coordinator.receive_corn_machine_gun_burst_batch(
		plant_net_ids,
		action_ids,
		directions,
		host_action_times,
		_get_net_time(),
		session_coordinator.has_host_time_offset(),
		session_coordinator.get_host_to_client_time_offset()
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_action(
	net_id: int,
	action_name: String,
	direction: Vector2,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	if not is_finite(host_action_timestamp):
		return
	var received_at := _get_net_time()
	var mapped_action_time := received_at
	if host_action_timestamp >= 0.0:
		mapped_action_time = _map_host_timestamp_to_client_time(
			host_action_timestamp,
			false
		)
	enemy_coordinator.receive_enemy_action(
		net_id,
		StringName(action_name),
		direction,
		action_position,
		action_id,
		mapped_action_time,
		received_at,
		host_action_timestamp
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_target_action(
	net_id: int,
	action_name: String,
	target_peer_id: int,
	action_position: Vector2,
	action_id: int,
	host_action_timestamp: float = -1.0
) -> void:
	if not is_finite(host_action_timestamp):
		return
	var received_at := _get_net_time()
	var mapped_action_time := received_at
	if host_action_timestamp >= 0.0:
		mapped_action_time = _map_host_timestamp_to_client_time(
			host_action_timestamp,
			false
		)
	enemy_coordinator.receive_enemy_target_action(
		net_id,
		StringName(action_name),
		target_peer_id,
		action_position,
		action_id,
		mapped_action_time,
		received_at,
		host_action_timestamp
	)


@rpc("authority", "call_remote", "unreliable_ordered", 7)
func net_enemy_lightning_chain(points: PackedVector2Array) -> void:
	if (
		game == null
		or net_manager.is_host()
		or not _is_valid_enemy_lightning_chain_points(points)
	):
		return
	# Damage and chain selection are Host-only. Clients replay only the accepted
	# endpoint list as a transient visual and never resolve targets locally.
	game.play_lightning_sorcerer_chain_vfx(points)


@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_removed(net_id: int) -> void:
	world_flow_coordinator.receive_pickup_removed(net_id)


@rpc("authority", "call_remote", "reliable", 5)
func net_pickup_spawned(net_id: int, config_path: String, pos_x: float, pos_y: float) -> void:
	world_flow_coordinator.receive_pickup_spawned(
		net_id,
		config_path,
		Vector2(pos_x, pos_y)
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_pickup_collected(
	net_id: int,
	collector_peer_id: int,
	config_path: String,
	applied_immediately: bool,
	inventory_snapshot: Dictionary = {}
) -> void:
	if game == null or net_manager.is_host():
		return
	var pickup: Pickup = game.get_pickup_for_net_id(net_id)
	if pickup != null and is_instance_valid(pickup):
		game.multiplayer_pickups.erase(net_id)
		pickup.queue_free()
	if config_path.is_empty():
		return
	var pickup_config := load(config_path) as PickupConfig
	if pickup_config == null:
		return
	var player_node: Player = game.get_player_for_peer(collector_peer_id)
	if player_node == null or not is_instance_valid(player_node):
		return
	if applied_immediately:
		player_node.apply_pickup(pickup_config, false)
	elif not inventory_snapshot.is_empty():
		var inventory_revision_before := run_state.get_inventory_revision_for_peer(
			collector_peer_id
		)
		var snapshot_applied := run_state.apply_inventory_snapshot_for_peer(
			collector_peer_id,
			inventory_snapshot
		)
		if (
			snapshot_applied
			and run_state.get_inventory_revision_for_peer(collector_peer_id)
			> inventory_revision_before
		):
			player_node.play_world_inventory_pickup_feedback(pickup_config)


@rpc("authority", "call_remote", "reliable", 5)
func net_merchant_active_changed(active: bool) -> void:
	world_flow_coordinator.receive_merchant_active(active)



@rpc("authority", "call_remote", "reliable", 5)
func net_flow_state_changed(step_id: String, state: int, countdown_seconds: int) -> void:
	world_flow_coordinator.receive_flow_state(
		StringName(step_id),
		state,
		countdown_seconds
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_boss_started(net_id: int, boss_config_path: String, spawn_position: Vector2) -> void:
	world_flow_coordinator.receive_boss_started(
		net_id,
		boss_config_path,
		spawn_position,
		_get_net_time()
	)


@rpc("authority", "call_remote", "reliable", 5)
func net_linglan_airdrop_started(
	enemy_config_path: String,
	landing_position: Vector2,
	warning_duration: float,
	drop_height: float,
	drop_duration: float
) -> void:
	if game == null or net_manager.is_host() or enemy_config_path.is_empty():
		return
	var enemy_config := load(enemy_config_path) as EnemyConfig
	if enemy_config == null:
		return
	var runtime_port := _get_linglan_boss_runtime_port()
	if runtime_port == null:
		return
	runtime_port.apply_remote_airdrop_started(
		enemy_config,
		landing_position,
		warning_duration,
		drop_height,
		drop_duration
	)


func _get_linglan_boss_runtime_port() -> LinglanBossRuntimePort:
	if (
		_linglan_boss_runtime_port != null
		and is_instance_valid(_linglan_boss_runtime_port)
	):
		return _linglan_boss_runtime_port
	if game == null or not is_instance_valid(game):
		return null
	_linglan_boss_runtime_port = game.get_node_or_null(
		"LinglanBossRuntimePort"
	) as LinglanBossRuntimePort
	return _linglan_boss_runtime_port


@rpc("authority", "call_remote", "reliable", 5)
func net_game_defeated(failure_reason: String = "") -> void:
	world_flow_coordinator.receive_defeat(failure_reason)


@rpc("authority", "call_remote", "reliable", 5)
func net_game_victory() -> void:
	world_flow_coordinator.receive_victory()


@rpc("any_peer", "call_remote", "reliable", 6)
func net_upgrade_selected(stat_type: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	transactions_coordinator.handle_remote_upgrade_selection(sender_id, stat_type)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_use_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	transactions_coordinator.handle_remote_inventory_item_use_request(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_inventory_item_discard_requested(
	slot_index: int,
	expected_inventory_revision: int = -1
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	transactions_coordinator.handle_remote_inventory_item_discard_request(
		sender_id,
		slot_index,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_simple_crafting_requested(
	request_id: int,
	recipe_id: String,
	expected_inventory_revision: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	transactions_coordinator.handle_remote_simple_crafting_request(
		sender_id,
		request_id,
		recipe_id,
		expected_inventory_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_skill1_purchase_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	transactions_coordinator.handle_remote_skill1_purchase_request(sender_id)


@rpc("any_peer", "call_remote", "reliable", 5)
func net_tower_defense_start_wave_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if not net_manager.is_host() or not world_flow_coordinator.supports_wave_progress():
		return
	if sender_id <= 0:
		return
	if not transactions_coordinator.consume_remote_transaction_admission(sender_id):
		return
	if game.get_player_for_peer(sender_id) == null:
		return
	world_flow_coordinator.request_authoritative_wave_start(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_interaction_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	tower_fate_coordinator.handle_remote_interaction(sender_id)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_fate_vote_requested(
	option_id: String,
	permanent_buff_id: String
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	tower_fate_coordinator.handle_remote_vote(
		sender_id,
		option_id,
		permanent_buff_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_xiaocong_collectible_choice_requested(choice_index: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not _has_tower_mode()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	tower_fate_coordinator.handle_remote_collectible_choice(
		sender_id,
		choice_index
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_collectible_offer_requested(
		sender_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_choice_requested(
	choice_index: int,
	offer_revision: int = 0
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_collectible_choice_requested(
		sender_id,
		choice_index,
		offer_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_requested(offer_revision: int = 0) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_collectible_refresh_requested(
		sender_id,
		offer_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_start_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_special_game_start_requested(
		sender_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_card_reveal_requested(
	session_revision: int,
	card_index: int
) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_special_game_card_reveal_requested(
		sender_id,
		session_revision,
		card_index
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_luoxi_special_game_finish_requested(session_revision: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_luoxi_special_game_finish_requested(
		sender_id,
		session_revision
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_cheat_xirang_requested() -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or not OS.is_debug_build()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_cheat_xirang_requested(
		sender_id
	)


@rpc("any_peer", "call_remote", "reliable", 6)
func net_debug_collectible_requested(config_path: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	if (
		not net_manager.is_host()
		or sender_id <= 0
		or not transactions_coordinator.consume_remote_transaction_admission(
			sender_id
		)
	):
		return
	merchant_transactions_coordinator.handle_remote_debug_collectible_requested(
		sender_id,
		config_path
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_upgrade_confirmed(
	peer_id: int,
	stat_type: int,
	level: int,
	current_xirang: int,
	success: bool,
	free_upgrade: bool = false
) -> void:
	transactions_coordinator.receive_upgrade_confirmation(
		peer_id,
		stat_type,
		level,
		current_xirang,
		success,
		free_upgrade
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_used(
	peer_id: int,
	slot_index: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	transactions_coordinator.receive_inventory_item_used(
		peer_id,
		slot_index,
		config_path,
		success,
		inventory_snapshot,
		force_inventory_repair
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_inventory_item_discarded(
	peer_id: int,
	slot_index: int,
	success: bool,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	transactions_coordinator.receive_inventory_item_discarded(
		peer_id,
		slot_index,
		success,
		inventory_snapshot,
		force_inventory_repair
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_simple_crafting_result(
	peer_id: int,
	request_id: int,
	recipe_id: String,
	result: String,
	inventory_snapshot: Dictionary,
	force_inventory_repair: bool = false
) -> void:
	transactions_coordinator.receive_simple_crafting_result(
		peer_id,
		request_id,
		recipe_id,
		result,
		inventory_snapshot,
		force_inventory_repair
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_skill1_purchase_confirmed(
	peer_id: int,
	current_xirang: int,
	skill1_unlocked: bool,
	result_code: int,
	skill1_upgrade_level: int = -1,
	skill1_charge_duration: float = -1.0
) -> void:
	transactions_coordinator.receive_skill1_purchase_confirmation(
		peer_id,
		current_xirang,
		skill1_unlocked,
		result_code,
		skill1_upgrade_level,
		skill1_charge_duration
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_offer_state(
	peer_id: int,
	offer_revision: int,
	config_paths: PackedStringArray,
	refresh_count: int,
	current_xirang: int,
	refresh_result_code: int = -1
) -> void:
	merchant_transactions_coordinator.receive_luoxi_collectible_offer_state(
		peer_id,
		offer_revision,
		config_paths,
		refresh_count,
		current_xirang,
		refresh_result_code
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_confirmed(
	peer_id: int,
	choice_index: int,
	config_path: String,
	result_code: int,
	offer_revision: int = 0,
	inventory_snapshot: Dictionary = {}
) -> void:
	merchant_transactions_coordinator.receive_luoxi_collectible_confirmation(
		peer_id,
		choice_index,
		config_path,
		result_code,
		offer_revision,
		inventory_snapshot
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_collectible_refresh_confirmed(
	peer_id: int,
	result_code: int,
	refresh_count: int,
	current_xirang: int
) -> void:
	merchant_transactions_coordinator.receive_luoxi_collectible_refresh_confirmation(
		peer_id,
		result_code,
		refresh_count,
		current_xirang
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_started(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {}
) -> void:
	merchant_transactions_coordinator.receive_luoxi_special_game_started(
		peer_id,
		result,
		inventory_snapshot
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_card_revealed(
	peer_id: int,
	result: Dictionary
) -> void:
	merchant_transactions_coordinator.receive_luoxi_special_game_card_revealed(
		peer_id,
		result
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_luoxi_special_game_finished(
	peer_id: int,
	result: Dictionary,
	inventory_snapshot: Dictionary = {}
) -> void:
	merchant_transactions_coordinator.receive_luoxi_special_game_finished(
		peer_id,
		result,
		inventory_snapshot
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_visual_effect(
	effect_type: String,
	spawn_position: Vector2,
	radius: float,
	color: Color,
	duration: float,
	effect_event_id: int = 0
) -> void:
	collectible_presentation_coordinator.receive_visual_effect(
		effect_type,
		spawn_position,
		radius,
		color,
		duration,
		effect_event_id
	)


@rpc("authority", "call_remote", "unreliable", 7)
func net_collectible_follow_visual_effect(
	effect_type: String,
	owner_peer_id: int,
	radius: float,
	duration: float,
	effect_event_id: int = 0
) -> void:
	collectible_presentation_coordinator.receive_follow_visual_effect(
		effect_type,
		owner_peer_id,
		radius,
		duration,
		effect_event_id
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_cheat_xirang_confirmed(peer_id: int, current_xirang: int, added_amount: int) -> void:
	merchant_transactions_coordinator.receive_cheat_xirang_confirmation(
		peer_id,
		current_xirang,
		added_amount
	)


@rpc("authority", "call_remote", "reliable", 6)
func net_debug_collectible_granted(
	peer_id: int,
	config_path: String,
	success: bool,
	inventory_snapshot: Dictionary = {}
) -> void:
	merchant_transactions_coordinator.receive_debug_collectible_granted(
		peer_id,
		config_path,
		success,
		inventory_snapshot
	)


func _apply_debug_collectible_for_peer(peer_id: int, config_path: String) -> void:
	if merchant_transactions_coordinator == null:
		return
	merchant_transactions_coordinator.apply_debug_collectible_for_peer(
		peer_id,
		config_path
	)


func _get_host_peer_id() -> int:
	if net_manager != null and net_manager.has_method("get_host_peer_id"):
		return int(net_manager.get_host_peer_id())
	return 1


func _get_local_peer_id() -> int:
	if net_manager == null:
		return 0
	return int(net_manager.get_local_peer_id())


func _get_client_view_local_peer_id() -> int:
	var local_peer_id := _get_local_peer_id()
	if local_peer_id > 0:
		return local_peer_id
	if game != null:
		return int(game.multiplayer_local_peer_id)
	return 0


func _get_net_time() -> float:
	return session_coordinator.get_net_time()


func _map_host_timestamp_to_client_time(host_timestamp: float, update_offset: bool = true) -> float:
	return session_coordinator.map_host_timestamp_to_client_time(
		host_timestamp,
		update_offset
	)


func _on_connection_state_changed(new_state: int) -> void:
	if new_state == STATE_DISCONNECTED:
		_return_to_lobby()
	elif new_state == STATE_IN_GAME:
		if embedded_runtime:
			if _embedded_runtime_active and net_manager.is_client():
				_request_runtime_state_from_host()
			return
		_client_host_game_ready = true
		if game != null:
			game.activate_runtime()
		if net_manager.is_client():
			_request_runtime_state_from_host()


func _on_net_player_left(peer_id: int) -> void:
	if peer_id <= 0:
		return
	if embedded_runtime and not _embedded_participant_peer_ids.has(peer_id):
		return
	_capture_disconnected_player_reconnect_state(peer_id)
	_clear_peer_network_state(peer_id)
	if game != null:
		game.remove_multiplayer_player(peer_id)


func _capture_disconnected_player_reconnect_state(peer_id: int) -> void:
	if game == null or peer_id <= 0:
		return
	var player_state: SnapshotManager.PlayerState = null
	for state in game.collect_player_snapshot_states():
		if state != null and state.peer_id == peer_id:
			player_state = state
			break
	var spawn_slot_index := 0
	var wave_death_count := 0
	if _has_tower_mode():
		spawn_slot_index = (
			tower_mode_adapter.get_reconnect_spawn_slot_index(peer_id)
		)
		wave_death_count = (
			tower_mode_adapter.get_reconnect_wave_death_count(peer_id)
		)
	var owned_plant_net_ids: Array[int] = []
	if _has_tower_mode():
		for plant_snapshot in _get_tower_plant_snapshots():
			if int(plant_snapshot.get("owner_peer_id", 0)) == peer_id:
				owned_plant_net_ids.append(int(plant_snapshot.get("net_id", 0)))
	var reconnect_state := {
		"state": player_state,
		"spawn_slot_index": spawn_slot_index,
		"wave_death_count": wave_death_count,
		"owned_plant_net_ids": owned_plant_net_ids,
	}
	reconnect_state.merge(
		merchant_transactions_coordinator.capture_reconnect_state(peer_id),
		true
	)
	reconnect_state.merge(
		player_coordinator.capture_reconnect_life_state(peer_id),
		true
	)
	_disconnected_player_reconnect_states[peer_id] = reconnect_state


func _on_net_player_reconnected(
	old_peer_id: int,
	new_peer_id: int,
	player_name: String,
	character_id: StringName
) -> void:
	if (
		old_peer_id <= 0
		or new_peer_id <= 0
		or old_peer_id == new_peer_id
	):
		return
	if (
		embedded_runtime
		and _embedded_participant_peer_ids.has(old_peer_id)
		and _suspended_embedded_participant_peer_ids.has(old_peer_id)
	):
		_embedded_participant_peer_ids.erase(old_peer_id)
		_embedded_participant_peer_ids[new_peer_id] = true
		_suspended_embedded_participant_peer_ids.erase(old_peer_id)
		_suspended_embedded_participant_peer_ids[new_peer_id] = true
		_clear_peer_network_state(old_peer_id)
		_clear_peer_network_state(new_peer_id)
		return
	if game == null:
		return
	var reconnect_state := (
		_disconnected_player_reconnect_states.get(old_peer_id, {}) as Dictionary
	)
	if embedded_runtime:
		if not _embedded_participant_peer_ids.has(old_peer_id):
			return
		# A client that rejoined after this peer disconnected has no local capture.
		# Restore a remote placeholder; the Host's next new-id player keyframe and
		# reliable inventory snapshot converge every authoritative field. The Host
		# must never synthesize missing authority state.
		if reconnect_state.is_empty() and not net_manager.is_client():
			push_error(
				"MpGame: 房主缺少参战玩家 %d 的权威重连状态。"
				% old_peer_id
			)
			return
	var run_state_was_remapped := false
	if run_state.has_multiplayer_peer_state(old_peer_id):
		var preserve_newer_client_inventory: bool = (
			embedded_runtime and net_manager.is_client()
		)
		if not run_state.remap_multiplayer_peer_state(
			old_peer_id,
			new_peer_id,
			preserve_newer_client_inventory,
			preserve_newer_client_inventory
		):
			push_error(
				"MpGame: 无法迁移重连玩家 %d -> %d 的背包状态。"
				% [old_peer_id, new_peer_id]
			)
			return
		run_state_was_remapped = true
	else:
		run_state.ensure_multiplayer_peer_state(new_peer_id)
	var player_state := reconnect_state.get("state") as SnapshotManager.PlayerState
	if player_state != null:
		player_state.peer_id = new_peer_id
	var player_node := game.restore_multiplayer_player(
		old_peer_id,
		new_peer_id,
		player_name,
		character_id,
		player_state,
		int(reconnect_state.get("spawn_slot_index", 0)),
		reconnect_state
	)
	if player_node == null or not is_instance_valid(player_node):
		if run_state_was_remapped:
			if not run_state.remap_multiplayer_peer_state(new_peer_id, old_peer_id):
				push_error(
					"MpGame: 无法回滚重连玩家 %d -> %d 的背包状态。"
					% [new_peer_id, old_peer_id]
				)
		if player_state != null:
			player_state.peer_id = old_peer_id
		push_error(
			"MpGame: 无法恢复重连玩家 %d -> %d 的运行时节点。"
			% [old_peer_id, new_peer_id]
		)
		return
	if embedded_runtime:
		_embedded_participant_peer_ids.erase(old_peer_id)
		_embedded_participant_peer_ids[new_peer_id] = true
	player_coordinator.restore_reconnect_life_state(
		new_peer_id,
		reconnect_state,
		net_manager.is_host()
	)
	merchant_transactions_coordinator.restore_reconnect_state(
		new_peer_id,
		reconnect_state
	)
	if player_state != null:
		player_coordinator.restore_reconnected_player_snapshot(
			player_node,
			player_state,
			_get_net_time(),
			net_manager.is_host(),
			_get_client_view_local_peer_id(),
			player_coordinator.has_local_tango_prediction()
		)
		if net_manager.is_host():
			player_coordinator.remember_accepted_player_pose(
				new_peer_id,
				player_state.position,
				_get_net_time()
			)
	var owned_plant_ids := reconnect_state.get("owned_plant_net_ids", []) as Array
	for plant_net_id_variant in owned_plant_ids:
		var plant := _get_tower_plant(int(plant_net_id_variant))
		if plant != null and is_instance_valid(plant):
			plant.owner_player = player_node
	_disconnected_player_reconnect_states.erase(old_peer_id)


func _clear_peer_network_state(peer_id: int) -> void:
	# A surge field is world-owned after activation. Keep its compact roster
	# record (and sequence guards) across caster removal until the field's own
	# finished signal retires it.
	player_coordinator.mark_tango_owner_disconnected(peer_id)
	var active_tiyi_activation_id := (
		player_coordinator.get_active_tiyi_high_noon_activation_id(peer_id)
	)
	if active_tiyi_activation_id > 0 and net_manager != null and net_manager.is_host():
		_cancel_authoritative_tiyi_high_noon(peer_id, active_tiyi_activation_id, true)
	if (
		player_coordinator.has_active_tango_charge(peer_id)
		and net_manager != null
		and net_manager.is_host()
	):
		_cancel_authoritative_tango_charge(peer_id, true)
	enemy_coordinator.clear_peer(peer_id)
	player_coordinator.clear_peer(peer_id)
	tower_world_coordinator.clear_peer(peer_id)
	_last_tango_volley_visual_state_by_peer.erase(peer_id)
	session_coordinator.clear_peer(peer_id)
	transactions_coordinator.clear_peer(peer_id)
	tower_economy_coordinator.clear_peer(peer_id)
	merchant_transactions_coordinator.clear_peer(peer_id)
	tower_fate_coordinator.clear_peer(peer_id)
	collectible_presentation_coordinator.clear_peer(peer_id)
	network_diagnostics_coordinator.clear_peer(peer_id)
	projectile_coordinator.clear_peer(peer_id)


func _return_to_lobby() -> void:
	player_coordinator.reset_session_state()
	enemy_coordinator.reset_session_state()
	projectile_coordinator.reset_session_state()
	world_flow_coordinator.reset_session_state()
	_disconnected_player_reconnect_states.clear()
	collectible_presentation_coordinator.reset_session_state()
	network_diagnostics_coordinator.reset_session_state()
	tower_economy_coordinator.reset_session_state()
	tower_world_coordinator.reset_session_state()
	merchant_transactions_coordinator.reset_session_state()
	tower_fate_coordinator.reset_session_state()
	session_coordinator.reset_session_state()
	transactions_coordinator.reset_session_state()
	_last_tango_volley_visual_state_by_peer.clear()
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	tree.change_scene_to_file("res://scene/multiplayer/multiplayer_lobby.tscn")
